#!/usr/bin/env bash
#
# 04-deploy-max-lifetime-lambda.sh
#
# .SYNOPSIS
#   Deploy the OPTIONAL hard max-lifetime cap Lambda + its schedule.
#
# .DESCRIPTION
#   This is a purely optional last-resort cost guard. Independent of the on-box
#   watchdog and the idle alarm, it enforces an absolute ceiling: if the instance
#   has been running longer than MAX_LIFETIME_HOURS, stop it -- no matter what the
#   GPU is doing. This protects you from a runaway render / stuck job / forgotten
#   box that somehow keeps the GPU busy past any reasonable session length.
#
#   Steps performed here:
#     1. Tag the instance AutoStopEligible=true (the Lambda's stop permission
#        is tag-scoped -- see iam/lambda-execution-policy.json)
#     2. Zip the Lambda source at ../lambda/max-lifetime-stop
#     3. Create the Lambda execution role (iam/lambda-execution-policy.json)
#     4. Create the Lambda function (handler wired to that zip)
#     5. Create an EventBridge Scheduler schedule (falls back to a CloudWatch
#        Events rule) that invokes the function on a fixed cadence
#
#   The ceiling is parameterized via env MAX_LIFETIME_HOURS (default 12) and is
#   passed to the Lambda as an environment variable, so the function reads the
#   instance launch time and compares against it.
#
# .NOTES
#   Run from an admin workstation with AWS CLI v2 configured.
#   Requires env vars: INSTANCE_ID, AWS_REGION.
#   Optional env var:  MAX_LIFETIME_HOURS (default 12) -- must be a positive,
#   finite number (matches handler.py's own validation); an invalid value
#   (including one so large it overflows to infinity) is rejected here at
#   deploy time rather than silently deploying a Lambda that falls back to its
#   own default and lies about the effective ceiling.
#
#   PREREQUISITES / assumptions:
#     * The Lambda source directory ../lambda/max-lifetime-stop exists and
#       contains a handler (e.g. handler.py exporting handler(event, context)).
#     * You have `zip` available on the admin workstation.
#     * EventBridge Scheduler is available in AWS_REGION; if not, this script
#       falls back to a classic CloudWatch Events (EventBridge) rule.
#     * THIS WHOLE STAGE IS OPTIONAL. If you do not want a hard cap, skip it.
#
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: INSTANCE_ID=i-XXXXXXXXXXXXXXXXX AWS_REGION=<region> [MAX_LIFETIME_HOURS=12] ./04-deploy-max-lifetime-lambda.sh

Required environment variables:
  INSTANCE_ID         The target EC2 instance id (e.g. i-XXXXXXXXXXXXXXXXX)
  AWS_REGION          The AWS region the instance lives in (e.g. <region>)

Optional environment variables:
  MAX_LIFETIME_HOURS  Absolute run-time ceiling in hours (default 12).
                      Must be a positive number, e.g. 12 or 4.5.
EOF
  exit 1
}

if [[ -z "${INSTANCE_ID:-}" ]]; then echo "ERROR: INSTANCE_ID is not set." >&2; usage; fi
if [[ -z "${AWS_REGION:-}"  ]]; then echo "ERROR: AWS_REGION is not set."  >&2; usage; fi

# Resolve the directory this script lives in so the iam/*.json paths and
# lib/*.sh sourcing work regardless of the caller's current working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/aws-idempotent.sh
source "${SCRIPT_DIR}/lib/aws-idempotent.sh"
# shellcheck source=lib/validation.sh
source "${SCRIPT_DIR}/lib/validation.sh"

MAX_LIFETIME_HOURS="${MAX_LIFETIME_HOURS:-12}"
# Mirror handler.py's own validation here so a bad value fails LOUDLY at
# deploy time instead of deploying "successfully" while the Lambda silently
# substitutes its default 12h ceiling -- the deploy output would otherwise
# lie about the effective cap.
if ! is_valid_max_lifetime_hours "$MAX_LIFETIME_HOURS"; then
  echo "ERROR: MAX_LIFETIME_HOURS must be a positive number, e.g. 12 or 4.5 (got '${MAX_LIFETIME_HOURS}')." >&2
  usage
fi

# WHY per-instance names: like the idle alarm, create-function/create-schedule
# target a fixed name -- a shared name would let a second instance's deploy
# silently clobber (re-target) the first instance's function and schedule.
FUNCTION_NAME="topaz-max-lifetime-stop-${INSTANCE_ID}"
SCHEDULE_NAME="topaz-max-lifetime-schedule-${INSTANCE_ID}"
# WHY shared (not per-instance): unlike the function/schedule above, every
# instance's execution policy is byte-for-byte identical and tag-scoped
# (aws:ResourceTag/AutoStopEligible=true, see iam/lambda-execution-policy.json)
# -- there is nothing instance-specific to separate, so one role safely serves
# every instance.
LAMBDA_ROLE_NAME="topaz-max-lifetime-lambda-role"
HANDLER="handler.handler"
RUNTIME="python3.12"
SCHEDULE_EXPRESSION="rate(30 minutes)"
# Keep the Scheduler definition declarative. `update-schedule` replaces the
# schedule's mutable settings rather than patching individual fields, so the
# create and update paths must use the same complete desired state. Without
# that, a re-deploy after changing the cadence/function/role would silently
# leave an old schedule invoking the wrong target or staying disabled.
SCHEDULE_TIMEZONE="UTC"
SCHEDULE_FLEXIBLE_TIME_WINDOW='{"Mode":"OFF"}'
SCHEDULE_STATE="ENABLED"
SCHEDULE_TARGET_INPUT='{}'

IAM_DIR="${SCRIPT_DIR}/iam"
LAMBDA_SRC_DIR="${SCRIPT_DIR}/../lambda/max-lifetime-stop"
LAMBDA_EXEC_POLICY="${IAM_DIR}/lambda-execution-policy.json"
TRUST_POLICY_JSON='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

# A temp DIR (not just a temp file) so the zip step's own scratch space is
# cleaned up too; the trap covers every exit path (success, error, a usage()
# exit) so a per-run temp dir is never leaked on the admin workstation.
ZIP_TMP_DIR="$(mktemp -d)"
ZIP_PATH="${ZIP_TMP_DIR}/max-lifetime-stop.zip"
trap 'rm -rf "$ZIP_TMP_DIR"' EXIT

echo "==> [0/5] Sanity checks"
[[ -d "$LAMBDA_SRC_DIR" ]]     || { echo "ERROR: Lambda source dir not found: ${LAMBDA_SRC_DIR}" >&2; exit 1; }
[[ -f "$LAMBDA_EXEC_POLICY" ]] || { echo "ERROR: execution policy not found: ${LAMBDA_EXEC_POLICY}" >&2; exit 1; }
command -v zip >/dev/null 2>&1 || { echo "ERROR: 'zip' is required but not installed." >&2; exit 1; }

# WHY tag first: the Lambda's ec2:StopInstances permission (see
# iam/lambda-execution-policy.json) is conditioned on
# aws:ResourceTag/AutoStopEligible=true. Nothing else in this pipeline ever
# applies that tag -- without it, the Lambda's stop call fails
# UnauthorizedOperation every time it fires, a silently dead safety net.
# create-tags is idempotent, so this is safe to re-run.
echo "==> [1/5] Tagging ${INSTANCE_ID} with AutoStopEligible=true (required by the Lambda's tag-scoped stop permission)"
echo "    aws ec2 create-tags --region ${AWS_REGION} --resources ${INSTANCE_ID} --tags Key=AutoStopEligible,Value=true"
aws ec2 create-tags \
  --region "$AWS_REGION" \
  --resources "$INSTANCE_ID" \
  --tags Key=AutoStopEligible,Value=true

echo "==> [2/5] Zipping Lambda source ${LAMBDA_SRC_DIR} -> ${ZIP_PATH}"
# Zip ONLY the runtime file(s) the Lambda actually needs -- not the test
# suite, conftest.py, requirements-dev.txt, README, or any stale __pycache__
# bytecode that previously rode along via `zip -r .`. Add new runtime modules
# to this list explicitly as they're introduced; never fall back to `-r .`.
( cd "$LAMBDA_SRC_DIR" && zip -q "$ZIP_PATH" handler.py )
echo "    built ${ZIP_PATH}"

echo "==> [3/5] Creating the Lambda execution role ${LAMBDA_ROLE_NAME}"
echo "    aws iam create-role --role-name ${LAMBDA_ROLE_NAME} --assume-role-policy-document <lambda trust policy>"
if ! run_idempotent "EntityAlreadyExists" aws iam create-role \
      --role-name "$LAMBDA_ROLE_NAME" \
      --assume-role-policy-document "$TRUST_POLICY_JSON" \
      --description "Execution role for the Topaz max-lifetime-stop Lambda"; then
  echo "    NOTE: role ${LAMBDA_ROLE_NAME} already exists; reusing it."
fi

echo "    aws iam put-role-policy --role-name ${LAMBDA_ROLE_NAME} --policy-name topaz-lambda-exec --policy-document file://${LAMBDA_EXEC_POLICY}"
aws iam put-role-policy \
  --role-name "$LAMBDA_ROLE_NAME" \
  --policy-name "topaz-lambda-exec" \
  --policy-document "file://${LAMBDA_EXEC_POLICY}"

echo "    Resolving role ARN..."
LAMBDA_ROLE_ARN="$(aws iam get-role --role-name "$LAMBDA_ROLE_NAME" --query 'Role.Arn' --output text)"
echo "    role arn: ${LAMBDA_ROLE_ARN}"

echo "    Waiting for IAM role to propagate before creating the function..."
sleep 10

echo "==> [4/5] Creating (or updating) Lambda function ${FUNCTION_NAME}"
echo "    env: INSTANCE_ID=${INSTANCE_ID} AWS_TARGET_REGION=${AWS_REGION} MAX_LIFETIME_HOURS=${MAX_LIFETIME_HOURS}"
echo "    aws lambda create-function --region ${AWS_REGION} --function-name ${FUNCTION_NAME} ..."
if ! run_idempotent "ResourceConflictException|Function already exist" aws lambda create-function \
      --region "$AWS_REGION" \
      --function-name "$FUNCTION_NAME" \
      --runtime "$RUNTIME" \
      --role "$LAMBDA_ROLE_ARN" \
      --handler "$HANDLER" \
      --timeout 30 \
      --zip-file "fileb://${ZIP_PATH}" \
      --environment "Variables={INSTANCE_ID=${INSTANCE_ID},AWS_TARGET_REGION=${AWS_REGION},MAX_LIFETIME_HOURS=${MAX_LIFETIME_HOURS}}"; then
  echo "    NOTE: function ${FUNCTION_NAME} already exists; updating code + config instead."
  aws lambda update-function-code \
    --region "$AWS_REGION" \
    --function-name "$FUNCTION_NAME" \
    --zip-file "fileb://${ZIP_PATH}" >/dev/null
  # update-function-code returns while the deploy is still InProgress; a
  # config update issued before it settles fails with ResourceConflictException.
  # Wait for the function to leave the InProgress state before updating config.
  aws lambda wait function-updated-v2 \
    --region "$AWS_REGION" \
    --function-name "$FUNCTION_NAME" 2>/dev/null \
    || aws lambda wait function-updated \
         --region "$AWS_REGION" \
         --function-name "$FUNCTION_NAME"
  aws lambda update-function-configuration \
    --region "$AWS_REGION" \
    --function-name "$FUNCTION_NAME" \
    --environment "Variables={INSTANCE_ID=${INSTANCE_ID},AWS_TARGET_REGION=${AWS_REGION},MAX_LIFETIME_HOURS=${MAX_LIFETIME_HOURS}}" >/dev/null
fi

FUNCTION_ARN="$(aws lambda get-function --region "$AWS_REGION" --function-name "$FUNCTION_NAME" --query 'Configuration.FunctionArn' --output text)"
echo "    function arn: ${FUNCTION_ARN}"

# WHY factored: the classic-CloudWatch-Events fallback (put-rule +
# add-permission + put-targets, same statement-id) used to be duplicated
# verbatim in both fallback branches below (no SCHEDULER_ROLE_ARN configured,
# and no `aws scheduler` CLI at all) -- this is the single implementation both
# call, parameterized only on the schedule expression (both branches always
# pass the same "$SCHEDULE_EXPRESSION" anyway).
create_classic_eventbridge_rule() {
  local expr="$1"
  local rule_arn
  echo "    aws events put-rule --region ${AWS_REGION} --name ${SCHEDULE_NAME} --schedule-expression '${expr}'"
  rule_arn="$(aws events put-rule \
    --region "$AWS_REGION" \
    --name "$SCHEDULE_NAME" \
    --schedule-expression "$expr" \
    --query 'RuleArn' --output text)"
  echo "    aws lambda add-permission (allow events.amazonaws.com to invoke ${FUNCTION_NAME})"
  if ! run_idempotent "ResourceConflictException" aws lambda add-permission \
        --region "$AWS_REGION" \
        --function-name "$FUNCTION_NAME" \
        --statement-id "topaz-max-lifetime-eventbridge" \
        --action "lambda:InvokeFunction" \
        --principal "events.amazonaws.com" \
        --source-arn "$rule_arn"; then
    echo "    NOTE: permission already exists; continuing."
  fi
  echo "    aws events put-targets --region ${AWS_REGION} --rule ${SCHEDULE_NAME} --targets Id=1,Arn=${FUNCTION_ARN}"
  aws events put-targets \
    --region "$AWS_REGION" \
    --rule "$SCHEDULE_NAME" \
    --targets "Id=1,Arn=${FUNCTION_ARN}"
}

reconcile_eventbridge_scheduler_schedule() {
  # EventBridge Scheduler's update API is a full reconciliation operation, not
  # a partial patch: expression, timezone, flexible window, target (including
  # its input), and enabled state are all supplied on every update. Keeping the
  # desired target JSON in one place prevents an existing schedule from drifting
  # away from the create path on a later deployment.
  local scheduler_target
  scheduler_target="{\"Arn\":\"${FUNCTION_ARN}\",\"RoleArn\":\"${SCHEDULER_ROLE_ARN}\",\"Input\":\"${SCHEDULE_TARGET_INPUT}\"}"

  echo "    aws scheduler create-schedule --region ${AWS_REGION} --name ${SCHEDULE_NAME} ..."
  if run_idempotent "ConflictException|already exists" aws scheduler create-schedule \
        --region "$AWS_REGION" \
        --name "$SCHEDULE_NAME" \
        --schedule-expression "$SCHEDULE_EXPRESSION" \
        --schedule-expression-timezone "$SCHEDULE_TIMEZONE" \
        --flexible-time-window "$SCHEDULE_FLEXIBLE_TIME_WINDOW" \
        --target "$scheduler_target" \
        --state "$SCHEDULE_STATE"; then
    echo "    Created schedule ${SCHEDULE_NAME}."
    return
  fi

  # run_idempotent only returns nonzero for a recognized idempotency conflict;
  # all other failures exit the script after printing stderr. Reconcile the
  # existing schedule instead of preserving a possibly stale target/cadence.
  echo "    NOTE: schedule ${SCHEDULE_NAME} already exists; reconciling its desired state."
  echo "    aws scheduler update-schedule --region ${AWS_REGION} --name ${SCHEDULE_NAME} ..."
  aws scheduler update-schedule \
    --region "$AWS_REGION" \
    --name "$SCHEDULE_NAME" \
    --schedule-expression "$SCHEDULE_EXPRESSION" \
    --schedule-expression-timezone "$SCHEDULE_TIMEZONE" \
    --flexible-time-window "$SCHEDULE_FLEXIBLE_TIME_WINDOW" \
    --target "$scheduler_target" \
    --state "$SCHEDULE_STATE"
  echo "    Reconciled existing schedule ${SCHEDULE_NAME}."
}

echo "==> [5/5] Creating the invocation schedule (${SCHEDULE_EXPRESSION})"
if aws scheduler create-schedule --help >/dev/null 2>&1; then
  echo "    Using EventBridge Scheduler."
  # EventBridge Scheduler needs a role it can assume to invoke the Lambda.
  # Reuse the same lambda role's ARN only if it trusts scheduler; otherwise the
  # operator should supply SCHEDULER_ROLE_ARN. We note this rather than guess.
  if [[ -n "${SCHEDULER_ROLE_ARN:-}" ]]; then
    reconcile_eventbridge_scheduler_schedule
  else
    echo "    NOTE: SCHEDULER_ROLE_ARN not set. EventBridge Scheduler needs an"
    echo "          invoke role. Falling back to a classic CloudWatch Events rule,"
    echo "          which can target Lambda directly via resource-based permission."
    create_classic_eventbridge_rule "$SCHEDULE_EXPRESSION"
  fi
else
  echo "    EventBridge Scheduler CLI not available; using a classic CloudWatch Events rule."
  create_classic_eventbridge_rule "$SCHEDULE_EXPRESSION"
fi

echo "==> Done. Optional max-lifetime cap deployed: ${FUNCTION_NAME} will stop"
echo "    ${INSTANCE_ID} once it has run longer than ${MAX_LIFETIME_HOURS}h."
echo "    (This stage is optional -- delete the function + schedule to remove it.)"
