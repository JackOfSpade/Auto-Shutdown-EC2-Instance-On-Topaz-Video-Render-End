"""
max-lifetime-stop Lambda
========================

OPTIONAL last-resort safety net for the Topaz auto-stop pipeline.

*** DANGER: A STOP FROM THIS LAMBDA CAN PERMANENTLY DESTROY A FINISHED RENDER. ***

This function calls ec2:StopInstances directly, from the control plane. It never
consults the guest, and nothing in the guest is triggered by an EC2-API stop
(Register-ScheduledTasks.ps1 registers no shutdown-triggered task), so
Stop-Sequence.ps1 DOES NOT RUN: no rclone upload, no upload verification, no
misplaced-output recovery scan, and -- the one that matters -- no ephemeral
upload interlock. OutputDir normally lives on the instance-store scratch volume,
which is ERASED the instant the instance stops. A render that has finished but
has not been uploaded and verified when the ceiling is crossed is simply gone:
no local file, no snapshot, nothing to re-run. That is not hypothetical -- a
finished ~2.3 GB render was already lost that way once on this deployment; see
docs/16-render-loss-incident.md.

The in-guest equivalent, in-guest/Register-TimedStop.ps1, takes the opposite
position on purpose: it fires Stop-Sequence.ps1, so the interlock still applies
and a stop that would erase an unuploaded render is REFUSED and retried instead.
PREFER Register-TimedStop.ps1 whenever the guest is reachable. Deploy this Lambda
only when the guest cannot be trusted to act at all -- and accept that its cap is
absolute in both directions: it will always stop the box, including when stopping
the box is the wrong thing to do.

Note the topology this actually sits in (as of 2026-07-28): the watchdog's own
render-queue completion detection is the ONLY armed stop path. The GPU-idle
CloudWatch alarm is opt-in and not armed here -- control-plane/03-create-idle-alarm.sh
refuses to create it without ENABLE_IDLE_ALARM=1, and the alarm that once existed
was deleted (see the banner at the top of docs/06-phase4-safety-net.md). So this
Lambda is not "complementary" to an idle alarm on this deployment: once deployed
it is the only *scheduled* thing that can stop the box, and its blindness -- to
render progress and to pending uploads alike -- weighs correspondingly more.

What it is for: the pathological case in-guest completion detection cannot see --
a job that stays "stuck busy" and never finishes, so the guest never decides to
stop anything and the box runs forever. It enforces a hard, absolute ceiling on
wall-clock run time: if the target instance has been running (LaunchTime) longer
than MAX_LIFETIME_HOURS, force-stop it -- no matter what the GPU is doing.

Within that deliberately narrow job it is dumb and careful:
  * only ever calls ec2:StopInstances (never terminate),
  * idempotent -- if the instance is already stopping/stopped it does nothing,
  * timezone-aware UTC math, and
  * degrades to a logged no-op if the instance genuinely no longer exists
    (a structurally invalid id raises instead -- see _describe_instance).
"Dumb and careful" is scoped to instance/GPU state only. It has never said
anything about unuploaded output; the DANGER block above is what governs there.

Environment variables
---------------------
  TARGET_INSTANCE_ID   Required. The EC2 instance id to guard (i-...).
                       For compatibility with 04-deploy-max-lifetime-lambda.sh
                       the legacy name INSTANCE_ID is also accepted.
  MAX_LIFETIME_HOURS   Optional. Absolute run-time ceiling in hours. Default 12.
  AWS_TARGET_REGION    Optional. Region of the target instance. If unset, boto3
                       resolves the region from the standard Lambda runtime env
                       (AWS_REGION); the region is never hardcoded.

Both TARGET_INSTANCE_ID and AWS_TARGET_REGION are stripped before use, because
an unnoticed stray space in either one breaks the guard on every invocation.
"""

import logging
import math
import os
from datetime import UTC, datetime

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# States in which the instance is (or is becoming) not-running. If the instance
# is in any of these, there is nothing for us to do.
_NON_RUNNING_STATES = {"pending", "stopping", "stopped", "shutting-down", "terminated"}

DEFAULT_MAX_LIFETIME_HOURS = 12.0


def _utc_now() -> datetime:
    """Return the current UTC time.

    Kept as a tiny seam so the safety-critical ceiling boundary can be tested
    against a fixed instant instead of depending on wall-clock scheduling.
    """
    return datetime.now(UTC)


def _get_instance_id() -> str:
    """Resolve the target instance id from env (TARGET_INSTANCE_ID preferred).

    Each candidate is stripped *before* the `or` fallback decision (mirroring
    _get_max_lifetime_hours's whitespace handling): otherwise a whitespace-only
    TARGET_INSTANCE_ID is truthy and wins the `or` over a valid legacy
    INSTANCE_ID, then strips down to '' -- silently disabling the guard
    (describe_instances([""]) -> InvalidInstanceID.Malformed -> perpetual noop).
    """
    target = (os.environ.get("TARGET_INSTANCE_ID") or "").strip()
    legacy = (os.environ.get("INSTANCE_ID") or "").strip()
    instance_id = target or legacy
    if not instance_id:
        raise ValueError(
            "No target instance id configured: set TARGET_INSTANCE_ID "
            "(or INSTANCE_ID) in the Lambda environment."
        )
    return instance_id


def _get_max_lifetime_hours() -> float:
    """Read MAX_LIFETIME_HOURS from env, falling back to the default on any issue."""
    raw = os.environ.get("MAX_LIFETIME_HOURS")
    if raw is None or raw.strip() == "":
        return DEFAULT_MAX_LIFETIME_HOURS
    try:
        hours = float(raw)
    except (TypeError, ValueError):
        logger.warning(
            "MAX_LIFETIME_HOURS=%r is not a number; using default %.1f",
            raw,
            DEFAULT_MAX_LIFETIME_HOURS,
        )
        return DEFAULT_MAX_LIFETIME_HOURS
    if not math.isfinite(hours):
        # float("nan")/float("inf") both parse fine but would break the ceiling
        # check below: `age_hours < nan` is always False (stops immediately on
        # every invocation) and `age_hours < inf` is always True (cap silently
        # disabled). Reject both the same way we reject non-positive values.
        logger.warning(
            "MAX_LIFETIME_HOURS=%s is not finite; using default %.1f",
            hours,
            DEFAULT_MAX_LIFETIME_HOURS,
        )
        return DEFAULT_MAX_LIFETIME_HOURS
    if hours <= 0:
        logger.warning(
            "MAX_LIFETIME_HOURS=%s is not positive; using default %.1f",
            hours,
            DEFAULT_MAX_LIFETIME_HOURS,
        )
        return DEFAULT_MAX_LIFETIME_HOURS
    return hours


def _ec2_client():
    """Build an EC2 client. Region comes from AWS_TARGET_REGION if set, else the
    standard boto3/Lambda resolution (AWS_REGION). Never hardcoded.

    The value is stripped for the same reason _get_instance_id strips its
    candidates: a console edit or a shell variable can leave stray whitespace,
    and boto3.client("ec2", region_name="  us-east-1 ") raises
    InvalidRegionError on EVERY invocation, before describe_instances -- so the
    cap never runs at all. Stripping to "" (rather than passing the padded
    value) lets the `if region:` guard below fall through to boto3's standard
    region resolution, which is the sane reading of "the operator set nothing".
    """
    region = (os.environ.get("AWS_TARGET_REGION") or "").strip()
    if region:
        return boto3.client("ec2", region_name=region)
    return boto3.client("ec2")


def _describe_instance(ec2, instance_id):
    """Return the instance dict, or None if the instance genuinely does not exist.

    The two InvalidInstanceID.* codes are deliberately NOT handled the same way,
    because they are not the same kind of event:

      * NotFound is a legitimate runtime condition -- the guarded instance was
        terminated or replaced -- so it degrades to a no-op. It is logged at
        ERROR rather than WARNING, and names the resolved region, because the
        other way to reach it is a wrong-region deploy: then every scheduled
        tick no-ops while reporting SUCCESS, the Errors metric stays flat, and
        the box runs forever. One greppable line is what makes a dead safety
        net visible at all (see the README's Monitoring section).
      * Malformed can only ever be a configuration error -- a typo'd
        TARGET_INSTANCE_ID edited straight into the Lambda console. No future
        invocation will do better, so it re-raises and the invocation is
        recorded as FAILED. That is exactly the "perpetual noop" hazard
        _get_instance_id's docstring already calls out; swallowing Malformed
        here re-created it for any structurally invalid id.
    """
    try:
        response = ec2.describe_instances(InstanceIds=[instance_id])
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "")
        if code == "InvalidInstanceID.NotFound":
            logger.error(
                "Instance %s does not exist in region %s (%s); the max-lifetime "
                "cap is guarding nothing. Check TARGET_INSTANCE_ID and "
                "AWS_TARGET_REGION.",
                instance_id,
                getattr(ec2.meta, "region_name", "<unresolved>"),
                code,
            )
            return None
        if code == "InvalidInstanceID.Malformed":
            logger.error(
                "Configured instance id %r is structurally invalid (%s); failing "
                "this invocation deliberately, so a mistyped id shows up on the "
                "function's Errors metric instead of no-opping successfully "
                "forever.",
                instance_id,
                code,
            )
        raise

    reservations = response.get("Reservations", [])
    if not reservations:
        logger.warning("No reservations returned for instance %s.", instance_id)
        return None
    instances = reservations[0].get("Instances", [])
    if not instances:
        logger.warning("Reservation for %s contained no instances.", instance_id)
        return None
    return instances[0]


def handler(event, context):
    """Lambda entrypoint. Force-stop the target instance if it has been running
    at or beyond the configured max-lifetime ceiling. Returns a small decision dict."""
    instance_id = _get_instance_id()
    max_hours = _get_max_lifetime_hours()
    now = _utc_now()

    logger.info(
        "max-lifetime-stop invoked: instance=%s ceiling=%.2fh now=%s",
        instance_id,
        max_hours,
        now.isoformat(),
    )

    ec2 = _ec2_client()
    instance = _describe_instance(ec2, instance_id)

    if instance is None:
        logger.info("Nothing to do: instance %s not found.", instance_id)
        return {
            "instance_id": instance_id,
            "action": "noop",
            "reason": "instance-not-found",
            "max_lifetime_hours": max_hours,
        }

    state = instance.get("State", {}).get("Name", "unknown")
    launch_time = instance.get("LaunchTime")  # boto3 returns a tz-aware datetime

    if launch_time is None:
        logger.warning("Instance %s has no LaunchTime; skipping.", instance_id)
        return {
            "instance_id": instance_id,
            "state": state,
            "action": "noop",
            "reason": "no-launch-time",
            "max_lifetime_hours": max_hours,
        }

    age_seconds = (now - launch_time).total_seconds()
    age_hours = age_seconds / 3600.0

    result = {
        "instance_id": instance_id,
        "state": state,
        "launch_time": launch_time.isoformat(),
        "age_hours": round(age_hours, 3),
        "max_lifetime_hours": max_hours,
    }

    logger.info(
        "Instance %s state=%s launch=%s age=%.3fh ceiling=%.2fh",
        instance_id,
        state,
        launch_time.isoformat(),
        age_hours,
        max_hours,
    )

    # Idempotency / safety: only a genuinely running instance is a candidate.
    if state != "running":
        # The two reason strings are near-identical and both are published in
        # the README, so they stay as they are; the LOG line is where the two
        # cases are told apart. 'not-running' means EC2 reported a state
        # outside the set this handler knows (or the response carried no State
        # at all, which reads as 'unknown') -- worth a WARNING, because it is
        # either a new EC2 state or a malformed response, not a routine no-op.
        known = state in _NON_RUNNING_STATES
        reason = "already-not-running" if known else "not-running"
        if known:
            logger.info(
                "Instance %s is %s (not 'running'); nothing to stop.",
                instance_id,
                state,
            )
        else:
            logger.warning(
                "Instance %s reports the unrecognized state %r (not 'running'); "
                "nothing to stop.",
                instance_id,
                state,
            )
        result.update(action="noop", reason=reason)
        return result

    if age_hours < max_hours:
        logger.info(
            "Instance %s under ceiling (%.3fh < %.2fh); leaving it running.",
            instance_id,
            age_hours,
            max_hours,
        )
        result.update(action="noop", reason="under-ceiling")
        return result

    # Over the ceiling and still running -> force stop.
    logger.warning(
        "Instance %s has run %.3fh (>= ceiling %.2fh); calling stop_instances.",
        instance_id,
        age_hours,
        max_hours,
    )
    try:
        stop_response = ec2.stop_instances(InstanceIds=[instance_id])
    except ClientError as exc:
        # Re-raise so the invocation is recorded as failed (and can be alarmed
        # on / retried); the max-lifetime cap must not silently swallow a
        # failed stop. The decision `result` is intentionally not returned here.
        logger.error("stop_instances failed for %s: %s", instance_id, exc)
        raise

    transitions = {
        i.get("InstanceId"): i.get("CurrentState", {}).get("Name")
        for i in stop_response.get("StoppingInstances", [])
    }
    logger.info(
        "stop_instances accepted for %s; transitions=%s", instance_id, transitions
    )

    result.update(action="stopped", reason="over-ceiling", stopping=transitions)
    return result


if __name__ == "__main__":
    # Local smoke test:
    #   TARGET_INSTANCE_ID=i-0123... AWS_TARGET_REGION=us-east-1 python handler.py
    import json

    print(json.dumps(handler({}, None), indent=2, default=str))
