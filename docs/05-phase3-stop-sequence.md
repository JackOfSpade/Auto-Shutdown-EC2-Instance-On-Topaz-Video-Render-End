# 05 - Phase 3: The stop sequence

[README](../README.md) - [Architecture](01-architecture.md) - [Phase 0](02-phase0-confirmations.md) - [Phase 1](03-phase1-instance-prep.md) - [Phase 2](04-phase2-watchdog.md) - **Phase 3** - [Phase 4](06-phase4-safety-net.md) - [Phase 5](07-phase5-notifications.md)

[`Stop-Sequence.ps1`](../in-guest/Stop-Sequence.ps1) is invoked by the watchdog
once the render queue is complete or stalled, with `-Reason completed` or
`-Reason stalled`. It runs the optional best-effort artifact/notification steps
and then powers the guest off.

## The stop needs no API call and no credentials

The actual stop is a **guest-OS shutdown** - `Stop-Computer -Force`, equivalent
to `shutdown /s /t 0`. Because
`InstanceInitiatedShutdownBehavior=stop` was set in
[Phase 1](03-phase1-instance-prep.md), that shutdown **stops** the EC2 instance.

There is **no `ec2:StopInstances` call and no AWS credential** involved in the
stop itself. The box stops itself simply by turning its own OS off. This is the
central design property of the whole pipeline (see [Architecture](01-architecture.md)).

## Order of operations

```
1. (best-effort) IMDSv2 lookup of this instance's id   -- only to prettify notifications
2. (optional)    aws s3 sync OutputDir -> S3SyncTarget -- BEFORE power off
3. (optional)    aws sns publish "render complete/stalled"
4. DryRun?  -> log the decision and RETURN (no power off)
5. else     -> Stop-Computer -Force   (guest shutdown => instance STOP)
```

### 1. Best-effort instance-id (IMDSv2)

The script fetches the instance id via IMDSv2 (token-based metadata) purely to
make notifications readable. If IMDS is unreachable it falls back to a placeholder
id and continues - this lookup never blocks the stop.

### 2. Optional S3 sync (runs BEFORE power off)

If `S3SyncTarget` is set in [`Config.ps1`](../in-guest/Config.ps1) (e.g.
`s3://my-bucket/renders/`), the script runs `aws s3 sync OutputDir S3SyncTarget
--only-show-errors` **before** powering off, so finished artifacts are safe even
if something later goes wrong. Empty (the default) skips the sync. A non-zero exit
or thrown error is logged as a warning and **does not** block the stop.

> S3 sync uses the AWS CLI and therefore the instance role's credentials. The
> default instance role only grants `cloudwatch:PutMetricData`; if you enable S3
> sync you must also grant the role `s3:PutObject` (and typically `s3:ListBucket`)
> on the target bucket/prefix. That grant is not part of
> [`02-create-iam-role.sh`](../control-plane/02-create-iam-role.sh) - add it yourself.

### 3. Optional SNS notification

If `SnsTopicArn` is set, the script publishes a best-effort "render
complete/stalled" message before stopping. This is covered in
[Phase 5 - notifications](07-phase5-notifications.md). Like the sync, a failure
here is logged and ignored - it never blocks the power-off.

### 4. The DryRun switch

`Config.ps1` ships with `DryRun = $true`. In dry-run mode the stop sequence logs
exactly what it *would* do (including the reason) and **returns without powering
off**. This lets you watch several real jobs drive the whole pipeline - detection,
unlock gate, stop decision - with zero risk of an unwanted stop.

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
  drained (no child `ffmpeg` for `DebounceSec`) or a stall was declared. We are not
  force-killing an active encoder.
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
