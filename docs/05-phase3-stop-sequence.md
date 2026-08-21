# 05 - Phase 3: The stop sequence

[README](../README.md) - [Architecture](01-architecture.md) - [Phase 0](02-phase0-confirmations.md) - [Phase 1](03-phase1-instance-prep.md) - [Phase 2](04-phase2-watchdog.md) - **Phase 3** - [Phase 4](06-phase4-safety-net.md) - [Phase 5](07-phase5-notifications.md)

[`Stop-Sequence.ps1`](../in-guest/Stop-Sequence.ps1) is invoked by the watchdog
once the render queue is complete or stalled, with `-Reason completed` or
`-Reason stalled`. It runs the optional best-effort artifact/notification steps
and then powers the guest off.

## The stop follows an ordered plan: API first, guest shutdown as fallback

The actual stop is not a single fixed action - `Stop-Sequence.ps1` follows the
configured `StopStrategy` (`Config.ps1`; `Resolve-StopPlan` is the pure
function that turns it into an ordered action list):

- **`Ec2ApiStop`** - call `ec2:StopInstances` against this instance. The
  **only** action that *provably* ends billing.
- **`GuestShutdown`** - `Stop-Computer -Force`, equivalent to
  `shutdown /s /t 0`. Needs **no `ec2:StopInstances` call and no AWS
  credential** - it stops the box simply by turning its own OS off, and it
  **stops** (rather than terminates) the EC2 instance only because
  `InstanceInitiatedShutdownBehavior=stop` was set in
  [Phase 1](03-phase1-instance-prep.md).
- **`'Auto'`** (the default) - tries `Ec2ApiStop` first and, if that call is
  denied or does not take effect within `StopVerifySec` (default **300 s**),
  falls back to `GuestShutdown`.

  > `StopVerifySec` was **90 s** until 2026-07-27, and this document said so
  > for a while after it changed. 90 s was measured to be too short: the
  > 03:00:31 cycle logged `Still running 90s after an accepted
  > ec2:StopInstances` and escalated to a guest shutdown that was never
  > needed, because AWS's graceful-shutdown window simply had not finished.
  > For contrast, the run in
  > [docs/15](15-third-end-to-end-run.md) went down **7.99 s** after the API
  > call was accepted - the 300 s budget is generous precisely so that a
  > normal, slightly slow stop never escalates.

**Why the API leg goes first.** A guest shutdown only ends billing when
`InstanceInitiatedShutdownBehavior` happens to be `stop` - a fact this box
cannot verify about itself without an extra permission
(`ec2:DescribeInstanceAttribute`). Ordering the credential-free-but-unverified
action first would, on a box where that attribute is `terminate` (or the
guest shutdown simply does not stop the instance for some other reason),
either destroy the box or quietly keep billing it. Trying the action that is
provably correct first, and degrading to the best-effort one, is the safer
direction - this is the central design property of the whole pipeline (see
[Architecture](01-architecture.md), which also explains the credential
trade-off this addition made explicit).

## Order of operations

```
1. (best-effort) IMDSv2 lookup of this instance's id + region -- id prettifies
                 notifications; region is REQUIRED by steps 2 and 4 below
2. (optional)    aws s3 sync OutputDir -> S3SyncTarget --region <region> -- BEFORE power off
3. rclone upload OutputDir -> UploadTarget (Google Drive), verified by an independent
                 `rclone check` -- THE EPHEMERAL INTERLOCK: on ephemeral storage a failure
                 here (after one retry) REFUSES the stop. An OutputDir found EMPTY at this
                 step is no longer unconditionally safe -- see "The misplaced-output scan"
                 below.
4. (optional)    aws sns publish "render complete/stalled" --region <region>
5. DryRun?  -> log the decision and RETURN (no power off; Watchdog.ps1 re-arms)
6. else     -> follow the StopStrategy plan in order (default 'Auto':
                ec2:StopInstances, then Stop-Computer -Force) until one
                action succeeds or the plan is exhausted
```

### 1. Best-effort instance id + region (IMDSv2)

The script fetches the instance id **and region** via IMDSv2 (one token, two
metadata calls, via the shared `Get-Ec2Identity` helper in
[`Config.ps1`](../in-guest/Config.ps1)). The instance id is only to make
notifications readable and falls back to a placeholder if IMDS is unreachable.
The region is not cosmetic: the S3 sync and SNS publish calls below both pass it
explicitly as `--region`, because the **SYSTEM account has no default region
configured anywhere in this pipeline** - without an explicit `--region`, both
`aws s3 sync` and `aws sns publish` fail client-side with `NoRegionError` every
single time, silently, since it only surfaces as a WARN in a log nobody reads
until after the box is off. This lookup never blocks the stop; if region
discovery fails, the script logs a warning and still attempts both calls
without `--region` (so they may fail, but the stop itself is unaffected).

### 2. Optional S3 sync (runs BEFORE power off)

If `S3SyncTarget` is set in [`Config.ps1`](../in-guest/Config.ps1) (e.g.
`s3://my-bucket/renders/`), the script runs `aws s3 sync OutputDir S3SyncTarget
--only-show-errors --region <discovered-region>` **before** powering off, so
finished artifacts are safe even if something later goes wrong. Empty (the
default) skips the sync. A non-zero exit, a thrown error, or a hang past
`S3SyncTimeoutSec` (default **1800 s**, generous since a large sync may
genuinely need that long) is logged as a warning and **does not** block the
stop - the call is killed on timeout rather than left to wedge power-off
forever.

> S3 sync uses the AWS CLI and therefore the instance role's credentials. The
> default instance role only grants `cloudwatch:PutMetricData`; if you enable S3
> sync you must also grant the role `s3:PutObject` (and typically `s3:ListBucket`)
> on the target bucket/prefix. That grant is not part of
> [`02-create-iam-role.sh`](../control-plane/02-create-iam-role.sh) - add it yourself.

### 3. The Google Drive upload, and the ephemeral interlock

Immediately after the optional S3 sync, `Invoke-TopazRenderUpload` (in
[`Config.ps1`](../in-guest/Config.ps1)) uploads everything currently in `OutputDir` to
`UploadTarget` (default `gdrive:temp`) via `rclone copy`, then independently re-verifies the
transfer with `rclone check --one-way` - belt and braces, since `copy` already validates Drive's
returned hash but the cost of being wrong here is a lost multi-hour render. `copy`, not `move` or
`sync`, is deliberate: the scratch volume is wiped by the stop regardless, so nothing is gained by
deleting the source, and re-running this after a partial failure is cheap because rclone skips
files already present at the destination.

Both the copy and the check get **one retry** (2 attempts total via
`Resolve-UploadRetryDecision`, `UploadRetryDelaySec` default **15 s** between them) - a bare,
un-retried failure used to refuse the stop on the very first transient Drive-side blip, costing
instance uptime for something a plain retry would often clear. The whole call is bounded by
`UploadTimeoutSec` (default **14400 s / 4 h**, generous for a multi-GB transfer at the ~55-65
MiB/s measured on this deployment).

**The ephemeral interlock.** When `OutputIsEphemeral` is `$true` (the shipped default -
`OutputDir` is the instance-store scratch drive, erased on every stop) and `OutputDir` holds
files, a failure of BOTH attempts makes `Invoke-TopazRenderUpload` return `$false`, and
`Stop-Sequence.ps1` **REFUSES to stop**: it logs the exact manual recovery `rclone` command and
returns `$false` up to `Watchdog.ps1`, which re-arms and retries roughly every `DebounceSec`
(see [Phase 2](04-phase2-watchdog.md)'s `Resolve-RefusalStallSec` for why a `'stalled'` reason
retries on a different cadence than `'completed'`) instead of exiting. The box stays up - and
billing - until the upload succeeds or a human intervenes, because losing instance-uptime money
is recoverable and losing the render is not.

An `OutputDir` found **empty** - or, per CORRECTION 1 below, in any state at all - at this step
is a separate case, covered next.

### 4. The misplaced-output scan: it runs on every completed stop, not only when OutputDir is empty

Before 2026-07-28 an empty `OutputDir` at this point was treated as unconditionally safe -
"nothing to upload." That is what let a finished ~2.3 GB render, muxed by Topaz's own
crash-recovery retry to `D:\` root instead of `D:\Renders\`, get wiped along with the rest of the
ephemeral scratch volume; see [docs/16-render-loss-incident.md](16-render-loss-incident.md) for
the full forensic record.

**CORRECTION 1 (same day): the scan's trigger is `Reason='completed'` alone, not `OutputDir`
being empty.** The first remediation pass gated the scan on `OutputDir` having zero files, and a
live counter-example on this same box - caught the same day, before the gap could bite a second
time - showed why that was still wrong: `OutputDir` can legitimately hold one finished render
(e.g. `D:\Renders\SDR_Render_video3_pnat1.mov`) while a *second* export is mid-flight and about to
land misplaced at the volume root (`D:\SDR_Render_video3_227249191.mov`, growing). An
empty-`OutputDir` trigger would never fire in that shape - `OutputDir` is not empty - so the
second, misplaced render would be lost exactly like the first. The real question was never "is
`OutputDir` empty", it is "does a recent, complete render file exist OUTSIDE `OutputDir` that this
stop is about to erase", which is orthogonal to whatever `OutputDir` itself contains. The scan
therefore now runs on **every** `Reason='completed'` stop, whether `OutputDir` has files or not -
`Invoke-TopazRenderUpload` calls it unconditionally rather than only from an empty-directory
branch. `'stalled'`/`'maxlifetime'` stops still skip it entirely (see below).

"OutputDir is empty" itself stops being automatically benign because `Reason='completed'` only
ever fires after `ArmSec` of continuously confirmed worker activity (see
[Phase 2](04-phase2-watchdog.md)), so a real render is known to have run:

- **`Resolve-OutputAnomalyClass`** (pure; renamed from `Resolve-EmptyOutputDirDecision` as part of
  CORRECTION 1) labels which of two classes applies - both greppable and logged distinctly, and,
  deliberately, **neither one refuses the stop**. `OutputDirHasFiles` and `CandidatesFound` are now
  independent inputs, not one implied by the other:
  - **`ErrorClassA`** (RENDER-OUTSIDE-OUTPUTDIR) - a recent, unlocked candidate render file was
    found elsewhere on the `OutputDir` volume, **whether or not `OutputDir` itself is empty** - a
    misplaced *second* file is just as real a loss as a first one.
  - **`ErrorClassB`** (RENDER-PRODUCED-NO-OUTPUT) - `OutputDir` is empty AND nothing was found
    anywhere else either; the render produced no output at all.
  - `'stalled'`/`'maxlifetime'` reasons always classify as `'NotApplicable'` - they carry no
    "a real render definitely ran" guarantee, so the scan is skipped for them entirely (unchanged
    from before CORRECTION 1).
- **`Find-RenderRecoveryCandidates`** runs the scan behind that label: extension-matched
  (`RenderFileExtensions`), depth/count/time-bounded so a forensic aid can never itself hang or
  meaningfully delay the stop
  (`RecoveryScanMaxDepth`/`RecoveryScanMaxFiles`/`RecoveryScanTimeoutSec`), and
  **recency-bounded** - only a file modified at or after `-ModifiedAfter` (computed by its caller
  as `(Get-Date).AddMinutes(-$cfg.RecoveryMaxAgeMin)`, default **60** minutes back) counts as a
  candidate, because source footage and abandoned partial outputs legitimately share the volume
  root with a real deliverable (docs/16 §F-§G), and matching on extension alone would both
  re-upload already-safe source footage as though it were a recovered render AND misreport a
  render that produced nothing as merely misplaced. Older matches are still found and logged
  (`ExcludedByAge`), just never uploaded and never allowed to decide the class. A recent,
  extension-matched file that is still **locked** (a writer holds it open - Topaz's own live
  intermediate mid-mux) goes to a third bucket, `SkippedInProgress`, and likewise never votes on
  the class.
- **`Invoke-TopazForensicCapture`** copies the newest Topaz `*.tzlog`'s `process exited`/`error
  occurred` lines into `stop.log` on either error branch, best-effort and bounded
  (`TopazForensicTimeoutSec`, default **10 s**) - the piece that puts Topaz's own crash signature
  into THIS pipeline's own logs, rather than only into a session log that may not outlive the box.
- **`Invoke-TopazRecoveryUpload`** attempts a best-effort `rclone copy` + `rclone check` of
  exactly the discovered `ErrorClassA` candidate(s) to `<UploadTarget>/recovered`, reusing the
  same one-retry policy as the normal upload above, and logs a `RECOVERY DISPOSITION` line per
  file (`uploaded+verified` / `uploaded-but-unverified` / `NOT RECOVERED`).

All of this runs inside `Invoke-TopazOutputAnomalyHandling` (renamed from
`Invoke-TopazEmptyOutputDirHandling`), which `Invoke-TopazRenderUpload` calls unconditionally on
every `Reason='completed'` stop - not from an empty-directory branch - and which always returns
`$true` and never throws (an unanticipated failure inside it degrades to a logged warning rather
than propagating into `Stop-Sequence.ps1`).

**The box still stops in both classes - a deliberate, operator-chosen risk, not an oversight.**
The operator's own instruction: recover best-effort and log clearly, but still let the box stop
either way, rather than add a second refuse-to-stop path on top of the one in §3 above. That is a
real asymmetry against §3's interlock (a populated `OutputDir` whose upload fails twice DOES
refuse), and it is deliberate: this anomaly path is already handling a scenario the operator
pre-accepted the risk of (human/Topaz error misplacing an output), whereas §3's interlock
protects the common, expected case the whole pipeline exists for.

**A narrower gap than this remediation used to leave: a crashed writer's partial file can still be
uploaded and self-verified by the *incremental* upload path (Phase 2) before the resumed writer's
real content lands, for the short window until that path corrects itself.** This section's scan is
a stop-time safety net; it is unrelated to the eligibility rule
[Phase 2](04-phase2-watchdog.md#incremental-per-render-upload-and-the-blind-window-it-introduces-correction-3-shipped-2026-07-28)'s
`Resolve-IncrementalUploadEligibility` uses mid-render. See that section for the full reasoning -
in short, "unlocked + size-stable" cannot distinguish a genuinely finished file from one left
behind by a worker crash that Topaz has not yet retried, so a partial can still be uploaded once.
What has changed: identity is now the size and write-time actually uploaded
(`UploadedSize`/`UploadedWriteTimeUtc`), not the bare path alone, so once the resumed writer
overwrites that path with the real content, the path becomes eligible again and is re-uploaded -
logged at WARN, greppable as `SUPERSEDED` - the very next poll its new size restabilizes, rather
than waiting on this section's sweep. This section's own unconditional final sweep
(`Invoke-TopazRenderUpload`, §3 above) remains the catch-all for whatever has not yet restabilized,
or otherwise wasn't corrected, by the time the box actually stops, since it re-lists `OutputDir`
and re-runs copy+check with no memory of what the incremental pass already did.

### 5. Optional SNS notification

If `SnsTopicArn` is set, the script publishes a best-effort "render
complete/stalled" message (also with the discovered `--region`) before stopping.
This is covered in [Phase 5 - notifications](07-phase5-notifications.md). Like
the sync, a failure here is logged and ignored - it never blocks the power-off.
Under `DryRun` the message text itself says the stop was **suppressed** (see
below) rather than claiming the box is stopping - a real notification would
otherwise be a false alarm to anyone subscribed to the topic.

### 6. The DryRun switch

Start a new deployment with `DryRun = $true` in `Config.ps1`. In dry-run mode
the stop sequence logs exactly what it *would* do (including the reason and
the resolved `StopStrategy` plan) and **returns without powering off**.
`Watchdog.ps1` then **re-arms and keeps monitoring** for the next queue
instead of exiting - previously a `DryRun` stop left nothing watching until a
reboot re-triggered the scheduled task. This lets you watch several real jobs
drive the whole pipeline - detection, unlock gate, stop decision - **for the
in-guest path**. (This checked-in `Config.ps1` currently ships with
`DryRun = $false`, because this specific, already-verified instance has been
through this exact loop and armed - see
[docs/11-deploying-on-this-instance.md](11-deploying-on-this-instance.md) -
not because a new deployment should skip it.)

> **`DryRun` does not cover the out-of-band safety nets, IF you have enabled
> any of them.** For this project, as of 2026-07-28, neither exists: the
> CloudWatch idle alarm is opt-in and not created, and the max-lifetime
> Lambda is not deployed - see
> [docs/09 §5](09-appendix-b-boundaries.md#5-no-idle-alarm-no-timed-stop-the-watchdog-is-the-only-thing-that-will-ever-stop-this-box).
> But if you (or a different deployment) do enable either, know that they are
> control-plane resources entirely independent of `Config.ps1` - they are
> **not gated by `DryRun`** and will really call `ec2:StopInstances` on the
> box, e.g. roughly `IDLE_MINUTES` after the render's GPU goes idle, even
> while you are validating in `DryRun`. Leaving an idle-based safety net
> active during `DryRun` testing means the box can still stop out from under
> you while you are watching the in-guest logs prove out "zero risk." Pause
> the idle alarm's actions (`aws cloudwatch disable-alarm-actions`, see
> [Phase 4](06-phase4-safety-net.md)) or account for the max-lifetime ceiling
> if you need a genuinely stop-proof validation window.

Once you have watched a couple of jobs complete cleanly in the logs
(`C:\topaz-autostop\logs\stop.log`), flip `DryRun = $false` in `Config.ps1`, then
re-run [`Install.ps1`](../in-guest/Install.ps1) and
[`Register-ScheduledTasks.ps1`](../in-guest/Register-ScheduledTasks.ps1) so the
installed copy the SYSTEM task runs picks up the change.

### 7. Why `-Force` is safe here

`Stop-Computer -Force` skips the "an app is asking to cancel shutdown" negotiation
and powers off immediately. That is safe in this pipeline specifically because the
watchdog has **already proven** the two things `-Force` would otherwise risk:

- **The encode workers have exited.** The stop only happens after the queue
  drained (no active worker descendant for `DebounceSec`) or a stall was
  declared. We are not force-killing an active encoder.
- **The output files are unlocked.** The file-unlock gate confirmed nothing holds
  a write handle on any non-`_temp` output file before handing off. There is no
  half-written file for `-Force` to truncate.

In other words, `-Force` is not "stop even though work is in progress" - it is
"stop now that we have confirmed no work is in progress." See
[Phase 2](04-phase2-watchdog.md) for the completion and unlock logic.

## What the script returns, and why that is load-bearing

`Stop-Sequence.ps1` reports its outcome as a **single boolean on the output
stream**:

- **`$false`** - the stop was REFUSED (ephemeral interlock, final completion
  safety gate) or every action in the plan was attempted and the box is still
  running.
- **`$true`** - the stop was performed, or was deliberately suppressed by
  `DryRun`. ("Suppressed on purpose" is not a failure, and conflating it with a
  refusal would break the watchdog's own `DryRun` re-arm path.)

`Watchdog.ps1` tests that value with `$stopResult -eq $false` to decide whether
to re-arm and retry. That is the retry loop keeping an un-uploaded render alive,
so two properties are non-negotiable and are now pinned by
[`in-guest/tests/Stop-Sequence.Tests.ps1`](../in-guest/tests/Stop-Sequence.Tests.ps1):
**exactly one object** is emitted (this is why `Write-TopazLog` writes to the
Information/Warning/Error streams and never to output - see its comment in
`Config.ps1`), and the watchdog's call path must never `exit`, because `exit`
makes the `& <script>` expression yield `$null`, and `$null -eq $false` is
false, so the re-arm block would simply be skipped.

### `-ExitCodeOnRefusal`, for the scheduled-task caller only

Under Task Scheduler's `powershell.exe -File`, a returned `$false` is just text
on stdout: the host prints `False` and exits **0**. So a refused wall-clock hard
stop showed `LastTaskResult=0` - *success* - which is precisely the field
[`Register-TimedStop.ps1`](../in-guest/Register-TimedStop.ps1)'s `.NOTES` tells
the operator to inspect for a cost backstop that had, in fact, stopped nothing
and would keep refusing every `RetryIntervalMinutes`.

The opt-in `-ExitCodeOnRefusal` switch translates the outcome into an exit code
(**2** = refused, **0** = stopped or suppressed). It is passed by
`Register-TimedStop.ps1`'s action string and **nowhere else** - deliberately a
switch rather than a test on `$MyInvocation`, because that test cannot tell
`-File` from the watchdog's `&` call and would have silently broken the re-arm
contract above.

### The `-LibraryOnly` seam

Dot-sourcing `Stop-Sequence.ps1 -LibraryOnly` defines its functions and does
nothing else - no config load, no IMDS round trip, no `stop.log` line. The whole
body lives in `Invoke-TopazStopSequence`, and the ephemeral branch is the pure
`Resolve-EphemeralUploadRefusal`. That exists so the ORDERING above is testable:
before it, the file was straight-line top-level code that could not be loaded
without attempting a real stop, so moving the safety gate below the `DryRun`
guard - or dropping a `return $false` - would have left every test in the repo
green while turning a refusal into a stop.

## Incremental per-render upload (CORRECTION 3, shipped 2026-07-28)

Before this correction, upload only happened once - inside `Stop-Sequence.ps1`, after the whole
queue had gone idle for `DebounceSec` (see [Phase 2](04-phase2-watchdog.md)). On a multi-export
queue that left a finished, multi-GB deliverable unprotected on the ephemeral scratch volume for
the entire duration of every subsequent export - hours, in the incident this project's
remediation work keeps referring back to ([docs/16](16-render-loss-incident.md)). Per the
operator's instruction, `Watchdog.ps1` now starts uploading a render as soon as it finishes, not
after the whole queue drains.

The shipped design, from this document's side (see [Phase 2](04-phase2-watchdog.md) for the same
mechanism from the poll loop's own side):

- **Eligibility is a pure, unit-testable decision** (`Resolve-IncrementalUploadEligibility` in
  `Watchdog.ps1`), not an ad-hoc check: given whether a candidate file is a temp file
  (`Test-TopazTempFile`), whether it is unlocked (`Test-FileUnlocked`), its size now vs. last
  seen, how many seconds it has held that size, and whether it was already uploaded, a file
  becomes eligible once it is not a temp file, is unlocked, its size matches the last poll's
  reading, AND its size has been unchanged for `UploadStableSec` (default **30 s**) - size-stable
  and unlocked together is what actually distinguishes "finished" from "still being written." The
  companion function `Get-NextUploadTrackingState` updates the per-file stability bookkeeping each
  poll and calls the eligibility check with the fresh numbers. "Already uploaded" is identity-based
  (`UploadedSize`/`UploadedWriteTimeUtc`), not a bare path check, so a file whose content changes
  after its upload becomes eligible again - see below.
- On eligibility, `Invoke-TopazIncrementalUploadPoll` (`Watchdog.ps1`) calls
  `Invoke-TopazIncrementalUpload` (`Config.ps1`), which uploads **that file alone** via a scoped
  `rclone copyto <local-file> <UploadTarget>/<relative-path>`, then verifies that exact file-to-file
  destination with `rclone check --one-way`. This deliberately avoids an `--include` filter here:
  rclone filters are glob patterns, whereas the literal destination preserves an output filename
  containing filter metacharacters. It then marks the size and write-time it uploaded so later polls
  skip it - unless the file's size or write-time later differs from what was uploaded, in which case
  it becomes eligible again (see below).
- A failed incremental attempt reuses the same one-retry policy
  (`Resolve-UploadRetryDecision`) and is **never fatal** to the monitoring loop: log it, leave the
  file unmarked, and let a later poll - or §3's end-of-queue upload, still an unconditional
  catch-all sweep - retry it. §3 does not change at all; it just costs almost nothing once most
  files are already uploaded, since rclone skips them.
- Switchable (`UploadWhenReady`, default `$true`) so it can be turned off without a code change.

See [Phase 2](04-phase2-watchdog.md) for the blind window this introduces in the poll loop, why
it is bounded and accepted rather than solved with a background job, and a known gap: the
"unlocked + size-stable" eligibility rule can be fooled by a worker that crashed mid-export,
letting an incomplete file be uploaded and marked as such before the resumed writer supplies the
real content. That no longer waits on this document's own §3/§4 final sweep to be corrected,
though - identity is keyed on the size/write-time actually uploaded, so the path becomes eligible
again (logged at WARN, greppable as `SUPERSEDED`) the moment the resumed writer's real content
restabilizes, on the very next poll after that. §3/§4's final sweep remains the catch-all for
whatever has not yet restabilized, or otherwise wasn't corrected, by the time the box actually
stops.

## What is deliberately NOT here

There is intentionally **no in-guest fallback timer** (`Start-Job` +
`Stop-EC2Instance`) as a backstop. A job scheduled inside this session lives
inside the very session being torn down and would die with it before it could
fire. Any out-of-band safety net therefore has to live in the control plane -
the CloudWatch idle alarm in [Phase 4](06-phase4-safety-net.md) is that
capability, kept available and documented, but **not armed by default for
this project** (decided 2026-07-28 - see
[docs/09 §5](09-appendix-b-boundaries.md#5-no-idle-alarm-no-timed-stop-the-watchdog-is-the-only-thing-that-will-ever-stop-this-box)).
This is one of the corrected assumptions in
[Appendix A](08-appendix-a-corrections.md).

Continue to [Phase 4 - the safety net](06-phase4-safety-net.md).
