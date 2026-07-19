#!/usr/bin/env bash
#
# 03-create-idle-alarm.sh
#
# .SYNOPSIS
#   Create the out-of-band idle-stop CloudWatch alarm.
#
# .DESCRIPTION
#   This alarm is the SAFETY NET, not the primary stop path. The primary stop is
#   the on-box watchdog that detects a finished Topaz render and shuts the guest
#   down. This alarm exists only to catch a truly dead / hung / idle box that the
#   watchdog failed to stop (crashed watchdog, orphaned instance, etc.).
#
#   It fires on the CUSTOM GPU metric (default TopazRender/GPU : GPUUtilization,
#   see METRIC_NAMESPACE/METRIC_NAME below) published by the on-box watchdog,
#   and uses the built-in EC2 alarm action to stop the instance. The window is
#   deliberately LONG and conservative:
#       period 60s  x  evaluation-periods IDLE_MINUTES (default 30)  =  IDLE_MINUTES minutes
#   of SUSTAINED sub-5% GPU before it acts, so it can never false-stop an active
#   render (Topaz GPU work spikes well above 5% while encoding). Raise
#   IDLE_MINUTES if a slow pre-render setup (e.g. uploading source files over a
#   slow link) routinely leaves the GPU idle for longer than the default before
#   Export is clicked -- otherwise the alarm can stop the box out from under an
#   operator who simply hasn't started rendering yet.
#
#   treat-missing-data notBreaching: if the metric stops arriving entirely (e.g.
#   watchdog stopped publishing) we do NOT treat that as "idle" and stop the box
#   on missing data alone -- missing data is ambiguous, so we stay OK.
#
#   #############################################################################
#   # DO NOT key this alarm on CPUUtilization.                                  #
#   # CPU is BLIND to GPU load. A Topaz render can peg the GPU while CPU sits   #
#   # near idle, so a CPU-based alarm would FALSE-STOP a real, active render.   #
#   # The whole point of the custom GPU metric is to observe the actual work.  #
#   #############################################################################
#
# .NOTES
#   Run from an admin workstation with AWS CLI v2 configured.
#   Requires env vars: INSTANCE_ID, AWS_REGION.
#   Optional env var:  IDLE_MINUTES (default 30) -- sustained-idle window, in
#   whole minutes, before the alarm stops the instance. Must be a positive
#   integer.
#   Optional env vars: METRIC_NAMESPACE (default TopazRender/GPU) and
#   METRIC_NAME (default GPUUtilization) -- override which custom metric the
#   alarm watches, mirroring in-guest/Config.ps1's editable
#   MetricNamespace/MetricName. Only change these together with the
#   watchdog's own config, or the alarm ends up watching a metric nothing
#   publishes.
#   The arn:aws:automate:<region>:ec2:stop action requires no extra IAM role.
#
set -euo pipefail

# Resolve the directory this script lives in so lib/*.sh sourcing works
# regardless of the caller's current working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/validation.sh
source "${SCRIPT_DIR}/lib/validation.sh"

usage() {
  cat >&2 <<'EOF'
Usage: INSTANCE_ID=i-XXXXXXXXXXXXXXXXX AWS_REGION=<region> [IDLE_MINUTES=30] ./03-create-idle-alarm.sh

Required environment variables:
  INSTANCE_ID   The target EC2 instance id (e.g. i-XXXXXXXXXXXXXXXXX)
  AWS_REGION    The AWS region the instance lives in (e.g. <region>)

Optional environment variables:
  IDLE_MINUTES      Sustained sub-5% GPU window, in whole minutes, before the
                    alarm stops the instance (default 30). Must be a positive
                    integer. Raise this if pre-render setup (e.g. uploading
                    source files over a slow link) can leave the GPU idle for a
                    long stretch before Export is clicked.
  METRIC_NAMESPACE  CloudWatch namespace of the custom GPU metric to watch
                    (default TopazRender/GPU). Mirrors in-guest/Config.ps1's
                    MetricNamespace.
  METRIC_NAME       CloudWatch metric name within that namespace (default
                    GPUUtilization). Mirrors in-guest/Config.ps1's MetricName.
EOF
  exit 1
}

[[ -n "${INSTANCE_ID:-}" ]] || { echo "ERROR: INSTANCE_ID is not set." >&2; usage; }
[[ -n "${AWS_REGION:-}"  ]] || { echo "ERROR: AWS_REGION is not set."  >&2; usage; }

IDLE_MINUTES="${IDLE_MINUTES:-30}"
if ! is_valid_idle_minutes "$IDLE_MINUTES"; then
  echo "ERROR: IDLE_MINUTES must be a positive integer with no leading zeros (got '${IDLE_MINUTES}')." >&2
  usage
fi

METRIC_NAMESPACE="${METRIC_NAMESPACE:-TopazRender/GPU}"
METRIC_NAME="${METRIC_NAME:-GPUUtilization}"

# WHY per-instance name: put-metric-alarm OVERWRITES any existing alarm that
# has the same --alarm-name. A hardcoded shared name meant provisioning a
# SECOND instance silently repointed (and thereby disabled) the first box's
# safety net. Keying the name on INSTANCE_ID gives every instance its own
# alarm.
ALARM_NAME="topaz-gpu-idle-autostop-${INSTANCE_ID}"

echo "==> Creating idle-stop alarm '${ALARM_NAME}'"
echo "    metric  : ${METRIC_NAMESPACE} : ${METRIC_NAME} (custom, GPU-aware -- NOT CPUUtilization)"
echo "    window  : period 60s x ${IDLE_MINUTES} evaluation-periods = ${IDLE_MINUTES} min sustained < 5% GPU"
echo "    action  : arn:aws:automate:${AWS_REGION}:ec2:stop"
echo "    aws cloudwatch put-metric-alarm --region ${AWS_REGION} --alarm-name ${ALARM_NAME} ..."

aws cloudwatch put-metric-alarm \
  --region "$AWS_REGION" \
  --alarm-name "$ALARM_NAME" \
  --alarm-description "Safety net: stop the Topaz render box after ${IDLE_MINUTES} min of sustained sub-5% GPU. Keyed on the custom GPU metric, never on CPU." \
  --namespace "$METRIC_NAMESPACE" \
  --metric-name "$METRIC_NAME" \
  --dimensions Name=InstanceId,Value="$INSTANCE_ID" \
  --statistic Average \
  --period 60 \
  --evaluation-periods "$IDLE_MINUTES" \
  --threshold 5 \
  --comparison-operator LessThanThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions "arn:aws:automate:${AWS_REGION}:ec2:stop"

echo "==> Done. Alarm '${ALARM_NAME}' created/updated."
echo "    Verify: aws cloudwatch describe-alarms --region ${AWS_REGION} --alarm-names ${ALARM_NAME}"
echo ""
echo "    NOTE: upgrading from an older deployment that used the shared alarm"
echo "          name 'topaz-gpu-idle-autostop'? Delete it -- it no longer"
echo "          tracks this (or any) instance and is an orphaned safety net:"
echo "            aws cloudwatch delete-alarms --region ${AWS_REGION} --alarm-names topaz-gpu-idle-autostop"
echo ""
echo "    Pause/resume the alarm's stop action -- pause it before a long"
echo "    pre-render setup (uploading sources, etc.) where the GPU may sit"
echo "    idle past ${IDLE_MINUTES} min, then resume it right after clicking Export:"
echo "      aws cloudwatch disable-alarm-actions --region ${AWS_REGION} --alarm-names ${ALARM_NAME}"
echo "      aws cloudwatch enable-alarm-actions  --region ${AWS_REGION} --alarm-names ${ALARM_NAME}"
