#!/usr/bin/env bash
# Fake `zip` for the deployment test. It creates the requested archive path,
# and -- unlike the truncate-and-forget version this replaces -- it VALIDATES
# and RECORDS the file list, because that list is a load-bearing contract:
# 04-deploy-max-lifetime-lambda.sh zips only the runtime file(s) the Lambda
# needs and must never fall back to `zip -r .` (which would ship the test
# suite, conftest.py, requirements-dev.txt and stale __pycache__ into the
# package). A fixture that ignores its arguments lets a typo'd or renamed file
# pass CI green while real zip exits 12 ("Nothing to do!") on the operator's
# workstation, aborting the deploy under set -euo pipefail.
set -euo pipefail

[[ "$1" == "-q" ]] && shift   # AND-list, so a non-match here is not a set -e exit
archive="${1:?expected output archive path}"; shift

[[ $# -gt 0 ]] || { echo "zip error: Nothing to do! ($archive)" >&2; exit 12; }
for f in "$@"; do
  # Same outcome real zip gives for a name that matches nothing.
  [[ -e "$f" ]] || {
    echo "zip warning: name not matched: $f"
    echo "zip error: Nothing to do! ($archive)" >&2
    exit 12
  }
done

# One line per named input, so a test can compare the manifest against the
# exact expected contents rather than substring-matching it.
printf '%s\n' "$@" > "${FAKE_ZIP_MANIFEST:-/dev/null}"
: > "$archive"
