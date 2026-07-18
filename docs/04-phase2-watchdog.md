# 04 - Phase 2: The watchdog

[README](../README.md) - [Architecture](01-architecture.md) - [Phase 0](02-phase0-confirmations.md) - [Phase 1](03-phase1-instance-prep.md) - **Phase 2** - [Phase 3](05-phase3-stop-sequence.md) - [Phase 4](06-phase4-safety-net.md) - [Phase 5](07-phase5-notifications.md)

Phase 2 installs the on-box pipeline and registers it to run from boot.
[`Install.ps1`](../in-guest/Install.ps1) copies the scripts into
`C:\topaz-autostop`; [`Register-ScheduledTasks.ps1`](../in-guest/Register-ScheduledTasks.ps1)
registers the two SYSTEM scheduled tasks that point at those installed copies.

```powershell
# 1. edit the OPERATOR SETTINGS block in in-guest\Config.ps1 first (Phase 0 values)
.\in-guest\Install.ps1                     # copies scripts -> C:\topaz-autostop
# 2. from an ELEVATED PowerShell:
.\in-guest\Register-ScheduledTasks.ps1     # registers the two SYSTEM tasks
```

`Install.ps1` creates `InstallDir` + `LogDir`, copies `Config.ps1`,
`Watchdog.ps1`, `Stop-Sequence.ps1`, and `Push-GpuMetric.ps1`, warns if
`nvidia-smi`/`aws` are missing, and then tells you to run
`Register-ScheduledTasks.ps1` from an elevated shell. It does **not** register
tasks itself - that needs elevation.

## How the watchdog decides "done"

[`Watchdog.ps1`](../in-guest/Watchdog.ps1) never drives Topaz and never calls its
CLI. It only **observes**: via CIM (`Win32_Process`) the Topaz GUI process and its
child encoder worker, optionally GPU utilization, and the byte size of the output
folder. Whether a render counts as "active" on any given poll is controlled by
`CompletionSignal` (below). All tuning comes from
[`Config.ps1`](../in-guest/Config.ps1).

### The child-worker-of-Topaz signal

Topaz encodes a queued job by spawning an encoder **child** process. The watchdog:

1. Finds live Topaz GUI PIDs with `Name LIKE 'Topaz Video%'` (`TopazNameLike`).
2. Finds processes matching `WorkerNameLike` (a CIM `LIKE` pattern, default
   `'ffmpeg.exe'`) whose `ParentProcessId` is one of those Topaz PIDs. Only those
   parented-by-Topaz workers count - a stray process of the same name elsewhere on
   the box is ignored.

`WorkerNameLike` is configurable because the exact worker process name is
version-dependent; confirm the real name during
[Phase 0](02-phase0-confirmations.md) and use a `LIKE` pattern such as `'ffmpeg%'`
if it varies. A "real render worker exists" is therefore a precise, event-driven
signal, not a guess.

### The completion signal: `CompletionSignal`

The worker-presence check above feeds into `CompletionSignal`, which decides what
"a render is currently active" means on each poll:

| Value | Meaning |
|-------|---------|
| `WorkerOnly` (**default**) | Only the presence of the child encoder worker counts. This is the original, most specific behaviour - existing deployments see no change in default behavior. |
| `GpuOnly` | Only GPU utilization `>= GpuBusyPercent` counts. |
| `WorkerOrGpu` | Active if **either** a worker is present **or** the GPU is busy. Most robust if the worker process is not reliably a child of the GUI on your Topaz version. |

`GpuBusyPercent` (default **15**) is the GPU utilization percent at or above which
the GPU counts as actively rendering, used by the `GpuOnly` and `WorkerOrGpu`
modes. Note the DCV nuance: while you are **connected** over DCV the remote-display
encoder can add some GPU load of its own - this signal is meant to be read during
the **disconnected** render window, which is exactly when auto-stop matters.

Every mode degrades gracefully: if a GPU read fails (`nvidia-smi` errors or is
unavailable), the GPU simply stops contributing to that poll's decision and the
worker signal decides instead - a failed GPU read is never misread as "idle".

The actual decision is made by `Resolve-RenderActive`, a small **pure** function in
[`Config.ps1`](../in-guest/Config.ps1) that takes the raw worker/GPU signals and
returns a bool with no I/O of its own. Keeping it pure is what makes it
unit-testable: it has Pester coverage in
[`in-guest/tests/`](../in-guest/tests/) exercising all three `CompletionSignal`
modes, the `GpuBusyPercent` boundary, and the graceful-degradation-on-`$null`
behaviour. See [Testing & CI](10-testing-and-ci.md).

### The state machine

The main loop polls every `PollSec` (default **15 s**) and tracks four things:
`idleSec` (time with no active render), `stallSec` (time a render is active but
output is not growing), `sawActivity` (have we *ever* seen an active render), and
`lastBytes` (last output-folder size). "Active" on each poll is whatever
`CompletionSignal` says it is (worker presence by default).

- **Active + output growing** -> healthy; reset `stallSec`.
- **Active + output NOT growing** -> accrue `stallSec`. If it reaches `StallSec`
  (default **900 s / 15 min**), declare the job **stalled** and break.
- **Not active, and we have seen activity before** -> accrue `idleSec`. If it
  reaches `DebounceSec` (default **60 s**), declare the queue **complete** and
  break.
- **Not active, and we have NEVER seen activity** -> this is the normal
  *pre-render* state (opening a project, adding clips, configuring the export).
  The watchdog logs and waits; it does **not** treat this as a completed queue.
  The `sawActivity` guard is what prevents the box from stopping *before the
  first render even begins*. (See [Appendix A](08-appendix-a-corrections.md).)

### The debounce

`DebounceSec` exists because Topaz's **live preview** can spawn short-lived
worker children that are not the queued export. Requiring the *absence* of
activity for a continuous `DebounceSec` window absorbs those blips, so a preview
flicker is never mistaken for "queue drained." **Tuning note:** if your Topaz's
live preview spawns transient worker children, raise `DebounceSec` above their
typical lifetime - 45-60 s is typical, hence the default of 60. Set it comfortably
longer than the longest preview-worker you observed in [Phase 0](02-phase0-confirmations.md).
This applies under any `CompletionSignal` mode - it debounces transitions of
"active", not specifically the worker signal.

### The file-unlock gate

Once the loop decides to stop (completed or stalled), the watchdog does **not**
power off immediately. It waits up to `UnlockTimeoutMin` (default **5 min**) for
every output file to become unlocked:

- It scans `OutputDir` recursively, skipping any file whose name contains
  `TempMarker` (`_temp`) - Topaz may leave scratch files behind after a good
  export, and those must not block the stop.
- For each remaining file it tries to open it for read with **no sharing**
  (`FileShare.None`). Success means nothing else holds a write handle - the file
  is fully flushed and closed.
- When all such files are unlocked it proceeds. If the timeout expires with files
  still locked, it logs a warning and proceeds anyway (better to stop a
  cost-accruing box than hang forever).

Only then does it invoke
[`Stop-Sequence.ps1`](../in-guest/Stop-Sequence.ps1) with `-Reason completed` or
`-Reason stalled` (see [Phase 3](05-phase3-stop-sequence.md)).

## Why the tasks run as SYSTEM

[`Register-ScheduledTasks.ps1`](../in-guest/Register-ScheduledTasks.ps1)
registers both tasks under the **SYSTEM** account (`ServiceAccount` logon,
`RunLevel Highest`). SYSTEM is required for two reasons:

1. **`SeShutdownPrivilege`.** The guest shutdown that stops the instance needs
   the shutdown privilege. SYSTEM holds it unconditionally.
2. **Cross-session CIM visibility.** The Topaz GUI and its encoder-worker children
   run in an *interactive user session*. A task tied to a specific user session
   could miss them (or not exist when nobody is logged in); SYSTEM can enumerate
   processes across all sessions via CIM, so the watchdog always sees the GUI and
   its workers.

The two tasks:

- **`TopazAutoStop-Watchdog`** - trigger `-AtStartup`, `ExecutionTimeLimit` set to
  zero (no time limit, runs indefinitely), `-StartWhenAvailable`. It starts at
  boot and waits for the Topaz GUI before arming.
- **`TopazAutoStop-GpuMetric`** - a `-Once` trigger with a 1-minute repetition for
  an effectively-infinite duration (~10000 days), so it runs
  `Push-GpuMetric.ps1` once per minute forever; `-MultipleInstances IgnoreNew`
  skips a run if the previous minute is still going (see [Phase 4](06-phase4-safety-net.md)).

The registration is idempotent: it unregisters any existing same-name task before
re-creating it, so it is safe to re-run (e.g. after flipping `DryRun`). Verify
afterward with:

```powershell
Get-ScheduledTask -TaskName 'TopazAutoStop-Watchdog','TopazAutoStop-GpuMetric'
Get-ScheduledTaskInfo -TaskName 'TopazAutoStop-Watchdog'   # last-run details
```

## Logs

Every component writes a timestamped line to both the console and a per-component
log under `C:\topaz-autostop\logs` (`watchdog.log`, `stop.log`, `metric.log`,
`install.log`, `register.log`). Logging never throws in a way that could take down
the pipeline. Watch `watchdog.log` during your first `DryRun` jobs to confirm the
completion/stall decisions look right.

Continue to [Phase 3 - the stop sequence](05-phase3-stop-sequence.md).
