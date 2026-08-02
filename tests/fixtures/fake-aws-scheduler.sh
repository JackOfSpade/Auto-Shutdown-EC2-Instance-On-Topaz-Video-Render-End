#!/usr/bin/env bash
# Minimal fake AWS CLI for test_deploy_max_lifetime_scheduler.sh. It records
# every invocation in FAKE_AWS_TRACE and emulates only the responses that the
# deployment script reads.
set -euo pipefail

printf '%s\n' "$*" >> "${FAKE_AWS_TRACE:?FAKE_AWS_TRACE must be set}"

if [[ "$1" == "scheduler" && "$2" == "create-schedule" && " ${*} " == *" --help "* ]]; then
  [[ "${FAKE_SCHEDULER_AVAILABLE:-1}" == "1" ]]
  exit
fi

if [[ "$1" == "scheduler" && "$2" == "create-schedule" && "${FAKE_SCHEDULE_EXISTS:-0}" == "1" ]]; then
  echo "ConflictException: schedule already exists" >&2
  exit 1
fi

case "$1 $2" in
  "iam get-role")
    echo "arn:aws:iam::123456789012:role/topaz-max-lifetime-lambda-role"
    ;;
  "lambda get-function")
    echo "arn:aws:lambda:us-east-1:123456789012:function:topaz-max-lifetime-stop-i-0123456789abcdef0"
    ;;
  "events put-rule")
    echo "arn:aws:events:us-east-1:123456789012:rule/topaz-max-lifetime-schedule-i-0123456789abcdef0"
    ;;
esac
