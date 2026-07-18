# max-lifetime-stop (OPTIONAL hard cap)

Last-resort cost safety net for the Topaz auto-stop pipeline. It force-stops the
target EC2 instance once it has been **running longer than an absolute ceiling**,
regardless of what the GPU is doing.

## What it does

Every scheduled invocation it:

1. Reads the target instance id and the ceiling from its environment.
2. Calls `ec2:DescribeInstances` to read the instance's `LaunchTime` and state.
3. Computes `age = now(UTC) - LaunchTime`.
4. If the instance is **`running`** and `age >= MAX_LIFETIME_HOURS`, it calls
   `ec2:StopInstances`. Otherwise it does nothing.

It is deliberately conservative:

- **Stop only, never terminate.**
- **Idempotent / safe:** if the instance is already `stopping` / `stopped`
  (or otherwise not `running`), it is a no-op.
- **Timezone-aware:** all math uses `datetime.now(timezone.utc)` against the
  tz-aware `LaunchTime` boto3 returns.
- **Graceful on missing instance:** if the id can't be found or the describe
  returns no reservations, it logs and returns a no-op decision (no crash).

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

`action` is one of `stopped` | `noop` | `error`; `reason` explains the decision
(`over-ceiling`, `under-ceiling`, `already-not-running`, `not-running`,
`instance-not-found`, `no-launch-time`).

## Why it exists (OPTIONAL / complementary)

This Lambda is **optional** and **complementary** to the primary idle-shutdown
path (the on-box watchdog + the idle CloudWatch alarm). Those stop the box when
the GPU goes idle. This one catches the case they can't see: a job that stays
**"stuck busy" and never goes idle**, so the idle alarm never fires. If you don't
want a hard wall-clock cap, you can skip deploying it entirely.

## Required environment variables

| Variable             | Required | Default | Purpose                                                        |
|----------------------|----------|---------|----------------------------------------------------------------|
| `TARGET_INSTANCE_ID` | yes      | —       | Instance id to guard (`i-...`).                                |
| `MAX_LIFETIME_HOURS` | no       | `12`    | Absolute run-time ceiling, in hours.                           |
| `AWS_TARGET_REGION`  | no       | —       | Region of the target instance. If unset, boto3 resolves it from the Lambda runtime (`AWS_REGION`); the region is never hardcoded. |

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

- zips this source, creates the execution role + function (`python3.12`,
  handler `handler.handler`), and
- creates an **EventBridge Scheduler** schedule that invokes the function on a
  fixed recurring cadence (the script's default expression is `rate(30 minutes)`),
  **falling back** to a classic CloudWatch Events rule when EventBridge Scheduler
  isn't usable (e.g. no `SCHEDULER_ROLE_ARN` supplied).

Because the check is cheap and idempotent, running it on a short cadence just
means the instance is stopped promptly once it crosses the ceiling.

Deploy example:

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

It prints the returned decision dict as JSON. Set `MAX_LIFETIME_HOURS=0.0001` to
exercise the stop path against a running test instance (it will actually issue a
stop), or leave it at the default to observe a `noop`.
