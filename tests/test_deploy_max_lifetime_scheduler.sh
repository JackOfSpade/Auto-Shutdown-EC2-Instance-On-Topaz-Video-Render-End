#!/usr/bin/env bash
# Focused integration test for EventBridge Scheduler reconciliation in
# control-plane/04-deploy-max-lifetime-lambda.sh. The fake aws CLI records
# requests so no AWS credentials or network connection are needed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_SCRIPT="$ROOT/control-plane/04-deploy-max-lifetime-lambda.sh"
FAKE_AWS_SOURCE="$ROOT/tests/fixtures/fake-aws-scheduler.sh"
FAKE_ZIP_SOURCE="$ROOT/tests/fixtures/fake-zip.sh"
FAKE_SLEEP_SOURCE="$ROOT/tests/fixtures/fake-sleep.sh"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fake_bin="$scratch/bin"
mkdir -p "$fake_bin"
cp "$FAKE_AWS_SOURCE" "$fake_bin/aws"
cp "$FAKE_ZIP_SOURCE" "$fake_bin/zip"
cp "$FAKE_SLEEP_SOURCE" "$fake_bin/sleep"
chmod +x "$fake_bin/aws"
chmod +x "$fake_bin/zip" "$fake_bin/sleep"

fail=0
pass_count=0

assert_trace_contains() { # <description> <trace> <fixed-string>
  local description="$1" trace="$2" expected="$3"
  if grep -Fq -- "$expected" "$trace"; then
    echo "PASS: $description"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $description (missing '$expected')"
    fail=1
  fi
}

assert_trace_not_contains() { # <description> <trace> <fixed-string>
  local description="$1" trace="$2" unexpected="$3"
  if ! grep -Fq -- "$unexpected" "$trace"; then
    echo "PASS: $description"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $description (unexpected '$unexpected')"
    fail=1
  fi
}

run_deploy() { # <trace> <schedule-exists> <scheduler-available> <scheduler-role-or-empty>
  local trace="$1" exists="$2" available="$3" scheduler_role="$4"
  PATH="$fake_bin:$PATH" \
  FAKE_AWS_TRACE="$trace" \
  FAKE_SCHEDULE_EXISTS="$exists" \
  FAKE_SCHEDULER_AVAILABLE="$available" \
  INSTANCE_ID="i-0123456789abcdef0" \
  AWS_REGION="us-east-1" \
  SCHEDULER_ROLE_ARN="$scheduler_role" \
  bash "$DEPLOY_SCRIPT" >/dev/null
}

expected_target='{"Arn":"arn:aws:lambda:us-east-1:123456789012:function:topaz-max-lifetime-stop-i-0123456789abcdef0","RoleArn":"arn:aws:iam::123456789012:role/scheduler","Input":"{}"}'

create_trace="$scratch/create.trace"
run_deploy "$create_trace" 0 1 "arn:aws:iam::123456789012:role/scheduler"
assert_trace_contains "new Scheduler deployment creates a schedule" "$create_trace" "scheduler create-schedule"
assert_trace_not_contains "new Scheduler deployment does not update a schedule" "$create_trace" "scheduler update-schedule"
assert_trace_contains "create specifies the UTC schedule timezone" "$create_trace" "--schedule-expression-timezone UTC"
assert_trace_contains "create disables flexible time windows" "$create_trace" '--flexible-time-window {"Mode":"OFF"}'
assert_trace_contains "create supplies the Lambda target, role, and empty JSON input" "$create_trace" "--target $expected_target"
assert_trace_contains "create explicitly enables the schedule" "$create_trace" "--state ENABLED"

update_trace="$scratch/update.trace"
run_deploy "$update_trace" 1 1 "arn:aws:iam::123456789012:role/scheduler"
assert_trace_contains "existing Scheduler deployment attempts create to detect conflict" "$update_trace" "scheduler create-schedule"
assert_trace_contains "existing Scheduler deployment reconciles with update-schedule" "$update_trace" "scheduler update-schedule"
assert_trace_contains "update reconciles the expression" "$update_trace" "--schedule-expression rate(30 minutes)"
assert_trace_contains "update reconciles the UTC schedule timezone" "$update_trace" "--schedule-expression-timezone UTC"
assert_trace_contains "update reconciles flexible time windows" "$update_trace" '--flexible-time-window {"Mode":"OFF"}'
assert_trace_contains "update reconciles target ARN, role, and input" "$update_trace" "--target $expected_target"
assert_trace_contains "update explicitly enables the schedule" "$update_trace" "--state ENABLED"

fallback_trace="$scratch/fallback.trace"
run_deploy "$fallback_trace" 0 0 ""
assert_trace_contains "missing Scheduler CLI keeps the classic rule fallback" "$fallback_trace" "events put-rule"
assert_trace_contains "classic fallback still grants Lambda invoke permission" "$fallback_trace" "lambda add-permission"
assert_trace_contains "classic fallback still attaches the Lambda target" "$fallback_trace" "events put-targets"
assert_trace_not_contains "classic fallback never calls Scheduler update" "$fallback_trace" "scheduler update-schedule"

echo
if [[ "$fail" -ne 0 ]]; then
  echo "deploy_max_lifetime_scheduler tests: FAILED"
  exit 1
fi
echo "deploy_max_lifetime_scheduler tests: all $pass_count assertions passed"
