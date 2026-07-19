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
# `gh api repos/<repo>/actions/workflows/ci.yml/runs?head_sha=<sha>&per_page=10` (or "" / unparseable
# JSON, e.g. from a failed API call), print:
#   - "success" — ANY run in the returned page has conclusion "success". A branch with an open PR gets
#     TWO "CI" workflow runs per commit (the `push` event and the `pull_request` event), completing
#     independently and in no guaranteed order — per_page=10 (see the workflow's CI-gate comment) pulls
#     back both, so a completed successful run is found even when a duplicate run for the same sha is
#     still in_progress or was cancelled and happens to sort first. This stays fail-closed: "success" is
#     only ever printed when a real completed run of THIS workflow for THIS sha concluded success.
#   - otherwise, the conclusion of the MOST RECENT run (today's original behavior, unchanged when no run
#     succeeded) — "failure" / "in_progress" / ... — a real run's conclusion.
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
  # before treating it as a real (possibly empty) result. Among the runs, a "success" ANYWHERE wins
  # (duplicate-run rationale above); otherwise fall back to the first (most recent) run's own
  # conclusion // status // "unknown" — unchanged from before per_page was widened.
  if [ -n "$1" ] \
     && out="$(printf '%s' "$1" | jq -r 'if (.workflow_runs | type) != "array" then "error" elif (.workflow_runs | length) == 0 then "none" elif (.workflow_runs | any(.conclusion == "success")) then "success" else (.workflow_runs[0] as $r | ($r.conclusion // $r.status // "unknown")) end' 2>/dev/null)" \
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

# _ci_run_field_from_json <json> <field> — shared implementation behind ci_run_id_from_json and
# ci_run_attempt_from_json (the two are identical apart from which field of the most-recent run they
# pull), so the "" / unparseable / no-run-yet fail-closed handling lives in exactly one place. Not
# part of the public predicate surface — the workflow and tests call the two named wrappers below.
_ci_run_field_from_json() {
  local out
  if [ -n "$1" ] \
     && out="$(printf '%s' "$1" | jq -r --arg field "$2" 'if (.workflow_runs | type) != "array" then "" else (.workflow_runs[0] as $r | if $r == null then "" else ($r[$field] // "") end) end' 2>/dev/null)"; then
    printf '%s\n' "$out"
  else
    printf '\n'
  fi
}

# ci_run_id_from_json <json> — the numeric id of the most recent run (for gh api/gh run rerun
# targeting), or "" if none/unparseable. Companion to ci_conclusion_from_json. Deliberately keeps
# FIRST-run semantics (does not search for a success like ci_conclusion_from_json does): this only
# feeds the retry path below, which runs when NOTHING succeeded, so there is no successful run to find —
# the most recent run is exactly the one worth re-running.
ci_run_id_from_json() { _ci_run_field_from_json "$1" id; }

# ci_run_attempt_from_json <json> — the run_attempt of the most recent run (GitHub's own retry
# counter — 1 for a never-retried run), or "" if none/unparseable/missing. Same first-run semantics as
# ci_run_id_from_json, for the same reason: it only matters on the retry path, taken when no run
# succeeded.
ci_run_attempt_from_json() { _ci_run_field_from_json "$1" run_attempt; }

# should_retry_failed_ci <conclusion> <run_attempt> — true (exit 0) only for a GENUINE terminal
# failure ("failure", never "in_progress"/"none"/"error"/"cancelled"/etc.) on its FIRST attempt
# (run_attempt == "1"). Bounds this to exactly ONE automatic retry ever per branch: GitHub increments
# run_attempt on every rerun, so a re-run that fails again reads run_attempt=2 and is never retried
# again — a content-free, self-limiting retry for transient/flaky CI. A real code bug just fails again
# on attempt 2 and the branch is left un-merged for a human; this never touches branch content.
should_retry_failed_ci() {
  [ "$1" = "failure" ] && [ "$2" = "1" ]
}
