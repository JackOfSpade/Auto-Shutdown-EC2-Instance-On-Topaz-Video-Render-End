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
itself, which is exactly why the API leg exists. **This project runs with no
idle-based auto-stop at all** - the operator decided (2026-07-28) that the
only sanctioned auto-stop is watchdog-completion -> verified Google Drive
upload -> `ec2:StopInstances`; see
[docs/09-appendix-b-boundaries.md §5](docs/09-appendix-b-boundaries.md#5-no-idle-alarm-no-timed-stop-the-watchdog-is-the-only-thing-that-will-ever-stop-this-box)
for why, and for the accepted cost. An out-of-band CloudWatch idle alarm and
an optional max-lifetime Lambda remain available as opt-in capabilities - see
[docs/06-phase4-safety-net.md](docs/06-phase4-safety-net.md) - but neither is
armed by default, and this instance's alarm has been deleted.

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
  |   | Stop-Sequence.ps1  |  optional S3 sync, Google Drive upload (MANDATORY|
  |   +---------+----------+  when OutputDir is ephemeral) + SNS, then the   |
  |             |             StopStrategy plan: Ec2ApiStop, falling back to |
  |             |             GuestShutdown ('Auto' is the default)          |
  +-------------+---------------------------------------------------------- +
                v
   ec2:StopInstances (provably ends billing)   -->   INSTANCE STOPS
   falls back to Stop-Computer -Force, which only STOPS (never terminates)
   the instance when InstanceInitiatedShutdownBehavior = stop


  OUT-OF-BAND FALLBACKS  (opt-in capabilities; NOT ARMED for this project)
  +-------------------------------+        +---------------------------------+
  | Push-GpuMetric.ps1 (SYSTEM,   |  put   | CloudWatch idle alarm           |
  | once/min): CIM worker query   | metric | NOT created/armed here -- opt-  |
  | -> RenderActive (1/0),        | -----> | in via ENABLE_IDLE_ALARM=1 on   |
  | nvidia-smi -> GPUUtilization%  |        | 03-create-idle-alarm.sh         |
  | (telemetry only, always on)   |        | (decided against, 2026-07-28)   |
  +-------------------------------+        +---------------------------------+

  OPTIONAL HARD CAP  (last-resort cost guard -- NOT DEPLOYED for this project)
  +------------------------------------------------------------------------+
  | EventBridge schedule --> max-lifetime-stop Lambda --> ec2:StopInstances |
  | fires when instance age >= MAX_LIFETIME_HOURS, regardless of GPU load   |
  +------------------------------------------------------------------------+
```

**The only auto-stop armed on this project is the primary path above** -
watchdog completion, verified upload, `ec2:StopInstances`. The two boxes below
the primary path are documented capabilities, not active safety nets here;
see [docs/09-appendix-b-boundaries.md §5](docs/09-appendix-b-boundaries.md#5-no-idle-alarm-no-timed-stop-the-watchdog-is-the-only-thing-that-will-ever-stop-this-box)
for the accepted cost of running that way and the manual mitigations
available.

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
- **Any out-of-band fallback lives in the control plane, when one is armed at
  all - and for this project, none is.** The CloudWatch idle alarm, if
  created, lives entirely in the AWS control plane and acts through the
  built-in `arn:aws:automate:<region>:ec2:stop` action, so it cannot be taken
  down by the same crash, hang, or logoff that could take down the guest
  watchdog. But the operator decided (2026-07-28) against arming it: an idle
  signal cannot distinguish an abandoned box from one that is merely mid-setup
  or between queue items, and the GPU-keyed version of this exact alarm had
  already come within five minutes of stopping a live, healthy render the day
  before (2026-07-27). `control-plane/03-create-idle-alarm.sh` is therefore
  opt-in (`ENABLE_IDLE_ALARM=1`), not part of this project's deployment
  sequence - see
  [docs/09-appendix-b-boundaries.md §5](docs/09-appendix-b-boundaries.md#5-no-idle-alarm-no-timed-stop-the-watchdog-is-the-only-thing-that-will-ever-stop-this-box).
  A separately *rejected* alternative, on any deployment, is an in-guest
  fallback timer (`Start-Job` / `Stop-EC2Instance`): such a job lives inside
  the very session being torn down and could never reliably fire - which is
  why any fallback that *is* armed belongs in the control plane, never the
  guest.
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
│   ├── Stop-Sequence.ps1         <- optional S3 sync, Google Drive upload (mandatory when
│   │                                 OutputDir is ephemeral; misplaced-output recovery scan
│   │                                 on an anomalous empty OutputDir) + SNS, then the
│   │                                 StopStrategy plan (Ec2ApiStop, falling back to
│   │                                 GuestShutdown)
│   ├── Push-GpuMetric.ps1        <- publishes RenderActive (1/0, the alarm's
│   │                                 default signal) + GPU% (telemetry) to
│   │                                 CloudWatch every minute
│   ├── Initialize-ScratchDisk.ps1  <- formats the instance-store NVMe and re-creates
│   │                                   OutputDir at every boot (it comes back RAW after
│   │                                   every stop); runs as its own SYSTEM task
│   ├── Install.ps1               <- copies scripts into C:\topaz-autostop
│   ├── Register-ScheduledTasks.ps1  <- registers the three SYSTEM scheduled tasks
│   ├── Register-TimedStop.ps1    <- optional wall-clock cost backstop (repeating
│   │                                 trigger; honors the upload interlock, so a
│   │                                 refused stop is retried rather than dropped)
│   ├── Set-GoogleDriveAuth.ps1   <- one-time rclone/Google Drive credential setup
│   ├── Test-Deployment.ps1       <- preflight GO/NO-GO doctor (run before arming)
│   └── tests/                    <- Pester unit tests (Config.ps1 + Watchdog.ps1 pure helpers,
│                                     Stop-Sequence.ps1 + Test-Deployment.ps1 via -LibraryOnly)
├── control-plane/                <- runs from an admin workstation (AWS CLI v2)
│   ├── 00-verify-prerequisites.sh    <- read-only prerequisite verifier
│   ├── 01-set-shutdown-behavior.sh   <- set InstanceInitiatedShutdownBehavior=stop
│   ├── 02-create-iam-role.sh         <- least-privilege instance role (PutMetricData,
│   │                                     optionally tag-scoped ec2:StopInstances)
│   ├── 03-create-idle-alarm.sh       <- OPT-IN out-of-band idle CloudWatch alarm
│   │                                     (OFF by default -- ENABLE_IDLE_ALARM=1
│   │                                     required; TEARDOWN=1 to remove)
│   ├── 04-deploy-max-lifetime-lambda.sh  <- optional hard-cap Lambda + schedule
│   ├── 05-grant-audit-reads.sh       <- OPTIONAL/OPT-IN: read-only control-plane
│   │                                     audit reads, for an on-box post-mortem
│   ├── lib/                       <- sourceable idempotency/validation helpers
│   │   ├── aws-idempotent.sh
│   │   └── validation.sh
│   └── iam/                       <- trust + permission policy documents
│       ├── instance-role-trust-policy.json
│       ├── cloudwatch-putmetric-policy.json
│       ├── ec2-stop-optional-policy.json
│       ├── lambda-execution-policy.json
│       └── audit-read-optional-policy.json
├── lambda/
│   └── max-lifetime-stop/         <- optional wall-clock cap Lambda
│       ├── handler.py
│       ├── test_handler.py
│       └── README.md
├── scripts/
│   └── auto_merge_decision.sh    <- sourceable CI-gate predicates for auto-merge-claude.yml
├── tests/
│   ├── test_*.sh                 <- glob-discovered bash suites (control-plane deploy
│   │                                 scripts + lib predicates + auto-merge decisions)
│   └── fixtures/                 <- fake `aws`/`zip`/`sleep` stand-ins the suites drive
│                                     the deploy scripts against (no AWS, no network)
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
   .\in-guest\Register-ScheduledTasks.ps1    # registers the three SYSTEM tasks
   ```
   See [docs/04-phase2-watchdog.md](docs/04-phase2-watchdog.md) and
   [docs/05-phase3-stop-sequence.md](docs/05-phase3-stop-sequence.md).

3. **Control plane - optional hard cap (skip if you do not want one; NOT deployed for this project).**
   ```bash
   INSTANCE_ID=i-XXXXXXXXXXXXXXXXX AWS_REGION=<region> MAX_LIFETIME_HOURS=12 \
     ./control-plane/04-deploy-max-lifetime-lambda.sh
   ```
   Tags the instance `AutoStopEligible=true` (required for the Lambda's
   tag-scoped stop permission to actually work), then deploys a **per-instance**
   function (`topaz-max-lifetime-stop-<instance-id>`) and schedule
   (`topaz-max-lifetime-schedule-<instance-id>`).

   > **DANGER: a Lambda stop bypasses `Stop-Sequence.ps1` entirely** - no
   > upload, no verification, no ephemeral-upload interlock. A finished but
   > un-uploaded render on the instance-store volume is **destroyed** with the
   > stop. Prefer [`in-guest/Register-TimedStop.ps1`](in-guest/Register-TimedStop.ps1)
   > whenever the guest is reachable: it is the wall-clock cap that *honors* the
   > interlock, refusing and retrying instead of erasing. Full warnings in
   > [docs/06 §DANGER](docs/06-phase4-safety-net.md#danger-a-lambda-stop-bypasses-stop-sequenceps1-and-can-destroy-a-finished-render),
   > [`lambda/max-lifetime-stop/README.md`](lambda/max-lifetime-stop/README.md)
   > and the incident this rule came from,
   > [docs/16](docs/16-render-loss-incident.md).

   See [docs/06-phase4-safety-net.md](docs/06-phase4-safety-net.md).

That is the entire deployment sequence. **There is no numbered step for the
CloudWatch idle alarm any more** - see the callout immediately below for why,
and how to opt into it anyway if you have a specific reason to.

> **Not a pipeline step - control plane, out-of-band idle alarm (OFF BY
> DEFAULT; the operator decided against it on 2026-07-28 - skip unless you
> specifically want it for a different deployment or a bounded, supervised
> session).**
> ```bash
> INSTANCE_ID=i-XXXXXXXXXXXXXXXXX AWS_REGION=<region> ENABLE_IDLE_ALARM=1 \
>   [IDLE_SIGNAL=render] [IDLE_MINUTES=30] ./control-plane/03-create-idle-alarm.sh
> ```
> [`03-create-idle-alarm.sh`](control-plane/03-create-idle-alarm.sh) **refuses
> to create or update anything unless `ENABLE_IDLE_ALARM=1` is passed
> explicitly** - without it, it explains why and exits without calling AWS.
> This project's own sole sanctioned auto-stop is watchdog-completion ->
> verified Google Drive upload -> `ec2:StopInstances`; an idle alarm cannot
> distinguish "abandoned" from "operator is mid-setup" or "between two queue
> items", and the GPU-keyed version of this exact alarm had already come
> within five minutes of stopping a live, healthy render on 2026-07-27 - see
> [docs/09-appendix-b-boundaries.md §5](docs/09-appendix-b-boundaries.md#5-no-idle-alarm-no-timed-stop-the-watchdog-is-the-only-thing-that-will-ever-stop-this-box).
> If enabled anyway, it creates a **per-instance** alarm
> (`topaz-gpu-idle-autostop-<instance-id>`) that fires after `IDLE_MINUTES`
> (default 30) of sustained idle - `IDLE_SIGNAL` (default `render`) keys it on
> `RenderActive` (no encoder worker process alive); the legacy `IDLE_SIGNAL=gpu`
> restores the old sub-5% `GPUUtilization` behavior, measured wrong in both
> directions on a box with a connected DCV session -- see
> [docs/06-phase4-safety-net.md](docs/06-phase4-safety-net.md). Remove it again
> with `TEARDOWN=1 ./control-plane/03-create-idle-alarm.sh` (idempotent).

> **Not a pipeline step - control plane, read-only audit access (skip unless
> you specifically want it).**
> ```bash
> INSTANCE_ID=i-XXXXXXXXXXXXXXXXX AWS_REGION=<region> ./control-plane/05-grant-audit-reads.sh
> ```
> [`05-grant-audit-reads.sh`](control-plane/05-grant-audit-reads.sh) is
> **optional and opt-in, not part of the normal deployment sequence above.**
> It grants the render role READ-ONLY CloudTrail/CloudWatch/Lambda/Logs/IAM
> permissions so an in-guest post-mortem can attribute a stop (watchdog vs.
> alarm vs. Lambda vs. human) without an admin workstation - the pipeline
> itself needs none of it. For a one-off investigation, prefer running the
> same audit commands from the admin workstation you already used for step 1
> and (if enabled) the idle-alarm/hard-cap callouts above - it already holds
> broader credentials and this script changes nothing on the box. Only reach
> for `05` when you want the render box itself
> to be forensically self-sufficient. See
> [docs/09-appendix-b-boundaries.md](docs/09-appendix-b-boundaries.md).

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
> covers the in-guest stop path** - IF you have separately opted into the
> CloudWatch idle alarm or deployed the optional max-lifetime Lambda (step 3
> and its callout above), know that both are separate control-plane resources
> that are **not** gated by `DryRun` and would really stop the box if the GPU
> goes idle during your test, even while `DryRun` is on. And `DryRun` is the
> *weaker* half of what they miss: neither is gated by the **ephemeral-upload
> interlock** either, so their stop can destroy a finished-but-unuploaded render
> rather than merely surprise you with a powered-off box - see the DANGER note
> on step 3. Neither is armed by
> default for this project (see
> [docs/09-appendix-b-boundaries.md §5](docs/09-appendix-b-boundaries.md#5-no-idle-alarm-no-timed-stop-the-watchdog-is-the-only-thing-that-will-ever-stop-this-box)),
> so this caveat only applies if you deliberately enabled one. See
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

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) defines the gates below.
**GitHub Actions is currently disabled for this repo** - a green checkmark will
not appear on a push or PR; the gates execute locally via `act` from a
machine-local pre-push hook that a clone on another machine does not have. Read
[docs/10 §Where CI actually runs](docs/10-testing-and-ci.md#where-ci-actually-runs-today)
before relying on a green push from somewhere else.

The gates: `shellcheck` on **every `*.sh` in the tree**, discovered by `find`
rather than hand-globbed - fixtures included, because
[`tests/fixtures/`](tests/fixtures/) is what decides which branch of a deploy
script a test actually exercises;
a **bash-3.2 lint** that fails the build on the bash-4-only `${var^^}` /
`${var,,}` expansions, which are a fatal parse error on the macOS `/bin/bash`
the operator runs these from;
an **executable-bit assertion** over the operator-run scripts, since the
runbooks invoke them as `./control-plane/NN-*.sh`;
**IAM policy JSON validation** of `control-plane/iam/*.json`, the documents
handed verbatim to AWS mid-deploy;
`actionlint` (pinned Docker tag) on the workflow YAML, which also lints the
bash embedded directly in workflow `run:` steps;
**every `tests/test_*.sh` suite** - discovered, not listed, so a new one is
gated the moment it lands (currently six: the auto-merge decision logic in
[`scripts/auto_merge_decision.sh`](scripts/auto_merge_decision.sh), the shared
predicates in `control-plane/lib/*.sh`, and the `00`/`02`/`03`/`04` deploy
scripts against the fake-AWS fixtures);
PSScriptAnalyzer + Pester on `in-guest/` (including the
[`in-guest/tests/`](in-guest/tests/) suites for the `Resolve-RenderActive`
completion-decision helper, `Watchdog.ps1`'s own pure helpers, the
`Stop-Sequence.ps1` return contract and `Test-Deployment.ps1`'s
destruction-relevant predicates;
PSScriptAnalyzer fails the build on any
Error/ParseError, and on a Warning too unless its rule is explicitly
allowlisted in `ci.yml`);
**`PSUseCompatibleSyntax` at `TargetVersions = 5.1, 7.0`** over `in-guest/`,
which is the *only* automated check that those scripts still parse on the
Windows PowerShell 5.1 the EC2 guest actually runs - everything else here is
pwsh 7, so a PS7-only construct passes every other gate and then takes down
`Config.ps1` on the box that matters;
and `ruff` + `pytest` on
[`lambda/max-lifetime-stop/`](lambda/max-lifetime-stop/). Run the Lambda tests
locally with:

```bash
python -m pip install -r lambda/max-lifetime-stop/requirements-dev.txt && python -m pytest lambda/ -q
```

Run the auto-merge decision tests locally with:

```bash
bash tests/test_auto_merge_logic.sh
```

Run the control-plane validation tests locally with:

```bash
bash tests/test_control_plane_validation.sh
```

Run the max-lifetime deployment scheduler tests locally with:

```bash
bash tests/test_deploy_max_lifetime_scheduler.sh
```

The Pester tests need PowerShell 7+ (`pwsh`). CI intentionally pins Pester
5.7.1 (never Pester 6+) because the suite uses Pester 5's CI interface:
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
| [docs/04-phase2-watchdog.md](docs/04-phase2-watchdog.md) | How the watchdog works, `CompletionSignal` (`WorkerOnly`/`GpuOnly`/`WorkerOrGpu`), why SYSTEM, `DebounceSec` tuning, and the incremental per-render upload's eligibility rule and blind window (CORRECTION 3, shipped 2026-07-28). |
| [docs/05-phase3-stop-sequence.md](docs/05-phase3-stop-sequence.md) | Event-driven stop: optional S3 sync, the Google Drive upload + ephemeral interlock, the misplaced-output recovery scan (ERROR CLASS A/B), optional SNS, DryRun, why `-Force` is safe, and the per-render incremental upload (CORRECTION 3, shipped 2026-07-28). |
| [docs/06-phase4-safety-net.md](docs/06-phase4-safety-net.md) | The idle alarm (`RenderActive` by default, legacy GPU sub-5% mode) and optional Lambda as reference material - **both opt-in and NOT armed for this project** (decided 2026-07-28) - plus the metric publisher, which keeps running as telemetry regardless. |
| [docs/07-phase5-notifications.md](docs/07-phase5-notifications.md) | Optional SNS notify, `sns:Publish` permission. |
| [docs/08-appendix-a-corrections.md](docs/08-appendix-a-corrections.md) | Eight bugs / wrong claims removed from the prior report. |
| [docs/09-appendix-b-boundaries.md](docs/09-appendix-b-boundaries.md) | Decided design boundaries (single-user GUI-only, one Export click, no robot) and why control-plane stop-attribution is impossible from the guest by default, plus the optional `05-grant-audit-reads.sh` remedy and its privilege trade-off. |
| [docs/10-testing-and-ci.md](docs/10-testing-and-ci.md) | What CI checks (including `actionlint`), the auto-merge-to-main workflow and its test suite, and how to run the Pester and Lambda pytest suites locally. |
| [docs/11-deploying-on-this-instance.md](docs/11-deploying-on-this-instance.md) | Instance-specific runbook: read-only prerequisite verification, fixing an IAM role-name mismatch and confirming shutdown behavior from an admin workstation, and safely arming `DryRun`. |
| [docs/12-empirical-findings.md](docs/12-empirical-findings.md) | Live-measured process topology, `neuroserver`/`ffmpeg` invocation arguments, and the NTFS directory-length-vs-`WriteTransferCount` evidence behind `Config.ps1`'s worker/stall/completion settings. |
| [docs/13-first-end-to-end-run.md](docs/13-first-end-to-end-run.md) | Forensic reconstruction of the first complete render -> upload-verify -> stop cycle, including the ffmpeg crash-and-retry and the unlock-gate timeout that preceded it. |
| [docs/14-second-end-to-end-run.md](docs/14-second-end-to-end-run.md) | Forensic reconstruction of the first cycle to run on the committed code: a 4 h 58 m / 9.84 GiB render, verified upload, and a clean stop with the guest-shutdown fallback proven unused. Also records the observability fixes it prompted. |
| [docs/15-third-end-to-end-run.md](docs/15-third-end-to-end-run.md) | Forensic reconstruction of the first cycle under full heartbeat/timestamp observability, including the 25-minute sub-5% GPU near-miss that drove the alarm's `RenderActive` re-key. |
| [docs/16-render-loss-incident.md](docs/16-render-loss-incident.md) | Forensic record of the 2026-07-28 render-loss incident: a crash-retry mux that silently dropped its configured output folder, an empty-`OutputDir` "safe to proceed" check that missed the contradiction, and the ~2.3 GB ephemeral-volume loss that followed. Also records the operator's recover-and-stop decision, the remediation that landed the same day, and (§I) a live counter-example plus two currently-open gaps in that remediation. |
