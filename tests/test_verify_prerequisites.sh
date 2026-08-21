#!/usr/bin/env bash
# Integration test for control-plane/00-verify-prerequisites.sh -- the first
# command in the whole deployment runbook, and a script that must produce a
# COMPLETE report even when (especially when) something is wrong.
#
# The scenario that motivated this suite: the [2/6] FAIL message once used
# ${SHUTDOWN_BEHAVIOR^^}, a bash 4.0+ uppercase expansion. macOS ships
# /bin/bash 3.2.57, which `#!/usr/bin/env bash` resolves to on any admin
# workstation without a newer bash earlier in PATH. `bash -n` parses ^^ fine on
# 3.2, so a syntax pre-check does not catch it; it fails at RUNTIME with "bad
# substitution" and, being non-interactive, ABORTS. That aborted precisely on
# the branch reached when a guest shutdown would TERMINATE the instance --
# checks [3/6]-[6/6] never ran and no Summary was printed. shellcheck does not
# flag bash-version features (verified 0.11.0, even with --enable=all), and CI
# runs on ubuntu-latest (bash 5), so nothing else in this repo can catch the
# class. Hence: assert the whole report survives the FAIL branch, and re-run
# the same scenario under a real bash 3.x whenever the host has one.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY_SCRIPT="$ROOT/control-plane/00-verify-prerequisites.sh"
FAKE_AWS_SOURCE="$ROOT/tests/fixtures/fake-aws-verify.sh"

INSTANCE="i-0123456789abcdef0"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fake_bin="$scratch/bin"
mkdir -p "$fake_bin"
cp "$FAKE_AWS_SOURCE" "$fake_bin/aws"
chmod +x "$fake_bin/aws"

fail=0
pass_count=0

assert_contains() { # <description> <file> <fixed-string>
  local description="$1" file="$2" expected="$3"
  if grep -Fq -- "$expected" "$file"; then
    echo "PASS: $description"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $description (missing '$expected')"
    fail=1
  fi
}

assert_not_contains() { # <description> <file> <fixed-string>
  local description="$1" file="$2" unexpected="$3"
  if ! grep -Fq -- "$unexpected" "$file"; then
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

rc=0; out=""; trace=""
run_verify() { # <name> <bash-binary> [VAR=value ...]
  local name="$1" bash_bin="$2"; shift 2
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
    "$bash_bin" "$VERIFY_SCRIPT" >"$out" 2>&1
  rc=$?
  set -e
}

# ---- Everything healthy ---------------------------------------------------------------------

run_verify "healthy" bash
assert_eq "a healthy box reports no FAILs (exit 0)" "$rc" "0"
assert_contains "the report confirms a guest shutdown will STOP, not terminate" "$out" "will STOP (not terminate)"
assert_contains "every check runs through to the summary" "$out" "==> Summary:"
assert_contains "the run is read-only: no mutating verb appears in the trace" "$out" "READ-ONLY"
for verb in "create-tags" "put-metric-alarm" "modify-instance-attribute" "put-role-policy" "associate-iam-instance-profile" "delete-alarms"; do
  assert_not_contains "READ-ONLY: never calls ${verb}" "$trace" "$verb"
done

# ---- The bash-3.2 crash site: InstanceInitiatedShutdownBehavior != stop ----------------------
# This is the single most safety-critical branch in the script: it is reached
# only when a guest-OS shutdown would DESTROY the instance.

run_verify "terminate" bash FAKE_SHUTDOWN_BEHAVIOR=terminate
assert_eq "a terminate-behavior box fails the run (exit 1)" "$rc" "1"
assert_contains "the FAIL says the guest shutdown would TERMINATE, uppercased" "$out" "would TERMINATE this instance"
assert_contains "the FAIL quotes the raw attribute value too" "$out" "InstanceInitiatedShutdownBehavior='terminate'"
assert_contains "the FAIL forbids arming DryRun until it reads back 'stop'" "$out" "DO NOT flip DryRun"
assert_contains "the FAIL names the fixing script" "$out" "01-set-shutdown-behavior.sh"
# The regression this suite exists for: an aborted script would stop right here.
assert_contains "checks after the FAIL still run: [3/6]" "$out" "[3/6]"
assert_contains "checks after the FAIL still run: [4/6]" "$out" "[4/6]"
assert_contains "checks after the FAIL still run: [5/6]" "$out" "[5/6]"
assert_contains "checks after the FAIL still run: [6/6]" "$out" "[6/6]"
assert_contains "the Summary line is still printed after the FAIL" "$out" "==> Summary:"
assert_not_contains "the FAIL branch never dies on a bash-4-only expansion" "$out" "bad substitution"

# Re-run the same scenario under a REAL bash 3.x when the host has one (macOS
# admin workstations do; ubuntu-latest CI does not, hence the skip rather than
# a hard requirement). This is the only gate that actually proves the fix.
old_bash=""
for candidate in /bin/bash /usr/bin/bash; do
  if [[ -x "$candidate" ]]; then
    # shellcheck disable=SC2016 # single-quoted on purpose: ${BASH_VERSINFO[0]}
    # must expand in the CANDIDATE shell being probed, not in this one.
    case "$("$candidate" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null)" in
      3) old_bash="$candidate"; break ;;
    esac
  fi
done
if [[ -n "$old_bash" ]]; then
  run_verify "terminate-bash3" "$old_bash" FAKE_SHUTDOWN_BEHAVIOR=terminate
  assert_eq "under real bash 3.2, the terminate FAIL run still exits 1 (not a parse/expansion abort)" "$rc" "1"
  assert_contains "under real bash 3.2, the uppercase TERMINATE wording still renders" "$out" "would TERMINATE this instance"
  assert_contains "under real bash 3.2, the report still reaches its Summary" "$out" "==> Summary:"
  assert_not_contains "under real bash 3.2, nothing emits 'bad substitution'" "$out" "bad substitution"
else
  echo "SKIP: no bash 3.x on this host; the bash-3.2 runtime leg of this suite did not run"
fi

# ---- [5/6]: the absent idle alarm is the INTENDED state here, not a defect -------------------
# 03-create-idle-alarm.sh refuses without ENABLE_IDLE_ALARM=1, so the old
# "Fix: ... ./03-create-idle-alarm.sh" text pointed at a command that answers
# with a multi-paragraph refusal -- while also contradicting the 2026-07-28
# decision. The level stays WARN because docs/11's troubleshooting table
# documents that WARN as expected on this box.

run_verify "no-alarm" bash
assert_contains "an absent idle alarm is described as EXPECTED" "$out" "EXPECTED for this project"
assert_contains "an absent idle alarm is explicitly not something to fix" "$out" "NOT something to fix"
assert_contains "the alarm line cites the decision date" "$out" "2026-07-28"
assert_contains "any command it does print carries the opt-in 03 actually requires" "$out" "ENABLE_IDLE_ALARM=1 ./03-create-idle-alarm.sh"
assert_contains "the absent alarm stays a [WARN], matching docs/11's troubleshooting table" "$out" "[WARN] alarm topaz-gpu-idle-autostop-${INSTANCE} does not exist"

run_verify "alarm-paused" bash FAKE_ALARM_STATE=OK FAKE_ALARM_ACTIONS=False
assert_contains "a paused alarm is described as paused, not as a fault" "$out" "PAUSED"
assert_contains "a paused alarm's line notes the pause may be deliberate" "$out" "may be deliberate"
assert_contains "a paused alarm's line still gives the resume command" "$out" "enable-alarm-actions"

run_verify "alarm-live" bash FAKE_ALARM_STATE=OK FAKE_ALARM_ACTIONS=True
assert_contains "a live alarm reports OK with its state" "$out" "[OK]   alarm topaz-gpu-idle-autostop-${INSTANCE} exists, actions ENABLED, state OK."

# ---- A malformed INSTANCE_ID must fail before any AWS call -----------------------------------

bad_id_trace="$scratch/bad-id.trace"
: > "$bad_id_trace"
set +e
env -i PATH="$fake_bin:/usr/bin:/bin" HOME="$HOME" \
  FAKE_AWS_TRACE="$bad_id_trace" \
  INSTANCE_ID="i-nope" AWS_REGION="us-east-1" \
  bash "$VERIFY_SCRIPT" >"$scratch/bad-id.out" 2>&1
bad_id_rc=$?
set -e
assert_eq "a malformed INSTANCE_ID exits 1" "$bad_id_rc" "1"
assert_eq "a malformed INSTANCE_ID makes NO AWS call" "$(wc -l < "$bad_id_trace" | tr -d ' ')" "0"

echo
if [[ "$fail" -ne 0 ]]; then
  echo "verify_prerequisites tests: FAILED"
  exit 1
fi
echo "verify_prerequisites tests: all $pass_count assertions passed"
