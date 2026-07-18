#!/usr/bin/env bash
# Sourceable decision helpers for .github/workflows/auto-merge-claude.yml.
#
# WHY: the merge/CI-gate/delete logic that decides whether a branch reaches `main` is the most
# consequential automation in the repo, so its extractable PREDICATES live here as functions the
# workflow `source`s directly. Production and tests then run the IDENTICAL implementation (no shadow
# copy to drift). tests/test_auto_merge_logic.sh exercises these against a scratch git repo plus canned
# `gh api` JSON, and is wired into ci.yml.
#
# NOT extracted: the git plumbing around these predicates (fetch/checkout/merge/push, the conflict-PR
# path, the branch listing/filtering) stays inline in the workflow — a thin, linear sequence of git/gh
# calls that reads clearly in place.

# ci_conclusion_from_json <json> — given the JSON body of
# `gh api repos/<repo>/actions/workflows/ci.yml/runs?head_sha=<sha>&per_page=1` (or "" / unparseable
# JSON, e.g. from a failed API call), print the conclusion of the most recent run:
#   - "success" / "failure" / "in_progress" / ... — a real run's conclusion.
#   - "none"    — valid JSON but no matching run yet (new commit; CI hasn't started/finished).
#   - "error"   — the API call failed, or returned empty/unparseable/error-shaped JSON.
# Requires `jq`. NOTE: jq treats a completely empty stdin as "no output, exit 0" (not an error), so an
# empty/missing `$1` is checked explicitly rather than relying on jq's own exit code for that case.
ci_conclusion_from_json() {
  local out
  # A JSON object with NO `workflow_runs` array at all (e.g. `{"message":"Not Found"}`, what a failed
  # `gh api` call's stdout looks like on an HTTP error) must parse to "error", NOT "none" — otherwise
  # an API failure would be indistinguishable from a legitimate zero-runs response and could satisfy a
  # gate. The `(.workflow_runs | type) != "array"` guard requires workflow_runs to actually be an array
  # before treating it as a real (possibly empty) result.
  if [ -n "$1" ] \
     && out="$(printf '%s' "$1" | jq -r 'if (.workflow_runs | type) != "array" then "error" else (.workflow_runs[0] as $r | if $r == null then "none" else ($r.conclusion // $r.status // "unknown") end) end' 2>/dev/null)" \
     && [ -n "$out" ]; then
    printf '%s\n' "$out"
  else
    echo "error"
  fi
}

# is_ci_green <conclusion> — fail-closed: ONLY an exact "success" counts as green. Any other value
# (in-progress, failure, "none", "error") is NOT green, so a missing/ambiguous CI result blocks the
# merge instead of silently defaulting to allow.
is_ci_green() {
  [ "$1" = "success" ]
}

# is_ancestor_of <maybe-ancestor-ref> <descendant-ref> — true (exit 0) if the first ref's commit is
# reachable from the second, i.e. the first is already merged into the second. Used both for "already
# contained in main, just clean up" and for the re-confirm-before-delete ancestry check (a branch whose
# tip advanced after the merge decision was made must NOT look like an ancestor, so it must NOT be
# deleted).
is_ancestor_of() {
  git merge-base --is-ancestor "$1" "$2"
}

# ci_run_id_from_json <json> — the numeric id of the most recent run (for gh api/gh run rerun
# targeting), or "" if none/unparseable. Companion to ci_conclusion_from_json.
ci_run_id_from_json() {
  local out
  if [ -n "$1" ] \
     && out="$(printf '%s' "$1" | jq -r 'if (.workflow_runs | type) != "array" then "" else (.workflow_runs[0] as $r | if $r == null then "" else ($r.id // "") end) end' 2>/dev/null)"; then
    printf '%s\n' "$out"
  else
    printf '\n'
  fi
}

# ci_run_attempt_from_json <json> — the run_attempt of the most recent run (GitHub's own retry
# counter — 1 for a never-retried run), or "" if none/unparseable/missing.
ci_run_attempt_from_json() {
  local out
  if [ -n "$1" ] \
     && out="$(printf '%s' "$1" | jq -r 'if (.workflow_runs | type) != "array" then "" else (.workflow_runs[0] as $r | if $r == null then "" else ($r.run_attempt // "") end) end' 2>/dev/null)"; then
    printf '%s\n' "$out"
  else
    printf '\n'
  fi
}

# should_retry_failed_ci <conclusion> <run_attempt> — true (exit 0) only for a GENUINE terminal
# failure ("failure", never "in_progress"/"none"/"error"/"cancelled"/etc.) on its FIRST attempt
# (run_attempt == "1"). Bounds this to exactly ONE automatic retry ever per branch: GitHub increments
# run_attempt on every rerun, so a re-run that fails again reads run_attempt=2 and is never retried
# again — a content-free, self-limiting retry for transient/flaky CI. A real code bug just fails again
# on attempt 2 and the branch is left un-merged for a human; this never touches branch content.
should_retry_failed_ci() {
  [ "$1" = "failure" ] && [ "$2" = "1" ]
}
