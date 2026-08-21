# 11 - Deploying on this instance (i-029f35d589bec9b9c)

[README](../README.md) - [Architecture](01-architecture.md) - [Phase 0](02-phase0-confirmations.md) - [Phase 1](03-phase1-instance-prep.md) - [Phase 2](04-phase2-watchdog.md) - [Phase 3](05-phase3-stop-sequence.md) - [Phase 4](06-phase4-safety-net.md) - [Phase 5](07-phase5-notifications.md) - [Appendix A](08-appendix-a-corrections.md) - [Appendix B](09-appendix-b-boundaries.md) - [Testing & CI](10-testing-and-ci.md) - **Deploying on this instance**

This is a specific, instance-scoped runbook, not a general phase guide. It
covers exactly one box:

| Field | Value |
|-------|-------|
| Instance | `i-029f35d589bec9b9c` (`g6e.2xlarge`, 1x NVIDIA L40S) |
| Region | `us-west-2` |
| Account | `720800607666` |
| Instance role (currently attached) | `topaz-gpu-render-role` |

Everything below assumes those four values. If you are adapting this runbook
for a different box, substitute your own instance id / region / account /
role name throughout - do not copy the literal values below onto another
instance.

> **UPDATE (2026-07-28): this callout is now historical.** The
> `TopazAutoStop-TimedStop` task described below was cancelled on
> **2026-07-27 00:47:20** (`timedstop.log`: `"Cancelled the timed stop:
> removed task 'TopazAutoStop-TimedStop'."`), exactly per this callout's own
> original instruction, once Section 3 verified both `StopStrategy` legs (see
> Section 2). It does **not** exist on this box any more - do not expect it to
> fire, and do not rely on `Get-ScheduledTask` finding it. Left in place below
> for the historical record of why it was armed in the first place. **The
> operator has separately decided (also 2026-07-28) against re-arming any
> automatic backstop by default** - no idle alarm, no max-lifetime Lambda; see
> [docs/09-appendix-b-boundaries.md §5](09-appendix-b-boundaries.md#5-no-idle-alarm-no-timed-stop-the-watchdog-is-the-only-thing-that-will-ever-stop-this-box)
> for that trade-off and its manual mitigations, one of which is deliberately
> re-arming this same task for a single bounded session.
>
> **Original callout, as written before cancellation:** This box had a
> one-shot wall-clock stop armed via
> [`Register-TimedStop.ps1`](../in-guest/Register-TimedStop.ps1), at the
> operator's explicit request, as a cost backstop while the real stop path was
> still being fixed. It ran
> `Stop-Sequence.ps1 -Reason maxlifetime -IgnoreDryRun`, which bypasses
> `DryRun` on purpose - a backstop that respected `DryRun` would not be one.
> It would have fired on the clock regardless of whether a render was still
> running.
>
> **It could not have terminated this instance.** `Stop-Sequence.ps1` only
> ever issues `ec2:StopInstances` and then `Stop-Computer -Force`. A guest
> shutdown can only *terminate* an EC2 instance when
> `InstanceInitiatedShutdownBehavior` is `terminate`, and that attribute has
> only two possible values. This box demonstrably survived an earlier manual
> Windows shutdown, which rules `terminate` out - so the attribute was
> effectively certain to be `stop`, and the worst case for this task would
> have been the guest powering off without the instance stopping (i.e.
> billing continues), **not** data loss.
>
> To re-arm it deliberately for a bounded session (see
> [docs/09 §5](09-appendix-b-boundaries.md#5-no-idle-alarm-no-timed-stop-the-watchdog-is-the-only-thing-that-will-ever-stop-this-box)):
> ```powershell
> .\in-guest\Register-TimedStop.ps1
> Get-ScheduledTask -TaskName 'TopazAutoStop-TimedStop' -ErrorAction SilentlyContinue | Get-ScheduledTaskInfo
> # to stand it back down once you trust the watchdog to take over cleanly:
> .\in-guest\Register-TimedStop.ps1 -Cancel
> ```

## 1. In-guest status

**Design (per [Phase 2](04-phase2-watchdog.md)):**
[`Install.ps1`](../in-guest/Install.ps1) copies `Config.ps1`, `Watchdog.ps1`,
`Stop-Sequence.ps1`, and `Push-GpuMetric.ps1` (plus the optional operator
tools `Register-TimedStop.ps1` / `Test-Deployment.ps1`, when present) into
`C:\topaz-autostop`, then (from an **elevated** PowerShell)
[`Register-ScheduledTasks.ps1`](../in-guest/Register-ScheduledTasks.ps1)
registers two SYSTEM scheduled tasks:

- `TopazAutoStop-Watchdog` - runs `Watchdog.ps1` at startup, unlimited run
  time, restarts up to 3 times 1 minute apart if it crashes.
- `TopazAutoStop-GpuMetric` - runs `Push-GpuMetric.ps1` once a minute,
  forever.

**Verified state on this box as of this writing (a snapshot from before the
2026-07-27 `TimedStop` cancellation - see the updated callout above; the
`TopazAutoStop-TimedStop` row below no longer reflects current reality):**
both `Watchdog`/`GpuMetric` are installed and registered - `C:\topaz-autostop`
exists, and:

```powershell
> Get-ScheduledTask -TaskName 'TopazAutoStop-*' | Select-Object TaskName, State
TaskName                  State
--------                  -----
TopazAutoStop-GpuMetric   Ready
TopazAutoStop-TimedStop   Ready      # historical -- cancelled 2026-07-27, see callout above
TopazAutoStop-Watchdog    Running
```

**This box is now ARMED: `DryRun = $false`** (confirm with
`Select-String DryRun in-guest/Config.ps1`, and check the INSTALLED copy at
`C:\topaz-autostop\Config.ps1` too - the scheduled tasks run that one). The
watchdog will execute a real stop when it decides the queue is complete. It
was armed only after Section 3's verification succeeded; see Section 2 for
the evidence.

**How the stop actually happens has changed.** `Config.ps1` now has a
`StopStrategy` setting (default `'Auto'`) that governs what `Stop-Sequence.ps1`
does once `DryRun` is off:

- `'Ec2ApiStop'` - call `ec2:StopInstances` against itself. The **only**
  method that provably ends billing. Requires the instance role to grant
  `ec2:StopInstances`.
- `'GuestShutdown'` - `Stop-Computer -Force`. Ends billing **only if**
  `InstanceInitiatedShutdownBehavior=stop`.
- `'Auto'` (default) - tries `Ec2ApiStop` first, waits `StopVerifySec`
  (default 90s) to see if the instance actually goes down, and falls back to
  `GuestShutdown` if the API call was denied/failed or did not take effect.

An earlier note in this file claimed a guest shutdown had been observed NOT to
stop this instance. That was a **misreport**: the action actually performed was
a *restart*, which of course never stops an instance. Both stop legs are now
verified working - see Section 2.

## 2. Verified stop paths (both legs confirmed)

`Config.ps1`'s `DryRun` switch gates the **in-guest** stop
([Phase 3](05-phase3-stop-sequence.md)) - it does not touch the out-of-band
safety nets, and it is bypassed entirely by the timed-stop task via
`-IgnoreDryRun`. With `DryRun = $false`, a completed or stalled render runs
the full `StopStrategy='Auto'` plan for real: try `ec2:StopInstances`, then
fall back to `Stop-Computer -Force`.

Both legs were verified from inside the guest before arming:

```
$ aws ec2 stop-instances --instance-ids i-029f35d589bec9b9c --dry-run --region us-west-2
An error occurred (DryRunOperation) ... Request would have succeeded,
but DryRun flag is set.                                   # => ec2:StopInstances GRANTED

$ aws ec2 describe-instance-attribute --instance-id i-029f35d589bec9b9c \
    --region us-west-2 --attribute instanceInitiatedShutdownBehavior
{ "InstanceInitiatedShutdownBehavior": { "Value": "stop" } }   # => guest shutdown STOPS, never terminates
```

- **`Ec2ApiStop` works.** An inline policy `topaz-autostop-inline` on
  `topaz-gpu-render-role` grants `ec2:StopInstances` scoped to this instance's
  ARN, plus `ec2:DescribeInstanceAttribute`/`DescribeInstances`/`DescribeTags`
  and `cloudwatch:PutMetricData` conditioned on namespace `TopazRender/GPU`.
- **`GuestShutdown` works as a fallback.** `InstanceInitiatedShutdownBehavior`
  reads `stop`, so a guest shutdown stops the instance and can never terminate
  it.
- **The out-of-band GPU metric feed now publishes.** `Push-GpuMetric.ps1` logs
  `Published TopazRender/GPU/GPUUtilization=<n>% ...` once a minute. Note the
  role still lacks `cloudwatch:DescribeAlarms`/`ListMetrics`/`PutMetricAlarm`,
  so the idle **alarm** itself must still be created from an admin workstation
  ([`03-create-idle-alarm.sh`](../control-plane/03-create-idle-alarm.sh)).

> **Watch out for IAM eventual consistency.** After the policy was attached,
> `ec2:StopInstances` took effect immediately but `cloudwatch:PutMetricData`
> alternated denied/denied/accepted for several minutes. Re-probe a few times
> before concluding a grant did not apply.

Both stop paths are verified, so this box is armed. The remaining work in
Section 3 is the optional out-of-band idle alarm, not the primary stop.

## 3. Commands to run from an admin workstation

Run these from a workstation with **AWS CLI v2** and **real IAM credentials**
(not this instance's role) - e.g. your own SSO/IAM user with EC2/IAM/CloudWatch
permissions on account `720800607666`. Set the instance/region once:

```bash
export INSTANCE_ID=i-029f35d589bec9b9c
export AWS_REGION=us-west-2
```

### 3.1. Verify first (read-only, safe to run anytime)

```bash
./control-plane/00-verify-prerequisites.sh
```

This makes no mutating call. Confirm you see `[FAIL]` on the caller-identity
check turn into `[OK]` (i.e. you are *not* running as
`topaz-gpu-render-role` yourself), and note which of the remaining checks
are `[FAIL]` - that is exactly what steps 3.2-3.4 below fix. Expect, on the
first run against this box, `[FAIL]` on `InstanceInitiatedShutdownBehavior`,
the instance-profile-role's `PutMetricData` grant, and likely the instance
profile check itself (see the naming-mismatch note in 3.3).

### 3.2. Fix the shutdown behavior (the `GuestShutdown` fallback leg)

```bash
./control-plane/01-set-shutdown-behavior.sh
```

Sets `InstanceInitiatedShutdownBehavior=stop` and reads it back to confirm.
Do this even if you also complete 3.3's `ec2:StopInstances` grant below -
`StopStrategy='Auto'` falls back to `GuestShutdown` whenever the API call is
denied or does not take effect within `StopVerifySec`, so this is the
last line of defense, not a redundant step.

### 3.3. Grant `cloudwatch:PutMetricData` + `ec2:StopInstances` - expect a role-name conflict

```bash
INCLUDE_EC2_STOP=1 ./control-plane/02-create-iam-role.sh
```

`INCLUDE_EC2_STOP=1` matters on this box specifically: it grants the
tag-scoped `ec2:StopInstances` permission `StopStrategy='Auto'`'s primary
(`Ec2ApiStop`) leg needs, and tags the instance `AutoStopEligible=true` so
that grant is actually usable (see
[`iam/ec2-stop-optional-policy.json`](../control-plane/iam/ec2-stop-optional-policy.json)).
Without it, only the `cloudwatch:PutMetricData` grant is created and the
`Ec2ApiStop` leg stays permanently denied.

**This box already has a different role attached** (`topaz-gpu-render-role`,
not this script's `topaz-render-instance-role`). `02-create-iam-role.sh`
will create the new role/profile fine, but the final
`associate-iam-instance-profile` step will hit its own
already-associated-with-a-different-profile branch and print something like:

```
ERROR: i-029f35d589bec9b9c is associated with a DIFFERENT IAM instance profile: <existing profile name>
       Expected: topaz-render-instance-profile
       Fix with:
         aws ec2 replace-iam-instance-profile-association --region us-west-2 \
             --association-id <assoc-id> \
             --iam-instance-profile Name=topaz-render-instance-profile
```

You have two options here - pick one, do not do both:

- **Option A (matches the repo as-is):** run the printed
  `replace-iam-instance-profile-association` command. This swaps the
  instance over to the repo's own `topaz-render-instance-role` /
  `topaz-render-instance-profile`. This is safe to do even while the render
  is in progress - swapping the instance profile is an EC2-metadata-only
  change; it does not touch the running Topaz/`neuroserver` processes -
  but any process on the box already relying on the OLD role's credentials
  would see them change. As of this writing, the watchdog/metric tasks are
  registered but nothing has consumed `topaz-gpu-render-role`'s credentials
  for anything that matters yet (Section 1), so this is low-risk right now.
- **Option B (smaller diff, keep the existing role name):** skip
  `02-create-iam-role.sh`'s instance-profile creation entirely and attach the
  same policies directly to the role already in place:
  ```bash
  aws iam put-role-policy --role-name topaz-gpu-render-role \
    --policy-name topaz-putmetric \
    --policy-document file://control-plane/iam/cloudwatch-putmetric-policy.json
  aws iam put-role-policy --role-name topaz-gpu-render-role \
    --policy-name topaz-ec2-stop \
    --policy-document file://control-plane/iam/ec2-stop-optional-policy.json
  aws ec2 create-tags --region us-west-2 --resources i-029f35d589bec9b9c \
    --tags Key=AutoStopEligible,Value=true
  ```
  This grants exactly the same `cloudwatch:PutMetricData` (namespace-scoped
  to `TopazRender/GPU`) and tag-scoped `ec2:StopInstances` permissions the
  pipeline needs, without touching the instance-profile association at all.

Either way, re-run `00-verify-prerequisites.sh` afterward and confirm check
4/6 (`PutMetricData grant`) now reports `[OK]`, and separately confirm the
`ec2:StopInstances` grant landed (`00-verify-prerequisites.sh` does not check
this - it is out of that script's scope; verify with
`aws iam list-role-policies --role-name <role>` /
`aws iam get-role-policy --role-name <role> --policy-name topaz-ec2-stop`).

### 3.4. The out-of-band idle alarm - SKIPPED for this box (decided 2026-07-28)

**Do not run this step as part of the normal deployment sequence any more.**
The operator decided, on 2026-07-28, against any idle-based auto-stop for
this project and has already deleted this box's alarm
(`topaz-gpu-idle-autostop-i-029f35d589bec9b9c`). See
[Phase 4](06-phase4-safety-net.md) and
[docs/09 §5](09-appendix-b-boundaries.md#5-no-idle-alarm-no-timed-stop-the-watchdog-is-the-only-thing-that-will-ever-stop-this-box)
for the full reasoning and the accepted cost. `00-verify-prerequisites.sh`'s
check `5/6` is therefore **expected** to report `[WARN]` ("alarm ... does not
exist yet") on this box from now on - that is the intended state, not a
regression to fix.

If you deliberately want to re-create it anyway (e.g. for a bounded,
supervised session - see docs/09 §5's manual mitigations), the script now
requires an explicit opt-in and refuses to run without it:

```bash
ENABLE_IDLE_ALARM=1 ./control-plane/03-create-idle-alarm.sh
```

This creates `topaz-gpu-idle-autostop-i-029f35d589bec9b9c`, watching, by
default (`IDLE_SIGNAL=render`), `TopazRender/GPU : RenderActive` (`--statistic
Maximum`, `< 1`) for `IDLE_MINUTES` minutes (default **30**) of sustained idle
- i.e. no encoder worker process alive - before calling the built-in
`arn:aws:automate:us-west-2:ec2:stop` action. The legacy sub-5%
`GPUUtilization` behavior is still available via `IDLE_SIGNAL=gpu`, but was
measured wrong in both directions on this box (too low during a real render,
too high while merely DCV-connected) - see [Phase 4](06-phase4-safety-net.md).
Tear it back down when the supervised session is over (idempotent - safe even
if it was never created):

```bash
TEARDOWN=1 ./control-plane/03-create-idle-alarm.sh
```

> **Historical note, kept for context.** Before the 2026-07-28 decision, this
> box's alarm had already been re-run once to move it from the old
> `GPUUtilization` default onto `RenderActive` - see the 30-minute default
> window referenced against this box's alarm in
> [docs/15 §K](15-third-end-to-end-run.md), which documented a real
> near-miss under the old signal. That re-key narrowed the false-stop hazard;
> it is why the operator's 2026-07-28 decision was to remove the alarm
> entirely rather than merely trust the narrower signal.

### 3.5. Optional: grant on-box control-plane audit reads (skip unless you specifically want it)

```bash
./control-plane/05-grant-audit-reads.sh
```

**This is not part of the deployment sequence above - it is optional and
opt-in.** The role attached to this box (`topaz-gpu-render-role`, per the
table at the top of this doc) grants only what Section 3.3 put there:
`cloudwatch:PutMetricData` and a tag-scoped `ec2:StopInstances`. That is
correct for running the pipeline, but it also means this box cannot answer
"what actually stopped me?" after the fact -
[docs/09-appendix-b-boundaries.md §4](09-appendix-b-boundaries.md) records the
exact `AccessDenied` reads a real forensic audit hit on this box's role
(`cloudtrail:LookupEvents`, `cloudwatch:DescribeAlarms`/`DescribeAlarmHistory`,
`lambda:ListFunctions`, `logs:DescribeLogGroups`, `iam:List*RolePolicies`).

`05-grant-audit-reads.sh` auto-discovers the role attached to `INSTANCE_ID`
(so it finds `topaz-gpu-render-role` on this box without any extra flag) and
grants it a separate, READ-ONLY managed policy covering exactly those reads -
nothing that can create, modify, delete, start, stop, or terminate anything.

**Prefer the admin workstation instead, for a one-off investigation.** You are
already running these control-plane commands from a workstation with broader
credentials than this box will ever need - `aws cloudtrail lookup-events`,
`aws cloudwatch describe-alarms`, `aws lambda list-functions`, etc. all work
fine from here right now, at zero cost to this box's privilege and nothing to
remember to revoke later. Reach for `05-grant-audit-reads.sh` only if you
specifically want a post-mortem run **from the box itself** to be
self-sufficient (e.g. no admin workstation reachable at post-mortem time).
Skipping this step entirely is the default, least-privilege posture and does
not block anything else in this runbook.

### 3.6. Re-verify everything

```bash
./control-plane/00-verify-prerequisites.sh
```

Confirm **zero `[FAIL]` lines**, in particular
`InstanceInitiatedShutdownBehavior='stop'`. Then separately confirm the
`ec2:StopInstances` grant from 3.3 (not checked by this script - see its
note above). Do not proceed to Section 4 until both are true.

## 4. The single edit that arms the pipeline

Once (and only once) Section 3 has confirmed **both**
`InstanceInitiatedShutdownBehavior='stop'` **and** the tag-scoped
`ec2:StopInstances` grant:

```powershell
# in-guest/Config.ps1, in the "HOW THE STOP IS PERFORMED" block
DryRun           = $false   # was: $true
```

That is the entire edit - one line. Because that file is owned by a
concurrent workstream on this box (Section 1), coordinate the edit with its
owner rather than changing it unilaterally.

After the edit lands, the installed copy under `C:\topaz-autostop` must be
refreshed and the scheduled tasks must pick up the change:

```powershell
.\in-guest\Install.ps1                    # re-copies Config.ps1 (+ the others) into C:\topaz-autostop
# from an ELEVATED PowerShell:
.\in-guest\Register-ScheduledTasks.ps1    # re-registers the two SYSTEM tasks
```

`Register-ScheduledTasks.ps1` unregisters and re-creates each task by name,
so this is safe to run repeatedly. **Do not perform this edit or re-run these
two scripts until Section 3 has verified both stop-path legs, and not while
the current render (GUI PID `11980` / `neuroserver` PID `10680`) is still
running** - wait for it to finish, or you risk the very next completed/
stalled render stopping the box for real, before you intended to test that.

## 5. What will happen when it fires

Once armed (Section 4) and a render completes or stalls:

1. `Watchdog.ps1` detects the render queue is done (no active worker/GPU
   signal for `DebounceSec`, **300s** on this box) or stalled (no progress on
   EITHER the worker I/O counters or the output byte total for `StallSec`,
   **1800s**), then waits up to `UnlockTimeoutMin` (default 5 min) for every
   output file to unlock.

   The 300s debounce is what absorbs the gap between two queued items. That gap
   was measured on this box at **61 seconds** (item 1's `neuroserver` exited
   01:52:28, item 2's started 01:53:29), so the shipped value has roughly 5x
   headroom over the observed worst case.
2. It hands off to `Stop-Sequence.ps1 -Reason completed|stalled`, which runs
   any optional S3 sync / SNS publish, then executes the `StopStrategy` plan.
3. With the default `'Auto'` strategy: it calls `ec2:StopInstances` first
   (now provably granted, per Section 3.3) and waits up to `StopVerifySec`
   (default 90s) for the instance to actually go down. This is the path that
   **provably ends billing**, with no dependency on
   `InstanceInitiatedShutdownBehavior`.
4. Only if that call is denied, fails, or does not take effect in time does
   it fall back to `Stop-Computer -Force` - which, because
   `InstanceInitiatedShutdownBehavior=stop` (verified in Section 3.2), still
   **stops** (does not terminate) `i-029f35d589bec9b9c` if it is ever reached.
5. If every action in the plan fails, `Stop-Sequence.ps1` logs an `ERROR`
   that the instance is still running and likely still being billed - see
   Section 6.
6. **There is no independent backstop layer on this box.** Section 3.4's
   CloudWatch idle alarm is deliberately not created, the max-lifetime Lambda
   is not deployed, and the in-guest `Register-TimedStop.ps1` timed stop was
   cancelled once this section's steps were verified. If steps 1-5 above all
   fail to stop the instance, nothing else will - a human has to notice and
   stop it by hand.
   **If you ever re-arm one of these, prefer `Register-TimedStop.ps1` over the
   max-lifetime Lambda.** The timed stop runs *through* `Stop-Sequence.ps1`, so
   the ephemeral-upload interlock still refuses a stop that would erase a
   finished-but-not-uploaded render (it simply retries on its repeating
   trigger). The Lambda stops the instance from *outside* the guest and so
   bypasses that interlock entirely - a render sitting unuploaded on the
   instance-store scratch volume is destroyed with the stop. See the `.DANGER`
   header of
   [`04-deploy-max-lifetime-lambda.sh`](../control-plane/04-deploy-max-lifetime-lambda.sh)
   and [docs/16](16-render-loss-incident.md). See
   [docs/09 §5](09-appendix-b-boundaries.md#5-no-idle-alarm-no-timed-stop-the-watchdog-is-the-only-thing-that-will-ever-stop-this-box)
   for that trade-off and its manual mitigations, and
   [Phase 4](06-phase4-safety-net.md) for how to re-arm any of these layers
   deliberately if you want one back for a specific session.

## 6. Troubleshooting

| Symptom | Likely cause | Where to look |
|---------|--------------|----------------|
| `00-verify-prerequisites.sh` shows `[WARN]` on caller identity | You ran it using this instance's own role (ARN ends in `/i-029f35d589bec9b9c`), not an admin workstation's credentials | Re-run from an admin workstation; the ARN in the `[1/6]` line names the identity actually used |
| `InstanceInitiatedShutdownBehavior` still not `stop` after 3.2 | `01-set-shutdown-behavior.sh` was never run, or ran against the wrong `INSTANCE_ID`/`AWS_REGION` | Re-run `00-verify-prerequisites.sh`'s `[2/6]` check; re-run `01-set-shutdown-behavior.sh` with the exact values in Section 3 |
| `02-create-iam-role.sh` errors with "associated with a DIFFERENT IAM instance profile" | Expected on this box - see 3.3 | Follow Option A or B in Section 3.3 |
| `Stop-Sequence.ps1` logs `EC2 API stop ... AccessDenied` | The role lacks `ec2:StopInstances`, or the instance is not tagged `AutoStopEligible=true` | `C:\topaz-autostop\logs\stop.log`; re-run Section 3.3 with `INCLUDE_EC2_STOP=1` (or Option B) |
| `Stop-Sequence.ps1` logs "Every action in the stop plan ... was attempted and the instance is STILL RUNNING" | Both `Ec2ApiStop` (no grant) and `GuestShutdown` (`InstanceInitiatedShutdownBehavior` not `stop`) failed - the box is running and being billed with nothing left to stop it | `C:\topaz-autostop\logs\stop.log`; complete Section 3 fully before this happens again |
| Watchdog never seems to start after a fresh render | `TopazAutoStop-Watchdog` task not registered, or Topaz's process name changed and no longer matches `TopazNameLike` | `Get-ScheduledTask -TaskName TopazAutoStop-Watchdog`; `C:\topaz-autostop\logs\watchdog.log` for `"Watchdog starting..."` / `"Topaz GUI detected"` lines |
| Box never stops after a render finishes, even with `DryRun=$false` | Watchdog still sees an active worker/GPU signal (a false-positive live-preview `ffmpeg`, or `CompletionSignal`/`GpuBusyPercent` tuned wrong); or the unlock gate is stuck on a locked file | `C:\topaz-autostop\logs\watchdog.log` for `"No active render for ...s (>= debounce)"` and `"All output files are unlocked"` / `"Unlock wait timed out"` lines |
| Watchdog declares `STALLED` during a real, still-running render | `StallSec` (1800s here) too short for this job's progress pattern | `C:\topaz-autostop\logs\watchdog.log` for `"Output stalled for ...s"`; raise `StallSec` in `Config.ps1` |
| A render produces NO output at all and the box stops anyway | **Disk full.** Topaz's final mux step runs `ffmpeg -c:v copy`, which writes a COMPLETE SECOND COPY of the output before replacing the original - so an export needs ~2x its output size free. When it fails, Topaz DELETES both files, leaving no trace in the output folder. The watchdog cannot tell a failed render from a successful one; it only sees the queue drain, and stops the box either way | Topaz's own log at `%APPDATA%\Topaz Labs LLC\Topaz Video\logs\*.tzlog` - search for `No space left on device` and `Conversion failed!`. Budget `frames x 3.64 MB x 2` free space for 4K DNxHR HQX |
| Stop-Sequence runs but the box never actually stops | `DryRun` is still `$true` in the **installed** copy (`Install.ps1` not re-run after the edit) | `C:\topaz-autostop\logs\stop.log` for `"DRY RUN - would stop now"` - if present, the edit from Section 4 has not taken effect yet |
| S3 sync / SNS publish logged as failed, but the box still stopped | Both are best-effort and never block the stop; check `NoRegionError` (region discovery via IMDS failed) or a permissions gap | `C:\topaz-autostop\logs\stop.log` for `WARN` lines naming the failed call |
| GPU/RenderActive telemetry never appears in CloudWatch (no alarm is watching it by default - see 3.4) | `TopazAutoStop-GpuMetric` task not registered, `nvidia-smi.exe`/`aws.exe` not on PATH for the SYSTEM account, or the role still lacks `PutMetricData` (Section 3.3) | `C:\topaz-autostop\logs\metric.log`; `00-verify-prerequisites.sh`'s `[4/6]` check |
| `00-verify-prerequisites.sh`'s `[5/6]` reports `[WARN]`: alarm does not exist | **Expected on this box since 2026-07-28** - the idle alarm is deliberately not created; see Section 3.4 | Not a defect; see [docs/09 §5](09-appendix-b-boundaries.md#5-no-idle-alarm-no-timed-stop-the-watchdog-is-the-only-thing-that-will-ever-stop-this-box) |
| `Install.ps1` reports errors | A source script is missing from `in-guest/`, or the install directory is not writable | `C:\topaz-autostop\logs\install.log` |
| `Register-ScheduledTasks.ps1` throws "requires elevation" | Not run from an Administrator PowerShell | Re-run from an elevated shell; `C:\topaz-autostop\logs\register.log` |
| Instance stops unexpectedly at a specific wall-clock time with no render running | The `TopazAutoStop-TimedStop` task (see the URGENT callout at the top of this doc) fired | `C:\topaz-autostop\logs\stop.log` (`-Reason maxlifetime`); `Get-ScheduledTaskInfo -TaskName TopazAutoStop-TimedStop` for when it last ran |

Continue back to [README](../README.md) for the full pipeline, or
[Phase 4](06-phase4-safety-net.md) for the safety-net design this runbook
exists to finish deploying.
