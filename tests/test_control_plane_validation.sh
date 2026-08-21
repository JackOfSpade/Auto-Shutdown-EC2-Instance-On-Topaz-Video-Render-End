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
  local rc=0
  "$@" || rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "FAIL: $desc (expected failure/false, got success)"
    fail=1
  elif [ "$rc" -ge 126 ]; then
    # 126/127 are the shell's "found but not executable" / "command not found" statuses. A naive
    # `if ! "$@"` treats those as a PASS, so a predicate renamed or deleted in
    # control-plane/lib/validation.sh would leave MOST of this suite green against a function that
    # no longer exists — bash's "command not found" goes to stderr, invisible in the PASS/FAIL
    # summary. The negative-path assertions are exactly the assert_false ones (an empty INSTANCE_ID
    # rejected, an out-of-range IDLE_MINUTES rejected, an unconfirmed shutdown behavior rejected),
    # and those predicates gate real ec2:StopInstances-capable scripts, so they are precisely the
    # ones that must not be able to pass vacuously.
    # Mirrors tests/test_auto_merge_logic.sh's harness, deliberately: same hazard, same fix.
    # Only >= 126 is treated as broken, NOT every "large" status — a genuine command can return one.
    echo "FAIL: $desc (command '$1' not found or not executable, rc=$rc — not a genuine false)"
    fail=1
  else
    echo "PASS: $desc"
    pass_count=$((pass_count + 1))
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

# ---- predicate existence gate ------------------------------------------------------------------
# Belt-and-braces for the assert_false hazard above: assert existence UP FRONT, so a rename or a
# deletion in either sourced library reports the missing predicate BY NAME instead of showing up as
# a wall of rc=127 assertion failures (or, before the hardening above, as silence). The list is the
# set of functions this suite actually calls across control-plane/lib/validation.sh and
# control-plane/lib/aws-idempotent.sh.
EXPECTED_PREDICATES="is_valid_instance_id is_valid_idle_minutes is_valid_max_lifetime_hours"
EXPECTED_PREDICATES="$EXPECTED_PREDICATES is_shutdown_behavior_confirmed profile_names_match"
EXPECTED_PREDICATES="$EXPECTED_PREDICATES run_idempotent run_idempotent_hinted"
for fn in $EXPECTED_PREDICATES; do
  declare -F "$fn" >/dev/null \
    || { echo "FAIL: predicate $fn is missing from control-plane/lib/"; fail=1; }
done

# ---- is_valid_instance_id: the one input EVERY control-plane script takes ----------------------
# The scripts tag instances, associate instance profiles onto them, and arm schedules that call
# ec2:StopInstances against them, from an INSTANCE_ID the runbook has the operator `export` into
# their shell -- so a stale export survives across sessions and across scripts. AWS has only ever
# issued the 8-hex legacy form and the 17-hex current form, always lowercase.

assert_true  "instance id: 17-hex current form is valid"  is_valid_instance_id "i-0123456789abcdef0"
assert_true  "instance id: 8-hex legacy form is valid"    is_valid_instance_id "i-1234abcd"
assert_true  "instance id: all-digits 17-hex is valid"    is_valid_instance_id "i-01234567890123456"

assert_false "instance id: '' is invalid"                        is_valid_instance_id ""
assert_false "instance id: bare id without the i- prefix is invalid" is_valid_instance_id "0123456789abcdef0"
assert_false "instance id: a name-like value is invalid"         is_valid_instance_id "i-not-an-id"
assert_false "instance id: 16 hex digits (one short) is invalid"  is_valid_instance_id "i-0123456789abcde"
assert_false "instance id: 18 hex digits (one long) is invalid"   is_valid_instance_id "i-0123456789abcdef01"
assert_false "instance id: 9 hex digits is invalid (between the two legal widths)" is_valid_instance_id "i-1234abcde"
assert_false "instance id: uppercase hex is invalid (AWS emits lowercase)" is_valid_instance_id "i-0123456789ABCDEF0"
assert_false "instance id: non-hex letters are invalid"          is_valid_instance_id "i-0123456789abcdefg"
assert_false "instance id: a volume id is invalid"               is_valid_instance_id "vol-0123456789abcdef0"
# The regex is anchored at both ends; without ^ and $ a shell-mangled value like a trailing newline
# or an extra word would still match somewhere inside.
assert_false "instance id: trailing junk after a valid id is invalid" is_valid_instance_id "i-0123456789abcdef0 extra"
assert_false "instance id: leading junk before a valid id is invalid" is_valid_instance_id "x i-0123456789abcdef0"

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
assert_false "run_idempotent: with no hint configured, nothing extra is appended to the stderr" \
  grep -q "HINT:" "$SUBSHELL_ERR"
rm -f "$SUBSHELL_ERR"

# ---- run_idempotent_hinted: the same wrapper, plus an operator hint on the hard-exit path ------
# 02's instance-profile association and 04's create-function both fail in a way that reads like a
# typo when it is really just IAM's eventual consistency. The hint must NOT be folded into the
# idempotency pattern: a match there returns 2, which sends both call sites into a reconciliation
# branch that reads back a nonexistent entity and reports something actively misleading.

_stub_fail_propagation_lag() {
  echo "An error occurred (InvalidParameterValue) when calling the AssociateIamInstanceProfile operation: Invalid IAM Instance Profile name" >&2
  return 1
}

# (a) success is untouched by the hint arguments.
if run_idempotent_hinted "EntityAlreadyExists" "Invalid IAM Instance Profile" "HINT: wait and re-run." true; then rc=0; else rc=$?; fi
assert_eq "run_idempotent_hinted: successful command returns 0" "$rc" "0"

# (b) the idempotency pattern still wins over the hint pattern -- an "already exists" failure must
# stay a return 2 the caller reconciles, never a hinted hard exit.
if run_idempotent_hinted "EntityAlreadyExists" "Invalid IAM Instance Profile" "HINT: wait and re-run." _stub_fail_matching_pattern; then rc=0; else rc=$?; fi
assert_eq "run_idempotent_hinted: matching-idempotency-pattern failure still returns 2" "$rc" "2"

# (c) an unexpected failure that matches the hint pattern: still a hard exit 1, still passes the
# original stderr through, and ADDS the hint. Driven in a subshell because it calls `exit`.
HINTED_ERR="$(mktemp)"
if ( run_idempotent_hinted "IncorrectState|already" "Invalid IAM Instance Profile|InvalidParameterValue" \
       "HINT: IAM propagation is eventually consistent -- wait a minute and re-run." \
       _stub_fail_propagation_lag ) 2>"$HINTED_ERR"; then
  hinted_rc=0
else
  hinted_rc=$?
fi
assert_eq "run_idempotent_hinted: hint-matching failure still exits 1 (it is still a real failure)" "$hinted_rc" "1"
assert_true "run_idempotent_hinted: the raw AWS stderr is still passed through" \
  grep -q "Invalid IAM Instance Profile name" "$HINTED_ERR"
assert_true "run_idempotent_hinted: the propagation hint is appended for a hint-matching failure" \
  grep -q "wait a minute and re-run" "$HINTED_ERR"
rm -f "$HINTED_ERR"

# (d) an unexpected failure that does NOT match the hint pattern must not get the hint -- a hint
# glued onto an AccessDenied would send the operator off to wait for propagation that is not the
# problem.
UNHINTED_ERR="$(mktemp)"
if ( run_idempotent_hinted "IncorrectState|already" "Invalid IAM Instance Profile|InvalidParameterValue" \
       "HINT: IAM propagation is eventually consistent -- wait a minute and re-run." \
       _stub_fail_nonmatching_pattern ) 2>"$UNHINTED_ERR"; then
  unhinted_rc=0
else
  unhinted_rc=$?
fi
assert_eq "run_idempotent_hinted: non-hint-matching failure exits 1" "$unhinted_rc" "1"
assert_true "run_idempotent_hinted: non-hint-matching stderr is passed through" \
  grep -q "AccessDeniedException" "$UNHINTED_ERR"
assert_false "run_idempotent_hinted: the hint is NOT shown for an unrelated failure" \
  grep -q "wait a minute and re-run" "$UNHINTED_ERR"
rm -f "$UNHINTED_ERR"

echo
if [ "$fail" -ne 0 ]; then
  echo "control_plane_validation tests: FAILED"
  exit 1
fi
echo "control_plane_validation tests: all $pass_count assertions passed"
