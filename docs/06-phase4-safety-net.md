# 06 - Phase 4: The out-of-band safety net

[README](../README.md) - [Architecture](01-architecture.md) - [Phase 0](02-phase0-confirmations.md) - [Phase 1](03-phase1-instance-prep.md) - [Phase 2](04-phase2-watchdog.md) - [Phase 3](05-phase3-stop-sequence.md) - **Phase 4** - [Phase 5](07-phase5-notifications.md)

## NOT ARMED ON THIS PROJECT (decided 2026-07-28) - read this before anything else below

**The CloudWatch idle alarm this document describes is not running for this
deployment, and creating it is now an explicit opt-in act
(`control-plane/03-create-idle-alarm.sh` refuses to create/update anything
unless you pass `ENABLE_IDLE_ALARM=1` - see that script's own `.DECISION`
header block).** The operator decided this on 2026-07-28 and has already
deleted the alarm that previously existed for this instance. The **only**
auto-stop this project runs is:

```
watchdog detects render-queue completion -> Stop-Sequence.ps1 verifies the
Google Drive upload -> ec2:StopInstances
```

(See [Phase 3](05-phase3-stop-sequence.md) for the full upload picture: the ephemeral-upload
interlock, the misplaced-output recovery scan added after the 2026-07-28 incident, and the
per-render incremental upload (CORRECTION 3, shipped 2026-07-28).)

**Why.** An idle alarm - on *any* signal, GPU or `RenderActive` - watches
wall-clock/presence state, not intent. It cannot tell "the box was abandoned"
apart from "the operator is still setting up" or "the queue is between two
items", and re-keying the signal (the `GPUUtilization` -> `RenderActive`
change documented below) only narrows that hazard, it does not remove it
structurally. This is not theoretical: on 2026-07-27, the then-current
GPU-keyed build of exactly this alarm read under 5% GPU for **25 consecutive
one-minute samples** during a confirmed-healthy, actively-progressing 4K
render - **five minutes** short of breaching its own 30-minute window (see
[§K below](#why-the-alarm-no-longer-defaults-to-gpu-and-why-30-minutes--notbreaching)
and [docs/15 §K](15-third-end-to-end-run.md)). A near-miss on a live render is
not an acceptable safety net for a job whose whole point is to finish
unattended.

**What this means in practice:**

- No idle-based signal - `RenderActive` or `GPUUtilization` - can stop this
  box. Only the watchdog's own completion detection can.
- `Push-GpuMetric.ps1` keeps publishing `RenderActive` and `GPUUtilization`
  every minute regardless - the metric is still useful, passively-observed
  telemetry (for a human glancing at CloudWatch, or a future consumer that
  isn't a blind stop-the-box alarm). What changed is that **nothing acts on
  it** by default any more.
- The optional max-lifetime Lambda (below) is **not deployed** either. With
  neither of those and the one-shot wall-clock timed stop already removed
  (2026-07-27), the **only** thing that will ever stop this box is the
  watchdog completing a render. See
  [docs/09-appendix-b-boundaries.md](09-appendix-b-boundaries.md) for that
  trade-off recorded honestly, including its cost and the manual mitigations.
- This document is **kept as the reference for how the alarm works**, in full,
  below - for the day a different deployment (or this one, deliberately
  reconsidered) genuinely wants a wall-clock idle cap. Nothing below should be
  read as "this is armed here."

---

The watchdog is the primary stop. Phase 4 historically added the **fallbacks
that fire when the watchdog does not** - a crashed watchdog, an orphaned
instance, a job that hangs in a way the guest never notices - and this section
documents how they work, for anyone who deliberately opts back in. Crucially,
these fallbacks live **out of band**, in the AWS control plane, so they never
share fate with the guest they are guarding - that property does not depend on
whether they are currently armed.

## The GPU-idle CloudWatch alarm (OPT-IN - see the banner above)

```bash
INSTANCE_ID=i-XXXXXXXXXXXXXXXXX AWS_REGION=<region> ENABLE_IDLE_ALARM=1 \
  [IDLE_SIGNAL=render] [IDLE_MINUTES=30] \
  ./control-plane/03-create-idle-alarm.sh
```

**`ENABLE_IDLE_ALARM=1` is required and is not this project's default** (see the
banner at the top of this document) - without it the script explains why it is
refusing and exits without calling AWS at all. To remove an alarm this script
previously created: `INSTANCE_ID=... AWS_REGION=... TEARDOWN=1
./control-plane/03-create-idle-alarm.sh` (idempotent - deleting a non-existent
alarm name is not an error).

[`03-create-idle-alarm.sh`](../control-plane/03-create-idle-alarm.sh) creates a
**per-instance** alarm named `topaz-gpu-idle-autostop-<instance-id>`. That name,
and this section's heading, are kept for continuity with the AWS resource - the
signal the alarm evaluates **by default is no longer GPU load** (see "Why the
alarm no longer defaults to GPU" below):

| Setting | Value | Why |
|---------|-------|-----|
| Signal | `IDLE_SIGNAL` (default **`render`**) | `render` keys the alarm on the `RenderActive` 1/0 metric ("is an encoder worker process alive"); `gpu` restores the legacy sub-5% `GPUUtilization` behavior. Read the rationale below before choosing `gpu`. |
| Namespace / metric | `TopazRender/GPU` / `RenderActive` (default) or `GPUUtilization` (`IDLE_SIGNAL=gpu`) - override with `METRIC_NAMESPACE`/`METRIC_NAME` | The custom metric the box publishes. `METRIC_NAME` defaults per `IDLE_SIGNAL`. Only override these together with `Config.ps1`'s matching `RenderActiveMetricName`/`MetricName` **and** the same `METRIC_NAMESPACE` passed to [`02-create-iam-role.sh`](03-phase1-instance-prep.md) (it re-scopes the instance role's `PutMetricData` grant to match), or the alarm ends up watching a metric nothing is even allowed to publish. |
| Dimension | `InstanceId=<this instance>` | Scopes the alarm to one box. |
| Statistic / period | `Maximum` / `60 s` (default `render`) or `Average` / `60 s` (`gpu`) | One data point per published minute. `Maximum`, not `Average`, for `RenderActive`: it is a 1/0 value and two pushes can land in one 60 s period, so an `Average` of `0.5` would read as "below 1" and count an actively-rendering minute as idle - `Maximum` takes the safe direction (any sample seeing a worker means the period is not idle). |
| Evaluation periods | `IDLE_MINUTES` (default `30`) | `IDLE_MINUTES` x 60 s = **`IDLE_MINUTES` minutes** sustained. |
| Threshold / operator | `< 1` (default `render`) or `< 5%` (`gpu`, legacy) | `render`: `RenderActive` sustained at `0` = no encoder worker alive = idle. `gpu`: sub-5% GPU = idle - **the "never fires during a real render" claim for this mode was measured false**, see below. |
| `treat-missing-data` | `notBreaching` | Missing data is ambiguous; do **not** stop on it. |
| Action | `arn:aws:automate:<region>:ec2:stop` | Built-in EC2 stop action; needs no IAM role. |

**This change is not live until you re-run `03-create-idle-alarm.sh`.**
`put-metric-alarm` only updates an alarm when the script actually runs again -
an alarm created under the old GPU default keeps watching `GPUUtilization`
until you re-run it, and re-running it only helps if the guest is also on a
build that publishes `RenderActive` (see "The Windows in-guest metric
publisher" below) - otherwise every evaluation period is missing data and
`notBreaching` means the alarm just sits `OK` forever.

### Why per-instance, not a shared alarm name

`put-metric-alarm` **overwrites** any existing alarm with the same
`--alarm-name`. An earlier shared name (`topaz-gpu-idle-autostop`) meant
provisioning a **second** instance silently repointed - and thereby disabled -
the first box's safety net. Keying the name on `INSTANCE_ID` gives every
instance its own alarm; upgrading an older deployment should delete the
orphaned shared-name alarm (the script prints the exact command).

### Why not CPU, whichever signal is chosen

The alarm keys on a **custom metric published from inside the guest, never on
`CPUUtilization`**. A Topaz render can peg the GPU (and, under the default
`render` signal, keep an encoder worker process alive) while the CPU sits near
idle, so a CPU-based alarm would **false-stop an active render**. CPU is simply
blind to the actual work. The whole reason the box publishes its own metrics is
so the safety net can observe that work directly, not a proxy Topaz never
reliably drives. (This is a corrected assumption - see
[Appendix A](08-appendix-a-corrections.md).)

### Why the alarm no longer defaults to GPU, and why 30 minutes / `notBreaching`

The alarm used to key on `GPUUtilization` alone, on the reasoning that "Topaz
GPU work spikes well above 5% while encoding, so a real render can never
accumulate that many continuous idle minutes." **That specific claim was
measured false on 2026-07-27**: a confirmed-healthy 4K render read
`GPUUtilization` under 5% for **25 consecutive one-minute samples**
(`14:16:25` -> `14:40:25`, mostly a literal `0%`) - five minutes short of
breaching a 30-minute window - on a box that was, by every other measure
(climbing `workerIoBytes` on the watchdog's own heartbeat throughout),
genuinely rendering. See [docs/15 §K](15-third-end-to-end-run.md) and
[docs/12](12-empirical-findings.md). The same metric is wrong in the *other*
direction too: a connected Amazon DCV session encodes the remote display on
the same GPU and holds it at 14-58% with nothing rendering at all, so a
sub-5% alarm could never fire while anyone is connected
([docs/12](12-empirical-findings.md)). Wrong in both directions is not a
safety net.

`IDLE_SIGNAL=render` (the default) fixes both problems by watching
`RenderActive` instead of GPU load - the same class of signal the watchdog
itself already trusts for its own stop decision (`CompletionSignal =
'WorkerOnly'`, see [Phase 2](04-phase2-watchdog.md)). It also happens to fix
the DCV masking problem as a side effect: DCV's own processes
(`dwm.exe`/`dcvagent.exe`) match none of `WorkerNamesLike`'s patterns, so a
connected session no longer holds the alarm's signal artificially "busy" the
way it held `GPUUtilization` up.

- **`IDLE_MINUTES` minutes of sustained idle** (default **30**) is
  deliberately long and conservative regardless of signal - the window only
  elapses when the box is genuinely doing nothing. `IDLE_MINUTES` must be a
  positive integer with no leading zeros; raise it if a slow pre-render setup
  (uploading source files, configuring the export) or a large post-render S3
  sync routinely leaves the box idle longer than the default before/after the
  render itself - see "Safety-net operational windows" below.
- **`treat-missing-data notBreaching`** means that if the metric stops arriving
  entirely (e.g. the publisher died, or the guest is running an older build
  that never publishes `RenderActive` at all), the alarm does **not** interpret
  absence as "idle" and stop the box on missing data alone. Missing data is
  ambiguous, so the alarm stays OK. (The wall-clock cap below is what covers a
  truly wedged box - and, on a guest that publishes nothing, it is the *only*
  layer still working.)
- **`IDLE_SIGNAL=gpu`** is kept only for a box whose GPU is not shared with a
  remote-display encoder. Choosing it re-enables the false-idle-during-a-real-
  render hazard measured above.

Verify the alarm:

```bash
aws cloudwatch describe-alarms --region <region> --alarm-names topaz-gpu-idle-autostop-<instance-id>
```

### Pausing the alarm during a long pre-render setup

The script also prints the exact commands to pause and resume the alarm's stop
action, for the case where you need the box to sit idle (no render running)
longer than `IDLE_MINUTES` without triggering a stop (e.g. uploading large
source files before clicking Export):

```bash
aws cloudwatch disable-alarm-actions --region <region> --alarm-names topaz-gpu-idle-autostop-<instance-id>
aws cloudwatch enable-alarm-actions  --region <region> --alarm-names topaz-gpu-idle-autostop-<instance-id>
```

Disable before the idle stretch, then re-enable right after clicking Export so
the safety net is back in place for the actual render.

**This matters more than it used to.** Under the legacy `GPUUtilization`
signal, a connected DCV session usually kept the GPU reading above 5% anyway,
so a pre-render setup window rarely tripped the alarm in practice even without
pausing it. With the default `IDLE_SIGNAL=render`, that accidental cover is
gone: `RenderActive` reads `0` for as long as no encoder worker process
exists, DCV connected or not - so the alarm can now genuinely fire during a
long setup where nobody has clicked Export yet. Pause it *before* the setup
window, not after you notice the box stopped.

## The Windows in-guest metric publisher

The alarm is only as good as the metric feeding it, and both metrics it can
watch come from [`Push-GpuMetric.ps1`](../in-guest/Push-GpuMetric.ps1),
registered by [Phase 2](04-phase2-watchdog.md) as the once-per-minute SYSTEM
task `TopazAutoStop-GpuMetric`. It now reads and publishes **two independent
signals per run**, each wrapped so a failure reading one never blocks the
other from publishing:

1. **`RenderActive`** (unit `None`, value `1`/`0`) - **the metric
   `IDLE_SIGNAL=render` evaluates.** `1` when at least one process matching
   `WorkerNamesLike` (`neuroserver.exe`, `ffmpeg.exe`) is alive anywhere on the
   box, via the new `Test-RenderWorkerPresent` helper in
   [`Config.ps1`](../in-guest/Config.ps1). This is deliberately **not** the
   watchdog's own ancestry-based `Get-TopazWorkers` - it matches by **name
   only**, and it is **stateless**, for two reasons: (a) `Get-TopazWorkers`
   relies on a `$script:KnownWorkers` table built up across polls inside one
   long-lived process, but this task is relaunched fresh **every minute**, so
   that table would always start empty and an orphaned encoder (GUI dead,
   `ffmpeg` still writing) would read as idle; (b) the watchdog and the alarm
   want **opposite biases** - the watchdog decides whether to *stop*, so it
   needs a precise signal (ancestry, so a stray unrelated process can't hold
   the box up forever), while the alarm decides whether stopping is *safe*, so
   it needs a conservative one (name-only, so a stray `ffmpeg.exe` only ever
   costs uptime, never a render). Name-only matching is also what makes it
   stateless, and it's the reason DCV's own processes
   (`dwm.exe`/`dcvagent.exe`) never match. Returns `$null` (never a guessed
   `0`) if the process query itself fails.
2. **`GPUUtilization`** (unit `Percent`) - **telemetry only; no longer used by
   the default alarm.** Published via the shared `Get-GpuUtilizationMax`
   helper in `Config.ps1`, which runs `nvidia-smi --query-gpu=utilization.gpu
   --format=csv,noheader,nounits` and reports the **maximum** value across
   **all** GPUs on the box, not just the first line - this matters on a
   multi-GPU instance (e.g. a `g5.12xlarge` with 4 GPUs), where Topaz
   typically loads a single GPU and reading only the first GPU line could
   under-report during an actively-rendering job. Still worth publishing: it
   is what exposed the 25-minute sub-5% streak documented above in the first
   place, and remains useful for reading a run back afterwards. Returns
   `$null` (rather than `0`) if the read fails, so a failed read is never
   confused with a genuinely idle GPU.

Instance id and region come from IMDSv2 via the shared `Get-Ec2Identity`
helper (also in `Config.ps1`), using ONE token for both calls. Region is read
from the dedicated `placement/region` endpoint - correct for Local Zones and
Wavelength, where stripping the trailing letter off the availability zone does
not yield a valid region - falling back to the AZ-letter-strip only if that
endpoint is unavailable. Even that fallback never guesses a malformed region
for a Local Zone/Wavelength AZ: `Convert-AzToRegion` recognizes when the
stripped candidate does not look like a standard region and leaves the region
empty (same as a full IMDS failure) instead of passing a bad `--region` to the
AWS CLI.

Each available metric is published into `TopazRender/GPU` (dimension
`InstanceId=...`) via its **own** `aws cloudwatch put-metric-data` call,
bounded to `AwsCliTimeoutSec` (default **60 s**) independently, so a hung
`aws` call on one metric cannot wedge the other or the once-a-minute scheduled
task. `RenderActive` is published **first** - it is the metric the alarm
evaluates by default, so if the minute is slow enough that only one call
lands, it should be this one.

Every external call (CIM, `nvidia-smi`, IMDS, `aws`) is wrapped in try/catch,
and the two metrics now fail **independently** - fixing a real, previously
latent bug: the script used to return early the moment `nvidia-smi` failed,
which, once an alarm keys on `RenderActive`, would have let a broken GPU
reader silently take the alarm's only working signal down with it. A failed
read publishes **nothing** for that metric that minute (never a guessed
value), so the alarm's `notBreaching` holds state instead of counting an
unreadable minute as idle. The script **always exits 0**, so a bad read never
error-spams the scheduler.

### Why a scheduled-task publisher (and not the CloudWatch agent)

On Windows there is **no native CloudWatch collector for NVIDIA GPU utilization** -
the unified CloudWatch agent's NVIDIA GPU support is **Linux-only**. So on this
Windows box the `GPUUtilization` metric has to be produced by shelling out to
`nvidia-smi` and pushing the value with the AWS CLI, on a schedule (`RenderActive`
needs no such workaround - it reads a CIM process query, not `nvidia-smi`). That
is exactly what this task does. (This corrects a common wrong assumption - see
[Appendix A](08-appendix-a-corrections.md).)

This is why [Phase 1](03-phase1-instance-prep.md) insists both `nvidia-smi.exe`
and `aws.exe` are on PATH, and why [`Install.ps1`](../in-guest/Install.ps1) warns
if they are not: without `aws.exe`, **neither** metric can publish, so the alarm
has nothing to watch on any `IDLE_SIGNAL`; without `nvidia-smi.exe`, only
`GPUUtilization` fails to publish, which matters for `IDLE_SIGNAL=gpu` but not
for the `render` default.

## Optional: the max-lifetime hard cap (Lambda) - also NOT DEPLOYED for this project

Like the idle alarm above, this is documented as a reference and is **not
deployed** here - see the banner at the top of this document and
[docs/09-appendix-b-boundaries.md](09-appendix-b-boundaries.md) for the
accepted cost of running without it.

### DANGER: a Lambda stop bypasses `Stop-Sequence.ps1` and can destroy a finished render

Read this before deploying it, and before reading the "conservative" list
further down as a safety argument.

The Lambda calls `ec2:StopInstances` **out of band**. It never consults the
guest, and an EC2-API stop triggers nothing inside the guest -
[`Register-ScheduledTasks.ps1`](../in-guest/Register-ScheduledTasks.ps1)
registers only at-startup and repeating triggers, never a shutdown-triggered
task. So when the Lambda fires, [`Stop-Sequence.ps1`](../in-guest/Stop-Sequence.ps1)
**does not run**: no rclone upload, no upload verification, no misplaced-output
recovery scan, and **no ephemeral-upload interlock**.

`OutputDir` normally sits on the instance-store scratch volume, which is
**erased the instant the instance stops**. A render that finished but has not
been uploaded and verified when the ceiling is crossed is permanently lost - no
local file, no snapshot, nothing to re-run. This is recorded, not theoretical: a
finished ~2.3 GB render was lost exactly that way on this deployment, see
[docs/16-render-loss-incident.md](16-render-loss-incident.md). And the exposure
is not rare - when an upload keeps failing, the interlock deliberately keeps the
box running with finished renders on `D:` until a human fixes it, which is
precisely the state a wall-clock Lambda stop erases.

**Prefer [`Register-TimedStop.ps1`](../in-guest/Register-TimedStop.ps1) whenever
the guest is reachable.** It is the in-guest equivalent (see
[the section below](#in-guest-alternative-register-timedstopps1)) and takes the
opposite position on purpose: it routes through `Stop-Sequence.ps1`, so it is
equally blind to render *progress* but the upload interlock still applies - a
stop that would erase an unuploaded render is **refused** and retried until the
upload succeeds. Its header states the trade in as many words: *"Erasing a
completed render to save a few dollars of instance time is not a trade this
project makes, so the cost cap yields to it."* The Lambda makes exactly that
trade. Use the Lambda only where the guest cannot be trusted to act at all, and
accept that its cap is absolute in both directions.

**Considered and rejected: a guest-set veto tag.** The obvious middle road -
have the guest tag the instance `TopazUploadPending=true` while unuploaded output
exists and have the Lambda no-op while that tag is present - was rejected
deliberately. The max-lifetime cap is the *unconditional* last-resort backstop by
design, and a guest veto turns it into a soft cap that depends on the same guest
you deployed it because you could not trust; it would also require granting the
instance role `ec2:CreateTags`, a new write permission that cuts against the
least-privilege posture recorded in
[docs/09 §4](09-appendix-b-boundaries.md). `Register-TimedStop.ps1` already is
the interlock-honoring variant, and it needs no new grant.

The Lambda's own
[README](../lambda/max-lifetime-stop/README.md) carries the same warning at the
top, with a side-by-side comparison of the two backstops.

The idle alarm cannot catch a job that stays **"stuck busy."** Under the default
`render` signal that means a hung-but-still-alive worker process - `neuroserver`
or `ffmpeg` wedged but never exiting - since `RenderActive` never drops to `0`
while the process still exists, so the alarm never fires. Previously, under the
legacy `GPUUtilization` signal, a connected DCV session was itself a "stuck
busy" case: it kept the GPU reading above 5% indefinitely with nothing actually
rendering, which is exactly the near-permanent false-busy failure mode this
document describes above. **That case is fixed by the `render` signal** - DCV's
own processes never register as a worker - but a genuinely hung *render process*
is a different, orthogonal case no idle-based signal can ever catch by design.
The optional wall-clock cap below covers exactly that.

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
  Timezone-aware UTC math. All of that is about *instance* state; none of it is
  about unuploaded output - see the DANGER block above.
- **Graceful only where "gone" is a real runtime state.** An
  `InvalidInstanceID.NotFound` (or a describe with no reservations) degrades to
  a logged no-op, because the instance genuinely may have been terminated or
  replaced. An `InvalidInstanceID.Malformed` id does **not**: a structurally
  invalid id can only be a typo, no later invocation will do better, and a cap
  that reports SUCCESS every 30 minutes while guarding nothing is the worst way
  to be broken - so it fails the invocation, where the function's `Errors`
  metric can see it. Alarm on that metric if you deploy this; nothing in this
  repo creates that alarm for you.
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

### In-guest alternative: `Register-TimedStop.ps1`

For a deployment where the control plane cannot be reached to deploy the
Lambda above, [`Register-TimedStop.ps1`](../in-guest/Register-TimedStop.ps1)
is an in-guest wall-clock backstop that does a similar job locally: it
registers a SYSTEM scheduled task that fires `Stop-Sequence.ps1 -Reason
maxlifetime -IgnoreDryRun` a fixed number of hours from now (default **4**),
**bypassing `DryRun`** on purpose - a backstop that respected `DryRun` would
not be one - and then following the same `StopStrategy` plan as every other
stop. It is **blind to render state**: none of the watchdog's debounce,
stall, or unlock-gate logic applies, so if a render is still running when it
fires, that render is killed along with the instance.

**One guard it does not bypass, and this is the whole difference from the
Lambda above:** going through `Stop-Sequence.ps1` means the ephemeral upload
interlock still applies. If `OutputDir` is on the scratch volume and its
finished renders have not been uploaded and verified, the stop is **refused** -
so the task is registered with a repeating trigger rather than as a true
one-shot, and retries every `RetryIntervalMinutes` (default 15) until the
upload succeeds and the stop can go through. A cost cap that fired once, was
refused, and never tried again would not cap anything.

Cancel it (`.\Register-TimedStop.ps1 -Cancel`) once the real watchdog is armed
and verified - see its own header comment for the full reasoning, including a
real near-miss recorded on this deployment.

## Safety-net operational windows (only relevant if you opt back in)

Both out-of-band safety nets watch **wall-clock/render-presence state**, not
"is a render actually supposed to be happening" - so two ordinary operational
windows can trip the idle alarm if you are not deliberate about them. Neither
hazard below applies to this project as currently run, since neither safety
net is armed - this section exists for whoever opts back in:

- **Pre-render setup.** The idle alarm has no concept of "the operator is still
  setting up." If uploading source files or configuring the export keeps the box
  idle (no encoder worker alive) longer than `IDLE_MINUTES` **before** Export is
  clicked, the alarm will stop the box out from under you mid-setup. **This
  hazard is worse than it used to be, and deliberately so.** Under the legacy
  `GPUUtilization` signal, a connected DCV session usually kept the GPU reading
  above 5% during setup anyway, so this rarely fired in practice. Under the
  default `render` signal there is no such accidental cover - `RenderActive`
  reads `0` regardless of DCV state whenever no worker process exists - so the
  alarm can now genuinely fire during a long pre-render setup. Pause it first
  with the `disable-alarm-actions` command above, and re-enable it right after
  clicking Export.
- **Post-render S3 sync.** If `S3SyncTarget` is configured
  ([Phase 3](05-phase3-stop-sequence.md)), no encoder worker has existed since
  the debounce window started - well before `Stop-Sequence.ps1` even begins the
  sync - so the box already reads idle for that entire stretch under the
  default signal too. A large sync of big output files can push the
  *cumulative* idle time (debounce + unlock wait + sync) past `IDLE_MINUTES`,
  and the idle alarm does not know a sync is in flight: its `ec2:stop` action
  would abruptly stop the instance mid-sync, ahead of `Stop-Sequence.ps1`'s own
  graceful `StopStrategy` plan. Size `IDLE_MINUTES` generously (covering
  debounce + unlock wait + your largest expected sync) whenever `S3SyncTarget`
  is set.

## The three layers, and which are actually armed here

| Layer | Fires when | Plane | Armed on this project? |
|-------|-----------|-------|------------------------|
| Watchdog (primary) | Queue drained / stalled + files unlocked + upload verified | In-guest | **Yes - the only sanctioned auto-stop.** |
| Idle alarm (`topaz-gpu-idle-autostop-*`) | `IDLE_MINUTES` min sustained idle - default `render` signal (`RenderActive=0`, no worker alive); legacy `gpu` signal (sub-5% GPU) (default 30 min) | Control plane | **No - opt-in only, decided 2026-07-28. Deleted for this instance.** |
| Max-lifetime Lambda (optional) | Instance age >= ceiling, any GPU load | Control plane | **No - not deployed.** |

Only the watchdog layer is armed for this project. See
[docs/09-appendix-b-boundaries.md](09-appendix-b-boundaries.md) for what that
means in practice: with no idle alarm and no Lambda, a dead watchdog, an
unopened Topaz session, or a failed render leaves nothing to stop the box but
a human.

**None of these three layers is gated by `Config.ps1`'s `DryRun` switch** - only
the in-guest watchdog/stop-sequence path is. See the `DryRun` caveat in
[Phase 3](05-phase3-stop-sequence.md).

**And neither control-plane layer is gated by the ephemeral upload interlock
either** - both stop the instance through the EC2 API, so `Stop-Sequence.ps1`
never runs and unuploaded renders on the scratch volume are erased with the
volume. That is a stronger statement than the `DryRun` caveat and it is the
reason the two rows above are worth reading twice before arming: see the
[DANGER block](#danger-a-lambda-stop-bypasses-stop-sequenceps1-and-can-destroy-a-finished-render)
and [docs/16](16-render-loss-incident.md).

Continue to [Phase 5 - notifications](07-phase5-notifications.md).
