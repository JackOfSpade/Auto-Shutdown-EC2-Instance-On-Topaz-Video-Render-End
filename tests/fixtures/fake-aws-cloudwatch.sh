#!/usr/bin/env bash
# Minimal fake AWS CLI for test_create_idle_alarm.sh. Records every invocation
# in FAKE_AWS_TRACE (one flattened line per call) and emulates only the reads
# 03-create-idle-alarm.sh performs.
set -euo pipefail

printf '%s\n' "$*" >> "${FAKE_AWS_TRACE:?FAKE_AWS_TRACE must be set}"

if [[ "$1" == "cloudwatch" && "$2" == "describe-alarms" ]]; then
  # 03 issues two different describe-alarms reads, distinguished by --query:
  #   * the TEARDOWN probe for the pre-2026-07-28 shared-name alarm, which
  #     projects [<InstanceId dimension>, ActionsEnabled] as two tab-separated
  #     fields, and
  #   * the create path's ActionsEnabled read, used to preserve a deliberate
  #     pause across a re-run.
  # The --query value arrives as ONE argument, so match on a fragment of the
  # JMESPath itself rather than on a space-delimited word.
  if [[ " ${*} " == *"Dimensions[?Name=="* ]]; then
    printf '%s\t%s\n' \
      "${FAKE_LEGACY_ALARM_INSTANCE:-None}" \
      "${FAKE_LEGACY_ALARM_ACTIONS:-None}"
    exit 0
  fi
  # FAKE_DESCRIBE_ALARMS_DENIED lets a test drive the "could not read the prior
  # pause state" branch -- the one the `|| true` guard exists for.
  if [[ "${FAKE_DESCRIBE_ALARMS_DENIED:-0}" == "1" ]]; then
    echo "AccessDeniedException: not authorized to perform cloudwatch:DescribeAlarms" >&2
    exit 255
  fi
  printf '%s\n' "${FAKE_ALARM_ACTIONS_ENABLED:-None}"
  exit 0
fi
