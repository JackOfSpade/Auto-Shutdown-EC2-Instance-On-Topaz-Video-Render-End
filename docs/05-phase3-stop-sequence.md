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
  denied or does not take effect within `StopVerifySec` (default **90 s**),
  falls back to `GuestShutdown`.

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
                 notifications; region is REQUIRED by steps 2-3 below
2. (optional)    aws s3 sync OutputDir -> S3SyncTarget --region <region> -- BEFORE power off
3. (optional)    aws sns publish "render complete/stalled" --region <region>
4. DryRun?  -> log the decision and RETURN (no power off; Watchdog.ps1 re-arms)
5. else     -> follow the StopStrategy plan in order (default 'Auto':
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

### 3. Optional SNS notification

If `SnsTopicArn` is set, the script publishes a best-effort "render
complete/stalled" message (also with the discovered `--region`) before stopping.
This is covered in [Phase 5 - notifications](07-phase5-notifications.md). Like
the sync, a failure here is logged and ignored - it never blocks the power-off.
Under `DryRun` the message text itself says the stop was **suppressed** (see
below) rather than claiming the box is stopping - a real notification would
otherwise be a false alarm to anyone subscribed to the topic.

### 4. The DryRun switch

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

> **`DryRun` does not cover the out-of-band safety nets.** The CloudWatch
> GPU-idle alarm and the optional max-lifetime Lambda are control-plane
> resources, entirely independent of `Config.ps1` - they are **not gated by
> `DryRun`** and will really call `ec2:StopInstances` on the box, e.g. roughly
> `IDLE_MINUTES` after the render's GPU goes idle, even while you are validating
> in `DryRun`. If you leave those safety nets active during `DryRun` testing (as
> intended - see [Phase 4](06-phase4-safety-net.md)), the box can still stop out
> from under you while you are watching the in-guest logs prove out "zero risk."
> Pause the idle alarm's actions (`aws cloudwatch disable-alarm-actions`, see
> [Phase 4](06-phase4-safety-net.md)) or account for the max-lifetime ceiling if
> you need a genuinely stop-proof validation window.

Once you have watched a couple of jobs complete cleanly in the logs
(`C:\topaz-autostop\logs\stop.log`), flip `DryRun = $false` in `Config.ps1`, then
re-run [`Install.ps1`](../in-guest/Install.ps1) and
[`Register-ScheduledTasks.ps1`](../in-guest/Register-ScheduledTasks.ps1) so the
installed copy the SYSTEM task runs picks up the change.

### 5. Why `-Force` is safe here

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

## What is deliberately NOT here

There is intentionally **no in-guest fallback timer** (`Start-Job` +
`Stop-EC2Instance`) as a backstop. A job scheduled inside this session lives
inside the very session being torn down and would die with it before it could
fire. The real out-of-band safety net is the CloudWatch idle alarm in
[Phase 4](06-phase4-safety-net.md). This is one of the corrected assumptions in
[Appendix A](08-appendix-a-corrections.md).

Continue to [Phase 4 - the safety net](06-phase4-safety-net.md).
