#!/usr/bin/env bash
#
# 05-grant-audit-reads.sh
#
# .SYNOPSIS
#   *** OPTIONAL / OPT-IN -- EXPANDS the render instance role's privilege. ***
#   Grants READ-ONLY control-plane audit permissions so a future in-guest
#   post-mortem can attribute an instance stop to the automation, an alarm, a
#   Lambda, or a human -- instead of only being able to infer it from
#   guest-side logs. The auto-stop pipeline itself needs NONE of this; it
#   works exactly as well with this script never run. Skip it unless you
#   specifically want an on-box post-mortem to be self-sufficient.
#
# .DESCRIPTION
#   02-create-iam-role.sh's role is deliberately least-privilege: it grants
#   only cloudwatch:PutMetricData (namespace-scoped) plus an optional
#   tag-scoped ec2:StopInstances. That is correct for running the pipeline,
#   but it means the box itself cannot answer "what actually stopped me?" --
#   every read needed to attribute a stop (cloudtrail:LookupEvents,
#   cloudwatch:DescribeAlarms/DescribeAlarmHistory, lambda:ListFunctions,
#   logs:DescribeLogGroups, iam:List*RolePolicies, ...) comes back
#   AccessDenied from the box today. See docs/09-appendix-b-boundaries.md for
#   the full trade-off writeup and the honest recommendation.
#
#   This script creates (or updates) ONE customer-managed IAM policy --
#   iam/audit-read-optional-policy.json, granting ONLY the read-only actions
#   listed below -- and attaches it to the render instance role. Nothing it
#   grants can create, modify, delete, start, stop, or terminate anything:
#
#     cloudtrail:LookupEvents                                   (Resource "*" --
#         CANNOT be resource-scoped at all; LookupEvents takes no ARN
#         parameter, so this is the least tightly-scopeable grant in this
#         policy and the main reason the whole policy stays opt-in rather
#         than folded into 02's baseline grant.)
#     cloudwatch:DescribeAlarms, cloudwatch:DescribeAlarmHistory,
#     cloudwatch:GetMetricStatistics, cloudwatch:ListMetrics             (Resource "*" --
#         GetMetricStatistics/ListMetrics can never be scoped, CloudWatch
#         metrics are not ARN-addressable, same reasoning
#         cloudwatch-putmetric-policy.json already documents. DescribeAlarms/
#         DescribeAlarmHistory COULD be scoped to one alarm ARN, but a
#         forensic tool that only sees "its own" alarm can't tell you some
#         OTHER alarm fired instead -- narrowing it would defeat the audit.)
#     lambda:ListFunctions, lambda:GetFunctionConfiguration             (Resource "*" --
#         ListFunctions cannot be scoped; GetFunctionConfiguration could be
#         scoped to one function ARN, but which Lambda (if any) touched this
#         instance is exactly the unknown a post-mortem is trying to answer.)
#     logs:DescribeLogGroups, logs:DescribeLogStreams,
#     logs:FilterLogEvents                                              (Resource "*" --
#         the relevant log group name is not known in advance -- narrowing
#         it to a guess would be the same mistake as above.)
#     iam:ListAttachedRolePolicies, iam:ListRolePolicies,
#     iam:GetRolePolicy                                                 (Resource scoped
#         to THIS role's own ARN -- the one case in this policy where the
#         action supports resource-level scoping AND the correct target is
#         unambiguous: a role auditing its own grants has exactly one
#         sensible target, itself.)
#
#   Steps:
#     1. Resolve ROLE_NAME (env override, or auto-discovered from
#        INSTANCE_ID's attached instance profile -- same lookup
#        00-verify-prerequisites.sh's [3/6] check performs).
#     2. Resolve the caller's AWS account id (needed to build ARNs).
#     3. Render iam/audit-read-optional-policy.json's placeholder role ARN to
#        the real one, into a per-run temp copy (same pattern
#        02-create-iam-role.sh uses for its METRIC_NAMESPACE rendering --
#        plain bash substitution, not sed/jq, for the same reasons given
#        there).
#     4. create-policy (or, if it already exists, prune the oldest non-default
#        version if at IAM's 5-version cap, then create-policy-version
#        --set-as-default) -- a MANAGED policy, not an inline one, so it can
#        be inspected, versioned, and detached independently of whatever
#        inline policies 02/04 already manage on this role.
#     5. attach-role-policy (idempotent -- attaching an already-attached
#        policy is a no-op success).
#
# .NOTES
#   Run from an admin workstation with AWS CLI v2 configured.
#   Requires env vars: INSTANCE_ID, AWS_REGION.
#   Optional env var:  ROLE_NAME -- grant the policy to this role by name
#   instead of auto-discovering it from INSTANCE_ID's attached instance
#   profile. Use this if the instance-profile lookup itself is denied, or to
#   grant the policy to a role not (yet) attached to any instance.
#
#   *** THE ALTERNATIVE, AND WHICH ONE TO PICK ***
#   The alternative to running this script is to run the SAME control-plane
#   audit commands (cloudtrail lookup-events, cloudwatch describe-alarms,
#   etc.) from the admin workstation you are reading this on right now --
#   which already holds broader credentials than this box will ever have.
#   For a ONE-OFF investigation, that is the better choice: it requires no
#   change to the render box's privilege at all, and the workstation
#   credentials are already sitting there unused for exactly this purpose.
#   Reach for THIS script only when you want a post-mortem run FROM THE BOX
#   ITSELF to be self-sufficient -- e.g. no admin workstation is reachable at
#   the time, or the post-mortem is itself being automated in-guest. Either
#   way: this is a deliberate, opt-in widening of what the render box can do,
#   not a default posture change, and the pipeline runs identically without
#   it.
#
set -euo pipefail

cat >&2 <<'BANNER'
################################################################################
# OPT-IN: 05-grant-audit-reads.sh EXPANDS the render instance role's         #
# privilege with READ-ONLY control-plane audit permissions (CloudTrail,      #
# CloudWatch alarms/metrics, Lambda config, CloudWatch Logs, and the role's  #
# own attached-policy listing).                                              #
#                                                                              #
# The auto-stop pipeline needs NONE of this -- it works identically whether  #
# or not this script is ever run. Only an in-guest post-mortem that wants to #
# attribute a stop from the control plane, on-box, needs it. For a one-off   #
# investigation, prefer running the same audit commands from THIS admin      #
# workstation instead -- it already holds broader credentials and this       #
# script changes nothing on the box. See docs/09-appendix-b-boundaries.md.   #
################################################################################
BANNER

usage() {
  cat >&2 <<'EOF'
Usage: INSTANCE_ID=i-XXXXXXXXXXXXXXXXX AWS_REGION=<region> [ROLE_NAME=<role>] ./05-grant-audit-reads.sh

*** OPTIONAL / OPT-IN. Not required by the auto-stop pipeline. ***
Grants the render instance role READ-ONLY control-plane audit permissions
(CloudTrail, CloudWatch alarms/metrics, Lambda config, CloudWatch Logs, and
the role's own attached-policy listing) so a future in-guest post-mortem can
attribute an instance stop without an admin workstation. Skip this unless you
specifically want that. See docs/09-appendix-b-boundaries.md.

Required environment variables:
  INSTANCE_ID       The target EC2 instance id (e.g. i-XXXXXXXXXXXXXXXXX)
  AWS_REGION        The AWS region the instance lives in (e.g. <region>)

Optional environment variables:
  ROLE_NAME         Grant the audit policy to this role by name instead of
                    auto-discovering it from INSTANCE_ID's attached instance
                    profile. Use this if the instance-profile lookup itself
                    is denied, or to target a role not yet attached to any
                    instance.

To REVOKE this grant later, see the commands this script prints at the end
of a successful run, or:
  aws iam detach-role-policy --role-name <role> --policy-arn arn:aws:iam::<account>:policy/topaz-audit-read
  aws iam delete-policy --policy-arn arn:aws:iam::<account>:policy/topaz-audit-read
EOF
  exit 1
}

[[ -n "${INSTANCE_ID:-}" ]] || { echo "ERROR: INSTANCE_ID is not set." >&2; usage; }
[[ -n "${AWS_REGION:-}"  ]] || { echo "ERROR: AWS_REGION is not set."  >&2; usage; }

POLICY_NAME="topaz-audit-read"

# Resolve the directory this script lives in so the iam/*.json path and
# lib/*.sh sourcing work regardless of the caller's current working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IAM_DIR="${SCRIPT_DIR}/iam"
# shellcheck source=lib/aws-idempotent.sh
source "${SCRIPT_DIR}/lib/aws-idempotent.sh"
# shellcheck source=lib/validation.sh
source "${SCRIPT_DIR}/lib/validation.sh"

AUDIT_POLICY="${IAM_DIR}/audit-read-optional-policy.json"
[[ -f "$AUDIT_POLICY" ]] || { echo "ERROR: required policy file not found: $AUDIT_POLICY" >&2; exit 1; }

# ---------------------------------------------------------------------------
# [1/5] Resolve ROLE_NAME
# ---------------------------------------------------------------------------
if [[ -n "${ROLE_NAME:-}" ]]; then
  echo "==> [1/5] Using explicitly-set ROLE_NAME=${ROLE_NAME} (skipping auto-discovery)"
else
  echo "==> [1/5] Auto-discovering the role attached to ${INSTANCE_ID}'s instance profile"
  # Same lookup 00-verify-prerequisites.sh's [3/6] check performs: instance ->
  # instance profile -> role. Kept deliberately simpler here (no reconciliation
  # branches) because this script only READS the current association; it
  # never creates or repoints one the way 02-create-iam-role.sh does.
  ASSOC_ARN="$(aws ec2 describe-iam-instance-profile-associations \
    --region "$AWS_REGION" \
    --filters "Name=instance-id,Values=${INSTANCE_ID}" "Name=state,Values=associating,associated" \
    --query 'IamInstanceProfileAssociations[0].IamInstanceProfile.Arn' \
    --output text)"
  if [[ -z "$ASSOC_ARN" || "$ASSOC_ARN" == "None" ]]; then
    echo "ERROR: no IAM instance profile is associated with ${INSTANCE_ID}; cannot auto-discover its role." >&2
    echo "       Run 02-create-iam-role.sh first, or set ROLE_NAME explicitly." >&2
    exit 1
  fi
  PROFILE_NAME="${ASSOC_ARN##*/}"
  ROLE_NAME="$(aws iam get-instance-profile \
    --instance-profile-name "$PROFILE_NAME" \
    --query 'InstanceProfile.Roles[0].RoleName' \
    --output text)"
  if [[ -z "$ROLE_NAME" || "$ROLE_NAME" == "None" ]]; then
    echo "ERROR: instance profile ${PROFILE_NAME} has no role in it; cannot auto-discover a role for ${INSTANCE_ID}." >&2
    echo "       Set ROLE_NAME explicitly instead." >&2
    exit 1
  fi
  echo "    discovered role: ${ROLE_NAME}"
fi

# ---------------------------------------------------------------------------
# [2/5] Resolve the AWS account id (needed to build the role ARN and the
# managed policy's own ARN below).
# ---------------------------------------------------------------------------
echo "==> [2/5] Resolving AWS account id"
ACCOUNT_ID="$(aws sts get-caller-identity --query 'Account' --output text)"
echo "    account: ${ACCOUNT_ID}"

ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"

# ---------------------------------------------------------------------------
# [3/5] Render the policy's placeholder role ARN to the real one
# ---------------------------------------------------------------------------
# Mirrors 02-create-iam-role.sh's own METRIC_NAMESPACE rendering: a temp DIR
# (not just a temp file) so any scratch space is cleaned up too, a trap
# covering every exit path (success, error, a usage() exit), and plain bash
# string substitution rather than sed/jq -- sidestepping both a jq dependency
# and sed-delimiter collisions with an ARN that itself contains '/'. The
# literal '/' in the pattern below must be backslash-escaped for the SAME
# reason 02's own TopazRender\/GPU substitution escapes it: bash's
# ${var//pattern/replacement} would otherwise read the first unescaped '/' in
# pattern as the pattern/replacement delimiter.
echo "==> [3/5] Rendering ${AUDIT_POLICY}'s role ARN to ${ROLE_ARN}"
AUDIT_TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$AUDIT_TMP_DIR"' EXIT
AUDIT_POLICY_RENDERED="${AUDIT_TMP_DIR}/audit-read-optional-policy.json"
audit_policy_json="$(cat "$AUDIT_POLICY")"
audit_policy_json="${audit_policy_json//arn:aws:iam::123456789012:role\/topaz-render-instance-role/$ROLE_ARN}"
printf '%s' "$audit_policy_json" > "$AUDIT_POLICY_RENDERED"
# Defensive check: if the checked-in placeholder ARN ever drifts from the
# string this script substitutes, the render above would silently no-op and
# ship the LITERAL placeholder ARN in a real policy instead of failing loudly.
if ! grep -qF "$ROLE_ARN" "$AUDIT_POLICY_RENDERED"; then
  echo "ERROR: rendering ${AUDIT_POLICY}'s role ARN placeholder failed -- the rendered" >&2
  echo "       policy does not contain ${ROLE_ARN}. Check the placeholder ARN literal" >&2
  echo "       in both this script and ${AUDIT_POLICY} still match." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# [4/5] Create (or update) the managed policy
# ---------------------------------------------------------------------------
echo "==> [4/5] Creating (or updating) managed policy ${POLICY_NAME}"
echo "    aws iam create-policy --policy-name ${POLICY_NAME} --policy-document file://${AUDIT_POLICY_RENDERED}"
if run_idempotent "EntityAlreadyExists" aws iam create-policy \
      --policy-name "$POLICY_NAME" \
      --policy-document "file://${AUDIT_POLICY_RENDERED}" \
      --description "OPTIONAL/OPT-IN read-only control-plane audit permissions for an in-guest post-mortem. NOT required by the auto-stop pipeline. See control-plane/05-grant-audit-reads.sh."; then
  echo "    created ${POLICY_ARN}"
else
  echo "    NOTE: managed policy ${POLICY_NAME} already exists (${POLICY_ARN}); publishing an updated default version instead."
  # A managed policy keeps at most 5 versions; publishing a 6th fails with
  # LimitExceeded until an old one is pruned. Prune the oldest NON-default
  # version first (never the current default, and never more than the one
  # needed to make room) so a re-run of this script never fails here.
  VERSION_COUNT="$(aws iam list-policy-versions --policy-arn "$POLICY_ARN" --query 'length(Versions)' --output text)"
  if [[ "$VERSION_COUNT" -ge 5 ]]; then
    # shellcheck disable=SC2016 # single-quoted on purpose: this is JMESPath
    # (the `false` literal and &CreateDate expression are --query syntax, not
    # bash expansion), so it must NOT be double-quoted/interpolated.
    OLDEST_NON_DEFAULT="$(aws iam list-policy-versions --policy-arn "$POLICY_ARN" \
      --query 'sort_by(Versions[?IsDefaultVersion==`false`], &CreateDate)[0].VersionId' --output text)"
    if [[ -n "$OLDEST_NON_DEFAULT" && "$OLDEST_NON_DEFAULT" != "None" ]]; then
      echo "    at the 5-version cap (${VERSION_COUNT}); pruning oldest non-default version ${OLDEST_NON_DEFAULT} to make room"
      aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$OLDEST_NON_DEFAULT"
    fi
  fi
  aws iam create-policy-version \
    --policy-arn "$POLICY_ARN" \
    --policy-document "file://${AUDIT_POLICY_RENDERED}" \
    --set-as-default >/dev/null
fi

# ---------------------------------------------------------------------------
# [5/5] Attach the policy to the role
# ---------------------------------------------------------------------------
echo "==> [5/5] Attaching ${POLICY_NAME} to role ${ROLE_NAME}"
echo "    aws iam attach-role-policy --role-name ${ROLE_NAME} --policy-arn ${POLICY_ARN}"
# attach-role-policy is idempotent by nature: attaching an already-attached
# policy returns success, not an error, so no run_idempotent wrapping is
# needed here (matches 02-create-iam-role.sh's own put-role-policy comment).
aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn "$POLICY_ARN"

echo ""
echo "==> Done. ${ROLE_NAME} can now make READ-ONLY control-plane audit calls"
echo "    (CloudTrail, CloudWatch alarms/metrics, Lambda config, CloudWatch Logs,"
echo "    and its own attached-policy listing). Nothing here can create, modify,"
echo "    delete, start, stop, or terminate anything."
echo ""
echo "    REMINDER: this is OPTIONAL and EXPANDS this role's privilege beyond"
echo "    what the auto-stop pipeline needs. If this was a one-off investigation,"
echo "    consider revoking it when you are done:"
echo ""
echo "      aws iam detach-role-policy --role-name ${ROLE_NAME} --policy-arn ${POLICY_ARN}"
echo "      # delete-policy requires every NON-default version removed first --"
echo "      # list them, delete any extras, then delete the policy itself:"
echo "      aws iam list-policy-versions --policy-arn ${POLICY_ARN}"
echo "      aws iam delete-policy-version --policy-arn ${POLICY_ARN} --version-id <non-default-version-id>   # repeat per extra version"
echo "      aws iam delete-policy --policy-arn ${POLICY_ARN}"
