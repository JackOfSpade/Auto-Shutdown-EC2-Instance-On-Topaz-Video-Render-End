#!/usr/bin/env bash
#
# 04-deploy-max-lifetime-lambda.sh
#
# .SYNOPSIS
#   Deploy the OPTIONAL hard max-lifetime cap Lambda + its schedule.
#
# .DANGER -- READ THIS BEFORE DEPLOYING: THIS STOP BYPASSES THE UPLOAD INTERLOCK
#   A stop initiated by this Lambda calls ec2:StopInstances from OUTSIDE the
#   guest. It never runs Stop-Sequence.ps1, so NONE of that script's guards
#   apply -- in particular its EPHEMERAL UPLOAD INTERLOCK, which refuses a stop
#   while finished renders sitting on the instance-store scratch volume have
#   not been uploaded and verified. Instance-store contents are DESTROYED by a
#   stop. A render that finished but has not finished uploading when this cap
#   fires is therefore PERMANENTLY LOST -- hours of paid GPU time, gone, with
#   no copy anywhere. That exact loss already happened once on this project;
#   see docs/16-render-loss-incident.md.
#
#   Contrast with the in-guest wall-clock backstop,
#   in-guest/Register-TimedStop.ps1 (see its "ONE GUARD IS NOT BYPASSED,
#   DELIBERATELY" block, lines 35-42): that one goes THROUGH Stop-Sequence.ps1,
#   so the interlock still refuses the stop and the task simply retries on its
#   repeating trigger until the upload completes. It yields to the render; this
#   Lambda cannot, because it has no way to see the guest's upload state at
#   all.
#
#   Consequences for how you use this stage:
#     * Prefer Register-TimedStop.ps1 when the box's own guest is healthy --
#       it caps cost WITHOUT being able to erase a finished render.
#     * If you deploy this anyway (e.g. as a cap that survives a wedged guest),
#       size MAX_LIFETIME_HOURS against the SLOWEST render you might queue PLUS
#       its upload time, not the typical one.
#     * Treat it as a cost guard of last resort against a box nobody is
#       watching, not as a routine part of the deployment. This project does
#       not deploy it by default (docs/09-appendix-b-boundaries.md Sec 5).
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
#   WHAT iam/lambda-execution-policy.json GRANTS, AND WHY EACH SCOPE IS WHAT IT
#   IS (recorded here in the style of 05-grant-audit-reads.sh's own header,
#   because JSON cannot carry comments and an unexplained wildcard reads the
#   same as an unreviewed one):
#
#     ec2:StopInstances       Resource "*" + aws:ResourceTag/AutoStopEligible
#         = "true". NOT an instance-level boundary -- see the LAMBDA_ROLE_NAME
#         comment below for what that tag actually bounds and why narrowing it
#         while the role name stays shared would make things worse.
#     ec2:DescribeInstances   Resource "*" -- unavoidable. The EC2 Describe*
#         actions do not support resource-level permissions at all, so there is
#         no ARN to scope this to. It is read-only and returns only metadata.
#     logs:CreateLogGroup / CreateLogStream / PutLogEvents
#         Scoped to arn:aws:logs:*:*:log-group:/aws/lambda/topaz-max-lifetime-stop-*
#         -- FUNCTION_NAME below is always topaz-max-lifetime-stop-<instance
#         id>, so the log group name is fully determined at deploy time. The
#         trailing '*' is what keeps this working for every per-instance
#         function under one shared role, and it also covers the ':log-stream:'
#         suffix, so no second statement is needed. If a future rename breaks
#         the pattern the function loses its LOGS, not its ability to run --
#         confirm one invocation writes to CloudWatch Logs after re-running
#         this script.
#
# .NOTES
#   Run from an admin workstation with AWS CLI v2 configured.
#   Requires env vars: INSTANCE_ID, AWS_REGION.
#   Optional env var:  MAX_LIFETIME_HOURS (default 12) -- must be a positive,
#   finite number (matches handler.py's own validation); an invalid value
#   (including one so large it overflows to infinity) is rejected here at
#   deploy time rather than silently deploying a Lambda that falls back to its
#   own default and lies about the effective ceiling. The ceiling is a FLOOR,
#   not an exact time: the schedule polls on a fixed rate(30 minutes) cadence,
#   so the stop lands somewhere between N and N+0.5 hours. A ceiling that is
#   small relative to 30 minutes overshoots proportionally more.
#   Optional env var:  SCHEDULER_ROLE_ARN -- the ARN of an IAM role that
#   EventBridge Scheduler can assume (i.e. one trusting
#   scheduler.amazonaws.com) and that may lambda:InvokeFunction this function.
#   Supplying it selects the EventBridge Scheduler path; OMITTING IT (the
#   default, and what every documented invocation does) selects a classic
#   CloudWatch Events rule, which needs no invoke role because it targets
#   Lambda through a resource-based permission instead. This script never
#   guesses a role: Scheduler with an empty RoleArn would deploy a schedule
#   that can never invoke anything.
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
                      Must be a positive number, e.g. 12 or 4.5. Checked on a
                      fixed rate(30 minutes) cadence, so the actual stop lands
                      up to 30 minutes AFTER this ceiling.
  SCHEDULER_ROLE_ARN  ARN of a role EventBridge Scheduler can assume (trusting
                      scheduler.amazonaws.com) and that can invoke this
                      function. Supplying it selects the EventBridge Scheduler
                      path; omitting it (the default) selects a classic
                      CloudWatch Events rule, which needs no invoke role.

DANGER: a stop initiated by this Lambda bypasses Stop-Sequence.ps1 entirely,
including its ephemeral-upload interlock -- a finished-but-not-yet-uploaded
render on the instance-store scratch volume is PERMANENTLY LOST when the cap
fires. See this script's .DANGER header block and docs/16-render-loss-incident.md.
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

# Shape-check INSTANCE_ID before ANY AWS call: this script tags the instance
# and arms a recurring job that calls ec2:StopInstances against it, so a stale
# `export INSTANCE_ID=` points the most destructive thing in this repo at the
# wrong box. The shape check cannot catch a transposition that still names a
# real instance -- step [1/5]'s identity echo covers that half.
if ! is_valid_instance_id "$INSTANCE_ID"; then
  echo "ERROR: INSTANCE_ID='${INSTANCE_ID}' is not a valid EC2 instance id (expected i- followed by 8 or 17 hex digits)." >&2
  usage
fi

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
#
# BE PRECISE ABOUT WHAT "tag-scoped" BOUNDS HERE. Step [1/5] below applies
# AutoStopEligible=true itself, and 02-create-iam-role.sh applies it too, so the
# tag is a FLEET MEMBERSHIP marker this pipeline stamps on every managed box --
# NOT an instance identifier. The honest boundary is: this role can stop EVERY
# AutoStopEligible=true instance in the account, not just ${INSTANCE_ID}. The
# per-instance scoping is enforced only by the function's own INSTANCE_ID env
# var (and, for the guest-side stop path, by Stop-Sequence.ps1's IMDS-derived
# id) -- not by IAM. Accepted for this single-box deployment, where the fleet
# and the instance are the same thing.
#
# The fix for multi-box is NOT to render Resource down to one instance ARN
# while this role name stays shared: put-role-policy below writes the fixed
# policy name topaz-lambda-exec on the fixed role name here, so box B's deploy
# would overwrite box A's grant and A's max-lifetime Lambda would start failing
# UnauthorizedOperation -- a silently dead safety net, which is worse than a
# broad one. Make LAMBDA_ROLE_NAME per-instance FIRST (suffix it with
# INSTANCE_ID like FUNCTION_NAME/SCHEDULE_NAME above), and only then narrow the
# Resource or condition on a per-box tag VALUE. See the matching block at
# 02-create-iam-role.sh's step [2b/6] for the instance-role half of this.
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
# PRE-FLIGHT IDENTITY ECHO, before the first mutating call. Everything below
# tags an instance and arms a half-hourly job that stops it, and the runbook
# (docs/11 Sec 3) has the operator `export INSTANCE_ID=` into their shell --
# so a stale export, or a transposed character that still names a real
# instance, silently retargets all of it at someone else's running box. The
# id's SHAPE is already checked above; this resolves what it actually IS and
# prints it. A nonexistent id fails hard right here (describe-instances errors,
# set -e aborts) instead of half-way through the deployment.
#
# Deliberately NOT an interactive confirmation prompt: this must stay usable
# non-interactively. Echoing the resolved Name/state/launch time is the
# cost/benefit sweet spot -- it puts the wrong-box mistake in front of the
# operator without making the script unrunnable from a pipeline.
#
# shellcheck disable=SC2016 # single-quoted on purpose: this is JMESPath -- the
# backticked `Name` is a --query string literal, not a bash command
# substitution, so it must NOT be double-quoted/interpolated. Same reasoning as
# 05-grant-audit-reads.sh's own JMESPath disable.
TARGET_IDENTITY="$(aws ec2 describe-instances \
  --region "$AWS_REGION" \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].[State.Name,LaunchTime,Tags[?Key==`Name`].Value|[0]]' \
  --output text)"
TARGET_STATE="$(printf '%s' "$TARGET_IDENTITY" | cut -f1)"
TARGET_LAUNCH="$(printf '%s' "$TARGET_IDENTITY" | cut -f2)"
TARGET_NAME="$(printf '%s' "$TARGET_IDENTITY" | cut -f3)"
echo "    about to arm a ${MAX_LIFETIME_HOURS}h stop cap on: ${INSTANCE_ID}"
echo "      Name        : ${TARGET_NAME:-<none>}"
echo "      State       : ${TARGET_STATE:-<unknown>}"
echo "      LaunchTime  : ${TARGET_LAUNCH:-<unknown>}"
echo "    If that is not the box you meant, Ctrl-C NOW -- the next call tags it."
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
  # Same gap, and the same treatment, as 02-create-iam-role.sh's [1/6] branch:
  # put-role-policy below is declarative, but the TRUST policy of a role we did
  # not create is accepted unverified unless it is read back. A role of this
  # name that no longer trusts lambda.amazonaws.com makes create-function fail
  # with an error about an unassumable role -- or, if the function already
  # exists from an earlier deploy, leaves it wired to a role it cannot assume
  # and the cap silently never fires. Detect, explain, exit 1 rather than
  # blind-overwriting someone else's trust document with
  # update-assume-role-policy (which replaces it wholesale).
  EXISTING_LAMBDA_TRUST="$(aws iam get-role --role-name "$LAMBDA_ROLE_NAME" --query 'Role.AssumeRolePolicyDocument' --output json)"
  if ! printf '%s' "$EXISTING_LAMBDA_TRUST" | grep -qF -- "lambda.amazonaws.com"; then
    echo "ERROR: the existing role ${LAMBDA_ROLE_NAME} does not trust lambda.amazonaws.com." >&2
    echo "       Lambda cannot assume it, so the max-lifetime cap would never be able to" >&2
    echo "       run -- a silently dead safety net. Inspect it, and if this role really is" >&2
    echo "       meant to be ours, replace its trust policy with:" >&2
    echo "         aws iam get-role --role-name ${LAMBDA_ROLE_NAME} --query Role.AssumeRolePolicyDocument" >&2
    echo "         aws iam update-assume-role-policy --role-name ${LAMBDA_ROLE_NAME} \\" >&2
    echo "             --policy-document '${TRUST_POLICY_JSON}'" >&2
    echo "       (that REPLACES the whole trust document -- check what is there first)." >&2
    exit 1
  fi
  echo "    NOTE: confirmed -- ${LAMBDA_ROLE_NAME}'s trust policy still allows lambda.amazonaws.com to assume it."
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
# 10s is NOT a guarantee -- IAM propagation to Lambda routinely takes 30-60s on
# a first creation. create-function below recognizes that specific failure and
# says "re-run", rather than leaving the operator with an error that reads like
# a bad role ARN. Same treatment as 02-create-iam-role.sh's [6/6] association.
sleep 10

echo "==> [4/5] Creating (or updating) Lambda function ${FUNCTION_NAME}"
echo "    env: INSTANCE_ID=${INSTANCE_ID} AWS_TARGET_REGION=${AWS_REGION} MAX_LIFETIME_HOURS=${MAX_LIFETIME_HOURS}"
echo "    aws lambda create-function --region ${AWS_REGION} --function-name ${FUNCTION_NAME} ..."
if ! run_idempotent_hinted "ResourceConflictException|Function already exist" \
      "cannot be assumed|InvalidParameterValueException" \
      "HINT: IAM role propagation to Lambda is eventually consistent and can take 30-60s on first creation, while the wait above is a fixed 10s. This script is idempotent -- wait a minute and re-run it before treating the error above as a real problem." \
      aws lambda create-function \
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
  # Reconcile the SAME complete desired state the create path expresses, not
  # just --environment. Identical discipline to the Scheduler reconcile
  # (see the SCHEDULE_* block near the top of this script): create and update
  # must describe ONE desired state, or a re-deploy silently leaves the live
  # function on the old value while reporting success.
  # Concretely, --environment-only meant that bumping RUNTIME (python3.12 going
  # end-of-support), raising the 30s --timeout because describe-instances is
  # throttling, or re-pointing --role after the shared role was recreated with
  # a new ARN, all printed "Done. Optional max-lifetime cap deployed" while
  # changing nothing.
  aws lambda update-function-configuration \
    --region "$AWS_REGION" \
    --function-name "$FUNCTION_NAME" \
    --runtime "$RUNTIME" \
    --role "$LAMBDA_ROLE_ARN" \
    --handler "$HANDLER" \
    --timeout 30 \
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
  # PutTargets is a BATCH operation: it returns HTTP 200 (CLI exit 0) with a
  # FailedEntryCount and a FailedEntries array when an individual target could
  # not be attached -- most often because the add-permission above has not
  # propagated yet, or because the statement-id already exists bound to a
  # different source ARN (which run_idempotent's ResourceConflictException arm
  # deliberately swallows). Left unchecked, set -e sees exit 0, the script
  # prints "Done. Optional max-lifetime cap deployed", and the schedule invokes
  # nothing, forever: the "silently dead safety net" the tag-first comment
  # above exists to prevent, one step further down the same path. And this is
  # the DEFAULT path -- the Scheduler branch needs SCHEDULER_ROLE_ARN, which no
  # documented invocation sets.
  local put_targets_failed
  put_targets_failed="$(aws events put-targets \
    --region "$AWS_REGION" \
    --rule "$SCHEDULE_NAME" \
    --targets "Id=1,Arn=${FUNCTION_ARN}" \
    --query 'FailedEntryCount' --output text)"
  if [[ "$put_targets_failed" != "0" ]]; then
    echo "ERROR: events put-targets reported ${put_targets_failed} failed entry/entries;" >&2
    echo "       ${SCHEDULE_NAME} will never invoke ${FUNCTION_NAME}. What is actually attached:" >&2
    # list-targets-by-rule, not a second put-targets --query FailedEntries: the
    # latter would be a second MUTATING call just to read an error detail.
    # `|| true` so a denied read still leaves the exit-1 below as the outcome.
    aws events list-targets-by-rule --region "$AWS_REGION" --rule "$SCHEDULE_NAME" >&2 || true
    exit 1
  fi
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
# ORDER MATTERS: the SCHEDULER_ROLE_ARN test comes FIRST, before the CLI
# capability probe. EventBridge Scheduler needs a role it can assume to invoke
# the Lambda, and this script never guesses one -- so with no role supplied the
# outcome is the classic rule regardless of what the probe would say, and
# running the probe anyway is a full `aws ... --help` render (on macOS, AWS CLI
# v2 pipes --help through groff) whose result is discarded. Worse, if groff is
# missing the probe fails and the script blames "EventBridge Scheduler CLI not
# available" for something entirely unrelated to Scheduler -- a debugging trap
# on the path every documented invocation takes.
if [[ -z "${SCHEDULER_ROLE_ARN:-}" ]]; then
  echo "    NOTE: SCHEDULER_ROLE_ARN not set. EventBridge Scheduler needs an"
  echo "          invoke role. Falling back to a classic CloudWatch Events rule,"
  echo "          which can target Lambda directly via resource-based permission."
  create_classic_eventbridge_rule "$SCHEDULE_EXPRESSION"
elif aws scheduler create-schedule --help >/dev/null 2>&1; then
  echo "    Using EventBridge Scheduler."
  reconcile_eventbridge_scheduler_schedule
else
  echo "    EventBridge Scheduler CLI not available; using a classic CloudWatch Events rule."
  create_classic_eventbridge_rule "$SCHEDULE_EXPRESSION"
fi

echo "==> Done. Optional max-lifetime cap deployed: ${FUNCTION_NAME} will stop"
echo "    ${INSTANCE_ID} once it has run longer than ${MAX_LIFETIME_HOURS}h -- checked"
echo "    every 30 minutes, so the actual stop lands up to 30 min after that ceiling."
# The cadence is a fixed rate(30 minutes) while MAX_LIFETIME_HOURS accepts any
# positive finite value, so a small ceiling overshoots proportionally more:
# MAX_LIFETIME_HOURS=0.5 advertises a 30-minute cap whose real worst case is 60
# minutes. is_valid_max_lifetime_hours exists so the deploy output cannot lie
# about the effective cap; this is the remaining way it could.
# `if awk ...; then`, not `awk ... && echo ...`: an && chain returns nonzero
# for h >= 2, and as the script's final statement that would become its exit
# status under set -e.
if awk -v h="$MAX_LIFETIME_HOURS" 'BEGIN { exit !(h < 2) }'; then
  echo "    NOTE: with a ${MAX_LIFETIME_HOURS}h ceiling, the fixed rate(30 minutes) cadence is a"
  echo "          large fraction of the cap itself. Tighten SCHEDULE_EXPRESSION if that"
  echo "          overshoot matters."
fi
echo "    (This stage is optional -- delete the function + schedule to remove it.)"
echo ""
echo "    DANGER, RESTATED: this cap stops the instance from OUTSIDE the guest, so it"
echo "    bypasses Stop-Sequence.ps1 and its ephemeral-upload interlock entirely. A"
echo "    render that finished but has not been uploaded and verified when the cap"
echo "    fires is PERMANENTLY LOST (docs/16-render-loss-incident.md). Size"
echo "    MAX_LIFETIME_HOURS against your slowest render PLUS its upload time."
