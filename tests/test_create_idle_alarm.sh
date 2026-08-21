#!/usr/bin/env bash
# Integration test for control-plane/03-create-idle-alarm.sh -- the only script
# in this repo that creates a CloudWatch STOP ACTION, and until now the only
# one with no test at all.
#
# What is actually being protected here:
#   * The ENABLE_IDLE_ALARM opt-in gate. It is the single guard between an
#     operator's pre-2026-07-28 muscle memory and a re-armed idle stop, and the
#     script's own header promises it refuses "without calling AWS at all".
#     "At all" is the assertable part: an EMPTY trace.
#   * The statistic/threshold pairing per IDLE_SIGNAL. `Average < 5` against
#     the 1/0 RenderActive metric is true on EVERY evaluation period, so it
#     would stop the box unconditionally IDLE_MINUTES after creation --
#     mid-render included. A refactor of the case block could invert these with
#     every other gate green.
#   * The ActionsEnabled preservation. PutMetricAlarm defaults it to TRUE on a
#     full replace, so a re-run silently cancels a deliberate pause.
#   * TEARDOWN, which is the command an operator runs to guarantee nothing can
#     idle-stop the box -- including the pre-rename shared-name orphan.
#
# The fake aws CLI records requests, so no AWS credentials or network are used.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALARM_SCRIPT="$ROOT/control-plane/03-create-idle-alarm.sh"
FAKE_AWS_SOURCE="$ROOT/tests/fixtures/fake-aws-cloudwatch.sh"

INSTANCE="i-0123456789abcdef0"
ALARM="topaz-gpu-idle-autostop-${INSTANCE}"
LEGACY_ALARM="topaz-gpu-idle-autostop"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fake_bin="$scratch/bin"
mkdir -p "$fake_bin"
cp "$FAKE_AWS_SOURCE" "$fake_bin/aws"
chmod +x "$fake_bin/aws"

fail=0
pass_count=0
run_count=0

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

# run_alarm <name> [VAR=value ...] -- runs 03 with the fake CLI on PATH and the
# given extra environment, capturing combined output and the AWS trace.
# Populates: rc, out (path), trace (path). Never aborts the suite on a nonzero
# exit; the refusal paths are exactly what several cases assert.
rc=0; out=""; trace=""
run_alarm() {
  local name="$1"; shift
  run_count=$((run_count + 1))
  out="$scratch/${name}.out"
  trace="$scratch/${name}.trace"
  : > "$trace"
  set +e
  env -i PATH="$fake_bin:/usr/bin:/bin" \
    HOME="$HOME" \
    FAKE_AWS_TRACE="$trace" \
    INSTANCE_ID="$INSTANCE" \
    AWS_REGION="us-east-1" \
    "$@" \
    bash "$ALARM_SCRIPT" >"$out" 2>&1
  rc=$?
  set -e
}

trace_line_count() { wc -l < "$1" | tr -d ' '; }

# ---- The opt-in gate: no ENABLE_IDLE_ALARM means no AWS call whatsoever ----------------------

run_alarm "no-optin"
assert_eq "without ENABLE_IDLE_ALARM the script refuses (exit 1)" "$rc" "1"
assert_eq "the refusal makes NO AWS call at all -- the trace is empty" "$(trace_line_count "$trace")" "0"
assert_trace_contains "the refusal explains the 2026-07-28 decision rather than just erroring" \
  "$out" "2026-07-28"
assert_trace_contains "the refusal names the exact opt-in needed to override it" "$out" "ENABLE_IDLE_ALARM=1"

# ---- TEARDOWN: allowed without the opt-in, and it sweeps the legacy orphan too ---------------

run_alarm "teardown-no-legacy" TEARDOWN=1
assert_eq "TEARDOWN=1 succeeds without ENABLE_IDLE_ALARM" "$rc" "0"
assert_trace_contains "TEARDOWN deletes this instance's own alarm" \
  "$trace" "cloudwatch delete-alarms --region us-east-1 --alarm-names ${ALARM}"
assert_trace_not_contains "TEARDOWN never creates or updates an alarm" "$trace" "put-metric-alarm"
assert_trace_not_contains "TEARDOWN with no legacy alarm present does not delete the shared name" \
  "$trace" "--alarm-names ${ALARM} ${LEGACY_ALARM}"

run_alarm "teardown-legacy-ours" TEARDOWN=1 FAKE_LEGACY_ALARM_INSTANCE="$INSTANCE" FAKE_LEGACY_ALARM_ACTIONS=True
assert_eq "TEARDOWN with a legacy alarm pointing at THIS box succeeds" "$rc" "0"
assert_trace_contains "a legacy shared-name alarm dimensioned to THIS box is deleted in the same call" \
  "$trace" "cloudwatch delete-alarms --region us-east-1 --alarm-names ${ALARM} ${LEGACY_ALARM}"

run_alarm "teardown-legacy-other" TEARDOWN=1 FAKE_LEGACY_ALARM_INSTANCE="i-9999999999999999f" FAKE_LEGACY_ALARM_ACTIONS=True
assert_eq "TEARDOWN with a legacy alarm pointing at ANOTHER box still succeeds" "$rc" "0"
assert_trace_not_contains "a legacy alarm belonging to another box is NEVER blind-deleted" \
  "$trace" "--alarm-names ${ALARM} ${LEGACY_ALARM}"
assert_trace_contains "the operator is warned about the other box's legacy alarm, by instance id" \
  "$out" "i-9999999999999999f"
assert_trace_contains "the warning prints the manual delete command for it" \
  "$out" "delete-alarms --region us-east-1 --alarm-names ${LEGACY_ALARM}"

# ---- IDLE_SIGNAL=render (the default): Maximum < 1 on RenderActive --------------------------

run_alarm "render-default" ENABLE_IDLE_ALARM=1
assert_eq "IDLE_SIGNAL defaults to render and succeeds" "$rc" "0"
assert_trace_contains "render signal watches the RenderActive metric" "$trace" "--metric-name RenderActive"
assert_trace_contains "render signal uses Maximum (an Average of a 1/0 series reads an active minute as idle)" \
  "$trace" "--statistic Maximum"
assert_trace_contains "render signal thresholds at 1" "$trace" "--threshold 1"
assert_trace_contains "render signal compares LessThanThreshold" "$trace" "--comparison-operator LessThanThreshold"
assert_trace_contains "missing data is never treated as idle" "$trace" "--treat-missing-data notBreaching"
assert_trace_contains "the window is 60s periods" "$trace" "--period 60"
assert_trace_contains "the default window is 30 evaluation periods" "$trace" "--evaluation-periods 30"
assert_trace_contains "the alarm is dimensioned to THIS instance" "$trace" "--dimensions Name=InstanceId,Value=${INSTANCE}"
assert_trace_contains "the stop action is the built-in EC2 one" "$trace" "--alarm-actions arn:aws:automate:us-east-1:ec2:stop"
assert_trace_not_contains "CPUUtilization is never the alarm metric (it is blind to GPU work)" \
  "$trace" "--metric-name CPUUtilization"

run_alarm "render-window" ENABLE_IDLE_ALARM=1 IDLE_MINUTES=90
assert_trace_contains "IDLE_MINUTES drives evaluation-periods 1:1 against a 60s period" "$trace" "--evaluation-periods 90"

# ---- IDLE_SIGNAL=gpu (legacy): Average < 5 on GPUUtilization --------------------------------

run_alarm "gpu-signal" ENABLE_IDLE_ALARM=1 IDLE_SIGNAL=gpu
assert_eq "IDLE_SIGNAL=gpu succeeds" "$rc" "0"
assert_trace_contains "gpu signal watches GPUUtilization" "$trace" "--metric-name GPUUtilization"
assert_trace_contains "gpu signal uses Average" "$trace" "--statistic Average"
assert_trace_contains "gpu signal thresholds at 5 percent" "$trace" "--threshold 5"
assert_trace_contains "gpu signal warns that it is the legacy, measured-unreliable signal" "$out" "LEGACY"

# ---- The cross-signal metric pairings that would stop the box mid-render ---------------------

run_alarm "mismatch-render-gpu" ENABLE_IDLE_ALARM=1 IDLE_SIGNAL=render METRIC_NAME=GPUUtilization
assert_eq "IDLE_SIGNAL=render + METRIC_NAME=GPUUtilization is rejected" "$rc" "1"
assert_eq "the rejected render/gpu pairing makes NO AWS call" "$(trace_line_count "$trace")" "0"

run_alarm "mismatch-gpu-render" ENABLE_IDLE_ALARM=1 IDLE_SIGNAL=gpu METRIC_NAME=RenderActive
assert_eq "IDLE_SIGNAL=gpu + METRIC_NAME=RenderActive is rejected" "$rc" "1"
assert_eq "the rejected gpu/render pairing makes NO AWS call" "$(trace_line_count "$trace")" "0"
assert_trace_contains "the gpu/render rejection states the consequence: an unconditional mid-render stop" \
  "$out" "mid-render"

run_alarm "bad-signal" ENABLE_IDLE_ALARM=1 IDLE_SIGNAL=cpu
assert_eq "an unknown IDLE_SIGNAL is rejected" "$rc" "1"
assert_eq "an unknown IDLE_SIGNAL makes NO AWS call" "$(trace_line_count "$trace")" "0"

# ---- IDLE_MINUTES validation happens before any AWS call ------------------------------------

for bad_minutes in 0 08 abc 3.5 -1; do
  run_alarm "bad-minutes" ENABLE_IDLE_ALARM=1 IDLE_MINUTES="$bad_minutes"
  assert_eq "IDLE_MINUTES='${bad_minutes}' is rejected" "$rc" "1"
  assert_eq "IDLE_MINUTES='${bad_minutes}' makes NO AWS call" "$(trace_line_count "$trace")" "0"
done

# ---- A malformed INSTANCE_ID must fail before anything, on both paths ------------------------

for teardown_flag in 0 1; do
  out="$scratch/bad-id-${teardown_flag}.out"
  trace="$scratch/bad-id-${teardown_flag}.trace"
  : > "$trace"
  set +e
  env -i PATH="$fake_bin:/usr/bin:/bin" HOME="$HOME" \
    FAKE_AWS_TRACE="$trace" \
    INSTANCE_ID="i-nope" AWS_REGION="us-east-1" \
    ENABLE_IDLE_ALARM=1 TEARDOWN="$teardown_flag" \
    bash "$ALARM_SCRIPT" >"$out" 2>&1
  rc=$?
  set -e
  assert_eq "a malformed INSTANCE_ID is rejected (TEARDOWN=${teardown_flag})" "$rc" "1"
  assert_eq "a malformed INSTANCE_ID makes NO AWS call (TEARDOWN=${teardown_flag})" \
    "$(trace_line_count "$trace")" "0"
done

# ---- ActionsEnabled: a deliberate pause must survive a re-run --------------------------------

run_alarm "actions-new" ENABLE_IDLE_ALARM=1
assert_trace_contains "a brand-new alarm is created with actions explicitly ENABLED, never implicitly" \
  "$trace" "--actions-enabled"

run_alarm "actions-paused" ENABLE_IDLE_ALARM=1 FAKE_ALARM_ACTIONS_ENABLED=False IDLE_MINUTES=180
assert_eq "re-running against a PAUSED alarm succeeds" "$rc" "0"
assert_trace_contains "re-running against a PAUSED alarm keeps it paused (--no-actions-enabled)" \
  "$trace" "--no-actions-enabled"
assert_trace_contains "the preserved pause is stated loudly, with the command to resume it" \
  "$out" "enable-alarm-actions"

run_alarm "actions-live" ENABLE_IDLE_ALARM=1 FAKE_ALARM_ACTIONS_ENABLED=True
assert_trace_contains "re-running against a LIVE alarm keeps its actions enabled" "$trace" "--actions-enabled"
assert_trace_not_contains "re-running against a LIVE alarm does not pause it" "$trace" "--no-actions-enabled"

run_alarm "actions-unreadable" ENABLE_IDLE_ALARM=1 FAKE_DESCRIBE_ALARMS_DENIED=1
assert_eq "a denied DescribeAlarms does NOT abort a previously-working create run" "$rc" "0"
assert_trace_contains "an unreadable prior pause state defaults to actions enabled" "$trace" "--actions-enabled"
assert_trace_contains "an unreadable prior pause state is warned about, not silently assumed" \
  "$out" "could not read"

echo
if [[ "$fail" -ne 0 ]]; then
  echo "create_idle_alarm tests: FAILED"
  exit 1
fi
echo "create_idle_alarm tests: all $pass_count assertions passed across $run_count script runs"
