# Auto-Shutdown EC2 Instance on Topaz Video Render End

Run Topaz Video AI on a rented GPU EC2 box and pay only for the render. An
on-box **watchdog** observes the Topaz GUI and its child `ffmpeg` encode
workers; the moment the render queue drains (or provably stalls) and every
output file is unlocked, it shuts the guest OS down. Because the instance's
`InstanceInitiatedShutdownBehavior` is set to `stop`, that guest shutdown
**stops** the instance with **no AWS API call and no credentials on the box**.
An independent CloudWatch GPU-idle alarm, and an optional max-lifetime Lambda,
sit out-of-band as safety nets that never share fate with the guest.

The operator's only manual act is to load the project and click **Export once**,
then disconnect. Everything after that click is automated. There is no GUI
robot.

## Architecture

```
                 EC2 GPU instance  -  Windows Server, Amazon DCV display
  +-------------------------------------------------------------------------+
  |                                                                         |
  |   Topaz Video AI (GUI)  --spawns-->  ffmpeg.exe  (encode worker)        |
  |        |                                  |                             |
  |        | observed via CIM                 | writes finished files       |
  |        v   (Win32_Process)                v                             |
  |   +---------------+   queue done /    +----------------+                 |
  |   | Watchdog.ps1  |   stalled  AND    |  D:\Exports     |                |
  |   | (SYSTEM task) |   files unlocked  |  (output dir)   |                |
  |   +-------+-------+                   +----------------+                 |
  |           | hands off (-Reason completed|stalled)                       |
  |           v                                                             |
  |   +--------------------+                                                 |
  |   | Stop-Sequence.ps1  |  optional S3 sync + SNS, then Stop-Computer     |
  |   +---------+----------+                                                 |
  |             | guest OS shutdown                                         |
  +-------------+---------------------------------------------------------- +
                v
   InstanceInitiatedShutdownBehavior = stop   -->   INSTANCE STOPS
        PRIMARY STOP: no AWS API call, no credentials on the box


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

- **The primary stop needs no AWS credentials on the box.** The stop is a plain
  guest-OS shutdown. `InstanceInitiatedShutdownBehavior=stop` (set once, at the
  AWS control plane) is what turns that shutdown into an instance *stop* rather
  than a terminate. Nothing on the instance calls `ec2:StopInstances` and no
  keys are stored to do so.
- **The fallback is out-of-band.** The CloudWatch GPU-idle alarm lives entirely
  in the AWS control plane and acts through the built-in
  `arn:aws:automate:<region>:ec2:stop` action. It cannot be taken down by the
  same crash, hang, or logoff that could take down the guest watchdog. A
  deliberately *rejected* alternative was an in-guest fallback timer
  (`Start-Job` / `Stop-EC2Instance`): such a job lives inside the very session
  being torn down and could never reliably fire.
- **Completion is event-driven, never a fixed timer.** The watchdog decides
  "done" from the **lifecycle of Topaz's child `ffmpeg` worker** plus a
  **file-unlock gate** on the output directory - not from a wall-clock sleep. A
  debounce absorbs transient live-preview `ffmpeg` children; a stall detector
  catches a worker that is alive but no longer producing output.
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
│   │                                 CompletionSignal: WorkerOnly/GpuOnly/WorkerOrGpu)
│   ├── Watchdog.ps1              <- detects render complete/stalled, gates on file unlock
│   ├── Stop-Sequence.ps1         <- optional S3 sync + SNS, then Stop-Computer -Force
│   ├── Push-GpuMetric.ps1        <- publishes GPU% to CloudWatch every minute
│   ├── Install.ps1               <- copies scripts into C:\topaz-autostop
│   ├── Register-ScheduledTasks.ps1  <- registers the two SYSTEM scheduled tasks
│   └── tests/                    <- Pester unit tests (Config.ps1 + Watchdog.ps1 pure helpers)
├── control-plane/                <- runs from an admin workstation (AWS CLI v2)
│   ├── 01-set-shutdown-behavior.sh   <- set InstanceInitiatedShutdownBehavior=stop
│   ├── 02-create-iam-role.sh         <- least-privilege instance role (PutMetricData)
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

> **Ship in DryRun first.** `Config.ps1` sets `DryRun = $true` by default: the
> watchdog and stop sequence log every decision but do **not** power the box off,
> and the watchdog re-arms afterward to keep monitoring the next queue. Watch a
> couple of real jobs complete cleanly, confirm the logs under
> `C:\topaz-autostop\logs`, then flip `DryRun = $false` and re-run
> `Install.ps1` + `Register-ScheduledTasks.ps1`. **`DryRun` only covers this
> in-guest path** - the CloudWatch idle alarm and optional max-lifetime Lambda
> from step 3-4 below are separate control-plane resources and will really stop
> the box if the GPU goes idle during your test, even while `DryRun` is on. See
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
  detects completion by *observing* the GUI process and its `ffmpeg` children
  and the output folder on disk - never by calling Topaz.

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
