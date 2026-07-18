# 06 - Phase 4: The out-of-band safety net

[README](../README.md) - [Architecture](01-architecture.md) - [Phase 0](02-phase0-confirmations.md) - [Phase 1](03-phase1-instance-prep.md) - [Phase 2](04-phase2-watchdog.md) - [Phase 3](05-phase3-stop-sequence.md) - **Phase 4** - [Phase 5](07-phase5-notifications.md)

The watchdog is the primary stop. Phase 4 adds the **fallbacks that fire when the
watchdog does not** - a crashed watchdog, an orphaned instance, a job that hangs
in a way the guest never notices. Crucially, these fallbacks live **out of band**,
in the AWS control plane, so they never share fate with the guest they are
guarding.

## The GPU-idle CloudWatch alarm

```bash
INSTANCE_ID=i-XXXXXXXXXXXXXXXXX AWS_REGION=<region> \
  ./control-plane/03-create-idle-alarm.sh
```

[`03-create-idle-alarm.sh`](../control-plane/03-create-idle-alarm.sh) creates the
alarm `topaz-gpu-idle-autostop`:

| Setting | Value | Why |
|---------|-------|-----|
| Namespace / metric | `TopazRender/GPU` / `GPUUtilization` | The custom GPU metric the box publishes. |
| Dimension | `InstanceId=<this instance>` | Scopes the alarm to one box. |
| Statistic / period | `Average` / `60 s` | One data point per published minute. |
| Evaluation periods | `30` | 30 x 60 s = **30 minutes** sustained. |
| Threshold / operator | `< 5%` | Sub-5% GPU = idle. |
| `treat-missing-data` | `notBreaching` | Missing data is ambiguous; do **not** stop on it. |
| Action | `arn:aws:automate:<region>:ec2:stop` | Built-in EC2 stop action; needs no IAM role. |

### Why GPU, not CPU

The alarm keys on the **custom GPU metric, never on `CPUUtilization`**. A Topaz
render can peg the GPU while the CPU sits near idle, so a CPU-based alarm would
**false-stop an active render**. CPU is simply blind to GPU load. The whole reason
the box publishes a custom GPU metric is so the safety net can observe the actual
work. (This is a corrected assumption - see [Appendix A](08-appendix-a-corrections.md).)

### Why 30 minutes, and why `notBreaching`

- **30 minutes of sustained sub-5% GPU** is deliberately long and conservative.
  Topaz GPU work spikes well above 5% while encoding, so a real render can never
  accumulate 30 continuous idle minutes. The window only elapses when the box is
  genuinely doing nothing.
- **`treat-missing-data notBreaching`** means that if the metric stops arriving
  entirely (e.g. the publisher died), the alarm does **not** interpret absence as
  "idle" and stop the box on missing data alone. Missing data is ambiguous, so the
  alarm stays OK. (The wall-clock cap below is what covers a truly wedged box.)

Verify the alarm:

```bash
aws cloudwatch describe-alarms --region <region> --alarm-names topaz-gpu-idle-autostop
```

## The Windows GPU metric publisher

The alarm is only as good as the metric feeding it, and that metric comes from
[`Push-GpuMetric.ps1`](../in-guest/Push-GpuMetric.ps1), registered by
[Phase 2](04-phase2-watchdog.md) as the once-per-minute SYSTEM task
`TopazAutoStop-GpuMetric`. Each run:

1. Reads GPU utilization from `nvidia-smi --query-gpu=utilization.gpu
   --format=csv,noheader,nounits` (first GPU line).
2. Resolves instance id and region from IMDSv2 (region = the availability zone
   with its trailing zone letter stripped, e.g. `us-east-1a` -> `us-east-1` -
   never hardcoded).
3. Publishes `TopazRender/GPU / GPUUtilization` (unit `Percent`, dimension
   `InstanceId=...`) via `aws cloudwatch put-metric-data`.

Every external call is wrapped in try/catch and the script **always exits 0**, so
a bad read simply publishes nothing that minute rather than error-spamming the
scheduler.

### Why a scheduled-task publisher (and not the CloudWatch agent)

On Windows there is **no native CloudWatch collector for NVIDIA GPU utilization** -
the unified CloudWatch agent's NVIDIA GPU support is **Linux-only**. So on this
Windows box the metric has to be produced by shelling out to `nvidia-smi` and
pushing the value with the AWS CLI, on a schedule. That is exactly what this task
does. (This corrects a common wrong assumption - see [Appendix A](08-appendix-a-corrections.md).)

This is why [Phase 1](03-phase1-instance-prep.md) insists both `nvidia-smi.exe`
and `aws.exe` are on PATH, and why [`Install.ps1`](../in-guest/Install.ps1) warns
if they are not: without them the box publishes no GPU metric and the alarm has
nothing to watch.

## Optional: the max-lifetime hard cap (Lambda)

The idle alarm cannot catch a job that stays **"stuck busy"** - a hung render that
keeps the GPU above 5% forever never goes idle, so the alarm never fires. The
optional wall-clock cap covers exactly that.

```bash
INSTANCE_ID=i-XXXXXXXXXXXXXXXXX AWS_REGION=<region> MAX_LIFETIME_HOURS=12 \
  ./control-plane/04-deploy-max-lifetime-lambda.sh
```

[`04-deploy-max-lifetime-lambda.sh`](../control-plane/04-deploy-max-lifetime-lambda.sh)
zips [`lambda/max-lifetime-stop`](../lambda/max-lifetime-stop/), creates the
execution role `topaz-max-lifetime-lambda-role` (from
[`iam/lambda-execution-policy.json`](../control-plane/iam/lambda-execution-policy.json)),
creates the `topaz-max-lifetime-stop` function (`python3.12`, handler
`handler.handler`), and schedules it with **EventBridge Scheduler** at
`rate(30 minutes)` - falling back to a classic CloudWatch Events rule when
EventBridge Scheduler is not usable (e.g. no `SCHEDULER_ROLE_ARN` supplied).

What the [handler](../lambda/max-lifetime-stop/handler.py) does on each fire:

- Reads the target instance's `LaunchTime` and state via `ec2:DescribeInstances`.
- If the instance is **`running`** and its age `>= MAX_LIFETIME_HOURS` (default
  **12**), calls `ec2:StopInstances`. Otherwise it is a no-op.
- **Stop only, never terminate.** Idempotent: already-stopping/stopped is a no-op.
  Timezone-aware UTC math. Graceful if the instance id can't be found.

The `ec2:StopInstances` grant in the Lambda's execution policy is **tag-scoped to
`AutoStopEligible=true`**, so the target instance must carry that tag for the stop
to succeed. See [`lambda/max-lifetime-stop/README.md`](../lambda/max-lifetime-stop/README.md)
for the full environment-variable contract and a local smoke test.

This whole stage is **optional**. If you do not want a hard wall-clock ceiling,
skip it - delete the function and schedule to remove it later.

## The three layers together

| Layer | Fires when | Plane | Shares fate with guest? |
|-------|-----------|-------|------------------------|
| Watchdog (primary) | Queue drained / stalled + files unlocked | In-guest | n/a (it *is* the guest) |
| GPU-idle alarm | 30 min sustained sub-5% GPU | Control plane | No |
| Max-lifetime Lambda (optional) | Instance age >= ceiling, any GPU load | Control plane | No |

Continue to [Phase 5 - notifications](07-phase5-notifications.md).
