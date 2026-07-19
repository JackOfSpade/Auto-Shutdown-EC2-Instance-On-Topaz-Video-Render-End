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
tasks itself - that needs elevation. A directory-creation or script-copy
failure is a hard install failure, not a warning: `Install.ps1` logs it as an
ERROR and exits non-zero rather than reporting "Install complete" over a
half-installed pipeline. `Register-ScheduledTasks.ps1` in turn aborts (throws)
if either installed script is missing from `InstallDir`, rather than warning
and registering a task that points at a nonexistent file.

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

**Orphan-worker tracking.** Windows does not kill children when a parent process
dies: if the Topaz GUI crashes or is closed mid-export, its worker keeps encoding
but would otherwise vanish from the watchdog's view the instant the GUI PID
disappears from the process list - misreading "no worker" as "queue complete" and
powering off mid-encode. `Watchdog.ps1` guards against this with a
`$script:KnownWorkers` table, keyed on `"<PID>|<CreationDate.Ticks>"` (the
creation-date half guards against PID reuse): once a worker is positively
attributed to a live Topaz GUI PID, it stays "known" and keeps counting as active
even after its parent GUI is gone, until the worker process itself actually
exits (at which point it is pruned from the table).

**Both signals are three-valued.** The worker-presence check above, and the GPU
read below, can each come back `$true`, `$false`, or `$null` - where `$null`
means "could not be read this poll" (e.g. the underlying CIM query itself
failed), not "no worker" / "idle". `Resolve-RenderActive` (see below) degrades
gracefully: a `$null` signal simply stops contributing and the other signal
decides. Only when **neither** signal can be trusted does the overall decision
come back `$null`, and the main loop **freezes** its idle/stall bookkeeping for
that poll rather than guessing - see "The state machine" below.

### The completion signal: `CompletionSignal`

The worker-presence check above feeds into `CompletionSignal`, which decides what
"a render is currently active" means on each poll:

| Value | Meaning |
|-------|---------|
| `WorkerOnly` (**default**) | Only the presence of the child encoder worker counts. This is the original, most specific behaviour - existing deployments see no change in default behavior. |
| `GpuOnly` | Only GPU utilization `>= GpuBusyPercent` counts. |
| `WorkerOrGpu` | Active if **either** a worker is present **or** the GPU is busy. Most robust if the worker process is not reliably a child of the GUI on your Topaz version. |

An unrecognized `CompletionSignal` value fails loudly at config load time -
`Get-TopazAutoStopConfig` throws naming the bad value and the three valid
ones - instead of surfacing deep in the poll loop as a `Test-RenderActive`
error or a `$null` decision that freezes the watchdog for the life of the
instance.

`GpuBusyPercent` (default **15**) is the GPU utilization percent at or above which
the GPU counts as actively rendering, used by the `GpuOnly` and `WorkerOrGpu`
modes. Note the DCV nuance: while you are **connected** over DCV the remote-display
encoder can add some GPU load of its own - this signal is meant to be read during
the **disconnected** render window, which is exactly when auto-stop matters.

Every mode degrades gracefully: if the GPU read fails (`nvidia-smi` errors or is
unavailable), the GPU simply stops contributing to that poll's decision and the
worker signal decides instead - a failed GPU read is never misread as "idle". The
mirror case (a failed worker read, GPU signal still readable) degrades the same
way. Only when **both** signals are unreadable does the poll come back `$null`
(see "Both signals are three-valued" above) and the watchdog freezes rather than
guesses.

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
`CompletionSignal` says it is (worker presence by default) - and it can itself be
`$null` ("unknown this poll").

- **Signal unreadable (`$null`)** -> neither idle nor active can be trusted this
  poll. The watchdog logs a warning and **freezes** `idleSec`, `stallSec`,
  `sawActivity`, and `lastBytes` exactly as they were, then waits for the next
  poll. This matters because a transient CIM outage used to be indistinguishable
  from "no worker" - which could false-complete a queue mid-encode (nudging
  `idleSec` toward the debounce) or false-stall a healthy one (nudging
  `stallSec`), on a poll that told us nothing either way.
- **Active + output changed (grew OR shrank)** -> healthy; reset `stallSec`. A
  genuinely stalled worker writes nothing at all, so *any* byte delta is proof of
  life. Comparing for growth only had a high-water-mark bug: Topaz can delete a
  large `_temp` scratch file between jobs, shrinking the output folder, and a
  healthy next job growing back up from that lower base could sit under the old
  high-water mark for the whole `StallSec` window and get killed as "stalled"
  mid-render.
- **Active + output NOT growing (bytes unchanged)** -> accrue `stallSec`. If it
  reaches `StallSec` (default **900 s / 15 min**), declare the job **stalled**
  and break.
- **Not active, and we have seen activity before** -> accrue `idleSec`. If it
  reaches `DebounceSec` (default **120 s**), declare the queue **complete** and
  break.
- **Not active, and we have NEVER seen activity** -> this is the normal
  *pre-render* state (opening a project, adding clips, configuring the export).
  The watchdog logs and waits; it does **not** treat this as a completed queue.
  The `sawActivity` guard is what prevents the box from stopping *before the
  first render even begins*. (See [Appendix A](08-appendix-a-corrections.md).)

### Re-verifying "completed" after the unlock gate

A `'completed'` decision is not final the instant the debounce elapses. After the
file-unlock gate below finishes waiting, the watchdog checks `Test-RenderActive`
**one more time** before handing off to the stop step. If the operator queued
another export during the debounce-plus-unlock wait, that re-check comes back
`$true` and the watchdog **resumes monitoring** (resets `idleSec`/`stallSec`,
sets `sawActivity = $true`, refreshes `lastBytes`) instead of stopping partway
into a job that had already restarted. A `'stalled'` decision is **never**
re-verified this way - a stalled worker is still "active" by definition, so
re-checking it would just loop forever instead of ever stopping.

### The debounce

`DebounceSec` exists because Topaz's **live preview** can spawn short-lived
worker children that are not the queued export, and because real multi-clip
queues have inter-clip lulls (the next job loading its model) between jobs.
Requiring the *absence* of activity for a continuous `DebounceSec` window absorbs
both, so a preview flicker or a mid-queue lull is never mistaken for "queue
drained." **Tuning note:** typical inter-clip lulls run **45-90 s**; the default
of **120 s** clears that with margin - at the cost of only about one extra idle
minute per session - because a false "complete" here stops the box mid-queue. Set
it comfortably longer than the longest preview-worker or inter-clip lull you
observed in [Phase 0](02-phase0-confirmations.md). This applies under any
`CompletionSignal` mode - it debounces transitions of "active", not specifically
the worker signal.

### The file-unlock gate

Once the loop decides to stop (completed or stalled), the watchdog does **not**
power off immediately. It waits up to `UnlockTimeoutMin` (default **5 min**) for
every output file to become unlocked:

- It scans `OutputDir` recursively, skipping any file whose name matches
  `TempMarker` (`_temp`) **anchored** to a following `.`, `_`, `-`, or the end of
  the name (`Test-TopazTempFile` in [`Config.ps1`](../in-guest/Config.ps1)) -
  Topaz may leave scratch files behind after a good export, and those must not
  block the stop. Anchoring matters: a plain substring match would also catch a
  real deliverable like `Reel_Template_Final.mp4` (which merely *contains*
  `_temp` inside `_Template`) and silently skip it from the unlock check.
- For each remaining file it tries to open it for read with **no sharing**
  (`FileShare.None`). Success means nothing else holds a write handle - the file
  is fully flushed and closed.
- When all such files are unlocked it proceeds. If the timeout expires with files
  still locked, it logs a warning and proceeds anyway (better to stop a
  cost-accruing box than hang forever). It re-checks every `UnlockPollSec`
  (default **10 s**) while waiting.

Then, for a `'completed'` decision only, it re-verifies once (see above) before
invoking [`Stop-Sequence.ps1`](../in-guest/Stop-Sequence.ps1) with
`-Reason completed` or `-Reason stalled` (see [Phase 3](05-phase3-stop-sequence.md)).

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
  zero (no time limit, runs indefinitely), `-StartWhenAvailable`, and a
  restart-on-failure policy (`RestartCount 3`, one minute apart). It starts at
  boot and waits for the Topaz GUI before arming. The restart policy exists
  because the watchdog is the **primary** stop path - the CloudWatch idle alarm
  is a cost backstop, not a substitute - so a crashed watchdog process should not
  stay dead silently for the rest of the render. (See the limitation note below:
  a restart loses in-memory state, which is exactly what the idle alarm then
  backstops.)
- **`TopazAutoStop-GpuMetric`** - a `-Once` trigger with a 1-minute repetition for
  an effectively-infinite duration (~10000 days), so it runs
  `Push-GpuMetric.ps1` once per minute forever; `-MultipleInstances IgnoreNew`
  skips a run if the previous minute is still going (see [Phase 4](06-phase4-safety-net.md)).
  `ExecutionTimeLimit` is capped at **5 minutes** as OS-level defense-in-depth -
  a run wedged for any reason other than a slow `aws`/`nvidia-smi` call (which
  are already bounded, see [Phase 4](06-phase4-safety-net.md)) would otherwise
  sit forever under `IgnoreNew`, starving every future minute's run.

The registration is idempotent: it unregisters any existing same-name task before
re-creating it, so it is safe to re-run (e.g. after flipping `DryRun`). Each
task's registration is verified (`Get-ScheduledTask` must find it afterward)
and the two are attempted independently, so one failing does not stop the
other from being registered; `Register-ScheduledTasks.ps1` reports honestly
which task(s), if any, failed and exits non-zero rather than always claiming
"Both tasks registered." Verify afterward with:

```powershell
Get-ScheduledTask -TaskName 'TopazAutoStop-Watchdog','TopazAutoStop-GpuMetric'
Get-ScheduledTaskInfo -TaskName 'TopazAutoStop-Watchdog'   # last-run details
```

## Limitation: a watchdog restart mid-render loses in-memory state

`$script:KnownWorkers` (orphan-worker tracking) and the loop variables
`$sawActivity` / `$idleSec` / `$stallSec` / `$lastBytes` live only in the running
`Watchdog.ps1` process - deliberately **not** persisted to disk. If the watchdog
process itself is restarted mid-render (e.g. by the `RestartCount 3` policy
above, after a crash), it comes back up with a clean slate: it no longer knows an
orphaned worker was previously adopted, and it has forgotten whether it has ever
seen an active render this session. Persisting that state across a stop/start
cycle was considered and rejected - stale state surviving a restart would risk a
false stop (e.g. replaying a stale `sawActivity = $true` straight into a fresh
pre-render lull). The trade-off is deliberate: the out-of-band CloudWatch
GPU-idle alarm ([Phase 4](06-phase4-safety-net.md)) is exactly the backstop for
this case, since it does not depend on any in-guest process's memory.

## Logs

Every component writes a timestamped line to both the console and a per-component
log under `C:\topaz-autostop\logs` (`watchdog.log`, `stop.log`, `metric.log`,
`install.log`, `register.log`). Each log rotates once it exceeds 5MB: the live
file is moved to a single `<component>.log.1` backup (replacing any previous one)
rather than growing unbounded for the life of the instance. Logging never throws
in a way that could take down the pipeline. Watch `watchdog.log` during your
first `DryRun` jobs to confirm the completion/stall decisions look right.

Continue to [Phase 3 - the stop sequence](05-phase3-stop-sequence.md).
