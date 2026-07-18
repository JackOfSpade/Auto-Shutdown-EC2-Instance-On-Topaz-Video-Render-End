#!/usr/bin/env bash
#
# 01-set-shutdown-behavior.sh
#
# .SYNOPSIS
#   Set the EC2 instance-initiated-shutdown-behavior to "stop".
#
# .DESCRIPTION
#   This is the single most important control-plane setting for the whole
#   auto-stop pipeline. It makes a guest-OS shutdown (e.g. Windows
#   `Stop-Computer` issued by the watchdog when a Topaz render finishes) STOP
#   the instance instead of TERMINATING it. Without this, a guest shutdown on a
#   default instance would destroy the box.
#
#   After setting the attribute, the script reads it back with
#   describe-instance-attribute to confirm the change actually took.
#
# .NOTES
#   Run from an admin workstation with AWS CLI v2 configured.
#   Requires env vars: INSTANCE_ID, AWS_REGION.
#   No credentials, account numbers, or real instance ids are stored here.
#
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: INSTANCE_ID=i-XXXXXXXXXXXXXXXXX AWS_REGION=<region> ./01-set-shutdown-behavior.sh

Required environment variables:
  INSTANCE_ID   The target EC2 instance id (e.g. i-XXXXXXXXXXXXXXXXX)
  AWS_REGION    The AWS region the instance lives in (e.g. <region>)
EOF
  exit 1
}

if [[ -z "${INSTANCE_ID:-}" ]]; then echo "ERROR: INSTANCE_ID is not set." >&2; usage; fi
if [[ -z "${AWS_REGION:-}" ]];  then echo "ERROR: AWS_REGION is not set."  >&2; usage; fi

echo "==> Setting instance-initiated-shutdown-behavior=stop on ${INSTANCE_ID} in ${AWS_REGION}"
echo "    aws ec2 modify-instance-attribute --instance-id \"${INSTANCE_ID}\" --region \"${AWS_REGION}\" \\"
echo "        --instance-initiated-shutdown-behavior stop"

aws ec2 modify-instance-attribute \
  --instance-id "$INSTANCE_ID" \
  --region "$AWS_REGION" \
  --instance-initiated-shutdown-behavior stop

echo "==> Reading the attribute back to confirm it is now 'stop'"
echo "    aws ec2 describe-instance-attribute --instance-id \"${INSTANCE_ID}\" --region \"${AWS_REGION}\" \\"
echo "        --attribute instanceInitiatedShutdownBehavior"

CURRENT_BEHAVIOR="$(aws ec2 describe-instance-attribute \
  --instance-id "$INSTANCE_ID" \
  --region "$AWS_REGION" \
  --attribute instanceInitiatedShutdownBehavior \
  --query 'InstanceInitiatedShutdownBehavior.Value' \
  --output text)"

echo "==> Current instance-initiated-shutdown-behavior: ${CURRENT_BEHAVIOR}"

if [[ "$CURRENT_BEHAVIOR" != "stop" ]]; then
  echo "ERROR: expected 'stop' but got '${CURRENT_BEHAVIOR}'. Aborting." >&2
  exit 1
fi

echo "==> OK: a guest shutdown will now STOP (not terminate) this instance."
