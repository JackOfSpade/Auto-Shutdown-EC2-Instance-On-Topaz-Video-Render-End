# 04 - Phase 2: The watchdog

[README](../README.md) - [Architecture](01-architecture.md) - [Phase 0](02-phase0-confirmations.md) - [Phase 1](03-phase1-instance-prep.md) - **Phase 2** - [Phase 3](05-phase3-stop-sequence.md) - [Phase 4](06-phase4-safety-net.md) - [Phase 5](07-phase5-notifications.md)

Phase 2 installs the on-box pipeline and registers it to run from boot.
[`Install.ps1`](../in-guest/Install.ps1) copies the scripts into
`C:\topaz-autostop`; [`Register-ScheduledTasks.ps1`](../in-guest/Register-ScheduledTasks.ps1)
registers the three SYSTEM scheduled tasks that point at those installed copies.

```powershell
# 1. edit the OPERATOR SETTINGS block in in-guest\Config.ps1 first (Phase 0 values)
.\in-guest\Install.ps1                     # copies scripts -> C:\topaz-autostop
# 2. from an ELEVATED PowerShell:
.\in-guest\Register-ScheduledTasks.ps1     # registers the three SYSTEM tasks
```

`Install.ps1` creates `InstallDir` + `LogDir`, copies the five mandatory
scripts - `Config.ps1`, `Watchdog.ps1`, `Stop-Sequence.ps1`, `Push-GpuMetric.ps1`
and `Initialize-ScratchDisk.ps1` - (plus, best-effort, the four optional
operator tools `Register-TimedStop.ps1`, `Test-Deployment.ps1`,
`Set-GoogleDriveAuth.ps1` and `Register-ScheduledTasks.ps1` when present - a
missing one of those is only a warning, not an install failure; the last is
copied so `InstallDir` stays self-contained and tasks can be re-registered
after the repo checkout is deleted, which [docs/11](11-deploying-on-this-instance.md)
documents as a recovery step), warns if `nvidia-smi`/`aws` are missing, and then tells you to run
`Register-ScheduledTasks.ps1` from an elevated shell. It does **not** register
tasks itself - that needs elevation. A directory-creation or script-copy
failure is a hard install failure, not a warning: `Install.ps1` logs it as an
ERROR and exits non-zero rather than reporting "Install complete" over a
half-installed pipeline. `Register-ScheduledTasks.ps1` in turn aborts (throws)
if either installed script is missing from `InstallDir`, rather than warning
and registering a task that points at a nonexistent file.

## How the watchdog decides "done"

[`Watchdog.ps1`](../in-guest/Watchdog.ps1) never drives Topaz and never calls its
CLI. It only **observes**: via CIM (`Win32_Process`) the Topaz GUI process and
its encoder-worker descendants (matched by ancestry, not direct parentage),
optionally GPU utilization, and the output folder's byte size **and** the
workers' own cumulative disk I/O. Whether a render counts as "active" on any
given poll is controlled by `CompletionSignal` (below). All tuning comes from
[`Config.ps1`](../in-guest/Config.ps1).

### The worker-ancestry signal

Topaz encodes a queued job through a chain of processes, not a single child:
on this deployment the observed chain is `Topaz Video.exe` -> `neuroserver.exe`
-> `ffmpeg.exe`, i.e. `ffmpeg` is a **grandchild** of the GUI, not a direct
child (see [docs/12-empirical-findings.md](12-empirical-findings.md)). A
one-level "is this process's `ParentProcessId` the GUI's PID?" test therefore
misses `ffmpeg` entirely - which is exactly what the original, direct-child
implementation did, and why it never saw an active render at all. The
watchdog instead matches by **ancestry**:

1. Finds live Topaz GUI PIDs with `Name LIKE 'Topaz Video%'` (`TopazNameLike`).
2. Snapshots every process's `ProcessId`/`ParentProcessId` on the box and walks
   the tree breadth-first from those GUI PIDs, to unlimited depth
   (`Resolve-ProcessDescendants`, a pure, unit-tested function), producing the
   full set of PIDs descended from a live Topaz GUI - children, grandchildren,
   and deeper.
3. Finds processes matching any pattern in `WorkerNamesLike` (an **array** of
   CIM `LIKE` patterns, default `@('neuroserver.exe', 'ffmpeg.exe')`) and keeps
   only those whose PID is in that descendant set (or is a previously-adopted
   orphan - see below). A stray process of the same name elsewhere on the box,
   not descended from Topaz, is ignored.

`WorkerNamesLike` is an **array**, not a single string, because one process
name cannot describe the real topology: `neuroserver.exe` is the load-bearing
entry - it spans a queued item's entire lifetime, including the several-minute
analysis phase before `ffmpeg` even exists (see
[docs/12-empirical-findings.md](12-empirical-findings.md)) - and `ffmpeg.exe`
is kept as a second, corroborating signal for the encode sub-phase. Confirm
the real chain during [Phase 0](02-phase0-confirmations.md) - it is version
dependent - and add every worker name in it (`LIKE` patterns such as
`'ffmpeg%'` are fine) to `WorkerNamesLike`. A "real render worker exists" is
therefore a precise, event-driven signal, not a guess.

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
| `WorkerOnly` (**default**) | Only the presence of a matched encoder-worker descendant counts. See the DCV warning below for why this is the default on a box whose GPU is shared with the remote-display encoder. |
| `GpuOnly` | Only GPU utilization `>= GpuBusyPercent` counts. |
| `WorkerOrGpu` | Active if **either** a worker descendant is present **or** the GPU is busy. Safer on a box with a *dedicated* render GPU, where a false "busy" merely leaves the box up a little longer while a false "idle" would power it off mid-render. **Do not use it where DCV shares the GPU** - see below. |

> **Why `WorkerOnly` is the default: the DCV GPU-sharing trap.** Amazon DCV
> encodes the remote display on the same GPU the renders use. Measured on the
> reference deployment, an operator merely being *connected* - no render at all
> - drove the GPU to **14-55%**, far above `GpuBusyPercent = 15`. Under
> `WorkerOrGpu` the watchdog logged `Render active (worker=False gpu=21%)` with
> nothing rendering.
>
> That is worse than cosmetic. The GPU signal sets the internal `SawActivity`
> flag, which is the very thing that stops the watchdog completing a queue
> before a render has begun. Once set, a quiet spell of `DebounceSec` is enough
> to declare the queue "complete" - so an operator connecting over DCV, loading
> a project for twenty minutes and then pausing could have the box powered off
> underneath them, having never rendered anything.
>
> The GPU signal only ever existed as a hedge against unreliable worker
> detection. Now that matching is by ancestry and validated end-to-end (see
> [docs/12](12-empirical-findings.md)), that hedge is all cost on a DCV box.
> The failure direction of `WorkerOnly` is also the safe one: if worker
> detection ever broke, the box would fail to stop (costing money) rather than
> stop wrongly (costing a render or a working session).

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

The main loop polls every `PollSec` (default **15 s**) and tracks six things:
`idleSec` (time with no active render), `stallSec` (time a render is active but
making no progress), `sawActivity` (has the watchdog ever *armed* - see
`ArmSec` below), `activeSec` (consecutive seconds active so far, the arm
debounce's own clock), `lastBytes` (last output-folder size), and `lastIoBytes`
(last cumulative worker disk I/O total). "Active" on each poll is whatever
`CompletionSignal` says it is (`WorkerOnly` on this deployment, see the table
above) - and it can itself be `$null` ("unknown this poll").

All six are inputs to one pure function, `Get-NextWatchdogState`, which returns
the next bookkeeping plus a verdict of `continue` / `stalled` / `completed`;
the loop itself only fetches inputs, logs, and acts on that verdict. `ArmSec`
and `activeSec` are **mandatory** parameters of that function with no defaults,
deliberately: they used to default to `0`, and `ArmSec = 0` arms the watchdog on
the *first* active poll, silently restoring the very behaviour the arm debounce
exists to remove. A caller that forgets them now fails loudly at parameter
binding, and a watchdog that dies leaves the box **up**.

- **Signal unreadable (`$null`)** -> neither idle nor active can be trusted this
  poll. The watchdog logs a warning and **freezes** `idleSec`, `stallSec`,
  `sawActivity`, `activeSec`, `lastBytes`, and `lastIoBytes` exactly as they
  were, then waits for the next poll. This matters because a transient CIM outage
  used to be indistinguishable from "no worker" - which could false-complete a queue
  mid-encode (nudging `idleSec` toward the debounce) or false-stall a healthy
  one (nudging `stallSec`), on a poll that told us nothing either way.
  `activeSec` is frozen for the mirror reason: an unreadable poll is not evidence
  the worker went away, so it must neither *advance* the arm counter nor *reset*
  it - on a box with intermittent CIM failures, resetting would mean a genuine
  render could never accumulate `ArmSec` and the watchdog would silently become
  inert.
- **Active + progress on EITHER signal** -> healthy; reset `stallSec`. Progress
  is the *union* of two things:
  - the output folder's byte total **changing** (grew OR shrank - a genuinely
    stalled worker writes nothing at all, so *any* byte delta is proof of
    life; comparing for growth only had a high-water-mark bug, since Topaz can
    delete a large `_temp` scratch file between jobs and a healthy next job
    growing back up from that lower base could otherwise sit under the old
    high-water mark for the whole `StallSec` window), **or**
  - the matched workers' own cumulative `ReadTransferCount`/`WriteTransferCount`
    moving. This second signal was added because, on NTFS, a file's
    directory-entry length does **not** refresh while a writer holds the
    handle open - measured frozen for 466 s straight on this deployment while
    `ffmpeg` wrote 260+ MiB of real output (see
    [docs/12-empirical-findings.md](12-empirical-findings.md)). The
    folder-byte check is kept as a second, corroborating signal, never the
    sole one.
- **Active + NEITHER signal progressed** -> accrue `stallSec`. If it reaches
  `StallSec` (default **1800 s / 30 min**), declare the job **stalled** and
  break.
- **Not active, and we have seen activity before** -> accrue `idleSec`. If it
  reaches `DebounceSec` (default **300 s**), declare the queue **complete** and
  break.
- **Not active, and we have NEVER seen activity** -> this is the normal
  *pre-render* state (opening a project, adding clips, configuring the export).
  The watchdog logs and waits; it does **not** treat this as a completed queue.
  The `sawActivity` guard is what prevents the box from stopping *before the
  first render even begins*. (See [Appendix A](08-appendix-a-corrections.md).)
  `activeSec` is also reset to 0 here: the worker is gone, so whatever arm
  progress it had accrued is discarded rather than banked (see below).

### The arm debounce: `ArmSec`

`DebounceSec` guards the **far** side of a render - do not call it finished too
early. `ArmSec` (default **90 s**) guards the **near** side - do not call it
*started* at all until a worker has been continuously present for that long.

The reason is a measured near-miss on 2026-07-27 05:49. Topaz spawns short-lived
`ffmpeg`/`ffprobe` helpers for previews and thumbnails whenever the operator
touches the GUI; one appeared at 05:49:11 and was gone by 05:49:43 - under 32
seconds. That single active poll set `sawActivity`, which is the flag that makes
the watchdog willing to declare a queue complete. The box then sat idle, ran the
300 s debounce down, and came within ~90 seconds of stopping an instance on which
**no render had ever run**, while the operator was actively working on it.

So `sawActivity` is set only once `activeSec` reaches `ArmSec`, and `activeSec`
resets to 0 on any inactive poll - three separate 30 s blips cannot add up to
90 s and arm the watchdog by accident. Once armed it **stays** armed: a real
render that pauses between queue items must not disarm itself, or the completion
path could never fire at all. The two guards are only meaningful together, and
`in-guest/tests/Watchdog.Tests.ps1` exercises them that way: a 75 s burst (one
poll short of `ArmSec`) followed by 375 s of idle (well past `DebounceSec`) must
still never complete.

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
queues have inter-clip lulls between jobs: the GUI tears down one queue item's
`neuroserver` worker and only spawns the next item's afterward. Requiring the
*absence* of activity for a continuous `DebounceSec` window absorbs both, so a
preview flicker or a mid-queue lull is never mistaken for "queue drained."
**Tuning note:** the default is now **300 s (5 min)**, deliberately generous -
a false "complete" here stops the box mid-queue and destroys an entire
unrendered remainder, a far worse outcome than the five extra idle minutes it
costs at the genuine end of a session. Set it comfortably longer than the
longest preview-worker or inter-clip lull you observed in
[Phase 0](02-phase0-confirmations.md). This applies under any
`CompletionSignal` mode - it debounces transitions of "active", not
specifically the worker signal.

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
- When all such files are unlocked it proceeds. It re-checks every
  `UnlockPollSec` (default **10 s**) while waiting, and the deadline is computed
  from `[datetime]::UtcNow`, not local wall-clock time - a DST fall-back would
  otherwise make a 5-minute gate unreachable for an extra 60 minutes.
- **If the timeout expires with files still locked, what happens depends on
  `OutputIsEphemeral`**, and on this deployment (which ships
  `OutputIsEphemeral = $true`) it is the *refusing* branch that runs:
  - `OutputIsEphemeral = $false` - it logs a warning and **proceeds anyway**.
    The output survives the stop either way, so it is better to stop a
    cost-accruing box than to hang forever.
  - `OutputIsEphemeral = $true` (**the shipped value**) - it **refuses to stop**
    and re-arms. Powering off would erase the scratch volume, and a file still
    locked at the deadline is a file something may still be writing. Refusing is
    the direct lesson of [docs/16](16-render-loss-incident.md); an unbounded
    retry that keeps costing money is the correct trade against a stop that
    costs the render.

The unlock wait is a **blocking** loop, so it keeps its own heartbeat on the
`HeartbeatSec` clock (ticking at `UnlockPollSec`, not `PollSec`) - otherwise it
would log nothing at all between "waiting for output files to unlock" and its
own conclusion, which at a raised `UnlockTimeoutMin` would be a multi-minute void
in `watchdog.log` during the single most dangerous phase of the cycle.

Then, for a `'completed'` decision only, it re-verifies once (see above) before
invoking [`Stop-Sequence.ps1`](../in-guest/Stop-Sequence.ps1) with
`-Reason completed` or `-Reason stalled` (see [Phase 3](05-phase3-stop-sequence.md)).

### The three pre-stop refusals, and the retry loop they create

The watchdog can decline to hand off - or decline to act on a hand-off - at three
points. All three do the same thing: log loudly, **leave the instance up**, and
re-arm so the whole `completed -> unlock -> upload -> stop` path retries roughly
every `DebounceSec`. None of them exits the process, because exiting would leave
nothing watching a box that is still running, still billing, and still holding an
un-uploaded render on a volume nothing else will protect (this project runs with
the CloudWatch idle alarm deliberately **unarmed** - see
[docs/09 §5](09-appendix-b-boundaries.md#5-no-idle-alarm-no-timed-stop-the-watchdog-is-the-only-thing-that-will-ever-stop-this-box)).

1. **The unlock gate** - files still locked at the deadline on ephemeral storage,
   or `OutputDir` could not be fully enumerated for the gate at all (see above).
2. **The handoff snapshot** - immediately after the gate the watchdog records
   `OutputDir`'s real file count and byte total, which is the line the 2026-07-28
   incident was missing. If that enumeration fails it refuses rather than claim a
   partial listing is final.
3. **`Stop-Sequence.ps1` itself** - it returns `$false` when *it* refused (no
   `UploadTarget` on ephemeral storage, an upload that failed or could not be
   verified, or every action in the stop plan failing). The watchdog also treats
   a **throw** from that script, and any return value that is not exactly one
   boolean, as a refusal: `Stop-Sequence.ps1` has no top-level `try`/`catch` of
   its own and legitimately throws on bad config, and an uncaught throw used to
   kill the watchdog process outright - after which a restarted watchdog, seeing
   no worker and starting from `sawActivity = $false`, could **never** reach
   `completed` again and the box would run indefinitely.

Each refusal is numbered in the log (`refusal #N since the last clean cycle`).
The counter matters because for `reason = 'stalled'` the retry loop is unbounded
by design - a hung encoder still holding its output handle fails the gate every
cycle - so without a count `watchdog.log` shows an identical block repeating with
no way to tell the 40th attempt from the first. It resets to 0 on any cycle that
did **not** refuse (the re-verify found a live render, or `Stop-Sequence.ps1` ran
and returned cleanly).

### Incremental per-render upload, and the blind window it introduces (CORRECTION 3, shipped 2026-07-28)

Before this correction, the poll loop only ever logged an `OutputDir` file-count/byte-total
snapshot once, at handoff (see "The file-unlock gate" above) - upload itself happened later,
once, inside `Stop-Sequence.ps1`. On a multi-export queue that left a finished deliverable
unprotected on the ephemeral scratch volume for however long the rest of the queue took to
render - see [docs/16](16-render-loss-incident.md) for why that gap mattered concretely. Per the
operator's instruction, `Watchdog.ps1` now uploads each render as soon as IT finishes, not after
the whole queue drains. [Phase 3](05-phase3-stop-sequence.md) documents the upload mechanics
being reused; this section documents the change from the poll loop's own perspective.

**The eligibility rule.** `Resolve-IncrementalUploadEligibility` (pure; `Watchdog.ps1`) decides
whether one candidate file in `OutputDir` is eligible for its own, early upload right now. Five
conditions all gate it: not a temp file (`Test-TopazTempFile`), **unlocked**
(`Test-FileUnlocked` - the same function the unlock gate above uses, moved into `Config.ps1` so
both callers share one implementation), the size reported now still matching the size tracked as
of the last poll, that size having held for at least `UploadStableSec` (default **30 s**, i.e. 2
consecutive polls at the default `PollSec`) of consecutive polls, and the file not already having
been uploaded earlier this session. Unlocked alone is not enough - a file can be briefly reported
unlocked between writes - so unlocked-and-size-stable are required together, mirroring this
file's own convention of never trusting a single signal where two are available (compare the
stall detector's own byte-count-OR-I/O-counters union earlier in this document). The per-file
stability bookkeeping (size-last-seen, seconds-stable) is computed each poll by the companion pure
function `Get-NextUploadTrackingState`, which calls `Resolve-IncrementalUploadEligibility` with
the freshly-updated numbers; both are independently unit-tested the same way `Resolve-RenderActive`
and `Get-NextWatchdogState` already are. The main poll loop drives both through
`Invoke-TopazIncrementalUploadPoll`, called **every poll, regardless of whether a render is
currently active** - gating it on "active" would silently reopen the exact hole this correction
closes, since the point is protecting a file that finished while the *next* queue item is already
rendering.

> **A crashed writer can still pass this rule once, before the real content is in - but the
> mistake now self-corrects.** `Resolve-IncrementalUploadEligibility` treats "unlocked +
> size-stable for `UploadStableSec`" as a proxy for "finished," but a worker that crashes
> mid-export also releases its file handle and leaves the file at a stable, merely **incomplete**
> size - and, per [docs/16 §I](16-render-loss-incident.md), a worker crashing mid-export and being
> silently resumed through Topaz's own retry path is this box's documented, recurring behaviour,
> not a hypothetical. The eligibility rule cannot tell that case apart from a genuinely finished
> file, so the partial can still be uploaded and self-verified (both sides hold the same partial
> bytes) before the resumed writer overwrites it with the correct content - this does NOT make
> "unlocked + size-stable" a reliable "finished" signal. What no longer happens: identity (condition
> 5) is keyed on `UploadedSize`/`UploadedWriteTimeUtc` - the size and write-time actually uploaded -
> not the bare path alone (FINDING 2 of the 2026-07-28 adversarial review). Once the resumed writer
> overwrites that path with the real content, its size and/or write-time stop matching what was
> uploaded, so the path becomes eligible again the moment the new content restabilizes for
> `UploadStableSec`, and is re-uploaded - logged distinctly, at WARN, with the greppable literal
> `SUPERSEDED` - on the very next poll after that, instead of sitting "verified" until the final
> `Stop-Sequence.ps1` sweep (potentially hours later on a multi-export queue). An unchanged file is
> still skipped every poll, so this does not turn into a re-upload-every-poll loop. See
> [Phase 3](05-phase3-stop-sequence.md)'s own note on the same mechanism for the full reasoning.

**The blind window, stated honestly.** Uploading a multi-GB file takes real wall-clock time - on
the order of 1-2 minutes for a multi-GB render at the throughput measured on this deployment
([docs/16](16-render-loss-incident.md)) - and this poll loop is single-threaded, so the watchdog
observes **nothing else** while an incremental upload is running (`Invoke-TopazIncrementalUpload`
in `Config.ps1` runs `rclone copyto` + a file-to-file `rclone check` synchronously on the polling
thread). That
is accepted, not hidden: `DebounceSec` (300 s) and `StallSec` (1800 s) are both generous budgets,
and the upload only ever starts at the moment a render has *just* finished - the point in the
whole cycle where a brief blind spell is least likely to hide anything that matters. The window is
bounded by the existing `UploadTimeoutSec` plumbing (the same bound the end-of-queue upload uses,
see [Phase 3](05-phase3-stop-sequence.md)), so a wedged transfer cannot freeze the watchdog forever
the way an unbounded call could. The call is placed **after** the idle/stall/arm state-machine
update for the poll, never before or interleaved with it, precisely so a blocking upload cannot
delay that safety-critical bookkeeping's read of the render-active signal.

**Why not a background job.** Running the incremental upload in a `Start-Job`/runspace so the
poll loop keeps observing during the transfer was considered and deliberately rejected: the added
concurrency-control complexity in this pipeline's single most safety-critical loop - the one
deciding whether it is safe to power the box off - was judged not worth it for a window this small
and this well covered by `DebounceSec`/`StallSec`'s own margins. A simple, sequential,
occasionally-blind loop that is easy to reason about beats a concurrent one that merely runs the
completion-decision logic on a schedule while something else happens alongside it.

A failed incremental upload is never fatal to the loop: it reuses `Resolve-UploadRetryDecision`'s
one-retry policy, and on continued failure it just logs and leaves the file unmarked in the
in-memory tracking table for the final `Stop-Sequence.ps1` sweep - still an unconditional
catch-all - to pick up later. The whole pass is switchable via `UploadWhenReady` (default `$true`)
without a code change.

**Containment is per file, not per pass.** A failure while handling one file - a lock probe that
errors, or `Invoke-TopazIncrementalUpload`'s relative-path arithmetic throwing because a file's
`FullName` does not sit under the configured `OutputDir` (a junction, or an `OutputDir` spelled
differently from what enumeration returns) - is caught around **that file only**. Everything after
it in the enumeration is still processed, and the file itself is left exactly as the tracking table
already had it, for a later poll to retry. This matters because enumeration order is stable: with
pass-level containment alone, one *persistent* per-file fault silently disabled incremental upload
for every file ordered after it, on every poll, for the life of the process - defeating this
correction for precisely the multi-file queue it exists to protect. An outer `try`/`catch` still
wraps the iteration and the prune as a backstop, so nothing here can take down the poll loop.

**One directory walk per poll.** `OutputDir` is enumerated **once** per poll
(`Get-OutputFileSnapshot`) and that single snapshot feeds both the progress/stall signal and this
upload pass. Previously each walked the multi-GB folder separately, every `PollSec`, at two
different instants - so the two could also disagree about what was in the folder. `$null` from that
walk means "could not be read", never "empty": the stall bookkeeping freezes and this pass is
skipped entirely, rather than pruning tracked files that a failed read merely did not see. In the
same spirit, a file whose tracked uploaded size *and* write-time already match what is on disk is
no longer lock-probed at all - it is ineligible at the identity gate regardless, and the probe is
an exclusive `FileShare.None` open that would briefly deny another process access to a finished
deliverable on every poll for the rest of the queue.

## Why the tasks run as SYSTEM

[`Register-ScheduledTasks.ps1`](../in-guest/Register-ScheduledTasks.ps1)
registers all three tasks under the **SYSTEM** account (`ServiceAccount` logon,
`RunLevel Highest`). SYSTEM is required for two reasons:

1. **`SeShutdownPrivilege`.** The guest shutdown that stops the instance needs
   the shutdown privilege. SYSTEM holds it unconditionally.
2. **Cross-session CIM visibility.** The Topaz GUI and its encoder-worker children
   run in an *interactive user session*. A task tied to a specific user session
   could miss them (or not exist when nobody is logged in); SYSTEM can enumerate
   processes across all sessions via CIM, so the watchdog always sees the GUI and
   its workers.

The three tasks:

- **`TopazAutoStop-Watchdog`** - **two** triggers: `-AtStartup` (the normal
  path) and a **15-minute repeating sweep** (a `-Once` trigger with a
  `RepetitionInterval` of 15 minutes over an effectively-infinite duration),
  plus `ExecutionTimeLimit` set to zero (no time limit, runs indefinitely),
  `-StartWhenAvailable`, `-MultipleInstances IgnoreNew`, and a
  restart-on-failure policy (`RestartCount 3`, one minute apart). It starts at
  boot and waits for the Topaz GUI before arming. The restart policy exists
  because the watchdog is the **primary, and on this project the *only*,**
  stop path (see
  [docs/09 §5](09-appendix-b-boundaries.md#5-no-idle-alarm-no-timed-stop-the-watchdog-is-the-only-thing-that-will-ever-stop-this-box)
  for why no out-of-band alarm is armed here to catch a crashed watchdog) - so
  a crashed watchdog process should not stay dead silently for the rest of the
  render; the 15-minute sweep is a **self-healing** layer on top of that
  restart policy, reviving the watchdog within 15 minutes if it ever exhausts
  `RestartCount`'s retries and stays dead. `MultipleInstances IgnoreNew` is
  what makes the sweep safe: it is a no-op whenever the watchdog is already
  running, instead of stacking a second copy that would independently decide
  to stop the box. (See the limitation note below: a restart loses in-memory
  state - on a deployment that arms the CloudWatch idle alarm, that alarm
  backstops exactly this case, since it does not depend on any in-guest
  process's memory; this project runs without that backstop, by decision.)
- **`TopazAutoStop-ScratchInit`** - a single `-AtStartup` trigger running
  [`Initialize-ScratchDisk.ps1`](../in-guest/Initialize-ScratchDisk.ps1), with
  `ExecutionTimeLimit` **15 minutes** and `RestartCount 2` one minute apart.
  **Deliberately no recurring sweep**, unlike the watchdog: the script is a
  no-op once the volume exists, so re-running it buys nothing. This task cannot
  be a one-off install step, because the instance store is wiped and comes back
  as a **RAW, unpartitioned disk on every start** - so without it `OutputDir`
  does not exist after the first stop, Topaz has nowhere to export to, and the
  stop sequence then (correctly) refuses to stop because it cannot upload
  renders it cannot find. That failure is invisible until the *next* boot,
  which is why the verification command below uses a wildcard rather than a
  hand-typed name list.
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
and the three are attempted independently, so one failing does not stop the
others from being registered; `Register-ScheduledTasks.ps1` reports honestly
which task(s), if any, failed and exits non-zero rather than always claiming
"All three tasks registered." Verify afterward with the wildcard the script's
own success message recommends - a name list is the thing that lets a silently
absent task read as a clean bill of health:

```powershell
Get-ScheduledTask -TaskName 'TopazAutoStop-*'              # expect all THREE
Get-ScheduledTaskInfo -TaskName 'TopazAutoStop-Watchdog'   # last-run details
```

## Limitation: a watchdog restart mid-render loses in-memory state

`$script:KnownWorkers` (orphan-worker tracking), `$script:UploadTracking` (the
incremental-upload table) and the loop variables `$sawActivity` / `$activeSec` /
`$idleSec` / `$stallSec` / `$lastBytes` / `$lastIoBytes` live only in the running
`Watchdog.ps1` process - deliberately **not** persisted to disk. If the watchdog
process itself is restarted mid-render (e.g. by the `RestartCount 3` policy
above, after a crash), it comes back up with a clean slate: it no longer knows an
orphaned worker was previously adopted, and it has forgotten whether it has ever
seen an active render this session.

The sharpest edge of that is a restart *after* the queue has already drained: the
fresh process starts with `sawActivity = $false` and finds no worker to arm it,
so it can never reach `completed` again and the box simply runs on, logging
"Topaz GUI up but no render has started yet". That is why the stop hand-off is
wrapped so that nothing - a `Stop-Sequence.ps1` throw included - can end this
process where re-arming would do (see "The three pre-stop refusals" above). Persisting that state across a stop/start
cycle was considered and rejected - stale state surviving a restart would risk a
false stop (e.g. replaying a stale `sawActivity = $true` straight into a fresh
pre-render lull). The trade-off is deliberate: on a deployment that arms it,
the out-of-band CloudWatch GPU-idle alarm ([Phase 4](06-phase4-safety-net.md))
would be exactly the backstop for this case, since it does not depend on any
in-guest process's memory. This project runs with that alarm deliberately
unarmed (see
[docs/09 §5](09-appendix-b-boundaries.md#5-no-idle-alarm-no-timed-stop-the-watchdog-is-the-only-thing-that-will-ever-stop-this-box)),
so a watchdog restart that loses state is, here, backstopped only by the
15-minute self-healing sweep above and the restart-on-failure policy, not by
any out-of-band layer.

## Logs

Every component writes a timestamped line to both the console and a per-component
log under `C:\topaz-autostop\logs` (`watchdog.log`, `stop.log`, `metric.log`,
`install.log`, `register.log`). Each log rotates once it exceeds 5MB: the live
file is moved to a single `<component>.log.1` backup (replacing any previous one)
rather than growing unbounded for the life of the instance. Logging never throws
in a way that could take down the pipeline. Watch `watchdog.log` during your
first `DryRun` jobs to confirm the completion/stall decisions look right.

Continue to [Phase 3 - the stop sequence](05-phase3-stop-sequence.md).
