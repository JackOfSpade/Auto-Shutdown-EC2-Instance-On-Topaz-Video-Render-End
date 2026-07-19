#!/usr/bin/env bash
# Functional tests for control-plane/lib/validation.sh and control-plane/lib/aws-idempotent.sh — the
# pure predicates and the AWS-call idempotency wrapper that control-plane/01..04-*.sh source directly.
#
# This sources the SAME functions the production scripts source (not a reimplementation), following the
# convention tests/test_auto_merge_logic.sh already established for scripts/auto_merge_decision.sh.
#
# Run:  bash tests/test_control_plane_validation.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../control-plane/lib/aws-idempotent.sh
source "$ROOT/control-plane/lib/aws-idempotent.sh"
# shellcheck source=../control-plane/lib/validation.sh
source "$ROOT/control-plane/lib/validation.sh"

fail=0
pass_count=0

assert_true() {   # assert_true <description> <command...>
  local desc="$1"; shift
  if "$@"; then
    echo "PASS: $desc"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $desc (expected success/true, got failure)"
    fail=1
  fi
}

assert_false() {  # assert_false <description> <command...>
  local desc="$1"; shift
  if ! "$@"; then
    echo "PASS: $desc"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $desc (expected failure/false, got success)"
    fail=1
  fi
}

assert_eq() {     # assert_eq <description> <actual> <expected>
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    echo "PASS: $desc"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $desc (expected '$expected', got '$actual')"
    fail=1
  fi
}

# ---- is_valid_idle_minutes: 03's IDLE_MINUTES rule --------------------------------------------

assert_true  "idle minutes '1' is valid"  is_valid_idle_minutes "1"
assert_true  "idle minutes '30' is valid" is_valid_idle_minutes "30"
assert_true  "idle minutes '45' is valid" is_valid_idle_minutes "45"

assert_false "idle minutes '0' is invalid"    is_valid_idle_minutes "0"
assert_false "idle minutes '-1' is invalid"   is_valid_idle_minutes "-1"
assert_false "idle minutes '08' is invalid (leading zero, bash-octal trap)" is_valid_idle_minutes "08"
assert_false "idle minutes 'abc' is invalid"  is_valid_idle_minutes "abc"
assert_false "idle minutes '' is invalid"     is_valid_idle_minutes ""
assert_false "idle minutes '3.5' is invalid"  is_valid_idle_minutes "3.5"

# ---- is_valid_max_lifetime_hours: 04's MAX_LIFETIME_HOURS rule, extended with the finite bound --

assert_true  "max-lifetime '12' is valid"  is_valid_max_lifetime_hours "12"
assert_true  "max-lifetime '4.5' is valid" is_valid_max_lifetime_hours "4.5"
assert_true  "max-lifetime '0.1' is valid" is_valid_max_lifetime_hours "0.1"
assert_true  "max-lifetime '168' is valid" is_valid_max_lifetime_hours "168"

assert_false "max-lifetime '0' is invalid"   is_valid_max_lifetime_hours "0"
assert_false "max-lifetime '-1' is invalid"  is_valid_max_lifetime_hours "-1"
assert_false "max-lifetime 'abc' is invalid" is_valid_max_lifetime_hours "abc"
assert_false "max-lifetime '' is invalid"    is_valid_max_lifetime_hours ""
# The regex requires at least one digit after a decimal point, and at least one digit before it, so
# these two are rejected by the regex itself today -- asserted here as the actual current behavior,
# not because the spec demands rejecting them on numeric-value grounds.
assert_false "max-lifetime '12.' is invalid (regex requires a digit after '.')" is_valid_max_lifetime_hours "12."
assert_false "max-lifetime '.5' is invalid (regex requires a digit before '.')" is_valid_max_lifetime_hours ".5"

# The overflow-to-infinity case this predicate exists to close: a 400-digit string of 9s matches the
# digits-only regex, but awk parses it as +Infinity, which the h < 1e300 bound must reject.
overflow_value="$(printf '9%.0s' $(seq 1 400))"
assert_false "max-lifetime: 400-digit 9s overflows to infinity and must be rejected" \
  is_valid_max_lifetime_hours "$overflow_value"

# ---- is_shutdown_behavior_confirmed: 01's readback check ---------------------------------------

assert_true  "shutdown behavior 'stop' is confirmed"        is_shutdown_behavior_confirmed "stop"
assert_false "shutdown behavior 'terminate' is not confirmed" is_shutdown_behavior_confirmed "terminate"
assert_false "shutdown behavior '' is not confirmed"          is_shutdown_behavior_confirmed ""
assert_false "shutdown behavior 'Stop' (wrong case) is not confirmed" is_shutdown_behavior_confirmed "Stop"

# ---- profile_names_match: 02's reconciliation branches ------------------------------------------

assert_true  "profile_names_match: equal names match" \
  profile_names_match "topaz-render-instance-profile" "topaz-render-instance-profile"
assert_false "profile_names_match: different names do not match" \
  profile_names_match "some-other-profile" "topaz-render-instance-profile"
assert_false "profile_names_match: empty actual does not match a real expected name" \
  profile_names_match "" "topaz-render-instance-profile"

# ---- run_idempotent: the shared AWS-call idempotency wrapper ------------------------------------

# (b)/(c) need a command that fails and writes to stderr; stubbed rather than shelling out to a real
# AWS call (this whole file is meant to run with no AWS credentials or network access).
_stub_fail_matching_pattern() {
  echo "EntityAlreadyExists: role topaz-render-instance-role already exists" >&2
  return 1
}
_stub_fail_nonmatching_pattern() {
  echo "AccessDeniedException: user is not authorized to perform this action" >&2
  return 1
}

# (a) command succeeds -> returns 0.
if run_idempotent "EntityAlreadyExists" true; then rc=0; else rc=$?; fi
assert_eq "run_idempotent: successful command returns 0" "$rc" "0"

# (b) command fails, stderr matches the pattern -> returns 2 (caller decides what that means).
if run_idempotent "EntityAlreadyExists" _stub_fail_matching_pattern; then rc=0; else rc=$?; fi
assert_eq "run_idempotent: matching-pattern failure returns 2" "$rc" "2"

# (c) command fails, stderr does NOT match the pattern -> hard exit 1, with the original stderr passed
# through. run_idempotent calls `exit`, not `return`, on this path, so it must be driven inside a
# subshell here or it would tear down this whole test script.
SUBSHELL_ERR="$(mktemp)"
if ( run_idempotent "EntityAlreadyExists" _stub_fail_nonmatching_pattern ) 2>"$SUBSHELL_ERR"; then
  subshell_rc=0
else
  subshell_rc=$?
fi
assert_eq "run_idempotent: non-matching-pattern failure exits the subshell with 1" "$subshell_rc" "1"
assert_true "run_idempotent: non-matching-pattern stderr is passed through, not swallowed" \
  grep -q "AccessDeniedException" "$SUBSHELL_ERR"
rm -f "$SUBSHELL_ERR"

echo
if [ "$fail" -ne 0 ]; then
  echo "control_plane_validation tests: FAILED"
  exit 1
fi
echo "control_plane_validation tests: all $pass_count assertions passed"
