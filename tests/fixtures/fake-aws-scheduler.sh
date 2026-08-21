#!/usr/bin/env bash
# Minimal fake AWS CLI for test_deploy_max_lifetime_scheduler.sh. It records
# every invocation in FAKE_AWS_TRACE and emulates only the responses that the
# deployment script reads.
set -euo pipefail

# The EventBridge Scheduler CAPABILITY PROBE is recorded on its own marker line
# and returns before the normal trace write below. WHY: the probe is literally
# `aws scheduler create-schedule --help`, so when it shared the trace format
# with real calls, a fixed-string assertion for "scheduler create-schedule" was
# satisfied by the probe alone -- an assertion whose stated purpose was to lock
# in the create-then-catch-ConflictException strategy passed even if the create
# call was deleted. Marking the probe line means an assertion can name the
# probe deliberately ("probe: scheduler create-schedule --help") while real
# calls are matched on argument content no probe line can produce.
if [[ "$1" == "scheduler" && "$2" == "create-schedule" && " ${*} " == *" --help "* ]]; then
  printf 'probe: %s\n' "$*" >> "${FAKE_AWS_TRACE:?FAKE_AWS_TRACE must be set}"
  [[ "${FAKE_SCHEDULER_AVAILABLE:-1}" == "1" ]]
  exit
fi

printf '%s\n' "$*" >> "${FAKE_AWS_TRACE:?FAKE_AWS_TRACE must be set}"

if [[ "$1" == "scheduler" && "$2" == "create-schedule" && "${FAKE_SCHEDULE_EXISTS:-0}" == "1" ]]; then
  echo "ConflictException: schedule already exists" >&2
  exit 1
fi

# Lambda already deployed: makes run_idempotent return 2 so the deploy script
# takes its update-code / wait / update-configuration reconcile path. Without
# this knob that whole path was unreachable in every test, and a re-deploy with
# a changed MAX_LIFETIME_HOURS depends on it entirely.
if [[ "$1" == "lambda" && "$2" == "create-function" && "${FAKE_FUNCTION_EXISTS:-0}" == "1" ]]; then
  echo "ResourceConflictException: Function already exist: topaz-max-lifetime-stop-i-0123456789abcdef0" >&2
  exit 1
fi

# Older AWS CLI v2 builds have no `wait function-updated-v2`; the deploy script
# falls back to `wait function-updated`. "${3:-}" rather than "$3": this file
# runs under `set -u`, and a future two-argument `aws lambda ...` call would
# otherwise crash the FIXTURE with an unbound-variable error that reads like a
# bug in the script under test.
if [[ "$1" == "lambda" && "$2" == "wait" && "${3:-}" == "function-updated-v2" && "${FAKE_WAIT_V2_MISSING:-0}" == "1" ]]; then
  echo "Invalid choice: 'function-updated-v2'" >&2
  exit 2
fi

if [[ "$1" == "iam" && "$2" == "get-role" ]]; then
  # 04 reads this role twice with different --query values: once for the ARN,
  # and (only on the role-already-exists branch) once for the trust document it
  # checks for lambda.amazonaws.com. Dispatch on the query so the exists-branch
  # guard can be driven from a test.
  if [[ " ${*} " == *" Role.AssumeRolePolicyDocument "* ]]; then
    default_lambda_trust='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
    printf '%s\n' "${FAKE_LAMBDA_ROLE_TRUST:-$default_lambda_trust}"
  else
    echo "arn:aws:iam::123456789012:role/topaz-max-lifetime-lambda-role"
  fi
  exit 0
fi

case "$1 $2" in
  "iam create-role")
    if [[ "${FAKE_LAMBDA_ROLE_EXISTS:-0}" == "1" ]]; then
      echo "EntityAlreadyExists: Role with name topaz-max-lifetime-lambda-role already exists." >&2
      exit 1
    fi
    ;;
  "ec2 describe-instances")
    # [1/5]'s pre-flight identity echo. Tab-separated, matching
    # `--output text` for a three-element JMESPath projection.
    printf '%s\t%s\t%s\n' \
      "${FAKE_INSTANCE_STATE:-running}" \
      "${FAKE_INSTANCE_LAUNCH:-2026-08-21T00:00:00+00:00}" \
      "${FAKE_INSTANCE_NAME:-topaz-render-box}"
    ;;
  "lambda get-function")
    echo "arn:aws:lambda:us-east-1:123456789012:function:topaz-max-lifetime-stop-i-0123456789abcdef0"
    ;;
  "events put-rule")
    echo "arn:aws:events:us-east-1:123456789012:rule/topaz-max-lifetime-schedule-i-0123456789abcdef0"
    ;;
  "events put-targets")
    # PutTargets is a batch API: HTTP 200 with a nonzero FailedEntryCount is
    # how a target that could not be attached is reported. The deploy script
    # reads that count with --query, so the fixture must answer it -- and the
    # knob lets a test drive the partial-failure branch.
    echo "${FAKE_PUT_TARGETS_FAILED:-0}"
    ;;
esac
