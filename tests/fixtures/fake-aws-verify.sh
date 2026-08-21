#!/usr/bin/env bash
# Minimal fake AWS CLI for test_verify_prerequisites.sh. Every call
# 00-verify-prerequisites.sh makes is a read, so this fixture only has to
# answer reads. Tab-separated output where the real --output text would be.
#
# Deliberately written to bash 3.2 syntax as well: one of the scenarios runs
# the script under a real /bin/bash 3.2 when the host has one, and the fixture
# is on PATH for that run too.
set -euo pipefail

printf '%s\n' "$*" >> "${FAKE_AWS_TRACE:?FAKE_AWS_TRACE must be set}"

case "$1 $2" in
  "sts get-caller-identity")
    printf '%s\t%s\n' "${FAKE_CALLER_ARN:-arn:aws:iam::123456789012:user/admin}" "123456789012"
    ;;
  "ec2 describe-instance-attribute")
    printf '%s\n' "${FAKE_SHUTDOWN_BEHAVIOR:-stop}"
    ;;
  "ec2 describe-iam-instance-profile-associations")
    printf '%s\t%s\n' \
      "arn:aws:iam::123456789012:instance-profile/${FAKE_PROFILE_NAME:-topaz-render-instance-profile}" \
      "associated"
    ;;
  "iam get-instance-profile")
    printf '%s\n' "${FAKE_ROLE_NAME:-topaz-render-instance-role}"
    ;;
  "iam list-role-policies")
    printf '%s\n' "${FAKE_INLINE_POLICIES:-topaz-putmetric}"
    ;;
  "iam get-role-policy")
    printf '%s\n' "${FAKE_POLICY_DOC:-{\"Statement\":[{\"Action\":\"cloudwatch:PutMetricData\",\"Condition\":{\"StringEquals\":{\"cloudwatch:namespace\":\"TopazRender/GPU\"}}}]}}"
    ;;
  "iam list-attached-role-policies")
    printf '%s\n' "None"
    ;;
  "cloudwatch describe-alarms")
    printf '%s\t%s\n' "${FAKE_ALARM_STATE:-None}" "${FAKE_ALARM_ACTIONS:-None}"
    ;;
  "ec2 describe-tags")
    printf '%s\n' "${FAKE_TAG_VALUE:-true}"
    ;;
esac
