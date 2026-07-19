"""
max-lifetime-stop Lambda
========================

OPTIONAL last-resort safety net for the Topaz auto-stop pipeline.

The on-box watchdog + idle CloudWatch alarm normally stop the instance once the
GPU goes idle. This Lambda catches the pathological case those miss: a job that
stays "stuck busy" and never goes idle, so the idle alarm never fires and the
box runs forever. It enforces a hard, absolute ceiling on wall-clock run time:
if the target instance has been running (LaunchTime) longer than
MAX_LIFETIME_HOURS, force-stop it -- no matter what the GPU is doing.

It is deliberately dumb and safe:
  * only ever calls ec2:StopInstances (never terminate),
  * idempotent -- if the instance is already stopping/stopped it does nothing,
  * timezone-aware UTC math, and
  * degrades gracefully if the instance can't be found.

Environment variables
---------------------
  TARGET_INSTANCE_ID   Required. The EC2 instance id to guard (i-...).
                       For compatibility with 04-deploy-max-lifetime-lambda.sh
                       the legacy name INSTANCE_ID is also accepted.
  MAX_LIFETIME_HOURS   Optional. Absolute run-time ceiling in hours. Default 12.
  AWS_TARGET_REGION    Optional. Region of the target instance. If unset, boto3
                       resolves the region from the standard Lambda runtime env
                       (AWS_REGION); the region is never hardcoded.
"""

import logging
import math
import os
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# States in which the instance is (or is becoming) not-running. If the instance
# is in any of these, there is nothing for us to do.
_NON_RUNNING_STATES = {"pending", "stopping", "stopped", "shutting-down", "terminated"}

DEFAULT_MAX_LIFETIME_HOURS = 12.0


def _get_instance_id() -> str:
    """Resolve the target instance id from env (TARGET_INSTANCE_ID preferred)."""
    instance_id = os.environ.get("TARGET_INSTANCE_ID") or os.environ.get("INSTANCE_ID")
    if not instance_id:
        raise ValueError(
            "No target instance id configured: set TARGET_INSTANCE_ID "
            "(or INSTANCE_ID) in the Lambda environment."
        )
    return instance_id.strip()


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
    standard boto3/Lambda resolution (AWS_REGION). Never hardcoded."""
    region = os.environ.get("AWS_TARGET_REGION")
    if region:
        return boto3.client("ec2", region_name=region)
    return boto3.client("ec2")


def _describe_instance(ec2, instance_id):
    """Return the instance dict, or None if it does not exist / has no reservation."""
    try:
        response = ec2.describe_instances(InstanceIds=[instance_id])
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "")
        if code in ("InvalidInstanceID.NotFound", "InvalidInstanceID.Malformed"):
            logger.warning("Instance %s not found / malformed id (%s).", instance_id, code)
            return None
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
    now = datetime.now(timezone.utc)

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
        reason = "already-not-running" if state in _NON_RUNNING_STATES else "not-running"
        logger.info(
            "Instance %s is %s (not 'running'); nothing to stop.", instance_id, state
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
    logger.info("stop_instances accepted for %s; transitions=%s", instance_id, transitions)

    result.update(action="stopped", reason="over-ceiling", stopping=transitions)
    return result


if __name__ == "__main__":
    # Local smoke test:
    #   TARGET_INSTANCE_ID=i-0123... AWS_TARGET_REGION=us-east-1 python handler.py
    import json

    print(json.dumps(handler({}, None), indent=2, default=str))
