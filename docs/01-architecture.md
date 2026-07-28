# 01 - Architecture

[README](../README.md) - **Architecture** - [Phase 0](02-phase0-confirmations.md) - [Phase 1](03-phase1-instance-prep.md) - [Phase 2](04-phase2-watchdog.md) - [Phase 3](05-phase3-stop-sequence.md) - [Phase 4](06-phase4-safety-net.md) - [Phase 5](07-phase5-notifications.md)

## The whole picture

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


  OUT-OF-BAND FALLBACKS  (opt-in, NOT ARMED for this project -- see below)
  +-------------------------------+         +------------------------------+
  | Push-GpuMetric.ps1 (SYSTEM,   | put     | CloudWatch idle alarm        |
  | once/min): CIM worker query   | metric  | (telemetry only by default;  |
  | -> RenderActive (1/0);        | ----->  | NOT created/armed here --    |
  | nvidia-smi -> GPUUtilization% |         | opt-in via ENABLE_IDLE_ALARM)|
  +-------------------------------+         +------------------------------+

  OPTIONAL HARD CAP  (last-resort cost guard -- NOT DEPLOYED for this project)
  +------------------------------------------------------------------------+
  | EventBridge schedule --> max-lifetime-stop Lambda --> ec2:StopInstances |
  | fires when instance age >= MAX_LIFETIME_HOURS, regardless of GPU load   |
  +------------------------------------------------------------------------+
```

**On this project, exactly one of the three mechanisms below is armed: the
primary, in-guest one.** The operator decided on 2026-07-28 against any
idle-based auto-stop (see [Phase 4](06-phase4-safety-net.md) and
[Appendix B](09-appendix-b-boundaries.md)) and has not deployed the
max-lifetime Lambda. They are kept documented here as capabilities this
design supports, not as claims about this deployment's current state:

1. **Primary (in-guest, event-driven) - ARMED, the only sanctioned auto-stop:**
   `Watchdog.ps1` -> `Stop-Sequence.ps1` (which verifies the Google Drive
   upload) -> the `StopStrategy` plan (`ec2:StopInstances` first, guest
   shutdown as fallback, under the default `'Auto'`) -> instance stop. This is
   what fires on every clean job, and it is the *only* thing that stops this
   box. See [Phase 3](05-phase3-stop-sequence.md) for the full upload picture,
   including the ephemeral-upload interlock, the misplaced-output recovery
   scan added after the 2026-07-28 render-loss incident
   ([docs/16](16-render-loss-incident.md)), and the per-render incremental
   upload (CORRECTION 3, shipped 2026-07-28).
2. **Fallback (out-of-band, idle) - OPT-IN, NOT ARMED here.** The CloudWatch
   alarm on the custom `TopazRender/GPU` metric, if created
   (`ENABLE_IDLE_ALARM=1`), would stop the box after `IDLE_MINUTES` (default
   30) of sustained idle - by default keyed on `RenderActive` (no encoder
   worker process alive), with the legacy sub-5% `GPUUtilization` signal
   available via `IDLE_SIGNAL=gpu` (see [Phase 4](06-phase4-safety-net.md)).
   An idle signal cannot distinguish an abandoned box from an operator still
   setting up or a queue between two items, and the GPU-keyed version of this
   exact alarm came within five minutes of stopping a live, healthy render on
   2026-07-27 - which is why it is off by default for this project.
3. **Optional hard cap (out-of-band, wall-clock) - NOT DEPLOYED here.** The
   `max-lifetime-stop` Lambda would stop the box once it has *run* longer than
   a ceiling, regardless of GPU load, catching a job that stays "stuck busy"
   and never goes idle.

Layers 2 and 3 are intentionally uncorrelated in their failure modes when
armed - a crash that kills the primary path does not touch the alarm, and a
job that defeats the alarm (never idle) is still caught by the wall-clock cap.
With both off, that redundancy does not exist: a dead watchdog, an unopened
Topaz session, or a failed render is only ever noticed by a human. See
[Appendix B](09-appendix-b-boundaries.md) for that trade-off recorded
honestly, including the manual mitigations.

## Design principles (expanded)

### 1. The stop tries the API first, and keeps the credential-free guest shutdown as its fallback

`Stop-Sequence.ps1` follows an ordered `StopStrategy` plan
(`Resolve-StopPlan` in [`Config.ps1`](../in-guest/Config.ps1)) rather than a
single fixed action:

- **`Ec2ApiStop`** - call `ec2:StopInstances` against itself. The **only**
  action that *provably* ends billing.
- **`GuestShutdown`** - `Stop-Computer -Force` (equivalent to
  `shutdown /s /t 0`). Needs **no AWS credentials on the box** at all - what
  makes it a *stop* instead of a *terminate* is a one-time control-plane
  setting, `InstanceInitiatedShutdownBehavior=stop`:

  ```
  aws ec2 modify-instance-attribute --instance-initiated-shutdown-behavior stop
  ```

  (set by [`control-plane/01-set-shutdown-behavior.sh`](../control-plane/01-set-shutdown-behavior.sh)).
- **`'Auto'`** (the default) - tries `Ec2ApiStop` first and falls back to
  `GuestShutdown` if the API call is denied or does not take effect within
  `StopVerifySec`.

**Why the API leg was added, honestly.** The original design of this project
was exactly "no AWS credentials on the box, ever": a guest shutdown alone,
relying entirely on `InstanceInitiatedShutdownBehavior=stop`. That reasoning
still holds, and the guest-shutdown leg is **retained**, unconditionally, as
the fallback - it is what fires whenever the API call is denied. But a guest
shutdown only ends billing when that attribute *happens* to be `stop`, and
that fact **cannot be verified from inside the guest** without an extra
permission (`ec2:DescribeInstanceAttribute`) that the original zero-credential
design also declined to grant. Rather than ship an auto-stop pipeline that can
silently fail to stop billing with no way to detect it, this box now also
carries a narrowly-scoped, tag-conditioned `ec2:StopInstances` grant
(optional, `INCLUDE_EC2_STOP=1` at the control-plane level - see
[Phase 1](03-phase1-instance-prep.md)) and attempts it first, precisely
because it is the one action whose success is unambiguous.

Consequences:

- The instance role ([`02-create-iam-role.sh`](../control-plane/02-create-iam-role.sh))
  still grants only `cloudwatch:PutMetricData` by default; the
  `ec2:StopInstances` grant remains *optional* (`INCLUDE_EC2_STOP=1`) and
  tag-scoped (`AutoStopEligible=true`) - a deliberate trade-off, not silent
  scope creep. An operator who wants the original zero-credential posture can
  set `StopStrategy='GuestShutdown'` in `Config.ps1` and skip the grant
  entirely.
- The only OTHER AWS calls the box makes at stop time are the *optional*
  best-effort S3 sync and SNS publish, and a failure in either never blocks
  the power-off.
- See [docs/11-deploying-on-this-instance.md](11-deploying-on-this-instance.md)
  for how both legs were verified on this specific instance, and
  [Phase 3](05-phase3-stop-sequence.md) for the full ordering logic.

### 2. The fallback is out-of-band, when it is armed at all - and for this project, it is not

The GPU-idle alarm ([`03-create-idle-alarm.sh`](../control-plane/03-create-idle-alarm.sh))
lives in CloudWatch and would act through `arn:aws:automate:<region>:ec2:stop`, a
built-in alarm action that needs no IAM role and no code on the instance, fed
by `Push-GpuMetric.ps1`, with `treat-missing-data notBreaching` keeping it from
false-stopping on absent data if that publisher ever died. All of that remains
true as a design - but the operator decided, on 2026-07-28, not to run it:
an idle signal cannot tell "abandoned" apart from "still setting up" or
"between two queue items", and the then-current GPU-keyed build of this exact
alarm came within five minutes of stopping a live, healthy render the day
before. `03-create-idle-alarm.sh` is therefore opt-in
(`ENABLE_IDLE_ALARM=1`) rather than part of this project's own deployment
sequence; see [Phase 4](06-phase4-safety-net.md) and
[Appendix B](09-appendix-b-boundaries.md) for the full reasoning and the
accepted cost of running without it.

A rejected alternative, documented right in
[`Stop-Sequence.ps1`](../in-guest/Stop-Sequence.ps1): an in-guest fallback timer
(`Start-Job` + `Stop-EC2Instance`). Such a job lives inside the very session
being torn down; when the guest shuts down, the job dies with it and could never
fire. Any reliable fallback **must** live outside the guest - which is why, if
one is ever re-armed, it belongs in the control plane rather than the guest.
See [Appendix A](08-appendix-a-corrections.md).

### 3. Completion is event-driven, never a fixed timer

The watchdog never says "sleep N minutes, then assume done." It decides from
observable state:

- **Worker-descendant lifecycle.** Topaz spawns `neuroserver.exe` (a
  per-queue-item worker) as a child of the GUI, and that process in turn
  spawns `ffmpeg.exe` as **its own** child - so `ffmpeg` is a *grandchild* of
  the GUI, never a direct child (see
  [docs/12-empirical-findings.md](12-empirical-findings.md)). The watchdog
  therefore matches worker processes by **ancestry** (any descendant of a live
  Topaz GUI PID, to unlimited depth), not by direct parentage, and keeps
  counting a worker whose GUI parent crashed or was closed until the worker
  itself exits, so a dead GUI is never misread as "queue complete" mid-encode.
  "Queue complete" = no active render for `DebounceSec` (the debounce absorbs
  transient live-preview children and ordinary inter-clip lulls).
- **Stall detection.** Progress is the *union* of two signals: the output
  folder's byte total, and the matched workers' own cumulative disk I/O
  counters. The byte-total signal alone is unreliable on NTFS - a file's
  directory-entry length can sit frozen for many minutes while a writer holds
  it open, measured at 466 s straight on this deployment (see
  [docs/12-empirical-findings.md](12-empirical-findings.md)) - so only when
  *neither* signal has changed for `StallSec` is the job treated as stalled
  and the box stopped anyway.
- **File-unlock gate.** Before handing off to the stop step, the watchdog waits
  (up to `UnlockTimeoutMin`) for every output file - other than a `_temp`
  scratch file, anchored so a real deliverable merely containing that text is
  never skipped - to be openable with no sharing, i.e. nothing still holds a
  write handle. Only then does it power off, so a stop can never truncate a
  file mid-write.
- **Unreadable signals freeze, they never guess.** Both the worker-presence and
  GPU signals can come back "unknown this poll" (e.g. a transient CIM query
  failure); when that happens the watchdog freezes its idle/stall bookkeeping
  for that poll rather than risk misreading an outage as "no worker" (a false
  complete) or "stalled" (a false stall).

See [Phase 2](04-phase2-watchdog.md) for the full state machine.

### 4. The display protocol is Amazon DCV, not RDP

RDP reconfigures the display stack on connect/disconnect and can detach the
GPU's WDDM driver from the session, which interrupts (or degrades) GPU-accelerated
work. **Amazon DCV** keeps the GPU-bound session intact across disconnect, so the
operator can click Export, disconnect, and let the render run unattended. This
is verified in [Phase 0](02-phase0-confirmations.md) before anything is
automated.

## Where each concern lives

| Concern | Component | Plane |
|---------|-----------|-------|
| Turn guest shutdown into an instance stop | `InstanceInitiatedShutdownBehavior=stop` | Control plane (once) |
| Detect render complete / stalled | `Watchdog.ps1` (SYSTEM task) | In-guest |
| Perform the stop | `Stop-Sequence.ps1` -> `StopStrategy` plan (`ec2:StopInstances`, falling back to `Stop-Computer -Force`) | In-guest |
| Publish GPU/render telemetry (no alarm acts on it) | `Push-GpuMetric.ps1` (SYSTEM task) | In-guest |
| Idle safety net (opt-in, NOT armed for this project - 2026-07-28 decision) | `topaz-gpu-idle-autostop-<instance-id>` alarm (per-instance) | Control plane |
| Wall-clock cap (optional, NOT deployed for this project) | `topaz-max-lifetime-stop-<instance-id>` Lambda (per-instance) | Control plane (optional) |
| Least-privilege identity | `topaz-render-instance-role` | Control plane |

Continue to [Phase 0 - confirmations](02-phase0-confirmations.md).
