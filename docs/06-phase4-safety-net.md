# 06 - Phase 4: The out-of-band safety net

[README](../README.md) - [Architecture](01-architecture.md) - [Phase 0](02-phase0-confirmations.md) - [Phase 1](03-phase1-instance-prep.md) - [Phase 2](04-phase2-watchdog.md) - [Phase 3](05-phase3-stop-sequence.md) - **Phase 4** - [Phase 5](07-phase5-notifications.md)

The watchdog is the primary stop. Phase 4 adds the **fallbacks that fire when the
watchdog does not** - a crashed watchdog, an orphaned instance, a job that hangs
in a way the guest never notices. Crucially, these fallbacks live **out of band**,
in the AWS control plane, so they never share fate with the guest they are
guarding.

## The GPU-idle CloudWatch alarm

```bash
INSTANCE_ID=i-XXXXXXXXXXXXXXXXX AWS_REGION=<region> [IDLE_MINUTES=30] \
  ./control-plane/03-create-idle-alarm.sh
```

[`03-create-idle-alarm.sh`](../control-plane/03-create-idle-alarm.sh) creates a
**per-instance** alarm named `topaz-gpu-idle-autostop-<instance-id>`:

| Setting | Value | Why |
|---------|-------|-----|
| Namespace / metric | `TopazRender/GPU` / `GPUUtilization` (override with `METRIC_NAMESPACE`/`METRIC_NAME`) | The custom GPU metric the box publishes. Only override these together with `Config.ps1`'s matching `MetricNamespace`/`MetricName` **and** the same `METRIC_NAMESPACE` passed to [`02-create-iam-role.sh`](03-phase1-instance-prep.md) (it re-scopes the instance role's `PutMetricData` grant to match), or the alarm ends up watching a metric nothing is even allowed to publish. |
| Dimension | `InstanceId=<this instance>` | Scopes the alarm to one box. |
| Statistic / period | `Average` / `60 s` | One data point per published minute. |
| Evaluation periods | `IDLE_MINUTES` (default `30`) | `IDLE_MINUTES` x 60 s = **`IDLE_MINUTES` minutes** sustained. |
| Threshold / operator | `< 5%` | Sub-5% GPU = idle. |
| `treat-missing-data` | `notBreaching` | Missing data is ambiguous; do **not** stop on it. |
| Action | `arn:aws:automate:<region>:ec2:stop` | Built-in EC2 stop action; needs no IAM role. |

### Why per-instance, not a shared alarm name

`put-metric-alarm` **overwrites** any existing alarm with the same
`--alarm-name`. An earlier shared name (`topaz-gpu-idle-autostop`) meant
provisioning a **second** instance silently repointed - and thereby disabled -
the first box's safety net. Keying the name on `INSTANCE_ID` gives every
instance its own alarm; upgrading an older deployment should delete the
orphaned shared-name alarm (the script prints the exact command).

### Why GPU, not CPU

The alarm keys on the **custom GPU metric, never on `CPUUtilization`**. A Topaz
render can peg the GPU while the CPU sits near idle, so a CPU-based alarm would
**false-stop an active render**. CPU is simply blind to GPU load. The whole reason
the box publishes a custom GPU metric is so the safety net can observe the actual
work. (This is a corrected assumption - see [Appendix A](08-appendix-a-corrections.md).)

### Why 30 minutes by default, and why `notBreaching`

- **`IDLE_MINUTES` minutes of sustained sub-5% GPU** (default **30**) is
  deliberately long and conservative. Topaz GPU work spikes well above 5% while
  encoding, so a real render can never accumulate that many continuous idle
  minutes. The window only elapses when the box is genuinely doing nothing.
  `IDLE_MINUTES` must be a positive integer with no leading zeros; raise it if a
  slow pre-render setup (uploading source files, configuring the export) or a
  large post-render S3 sync routinely leaves the GPU idle longer than the
  default before/after the render itself - see "Safety-net operational windows"
  below.
- **`treat-missing-data notBreaching`** means that if the metric stops arriving
  entirely (e.g. the publisher died), the alarm does **not** interpret absence as
  "idle" and stop the box on missing data alone. Missing data is ambiguous, so the
  alarm stays OK. (The wall-clock cap below is what covers a truly wedged box.)

Verify the alarm:

```bash
aws cloudwatch describe-alarms --region <region> --alarm-names topaz-gpu-idle-autostop-<instance-id>
```

### Pausing the alarm during a long pre-render setup

The script also prints the exact commands to pause and resume the alarm's stop
action, for the case where you need the GPU to sit idle longer than
`IDLE_MINUTES` without triggering a stop (e.g. uploading large source files
before clicking Export):

```bash
aws cloudwatch disable-alarm-actions --region <region> --alarm-names topaz-gpu-idle-autostop-<instance-id>
aws cloudwatch enable-alarm-actions  --region <region> --alarm-names topaz-gpu-idle-autostop-<instance-id>
```

Disable before the idle stretch, then re-enable right after clicking Export so
the safety net is back in place for the actual render.

## The Windows GPU metric publisher

The alarm is only as good as the metric feeding it, and that metric comes from
[`Push-GpuMetric.ps1`](../in-guest/Push-GpuMetric.ps1), registered by
[Phase 2](04-phase2-watchdog.md) as the once-per-minute SYSTEM task
`TopazAutoStop-GpuMetric`. Each run:

1. Reads GPU utilization via the shared `Get-GpuUtilizationMax` helper in
   [`Config.ps1`](../in-guest/Config.ps1), which runs `nvidia-smi
   --query-gpu=utilization.gpu --format=csv,noheader,nounits` and publishes the
   **maximum** value across **all** GPUs on the box, not just the first line.
   This matters on a multi-GPU instance (e.g. a `g5.12xlarge` with 4 GPUs):
   Topaz typically loads a single GPU, so reading only the first GPU line could
   report ~0% during an actively-rendering job and let the idle alarm below
   false-stop the box. Returns `$null` (rather than `0`) if the read fails, so a
   failed read is never confused with a genuinely idle GPU.
2. Resolves instance id and region from IMDSv2 via the shared `Get-Ec2Identity`
   helper (also in `Config.ps1`), using ONE token for both calls. Region is read
   from the dedicated `placement/region` endpoint - correct for Local Zones and
   Wavelength, where stripping the trailing letter off the availability zone does
   not yield a valid region - falling back to the AZ-letter-strip only if that
   endpoint is unavailable. Even that fallback never guesses a malformed region
   for a Local Zone/Wavelength AZ: `Convert-AzToRegion` recognizes when the
   stripped candidate does not look like a standard region and leaves the region
   empty (same as a full IMDS failure) instead of passing a bad `--region` to the
   AWS CLI.
3. Publishes `TopazRender/GPU / GPUUtilization` (unit `Percent`, dimension
   `InstanceId=...`) via `aws cloudwatch put-metric-data`, bounded to
   `AwsCliTimeoutSec` (default **60 s**) so a hung `aws` call cannot wedge the
   once-a-minute scheduled task forever.

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
performs, in order:

1. **Tags the instance `AutoStopEligible=true`.** The Lambda's `ec2:StopInstances`
   grant (below) is tag-scoped to that tag. Nothing else in this stage applies
   it, so without this step the Lambda's stop call would fail
   `UnauthorizedOperation` on every fire - a silently dead safety net. This is
   step 1, before anything else is created.
2. Zips only `handler.py` from
   [`lambda/max-lifetime-stop`](../lambda/max-lifetime-stop/) - not the test
   suite, `conftest.py`, `requirements-dev.txt`, the README, or any stale
   `__pycache__` bytecode - and creates the execution role
   `topaz-max-lifetime-lambda-role` (shared across every
   instance - the policy is tag-scoped and byte-for-byte identical regardless of
   which instance it guards) from
   [`iam/lambda-execution-policy.json`](../control-plane/iam/lambda-execution-policy.json).
3. Creates a **per-instance** function `topaz-max-lifetime-stop-<instance-id>`
   (`python3.12`, handler `handler.handler`).
4. Schedules it under a **per-instance** name
   `topaz-max-lifetime-schedule-<instance-id>` with **EventBridge Scheduler** at
   `rate(30 minutes)` - falling back to a classic CloudWatch Events rule when
   EventBridge Scheduler is not usable (e.g. no `SCHEDULER_ROLE_ARN` supplied).

Per-instance function/schedule names exist for the same reason as the idle
alarm's per-instance name above: a shared name would let a second instance's
deploy silently clobber (re-target) the first instance's function and schedule.

`MAX_LIFETIME_HOURS` (default **12**) must be a positive, finite number (e.g.
`12` or `4.5`); the deploy script validates this itself - including rejecting
a numeric string long enough to overflow to infinity - and rejects a bad value
at deploy time, rather than deploying "successfully" while the Lambda silently
falls back to its own default and the deploy output lies about the effective
ceiling.

What the [handler](../lambda/max-lifetime-stop/handler.py) does on each fire:

- Reads the target instance's `LaunchTime` and state via `ec2:DescribeInstances`.
- If the instance is **`running`** and its age `>= MAX_LIFETIME_HOURS`, calls
  `ec2:StopInstances`. Otherwise it is a no-op.
- **Stop only, never terminate.** Idempotent: already-stopping/stopped is a no-op.
  Timezone-aware UTC math. Graceful if the instance id can't be found.
- **`MAX_LIFETIME_HOURS` validation is defense-in-depth, not just deploy-time.**
  The handler independently re-validates the env var on every invocation and
  falls back to the 12h default on anything non-numeric, non-positive, **or
  non-finite** (`nan`/`inf`). The non-finite check matters specifically:
  `age_hours < nan` is always `False` (which would invert the cap into
  stop-immediately on every fire) and `age_hours < inf` is always `True` (which
  would silently disable the cap forever) - both parse fine as a `float` but
  would otherwise defeat the ceiling check silently.

The `ec2:StopInstances` grant in the Lambda's execution policy is **tag-scoped to
`AutoStopEligible=true`**, so the target instance must carry that tag for the stop
to succeed - which is exactly why tagging is step 1 above. See
[`lambda/max-lifetime-stop/README.md`](../lambda/max-lifetime-stop/README.md)
for the full environment-variable contract and a local smoke test.

This whole stage is **optional**. If you do not want a hard wall-clock ceiling,
skip it - delete the function and schedule to remove it later.

## Safety-net operational windows

Both out-of-band safety nets watch **wall-clock/GPU state**, not "is a render
actually supposed to be happening" - so two ordinary operational windows can
trip the idle alarm if you are not deliberate about them:

- **Pre-render setup.** The idle alarm has no concept of "the operator is still
  setting up." If uploading source files or configuring the export keeps the GPU
  idle longer than `IDLE_MINUTES` **before** Export is clicked, the alarm will
  stop the box out from under you mid-setup. Pause it first with the
  `disable-alarm-actions` command above, and re-enable it right after clicking
  Export.
- **Post-render S3 sync.** If `S3SyncTarget` is configured
  ([Phase 3](05-phase3-stop-sequence.md)), the GPU has already been idle since
  the debounce window started - well before `Stop-Sequence.ps1` even begins the
  sync. A large sync of big output files can push the *cumulative* idle time
  (debounce + unlock wait + sync) past `IDLE_MINUTES`, and the idle alarm does
  not know a sync is in flight: its `ec2:stop` action would abruptly stop the
  instance mid-sync, ahead of `Stop-Sequence.ps1`'s own graceful
  `Stop-Computer -Force`. Size `IDLE_MINUTES` generously (covering debounce +
  unlock wait + your largest expected sync) whenever `S3SyncTarget` is set.

## The three layers together

| Layer | Fires when | Plane | Shares fate with guest? |
|-------|-----------|-------|------------------------|
| Watchdog (primary) | Queue drained / stalled + files unlocked | In-guest | n/a (it *is* the guest) |
| GPU-idle alarm | `IDLE_MINUTES` min sustained sub-5% GPU (default 30) | Control plane | No |
| Max-lifetime Lambda (optional) | Instance age >= ceiling, any GPU load | Control plane | No |

**None of these three layers is gated by `Config.ps1`'s `DryRun` switch** - only
the in-guest watchdog/stop-sequence path is. See the `DryRun` caveat in
[Phase 3](05-phase3-stop-sequence.md).

Continue to [Phase 5 - notifications](07-phase5-notifications.md).
