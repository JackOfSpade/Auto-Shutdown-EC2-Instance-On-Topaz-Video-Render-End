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
#   It fires on the CUSTOM GPU metric (TopazRender/GPU : GPUUtilization) published
#   by the on-box watchdog, and uses the built-in EC2 alarm action to stop the
#   instance. The window is deliberately LONG and conservative:
#       period 60s  x  evaluation-periods 30  =  30 minutes
#   of SUSTAINED sub-5% GPU before it acts, so it can never false-stop an active
#   render (Topaz GPU work spikes well above 5% while encoding).
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
#   The arn:aws:automate:<region>:ec2:stop action requires no extra IAM role.
#
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: INSTANCE_ID=i-XXXXXXXXXXXXXXXXX AWS_REGION=<region> ./03-create-idle-alarm.sh

Required environment variables:
  INSTANCE_ID   The target EC2 instance id (e.g. i-XXXXXXXXXXXXXXXXX)
  AWS_REGION    The AWS region the instance lives in (e.g. <region>)
EOF
  exit 1
}

[[ -n "${INSTANCE_ID:-}" ]] || { echo "ERROR: INSTANCE_ID is not set." >&2; usage; }
[[ -n "${AWS_REGION:-}"  ]] || { echo "ERROR: AWS_REGION is not set."  >&2; usage; }

ALARM_NAME="topaz-gpu-idle-autostop"

echo "==> Creating idle-stop alarm '${ALARM_NAME}'"
echo "    metric  : TopazRender/GPU : GPUUtilization (custom, GPU-aware -- NOT CPUUtilization)"
echo "    window  : period 60s x 30 evaluation-periods = 30 min sustained < 5% GPU"
echo "    action  : arn:aws:automate:${AWS_REGION}:ec2:stop"
echo "    aws cloudwatch put-metric-alarm --region ${AWS_REGION} --alarm-name ${ALARM_NAME} ..."

aws cloudwatch put-metric-alarm \
  --region "$AWS_REGION" \
  --alarm-name "$ALARM_NAME" \
  --alarm-description "Safety net: stop the Topaz render box after 30 min of sustained sub-5% GPU. Keyed on the custom GPU metric, never on CPU." \
  --namespace TopazRender/GPU \
  --metric-name GPUUtilization \
  --dimensions Name=InstanceId,Value="$INSTANCE_ID" \
  --statistic Average \
  --period 60 \
  --evaluation-periods 30 \
  --threshold 5 \
  --comparison-operator LessThanThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions "arn:aws:automate:${AWS_REGION}:ec2:stop"

echo "==> Done. Alarm '${ALARM_NAME}' created/updated."
echo "    Verify: aws cloudwatch describe-alarms --region ${AWS_REGION} --alarm-names ${ALARM_NAME}"
