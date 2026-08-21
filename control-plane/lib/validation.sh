# shellcheck shell=bash
#
# control-plane/lib/validation.sh
#
# Pure, no-AWS-call validation predicates shared by control-plane/*.sh. Kept
# separate from aws-idempotent.sh (which wraps AWS CLI calls) so this whole
# file can be exercised by tests/test_control_plane_validation.sh without any
# AWS credentials or network access -- these are the only parts of the
# control plane that CAN be tested end-to-end outside a real AWS account.

# is_valid_instance_id <v> — true iff <v> looks like an EC2 instance id: the
# 8-hex-digit legacy form (i-1234abcd) or the 17-hex-digit current form
# (i-0123456789abcdef0). AWS has only ever issued those two widths, and always
# lowercase hex.
#
# WHY every script that consumes INSTANCE_ID calls this: docs/11's runbook
# tells the operator to `export INSTANCE_ID=...` into their shell, so a stale
# export or a mistyped id survives across sessions and across scripts. The
# scripts here TAG instances, ASSOCIATE instance profiles onto them, and arm
# schedules that call ec2:StopInstances against them -- pointing any of that at
# the wrong box is the "wrong instance stop" class this project's safety bias
# exists to prevent. A shape check cannot catch a transposition that still
# names a real instance (04's pre-flight identity echo covers that half), but
# it does make a malformed id fail before the FIRST mutating AWS call instead
# of half-way through a multi-step deployment.
is_valid_instance_id() {
  [[ "$1" =~ ^i-([0-9a-f]{8}|[0-9a-f]{17})$ ]]
}

# is_valid_idle_minutes <v> — true iff <v> is a positive integer with no
# leading zeros (03-create-idle-alarm.sh's IDLE_MINUTES rule).
#
# The regex rejects zero and leading-zero forms ("08") outright, so the value
# is never fed to a bash arithmetic context (which would parse "08"/"09" as
# octal).
is_valid_idle_minutes() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

# is_valid_max_lifetime_hours <v> — true iff <v> is a positive, finite number
# (04-deploy-max-lifetime-lambda.sh's MAX_LIFETIME_HOURS rule). Mirrors
# handler.py's own validation so a bad value fails LOUDLY at deploy time
# instead of deploying "successfully" while the Lambda silently substitutes
# its default 12h ceiling -- the deploy output would otherwise lie about the
# effective cap.
#
# The h < 1e300 upper bound closes a real gap in the original digits-only
# regex + `h > 0` check: a numeric string long enough to overflow IEEE-754
# (e.g. a few hundred 9s) still matches the regex, and awk parses it as
# +Infinity -- and Infinity > 0 is true, so the old check accepted it. That is
# exactly the silent-divergence handler.py's own math.isfinite() guard exists
# to catch (an accepted-but-nonsensical ceiling silently replaced by the
# default at runtime), except here it would have happened at DEPLOY time
# while reporting success. 1e300 sits comfortably below a double's ~1.8e308
# max and handler.py's own isfinite() cutoff, so it rejects both genuine
# overflow-to-infinity and any finite-but-absurd value well before either.
is_valid_max_lifetime_hours() {
  [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]] && awk -v h="$1" 'BEGIN { exit !(h > 0 && h < 1e300) }'
}

# is_shutdown_behavior_confirmed <v> — true only for exactly "stop"
# (01-set-shutdown-behavior.sh's post-write readback check: anything else,
# including a near-miss like "Stop", must fail loudly rather than assume the
# attribute took).
is_shutdown_behavior_confirmed() {
  [[ "$1" == "stop" ]]
}

# profile_names_match <actual> <expected> — plain string-equality helper
# backing 02-create-iam-role.sh's reconciliation branches: the
# already-associated-instance-profile check, and the
# already-attached-role-on-the-instance-profile check. Named so each call
# site reads as "does what AWS actually reports match what we expect" rather
# than a bare "==".
profile_names_match() {
  [[ "$1" == "$2" ]]
}
