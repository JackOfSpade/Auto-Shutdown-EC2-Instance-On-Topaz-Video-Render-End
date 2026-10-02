#!/usr/bin/env bash
# Functional tests for scripts/auto_merge_decision.sh — the CI-gate + delete-safety predicates that
# .github/workflows/auto-merge-claude.yml sources to decide whether a branch merges to main and whether
# a merged branch is safe to delete.
#
# This sources the SAME functions the production workflow sources (not a reimplementation) and exercises
# them against a scratch git repo with fixture branches/commits, plus canned `gh api` JSON for the
# CI-conclusion parsing. Wired into ci.yml.
#
# The scratch repo is deliberately isolated from the ambient git environment (see the `git init` below):
# no global/system config, no `init.templateDir` hooks. This suite is meant to be run locally as well as
# in CI, and a developer's own hooks or `commit.gpgsign` must never run against — or abort — the fixture
# commits here.
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
  local rc=0
  "$@" || rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "FAIL: $desc (expected failure/false, got success)"
    fail=1
  elif [ "$rc" -ge 126 ]; then
    # 126/127 are the shell's "found but not executable" / "command not found" statuses. A naive
    # `if ! "$@"` treats those as a PASS, so a predicate renamed or deleted in
    # scripts/auto_merge_decision.sh would leave MOST of this suite green against a function that no
    # longer exists — bash's "command not found" goes to stderr, invisible in the PASS/FAIL summary.
    # The safety-critical assertions here (red CI must skip, a malformed API response must not be
    # green, an advanced branch must not be deleted) are exactly the assert_false ones, so they are
    # the ones that must not be able to pass vacuously.
    # NOTE: only >= 126 is treated as broken, NOT every "large" status — git's own 128 for an
    # unresolvable ref is a genuine result from a working command, so assertions about it use an
    # explicit exit-status check instead of assert_false (see the is_ancestor_of error cases below).
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

# ---- predicate existence gate ----------------------------------------------------------------
# Belt-and-braces for the assert_false hazard above: assert their existence UP FRONT, so a rename or
# a deletion in scripts/auto_merge_decision.sh reports the missing predicate by name instead of
# showing up as a wall of rc=127 assertion failures. This list is the public predicate surface the
# workflow calls; the reverse check below keeps it from rotting when a predicate is added.
EXPECTED_PREDICATES="ci_conclusion_from_json is_ci_green ci_runs_api_path can_merge_next_branch"
EXPECTED_PREDICATES="$EXPECTED_PREDICATES is_ancestor_of ci_run_id_from_json ci_run_attempt_from_json"
EXPECTED_PREDICATES="$EXPECTED_PREDICATES should_retry_failed_ci"
for fn in $EXPECTED_PREDICATES; do
  declare -F "$fn" >/dev/null \
    || { echo "FAIL: predicate $fn is missing from scripts/auto_merge_decision.sh"; fail=1; }
done
# Reverse direction: every public (non `_`-prefixed) function the script defines must appear above,
# so a NEW predicate can't be added to the workflow's decision surface with no test and no notice.
# `_ci_run_field_from_json` is deliberately excluded — it is the private shared helper behind the two
# wrappers, exercised through them.
# `done < <(...)` rather than a pipeline into the loop: a piped loop body runs in a SUBSHELL, so a
# `fail=1` set inside it would be discarded and this gate would report nothing.
while read -r fn; do
  case " $EXPECTED_PREDICATES " in
    *" $fn "*) ;;
    *) echo "FAIL: scripts/auto_merge_decision.sh defines $fn, which this suite does not cover — test it and add it to EXPECTED_PREDICATES"; fail=1 ;;
  esac
done < <(grep -oE '^[a-z][a-z0-9_]*\(\)' "$ROOT/scripts/auto_merge_decision.sh" | sed 's/()$//')

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

# ---- exact-main CI gate / one-merge-per-cycle -------------------------------------------------

assert_eq "CI API path scopes the query to the supplied exact SHA" \
  "$(ci_runs_api_path 'owner/repo' 'abc123')" \
  "repos/owner/repo/actions/workflows/ci.yml/runs?head_sha=abc123&per_page=10"

assert_true "green current main permits the first candidate merge" \
  can_merge_next_branch "success" "0"
assert_false "red current main blocks every candidate merge" \
  can_merge_next_branch "failure" "0"
assert_false "in-progress current main blocks every candidate merge" \
  can_merge_next_branch "in_progress" "0"
assert_false "missing current-main CI blocks every candidate merge" \
  can_merge_next_branch "none" "0"
assert_false "API error for current main blocks every candidate merge" \
  can_merge_next_branch "error" "0"
assert_false "a second candidate cannot merge in the same green-main cycle" \
  can_merge_next_branch "success" "1"
assert_false "an invalid merge count fails closed" can_merge_next_branch "success" "not-a-number"

# ---- is_ancestor_of: already-merged + re-confirm-before-delete, against a scratch git repo --

SCRATCH="$(mktemp -d)"
cleanup() { cd "$ROOT" 2>/dev/null || true; rm -rf "$SCRATCH"; }
trap cleanup EXIT

cd "$SCRATCH"
# ISOLATE THE FIXTURE REPO FROM THE AMBIENT GIT ENVIRONMENT. Set before `git init`, so both the
# config and the template are neutered at creation time:
#   - GIT_CONFIG_GLOBAL/GIT_CONFIG_SYSTEM=/dev/null — the developer's ~/.gitconfig never applies.
#     Without this, a global `commit.gpgsign = true` makes the fixture commits below prompt/fail and
#     abort the whole suite under `set -euo pipefail` with a gpg error rather than a test failure,
#     and a global `core.hooksPath` points the fixture repo at the developer's own hooks.
#   - --template= (empty) — do NOT copy `init.templateDir` hooks into this repo. This repo's own
#     developer setup can put a `pre-push` CI hook there; a bare `git init`
#     copies it into every scratch repo, so the moment this suite grows an end-to-end delete-safety
#     test that pushes, the test would recursively invoke that hook inside itself.
# Both mechanisms need git >= 2.32 / 1.7 respectively (satisfied by CI's ubuntu-latest and by local
# dev machines); switch to per-command `git -c` prefixes if an older git ever has to be supported.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
git init -q -b main --template=
# Now MANDATORY rather than merely polite: with the global config neutered there is no identity to
# fall back on. commit.gpgsign is redundant under /dev/null global config and set only to document
# that these fixture commits must never reach for a signing key.
git config user.name "test"
git config user.email "test@example.com"
git config commit.gpgsign false
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

# The delete gate in auto-merge-claude.yml treats ANY non-zero from this helper as "do not delete"
# (and, at the top of the loop, as "not already contained — attempt a real merge"). `git merge-base
# --is-ancestor` exits 128, not 1, for an unresolvable ref, so lock in that the helper passes that
# status straight through: a ref that vanished mid-run must never read as "already contained in
# main" and get deleted. Asserted on the exit status EXPLICITLY rather than via assert_false, which
# (correctly) rejects rc >= 126 as a broken invocation — git's 128 here is a real answer from a
# working command, not a missing function. 2>/dev/null keeps git's `fatal:` lines out of the suite
# output, where they would read as a broken test run.
rc=0; is_ancestor_of no-such-ref-abcdef main 2>/dev/null || rc=$?
assert_true "an unresolvable ANCESTOR ref is not reported as an ancestor (git's 128 stays non-zero)" \
  test "$rc" -ne 0
rc=0; is_ancestor_of merged-branch no-such-ref-abcdef 2>/dev/null || rc=$?
assert_true "an unresolvable DESCENDANT ref is not reported as containing anything" \
  test "$rc" -ne 0

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

# Genuinely unparseable JSON syntax (as opposed to valid-but-wrong-shape above) exercises the shared
# _ci_run_field_from_json helper's jq-failure branch (jq itself exits non-zero) rather than the
# "workflow_runs isn't an array" branch — both wrappers must still fail closed to "", not error out
# under `set -euo pipefail`.
run_id="$(ci_run_id_from_json '{not valid json')"
assert_eq "unparseable JSON syntax: run id is empty (shared helper's jq-failure path)" "$run_id" ""
attempt="$(ci_run_attempt_from_json '{not valid json')"
assert_eq "unparseable JSON syntax: run_attempt is empty (shared helper's jq-failure path)" "$attempt" ""

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
