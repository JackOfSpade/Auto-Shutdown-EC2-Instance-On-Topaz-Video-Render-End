#!/usr/bin/env bash
# The deployment test only needs a zip command that creates the requested
# archive path; Lambda code contents are not under test here.
set -euo pipefail

if [[ "$1" == "-q" ]]; then
  shift
fi

: > "${1:?expected output archive path}"
