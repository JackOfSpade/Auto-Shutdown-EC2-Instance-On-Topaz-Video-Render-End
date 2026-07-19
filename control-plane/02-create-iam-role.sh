#!/usr/bin/env bash
#
# 02-create-iam-role.sh
#
# .SYNOPSIS
#   Create the IAM role + instance profile the EC2 box uses to publish its
#   custom GPU metric (and, optionally, to stop itself).
#
# .DESCRIPTION
#   The watchdog running on the Windows instance needs exactly ONE permission
#   to do its normal job: cloudwatch:PutMetricData, so it can publish the
#   TopazRender/GPU GPUUtilization metric. This script creates a least-privilege
#   role granting only that.
#
#   Optionally (env INCLUDE_EC2_STOP=1) it also attaches a tightly tag-scoped
#   ec2:StopInstances policy, in case you want the instance to be able to stop
#   itself via the AWS API instead of relying on a guest-OS shutdown. This is
#   belt-and-suspenders and is OFF by default.
#
#   Steps:
#     1. create-role with the ec2 trust policy      (iam/instance-role-trust-policy.json)
#     2. put-role-policy PutMetricData              (iam/cloudwatch-putmetric-policy.json)
#     3. optionally put-role-policy ec2:StopInstances (iam/ec2-stop-optional-policy.json),
#        and, since that policy is tag-scoped, tag the instance AutoStopEligible=true
#     4. create-instance-profile
#     5. add-role-to-instance-profile
#     6. associate-iam-instance-profile with the instance
#
# .NOTES
#   Run from an admin workstation with AWS CLI v2 configured.
#   Requires env vars: INSTANCE_ID, AWS_REGION.
#   Optional env var:  INCLUDE_EC2_STOP=1 to also attach the ec2:stop policy.
#   Idempotency: entity-creation calls that may fail because the entity already
#   exists are guarded and NOTED (not silently swallowed) so re-runs are safe.
#
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: INSTANCE_ID=i-XXXXXXXXXXXXXXXXX AWS_REGION=<region> [INCLUDE_EC2_STOP=1] ./02-create-iam-role.sh

Required environment variables:
  INSTANCE_ID       The target EC2 instance id (e.g. i-XXXXXXXXXXXXXXXXX)
  AWS_REGION        The AWS region the instance lives in (e.g. <region>)

Optional environment variables:
  INCLUDE_EC2_STOP  Set to 1 to also attach the tag-scoped ec2:StopInstances policy.
EOF
  exit 1
}

[[ -n "${INSTANCE_ID:-}" ]] || { echo "ERROR: INSTANCE_ID is not set." >&2; usage; }
[[ -n "${AWS_REGION:-}"  ]] || { echo "ERROR: AWS_REGION is not set."  >&2; usage; }

INCLUDE_EC2_STOP="${INCLUDE_EC2_STOP:-0}"

ROLE_NAME="topaz-render-instance-role"
PROFILE_NAME="topaz-render-instance-profile"

# Resolve the directory this script lives in so the iam/*.json paths work
# regardless of the caller's current working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IAM_DIR="${SCRIPT_DIR}/iam"

TRUST_POLICY="${IAM_DIR}/instance-role-trust-policy.json"
PUTMETRIC_POLICY="${IAM_DIR}/cloudwatch-putmetric-policy.json"
EC2_STOP_POLICY="${IAM_DIR}/ec2-stop-optional-policy.json"

for f in "$TRUST_POLICY" "$PUTMETRIC_POLICY"; do
  [[ -f "$f" ]] || { echo "ERROR: required policy file not found: $f" >&2; exit 1; }
done

echo "==> [1/6] Creating IAM role ${ROLE_NAME}"
echo "    aws iam create-role --role-name ${ROLE_NAME} --assume-role-policy-document file://${TRUST_POLICY}"
# Idempotent: if the role already exists, note it and continue instead of aborting.
if ! aws iam create-role \
      --role-name "$ROLE_NAME" \
      --assume-role-policy-document "file://${TRUST_POLICY}" \
      --description "Least-privilege role for the Topaz render auto-stop watchdog" 2>/tmp/iam_err.$$; then
  if grep -q "EntityAlreadyExists" /tmp/iam_err.$$; then
    echo "    NOTE: role ${ROLE_NAME} already exists; reusing it."
  else
    cat /tmp/iam_err.$$ >&2; rm -f /tmp/iam_err.$$; exit 1
  fi
fi
rm -f /tmp/iam_err.$$

echo "==> [2/6] Attaching inline PutMetricData policy (cloudwatch:PutMetricData only)"
echo "    aws iam put-role-policy --role-name ${ROLE_NAME} --policy-name topaz-putmetric --policy-document file://${PUTMETRIC_POLICY}"
# put-role-policy is idempotent by nature (it overwrites the named inline policy).
aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "topaz-putmetric" \
  --policy-document "file://${PUTMETRIC_POLICY}"

if [[ "$INCLUDE_EC2_STOP" == "1" ]]; then
  [[ -f "$EC2_STOP_POLICY" ]] || { echo "ERROR: INCLUDE_EC2_STOP=1 but ${EC2_STOP_POLICY} not found." >&2; exit 1; }
  echo "==> [2b/6] INCLUDE_EC2_STOP=1: attaching tag-scoped ec2:StopInstances policy"
  echo "    aws iam put-role-policy --role-name ${ROLE_NAME} --policy-name topaz-ec2-stop --policy-document file://${EC2_STOP_POLICY}"
  aws iam put-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name "topaz-ec2-stop" \
    --policy-document "file://${EC2_STOP_POLICY}"

  # WHY: the policy above only grants ec2:StopInstances when the target instance
  # carries AutoStopEligible=true (see iam/ec2-stop-optional-policy.json). Nothing
  # else in this pipeline ever applies that tag -- without it, an in-guest API
  # stop call would fail UnauthorizedOperation every single time. Tag the
  # instance now so the permission we just granted is actually usable.
  echo "==> [2c/6] Tagging ${INSTANCE_ID} with AutoStopEligible=true (required by the policy's tag condition)"
  echo "    aws ec2 create-tags --region ${AWS_REGION} --resources ${INSTANCE_ID} --tags Key=AutoStopEligible,Value=true"
  aws ec2 create-tags \
    --region "$AWS_REGION" \
    --resources "$INSTANCE_ID" \
    --tags Key=AutoStopEligible,Value=true
else
  echo "==> [2b/6] INCLUDE_EC2_STOP not set to 1: skipping the optional ec2:stop policy."
fi

echo "==> [3/6] Creating instance profile ${PROFILE_NAME}"
echo "    aws iam create-instance-profile --instance-profile-name ${PROFILE_NAME}"
if ! aws iam create-instance-profile \
      --instance-profile-name "$PROFILE_NAME" 2>/tmp/iam_err.$$; then
  if grep -q "EntityAlreadyExists" /tmp/iam_err.$$; then
    echo "    NOTE: instance profile ${PROFILE_NAME} already exists; reusing it."
  else
    cat /tmp/iam_err.$$ >&2; rm -f /tmp/iam_err.$$; exit 1
  fi
fi
rm -f /tmp/iam_err.$$

echo "==> [4/6] Adding role ${ROLE_NAME} to instance profile ${PROFILE_NAME}"
echo "    aws iam add-role-to-instance-profile --instance-profile-name ${PROFILE_NAME} --role-name ${ROLE_NAME}"
if ! aws iam add-role-to-instance-profile \
      --instance-profile-name "$PROFILE_NAME" \
      --role-name "$ROLE_NAME" 2>/tmp/iam_err.$$; then
  if grep -q "LimitExceeded\|already" /tmp/iam_err.$$; then
    echo "    NOTE: role appears to already be attached to the instance profile; continuing."
  else
    cat /tmp/iam_err.$$ >&2; rm -f /tmp/iam_err.$$; exit 1
  fi
fi
rm -f /tmp/iam_err.$$

echo "==> [5/6] Waiting briefly for the instance profile to propagate (IAM is eventually consistent)..."
# Give IAM a moment; association can fail with 'Invalid IAM Instance Profile' if
# attempted too quickly after creation.
sleep 10

echo "==> [6/6] Associating instance profile ${PROFILE_NAME} with ${INSTANCE_ID}"
echo "    aws ec2 associate-iam-instance-profile --region ${AWS_REGION} \\"
echo "        --instance-id ${INSTANCE_ID} \\"
echo "        --iam-instance-profile Name=${PROFILE_NAME}"
if ! aws ec2 associate-iam-instance-profile \
      --region "$AWS_REGION" \
      --instance-id "$INSTANCE_ID" \
      --iam-instance-profile "Name=${PROFILE_NAME}" 2>/tmp/iam_err.$$; then
  if grep -q "IncorrectState\|already" /tmp/iam_err.$$; then
    echo "    NOTE: instance already has an IAM instance profile associated;"
    echo "          verifying it is the expected one (${PROFILE_NAME}) rather than"
    echo "          just assuming any existing association is fine..."
    # WHY: the old fallback accepted ANY existing association as "good enough".
    # If the instance is actually wearing a DIFFERENT (stale, wrong-account,
    # hand-attached) profile, it silently runs without the permissions this
    # script just granted. Look up the association by name and say so.
    ASSOCIATED_ARN="$(aws ec2 describe-iam-instance-profile-associations \
      --region "$AWS_REGION" \
      --filters "Name=instance-id,Values=${INSTANCE_ID}" "Name=state,Values=associating,associated" \
      --query 'IamInstanceProfileAssociations[0].IamInstanceProfile.Arn' \
      --output text)"
    ASSOCIATED_NAME="${ASSOCIATED_ARN##*/}"
    if [[ "$ASSOCIATED_NAME" == "$PROFILE_NAME" ]]; then
      echo "    NOTE: confirmed -- ${INSTANCE_ID} is already associated with ${PROFILE_NAME}."
    else
      ASSOCIATION_ID="$(aws ec2 describe-iam-instance-profile-associations \
        --region "$AWS_REGION" \
        --filters "Name=instance-id,Values=${INSTANCE_ID}" "Name=state,Values=associating,associated" \
        --query 'IamInstanceProfileAssociations[0].AssociationId' \
        --output text)"
      echo "ERROR: ${INSTANCE_ID} is associated with a DIFFERENT IAM instance profile: ${ASSOCIATED_NAME:-<unknown>}" >&2
      echo "       Expected: ${PROFILE_NAME}" >&2
      echo "       Fix with:" >&2
      echo "         aws ec2 replace-iam-instance-profile-association --region ${AWS_REGION} \\" >&2
      echo "             --association-id ${ASSOCIATION_ID} \\" >&2
      echo "             --iam-instance-profile Name=${PROFILE_NAME}" >&2
      rm -f /tmp/iam_err.$$
      exit 1
    fi
  else
    cat /tmp/iam_err.$$ >&2; rm -f /tmp/iam_err.$$; exit 1
  fi
fi
rm -f /tmp/iam_err.$$

echo "==> Done. Instance ${INSTANCE_ID} can now publish the TopazRender/GPU metric."
if [[ "$INCLUDE_EC2_STOP" == "1" ]]; then
  echo "    (Optional ec2:StopInstances also granted, tag-scoped to AutoStopEligible=true.)"
fi
