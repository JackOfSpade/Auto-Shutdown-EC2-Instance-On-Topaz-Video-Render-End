#!/usr/bin/env bash
#
# 03-create-idle-alarm.sh
#
# .DECISION -- READ THIS FIRST (recorded 2026-07-28, operator-directed)
#   THE OPERATOR HAS DECIDED AGAINST ANY IDLE-BASED AUTO-STOP FOR THIS PROJECT.
#   The only sanctioned auto-stop is:
#
#       watchdog detects render-queue completion
#         -> Stop-Sequence.ps1 verifies the Google Drive upload
#         -> ec2:StopInstances
#
#   Why: an idle alarm -- on ANY signal, GPU or RenderActive -- cannot tell
#   "the box was abandoned" apart from "the operator is still setting up" or
#   "the queue is between two items". That is not a hypothetical: on
#   2026-07-27 the then-current (GPU-keyed) build of exactly this alarm came
#   within five minutes of stopping a render that was, by every other
#   measure, healthy and actively progressing -- see
#   docs/15-third-end-to-end-run.md Sec K. Re-keying the signal
#   (GPUUtilization -> RenderActive, see the history below) narrowed that
#   hazard but structurally cannot remove it: no wall-clock/presence signal
#   can distinguish a real lull from real abandonment. The operator has
#   already DELETED the CloudWatch alarm this script previously created for
#   this instance. See docs/09-appendix-b-boundaries.md for the accepted cost
#   of running with no idle-based safety net at all, and
#   docs/06-phase4-safety-net.md for the full design discussion (kept current
#   as a reference, not as a statement that this alarm is armed here).
#
#   THIS SCRIPT IS THEREFORE OPT-IN AND OFF BY DEFAULT FOR THIS PROJECT.
#   Setting INSTANCE_ID/AWS_REGION alone does nothing -- you must also pass
#   ENABLE_IDLE_ALARM=1 to actually create/update the alarm. This is not a
#   deletion of the capability: a DIFFERENT deployment (e.g. a box with a GPU
#   not shared by a remote-display session, and an operator who genuinely
#   wants a wall-clock idle cap) may still have good reason to arm it. It is
#   simply no longer the default, or part of this project's own deployment
#   sequence -- see README.md's Quickstart.
#
#   The RenderActive METRIC itself is unaffected and keeps publishing --
#   Push-GpuMetric.ps1 still writes it every minute, and it remains useful,
#   passively-observed telemetry (e.g. for a human glancing at CloudWatch, or
#   for a future consumer that isn't a blind stop-the-box alarm). What changed
#   is that nothing here ACTS on it by default any more.
#
#   To remove an alarm this script previously created (idempotent -- deleting
#   an alarm name that does not exist is not an error):
#
#       INSTANCE_ID=i-XXXXXXXXXXXXXXXXX AWS_REGION=<region> TEARDOWN=1 \
#         ./03-create-idle-alarm.sh
#
# .SYNOPSIS
#   Create the out-of-band idle-stop CloudWatch alarm. OPT-IN -- see .DECISION
#   above. Also supports TEARDOWN=1 to remove it.
#
# .DESCRIPTION
#   When explicitly enabled (ENABLE_IDLE_ALARM=1), this creates a SAFETY NET,
#   not the primary stop path. The primary stop is the on-box watchdog that
#   detects a finished, uploaded Topaz render and shuts the guest down. This
#   alarm, if armed, exists only to catch a truly dead / hung / idle box that
#   the watchdog failed to stop (crashed watchdog, orphaned instance, etc.) --
#   see the .DECISION block above for why this project runs with it OFF.
#
#   It fires on a CUSTOM metric published by the on-box metric task, and uses
#   the built-in EC2 alarm action to stop the instance. The window is
#   deliberately LONG and conservative:
#       period 60s  x  evaluation-periods IDLE_MINUTES (default 30)  =  IDLE_MINUTES minutes
#   of SUSTAINED idle before it acts.
#
#   WHICH METRIC -- AND WHY IT IS NO LONGER THE GPU (changed 2026-07-28):
#
#   IDLE_SIGNAL=render (DEFAULT) watches TopazRender/GPU : RenderActive, a 1/0
#   published every minute meaning "at least one encoder worker process is
#   alive". It breaches after IDLE_MINUTES of sustained 0.
#
#   IDLE_SIGNAL=gpu is the LEGACY behaviour: sub-5% on GPUUtilization. It is
#   kept only for boxes whose GPU is not shared with a remote-display encoder.
#   This script used to claim that a sub-5% GPU window "can never false-stop an
#   active render (Topaz GPU work spikes well above 5% while encoding)". THAT
#   CLAIM WAS MEASURED TO BE FALSE on 2026-07-27: a confirmed-healthy 4K render
#   held GPUUtilization under 5% for 25 CONSECUTIVE one-minute samples, mostly
#   at a literal 0%, coming within five minutes of breaching a 30-minute window
#   WHILE RENDERING (docs/15-third-end-to-end-run.md). The same metric is also
#   wrong in the other direction: a connected Amazon DCV session encodes the
#   remote display on the same GPU and holds it at 14-58% with nothing rendering
#   at all, so the alarm could never fire while anyone was connected
#   (docs/12-empirical-findings.md). Wrong in both directions is not a safety
#   net. RenderActive is the same class of signal the watchdog itself trusts for
#   exactly these reasons (its CompletionSignal is 'WorkerOnly', not GPU-based).
#   Re-keying the signal narrowed the false-stop hazard; it did not remove the
#   deeper problem recorded in .DECISION above, which is why this alarm is now
#   off by default regardless of which signal it would watch.
#
#   NOTE THE BEHAVIOUR CHANGE THIS BRINGS, IF YOU DO ENABLE IT. Because DCV load
#   no longer masks an idle box, this alarm can now genuinely fire -- including
#   during a long pre-render setup where the operator is connected but has not
#   clicked Export. That is the point (an abandoned box finally gets stopped),
#   but it means the pause/resume commands printed at the end of this script
#   stop being theoretical. Raise IDLE_MINUTES, or disable the alarm actions,
#   before a long setup session.
#
#   treat-missing-data notBreaching: if the metric stops arriving entirely (e.g.
#   the metric task stopped publishing, or its worker query is failing) we do
#   NOT treat that as "idle" and stop the box on missing data alone -- missing
#   data is ambiguous, so we stay OK.
#
#   #############################################################################
#   # DO NOT key this alarm on CPUUtilization.                                  #
#   # CPU is BLIND to GPU load. A Topaz render can peg the GPU while CPU sits   #
#   # near idle, so a CPU-based alarm would FALSE-STOP a real, active render.   #
#   # The whole point of a custom metric is to observe the actual work.         #
#   #############################################################################
#
# .NOTES
#   Run from an admin workstation with AWS CLI v2 configured.
#   Requires env vars: INSTANCE_ID, AWS_REGION.
#   Required to actually create/update anything: ENABLE_IDLE_ALARM=1 (see
#   .DECISION above) -- without it this script explains why it is refusing and
#   exits 1 without calling AWS at all.
#   Optional env var:  TEARDOWN=1 -- delete this instance's alarm instead of
#   creating one. Idempotent: deleting a non-existent alarm name is not an
#   error. Does not require ENABLE_IDLE_ALARM.
#   Optional env var:  IDLE_MINUTES (default 30) -- sustained-idle window, in
#   whole minutes, before the alarm stops the instance. Must be a positive
#   integer.
#   Optional env var:  IDLE_SIGNAL (default "render") -- "render" keys the alarm
#   on the RenderActive 1/0 metric, "gpu" restores the legacy sub-5%
#   GPUUtilization behaviour. See the discussion above before choosing "gpu".
#   Optional env vars: METRIC_NAMESPACE (default TopazRender/GPU) and
#   METRIC_NAME (defaults to RenderActive or GPUUtilization per IDLE_SIGNAL)
#   -- override which custom metric the alarm watches, mirroring
#   in-guest/Config.ps1's editable MetricNamespace / RenderActiveMetricName /
#   MetricName. Only change these together with the watchdog's own config, or
#   the alarm ends up watching a metric nothing publishes.
#   The arn:aws:automate:<region>:ec2:stop action requires no extra IAM role.
#
set -euo pipefail

# Resolve the directory this script lives in so lib/*.sh sourcing works
# regardless of the caller's current working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/validation.sh
source "${SCRIPT_DIR}/lib/validation.sh"

usage() {
  cat >&2 <<'EOF'
Usage: INSTANCE_ID=i-XXXXXXXXXXXXXXXXX AWS_REGION=<region> ENABLE_IDLE_ALARM=1 \
         [IDLE_MINUTES=30] ./03-create-idle-alarm.sh

  or, to remove a previously-created alarm:

       INSTANCE_ID=i-XXXXXXXXXXXXXXXXX AWS_REGION=<region> TEARDOWN=1 \
         ./03-create-idle-alarm.sh

THIS ALARM IS OPT-IN AND OFF BY DEFAULT FOR THIS PROJECT (decided 2026-07-28
-- see the .DECISION block in this script's own header). The only sanctioned
auto-stop here is watchdog-completion -> verified upload -> ec2:StopInstances.
ENABLE_IDLE_ALARM=1 is required to create or update anything.

Required environment variables:
  INSTANCE_ID   The target EC2 instance id (e.g. i-XXXXXXXXXXXXXXXXX)
  AWS_REGION    The AWS region the instance lives in (e.g. <region>)

Required to actually create/update the alarm (deliberately not a default):
  ENABLE_IDLE_ALARM=1   Explicit opt-in. Without this, the script explains why
                        it is refusing and exits 1 -- no AWS call is made.

Optional environment variables:
  TEARDOWN          Set to 1 to DELETE this instance's alarm instead of
                    creating one, then exit. Idempotent -- deleting a
                    non-existent alarm name is not an error. Takes priority
                    over everything below and does not require
                    ENABLE_IDLE_ALARM.
  IDLE_SIGNAL       Which signal means "idle" (default render):
                      render - no encoder worker process alive (RenderActive=0).
                               GPU load is known to be wrong in both
                               directions on a DCV box; see the header.
                      gpu    - legacy sustained sub-5% GPUUtilization.
  IDLE_MINUTES      Sustained-idle window, in whole minutes, before the alarm
                    stops the instance (default 30). Must be a positive
                    integer. Raise this if pre-render setup (e.g. uploading
                    source files over a slow link) can leave the box idle for a
                    long stretch before Export is clicked.
  METRIC_NAMESPACE  CloudWatch namespace of the custom metric to watch
                    (default TopazRender/GPU). Mirrors in-guest/Config.ps1's
                    MetricNamespace.
  METRIC_NAME       CloudWatch metric name within that namespace (defaults to
                    RenderActive or GPUUtilization according to IDLE_SIGNAL).
                    Mirrors in-guest/Config.ps1's RenderActiveMetricName /
                    MetricName.
EOF
  exit 1
}

[[ -n "${INSTANCE_ID:-}" ]] || { echo "ERROR: INSTANCE_ID is not set." >&2; usage; }
[[ -n "${AWS_REGION:-}"  ]] || { echo "ERROR: AWS_REGION is not set."  >&2; usage; }
# Shape-check INSTANCE_ID before anything else: it is baked into the alarm NAME
# and into the alarm's InstanceId dimension, so a stale `export INSTANCE_ID=`
# would arm (or tear down) a stop action keyed to the wrong box. See
# lib/validation.sh's is_valid_instance_id.
is_valid_instance_id "$INSTANCE_ID" || {
  echo "ERROR: INSTANCE_ID='${INSTANCE_ID}' is not a valid EC2 instance id (expected i- followed by 8 or 17 hex digits)." >&2
  usage
}

# WHY per-instance name: put-metric-alarm OVERWRITES any existing alarm that
# has the same --alarm-name. A hardcoded shared name meant provisioning a
# SECOND instance silently repointed (and thereby disabled) the first box's
# safety net. Keying the name on INSTANCE_ID gives every instance its own
# alarm. Computed unconditionally (both the teardown and create paths need it).
#
# WHY the name still says "gpu" when the DEFAULT signal is RenderActive: the
# name predates the 2026-07-28 re-key from GPUUtilization to RenderActive and
# is kept deliberately, so alarms created by earlier runs and
# 00-verify-prerequisites.sh's own ALARM_NAME literal keep matching. Renaming
# it would orphan existing alarms and silently point 00's [5/6] check at a name
# nothing creates. The "gpu" in the name therefore does NOT mean the alarm is
# GPU-keyed -- IDLE_SIGNAL (default "render") decides that, and a post-mortem
# reading this name off CloudTrail must check IDLE_SIGNAL/the alarm's
# MetricName rather than assume a GPU threshold stopped the box.
ALARM_NAME="topaz-gpu-idle-autostop-${INSTANCE_ID}"
# The pre-2026-07-28 shared (non-per-instance) name. Only ever probed and
# reported on, never blind-deleted: its InstanceId dimension may point at a
# DIFFERENT box in this account.
LEGACY_ALARM_NAME="topaz-gpu-idle-autostop"

# ---------------------------------------------------------------------------
# TEARDOWN=1: remove this instance's alarm and exit. Always allowed -- tearing
# an alarm down is never the action the 2026-07-28 decision argues against,
# and it must work even if the alarm was never created (idempotent), so a
# repeated teardown (e.g. run from a runbook/checklist every time) never
# fails. No ENABLE_IDLE_ALARM gate applies here.
# ---------------------------------------------------------------------------
TEARDOWN="${TEARDOWN:-0}"
if [[ "$TEARDOWN" == "1" ]]; then
  echo "==> TEARDOWN=1: deleting idle-stop alarm '${ALARM_NAME}' (if it exists)"
  # WHY the legacy name is probed here and not only on the create path: the
  # create path already warns about the pre-rename shared alarm, but TEARDOWN
  # is the command an operator runs precisely to guarantee that NOTHING can
  # idle-stop this box. Saying "Done" while a legacy 'topaz-gpu-idle-autostop'
  # still carries dimension InstanceId=<this box> with actions enabled would
  # leave exactly the sub-5%-GPU stop action that came within five minutes of
  # false-stopping a healthy render on 2026-07-27 (docs/15) armed and
  # unmentioned. Probe first, so this box's own orphan can go in the SAME
  # delete-alarms call.
  #
  # shellcheck disable=SC2016 # single-quoted on purpose: this is JMESPath --
  # the backticked `InstanceId` is a --query string literal, not a bash command
  # substitution, so it must NOT be double-quoted/interpolated. Same reasoning
  # as 05-grant-audit-reads.sh's own JMESPath disable.
  LEGACY_LINE="$(aws cloudwatch describe-alarms \
    --region "$AWS_REGION" \
    --alarm-names "$LEGACY_ALARM_NAME" \
    --query 'MetricAlarms[0].[Dimensions[?Name==`InstanceId`].Value | [0], ActionsEnabled]' \
    --output text 2>/dev/null || true)"
  LEGACY_INSTANCE="$(printf '%s' "$LEGACY_LINE" | cut -f1)"
  LEGACY_ACTIONS="$(printf '%s' "$LEGACY_LINE" | cut -f2)"

  DELETE_NAMES=("$ALARM_NAME")
  if [[ "$LEGACY_INSTANCE" == "$INSTANCE_ID" ]]; then
    echo "    NOTE: the pre-2026-07-28 shared-name alarm '${LEGACY_ALARM_NAME}' exists and"
    echo "          targets THIS instance (actions enabled: ${LEGACY_ACTIONS:-unknown}). It is"
    echo "          unambiguously this box's orphan, so it is deleted in the same call."
    DELETE_NAMES+=("$LEGACY_ALARM_NAME")
  elif [[ -n "$LEGACY_INSTANCE" && "$LEGACY_INSTANCE" != "None" ]]; then
    echo "    WARNING: the pre-2026-07-28 shared-name alarm '${LEGACY_ALARM_NAME}' also exists,"
    echo "             but its InstanceId dimension is '${LEGACY_INSTANCE}', NOT ${INSTANCE_ID}"
    echo "             (actions enabled: ${LEGACY_ACTIONS:-unknown}). It is NOT deleted here --"
    echo "             it may be another box's live safety net. If it is not, remove it with:"
    echo "               aws cloudwatch delete-alarms --region ${AWS_REGION} --alarm-names ${LEGACY_ALARM_NAME}"
  fi

  echo "    aws cloudwatch delete-alarms --region ${AWS_REGION} --alarm-names ${DELETE_NAMES[*]}"
  # delete-alarms is idempotent by design -- CloudWatch does not error when
  # asked to delete an alarm name that does not exist, so no non-existence
  # check/branch is needed here.
  aws cloudwatch delete-alarms --region "$AWS_REGION" --alarm-names "${DELETE_NAMES[@]}"
  echo "==> Done. These alarm name(s) no longer exist: ${DELETE_NAMES[*]}"
  echo "    (delete-alarms is idempotent -- each was either just removed, or never"
  echo "    existed in the first place.)"
  exit 0
fi

# ---------------------------------------------------------------------------
# OPT-IN GATE (2026-07-28 decision -- see .DECISION above). Refuse to create
# or update anything unless the caller explicitly opts in. This is checked
# BEFORE any other validation/AWS call so an operator who runs this script out
# of habit (e.g. following stale muscle memory from before 2026-07-28) gets a
# clear refusal instead of a silently re-armed idle stop.
# ---------------------------------------------------------------------------
ENABLE_IDLE_ALARM="${ENABLE_IDLE_ALARM:-0}"
if [[ "$ENABLE_IDLE_ALARM" != "1" ]]; then
  cat >&2 <<EOF
ERROR: refusing to create/update '${ALARM_NAME}'.

This project's operator decided, on 2026-07-28, against any idle-based
auto-stop: an idle alarm cannot distinguish "the box was abandoned" from "the
operator is mid-setup" or "the queue is between two items", and the
GPU-keyed version of this exact alarm had already come within five minutes of
stopping a live, healthy render on 2026-07-27 (docs/15-third-end-to-end-run.md
Sec K). The operator has already deleted the alarm this script previously
created for this instance. The only sanctioned auto-stop for this project is:

    watchdog detects render-queue completion
      -> Stop-Sequence.ps1 verifies the Google Drive upload
      -> ec2:StopInstances

This script and capability are NOT removed -- they remain valid for a
different deployment that genuinely wants a wall-clock idle cap. If that is
what you are doing, and you understand this is a deliberate departure from
this project's own current decision, re-run with ENABLE_IDLE_ALARM=1.

See docs/06-phase4-safety-net.md and docs/09-appendix-b-boundaries.md.
EOF
  exit 1
fi

IDLE_MINUTES="${IDLE_MINUTES:-30}"
if ! is_valid_idle_minutes "$IDLE_MINUTES"; then
  echo "ERROR: IDLE_MINUTES must be a positive integer with no leading zeros (got '${IDLE_MINUTES}')." >&2
  usage
fi

METRIC_NAMESPACE="${METRIC_NAMESPACE:-TopazRender/GPU}"

# The signal choice sets STATISTIC, THRESHOLD and wording together, and those
# three are NOT overridable at all -- a mismatched set is silently broken rather
# than loudly broken. The specific hazard: --statistic Average --threshold 5
# against a 1/0 metric breaches on EVERY evaluation period (an average of a 1/0
# series is always <= 1, hence always < 5), so the alarm would stop the box
# unconditionally IDLE_MINUTES after creation -- including mid-render.
#
# METRIC_NAME stays overridable, but only to RENAME the chosen signal's own
# metric (an operator who edited RenderActiveMetricName/MetricName in
# in-guest/Config.ps1 must be able to point the alarm at the new name). Pointing
# it at the OTHER signal's metric is the dangerous pairing above, so that exact
# combination is rejected below rather than silently provisioned.
IDLE_SIGNAL="${IDLE_SIGNAL:-render}"

# Canonical per-signal metric names, needed both as defaults and for the
# cross-signal mismatch check.
RENDER_METRIC_DEFAULT='RenderActive'
GPU_METRIC_DEFAULT='GPUUtilization'

case "$IDLE_SIGNAL" in
  render)
    METRIC_NAME="${METRIC_NAME:-$RENDER_METRIC_DEFAULT}"
    if [[ "$METRIC_NAME" == "$GPU_METRIC_DEFAULT" ]]; then
      echo "ERROR: IDLE_SIGNAL=render with METRIC_NAME=${GPU_METRIC_DEFAULT} is a signal/metric mismatch." >&2
      echo "       The render signal evaluates 'Maximum < 1', which against a PERCENTAGE metric" >&2
      echo "       reads almost every real render minute as idle -- the exact false-idle bug this" >&2
      echo "       signal exists to remove (a healthy render measured 0% for 25 consecutive" >&2
      echo "       minutes on 2026-07-27; see docs/15-third-end-to-end-run.md)." >&2
      echo "       Use IDLE_SIGNAL=gpu to alarm on ${GPU_METRIC_DEFAULT}, or leave METRIC_NAME unset." >&2
      exit 1
    fi
    # Maximum, not Average: the value is 1/0 and pushes are ~1/min but not
    # exactly on the minute boundary, so two can land in one 60s period. An
    # Average of 0.5 would read as "below 1" and count an actively-rendering
    # minute as idle. Maximum takes the safe direction -- if ANY sample in the
    # period saw a worker, the period is not idle.
    STATISTIC='Maximum'
    THRESHOLD=1
    WINDOW_TEXT="${IDLE_MINUTES} min sustained RenderActive=0 (no encoder worker alive)"
    DESC_TEXT="OPT-IN safety net (see this script's .DECISION header -- OFF by default for this project): stop the Topaz render box after ${IDLE_MINUTES} min with no encoder worker process alive. Keyed on the custom RenderActive metric -- never on CPU, and deliberately not on GPU (measured wrong in both directions on this box, see docs/15)."
    ;;
  gpu)
    METRIC_NAME="${METRIC_NAME:-$GPU_METRIC_DEFAULT}"
    if [[ "$METRIC_NAME" == "$RENDER_METRIC_DEFAULT" ]]; then
      echo "ERROR: IDLE_SIGNAL=gpu with METRIC_NAME=${RENDER_METRIC_DEFAULT} is a signal/metric mismatch." >&2
      echo "       The gpu signal evaluates 'Average < 5'. The average of a 1/0 metric is always" >&2
      echo "       <= 1, so that condition is true on EVERY evaluation period: the alarm would" >&2
      echo "       stop this instance unconditionally ${IDLE_MINUTES} min after creation, mid-render" >&2
      echo "       included. Use IDLE_SIGNAL=render to alarm on ${RENDER_METRIC_DEFAULT}." >&2
      exit 1
    fi
    STATISTIC='Average'
    THRESHOLD=5
    WINDOW_TEXT="${IDLE_MINUTES} min sustained < 5% GPU  [LEGACY SIGNAL]"
    DESC_TEXT="OPT-IN safety net (see this script's .DECISION header -- OFF by default for this project): stop the Topaz render box after ${IDLE_MINUTES} min of sustained sub-5% GPU. LEGACY signal -- measured to read under 5% for 25 consecutive minutes during a healthy render (docs/15); prefer IDLE_SIGNAL=render."
    ;;
  *)
    echo "ERROR: IDLE_SIGNAL must be 'render' or 'gpu' (got '${IDLE_SIGNAL}')." >&2
    usage
    ;;
esac

echo "==> ENABLE_IDLE_ALARM=1: creating OPT-IN idle-stop alarm '${ALARM_NAME}'"
echo "    (this alarm is OFF by default for this project -- see the .DECISION"
echo "    block in this script's header for why, and TEARDOWN=1 to remove it)"
echo "    signal  : ${IDLE_SIGNAL}"
echo "    metric  : ${METRIC_NAMESPACE} : ${METRIC_NAME} (custom -- NOT CPUUtilization)"
echo "    window  : period 60s x ${IDLE_MINUTES} evaluation-periods = ${WINDOW_TEXT}"
echo "    rule    : ${STATISTIC} < ${THRESHOLD}"
echo "    action  : arn:aws:automate:${AWS_REGION}:ec2:stop"
echo "    aws cloudwatch put-metric-alarm --region ${AWS_REGION} --alarm-name ${ALARM_NAME} ..."

if [[ "$IDLE_SIGNAL" == 'gpu' ]]; then
  echo ""
  echo "    WARNING: IDLE_SIGNAL=gpu is the legacy signal and is known to be"
  echo "             unreliable in BOTH directions on a box where Amazon DCV"
  echo "             shares the render GPU. It read under 5% for 25 consecutive"
  echo "             minutes during a healthy render on 2026-07-27. Prefer"
  echo "             IDLE_SIGNAL=render unless this box has a dedicated GPU."
  echo ""
fi

# WHY ActionsEnabled is read first and always passed explicitly: PutMetricAlarm
# on an existing name is a FULL REPLACE (that overwrite semantics is what the
# per-instance-name comment above relies on), and the API defaults
# ActionsEnabled to TRUE when the flag is omitted. Omitting it therefore
# silently CANCELS a deliberate pause -- and this script's own closing advice
# is to pause the actions before a long pre-render setup and to re-run with a
# larger IDLE_MINUTES for exactly that situation. An operator doing both would
# have re-armed the stop action on a box sitting at RenderActive=0 during
# setup: the false-stop class the .DECISION block exists for.
#
# The read is guarded with `|| true` because it must never turn a working
# create run into a failure: under `set -euo pipefail`, a denied or throttled
# DescribeAlarms would otherwise abort the script outright, a brand-new failure
# mode. Unreadable/absent -> behave exactly as before (actions enabled).
PRIOR_ACTIONS_ENABLED="$(aws cloudwatch describe-alarms \
  --region "$AWS_REGION" \
  --alarm-names "$ALARM_NAME" \
  --query 'MetricAlarms[0].ActionsEnabled' \
  --output text 2>/dev/null || true)"

ACTIONS_ENABLED_FLAG="--actions-enabled"
if [[ "$PRIOR_ACTIONS_ENABLED" == "False" ]]; then
  ACTIONS_ENABLED_FLAG="--no-actions-enabled"
  echo ""
  echo "    NOTE: '${ALARM_NAME}' already exists with its actions DISABLED (paused)."
  echo "          Preserving that pause -- this update does NOT re-arm the stop action."
  echo "          Resume it deliberately when you are ready:"
  echo "            aws cloudwatch enable-alarm-actions --region ${AWS_REGION} --alarm-names ${ALARM_NAME}"
  echo ""
elif [[ -z "$PRIOR_ACTIONS_ENABLED" ]]; then
  echo ""
  echo "    WARNING: could not read '${ALARM_NAME}''s current ActionsEnabled state"
  echo "             (describe-alarms failed or was denied). Proceeding with actions"
  echo "             ENABLED. If you had deliberately paused this alarm, re-pause it:"
  echo "               aws cloudwatch disable-alarm-actions --region ${AWS_REGION} --alarm-names ${ALARM_NAME}"
  echo ""
fi

aws cloudwatch put-metric-alarm \
  --region "$AWS_REGION" \
  --alarm-name "$ALARM_NAME" \
  --alarm-description "$DESC_TEXT" \
  --namespace "$METRIC_NAMESPACE" \
  --metric-name "$METRIC_NAME" \
  --dimensions Name=InstanceId,Value="$INSTANCE_ID" \
  --statistic "$STATISTIC" \
  --period 60 \
  --evaluation-periods "$IDLE_MINUTES" \
  --threshold "$THRESHOLD" \
  --comparison-operator LessThanThreshold \
  --treat-missing-data notBreaching \
  "$ACTIONS_ENABLED_FLAG" \
  --alarm-actions "arn:aws:automate:${AWS_REGION}:ec2:stop"

echo "==> Done. Alarm '${ALARM_NAME}' created/updated."
echo "    Verify: aws cloudwatch describe-alarms --region ${AWS_REGION} --alarm-names ${ALARM_NAME}"
echo ""
echo "    REMINDER: this alarm is OPT-IN and runs counter to this project's own"
echo "    2026-07-28 decision to rely solely on watchdog-completion ->"
echo "    verified-upload -> ec2:StopInstances (see this script's .DECISION"
echo "    header block, docs/06-phase4-safety-net.md, and"
echo "    docs/09-appendix-b-boundaries.md). Remove it with:"
echo "      INSTANCE_ID=${INSTANCE_ID} AWS_REGION=${AWS_REGION} TEARDOWN=1 ./03-create-idle-alarm.sh"
echo ""
echo "    NOTE: upgrading from an older deployment that used the shared alarm"
echo "          name 'topaz-gpu-idle-autostop'? Delete it -- it no longer"
echo "          tracks this (or any) instance and is an orphaned safety net:"
echo "            aws cloudwatch delete-alarms --region ${AWS_REGION} --alarm-names topaz-gpu-idle-autostop"
echo ""
echo "    THE ALARM ONLY WORKS IF THE METRIC IS BEING PUBLISHED. ${METRIC_NAME} comes"
echo "    from the in-guest metric task (in-guest/Push-GpuMetric.ps1). If you just"
echo "    switched to IDLE_SIGNAL=render, make sure the guest is running a build"
echo "    that publishes RenderActive -- on an older build nothing publishes it,"
echo "    every period is missing data, and notBreaching means this alarm sits OK"
echo "    forever. Confirm with:"
echo "      aws cloudwatch get-metric-statistics --region ${AWS_REGION} \\"
echo "        --namespace ${METRIC_NAMESPACE} --metric-name ${METRIC_NAME} \\"
echo "        --dimensions Name=InstanceId,Value=${INSTANCE_ID} \\"
echo "        --start-time \$(date -u -d '-30 minutes' +%FT%TZ) --end-time \$(date -u +%FT%TZ) \\"
echo "        --period 60 --statistics Maximum"
echo ""
echo "    Pause/resume the alarm's stop action -- pause it before a long"
echo "    pre-render setup (uploading sources, etc.) where the box may sit"
echo "    idle past ${IDLE_MINUTES} min, then resume it right after clicking Export."
echo "    This matters more than it used to: with IDLE_SIGNAL=render a connected"
echo "    DCV session no longer masks an idle box, so the alarm can now actually"
echo "    fire during setup:"
echo "      aws cloudwatch disable-alarm-actions --region ${AWS_REGION} --alarm-names ${ALARM_NAME}"
echo "      aws cloudwatch enable-alarm-actions  --region ${AWS_REGION} --alarm-names ${ALARM_NAME}"
