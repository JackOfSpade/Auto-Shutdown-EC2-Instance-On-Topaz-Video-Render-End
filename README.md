# Auto-Shutdown EC2 Instance on Topaz Video Render End

Run Topaz Video AI on a rented GPU EC2 box and pay only for the render. An
on-box **watchdog** observes the Topaz GUI and its encode-worker descendants -
`neuroserver.exe` and, once it spawns one, `ffmpeg.exe` (a **grandchild** of
the GUI, matched by ancestry, not just direct parentage); the moment the
render queue drains (or provably stalls) and every output file is unlocked,
it stops the instance. The default `StopStrategy` (`'Auto'`) calls
`ec2:StopInstances` against itself first - the only action that **provably**
ends billing - and falls back to a guest-OS shutdown (`Stop-Computer -Force`)
if that call is denied or does not take effect; the guest-shutdown fallback
only stops (rather than terminates) the instance when
`InstanceInitiatedShutdownBehavior=stop`, a fact this box cannot verify about
itself, which is exactly why the API leg exists. An independent CloudWatch
GPU-idle alarm, and an optional max-lifetime Lambda, sit out-of-band as safety
nets that never share fate with the guest.

The operator's only manual act is to load the project and click **Export once**,
then disconnect. Everything after that click is automated. There is no GUI
robot.

## Architecture

```
                 EC2 GPU instance  -  Windows Server, Amazon DCV display
  +-------------------------------------------------------------------------+
  |                                                                         |
  |   Topaz Video AI (GUI) --spawns--> neuroserver.exe --spawns--> ffmpeg.exe |
  |        |                           (per-queue-item      (GRANDCHILD of   |
  |        | observed via CIM           worker, --once)      the GUI; encode |
  |        v   (Win32_Process, matched by ANCESTRY -- see docs/12)  phase)   |
  |   +---------------+   queue done /    +----------------+                 |
  |   | Watchdog.ps1  |   stalled  AND    |  OutputDir      |                |
  |   | (SYSTEM task) |   files unlocked  |  (output dir)   |                |
  |   +-------+-------+                   +----------------+                 |
  |           | hands off (-Reason completed|stalled)                       |
  |           v                                                             |
  |   +--------------------+                                                 |
  |   | Stop-Sequence.ps1  |  optional S3 sync + SNS, then the StopStrategy  |
  |   +---------+----------+  plan: Ec2ApiStop, falling back to             |
  |             |             GuestShutdown ('Auto' is the default)         |
  +-------------+---------------------------------------------------------- +
                v
   ec2:StopInstances (provably ends billing)   -->   INSTANCE STOPS
   falls back to Stop-Computer -Force, which only STOPS (never terminates)
   the instance when InstanceInitiatedShutdownBehavior = stop


  OUT-OF-BAND FALLBACK  (separate control plane; never shares fate w/ guest)
  +-------------------------------+        +--------------------------------+
  | Push-GpuMetric.ps1 (SYSTEM,   |  put   | CloudWatch alarm               |
  | once/min) nvidia-smi -------> | metric | TopazRender/GPU GPUUtilization |
  | TopazRender/GPU GPUUtilization| -----> | < 5% for 30 min  -> ec2:stop   |
  +-------------------------------+        +--------------------------------+

  OPTIONAL HARD CAP  (last-resort cost guard, independent of everything above)
  +------------------------------------------------------------------------+
  | EventBridge schedule --> max-lifetime-stop Lambda --> ec2:StopInstances |
  | fires when instance age >= MAX_LIFETIME_HOURS, regardless of GPU load   |
  +------------------------------------------------------------------------+
```

## Design principles

- **A guest shutdown needs no AWS credentials on the box - and is retained as
  the fallback leg.** `InstanceInitiatedShutdownBehavior=stop` (set once, at
  the AWS control plane) is what turns a plain guest-OS shutdown into an
  instance *stop* rather than a terminate, and that guest-shutdown path never
  needed a credential. But a guest shutdown only ends billing when that
  attribute happens to be `stop` - a fact the box cannot verify about itself
  without an extra permission. So the default `StopStrategy` (`'Auto'`) tries
  `ec2:StopInstances` FIRST, because that is the only action that *provably*
  ends billing, and only falls back to the credential-free guest shutdown if
  the API call is denied or does not take effect. This box therefore now
  holds a narrowly-scoped, tag-conditioned `ec2:StopInstances` grant (still
  optional and off by default at the control-plane level) that the original
  zero-credential design deliberately avoided - an explicit trade-off, not a
  silent one. See [docs/01-architecture.md](docs/01-architecture.md).
- **The fallback is out-of-band.** The CloudWatch GPU-idle alarm lives entirely
  in the AWS control plane and acts through the built-in
  `arn:aws:automate:<region>:ec2:stop` action. It cannot be taken down by the
  same crash, hang, or logoff that could take down the guest watchdog. A
  deliberately *rejected* alternative was an in-guest fallback timer
  (`Start-Job` / `Stop-EC2Instance`): such a job lives inside the very session
  being torn down and could never reliably fire.
- **Completion is event-driven, never a fixed timer.** The watchdog decides
  "done" from the **lifecycle of Topaz's encoder-worker descendants**
  (`neuroserver.exe`/`ffmpeg.exe`, matched by ancestry - `ffmpeg` is actually a
  *grandchild* of the GUI, see
  [docs/12-empirical-findings.md](docs/12-empirical-findings.md)) plus a
  **file-unlock gate** on the output directory - not from a wall-clock sleep. A
  debounce absorbs transient live-preview workers; a stall detector catches a
  worker that is alive but making no progress, on either the output folder's
  byte total or the workers' own cumulative disk I/O (the folder size alone is
  not reliable - see docs/12).
- **The display protocol is Amazon DCV, not RDP.** An RDP disconnect tears down
  the console session and rebinds the display, which can drop the NVIDIA WDDM
  driver and interrupt GPU work. DCV keeps the GPU session intact across
  disconnect so the render survives the operator walking away.

## Repository layout

```
.
├── README.md                     <- you are here
├── in-guest/                     <- runs on the Windows EC2 box (PowerShell 5.1)
│   ├── Config.ps1                <- single source of truth (paths, tuning, task names,
│   │                                 CompletionSignal: WorkerOnly/GpuOnly/WorkerOrGpu,
│   │                                 StopStrategy: Ec2ApiStop/GuestShutdown/Auto)
│   ├── Watchdog.ps1              <- detects render complete/stalled (worker ancestry +
│   │                                 GPU signal; progress = output bytes OR worker I/O),
│   │                                 gates on file unlock
│   ├── Stop-Sequence.ps1         <- optional S3 sync + SNS, then the StopStrategy plan
│   │                                 (Ec2ApiStop, falling back to GuestShutdown)
│   ├── Push-GpuMetric.ps1        <- publishes GPU% to CloudWatch every minute
│   ├── Install.ps1               <- copies scripts into C:\topaz-autostop
│   ├── Register-ScheduledTasks.ps1  <- registers the two SYSTEM scheduled tasks
│   ├── Register-TimedStop.ps1    <- optional one-shot wall-clock cost backstop
│   ├── Test-Deployment.ps1       <- preflight GO/NO-GO doctor (run before arming)
│   └── tests/                    <- Pester unit tests (Config.ps1 + Watchdog.ps1 pure helpers)
├── control-plane/                <- runs from an admin workstation (AWS CLI v2)
│   ├── 00-verify-prerequisites.sh    <- read-only prerequisite verifier
│   ├── 01-set-shutdown-behavior.sh   <- set InstanceInitiatedShutdownBehavior=stop
│   ├── 02-create-iam-role.sh         <- least-privilege instance role (PutMetricData,
│   │                                     optionally tag-scoped ec2:StopInstances)
│   ├── 03-create-idle-alarm.sh       <- out-of-band GPU-idle CloudWatch alarm
│   ├── 04-deploy-max-lifetime-lambda.sh  <- optional hard-cap Lambda + schedule
│   ├── lib/                       <- sourceable idempotency/validation helpers
│   │   ├── aws-idempotent.sh
│   │   └── validation.sh
│   └── iam/                       <- trust + permission policy documents
│       ├── instance-role-trust-policy.json
│       ├── cloudwatch-putmetric-policy.json
│       ├── ec2-stop-optional-policy.json
│       └── lambda-execution-policy.json
├── lambda/
│   └── max-lifetime-stop/         <- optional wall-clock cap Lambda
│       ├── handler.py
│       ├── test_handler.py
│       └── README.md
├── scripts/
│   └── auto_merge_decision.sh    <- sourceable CI-gate predicates for auto-merge-claude.yml
├── tests/
│   ├── test_auto_merge_logic.sh  <- tests for scripts/auto_merge_decision.sh
│   └── test_control_plane_validation.sh  <- tests for control-plane/lib/*.sh
├── .github/workflows/
│   ├── ci.yml                    <- shellcheck/actionlint + PSScriptAnalyzer/Pester + ruff/pytest
│   └── auto-merge-claude.yml     <- auto-merges CI-green branches into main
└── docs/                          <- full documentation set (linked below)
```

## Quickstart

The steps are ordered. Control-plane scripts run from an admin workstation with
AWS CLI v2 configured and expect `INSTANCE_ID` and `AWS_REGION` in the
environment. In-guest scripts run in PowerShell 5.1 on the EC2 box.

0. **Phase 0 - confirm the box behaves, then bake a golden AMI.** Verify a
   render survives a DCV disconnect, disable the Microsoft Basic Display Adapter
   so the NVIDIA WDDM driver binds, and observe the real Topaz process name,
   output directory, and `_temp` scratch naming. Sysprep a golden AMI.
   See [docs/02-phase0-confirmations.md](docs/02-phase0-confirmations.md).

1. **Control plane - shutdown behavior + instance role.**
   ```bash
   INSTANCE_ID=i-XXXXXXXXXXXXXXXXX AWS_REGION=<region> ./control-plane/01-set-shutdown-behavior.sh
   INSTANCE_ID=i-XXXXXXXXXXXXXXXXX AWS_REGION=<region> ./control-plane/02-create-iam-role.sh
   ```
   `01` makes a guest shutdown stop (not terminate) the box. `02` grants only
   `cloudwatch:PutMetricData`, scoped to the `METRIC_NAMESPACE` namespace
   (default `TopazRender/GPU`; optionally `ec2:StopInstances`, tag-scoped, via
   `INCLUDE_EC2_STOP=1` - which also tags the instance `AutoStopEligible=true` so
   that tag-scoped grant is actually usable). If you override `MetricNamespace`
   in `Config.ps1`, pass the SAME `METRIC_NAMESPACE` to `02` too, or the
   watchdog's PutMetricData calls are denied. See
   [docs/03-phase1-instance-prep.md](docs/03-phase1-instance-prep.md).

2. **In-guest - install the scripts, then register the SYSTEM tasks.** Edit the
   `OPERATOR SETTINGS` block in `in-guest/Config.ps1` to match Phase 0, then:
   ```powershell
   .\in-guest\Install.ps1                    # copies scripts into C:\topaz-autostop
   # from an ELEVATED PowerShell:
   .\in-guest\Register-ScheduledTasks.ps1    # registers the two SYSTEM tasks
   ```
   See [docs/04-phase2-watchdog.md](docs/04-phase2-watchdog.md) and
   [docs/05-phase3-stop-sequence.md](docs/05-phase3-stop-sequence.md).

3. **Control plane - the out-of-band idle alarm.**
   ```bash
   INSTANCE_ID=i-XXXXXXXXXXXXXXXXX AWS_REGION=<region> [IDLE_MINUTES=30] \
     ./control-plane/03-create-idle-alarm.sh
   ```
   Creates a **per-instance** GPU-idle safety net alarm
   (`topaz-gpu-idle-autostop-<instance-id>`) that fires after `IDLE_MINUTES`
   (default 30) of sustained sub-5% GPU. Also accepts `METRIC_NAMESPACE`/
   `METRIC_NAME` overrides (mirroring `Config.ps1`'s `MetricNamespace`/
   `MetricName`) if you changed those from their defaults -- pass the SAME
   `METRIC_NAMESPACE` you gave `02-create-iam-role.sh`, or this alarm watches
   a namespace the instance role isn't even allowed to publish to. The script
   also prints `disable-alarm-actions`/`enable-alarm-actions` commands for
   pausing it during a long pre-render setup. See
   [docs/06-phase4-safety-net.md](docs/06-phase4-safety-net.md).

4. **Control plane - optional hard cap (skip if you do not want one).**
   ```bash
   INSTANCE_ID=i-XXXXXXXXXXXXXXXXX AWS_REGION=<region> MAX_LIFETIME_HOURS=12 \
     ./control-plane/04-deploy-max-lifetime-lambda.sh
   ```
   Tags the instance `AutoStopEligible=true` (required for the Lambda's
   tag-scoped stop permission to actually work), then deploys a **per-instance**
   function (`topaz-max-lifetime-stop-<instance-id>`) and schedule
   (`topaz-max-lifetime-schedule-<instance-id>`). See
   [docs/06-phase4-safety-net.md](docs/06-phase4-safety-net.md).

> **Ship in DryRun first.** On a new deployment, set `DryRun = $true` in
> `Config.ps1` before arming automation: the watchdog and stop sequence then
> log every decision (including the resolved `StopStrategy` plan) but do
> **not** power the box off, and the watchdog re-arms afterward to keep
> monitoring the next queue. Run
> [`Test-Deployment.ps1`](in-guest/Test-Deployment.ps1) for a GO/NO-GO
> preflight check, watch a couple of real jobs complete cleanly, confirm the
> logs under `C:\topaz-autostop\logs`, then flip `DryRun = $false` and re-run
> `Install.ps1` + `Register-ScheduledTasks.ps1`. **This checked-in
> `Config.ps1` already ships with `DryRun = $false`**, because this specific
> instance has already been through that verification loop and had both
> `StopStrategy` legs confirmed - see
> [docs/11-deploying-on-this-instance.md](docs/11-deploying-on-this-instance.md)
> for the evidence; treat that value as this box's own already-verified
> state, not a default a new deployment should copy blindly. **`DryRun` only
> covers the in-guest stop path** - the CloudWatch idle alarm and optional
> max-lifetime Lambda from step 3-4 below are separate control-plane resources
> and will really stop the box if the GPU goes idle during your test, even
> while `DryRun` is on. See
> [docs/05-phase3-stop-sequence.md](docs/05-phase3-stop-sequence.md) and
> [docs/06-phase4-safety-net.md](docs/06-phase4-safety-net.md).

## The start model

The operator loads the files into the Topaz GUI over a DCV session, clicks
**Export once**, and disconnects. From that single click, the pipeline is fully
automated: the SYSTEM watchdog task (already running from boot) observes the
render, waits for the queue to drain and files to unlock, and stops the box.
There is **no GUI robot** - nothing drives, clicks, or scripts the Topaz
interface. See [docs/09-appendix-b-boundaries.md](docs/09-appendix-b-boundaries.md).

## IMPORTANT: license / compliance note

Topaz Video AI is **live-confirmed unwatermarked** on this instance, so it is
functionally usable here. However, the Topaz EULA names **cloud / virtualization
environments among its restrictions** and **bans the command-line interface
under a Personal License**. This pipeline is therefore built to stay strictly
within a defensible reading of that license:

- **Single-user, GUI-only.** One operator, driving the Topaz GUI by hand.
- **No CLI, ever.** Nothing in this repo invokes the Topaz CLI. The watchdog
  detects completion by *observing* the GUI process and its encoder-worker
  descendants (`neuroserver.exe`/`ffmpeg.exe`, matched by ancestry) and the
  output folder on disk - never by calling Topaz.

Running Topaz on a cloud/virtualized instance is **the operator's own informed
license decision.** This project does not grant any right to do so and does not
constitute legal advice. If your license terms forbid this deployment, do not
deploy it. See [docs/09-appendix-b-boundaries.md](docs/09-appendix-b-boundaries.md).

## Testing & CI

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs on every push/PR:
`shellcheck` on `control-plane/*.sh`, `control-plane/lib/*.sh`, `scripts/*.sh`,
and `tests/*.sh`;
`actionlint` (pinned Docker tag) on the workflow YAML, which also lints the
bash embedded directly in workflow `run:` steps; the
[`tests/test_auto_merge_logic.sh`](tests/test_auto_merge_logic.sh) suite for
the auto-merge-to-main decision logic in
[`scripts/auto_merge_decision.sh`](scripts/auto_merge_decision.sh);
[`tests/test_control_plane_validation.sh`](tests/test_control_plane_validation.sh)
for the shared predicates in `control-plane/lib/*.sh`;
PSScriptAnalyzer + Pester on `in-guest/` (including the
[`in-guest/tests/`](in-guest/tests/) suite for the `Resolve-RenderActive`
completion-decision helper and `Watchdog.ps1`'s own pure helpers;
PSScriptAnalyzer fails the build on any
Error/ParseError, and on a Warning too unless its rule is explicitly
allowlisted in `ci.yml`); and `ruff` + `pytest` on
[`lambda/max-lifetime-stop/`](lambda/max-lifetime-stop/). Run the Lambda tests
locally with:

```bash
pip install -r lambda/max-lifetime-stop/requirements-dev.txt && pytest lambda/ -q
```

Run the auto-merge decision tests locally with:

```bash
bash tests/test_auto_merge_logic.sh
```

Run the control-plane validation tests locally with:

```bash
bash tests/test_control_plane_validation.sh
```

The Pester tests need PowerShell 7+ (`pwsh`), which is what CI runs them under;
see [docs/10-testing-and-ci.md](docs/10-testing-and-ci.md) for how to run them
locally, and for what the auto-merge-to-main workflow
([`.github/workflows/auto-merge-claude.yml`](.github/workflows/auto-merge-claude.yml))
does.

## Documentation

| Doc | Contents |
|-----|----------|
| [docs/01-architecture.md](docs/01-architecture.md) | The diagram and design principles, expanded. |
| [docs/02-phase0-confirmations.md](docs/02-phase0-confirmations.md) | DCV vs RDP, WDDM/display adapter, observing process/output/scratch, golden AMI. |
| [docs/03-phase1-instance-prep.md](docs/03-phase1-instance-prep.md) | Shutdown behavior, IAM instance role, AutoAdminLogon caveat, PATH deps. |
| [docs/04-phase2-watchdog.md](docs/04-phase2-watchdog.md) | How the watchdog works, `CompletionSignal` (`WorkerOnly`/`GpuOnly`/`WorkerOrGpu`), why SYSTEM, DebounceSec tuning. |
| [docs/05-phase3-stop-sequence.md](docs/05-phase3-stop-sequence.md) | Event-driven stop, optional S3/SNS, DryRun, why `-Force` is safe. |
| [docs/06-phase4-safety-net.md](docs/06-phase4-safety-net.md) | GPU-idle alarm, the multi-GPU-safe metric publisher, optional Lambda. |
| [docs/07-phase5-notifications.md](docs/07-phase5-notifications.md) | Optional SNS notify, `sns:Publish` permission. |
| [docs/08-appendix-a-corrections.md](docs/08-appendix-a-corrections.md) | Eight bugs / wrong claims removed from the prior report. |
| [docs/09-appendix-b-boundaries.md](docs/09-appendix-b-boundaries.md) | Decided design boundaries (single-user GUI-only, one Export click, no robot). |
| [docs/10-testing-and-ci.md](docs/10-testing-and-ci.md) | What CI checks (including `actionlint`), the auto-merge-to-main workflow and its test suite, and how to run the Pester and Lambda pytest suites locally. |
| [docs/11-deploying-on-this-instance.md](docs/11-deploying-on-this-instance.md) | Instance-specific runbook: read-only prerequisite verification, fixing an IAM role-name mismatch and confirming shutdown behavior from an admin workstation, and safely arming `DryRun`. |
| [docs/12-empirical-findings.md](docs/12-empirical-findings.md) | Live-measured process topology, `neuroserver`/`ffmpeg` invocation arguments, and the NTFS directory-length-vs-`WriteTransferCount` evidence behind `Config.ps1`'s worker/stall/completion settings. |
| [docs/13-first-end-to-end-run.md](docs/13-first-end-to-end-run.md) | Forensic reconstruction of the first complete render -> upload-verify -> stop cycle, including the ffmpeg crash-and-retry and the unlock-gate timeout that preceded it. |
| [docs/14-second-end-to-end-run.md](docs/14-second-end-to-end-run.md) | Forensic reconstruction of the first cycle to run on the committed code: a 4 h 58 m / 9.84 GiB render, verified upload, and a clean stop with the guest-shutdown fallback proven unused. Also records the observability fixes it prompted. |
