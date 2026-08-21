#!/usr/bin/env bash
# Integration test for control-plane/02-create-iam-role.sh.
#
# tests/test_control_plane_validation.sh already covers profile_names_match in
# isolation, but the VALUE of 02's reconciliation branches is entirely in the
# wiring around that predicate: which query is issued, which value it is
# compared against, and that a mismatch exits 1 instead of continuing to the
# final "Done. Instance ... can now publish" line. A refactor that swapped the
# two --query expressions, or dropped an `exit 1`, would pass the predicate
# test, shellcheck, and every other gate. Both branches exist because earlier
# versions "silently accepted ANY existing association as good enough", which
# can leave the instance wearing the WRONG role -- no PutMetricData, and a
# safety net that is dead without saying so.
#
# Also covered here: the METRIC_NAMESPACE render guard (a drifted placeholder
# would otherwise ship a policy scoped to the OLD namespace while every printed
# line claims the new one) and the trust-policy readback on a reused role.
#
# The fake aws CLI records requests, so no AWS credentials or network are used.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROLE_SCRIPT="$ROOT/control-plane/02-create-iam-role.sh"
FAKE_AWS_SOURCE="$ROOT/tests/fixtures/fake-aws-iam-role.sh"
FAKE_SLEEP_SOURCE="$ROOT/tests/fixtures/fake-sleep.sh"
PUTMETRIC_POLICY="$ROOT/control-plane/iam/cloudwatch-putmetric-policy.json"

INSTANCE="i-0123456789abcdef0"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fake_bin="$scratch/bin"
mkdir -p "$fake_bin"
cp "$FAKE_AWS_SOURCE" "$fake_bin/aws"
cp "$FAKE_SLEEP_SOURCE" "$fake_bin/sleep"
chmod +x "$fake_bin/aws" "$fake_bin/sleep"

fail=0
pass_count=0

assert_trace_contains() { # <description> <file> <fixed-string>
  local description="$1" trace="$2" expected="$3"
  if grep -Fq -- "$expected" "$trace"; then
    echo "PASS: $description"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $description (missing '$expected')"
    fail=1
  fi
}

assert_trace_not_contains() { # <description> <file> <fixed-string>
  local description="$1" trace="$2" unexpected="$3"
  if ! grep -Fq -- "$unexpected" "$trace"; then
    echo "PASS: $description"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $description (unexpected '$unexpected')"
    fail=1
  fi
}

assert_eq() { # <description> <actual> <expected>
  local description="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    echo "PASS: $description"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $description (expected '$expected', got '$actual')"
    fail=1
  fi
}

rc=0; out=""; trace=""
run_role() { # <name> [VAR=value ...]
  local name="$1"; shift
  out="$scratch/${name}.out"
  trace="$scratch/${name}.trace"
  : > "$trace"
  set +e
  env -i PATH="$fake_bin:/usr/bin:/bin" \
    HOME="$HOME" \
    FAKE_AWS_TRACE="$trace" \
    INSTANCE_ID="$INSTANCE" \
    AWS_REGION="us-east-1" \
    "$@" \
    bash "$ROLE_SCRIPT" >"$out" 2>&1
  rc=$?
  set -e
}

# ---- Happy path -----------------------------------------------------------------------------

run_role "clean"
assert_eq "a clean run succeeds" "$rc" "0"
assert_trace_contains "it creates the role with the ec2 trust policy" "$trace" "iam create-role --role-name topaz-render-instance-role"
assert_trace_contains "it attaches the PutMetricData inline policy" "$trace" "--policy-name topaz-putmetric"
assert_trace_contains "it creates the instance profile" "$trace" "iam create-instance-profile --instance-profile-name topaz-render-instance-profile"
assert_trace_contains "it puts the role into the profile" "$trace" "iam add-role-to-instance-profile --instance-profile-name topaz-render-instance-profile --role-name topaz-render-instance-role"
assert_trace_contains "it associates the profile with THIS instance" \
  "$trace" "ec2 associate-iam-instance-profile --region us-east-1 --instance-id ${INSTANCE} --iam-instance-profile Name=topaz-render-instance-profile"
assert_trace_contains "a clean run reaches the final Done line" "$out" "can now publish"
# Named as the full put-role-policy call: the default path DOES mention
# topaz-ec2-stop, in the read-only get-role-policy probe that checks whether an
# earlier INCLUDE_EC2_STOP=1 run left the grant live. A bare "topaz-ec2-stop"
# assertion would be satisfied by that probe.
assert_trace_not_contains "without INCLUDE_EC2_STOP it never GRANTS ec2:StopInstances" \
  "$trace" "put-role-policy --role-name topaz-render-instance-role --policy-name topaz-ec2-stop"
assert_trace_contains "without INCLUDE_EC2_STOP it still probes whether an earlier run left the grant live" \
  "$trace" "iam get-role-policy --role-name topaz-render-instance-role --policy-name topaz-ec2-stop"
assert_trace_not_contains "without INCLUDE_EC2_STOP it never tags the instance AutoStopEligible" "$trace" "ec2 create-tags"

# A previously-granted stop policy must be reported, never silently revoked.
run_role "stop-policy-lingering" FAKE_EC2_STOP_POLICY_PRESENT=0
assert_eq "a run without the flag, over a live earlier grant, still succeeds" "$rc" "0"
assert_trace_contains "a lingering ec2:stop grant is reported to the operator" "$out" "remains in force"
assert_trace_contains "the report includes the exact revoke commands" "$out" "iam delete-role-policy --role-name topaz-render-instance-role --policy-name topaz-ec2-stop"
assert_trace_not_contains "a lingering grant is never auto-revoked behind the operator's back" \
  "$trace" "iam delete-role-policy"

run_role "with-stop" INCLUDE_EC2_STOP=1
assert_eq "INCLUDE_EC2_STOP=1 succeeds" "$rc" "0"
assert_trace_contains "INCLUDE_EC2_STOP=1 attaches the tag-scoped stop policy" "$trace" "--policy-name topaz-ec2-stop"
assert_trace_contains "INCLUDE_EC2_STOP=1 also applies the tag that policy is conditioned on" \
  "$trace" "ec2 create-tags --region us-east-1 --resources ${INSTANCE} --tags Key=AutoStopEligible,Value=true"
assert_trace_contains "INCLUDE_EC2_STOP=1 states the fleet-wide reach of the tag condition" \
  "$out" "any tagged instance's role can stop"

# ---- Reusing an existing role: the trust policy must be verified, not assumed ----------------

run_role "role-exists" FAKE_ROLE_EXISTS=1
assert_eq "reusing a role that still trusts ec2.amazonaws.com succeeds" "$rc" "0"
assert_trace_contains "the reused role's trust policy is actually read back" \
  "$trace" "iam get-role --role-name topaz-render-instance-role"
assert_trace_contains "the confirmed trust is reported, not silently assumed" "$out" "still allows ec2.amazonaws.com"

run_role "role-exists-bad-trust" FAKE_ROLE_EXISTS=1 \
  FAKE_ROLE_TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
assert_eq "a reused role that no longer trusts ec2.amazonaws.com aborts" "$rc" "1"
assert_trace_contains "the abort names the real problem (EC2 cannot assume the role)" "$out" "does not trust ec2.amazonaws.com"
assert_trace_contains "the abort prints the exact remediation command" "$out" "update-assume-role-policy"
assert_trace_not_contains "the abort never silently overwrites the existing trust document" \
  "$trace" "iam update-assume-role-policy"
assert_trace_not_contains "the abort happens before the instance profile is touched" "$trace" "create-instance-profile"

# ---- [4/6] reconcile: the instance profile already holds a role ------------------------------

run_role "profile-has-our-role" FAKE_PROFILE_EXISTS=1 FAKE_PROFILE_HAS_ROLE=1 FAKE_ATTACHED_ROLE=topaz-render-instance-role
assert_eq "an instance profile already holding OUR role continues" "$rc" "0"
assert_trace_contains "the already-attached role is confirmed by lookup, not assumed" \
  "$trace" "iam get-instance-profile --instance-profile-name topaz-render-instance-profile"
assert_trace_contains "confirming the expected role lets the run reach [6/6]" "$out" "[6/6] Associating"

run_role "profile-has-other-role" FAKE_PROFILE_EXISTS=1 FAKE_PROFILE_HAS_ROLE=1 FAKE_ATTACHED_ROLE=some-other-role
assert_eq "an instance profile holding a DIFFERENT role aborts" "$rc" "1"
assert_trace_contains "the abort says which role is actually attached" "$out" "already has a DIFFERENT role attached: some-other-role"
assert_trace_contains "the abort prints the remove/add remediation pair" "$out" "iam remove-role-from-instance-profile"
assert_trace_not_contains "the abort never reaches the association step" "$out" "[6/6] Associating"
assert_trace_not_contains "the abort never claims success" "$out" "can now publish"
assert_trace_not_contains "the abort issues no associate call" "$trace" "ec2 associate-iam-instance-profile"

# ---- [6/6] reconcile: the instance already wears an instance profile -------------------------

run_role "assoc-ours" FAKE_ASSOCIATE_RESULT=already FAKE_ASSOCIATED_PROFILE=topaz-render-instance-profile
assert_eq "an instance already associated with OUR profile succeeds" "$rc" "0"
assert_trace_contains "the existing association is verified by name, not accepted blindly" \
  "$trace" "ec2 describe-iam-instance-profile-associations"
assert_trace_contains "confirming the expected profile reaches the final Done line" "$out" "can now publish"

run_role "assoc-foreign" FAKE_ASSOCIATE_RESULT=already FAKE_ASSOCIATED_PROFILE=someone-elses-profile
assert_eq "an instance associated with a DIFFERENT profile aborts" "$rc" "1"
assert_trace_contains "the abort names the foreign profile" "$out" "DIFFERENT IAM instance profile: someone-elses-profile"
assert_trace_contains "the abort includes the AssociationId needed to fix it" "$out" "iip-assoc-0abcdef1234567890"
assert_trace_contains "the abort prints the replace-association remediation" "$out" "replace-iam-instance-profile-association"
assert_trace_not_contains "the abort never claims success" "$out" "can now publish"

# ---- IAM propagation lag must read as "wait and re-run", not as a typo -----------------------

run_role "assoc-propagation" FAKE_ASSOCIATE_RESULT=propagation
assert_eq "an unpropagated instance profile still aborts (it IS a failure)" "$rc" "1"
assert_trace_contains "the raw AWS error is still shown" "$out" "Invalid IAM Instance Profile name"
assert_trace_contains "the operator is told this is eventual consistency and to re-run" "$out" "wait a minute and re-run"
assert_trace_not_contains "propagation lag is never misreported as a DIFFERENT profile" \
  "$out" "DIFFERENT IAM instance profile"

run_role "assoc-denied" FAKE_ASSOCIATE_RESULT=denied
assert_eq "an unrelated association failure still aborts loudly" "$rc" "1"
assert_trace_contains "the unrelated failure's own error is shown" "$out" "UnauthorizedOperation"
assert_trace_not_contains "the propagation hint is NOT glued onto an unrelated failure" \
  "$out" "wait a minute and re-run"

# ---- A malformed INSTANCE_ID must fail before any AWS call -----------------------------------

bad_id_trace="$scratch/bad-id.trace"
: > "$bad_id_trace"
set +e
env -i PATH="$fake_bin:/usr/bin:/bin" HOME="$HOME" \
  FAKE_AWS_TRACE="$bad_id_trace" \
  INSTANCE_ID="i-nope" AWS_REGION="us-east-1" INCLUDE_EC2_STOP=1 \
  bash "$ROLE_SCRIPT" >"$scratch/bad-id.out" 2>&1
bad_id_rc=$?
set -e
assert_eq "a malformed INSTANCE_ID exits 1" "$bad_id_rc" "1"
assert_eq "a malformed INSTANCE_ID makes NO AWS call (nothing tagged, nothing associated)" \
  "$(wc -l < "$bad_id_trace" | tr -d ' ')" "0"

# ---- The METRIC_NAMESPACE render, and the guard that stops it drifting silently --------------
# The script substitutes the literal "TopazRender/GPU" out of the checked-in
# policy. If that literal ever drifts from the file's actual contents the
# substitution becomes a no-op and a policy scoped to the OLD namespace ships
# while the output claims the new one -- AccessDenied on every PutMetricData
# call, and only a [WARN] from 00-verify-prerequisites.sh's [4/6].

assert_trace_contains "the checked-in policy still carries the exact literal 02 substitutes" \
  "$PUTMETRIC_POLICY" '"cloudwatch:namespace": "TopazRender/GPU"'

# Same substitution 02 performs, applied here to prove the rendered result is
# still valid JSON-shaped policy text carrying the custom namespace.
#
# The replacement is held in a VARIABLE, exactly as 02 and 05 both do it, and
# that is load-bearing rather than stylistic: only the PATTERN half of
# ${var//pattern/replacement} needs its '/' backslash-escaped, and bash 3.2
# (macOS's /bin/bash, which these operator-run scripts must work under) does
# NOT strip a backslash written in the REPLACEMENT half -- it emits a literal
# "TopazRender\/Prod" where bash 5 emits "TopazRender/Prod". Writing the
# replacement inline with an escaped slash therefore silently ships a corrupt
# namespace on exactly the workstation this project runs from.
custom_namespace="TopazRender/Prod"
rendered="$(cat "$PUTMETRIC_POLICY")"
rendered="${rendered//TopazRender\/GPU/$custom_namespace}"
printf '%s' "$rendered" > "$scratch/rendered-policy.json"
assert_trace_contains "rendering with a custom namespace produces that namespace" \
  "$scratch/rendered-policy.json" '"cloudwatch:namespace": "TopazRender/Prod"'
assert_trace_not_contains "rendering with a custom namespace leaves no trace of the default" \
  "$scratch/rendered-policy.json" "TopazRender/GPU"
assert_trace_contains "rendering does not disturb the PutMetricData action" \
  "$scratch/rendered-policy.json" '"Action": "cloudwatch:PutMetricData"'
if command -v python3 >/dev/null 2>&1; then
  if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$scratch/rendered-policy.json" 2>/dev/null; then
    echo "PASS: the rendered policy is still valid JSON"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: the rendered policy is not valid JSON"
    fail=1
  fi
else
  echo "SKIP: python3 unavailable; not parsing the rendered policy as JSON"
fi

run_role "custom-namespace" METRIC_NAMESPACE=TopazRender/Prod
assert_eq "a custom METRIC_NAMESPACE run succeeds" "$rc" "0"
assert_trace_contains "the custom namespace reaches the operator-facing output" "$out" "namespace=TopazRender/Prod"
assert_trace_contains "the final line names the custom namespace" "$out" "into the TopazRender/Prod namespace"

echo
if [[ "$fail" -ne 0 ]]; then
  echo "create_iam_role tests: FAILED"
  exit 1
fi
echo "create_iam_role tests: all $pass_count assertions passed"
