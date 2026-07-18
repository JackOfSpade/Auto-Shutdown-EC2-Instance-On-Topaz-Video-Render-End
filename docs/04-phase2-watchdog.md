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
CLI. It only **observes**, via CIM (`Win32_Process`), three things: the Topaz GUI
process, its child `ffmpeg.exe` workers, and the byte size of the output folder.
All tuning comes from [`Config.ps1`](../in-guest/Config.ps1).

### The child-`ffmpeg`-of-Topaz signal

Topaz encodes a queued job by spawning `ffmpeg.exe` **child** processes. The
watchdog:

1. Finds live Topaz GUI PIDs with `Name LIKE 'Topaz Video%'` (`TopazNameLike`).
2. Finds `ffmpeg.exe` processes whose `ParentProcessId` is one of those Topaz
   PIDs. Only those parented-by-Topaz workers count - a stray `ffmpeg` elsewhere
   on the box is ignored.

A "real render worker exists" is therefore a precise, event-driven signal, not a
guess.

### The state machine

The main loop polls every `PollSec` (default **15 s**) and tracks four things:
`idleSec` (time with GUI up but no worker), `stallSec` (time a worker is alive
but output is not growing), `sawWorker` (have we *ever* seen a real worker), and
`lastBytes` (last output-folder size).

- **Worker alive + output growing** -> healthy; reset `stallSec`.
- **Worker alive + output NOT growing** -> accrue `stallSec`. If it reaches
  `StallSec` (default **900 s / 15 min**), declare the job **stalled** and break.
- **No worker, and we have seen one before** -> accrue `idleSec`. If it reaches
  `DebounceSec` (default **60 s**), declare the queue **complete** and break.
- **No worker, and we have NEVER seen one** -> this is the normal *pre-render*
  state (opening a project, adding clips, configuring the export). The watchdog
  logs and waits; it does **not** treat this as a completed queue. The
  `sawWorker` guard is what prevents the box from stopping *before the first
  render even begins*. (See [Appendix A](08-appendix-a-corrections.md).)

### The debounce

`DebounceSec` exists because Topaz's **live preview** can spawn short-lived
`ffmpeg` children that are not the queued export. Requiring the *absence* of any
worker for a continuous `DebounceSec` window absorbs those blips, so a preview
flicker is never mistaken for "queue drained." **Tuning note:** if your Topaz's
live preview spawns transient `ffmpeg` children, raise `DebounceSec` above their
typical lifetime - 45-60 s is typical, hence the default of 60. Set it comfortably
longer than the longest preview-worker you observed in [Phase 0](02-phase0-confirmations.md).

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
2. **Cross-session CIM visibility.** The Topaz GUI and its `ffmpeg` children run
   in an *interactive user session*. A task tied to a specific user session
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
