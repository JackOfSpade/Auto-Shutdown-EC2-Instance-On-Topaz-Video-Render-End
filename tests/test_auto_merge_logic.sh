#!/usr/bin/env bash
# Functional tests for scripts/auto_merge_decision.sh — the CI-gate + delete-safety predicates that
# .github/workflows/auto-merge-claude.yml sources to decide whether a branch merges to main and whether
# a merged branch is safe to delete.
#
# This sources the SAME functions the production workflow sources (not a reimplementation) and exercises
# them against a scratch git repo with fixture branches/commits, plus canned `gh api` JSON for the
# CI-conclusion parsing. Wired into ci.yml.
#
# Run:  bash tests/test_auto_merge_logic.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/auto_merge_decision.sh
source "$ROOT/scripts/auto_merge_decision.sh"

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

# ---- ci_conclusion_from_json / is_ci_green: the fail-closed CI gate ------------------------

conclusion="$(ci_conclusion_from_json '{"workflow_runs":[{"conclusion":"success"}]}')"
assert_eq "green-CI JSON parses to 'success'" "$conclusion" "success"
assert_true "green-CI branch: is_ci_green must allow the merge" is_ci_green "$conclusion"

conclusion="$(ci_conclusion_from_json '{"workflow_runs":[{"conclusion":"failure"}]}')"
assert_eq "red-CI JSON parses to 'failure'" "$conclusion" "failure"
assert_false "red-CI branch: is_ci_green must SKIP the merge" is_ci_green "$conclusion"

conclusion="$(ci_conclusion_from_json '{"workflow_runs":[]}')"
assert_eq "no-CI-run-yet JSON parses to 'none'" "$conclusion" "none"
assert_false "branch with no CI run yet: is_ci_green must SKIP, fail-closed" is_ci_green "$conclusion"

conclusion="$(ci_conclusion_from_json '')"
assert_eq "empty/failed API response parses to 'error'" "$conclusion" "error"
assert_false "gh api failure: is_ci_green must SKIP, fail-closed" is_ci_green "$conclusion"

conclusion="$(ci_conclusion_from_json '{"workflow_runs":[{"status":"in_progress","conclusion":null}]}')"
assert_false "in-progress CI: is_ci_green must SKIP until it completes" is_ci_green "$conclusion"

# Error-shaped body (valid JSON, but no workflow_runs array — e.g. gh api's stdout on an HTTP error)
# must parse to "error", NOT "none": an API failure is not the same fact as "legitimately zero runs".
conclusion="$(ci_conclusion_from_json '{"message":"Not Found"}')"
assert_eq "malformed/error-shaped JSON (missing workflow_runs) parses to 'error', not 'none'" "$conclusion" "error"
assert_false "is_ci_green must NOT treat a malformed API response as green" is_ci_green "$conclusion"

# ---- ci_conclusion_from_json: the two-runs-per-sha (push + pull_request events) case --------

# A branch with an open PR gets TWO "CI" runs per commit; the newer one (index 0, most recent) can
# still be in_progress while the older one already succeeded. A success ANYWHERE must win so a
# genuinely green branch is never parked behind its own duplicate run.
conclusion="$(ci_conclusion_from_json '{"workflow_runs":[{"status":"in_progress","conclusion":null},{"conclusion":"success"}]}')"
assert_eq "newer run in_progress, older run success: 'success' wins (duplicate-run rescue)" "$conclusion" "success"
assert_true "duplicate-run rescue: is_ci_green must allow the merge" is_ci_green "$conclusion"

# When NEITHER duplicate run succeeded, behavior is unchanged: the first (most recent) run's own
# conclusion, not the older run's — "cancelled" here, not "failure".
conclusion="$(ci_conclusion_from_json '{"workflow_runs":[{"conclusion":"cancelled"},{"conclusion":"failure"}]}')"
assert_eq "newer run cancelled, older run failure, no success anywhere: first run's value ('cancelled') wins" "$conclusion" "cancelled"
assert_false "no success among duplicate runs: is_ci_green must SKIP the merge" is_ci_green "$conclusion"

# ---- is_ci_green: fail-closed lock-in for near-miss statuses that must never count as green --

assert_false "is_ci_green must reject 'cancelled' (fail-closed lock-in)" is_ci_green "cancelled"
assert_false "is_ci_green must reject 'skipped' (fail-closed lock-in)" is_ci_green "skipped"

# ---- is_ancestor_of: already-merged + re-confirm-before-delete, against a scratch git repo --

SCRATCH="$(mktemp -d)"
cleanup() { cd "$ROOT" 2>/dev/null || true; rm -rf "$SCRATCH"; }
trap cleanup EXIT

cd "$SCRATCH"
git init -q -b main
git config user.name "test"
git config user.email "test@example.com"
echo "seed" > f.txt
git add f.txt
git commit -q -m "seed"

# A branch fully merged into main: already-merged check (and delete-safety) must see it as an ancestor.
git checkout -q -b merged-branch
echo "merged change" >> f.txt
git commit -q -am "merged change"
git checkout -q main
git merge -q --no-ff merged-branch -m "merge merged-branch"
assert_true "a branch merged into main IS an ancestor (already-merged / safe-to-delete)" \
  is_ancestor_of merged-branch main

# A branch whose tip advances AFTER the merge decision (a push landing during the merge window) must
# NOT look like an ancestor, so the re-confirm-before-delete check must refuse to delete it.
git checkout -q -b advances-after-merge
echo "v1" >> f.txt
git commit -q -am "v1"
git checkout -q main
git merge -q --no-ff advances-after-merge -m "merge advances-after-merge (decision point)"
git checkout -q advances-after-merge
echo "v2 pushed during the merge window" >> f.txt
git commit -q -am "v2 pushed during the merge window"
git checkout -q main
assert_false "a branch that advanced AFTER the merge decision is NOT an ancestor — must NOT be deleted" \
  is_ancestor_of advances-after-merge main

# An unmerged branch must not be mistaken for "already merged, just clean up".
git checkout -q -b unmerged-branch
echo "unmerged" >> f.txt
git commit -q -am "unmerged"
git checkout -q main
assert_false "an unmerged branch is NOT an ancestor of main — must attempt a real merge, not skip as already-merged" \
  is_ancestor_of unmerged-branch main

# ---- ci_run_id_from_json / ci_run_attempt_from_json / should_retry_failed_ci: the one-shot,
# content-free CI retry --------------------------------------------------------------------------

run_id="$(ci_run_id_from_json '{"workflow_runs":[{"id":12345,"conclusion":"failure","run_attempt":1}]}')"
assert_eq "run id parses from a real run" "$run_id" "12345"

attempt="$(ci_run_attempt_from_json '{"workflow_runs":[{"id":12345,"conclusion":"failure","run_attempt":1}]}')"
assert_eq "run_attempt parses from a real run" "$attempt" "1"

run_id="$(ci_run_id_from_json '{"workflow_runs":[]}')"
assert_eq "no matching run: run id is empty" "$run_id" ""

run_id="$(ci_run_id_from_json '')"
assert_eq "gh api failure: run id is empty (fail closed, no retry attempted)" "$run_id" ""

# Fail-closed coverage for the run-metadata parsers. ci_run_attempt_from_json gates
# should_retry_failed_ci (which fires ONLY when run_attempt == "1"), so its "" result — never a number,
# never "null" — on no-run / API-failure / error-shaped input is the load-bearing guarantee that a
# wrongful retry can't fire against the main-merge automation.
attempt="$(ci_run_attempt_from_json '{"workflow_runs":[]}')"
assert_eq "no matching run: run_attempt is empty (fail closed — should_retry can't see '1')" "$attempt" ""
attempt="$(ci_run_attempt_from_json '')"
assert_eq "gh api failure: run_attempt is empty (fail closed, no retry)" "$attempt" ""
# Error-shaped body: each parser carries its OWN copy of the (.workflow_runs|type)!="array" guard, so
# assert them directly.
attempt="$(ci_run_attempt_from_json '{"message":"Not Found"}')"
assert_eq "error-shaped JSON (missing workflow_runs): run_attempt is empty, not a bogus number" "$attempt" ""
run_id="$(ci_run_id_from_json '{"message":"Not Found"}')"
assert_eq "error-shaped JSON (missing workflow_runs): run id is empty, not a bogus id" "$run_id" ""

# End-to-end lock: the parser's actual no-run output, piped straight into the predicate, must NOT
# trigger a retry (guards against a future edit that made the parser emit "1" for a no-run state).
assert_false "no-run run_attempt piped into should_retry_failed_ci must NOT retry (fail closed end-to-end)" \
  should_retry_failed_ci "failure" "$(ci_run_attempt_from_json '{"workflow_runs":[]}')"

assert_true "first-attempt genuine failure: should_retry_failed_ci allows ONE retry" \
  should_retry_failed_ci "failure" "1"
assert_false "second-attempt failure (already retried once): should_retry_failed_ci must NOT retry again" \
  should_retry_failed_ci "failure" "2"
assert_false "in-progress run: should_retry_failed_ci must NOT retry (not a terminal failure)" \
  should_retry_failed_ci "in_progress" "1"
assert_false "no-run-yet ('none'): should_retry_failed_ci must NOT retry" \
  should_retry_failed_ci "none" "1"
assert_false "API error: should_retry_failed_ci must NOT retry" \
  should_retry_failed_ci "error" "1"
assert_false "missing run_attempt (empty string): should_retry_failed_ci must NOT retry" \
  should_retry_failed_ci "failure" ""

echo
if [ "$fail" -ne 0 ]; then
  echo "auto_merge_decision tests: FAILED"
  exit 1
fi
echo "auto_merge_decision tests: all $pass_count assertions passed"
