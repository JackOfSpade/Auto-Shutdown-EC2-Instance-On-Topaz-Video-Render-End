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
run_idempotent() {  # <grep -E pattern> <command...>
  local pattern="$1"; shift
  local errfile; errfile="$(mktemp)"
  if ! "$@" 2>"$errfile"; then
    if grep -qE "$pattern" "$errfile"; then rm -f "$errfile"; return 2; fi
    cat "$errfile" >&2; rm -f "$errfile"; exit 1
  fi
  rm -f "$errfile"
}
