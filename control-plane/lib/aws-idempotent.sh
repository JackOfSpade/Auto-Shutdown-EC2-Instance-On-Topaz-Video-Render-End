# shellcheck shell=bash
#
# control-plane/lib/aws-idempotent.sh
#
# Shared idempotency helper for control-plane/*.sh. Almost every AWS CLI call
# in this pipeline that creates or attaches a named entity (IAM role,
# instance profile, Lambda function, EventBridge rule/schedule, invoke
# permission...) can fail simply because a previous run already created that
# entity -- that failure is expected and fine. A DIFFERENT failure (bad JSON,
# missing permissions, throttling, a typo in an ARN...) is not expected and
# must never be swallowed. Before this lib existed, every call site
# copy-pasted its own `2>/tmp/<name>_err.$$` / grep / cat block to draw that
# line; run_idempotent() draws it once so all ~9 sites behave identically and
# a predictable /tmp/<name>_err.$$ path is never left behind.
#
# run_idempotent <grep -E pattern> <command...>
#   Runs <command...>, capturing its stderr to a scratch file made with
#   mktemp (not a predictable /tmp path -- avoids both leftover files with
#   guessable names and the collision risk that comes with them).
#     - command succeeds                              -> return 0 (ran clean)
#     - command fails, stderr matches <pattern>        -> return 2
#         (an "already exists" / "already attached" style failure -- the
#         caller decides what that means for its own call site: reuse it,
#         confirm it's the expected one, reconcile a mismatch, etc.)
#     - command fails, stderr does NOT match <pattern>  -> print the captured
#         stderr and hard-exit 1 (matches every current call site's
#         behavior: a genuinely unexpected failure aborts the whole script,
#         loudly, instead of being treated as "probably fine").
#
# run_idempotent_hinted <idempotency pattern> <hint pattern> <hint text> <command...>
#   Exactly run_idempotent, plus one thing: on the hard-exit path (an
#   UNEXPECTED failure), if the captured stderr also matches <hint pattern>,
#   print <hint text> to stderr after the raw error and before exiting 1.
#
#   WHY this exists rather than just widening run_idempotent's idempotency
#   pattern at the two call sites that want it: a widened pattern returns 2,
#   which means "this entity already exists, go reconcile it" -- and both call
#   sites' reconciliation branches then query AWS for an entity that does not
#   exist yet, get back "None", and abort with an actively misleading message
#   (02 would report "associated with a DIFFERENT IAM instance profile: None"
#   for what is really just IAM propagation lag). The failure must stay a hard
#   failure; only the OPERATOR-FACING EXPLANATION changes.
#
#   Both current uses are the same hazard: IAM's propagation to EC2/Lambda is
#   eventually consistent and routinely takes 30-60s on first creation, while
#   the scripts wait a fixed 10s. The resulting AWS error names a "bad"
#   role/profile and reads exactly like a typo, when the correct response is
#   "wait a minute and re-run" -- these scripts being idempotent, that is free.
run_idempotent() {  # <grep -E pattern> <command...>
  local pattern="$1"; shift
  run_idempotent_hinted "$pattern" "" "" "$@"
}

run_idempotent_hinted() {  # <grep -E pattern> <grep -E hint pattern> <hint text> <command...>
  local pattern="$1" hint_pattern="$2" hint_text="$3"; shift 3
  local errfile; errfile="$(mktemp)"
  if ! "$@" 2>"$errfile"; then
    if grep -qE "$pattern" "$errfile"; then rm -f "$errfile"; return 2; fi
    cat "$errfile" >&2
    # An empty hint pattern means "no hint at all", and has to be tested
    # explicitly: `grep -qE ""` matches EVERY line, so without this guard
    # run_idempotent()'s delegation above (which passes an empty pattern AND
    # an empty text) would append a blank line to every unexpected failure.
    if [[ -n "$hint_pattern" ]] && grep -qE "$hint_pattern" "$errfile"; then
      printf '%s\n' "$hint_text" >&2
    fi
    rm -f "$errfile"; exit 1
  fi
  rm -f "$errfile"
}
