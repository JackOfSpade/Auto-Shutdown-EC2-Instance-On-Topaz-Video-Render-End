#!/usr/bin/env bash
#
# 00-verify-prerequisites.sh
#
# .SYNOPSIS
#   READ-ONLY verification of every control-plane prerequisite the out-of-band
#   safety net depends on. Makes NO mutating AWS API call.
#
# .DESCRIPTION
#   Run this FIRST, from an admin workstation with AWS CLI v2 configured and
#   real (non-instance-role) credentials, before running any of
#   01-set-shutdown-behavior.sh / 02-create-iam-role.sh / 03-create-idle-alarm.sh.
#   It reports, one line per check, OK / WARN / FAIL:
#
#     1. Caller identity (sts get-caller-identity) -- and whether the ARN looks
#        like an admin principal rather than THIS instance's own instance-role
#        credentials. An EC2 instance-profile assumed-role session's STS
#        session name IS the instance id, so an ARN ending in "/<INSTANCE_ID>"
#        is a dead giveaway this script is being run FROM the box itself using
#        its own (near-permissionless) role, not from an admin workstation.
#     2. InstanceInitiatedShutdownBehavior -- a LOUD failure if it reads back
#        anything other than 'stop', including if the read itself is denied.
#     3. Whether an IAM instance profile is attached to the instance, and the
#        name of the role inside it.
#     4. Whether that role's policies (inline + managed) grant
#        cloudwatch:PutMetricData, and whether the policy text looks scoped to
#        METRIC_NAMESPACE.
#     5. Whether the per-instance idle alarm (topaz-gpu-idle-autostop-<id>)
#        exists, its current state, and whether its alarm actions are enabled.
#        NOTE that this alarm is OPT-IN and, for THIS project, deliberately
#        absent: the operator decided on 2026-07-28 against any idle-based
#        auto-stop (see 03-create-idle-alarm.sh's .DECISION header and
#        docs/09-appendix-b-boundaries.md Sec 5). Its absence is the INTENDED
#        state here and is reported as a [WARN] purely so the line stays
#        visible in the report -- it is not a defect to fix, and
#        docs/11-deploying-on-this-instance.md's troubleshooting table
#        documents that [WARN] as expected on this box.
#     6. Whether the AutoStopEligible=true tag is present (optional -- only
#        required for INCLUDE_EC2_STOP=1 on 02, or the max-lifetime Lambda).
#
#   Every AWS call here is a describe-/get-/list- read call. Nothing is ever
#   created, modified, deleted, enabled, disabled, or associated. Safe to run
#   at any time, as often as you like, from any principal with sufficient read
#   permissions -- including re-running it after each of 01/02/03 to confirm
#   the fix took.
#
# .NOTES
#   Run from an admin workstation with AWS CLI v2 configured.
#   Requires env vars: INSTANCE_ID, AWS_REGION.
#   Optional env var:  METRIC_NAMESPACE (default TopazRender/GPU) -- must
#   match 02-create-iam-role.sh's and 03-create-idle-alarm.sh's own
#   METRIC_NAMESPACE override, or this script checks the wrong namespace.
#   METRIC_NAME is accepted for backward compatibility but is NOT used by
#   [4/6]'s pass/fail logic: the role's cloudwatch:PutMetricData grant is
#   scoped to the NAMESPACE only (CloudWatch metrics are not ARN-addressable),
#   so it already covers every metric name published into it -- both the
#   default RenderActive and the legacy GPUUtilization -- with no per-metric
#   IAM distinction to check.
#   Exit code: 0 only if every check reported OK or WARN (no FAIL). 1 if any
#   check FAILed.
#
set -euo pipefail

# Resolve the directory this script lives in so lib/*.sh sourcing works
# regardless of the caller's current working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/validation.sh
source "${SCRIPT_DIR}/lib/validation.sh"

usage() {
  cat >&2 <<'EOF'
Usage: INSTANCE_ID=i-XXXXXXXXXXXXXXXXX AWS_REGION=<region> ./00-verify-prerequisites.sh

Required environment variables:
  INSTANCE_ID       The target EC2 instance id (e.g. i-XXXXXXXXXXXXXXXXX)
  AWS_REGION        The AWS region the instance lives in (e.g. <region>)

Optional environment variables:
  METRIC_NAMESPACE  CloudWatch namespace the PutMetricData grant is expected
                    to be scoped to (default TopazRender/GPU). Must match
                    in-guest/Config.ps1's MetricNamespace and the value passed
                    to 02-create-iam-role.sh / 03-create-idle-alarm.sh.
  METRIC_NAME       Accepted for backward compatibility; NOT used by [4/6]'s
                    pass/fail check. The role's PutMetricData grant is scoped
                    to METRIC_NAMESPACE only, which already covers every
                    metric name the box can publish into it (the default
                    RenderActive and the legacy GPUUtilization alike), so
                    naming one metric here would not make the check any more
                    accurate.

This script is READ-ONLY: it makes no create/put/modify/associate/enable/
disable AWS API call. It only describes, gets, and lists.
EOF
  exit 1
}

[[ -n "${INSTANCE_ID:-}" ]] || { echo "ERROR: INSTANCE_ID is not set." >&2; usage; }
[[ -n "${AWS_REGION:-}"  ]] || { echo "ERROR: AWS_REGION is not set."  >&2; usage; }
is_valid_instance_id "$INSTANCE_ID" || {
  echo "ERROR: INSTANCE_ID='${INSTANCE_ID}' is not a valid EC2 instance id (expected i- followed by 8 or 17 hex digits)." >&2
  usage
}

# METRIC_NAME has no meaningful default any more: which metric "matters" now
# depends on IDLE_SIGNAL (render -> RenderActive, gpu -> GPUUtilization), a
# choice this read-only script never asks for, and [4/6] below checks only
# the NAMESPACE-scoped grant anyway (see the .NOTES/usage text above). Left
# unset unless the caller overrides it, rather than defaulting to either
# metric name and silently implying that one is the one that matters.
METRIC_NAMESPACE="${METRIC_NAMESPACE:-TopazRender/GPU}"
METRIC_NAME="${METRIC_NAME:-}"
# WHY per-instance name: mirrors 03-create-idle-alarm.sh's own ALARM_NAME
# construction exactly -- a mismatch here would silently check the wrong alarm.
ALARM_NAME="topaz-gpu-idle-autostop-${INSTANCE_ID}"

OK_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

# report <OK|WARN|FAIL> <message...> -- one line per check, tallied for the
# final summary and exit-code decision. FAIL never exits early: every check
# below is independent, and stopping at the first FAIL would hide the rest of
# the picture from an operator who needs to fix everything in one pass.
report() {
  local level="$1"; shift
  case "$level" in
    OK)   OK_COUNT=$((OK_COUNT + 1));   printf '[OK]   %s\n' "$*" ;;
    WARN) WARN_COUNT=$((WARN_COUNT + 1)); printf '[WARN] %s\n' "$*" ;;
    FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)); printf '[FAIL] %s\n' "$*" ;;
    *)    echo "internal error: report() got unknown level '$level'" >&2; exit 1 ;;
  esac
}

# flatten_err <text> -- collapse a captured AWS CLI stderr blob to one line
# and drop everything from IAM's opaque base64 "Encoded authorization failure
# message" onward. That blob is not human-readable here (decode it separately
# with `aws sts decode-authorization-message` if you need the exact denied
# statement) and, left in, turns a single [FAIL]/[WARN] line into hundreds of
# characters of noise -- exactly what "one line per check" is meant to avoid.
flatten_err() {
  local flat
  flat="$(printf '%s' "$1" | tr '\n' ' ' | tr -s ' ')"
  flat="${flat%%Encoded authorization failure message:*}"
  flat="${flat%"${flat##*[![:space:]]}"}"
  printf '%s' "$flat"
}

echo "==> Verifying control-plane prerequisites for ${INSTANCE_ID} in ${AWS_REGION}"
echo "    READ-ONLY: no create/put/modify/associate/enable/disable call is made."
echo ""

# ---------------------------------------------------------------------------
# [1/6] Caller identity
# ---------------------------------------------------------------------------
echo "==> [1/6] Caller identity"
if IDENTITY_LINE="$(aws sts get-caller-identity --query '[Arn,Account]' --output text 2>&1)"; then
  CALLER_ARN="$(printf '%s' "$IDENTITY_LINE" | cut -f1)"
  CALLER_ACCOUNT="$(printf '%s' "$IDENTITY_LINE" | cut -f2)"
  if [[ -z "$CALLER_ARN" || "$CALLER_ARN" == "None" ]]; then
    report WARN "sts get-caller-identity returned no usable Arn; cannot evaluate caller identity."
  elif [[ "$CALLER_ARN" == *"/${INSTANCE_ID}" ]]; then
    # An EC2 instance-profile assumed-role session's STS session name IS the
    # instance id -- so an ARN ending in "/<INSTANCE_ID>" means this script is
    # running FROM the box, using the very role whose permissions the rest of
    # this report is trying to diagnose.
    report WARN "caller ARN (${CALLER_ARN}) ends in this instance's own id -- that is how an EC2 instance-profile assumed-role session is named. This looks like it is running FROM ${INSTANCE_ID} using its OWN role, not from an admin workstation with separate credentials. The remaining checks may themselves be denied."
  else
    report OK "caller identity: ${CALLER_ARN} (account ${CALLER_ACCOUNT}) -- does not look like ${INSTANCE_ID}'s own instance-role session."
  fi
else
  report FAIL "aws sts get-caller-identity failed: $(flatten_err "$IDENTITY_LINE"). Configure AWS CLI v2 credentials on this admin workstation before proceeding."
fi

# ---------------------------------------------------------------------------
# [2/6] InstanceInitiatedShutdownBehavior
# ---------------------------------------------------------------------------
echo ""
echo "==> [2/6] InstanceInitiatedShutdownBehavior"
if SHUTDOWN_BEHAVIOR="$(aws ec2 describe-instance-attribute \
      --instance-id "$INSTANCE_ID" \
      --region "$AWS_REGION" \
      --attribute instanceInitiatedShutdownBehavior \
      --query 'InstanceInitiatedShutdownBehavior.Value' \
      --output text 2>&1)"; then
  if is_shutdown_behavior_confirmed "$SHUTDOWN_BEHAVIOR"; then
    report OK "InstanceInitiatedShutdownBehavior='stop' -- a guest shutdown will STOP (not terminate) this instance."
  else
    # tr, not ${SHUTDOWN_BEHAVIOR^^}: the ^^ uppercase expansion is bash 4.0+,
    # and macOS still ships /bin/bash 3.2.57, which `#!/usr/bin/env bash`
    # resolves to on any admin workstation without a newer bash earlier in
    # PATH. `bash -n` parses ^^ fine on 3.2 (so a syntax pre-check misses it)
    # and it only blows up at RUNTIME, with "bad substitution" -- aborting the
    # script mid-report. It would have done so on exactly this line: the one
    # that fires when a guest shutdown would TERMINATE the box. shellcheck
    # does not flag bash-version features either (verified 0.11.0, even with
    # --enable=all), which is why this stays a comment and not a lint rule.
    SHUTDOWN_BEHAVIOR_UPPER="$(printf '%s' "$SHUTDOWN_BEHAVIOR" | tr '[:lower:]' '[:upper:]')"
    report FAIL "!!! InstanceInitiatedShutdownBehavior='${SHUTDOWN_BEHAVIOR}', NOT 'stop' !!! A guest-OS shutdown issued by the watchdog would ${SHUTDOWN_BEHAVIOR_UPPER} this instance, destroying it, not stop it. DO NOT flip DryRun to \$false until this reads back 'stop'. Fix: INSTANCE_ID=${INSTANCE_ID} AWS_REGION=${AWS_REGION} ./01-set-shutdown-behavior.sh"
  fi
else
  report FAIL "!!! could not read InstanceInitiatedShutdownBehavior: $(flatten_err "$SHUTDOWN_BEHAVIOR") !!! This is UNVERIFIABLE from here -- until it is confirmed 'stop', DryRun MUST stay \$true. Retry from an admin workstation with ec2:DescribeInstanceAttribute (the instance role itself is commonly denied this action)."
fi

# ---------------------------------------------------------------------------
# [3/6] IAM instance profile + role name
# ---------------------------------------------------------------------------
echo ""
echo "==> [3/6] IAM instance profile"
ROLE_NAME=""
if ASSOC_LINE="$(aws ec2 describe-iam-instance-profile-associations \
      --region "$AWS_REGION" \
      --filters "Name=instance-id,Values=${INSTANCE_ID}" "Name=state,Values=associating,associated" \
      --query 'IamInstanceProfileAssociations[0].[IamInstanceProfile.Arn,State]' \
      --output text 2>&1)"; then
  PROFILE_ARN="$(printf '%s' "$ASSOC_LINE" | cut -f1)"
  ASSOC_STATE="$(printf '%s' "$ASSOC_LINE" | cut -f2)"
  if [[ -z "$PROFILE_ARN" || "$PROFILE_ARN" == "None" ]]; then
    report FAIL "no IAM instance profile is attached to ${INSTANCE_ID}. The watchdog cannot publish the GPU metric without one. Fix: INSTANCE_ID=${INSTANCE_ID} AWS_REGION=${AWS_REGION} ./02-create-iam-role.sh"
  else
    PROFILE_NAME="${PROFILE_ARN##*/}"
    if ROLE_NAME="$(aws iam get-instance-profile \
          --instance-profile-name "$PROFILE_NAME" \
          --query 'InstanceProfile.Roles[0].RoleName' \
          --output text 2>&1)"; then
      if [[ -z "$ROLE_NAME" || "$ROLE_NAME" == "None" ]]; then
        report FAIL "instance profile ${PROFILE_NAME} is attached (state ${ASSOC_STATE}) but has NO role in it. Fix: INSTANCE_ID=${INSTANCE_ID} AWS_REGION=${AWS_REGION} ./02-create-iam-role.sh"
        ROLE_NAME=""
      else
        report OK "instance profile ${PROFILE_NAME} attached (state ${ASSOC_STATE}), role ${ROLE_NAME}."
      fi
    else
      report FAIL "instance profile ${PROFILE_NAME} is attached but 'aws iam get-instance-profile' failed: $(flatten_err "$ROLE_NAME")."
      ROLE_NAME=""
    fi
  fi
else
  report FAIL "could not query IAM instance profile associations for ${INSTANCE_ID}: $(flatten_err "$ASSOC_LINE")."
fi

# ---------------------------------------------------------------------------
# [4/6] cloudwatch:PutMetricData grant, scoped to METRIC_NAMESPACE
# ---------------------------------------------------------------------------
echo ""
echo "==> [4/6] cloudwatch:PutMetricData grant (namespace ${METRIC_NAMESPACE})"
if [[ -z "$ROLE_NAME" ]]; then
  report FAIL "cannot check policies -- no role to inspect (see the instance-profile check above)."
else
  ALL_POLICY_DOCS=""
  POLICY_LOOKUP_ERROR=0

  if INLINE_NAMES="$(aws iam list-role-policies --role-name "$ROLE_NAME" --query 'PolicyNames' --output text 2>&1)"; then
    [[ "$INLINE_NAMES" == "None" ]] && INLINE_NAMES=""
  else
    report WARN "could not list inline policies on ${ROLE_NAME}: $(flatten_err "$INLINE_NAMES")"
    INLINE_NAMES=""
    POLICY_LOOKUP_ERROR=1
  fi
  if [[ -n "$INLINE_NAMES" ]]; then
    read -ra INLINE_NAME_ARR <<< "$INLINE_NAMES"
    for pol in "${INLINE_NAME_ARR[@]}"; do
      if DOC="$(aws iam get-role-policy --role-name "$ROLE_NAME" --policy-name "$pol" --query 'PolicyDocument' --output json 2>&1)"; then
        ALL_POLICY_DOCS+="$DOC"$'\n'
      else
        report WARN "could not read inline policy '${pol}' on ${ROLE_NAME}: $(flatten_err "$DOC")"
        POLICY_LOOKUP_ERROR=1
      fi
    done
  fi

  if MANAGED_ARNS="$(aws iam list-attached-role-policies --role-name "$ROLE_NAME" --query 'AttachedPolicies[].PolicyArn' --output text 2>&1)"; then
    [[ "$MANAGED_ARNS" == "None" ]] && MANAGED_ARNS=""
  else
    report WARN "could not list managed policies on ${ROLE_NAME}: $(flatten_err "$MANAGED_ARNS")"
    MANAGED_ARNS=""
    POLICY_LOOKUP_ERROR=1
  fi
  if [[ -n "$MANAGED_ARNS" ]]; then
    read -ra MANAGED_ARN_ARR <<< "$MANAGED_ARNS"
    for arn in "${MANAGED_ARN_ARR[@]}"; do
      if VERSION_ID="$(aws iam get-policy --policy-arn "$arn" --query 'Policy.DefaultVersionId' --output text 2>&1)"; then
        if DOC="$(aws iam get-policy-version --policy-arn "$arn" --version-id "$VERSION_ID" --query 'PolicyVersion.Document' --output json 2>&1)"; then
          ALL_POLICY_DOCS+="$DOC"$'\n'
        else
          report WARN "could not read managed policy version for ${arn}: $(flatten_err "$DOC")"
          POLICY_LOOKUP_ERROR=1
        fi
      else
        report WARN "could not resolve default version for managed policy ${arn}: $(flatten_err "$VERSION_ID")"
        POLICY_LOOKUP_ERROR=1
      fi
    done
  fi

  if [[ -z "$INLINE_NAMES" && -z "$MANAGED_ARNS" && "$POLICY_LOOKUP_ERROR" -eq 0 ]]; then
    report FAIL "role ${ROLE_NAME} has NO inline or managed policies attached at all -- cloudwatch:PutMetricData is not granted. Fix: INSTANCE_ID=${INSTANCE_ID} AWS_REGION=${AWS_REGION} ./02-create-iam-role.sh"
  elif printf '%s' "$ALL_POLICY_DOCS" | grep -qE 'cloudwatch:(PutMetricData|\*)'; then
    if printf '%s' "$ALL_POLICY_DOCS" | grep -qF -- "$METRIC_NAMESPACE"; then
      report OK "role ${ROLE_NAME} grants cloudwatch:PutMetricData, and its policy text mentions namespace '${METRIC_NAMESPACE}'."
    else
      report WARN "role ${ROLE_NAME} grants cloudwatch:PutMetricData but no policy text mentions namespace '${METRIC_NAMESPACE}' -- verify the condition scoping manually (aws iam get-role-policy --role-name ${ROLE_NAME} --policy-name <name>)."
    fi
  else
    report FAIL "role ${ROLE_NAME} has policies attached but NONE grant cloudwatch:PutMetricData scoped to namespace ${METRIC_NAMESPACE}. The watchdog cannot publish either metric it produces (RenderActive or GPUUtilization) into that namespace; the idle-alarm safety net has nothing to watch, on any IDLE_SIGNAL. Fix: INSTANCE_ID=${INSTANCE_ID} AWS_REGION=${AWS_REGION} ./02-create-iam-role.sh"
  fi
fi

# ---------------------------------------------------------------------------
# [5/6] Idle-stop CloudWatch alarm
# ---------------------------------------------------------------------------
echo ""
echo "==> [5/6] Idle-stop CloudWatch alarm (${ALARM_NAME})"
if ALARM_LINE="$(aws cloudwatch describe-alarms \
      --region "$AWS_REGION" \
      --alarm-names "$ALARM_NAME" \
      --query 'MetricAlarms[0].[StateValue,ActionsEnabled]' \
      --output text 2>&1)"; then
  ALARM_STATE="$(printf '%s' "$ALARM_LINE" | cut -f1)"
  ALARM_ACTIONS_ENABLED="$(printf '%s' "$ALARM_LINE" | cut -f2)"
  # WHY these two stay [WARN] and not [OK], even though both describe an
  # intended state: docs/11-deploying-on-this-instance.md's troubleshooting
  # table documents "[5/6] reports [WARN]: alarm does not exist" as EXPECTED on
  # this box, so promoting it to OK would desync the runbook. The level is
  # deliberately unchanged; only the text is, because the old text called the
  # intended state something to "Fix" and printed a command 03 now refuses.
  if [[ -z "$ALARM_STATE" || "$ALARM_STATE" == "None" ]]; then
    report WARN "alarm ${ALARM_NAME} does not exist -- EXPECTED for this project. Idle-based auto-stop was decided against on 2026-07-28 (see 03-create-idle-alarm.sh's .DECISION header and docs/09-appendix-b-boundaries.md Sec 5); the GPU-keyed version of this alarm came within five minutes of stopping a healthy render on 2026-07-27. This is the intended state, NOT something to fix. Only if you deliberately want an idle cap for a different deployment: INSTANCE_ID=${INSTANCE_ID} AWS_REGION=${AWS_REGION} ENABLE_IDLE_ALARM=1 ./03-create-idle-alarm.sh (03 refuses without that opt-in)."
  elif [[ "$ALARM_ACTIONS_ENABLED" != "True" ]]; then
    report WARN "alarm ${ALARM_NAME} exists (state ${ALARM_STATE}) with its actions DISABLED -- i.e. PAUSED: it will not stop the instance even if it fires. That may be deliberate; 03-create-idle-alarm.sh itself advises pausing the actions before a long pre-render setup. To resume it when the setup is done: aws cloudwatch enable-alarm-actions --region ${AWS_REGION} --alarm-names ${ALARM_NAME}"
  elif [[ "$ALARM_STATE" == "ALARM" ]]; then
    report WARN "alarm ${ALARM_NAME} exists, actions ENABLED, and is currently IN ALARM state -- it may stop this instance imminently if that action is the built-in ec2:stop action."
  else
    report OK "alarm ${ALARM_NAME} exists, actions ENABLED, state ${ALARM_STATE}."
  fi
else
  report WARN "could not query alarm ${ALARM_NAME}: $(flatten_err "$ALARM_LINE")."
fi

# ---------------------------------------------------------------------------
# [6/6] AutoStopEligible tag
# ---------------------------------------------------------------------------
echo ""
echo "==> [6/6] AutoStopEligible tag"
if TAG_VALUE="$(aws ec2 describe-tags \
      --region "$AWS_REGION" \
      --filters "Name=resource-id,Values=${INSTANCE_ID}" "Name=key,Values=AutoStopEligible" \
      --query 'Tags[0].Value' \
      --output text 2>&1)"; then
  if [[ "$TAG_VALUE" == "true" ]]; then
    report OK "AutoStopEligible=true tag is present (required for INCLUDE_EC2_STOP=1's tag-scoped ec2:StopInstances grant on 02-create-iam-role.sh, and for the optional max-lifetime Lambda; not required by a guest-shutdown-only stop path)."
  else
    report WARN "AutoStopEligible=true tag is NOT present (read back: '${TAG_VALUE}'). Not required by a guest-shutdown-only stop path, but required if you use INCLUDE_EC2_STOP=1 on 02-create-iam-role.sh (e.g. for a Config.ps1 StopStrategy of 'Ec2ApiStop'/'Auto') or deploy 04-deploy-max-lifetime-lambda.sh."
  fi
else
  report WARN "could not read tags on ${INSTANCE_ID}: $(flatten_err "$TAG_VALUE")."
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "==> Summary: ${OK_COUNT} OK, ${WARN_COUNT} WARN, ${FAIL_COUNT} FAIL"
if [[ "$FAIL_COUNT" -gt 0 ]]; then
  echo "==> RESULT: FAIL -- fix the [FAIL] line(s) above before doing anything else." >&2
  echo "    See docs/11-deploying-on-this-instance.md for the exact commands." >&2
  exit 1
fi
echo "==> RESULT: OK -- no FAILs. Review any [WARN] line(s) above, then proceed."
exit 0
