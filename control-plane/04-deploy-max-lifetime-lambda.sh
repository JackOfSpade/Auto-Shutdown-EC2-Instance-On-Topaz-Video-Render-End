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
#     1. Zip the Lambda source at ../lambda/max-lifetime-stop
#     2. Create the Lambda execution role (iam/lambda-execution-policy.json)
#     3. Create the Lambda function (handler wired to that zip)
#     4. Create an EventBridge Scheduler schedule (falls back to a CloudWatch
#        Events rule) that invokes the function on a fixed cadence
#
#   The ceiling is parameterized via env MAX_LIFETIME_HOURS (default 12) and is
#   passed to the Lambda as an environment variable, so the function reads the
#   instance launch time and compares against it.
#
# .NOTES
#   Run from an admin workstation with AWS CLI v2 configured.
#   Requires env vars: INSTANCE_ID, AWS_REGION.
#   Optional env var:  MAX_LIFETIME_HOURS (default 12)
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
  MAX_LIFETIME_HOURS  Absolute run-time ceiling in hours (default 12)
EOF
  exit 1
}

if [[ -z "${INSTANCE_ID:-}" ]]; then echo "ERROR: INSTANCE_ID is not set." >&2; usage; fi
if [[ -z "${AWS_REGION:-}"  ]]; then echo "ERROR: AWS_REGION is not set."  >&2; usage; fi

MAX_LIFETIME_HOURS="${MAX_LIFETIME_HOURS:-12}"

FUNCTION_NAME="topaz-max-lifetime-stop"
LAMBDA_ROLE_NAME="topaz-max-lifetime-lambda-role"
SCHEDULE_NAME="topaz-max-lifetime-schedule"
HANDLER="handler.handler"
RUNTIME="python3.12"
SCHEDULE_EXPRESSION="rate(30 minutes)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IAM_DIR="${SCRIPT_DIR}/iam"
LAMBDA_SRC_DIR="${SCRIPT_DIR}/../lambda/max-lifetime-stop"
LAMBDA_EXEC_POLICY="${IAM_DIR}/lambda-execution-policy.json"
TRUST_POLICY_JSON='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

ZIP_PATH="$(mktemp -d)/max-lifetime-stop.zip"

echo "==> [0/4] Sanity checks"
[[ -d "$LAMBDA_SRC_DIR" ]]     || { echo "ERROR: Lambda source dir not found: ${LAMBDA_SRC_DIR}" >&2; exit 1; }
[[ -f "$LAMBDA_EXEC_POLICY" ]] || { echo "ERROR: execution policy not found: ${LAMBDA_EXEC_POLICY}" >&2; exit 1; }
command -v zip >/dev/null 2>&1 || { echo "ERROR: 'zip' is required but not installed." >&2; exit 1; }

echo "==> [1/4] Zipping Lambda source ${LAMBDA_SRC_DIR} -> ${ZIP_PATH}"
( cd "$LAMBDA_SRC_DIR" && zip -r -q "$ZIP_PATH" . )
echo "    built ${ZIP_PATH}"

echo "==> [2/4] Creating the Lambda execution role ${LAMBDA_ROLE_NAME}"
echo "    aws iam create-role --role-name ${LAMBDA_ROLE_NAME} --assume-role-policy-document <lambda trust policy>"
if ! aws iam create-role \
      --role-name "$LAMBDA_ROLE_NAME" \
      --assume-role-policy-document "$TRUST_POLICY_JSON" \
      --description "Execution role for the Topaz max-lifetime-stop Lambda" 2>/tmp/lam_err.$$; then
  if grep -q "EntityAlreadyExists" /tmp/lam_err.$$; then
    echo "    NOTE: role ${LAMBDA_ROLE_NAME} already exists; reusing it."
  else
    cat /tmp/lam_err.$$ >&2; rm -f /tmp/lam_err.$$; exit 1
  fi
fi
rm -f /tmp/lam_err.$$

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

echo "==> [3/4] Creating (or updating) Lambda function ${FUNCTION_NAME}"
echo "    env: INSTANCE_ID=${INSTANCE_ID} AWS_TARGET_REGION=${AWS_REGION} MAX_LIFETIME_HOURS=${MAX_LIFETIME_HOURS}"
echo "    aws lambda create-function --region ${AWS_REGION} --function-name ${FUNCTION_NAME} ..."
if ! aws lambda create-function \
      --region "$AWS_REGION" \
      --function-name "$FUNCTION_NAME" \
      --runtime "$RUNTIME" \
      --role "$LAMBDA_ROLE_ARN" \
      --handler "$HANDLER" \
      --timeout 30 \
      --zip-file "fileb://${ZIP_PATH}" \
      --environment "Variables={INSTANCE_ID=${INSTANCE_ID},AWS_TARGET_REGION=${AWS_REGION},MAX_LIFETIME_HOURS=${MAX_LIFETIME_HOURS}}" 2>/tmp/lam_err.$$; then
  if grep -q "ResourceConflictException\|Function already exist" /tmp/lam_err.$$; then
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
  else
    cat /tmp/lam_err.$$ >&2; rm -f /tmp/lam_err.$$; exit 1
  fi
fi
rm -f /tmp/lam_err.$$

FUNCTION_ARN="$(aws lambda get-function --region "$AWS_REGION" --function-name "$FUNCTION_NAME" --query 'Configuration.FunctionArn' --output text)"
echo "    function arn: ${FUNCTION_ARN}"

echo "==> [4/4] Creating the invocation schedule (${SCHEDULE_EXPRESSION})"
if aws scheduler create-schedule --help >/dev/null 2>&1; then
  echo "    Using EventBridge Scheduler."
  echo "    aws scheduler create-schedule --region ${AWS_REGION} --name ${SCHEDULE_NAME} ..."
  # EventBridge Scheduler needs a role it can assume to invoke the Lambda.
  # Reuse the same lambda role's ARN only if it trusts scheduler; otherwise the
  # operator should supply SCHEDULER_ROLE_ARN. We note this rather than guess.
  if [[ -n "${SCHEDULER_ROLE_ARN:-}" ]]; then
    if ! aws scheduler create-schedule \
          --region "$AWS_REGION" \
          --name "$SCHEDULE_NAME" \
          --schedule-expression "$SCHEDULE_EXPRESSION" \
          --flexible-time-window '{"Mode":"OFF"}' \
          --target "{\"Arn\":\"${FUNCTION_ARN}\",\"RoleArn\":\"${SCHEDULER_ROLE_ARN}\"}" 2>/tmp/lam_err.$$; then
      if grep -q "ConflictException\|already exists" /tmp/lam_err.$$; then
        echo "    NOTE: schedule ${SCHEDULE_NAME} already exists; leaving as-is."
      else
        cat /tmp/lam_err.$$ >&2; rm -f /tmp/lam_err.$$; exit 1
      fi
    fi
    rm -f /tmp/lam_err.$$
  else
    echo "    NOTE: SCHEDULER_ROLE_ARN not set. EventBridge Scheduler needs an"
    echo "          invoke role. Falling back to a classic CloudWatch Events rule,"
    echo "          which can target Lambda directly via resource-based permission."
    SCHEDULE_EXPRESSION_EB="$SCHEDULE_EXPRESSION"
    echo "    aws events put-rule --region ${AWS_REGION} --name ${SCHEDULE_NAME} --schedule-expression '${SCHEDULE_EXPRESSION_EB}'"
    RULE_ARN="$(aws events put-rule \
      --region "$AWS_REGION" \
      --name "$SCHEDULE_NAME" \
      --schedule-expression "$SCHEDULE_EXPRESSION_EB" \
      --query 'RuleArn' --output text)"
    echo "    aws lambda add-permission (allow events.amazonaws.com to invoke ${FUNCTION_NAME})"
    aws lambda add-permission \
      --region "$AWS_REGION" \
      --function-name "$FUNCTION_NAME" \
      --statement-id "topaz-max-lifetime-eventbridge" \
      --action "lambda:InvokeFunction" \
      --principal "events.amazonaws.com" \
      --source-arn "$RULE_ARN" 2>/dev/null || echo "    NOTE: permission may already exist; continuing."
    echo "    aws events put-targets --region ${AWS_REGION} --rule ${SCHEDULE_NAME} --targets Id=1,Arn=${FUNCTION_ARN}"
    aws events put-targets \
      --region "$AWS_REGION" \
      --rule "$SCHEDULE_NAME" \
      --targets "Id=1,Arn=${FUNCTION_ARN}"
  fi
else
  echo "    EventBridge Scheduler CLI not available; using a classic CloudWatch Events rule."
  echo "    aws events put-rule --region ${AWS_REGION} --name ${SCHEDULE_NAME} --schedule-expression '${SCHEDULE_EXPRESSION}'"
  RULE_ARN="$(aws events put-rule \
    --region "$AWS_REGION" \
    --name "$SCHEDULE_NAME" \
    --schedule-expression "$SCHEDULE_EXPRESSION" \
    --query 'RuleArn' --output text)"
  echo "    aws lambda add-permission (allow events.amazonaws.com to invoke ${FUNCTION_NAME})"
  aws lambda add-permission \
    --region "$AWS_REGION" \
    --function-name "$FUNCTION_NAME" \
    --statement-id "topaz-max-lifetime-eventbridge" \
    --action "lambda:InvokeFunction" \
    --principal "events.amazonaws.com" \
    --source-arn "$RULE_ARN" 2>/dev/null || echo "    NOTE: permission may already exist; continuing."
  echo "    aws events put-targets --region ${AWS_REGION} --rule ${SCHEDULE_NAME} --targets Id=1,Arn=${FUNCTION_ARN}"
  aws events put-targets \
    --region "$AWS_REGION" \
    --rule "$SCHEDULE_NAME" \
    --targets "Id=1,Arn=${FUNCTION_ARN}"
fi

echo "==> Done. Optional max-lifetime cap deployed: ${FUNCTION_NAME} will stop"
echo "    ${INSTANCE_ID} once it has run longer than ${MAX_LIFETIME_HOURS}h."
echo "    (This stage is optional -- delete the function + schedule to remove it.)"
