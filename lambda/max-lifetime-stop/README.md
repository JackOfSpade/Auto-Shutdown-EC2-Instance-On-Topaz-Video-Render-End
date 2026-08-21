# max-lifetime-stop (OPTIONAL hard cap)

Last-resort cost safety net for the Topaz auto-stop pipeline. It force-stops the
target EC2 instance once it has been **running longer than an absolute ceiling**,
regardless of what the GPU is doing.

## DANGER - a stop from this Lambda can permanently destroy a finished render

**A Lambda-initiated stop bypasses `Stop-Sequence.ps1` entirely.**

This function calls `ec2:StopInstances` from the control plane. It never consults
the guest, and an EC2-API stop triggers nothing inside the guest -
`Register-ScheduledTasks.ps1` registers no shutdown-triggered task. So when this
Lambda fires, `Stop-Sequence.ps1` **does not run**, which means:

- **no rclone upload** of finished renders,
- **no upload verification**,
- **no misplaced-output recovery scan**,
- and **no ephemeral-upload interlock**.

`OutputDir` normally sits on the instance-store scratch volume, which AWS
**erases the instant the instance stops**. A render that has finished but has not
been uploaded and verified when the ceiling is crossed is simply gone: no local
file, no snapshot, nothing to re-run. That is not a hypothetical - a finished
**~2.3 GB render was already lost exactly that way** on this deployment; see
[`docs/16-render-loss-incident.md`](../../docs/16-render-loss-incident.md).

The worst case is concrete and easy to reach, not exotic. When an upload keeps
failing, the in-guest interlock **deliberately keeps the box running** (and
billing) with finished renders sitting on `D:` until someone fixes the upload.
That is precisely the state a wall-clock Lambda stop erases - the cost cap fires
exactly when the render is most exposed.

### Prefer `Register-TimedStop.ps1` when the guest is reachable

[`in-guest/Register-TimedStop.ps1`](../../in-guest/Register-TimedStop.ps1) is the
in-guest stand-in for this Lambda, and it takes the opposite position on purpose.
It fires `Stop-Sequence.ps1 -Reason maxlifetime -IgnoreDryRun`, so it is equally
blind to render *progress* - but the ephemeral upload interlock still applies: a
stop that would erase an unuploaded render is **refused**, and retried on a
repeating trigger until the upload succeeds. Its own header states the trade
plainly - *"Erasing a completed render to save a few dollars of instance time is
not a trade this project makes, so the cost cap yields to it."* This Lambda makes
exactly that trade.

So:

- **Guest reachable** (you can get a session on the box, or run scripts there):
  use `Register-TimedStop.ps1`. Its cap is soft against the interlock, and that
  softness is the point.
- **Guest not reachable, or not trusted to act at all** (wedged guest, dead
  watchdog, no console access): this Lambda is what is left. Deploy it knowing
  its cap is absolute in **both** directions - it will stop the box, including
  when stopping the box destroys output.

### Considered and rejected: a guest-set veto tag

The obvious middle road is to let the guest veto: have the watchdog set an EC2
tag (`TopazUploadPending=true`) while unuploaded output exists on the ephemeral
volume, have this handler no-op while that tag is present, and bound the veto
with a grace multiplier. **Rejected.** The max-lifetime cap is the unconditional
last-resort backstop *by design* - a guest veto converts it into a soft cap,
which is exactly the property it exists to not have, and the guest whose upload
state you would be trusting is the same guest you deployed this because you could
not trust. It would also require granting the instance role `ec2:CreateTags`, a
new write permission that cuts against the least-privilege posture recorded in
[`docs/09-appendix-b-boundaries.md` §4](../../docs/09-appendix-b-boundaries.md),
while a guest that silently *could not* tag would degrade straight back to
today's behavior. `Register-TimedStop.ps1` already is the interlock-honoring
variant, and it needs no new grant - use it instead of softening this one.

## What it does

Every scheduled invocation it:

1. Reads the target instance id and the ceiling from its environment.
2. Calls `ec2:DescribeInstances` to read the instance's `LaunchTime` and state.
3. Computes `age = now(UTC) - LaunchTime`.
4. If the instance is **`running`** and `age >= MAX_LIFETIME_HOURS`, it calls
   `ec2:StopInstances`. Otherwise it does nothing.

Within that deliberately narrow job it is conservative:

- **Stop only, never terminate.**
- **Idempotent / safe:** if the instance is already `stopping` / `stopped`
  (or otherwise not `running`), it is a no-op.
- **Timezone-aware:** all math uses `datetime.now(UTC)` against the
  tz-aware `LaunchTime` boto3 returns.
- **Graceful when the instance is genuinely gone:** an
  `InvalidInstanceID.NotFound` or a describe with no reservations logs and
  returns a no-op decision (no crash). A **structurally invalid** id
  (`InvalidInstanceID.Malformed`) is treated as the configuration error it can
  only be, and fails the invocation instead - see the error contract below.

None of that says anything about unuploaded output. Read the DANGER block above
before treating this list as a safety argument.

Every invocation returns a small decision dict, e.g.:

```json
{
  "instance_id": "i-0123456789abcdef0",
  "state": "running",
  "launch_time": "2026-07-18T00:00:00+00:00",
  "age_hours": 13.42,
  "max_lifetime_hours": 12.0,
  "action": "stopped",
  "reason": "over-ceiling",
  "stopping": { "i-0123456789abcdef0": "stopping" }
}
```

`action` is one of `stopped` | `noop`; `reason` explains the decision
(`over-ceiling`, `under-ceiling`, `already-not-running`, `not-running`,
`instance-not-found`, `no-launch-time`). `already-not-running` is a state this
handler knows (`pending`/`stopping`/`stopped`/`shutting-down`/`terminated`);
`not-running` is anything else - a state EC2 added later, or a response that
carried no `State` at all, which is logged at `WARNING` as an unrecognized
state.

### Error contract: when there is no decision dict at all

There is no `action="error"` value. Two failures deliberately produce **no
decision dict**, re-raising instead so the Lambda invocation is recorded as
**failed** (and can be alarmed on / retried):

- **`ec2:StopInstances` fails.** The cap must not silently swallow a failed
  stop, so the `ClientError` propagates. The decision `result` is intentionally
  not returned.
- **`ec2:DescribeInstances` fails with anything other than
  `InvalidInstanceID.NotFound`.** A permissions problem (`UnauthorizedOperation`
  - the likeliest one here, given the tag-scoped policy below), throttling, or a
  bad region/endpoint all propagate. So does `InvalidInstanceID.Malformed`,
  which can only ever be a typo'd instance id: no future invocation would do
  better, and a "successful" no-op every 30 minutes forever is the worst
  possible way to report a dead safety net.

Only `InvalidInstanceID.NotFound` and an empty describe response degrade to a
noop decision dict (`reason: "instance-not-found"`), because the instance really
may have been terminated or replaced. That case is logged at `ERROR` with the
resolved region, precisely because the *other* way to reach it is a wrong-region
deploy.

### Monitoring

A wall-clock cap that is quietly doing nothing looks exactly like a wall-clock
cap that has nothing to do. Nothing in this repo creates these alarms for you;
if you deploy the Lambda, create them:

- An alarm on the function's **`Errors`** metric (`>= 1`). This is what catches
  a malformed instance id, a padded/invalid `AWS_TARGET_REGION`, a missing
  `ec2:StopInstances` grant, and every unexpected `ClientError`.
- A **metric filter** on the log group for `does not exist in region` (the
  not-found line). A persistent hit means the function is running happily
  against an instance that isn't there - a typo, a wrong region, or a replaced
  instance - and no `Errors` datapoint will ever tell you.

## Why it exists (OPTIONAL), and what is actually armed here

**Read this before believing this Lambda is a redundant backstop.** As of
2026-07-28 on this deployment, the **watchdog's own render-queue completion
detection is the only armed stop path**:

- the GPU-idle CloudWatch alarm is **opt-in and not armed** -
  `control-plane/03-create-idle-alarm.sh` refuses to create or update anything
  without `ENABLE_IDLE_ALARM=1`, and the alarm that previously existed for this
  instance was deleted;
- the in-guest wall-clock timed stop was removed (2026-07-27) - as a one-shot
  task, which is what it then was; `Register-TimedStop.ps1` now arms a
  **repeating** trigger (see below), so re-arming it today is not re-arming the
  same thing;
- and this Lambda is **not deployed**.

See the banner at the top of
[`docs/06-phase4-safety-net.md`](../../docs/06-phase4-safety-net.md), which is
the single source of truth for what is armed.

So this Lambda is **not** "complementary to the idle alarm" here. Deploy it and
it becomes the only *scheduled* thing that can stop the box - and the only stop
path that bypasses the upload gate. Its blindness weighs correspondingly more.

What it is for: the case in-guest completion detection cannot see - a job that
stays **"stuck busy"** and never finishes (a wedged `neuroserver`/`ffmpeg` that
never exits), so nothing in the guest ever decides to stop anything and the box
bills forever. If you do not want a hard wall-clock cap at all, skip deploying
it.

## Relationship to the in-guest timed stop

| | `Register-TimedStop.ps1` (in-guest) | This Lambda (control plane) |
|---|---|---|
| Runs | SYSTEM scheduled task, repeating trigger | EventBridge schedule, `rate(30 minutes)` |
| Stop path | `Stop-Sequence.ps1` -> `StopStrategy` | `ec2:StopInstances` directly |
| Blind to render progress | Yes, deliberately | Yes, deliberately |
| Honors the ephemeral upload interlock | **Yes** - refuses and retries | **No** - stops regardless |
| Shares fate with the guest | Yes (a dead guest cannot fire it) | No |
| Use when | The guest is reachable and trusted to act | It is not |

Both exist because they fail differently. `Register-TimedStop.ps1` cannot help
you if the guest is wedged badly enough that its scheduled task never runs; this
Lambda cannot protect output that the guest never got to upload.

## Required environment variables

| Variable             | Required | Default | Purpose                                                        |
|----------------------|----------|---------|----------------------------------------------------------------|
| `TARGET_INSTANCE_ID` | yes      | —       | Instance id to guard (`i-...`).                                |
| `MAX_LIFETIME_HOURS` | no       | `12`    | Absolute run-time ceiling, in hours.                           |
| `AWS_TARGET_REGION`  | no       | —       | Region of the target instance. If unset, boto3 resolves it from the Lambda runtime (`AWS_REGION`); the region is never hardcoded. |

Both `TARGET_INSTANCE_ID` and `AWS_TARGET_REGION` are stripped before use: a
stray space is trivially introduced by a console edit, and an unstripped one
breaks the guard on every invocation (an empty-after-strip id disables it, a
padded region makes client construction raise before the check ever runs).

> Compatibility: the deploy script `../../control-plane/04-deploy-max-lifetime-lambda.sh`
> currently injects the id as `INSTANCE_ID` and the region as `AWS_TARGET_REGION`.
> The handler therefore accepts `INSTANCE_ID` as a fallback for
> `TARGET_INSTANCE_ID`, so it works with that script out of the box. Prefer
> `TARGET_INSTANCE_ID` for new deployments.

## IAM permissions

The Lambda execution role needs:

- `ec2:DescribeInstances` — to read `LaunchTime` and state.
- `ec2:StopInstances` — to enforce the cap.
- `logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents` — CloudWatch Logs.

These are already codified in
`../../control-plane/iam/lambda-execution-policy.json`. Note that the
`ec2:StopInstances` statement there is scoped by a condition to instances tagged
`AutoStopEligible=true`, so the target instance must carry that tag for the stop
to succeed.

## Scheduling

Deployed and scheduled by
`../../control-plane/04-deploy-max-lifetime-lambda.sh`, which:

- zips only `handler.py` (not the test suite or dev-only files), creates the
  execution role + function (`python3.12`, handler `handler.handler`), and
- creates an **EventBridge Scheduler** schedule that invokes the function on a
  fixed recurring cadence (the script's default expression is `rate(30 minutes)`),
  **falling back** to a classic CloudWatch Events rule when EventBridge Scheduler
  isn't usable (e.g. no `SCHEDULER_ROLE_ARN` supplied).

Because the check is cheap and idempotent, running it on a short cadence just
means the instance is stopped promptly once it crosses the ceiling.

Deploy example (re-read the DANGER block above first - this command arms a stop
path that does not wait for an upload):

```bash
INSTANCE_ID=i-0123456789abcdef0 AWS_REGION=us-east-1 MAX_LIFETIME_HOURS=12 \
  ./control-plane/04-deploy-max-lifetime-lambda.sh
```

## Test locally

The handler has a `__main__` smoke test that just runs the decision against a
real instance using your local AWS credentials:

```bash
TARGET_INSTANCE_ID=i-0123456789abcdef0 AWS_TARGET_REGION=us-east-1 \
  python lambda/max-lifetime-stop/handler.py
```

It prints the returned decision dict as JSON. Leave `MAX_LIFETIME_HOURS` at the
default to observe a `noop`. Setting `MAX_LIFETIME_HOURS=0.0001` exercises the
stop path, and **really stops the instance** - with no upload and no interlock,
per the DANGER block above, so only ever point that at a scratch instance with
nothing on its ephemeral volume.

The smoke test needs **Python 3.11+** locally (`handler.py` uses the
`datetime.UTC` alias, matching the `python3.12` Lambda runtime). Ruff's
configuration for this directory lives in `pyproject.toml`; there is
deliberately no pytest configuration there. CI runs `python -m ruff check
lambda/` and `python -m pytest lambda/ -q` from the repo root.
