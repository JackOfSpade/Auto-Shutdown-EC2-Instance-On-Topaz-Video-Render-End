#!/usr/bin/env bash
#
# 02-create-iam-role.sh
#
# .SYNOPSIS
#   Create the IAM role + instance profile the EC2 box uses to publish its
#   custom GPU metrics (and, optionally, to stop itself).
#
# .DESCRIPTION
#   The watchdog running on the Windows instance needs exactly ONE permission
#   to do its normal job: cloudwatch:PutMetricData, so it can publish its
#   custom metrics into the TopazRender/GPU namespace -- RenderActive (1/0,
#   the default idle-alarm signal) and GPUUtilization (telemetry, and the
#   legacy idle-alarm signal). This script creates a least-privilege role
#   granting only that.
#
#   The grant below is scoped to the NAMESPACE, not to any single metric
#   NAME: CloudWatch metrics are not ARN-addressable, so a cloudwatch:namespace
#   condition is the only enforcement PutMetricData's policy can use (see the
#   WHY comment at step [2/6] below). That is load-bearing for RenderActive
#   specifically -- it means this role needed NO change to start granting
#   RenderActive alongside the pre-existing GPUUtilization; any metric name
#   published inside METRIC_NAMESPACE just works. Only a different NAMESPACE
#   (not a different metric name) requires re-running this script.
#
#   Optionally (env INCLUDE_EC2_STOP=1) it also attaches a tightly tag-scoped
#   ec2:StopInstances policy, in case you want the instance to be able to stop
#   itself via the AWS API instead of relying on a guest-OS shutdown. This is
#   belt-and-suspenders and is OFF by default.
#
#   Steps:
#     1. create-role with the ec2 trust policy      (iam/instance-role-trust-policy.json)
#     2. put-role-policy PutMetricData              (iam/cloudwatch-putmetric-policy.json,
#        with its cloudwatch:namespace condition rendered to METRIC_NAMESPACE below)
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
#   Optional env var:  METRIC_NAMESPACE (default TopazRender/GPU) -- must match
#   in-guest/Config.ps1's MetricNamespace and 03-create-idle-alarm.sh's own
#   METRIC_NAMESPACE override EXACTLY. cloudwatch-putmetric-policy.json's
#   cloudwatch:namespace condition is rendered to this value before being
#   applied, so a mismatch here would deny the watchdog's PutMetricData calls
#   outright (AccessDenied), not just leave 03's alarm watching the wrong
#   metric.
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
  METRIC_NAMESPACE  CloudWatch namespace the PutMetricData policy's
                    cloudwatch:namespace condition is scoped to (default
                    TopazRender/GPU). Must match in-guest/Config.ps1's
                    MetricNamespace and 03-create-idle-alarm.sh's own
                    METRIC_NAMESPACE override exactly, or PutMetricData calls
                    to the custom namespace are denied.
EOF
  exit 1
}

[[ -n "${INSTANCE_ID:-}" ]] || { echo "ERROR: INSTANCE_ID is not set." >&2; usage; }
[[ -n "${AWS_REGION:-}"  ]] || { echo "ERROR: AWS_REGION is not set."  >&2; usage; }

INCLUDE_EC2_STOP="${INCLUDE_EC2_STOP:-0}"
METRIC_NAMESPACE="${METRIC_NAMESPACE:-TopazRender/GPU}"

ROLE_NAME="topaz-render-instance-role"
PROFILE_NAME="topaz-render-instance-profile"

# Resolve the directory this script lives in so the iam/*.json paths and
# lib/*.sh sourcing work regardless of the caller's current working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IAM_DIR="${SCRIPT_DIR}/iam"
# shellcheck source=lib/aws-idempotent.sh
source "${SCRIPT_DIR}/lib/aws-idempotent.sh"
# shellcheck source=lib/validation.sh
source "${SCRIPT_DIR}/lib/validation.sh"

# Shape-check INSTANCE_ID before ANY mutating call. This script tags the
# instance (INCLUDE_EC2_STOP=1) and associates an instance profile onto it, so
# a stale `export INSTANCE_ID=` from an earlier session would apply both to the
# wrong box -- see lib/validation.sh's is_valid_instance_id for the full WHY.
if ! is_valid_instance_id "$INSTANCE_ID"; then
  echo "ERROR: INSTANCE_ID='${INSTANCE_ID}' is not a valid EC2 instance id (expected i- followed by 8 or 17 hex digits)." >&2
  usage
fi

TRUST_POLICY="${IAM_DIR}/instance-role-trust-policy.json"
PUTMETRIC_POLICY="${IAM_DIR}/cloudwatch-putmetric-policy.json"
EC2_STOP_POLICY="${IAM_DIR}/ec2-stop-optional-policy.json"

for f in "$TRUST_POLICY" "$PUTMETRIC_POLICY"; do
  [[ -f "$f" ]] || { echo "ERROR: required policy file not found: $f" >&2; exit 1; }
done

# Render cloudwatch-putmetric-policy.json's cloudwatch:namespace condition to
# METRIC_NAMESPACE into a per-run temp copy -- the checked-in file hardcodes
# the default "TopazRender/GPU" literal, so an operator overriding
# METRIC_NAMESPACE without this step would get a role that denies
# PutMetricData to their custom namespace (AccessDenied) while every step of
# this script still reports success. A temp DIR (not just a temp file) mirrors
# 04-deploy-max-lifetime-lambda.sh's own scratch-space pattern; the trap
# covers every exit path (success, error, a usage() exit) so it is never
# leaked on the admin workstation. Plain bash string substitution (not
# sed/jq) sidesteps both a jq dependency and sed-delimiter collisions with
# namespace values that themselves contain '/' or other sed-special chars.
PUTMETRIC_TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$PUTMETRIC_TMP_DIR"' EXIT
PUTMETRIC_POLICY_RENDERED="${PUTMETRIC_TMP_DIR}/cloudwatch-putmetric-policy.json"
putmetric_policy_json="$(cat "$PUTMETRIC_POLICY")"
putmetric_policy_json="${putmetric_policy_json//TopazRender\/GPU/$METRIC_NAMESPACE}"
printf '%s' "$putmetric_policy_json" > "$PUTMETRIC_POLICY_RENDERED"
# Defensive check, mirroring 05-grant-audit-reads.sh's identical guard on its
# own placeholder render: if the hardcoded "TopazRender/GPU" literal above ever
# drifts from what the checked-in JSON actually contains, the substitution
# silently becomes a no-op and this script applies a policy scoped to the OLD
# namespace while every line it prints -- including the final "can now publish
# ... into the <operator's value> namespace" -- claims the new one. The
# watchdog's PutMetricData calls would then come back AccessDenied every
# minute, and 00-verify-prerequisites.sh's [4/6] would report only a WARN.
if ! grep -qF -- "$METRIC_NAMESPACE" "$PUTMETRIC_POLICY_RENDERED"; then
  echo "ERROR: rendering ${PUTMETRIC_POLICY}'s cloudwatch:namespace placeholder failed -- the" >&2
  echo "       rendered policy does not contain '${METRIC_NAMESPACE}'. Check the placeholder" >&2
  echo "       literal in both this script and ${PUTMETRIC_POLICY} still match." >&2
  exit 1
fi

echo "==> [1/6] Creating IAM role ${ROLE_NAME}"
echo "    aws iam create-role --role-name ${ROLE_NAME} --assume-role-policy-document file://${TRUST_POLICY}"
# Idempotent: if the role already exists, note it and continue instead of aborting.
if ! run_idempotent "EntityAlreadyExists" aws iam create-role \
      --role-name "$ROLE_NAME" \
      --assume-role-policy-document "file://${TRUST_POLICY}" \
      --description "Least-privilege role for the Topaz render auto-stop watchdog"; then
  echo "    NOTE: role ${ROLE_NAME} already exists; reusing it."
  # WHY read the trust policy back instead of just reusing the role: the trust
  # policy is the ONE binding in this script that was previously accepted
  # unverified. put-role-policy below is declarative (it overwrites), and both
  # the profile/role and profile/instance bindings already have explicit
  # reconcile branches -- but a pre-existing role that does not trust
  # ec2.amazonaws.com (hand-edited, or created by an unrelated experiment that
  # happened to pick this name) makes every subsequent step report success
  # while EC2 cannot assume the role at all: IMDS serves no credentials,
  # Push-GpuMetric.ps1's PutMetricData fails, and 00-verify-prerequisites.sh's
  # [4/6] still reports OK because the POLICY TEXT is correct. The failure only
  # ever surfaces as missing CloudWatch data.
  #
  # WHY detect-and-exit rather than an unconditional update-assume-role-policy:
  # that API replaces the ENTIRE trust document. Silently hijacking a role this
  # script did not create is a bigger surprise than put-role-policy, which only
  # adds one name-scoped inline policy. Same convention as the two
  # ambiguous-existing-entity branches below: detect, explain, print the exact
  # remediation, exit 1.
  EXISTING_TRUST="$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.AssumeRolePolicyDocument' --output json)"
  if ! printf '%s' "$EXISTING_TRUST" | grep -qF -- "ec2.amazonaws.com"; then
    echo "ERROR: the existing role ${ROLE_NAME} does not trust ec2.amazonaws.com." >&2
    echo "       EC2 cannot assume it, so the instance would get NO credentials and the" >&2
    echo "       watchdog's PutMetricData (and any tag-scoped stop) would fail silently." >&2
    echo "       Inspect it, and if this role really is meant to be ours, replace its" >&2
    echo "       trust policy with:" >&2
    echo "         aws iam get-role --role-name ${ROLE_NAME} --query Role.AssumeRolePolicyDocument" >&2
    echo "         aws iam update-assume-role-policy --role-name ${ROLE_NAME} \\" >&2
    echo "             --policy-document file://${TRUST_POLICY}" >&2
    echo "       (that REPLACES the whole trust document -- check what is there first)." >&2
    exit 1
  fi
  echo "    NOTE: confirmed -- ${ROLE_NAME}'s trust policy still allows ec2.amazonaws.com to assume it."
fi

echo "==> [2/6] Attaching inline PutMetricData policy (cloudwatch:PutMetricData, namespace=${METRIC_NAMESPACE} only)"
echo "    aws iam put-role-policy --role-name ${ROLE_NAME} --policy-name topaz-putmetric --policy-document file://${PUTMETRIC_POLICY_RENDERED}"
# WHY the namespace condition matters even though Resource stays "*":
# PutMetricData has no resource-level ARNs to scope down (CloudWatch metrics
# aren't ARN-addressable), so the cloudwatch:namespace StringEquals condition
# baked into cloudwatch-putmetric-policy.json IS the enforcement -- it's what
# keeps this role scoped to the METRIC_NAMESPACE namespace, not the
# (necessarily wildcard) Resource field. See the METRIC_NAMESPACE rendering
# step above for why the RENDERED copy (not the checked-in file) is applied.
# Because the condition is on the namespace and not a metric name, EVERY
# metric name published inside METRIC_NAMESPACE is covered by this one grant
# -- both GPUUtilization and RenderActive -- with no additional policy change
# needed when a new metric name is added to the same namespace.
# put-role-policy is idempotent by nature (it overwrites the named inline policy).
aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "topaz-putmetric" \
  --policy-document "file://${PUTMETRIC_POLICY_RENDERED}"

if [[ "$INCLUDE_EC2_STOP" == "1" ]]; then
  [[ -f "$EC2_STOP_POLICY" ]] || { echo "ERROR: INCLUDE_EC2_STOP=1 but ${EC2_STOP_POLICY} not found." >&2; exit 1; }
  # ###########################################################################
  # WHAT THE TAG CONDITION ACTUALLY BOUNDS -- READ BEFORE ADDING A SECOND BOX.
  #
  # iam/ec2-stop-optional-policy.json grants ec2:StopInstances on Resource "*"
  # with a single condition: aws:ResourceTag/AutoStopEligible=true. Step [2c/6]
  # below applies exactly that tag, and 04-deploy-max-lifetime-lambda.sh
  # applies it too. So the tag is not an instance identifier -- it is a
  # FLEET MEMBERSHIP marker that this very pipeline stamps onto every managed
  # box. The honest statement of the boundary is therefore:
  #
  #     every AutoStopEligible=true instance's role can stop EVERY OTHER
  #     AutoStopEligible=true instance in this account.
  #
  # This is ACCEPTED for this single-box deployment: there is exactly one
  # tagged instance, so the fleet and the instance are the same thing. It is
  # recorded here because the credential lives on a Windows box running
  # third-party GUI software, and today the only thing keeping a stop scoped to
  # ONE machine is in-guest: Stop-Sequence.ps1 passes its own IMDS-derived
  # instance id. IAM, which is supposed to be the backstop, does not constrain
  # it. A bug or stale cached id in that resolution would be permitted by IAM.
  #
  # WHAT TO CHANGE FOR MULTI-BOX (and why it is not done here): scoping
  # Resource to a single instance ARN does NOT work as-is, because ROLE_NAME
  # and PROFILE_NAME above are fixed literals shared by every box -- box B's
  # deploy would overwrite the topaz-ec2-stop inline policy that box A's role
  # depends on, silently REVOKING A's ability to stop itself. That trades a
  # broad grant for a dead one, which is strictly worse under this project's
  # own "no silently dead safety net" standard. Do it in this order instead:
  #   1. make ROLE_NAME/PROFILE_NAME per-instance (suffix with INSTANCE_ID,
  #      exactly as 04 already does for its function/schedule names), THEN
  #   2. either give each box a distinct tag VALUE and condition on the value,
  #      or render Resource to that box's instance ARN, and
  #   3. update docs/11-deploying-on-this-instance.md Sec 3.3 Option B, whose
  #      manual `file://control-plane/iam/ec2-stop-optional-policy.json`
  #      fallback would then be applying a placeholder-bearing file.
  # (ec2:SourceInstanceARN is also worth evaluating first -- it can express
  # "this instance only" for requests made via an instance profile without
  # per-instance roles -- but verify its exact semantics against current AWS
  # docs rather than taking that on trust.)
  # ###########################################################################
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
  # WHY check-and-warn instead of auto-revoke: a PREVIOUS run with
  # INCLUDE_EC2_STOP=1 may have already granted topaz-ec2-stop (and tagged the
  # instance AutoStopEligible=true). Silently revoking that on a later run
  # without the flag would be a destructive surprise the operator didn't ask
  # for; saying nothing would leave them unaware the permission is still
  # live. Check for it and, if present, tell them exactly how to remove it.
  if aws iam get-role-policy --role-name "$ROLE_NAME" --policy-name topaz-ec2-stop >/dev/null 2>&1; then
    echo "    NOTE: a previously-granted topaz-ec2-stop policy (and the"
    echo "          AutoStopEligible tag it depends on) is still attached to"
    echo "          ${ROLE_NAME} / ${INSTANCE_ID} and remains in force."
    echo "          To revoke it manually:"
    echo "            aws iam delete-role-policy --role-name ${ROLE_NAME} --policy-name topaz-ec2-stop"
    echo "            aws ec2 delete-tags --region ${AWS_REGION} --resources ${INSTANCE_ID} --tags Key=AutoStopEligible"
  fi
fi

echo "==> [3/6] Creating instance profile ${PROFILE_NAME}"
echo "    aws iam create-instance-profile --instance-profile-name ${PROFILE_NAME}"
if ! run_idempotent "EntityAlreadyExists" aws iam create-instance-profile \
      --instance-profile-name "$PROFILE_NAME"; then
  echo "    NOTE: instance profile ${PROFILE_NAME} already exists; reusing it."
fi

echo "==> [4/6] Adding role ${ROLE_NAME} to instance profile ${PROFILE_NAME}"
echo "    aws iam add-role-to-instance-profile --instance-profile-name ${PROFILE_NAME} --role-name ${ROLE_NAME}"
if ! run_idempotent "LimitExceeded|already" aws iam add-role-to-instance-profile \
      --instance-profile-name "$PROFILE_NAME" \
      --role-name "$ROLE_NAME"; then
  # WHY confirm, not just note-and-continue: an instance profile holds exactly
  # ONE role, and AWS returns this SAME LimitExceeded error whether the role
  # already attached is ours or a stale different one. Blindly printing
  # "already attached" and moving on could leave the instance running with
  # the WRONG role and no PutMetricData permission -- a silently dead
  # idle-alarm safety net. Look up the actually-attached role and say so,
  # mirroring the association-mismatch handling below (the same class of bug).
  ACTUAL_ROLE="$(aws iam get-instance-profile \
    --instance-profile-name "$PROFILE_NAME" \
    --query 'InstanceProfile.Roles[0].RoleName' \
    --output text)"
  if profile_names_match "$ACTUAL_ROLE" "$ROLE_NAME"; then
    echo "    NOTE: confirmed -- role ${ROLE_NAME} is already attached to ${PROFILE_NAME}."
  else
    echo "ERROR: instance profile ${PROFILE_NAME} already has a DIFFERENT role attached: ${ACTUAL_ROLE:-<unknown>}" >&2
    echo "       Expected: ${ROLE_NAME}" >&2
    echo "       Fix with:" >&2
    echo "         aws iam remove-role-from-instance-profile --instance-profile-name ${PROFILE_NAME} --role-name ${ACTUAL_ROLE}" >&2
    echo "         aws iam add-role-to-instance-profile --instance-profile-name ${PROFILE_NAME} --role-name ${ROLE_NAME}" >&2
    exit 1
  fi
fi

echo "==> [5/6] Waiting briefly for the instance profile to propagate (IAM is eventually consistent)..."
# Give IAM a moment; association can fail with 'Invalid IAM Instance Profile' if
# attempted too quickly after creation. 10s is NOT a guarantee -- propagation
# to EC2 routinely takes 30-60s on a first creation -- so the association below
# also recognizes that specific failure and tells the operator to re-run rather
# than leaving them with an error that reads like a typo in the profile name.
sleep 10

echo "==> [6/6] Associating instance profile ${PROFILE_NAME} with ${INSTANCE_ID}"
echo "    aws ec2 associate-iam-instance-profile --region ${AWS_REGION} \\"
echo "        --instance-id ${INSTANCE_ID} \\"
echo "        --iam-instance-profile Name=${PROFILE_NAME}"
# run_idempotent_hinted, not run_idempotent: 'Invalid IAM Instance Profile' /
# InvalidParameterValue here is almost always propagation lag, not a bad name,
# and this script is idempotent so "wait and re-run" costs nothing. The hint
# must NOT be folded into the idempotency pattern above -- a match there
# returns 2 and drops into the reconciliation block below, which would then
# read back a nonexistent association and abort with the actively misleading
# "associated with a DIFFERENT IAM instance profile: None".
if ! run_idempotent_hinted "IncorrectState|already" \
      "Invalid IAM Instance Profile|InvalidParameterValue" \
      "HINT: IAM instance-profile propagation to EC2 is eventually consistent and can take 30-60s on first creation, while step [5/6] waits only 10s. This script is idempotent -- wait a minute and re-run it before treating the error above as a real problem." \
      aws ec2 associate-iam-instance-profile \
      --region "$AWS_REGION" \
      --instance-id "$INSTANCE_ID" \
      --iam-instance-profile "Name=${PROFILE_NAME}"; then
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
  if profile_names_match "$ASSOCIATED_NAME" "$PROFILE_NAME"; then
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
    exit 1
  fi
fi

echo "==> Done. Instance ${INSTANCE_ID} can now publish any metric (RenderActive, GPUUtilization, ...) into the ${METRIC_NAMESPACE} namespace."
if [[ "$INCLUDE_EC2_STOP" == "1" ]]; then
  echo "    (Optional ec2:StopInstances also granted, tag-scoped to AutoStopEligible=true."
  echo "     NOTE that AutoStopEligible is a FLEET marker this pipeline applies to every"
  echo "     managed box, not an instance identifier: any tagged instance's role can stop"
  echo "     any other tagged instance in this account. Accepted for a single-box"
  echo "     deployment -- see the boundary comment at step [2b/6] before adding a second.)"
fi
