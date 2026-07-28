# 16 - Fourth End-to-End Cycle: The Render-Loss Incident (2026-07-28)

[README](../README.md) - [Architecture](01-architecture.md) - [Phase 0](02-phase0-confirmations.md) - [Phase 1](03-phase1-instance-prep.md) - [Phase 2](04-phase2-watchdog.md) - [Phase 3](05-phase3-stop-sequence.md) - [Phase 4](06-phase4-safety-net.md) - [Phase 5](07-phase5-notifications.md) - [Appendix A](08-appendix-a-corrections.md) - [Appendix B](09-appendix-b-boundaries.md) - [Testing & CI](10-testing-and-ci.md) - [Deploying on this instance](11-deploying-on-this-instance.md) - [Empirical Findings](12-empirical-findings.md) - [First End-to-End Run](13-first-end-to-end-run.md) - [Second End-to-End Run](14-second-end-to-end-run.md) - [Third End-to-End Run](15-third-end-to-end-run.md) - **Fourth Cycle: Render-Loss Incident**

## Method and provenance

This is a **read-only forensic reconstruction**, written the same way as
[docs/13](13-first-end-to-end-run.md)-[15](15-third-end-to-end-run.md). Nothing was started,
stopped, killed, or modified to produce it. Every fact below is a direct quote or direct read
of: the Topaz session log
`C:\Users\Administrator\AppData\Roaming\Topaz Labs LLC\Topaz Video\logs\2026-07-28-06-39-38-Main.tzlog`,
`C:\topaz-autostop\logs\{watchdog,stop,scratch,rclone}.log`, and a read-only directory listing
of `D:\` / `D:\Renders` taken while writing this document. Every quote below was read directly
from its source file for this document, with the exact line number cited, not carried over
from an earlier draft unchecked.

**§I was added in a later pass**, over `in-guest/Config.ps1` as it stood in the working tree at
that time, plus a second, independent read-only directory listing of `D:\` / `D:\Renders` taken
at that time (below the original one used for §F-G) - both cited inline where used.

**Unlike docs/13-15, this is not a success story.** The prior three documents each confirmed an
end-to-end cycle worked, in progressively more detail. This one records the first cycle in this
series where the pipeline's own stop decision was correct on its own narrow terms - the render
queue really had drained, the file-unlock gate really found nothing locked - and still resulted
in the **permanent loss of a finished, ~2.3 GB render** to the ephemeral-volume wipe that
follows every stop. The defect is not in whether the watchdog detected completion correctly (it
did); it is in what `Stop-Sequence.ps1` concluded from an **empty** `OutputDir` immediately
afterward.

---

## A. Two exports queued, both explicitly configured to write into `D:\Renders`

Both exports of `D:/SDR_Render_video3.mov` were queued by the operator within a minute of each
other, and **both** carry an explicit, custom `cleanupPass` output path under `D:/Renders/` -
this was not left to a default:

- **`slp-2.5`**, queued `06-41-15.755` (line 759, `"export_source":"export_as"`):
  `cleanupPass` ends `... -fps_mode passthrough D:/Renders/SDR_Render_video3_slp.mov`.
- **`pnat-1`**, queued `06-42-06.589` (line 832, `"export_source":"export_as"`):
  `cleanupPass` ends `... -fps_mode passthrough D:/Renders/SDR_Render_video3_pnat1.mov`.

`"export_source":"export_as"` on both is the operator's own manual **Export As...** action, the
same GUI-driven trigger every prior document in this series analyzed. Neither queue item was
started via any automation this project provides - there is no CLI invocation anywhere in this
log, consistent with the license posture in [Appendix B](09-appendix-b-boundaries.md).

## B. `pnat-1`: outright failure, never retried

`pnat-1` runs as a single `ffmpeg` invocation (a `tvai_up` filter-graph call, not the
`neuroserver` + mux two-stage pattern `slp-2.5` uses below):

- **Started** `07-05-04.997` as process `32` (line 2866), writing
  `D:/SDR_Render_video3_787877699.mov` - note this is **not** yet the `cleanupPass` output; it
  is the raw intermediate the (never-reached) mux stage would have read from. This start comes
  immediately after the first project reload triggered by `slp-2.5`'s own first crash (§C) -
  the queue is processed sequentially, so `pnat-1`, though queued at `06-42-06.589`, does not
  actually begin running until `slp-2.5`'s first attempt has already failed and reloaded.
- **Died** `07-13-03.742`: `process exited error occurred: 32 1` (line 3787) - see the timing
  note in §C: this happened well under a second before `slp-2.5`'s own second attempt also
  died.

A search of the entire session log for every `"models":["pnat-1"]` `Video Export Started` event
returns exactly the one queued at `06-42-06.589` (line 832) - **no second occurrence, anywhere,
for the rest of the session.** Unlike `slp-2.5` below, `pnat-1` was never reloaded, never
resumed, and its `cleanupPass` (which would have written
`D:/Renders/SDR_Render_video3_pnat1.mov`) never ran, because the raw intermediate it depends on
never finished. The raw partial file `D:/SDR_Render_video3_787877699.mov` was left on `D:` with
no cleanup logged anywhere in this session. **This queue item simply vanished from the queue on
its first and only failure - no retry was ever attempted**, in direct contrast to `slp-2.5`.

## C. `slp-2.5`: crash, a reload-driven retry that silently lost its own output folder, a second crash, then success

- **Attempt 1** - `neuroserver` process `31` started `06-41-15.808` (line 766, `--start-frame-idx
  0 --end-frame-idx 631`). **Died** `07-03-08.910`: `process exited error occurred: 31 1` (line
  2743), at frame 174 of 631 (~27%).
- **`07-05-04.542`** (line 2776): `Loading project: C:\Users\Administrator\Documents/Topaz Video
  Projects/Default/project.tvai` - Topaz reloads the whole project from disk after the crash.
- **Attempt 2**, queued `07-05-05.571` (line 2883) as a **new** `Video Export Started` event -
  and this is where the divergence is introduced, on the very first retry, before any further
  crash: `"ux_track":{"export_source":"quick"}` (not `"export_as"`), resuming at
  `--start-frame-idx 148 --end-frame-idx 632`, and its `cleanupPass` already reads
  `... -fps_mode passthrough D:/SDR_Render_video3_slp.mov` - **the `Renders/` prefix is already
  gone**, three log lines after the reload. Runs as `neuroserver` process `34` (line 2890),
  started `07-05-05.596` - only **599 ms** after `pnat-1`'s process `32` started (§B). The two
  queue items ran concurrently as worker processes from this point on.
- **A notable, unexplained synchronicity, with a GUI-side corroborating detail.** `pnat-1`'s
  process `32` died at `07-13-03.742` (line 3787); a project reload began at `07-13-04.314`
  (line 3792); and `slp-2.5` attempt 2's process `34` then logged its own `process exited error
  occurred: 34 1` at `07-13-04.594` (line 3830) - **852 ms after `pnat-1`'s crash, and while the
  reload triggered by that crash was already loading.** Both processes had been running for
  almost exactly the same ~8-minute stretch (started 599 ms apart, per the point above) and both
  failed within under a second of each other. Moments before either exit code was logged, at
  `07-13-03.013`, the GUI's own export-item panel logged QML thumbnail-provider failures naming
  **both** items by their process ids in immediate succession - `"Failed to get image from
  provider: image://thumbnail/32"` and, five lines later, `"...image://thumbnail/34"` - i.e. the
  GUI itself was refreshing/tearing down both export items' UI state at essentially the same
  moment, not just their two independent worker processes coincidentally dying together. This
  points at a shared, GUI-level event rather than two unrelated worker crashes, but the log does
  not say what that event was (no `nvidia-smi`/CUDA error, out-of-memory message, or disk-space
  warning appears anywhere in this window) - so this document records the correlation and its
  one piece of corroborating evidence plainly, rather than asserting a mechanism the log does
  not show.
- **`07-13-04.314`** (line 3792, quoted above): the second `Loading project` reload of this
  session - the one that happens to sit temporally between the two near-simultaneous crashes
  above.
- **Attempt 3**, queued `07-13-05.371` (line 3898), again `"export_source":"quick"`, again
  resuming at frame 148, again with `cleanupPass` reading `D:/SDR_Render_video3_slp.mov` (no
  `Renders/`). Runs as `neuroserver` process `36` (line 3905). **This attempt succeeds**:
  `process exited: 36 0 0` at `08-10-53.156` (line 9673).
- **The mux**, `08-11-00.002` (line 9682), reusing process id `36` for a distinct `ffmpeg`
  invocation (Topaz recycles small integer process ids per queue stage within a session - this
  id is not globally unique):
  ```
  ffmpeg -hide_banner -nostdin -y
    -i C:/Users/Administrator/Documents/Topaz Video Projects/Default/previews/SDR_Render_video3_809344611.mov
    -i D:/SDR_Render_video3.mov
    -strict experimental -c:v copy -map 0:v -map 1:a:0 -map_metadata:s:a:0 1:s:a:0 -c:a copy
    -map_metadata 0 -movflags use_metadata_tags -fps_mode passthrough
    D:/SDR_Render_video3_slp.mov
  ```
  Its first input is a **preview file on `C:`**, produced `08-10-58.461` by an internal `concat`
  (line 9676, `"concat took 5295 ms."`) that stitched attempt 1's partial segment together with
  attempt 3's completed one (line 9679, `"36 Preview file
  C:/Users/.../previews/SDR_Render_video3_809344611.mov found"`) - a genuine intermediate
  artifact briefly touched `C:`, not just `D:`, though it did not survive (deleted at
  `08-11-01.413`, lines 9751-9752, immediately after the mux read it). Its output is,
  **explicitly, `D:/SDR_Render_video3_slp.mov` - the root of `D:`, not `D:/Renders/`.**
  **Exited cleanly**: `process exited: 36 0 0` at `08-11-01.412` (line 9750), reporting
  `frame= 632 fps=522 ... Lsize= 2257275KiB ... elapsed=0:00:01.20` - `2257275 KiB x 1024 =
  2,311,449,600 bytes` (**~2.31 GB / 2.15 GiB**), 632 frames. Topaz then deleted both raw `D:`
  intermediates (`SDR_Render_video3_491360453.mov` and `SDR_Render_video3_303746912.mov`, lines
  9677-9678/9683-9685) and the `C:` preview file - but **not** the final `D:\` output, which is
  the real, correctly-muxed, finished deliverable this incident is about.

**This was Topaz's own internal crash-recovery behavior, not anything this project's code
touched.** Nothing in this pipeline invokes the Topaz CLI or drives its GUI (see
[Appendix B](09-appendix-b-boundaries.md)); the `export_source` field switching from
`"export_as"` to `"quick"` at the exact moment of each `Loading project` reload is visible
entirely within Topaz's own log, and the loss of the custom output directory tracks that
switch exactly.

## D. Watchdog: correctly tracked a real, sustained render through both crash/retry cycles

`watchdog.log` shows continuous worker activity from the first arm through the eventual idle,
correctly riding out both crashes and reloads above (each `neuroserver` restart is matched by
the same ancestry-based `WorkerNamesLike` pattern, so a new PID after a crash is still counted):

```
[2026-07-28 06:43:14.874 +00:00] [INFO] Render active (worker=True gpu=n/a, armed) but NO progress on either signal (stall=15s / 1800s, outputBytes=0, workerIoBytes=192861291).
   ... climbing workerIoBytes on every heartbeat, through both crash/reload cycles ...
[2026-07-28 08:05:54.390 +00:00] [INFO] Render progressing (worker=True gpu=n/a, armed): active=3585s, outputBytes=0, workerIoBytes=24491246748. Heartbeat every 300s while healthy.
[2026-07-28 08:10:57.097 +00:00] [INFO] No active render (idle=15s / 300s debounce, worker=False gpu=n/a).
   ... 18 further polls, +15s each, no gaps ...
[2026-07-28 08:15:44.392 +00:00] [INFO] No active render (idle=300s / 300s debounce, worker=False gpu=n/a).
[2026-07-28 08:15:44.396 +00:00] [INFO] No active render for 300s (>= debounce). Render QUEUE considered COMPLETE.
[2026-07-28 08:15:44.402 +00:00] [INFO] Reason='completed'. Waiting up to 5 min for output files to unlock.
[2026-07-28 08:15:44.410 +00:00] [INFO] All output files are unlocked.
[2026-07-28 08:15:44.534 +00:00] [INFO] Invoking Stop-Sequence.ps1 (reason=completed).
```

`outputBytes=0` on every line above is expected and, on its own, benign - the same NTFS
open-handle behavior [docs/12](12-empirical-findings.md) measured directly. The unlock gate
passing in **8 ms** (`08:15:44.402` -> `08:15:44.410`) is not, in hindsight, a sign of health: it
passed instantly because `Watchdog.ps1`'s unlock scan is scoped to `$cfg.OutputDir`
(`D:\Renders`), and `D:\Renders` held **nothing at all** to check the lock state of - the one
real output sat one directory level above it, structurally invisible to this scan regardless of
timing. The watchdog's own decision - "the queue drained, and nothing in the folder I watch is
locked" - was a correct read of what it was told to look at. The queue really had drained; the
render really had finished; **the defect is entirely in what happens next.**

## E. `Stop-Sequence.ps1`: "OutputDir is empty; nothing to upload. Safe to proceed."

`stop.log`, in full, for this cycle:

```
[2026-07-28 08:15:44.616 +00:00] [INFO] Stop sequence invoked (reason=completed, dryRun=False).
[2026-07-28 08:15:44.680 +00:00] [INFO] No S3SyncTarget configured; skipping artifact sync.
[2026-07-28 08:15:44.693 +00:00] [INFO] OutputDir 'D:\Renders' is empty; nothing to upload. Safe to proceed.
[2026-07-28 08:15:44.701 +00:00] [INFO] No SnsTopicArn configured; skipping notification.
[2026-07-28 08:15:44.709 +00:00] [INFO] Stopping now (reason=completed). StopStrategy='Auto', plan=[Ec2ApiStop -> GuestShutdown].
[2026-07-28 08:15:46.376 +00:00] [INFO] ec2:StopInstances accepted for i-029f35d589bec9b9c. The instance should transition to 'stopping' shortly.
[2026-07-28 08:15:46.385 +00:00] [INFO] Waiting up to 300s for the instance to actually go down.
```

`rclone.log`'s own record independently corroborates that **no upload ran at all on
2026-07-28** - its last write of any kind is `2026/07/27 14:56:30` (the successful upload
from [docs/15](15-third-end-to-end-run.md)), with zero entries afterward.

**This code path already has the right instinct for a related case - it just does not
recognize this one.** One day earlier, `stop.log` recorded a genuine upload *failure* against a
**non-empty** `OutputDir`, and refused to stop:

```
[2026-07-27 07:04:02] [ERROR] rclone config not found at 'C:\topaz-autostop\rclone.conf'. The Google Drive remote has not been authorised -- run Set-GoogleDriveAuth.ps1. Cannot upload.
[2026-07-27 07:04:02] [ERROR] UPLOAD FAILED and OutputDir 'D:\Renders' is on EPHEMERAL storage. Stopping now would PERMANENTLY DESTROY the renders in it. REFUSING TO STOP -- the instance stays up so the render can still be recovered.
[2026-07-27 07:04:02] [ERROR] Recover with:  & 'C:\Program Files\rclone\rclone.exe' --config 'C:\topaz-autostop\rclone.conf' copy 'D:\Renders' 'gdrive:temp' -P   then re-run this script.
```

That is exactly the right behavior: files present, upload failed, refuse to stop. But
`Invoke-TopazRenderUpload`'s **empty**-directory branch is a completely different, unguarded
code path - it treats "zero files present" as unconditionally safe, with no check against the
fact that `Reason='completed'` only ever fires after the watchdog has observed sustained real
worker activity (confirmed armed at `06:43:14.874`, well past the 90 s `ArmSec` threshold, and
still active roughly 87 minutes later at `08:10:57.097` when idle was first detected, through
two crash/reload cycles). **"A real render was observed
to completion" and "its designated output folder is empty" is a contradiction this branch never
checks for.** An empty `OutputDir` following a genuinely-armed completion is not evidence there
is nothing to upload; on this box, on this cycle, it was evidence the output landed somewhere
else entirely.

## F. The ephemeral wipe and the loss

`D:` is instance-store / ephemeral (`Config.ps1`'s `OutputIsEphemeral = $true`), the same
volume type docs/13-15 already documented as being fully re-provisioned on every stop/start
cycle. `scratch.log` shows this directly for this cycle:

```
[2026-07-28 05:59:10.263 +00:00] [INFO] Selected Disk 1 (419.1 GiB, serial=E8E8_5EB2_96BF_2A3F_0100_0000_00CD_B440.) as the instance-store scratch disk.
[2026-07-28 05:59:13.846 +00:00] [INFO] Scratch drive ready: D: 'RenderScratch' 419.1 GiB, output directory 'D:\Renders' created (only this directory is uploaded).
[2026-07-28 08:25:30.193 +00:00] [INFO] Selected Disk 1 (419.1 GiB, serial=49D8_6583_2CE8_3034_0100_0000_00CD_B440.) as the instance-store scratch disk.
[2026-07-28 08:25:33.815 +00:00] [INFO] Scratch drive ready: D: 'RenderScratch' 419.1 GiB, output directory 'D:\Renders' created (only this directory is uploaded).
```

The disk serial number changed (`...96BF_2A3F` -> `...2CE8_3034`) between the stop
(`08:15:46.376`) and the next boot's re-provisioning (`08:25:30.193`) - physical-layer proof of
a freshly-issued instance-store device, the same evidence pattern [docs/15 §J](15-third-end-to-end-run.md)
used to confirm a wipe, not a relabel. A read-only directory listing taken while writing this
document confirms the result: `D:\Renders` is empty, and `D:\` itself no longer holds
`SDR_Render_video3_slp.mov` at all - only a freshly re-fetched copy of the original source
(`SDR_Render_video3.mov`, 1,616,764,730 bytes) and a new, already-in-progress render output
growing in real time (`SDR_Render_video3_709239916.mov`, 2,080,899,072 bytes and climbing as of
this writing - see §G).

**The ~2.31 GB `slp-2.5` output confirmed muxed and exited cleanly at `08-11-01.412` (§C) is
permanently gone.** It is the only file this session actually finished; `pnat-1` (§B) never
produced one at all.

## G. Current status: the operator is already redoing the render

A read-only directory listing of `D:\` taken for this document shows exactly two files besides
the empty `D:\Renders`: the re-fetched source `SDR_Render_video3.mov` (1,616,764,730 bytes,
matching the size this project's earlier, already-completed read-only `rclone lsjson` check
recorded against `gdrive:temp` - the source remains available and the work is redoable) and a
new output file already growing at the time of writing. This document does not further
characterize that in-progress render - it is out of scope for a record of the 2026-07-28
incident - beyond noting that the operator has already begun the redo implied by "recover" in
the decision recorded below.

## H. The decision taken in response: recover-and-stop, explicitly NOT a refusal

**The operator's explicit decision, recorded here rather than left implicit:** redo the render
and keep using this pipeline exactly as it stands, with both error classes from this incident
logged for the record (this document is that record) rather than treated as grounds to halt or
gate the automation:

- **Error class 1 (`pnat-1`, §B):** a queue item can fail once and vanish from the queue
  permanently, with no retry attempt logged anywhere, and no output of any kind.
- **Error class 2 (`slp-2.5`, §C):** a queue item can crash, be silently resumed by Topaz's own
  internal recovery path under a different `export_source`, lose its own operator-configured
  output directory in the process, and still ultimately **succeed** - producing a real,
  correctly-encoded, completed file that this project's own stop logic then failed to recognize
  as needing to be uploaded before the instance stopped.

**This is explicitly not a decision to refuse further automated runs, add a manual gate, or
disable auto-stop pending a fix.** The operator chose to continue relying on
watchdog-completion -> verified-upload -> `ec2:StopInstances` as the sole sanctioned auto-stop
(the same decision recorded in [docs/09 §5](09-appendix-b-boundaries.md#5-no-idle-alarm-no-timed-stop-the-watchdog-is-the-only-thing-that-will-ever-stop-this-box),
made the same day), and directed that the specific defect identified in §E - an empty
`OutputDir` following a completed queue being treated as unconditionally safe - be closed by
**recovering and still stopping**, not by refusing to stop. That remediation landed in
`in-guest/Config.ps1` the same day (see §I immediately below) - this is not the "left open,
unfixed, out of scope" situation an earlier draft of this document described here. §I also
records that the first pass of that remediation shipped with two gaps of its own, and that both
were closed the same day once found.

## I. Remediation landed the same day, including a same-day correction once a live counter-example exposed the first pass's own gap

Concrete changes landed in `in-guest/Config.ps1`, the same day as this incident, while the redo
described in §G was still under way (it still is - see the live counter-example below, which is
what drove the correction described after it):

- **`Resolve-OutputAnomalyClass`** (pure; shipped that day as `Resolve-EmptyOutputDirDecision`,
  then renamed the same day - see CORRECTION 1 below) classifies the render-output situation at
  stop time. For `Reason='stalled'` or `'maxlifetime'` it is unchanged, `'NotApplicable'`
  behaviour. For `Reason='completed'` - which only ever fires after `ArmSec` of continuously
  confirmed worker activity (§D above), so an empty `OutputDir` at that point is exactly the
  contradiction §E describes - it returns `'ErrorClassA'` (a candidate render file was found
  elsewhere on the `OutputDir` volume) or `'ErrorClassB'` (nothing was found anywhere; the render
  produced no output at all, the `pnat-1` shape from §B).
- **`Find-RenderRecoveryCandidates`** performs the bounded scan that decides which class applies:
  extension-matched (`RenderFileExtensions`), depth/count/time-capped
  (`RecoveryScanMaxDepth`/`RecoveryScanMaxFiles`/`RecoveryScanTimeoutSec`), and - the part added
  specifically because source footage and abandoned partials legitimately share the volume root
  with a real deliverable (see §F-§G) - recency-bounded: only files modified within
  `RecoveryMaxAgeMin` (default **60** minutes) count as recovery candidates; everything
  matched-but-older goes into a separately-logged `ExcludedByAge` list rather than silently
  vanishing or silently counting.
- **`Invoke-TopazForensicCapture`** copies the newest Topaz `*.tzlog`'s `process exited`/`error
  occurred` lines into `stop.log`, best-effort and time-bounded (`TopazForensicTimeoutSec`,
  default **10 s**). This is the piece that would have put §B/§C's crash-and-retry signature into
  **this pipeline's own logs** at the time, instead of only into a Topaz session log that
  happened to still be sitting on `C:` (a persistent volume) when this document was written.
- **`Invoke-TopazRecoveryUpload`** attempts a best-effort `rclone copy` + `rclone check` of
  exactly the discovered candidate(s) to `<UploadTarget>/recovered`, reusing the same one-retry
  policy (`Resolve-UploadRetryDecision`) as the normal upload path, and logs an explicit per-file
  `RECOVERY DISPOSITION` line (`uploaded+verified` / `uploaded-but-unverified` / `NOT
  RECOVERED`).
- Per the operator's own explicit instruction - *"if human error and render lands in wrong
  folder, im fine with it shutting down but try best effort to find it first and complete the
  upload"* - none of this ever refuses the stop. `Invoke-TopazOutputAnomalyHandling` (see
  CORRECTION 1 below for the rename) always returns `$true`. The box stops either way; only the
  *log* is required to be unambiguous about which of the two classes occurred.

**A live counter-example, read directly off this box while writing this section (read-only,
same method as the rest of this document), exposed a real gap in the first pass of this
remediation - closed the same day, before it could bite a second time:**

```
D:\Renders\SDR_Render_video3_pnat1.mov     2,311,449,636 bytes   (this redo's pnat-1, correctly
                                                                   finished AND correctly placed)
D:\SDR_Render_video3_227249191.mov         1,150,550,016 bytes   (live raw intermediate for the
                                                                   second, currently-running
                                                                   export of this same redo)
D:\SDR_Render_video3.mov                   1,616,764,730 bytes   (the source footage, unchanged)
```

As first shipped that day, the scan above was wired into `Invoke-TopazRenderUpload`'s branch on
`OutputDir` being **empty** - `Resolve-EmptyOutputDirDecision` (as it was named at that point) was
only ever consulted when `Get-ChildItem $OutputDir` returned zero files. On this box, at the
moment this was written, `OutputDir` was **not** empty - it held `SDR_Render_video3_pnat1.mov`.
Had the second export's own mux repeated exactly §C's defect (dropping the `Renders\` prefix from
its `cleanupPass` path), its finished deliverable would have landed beside the growing
intermediate at `D:\` root **while `OutputDir` simultaneously held a different, correctly-placed
file**. `Invoke-TopazRenderUpload`'s `$files.Count -eq 0` branch would then have been `false`, the
entire misplaced-output scan would never have run, the normal path would have uploaded only
`pnat-1`'s file, and the stop would have proceeded - destroying the second export exactly as §E-§F
describe, with every function listed above sitting unused in the very stop that needed them.

**CORRECTION 1, landed the same day this gap was found:** the check must run **whether or not
`OutputDir` has content** - "is `OutputDir` empty" was the wrong question; the right one is "do
recent, complete render files exist on the ephemeral volume outside `OutputDir` that this stop is
about to erase." `Invoke-TopazRenderUpload` now calls the misplaced-output handling
unconditionally on every `Reason='completed'` stop, not from an empty-directory branch, and
`Resolve-OutputAnomalyClass`'s `CandidatesFound` and `OutputDirHasFiles` are independent inputs
rather than one implied by the other - `ErrorClassA` fires whenever a recent candidate is found
elsewhere, regardless of what `OutputDir` itself holds. The two renames threaded through this
correction: `Resolve-EmptyOutputDirDecision` -> `Resolve-OutputAnomalyClass`, and
`Invoke-TopazEmptyOutputDirHandling` -> `Invoke-TopazOutputAnomalyHandling`. See
[Phase 3 §4](05-phase3-stop-sequence.md) for the shipped behaviour in full.

**A second, independent defect surfaced while reviewing this same remediation, and was closed the
same day alongside CORRECTION 1.** `Find-RenderRecoveryCandidates` declares `-ModifiedAfter` as a
`Mandatory` parameter (the recency bound described above); its only caller now passes it, computed
as `(Get-Date).AddMinutes(-$cfg.RecoveryMaxAgeMin)`. Before that fix, ANY `Reason='completed'` stop
that reached the recovery scan would have failed on a missing-mandatory-parameter error inside the
scan itself, before either error class was ever logged - which would have been more acute than the
trigger-scope gap above, since it meant the remediation code could not have completed a single run
as first written. Both gaps are recorded here for the same reason the rest of this document
exists - found by a deliberate reading of the code, not rediscovered by losing a third render -
and both are now closed in `in-guest/Config.ps1`, verified against the current working tree while
correcting this document.

**The root cause behind all of this: Topaz's own crash-recovery path is what drops the output
folder, and it will keep doing it.** §C already showed the mechanism - `export_source` flips from
`"export_as"` to `"quick"` at each `Loading project` reload, and the resumed export's `cleanupPass`
no longer carries the operator-chosen `D:/Renders/` prefix. That makes a misplaced output a
**predictable** consequence of any worker crash on this box, not a rare, random event: every
crash-and-retry Topaz performs internally is a fresh chance for the next deliverable to land at
the volume root instead of `OutputDir`. This is also why the scan in
[Phase 3 §4](05-phase3-stop-sequence.md) has to run unconditionally rather than only when
`OutputDir` is empty - a crash can just as easily happen on the *second* export of a session as the
first, landing its output beside an already-correct first file.

**Scope note.** §I above records what has actually landed in `in-guest/Config.ps1` for §E's
defect - both gaps it originally reported open are now closed there, verified against the current
working tree, not merely asserted. This document's own ownership is still `control-plane/**`,
`docs/**`, and `README.md` only; the in-guest changes themselves are `in-guest/Config.ps1`'s and
`in-guest/Watchdog.ps1`'s to make, and this section only records that they landed. The point of
recording the original gaps here, and now their closure, is the same as the point of the rest of
this document: so a real gap is found by someone deliberately reading the code and the incident
together, not silently rediscovered by losing a third render, misattributed to the wrong layer
(this was never an idle-alarm or control-plane problem), or blamed on the watchdog (which read its
own inputs correctly throughout, per §D).

## Verdict

**Two independent failures in one session, one output permanently lost, and a code path that
did the wrong thing for a reason that is easy to state precisely.** `pnat-1` failed once and was
silently dropped with no retry and no output (§B). `slp-2.5` crashed twice, was resumed both
times by Topaz's own internal recovery path, lost its own configured `D:/Renders/` output
directory on the very first resume (visible in the `export_source` field switching from
`"export_as"` to `"quick"` at each reload), and nonetheless finished cleanly on the third attempt
- muxing a real, correct, ~2.31 GB deliverable to `D:\` root instead of `D:\Renders\` (§C). The
watchdog observed all of this correctly: real, sustained worker activity throughout, a genuine
queue drain, and an honestly-empty `OutputDir` with nothing to unlock (§D). `Stop-Sequence.ps1`
then treated that empty directory as unconditionally safe - a check that already refuses to
stop on a *failed* upload against a non-empty directory (§E, contrasted directly against
2026-07-27's correct refusal) but has no equivalent check for "the queue says it finished and
the folder is empty anyway." The instance stopped, the ephemeral scratch volume was wiped and
re-provisioned on the next boot exactly as designed for ephemeral storage (§F), and the render
was gone. The operator's decision, recorded here: redo the render, log both error classes
plainly (this document), and keep using the pipeline as-is - explicitly not a refusal to
automate further (§H). Unlike an earlier draft of this document, the underlying defect was not
left open by choice: real remediation landed the same day (§I) - a misplaced-output scan, Topaz
forensic capture, and a best-effort recovery upload, all logging plainly and never refusing to
stop. §I also records that the first pass of that remediation, as first written, had two gaps of
its own - the scan was still scoped to `OutputDir` being found empty rather than running
unconditionally, so a second misplaced render sitting beside a first, correctly-placed one (the
exact shape of the live counter-example recorded in §I) would still have been missed, and a
missing `-ModifiedAfter` argument would have stopped the recovery scan from completing a single
run at all - and that **both were closed the same day**, verified against the current working
tree while correcting this document: the scan now runs on every `Reason='completed'` stop
regardless of `OutputDir`'s own contents, and `-ModifiedAfter` is passed on every call. §I also
now records the root cause behind the whole incident: Topaz's own crash-recovery path silently
drops the operator's chosen output folder on every crash-and-retry (visible in `export_source`
flipping from `"export_as"` to `"quick"`), which is what makes a misplaced output a predictable,
recurring risk on this box rather than a one-off. Separately, the incremental per-render upload
this project's remediation also added (Phase 2/3, CORRECTION 3) carries a narrower version of the
same shape of gap, recorded in those documents rather than here: its "unlocked + size-stable"
eligibility rule cannot distinguish a genuinely finished file from one left behind mid-crash, so a
partial can still be uploaded and self-verified before the resumed writer supplies the correct
content. As shipped that day, "already uploaded" was keyed on the file's path alone, so that
partial was never revisited by the incremental path again for the rest of the watchdog process's
life, and only this document's own §3/§4 final sweep - potentially hours later on a multi-export
queue - would correct Drive. That was subsequently fixed the same day (FINDING 2 of the 2026-07-28
adversarial review; see [Phase 2](04-phase2-watchdog.md)): identity is now the size and write-time
actually uploaded, not the bare path, so the resumed writer's overwrite makes the path eligible
again and it is re-uploaded - logged at WARN, greppable as `SUPERSEDED` - the very next poll its
real content restabilizes. Not a data-loss risk either way, since this document's own §3/§4 final
sweep still corrects Drive before the box stops regardless, but now a much shorter window in which
Drive can hold a stale file the log had called "verified."

---

Back to the [README](../README.md).
