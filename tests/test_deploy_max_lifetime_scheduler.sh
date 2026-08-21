#!/usr/bin/env bash
# Focused integration test for control-plane/04-deploy-max-lifetime-lambda.sh:
# EventBridge Scheduler reconciliation, the classic CloudWatch Events fallback
# (which is the DEFAULT path -- SCHEDULER_ROLE_ARN is optional and unset in
# every documented invocation), the Lambda already-exists reconcile, and the
# zip file-list contract. The fake aws CLI records requests so no AWS
# credentials or network connection are needed.
#
# ASSERTION STYLE, and why it matters here: every assertion names argument
# CONTENT (an ARN, a cadence, a rule name), not a bare subcommand. A bare
# subcommand assertion cannot tell a real call apart from a capability probe,
# and cannot notice a target ARN regressing to another instance's function --
# which in this script means arming a stop against the wrong box.
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

assert_eq() { # <description> <actual> <expected>
  local description="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    echo "PASS: $description"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $description (expected '$expected', got '$actual')"
    fail=1
  fi
}

# run_deploy <trace> <schedule-exists> <scheduler-available> <scheduler-role-or-empty>
# Extra fixture knobs (FAKE_FUNCTION_EXISTS, FAKE_WAIT_V2_MISSING,
# FAKE_PUT_TARGETS_FAILED, FAKE_ZIP_MANIFEST, MAX_LIFETIME_HOURS) are exported
# by the caller instead of growing this positional signature further.
run_deploy() {
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
expected_fn_arn='arn:aws:lambda:us-east-1:123456789012:function:topaz-max-lifetime-stop-i-0123456789abcdef0'
expected_rule_arn='arn:aws:events:us-east-1:123456789012:rule/topaz-max-lifetime-schedule-i-0123456789abcdef0'
# Named in full so the assertion cannot be satisfied by the `aws scheduler
# create-schedule --help` capability probe, which the fixture also records
# (on its own `probe: ` marker line, but still containing the subcommand).
scheduler_create_call='scheduler create-schedule --region us-east-1 --name topaz-max-lifetime-schedule-i-0123456789abcdef0'

# ---- EventBridge Scheduler: first deployment ------------------------------------------------

create_trace="$scratch/create.trace"
run_deploy "$create_trace" 0 1 "arn:aws:iam::123456789012:role/scheduler"
assert_trace_contains "new Scheduler deployment creates a schedule (a real create, not the --help probe)" \
  "$create_trace" "$scheduler_create_call"
assert_trace_not_contains "new Scheduler deployment does not update a schedule" "$create_trace" "scheduler update-schedule"
assert_trace_contains "create specifies the UTC schedule timezone" "$create_trace" "--schedule-expression-timezone UTC"
assert_trace_contains "create disables flexible time windows" "$create_trace" '--flexible-time-window {"Mode":"OFF"}'
assert_trace_contains "create supplies the Lambda target, role, and empty JSON input" "$create_trace" "--target $expected_target"
assert_trace_contains "create explicitly enables the schedule" "$create_trace" "--state ENABLED"
assert_trace_contains "deploy echoes the target instance's identity before tagging it" \
  "$create_trace" "ec2 describe-instances --region us-east-1 --instance-ids i-0123456789abcdef0"

# ---- EventBridge Scheduler: re-deployment onto an existing schedule -------------------------

update_trace="$scratch/update.trace"
run_deploy "$update_trace" 1 1 "arn:aws:iam::123456789012:role/scheduler"
assert_trace_contains "existing Scheduler deployment attempts a REAL create to detect the conflict" \
  "$update_trace" "$scheduler_create_call"
assert_trace_contains "existing Scheduler deployment reconciles with update-schedule" "$update_trace" "scheduler update-schedule"
assert_trace_contains "update reconciles the expression" "$update_trace" "--schedule-expression rate(30 minutes)"
assert_trace_contains "update reconciles the UTC schedule timezone" "$update_trace" "--schedule-expression-timezone UTC"
assert_trace_contains "update reconciles flexible time windows" "$update_trace" '--flexible-time-window {"Mode":"OFF"}'
assert_trace_contains "update reconciles target ARN, role, and input" "$update_trace" "--target $expected_target"
assert_trace_contains "update explicitly enables the schedule" "$update_trace" "--state ENABLED"

# ---- Classic CloudWatch Events fallback: Scheduler CLI absent -------------------------------

fallback_trace="$scratch/fallback.trace"
run_deploy "$fallback_trace" 0 0 ""
assert_trace_contains "missing Scheduler CLI keeps the classic rule fallback" "$fallback_trace" "events put-rule"
assert_trace_contains "classic fallback still grants Lambda invoke permission" "$fallback_trace" "lambda add-permission"
assert_trace_contains "classic fallback still attaches the Lambda target" "$fallback_trace" "events put-targets"
assert_trace_not_contains "classic fallback never calls Scheduler update" "$fallback_trace" "scheduler update-schedule"
assert_trace_contains "classic fallback keeps the 30-minute cadence" "$fallback_trace" "--schedule-expression rate(30 minutes)"
assert_trace_contains "classic fallback targets THIS instance's Lambda, not another instance's" \
  "$fallback_trace" "--targets Id=1,Arn=$expected_fn_arn"
assert_trace_contains "classic fallback scopes the invoke permission to the rule it just created" \
  "$fallback_trace" "--source-arn $expected_rule_arn"
assert_trace_contains "classic fallback uses the per-instance rule name" \
  "$fallback_trace" "--rule topaz-max-lifetime-schedule-i-0123456789abcdef0"

# ---- Classic fallback: Scheduler CLI PRESENT but no SCHEDULER_ROLE_ARN ----------------------
# The branch that fires in ordinary use. Previously untested: the only fallback
# scenario flipped BOTH knobs at once, so "Scheduler exists, no invoke role"
# never ran. Deploying a Scheduler schedule with an empty RoleArn either fails
# at deploy time or creates a schedule that can never invoke anything -- a
# silently dead cost cap.

no_role_trace="$scratch/no-role.trace"
run_deploy "$no_role_trace" 0 1 ""
assert_trace_contains "Scheduler CLI present but no SCHEDULER_ROLE_ARN: falls back to a classic rule" \
  "$no_role_trace" "events put-rule"
assert_trace_not_contains "no SCHEDULER_ROLE_ARN: must never create a Scheduler schedule with an empty RoleArn" \
  "$no_role_trace" '"RoleArn":""'
assert_trace_not_contains "no SCHEDULER_ROLE_ARN: must never reconcile a Scheduler schedule" \
  "$no_role_trace" "scheduler update-schedule"
# The role-ARN test now runs BEFORE the capability probe on purpose (the probe's
# result is discarded on this path, and on macOS a missing groff makes it blame
# "Scheduler CLI not available" for an unrelated reason). Asserted so the
# ordering cannot silently regress back.
assert_trace_not_contains "no SCHEDULER_ROLE_ARN: the pointless --help capability probe is skipped entirely" \
  "$no_role_trace" "probe: scheduler create-schedule --help"

# The probe still runs when a role IS supplied -- that is the branch whose
# outcome actually depends on it.
assert_trace_contains "Scheduler path does probe CLI availability before using it" \
  "$create_trace" "probe: scheduler create-schedule --help"

# ---- Lambda already exists: the update-code / wait / update-configuration path --------------
# A re-deploy with a changed MAX_LIFETIME_HOURS depends entirely on
# update-function-configuration. Asserted as the FULL call line, not just the
# --environment substring: the create-function attempt carries an identical
# --environment string, so a substring assertion would pass even if
# update-function-configuration never ran.

redeploy_trace="$scratch/redeploy.trace"
PATH="$fake_bin:$PATH" \
FAKE_AWS_TRACE="$redeploy_trace" \
FAKE_SCHEDULE_EXISTS=0 \
FAKE_SCHEDULER_AVAILABLE=0 \
FAKE_FUNCTION_EXISTS=1 \
FAKE_WAIT_V2_MISSING=1 \
INSTANCE_ID="i-0123456789abcdef0" \
AWS_REGION="us-east-1" \
MAX_LIFETIME_HOURS=6 \
SCHEDULER_ROLE_ARN="" \
bash "$DEPLOY_SCRIPT" >/dev/null

assert_trace_contains "existing function: pushes new code" \
  "$redeploy_trace" "lambda update-function-code --region us-east-1 --function-name topaz-max-lifetime-stop-i-0123456789abcdef0"
assert_trace_contains "existing function: waits for the code update to settle before touching config" \
  "$redeploy_trace" "lambda wait function-updated-v2 --region us-east-1 --function-name topaz-max-lifetime-stop-i-0123456789abcdef0"
assert_trace_contains "existing function: falls back to 'wait function-updated' when the -v2 waiter is missing" \
  "$redeploy_trace" "lambda wait function-updated --region us-east-1 --function-name topaz-max-lifetime-stop-i-0123456789abcdef0"
assert_trace_contains "existing function: update-function-configuration carries the NEW ceiling (whole call, not just the env substring)" \
  "$redeploy_trace" "lambda update-function-configuration --region us-east-1 --function-name topaz-max-lifetime-stop-i-0123456789abcdef0 --runtime python3.12 --role arn:aws:iam::123456789012:role/topaz-max-lifetime-lambda-role --handler handler.handler --timeout 30 --environment Variables={INSTANCE_ID=i-0123456789abcdef0,AWS_TARGET_REGION=us-east-1,MAX_LIFETIME_HOURS=6}"

# ---- The zip file-list contract -------------------------------------------------------------
# Exactly handler.py: never a typo'd/renamed module (real zip exits 12 and
# aborts the deploy), never `-r .` (which silently ships the test suite,
# conftest.py, requirements-dev.txt and stale __pycache__ into the package).
# Compared as exact content -- a `grep -Fv '.'`-style assertion is useless here
# because "." matches "handler.py".

zip_manifest="$scratch/zip.manifest"
zip_trace="$scratch/zip.trace"
PATH="$fake_bin:$PATH" \
FAKE_AWS_TRACE="$zip_trace" \
FAKE_SCHEDULE_EXISTS=0 \
FAKE_SCHEDULER_AVAILABLE=0 \
FAKE_ZIP_MANIFEST="$zip_manifest" \
INSTANCE_ID="i-0123456789abcdef0" \
AWS_REGION="us-east-1" \
SCHEDULER_ROLE_ARN="" \
bash "$DEPLOY_SCRIPT" >/dev/null

assert_eq "lambda package contains exactly handler.py and nothing else" \
  "$(cat "$zip_manifest")" "handler.py"

# ---- put-targets partial failure must abort, not report success -----------------------------
# PutTargets returns exit 0 with a nonzero FailedEntryCount when a target could
# not be attached (usually unpropagated invoke permission). Reporting "Done.
# Optional max-lifetime cap deployed" there would be a silently dead safety net.

put_targets_trace="$scratch/put-targets-failed.trace"
put_targets_out="$scratch/put-targets-failed.out"
set +e
PATH="$fake_bin:$PATH" \
FAKE_AWS_TRACE="$put_targets_trace" \
FAKE_SCHEDULE_EXISTS=0 \
FAKE_SCHEDULER_AVAILABLE=0 \
FAKE_PUT_TARGETS_FAILED=1 \
INSTANCE_ID="i-0123456789abcdef0" \
AWS_REGION="us-east-1" \
SCHEDULER_ROLE_ARN="" \
bash "$DEPLOY_SCRIPT" >"$put_targets_out" 2>&1
put_targets_rc=$?
set -e
assert_eq "put-targets reporting a failed entry aborts the deploy" "$put_targets_rc" "1"
assert_trace_contains "put-targets failure says the schedule will never invoke the function" \
  "$put_targets_out" "will never invoke topaz-max-lifetime-stop-i-0123456789abcdef0"
assert_trace_contains "put-targets failure dumps what is actually attached, via the READ-ONLY list call" \
  "$put_targets_trace" "events list-targets-by-rule --region us-east-1 --rule topaz-max-lifetime-schedule-i-0123456789abcdef0"
assert_trace_not_contains "put-targets failure never claims the cap was deployed" \
  "$put_targets_out" "Optional max-lifetime cap deployed"

# ---- An existing Lambda role that no longer trusts lambda.amazonaws.com ---------------------
# Reusing such a role would leave the cap wired to a role Lambda cannot assume:
# a cost guard that never fires and never says so.

bad_trust_out="$scratch/bad-trust.out"
set +e
PATH="$fake_bin:$PATH" \
FAKE_AWS_TRACE="$scratch/bad-trust.trace" \
FAKE_SCHEDULE_EXISTS=0 \
FAKE_SCHEDULER_AVAILABLE=0 \
FAKE_LAMBDA_ROLE_EXISTS=1 \
FAKE_LAMBDA_ROLE_TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
INSTANCE_ID="i-0123456789abcdef0" \
AWS_REGION="us-east-1" \
SCHEDULER_ROLE_ARN="" \
bash "$DEPLOY_SCRIPT" >"$bad_trust_out" 2>&1
bad_trust_rc=$?
set -e
assert_eq "an existing lambda role that does not trust lambda.amazonaws.com aborts the deploy" "$bad_trust_rc" "1"
assert_trace_contains "the untrusted-role abort names the actual problem" \
  "$bad_trust_out" "does not trust lambda.amazonaws.com"

good_trust_out="$scratch/good-trust.out"
PATH="$fake_bin:$PATH" \
FAKE_AWS_TRACE="$scratch/good-trust.trace" \
FAKE_SCHEDULE_EXISTS=0 \
FAKE_SCHEDULER_AVAILABLE=0 \
FAKE_LAMBDA_ROLE_EXISTS=1 \
INSTANCE_ID="i-0123456789abcdef0" \
AWS_REGION="us-east-1" \
SCHEDULER_ROLE_ARN="" \
bash "$DEPLOY_SCRIPT" >"$good_trust_out" 2>&1
assert_trace_contains "an existing lambda role that still trusts lambda.amazonaws.com is reused" \
  "$good_trust_out" "still allows lambda.amazonaws.com to assume it"

# ---- A malformed INSTANCE_ID must fail before any AWS call ----------------------------------

bad_id_trace="$scratch/bad-id.trace"
: > "$bad_id_trace"
bad_id_out="$scratch/bad-id.out"
set +e
PATH="$fake_bin:$PATH" \
FAKE_AWS_TRACE="$bad_id_trace" \
INSTANCE_ID="i-not-an-id" \
AWS_REGION="us-east-1" \
SCHEDULER_ROLE_ARN="" \
bash "$DEPLOY_SCRIPT" >"$bad_id_out" 2>&1
bad_id_rc=$?
set -e
assert_eq "a malformed INSTANCE_ID exits 1" "$bad_id_rc" "1"
assert_eq "a malformed INSTANCE_ID makes NO AWS call at all (nothing to untag or un-arm)" \
  "$(wc -l < "$bad_id_trace" | tr -d ' ')" "0"

echo
if [[ "$fail" -ne 0 ]]; then
  echo "deploy_max_lifetime_scheduler tests: FAILED"
  exit 1
fi
echo "deploy_max_lifetime_scheduler tests: all $pass_count assertions passed"
