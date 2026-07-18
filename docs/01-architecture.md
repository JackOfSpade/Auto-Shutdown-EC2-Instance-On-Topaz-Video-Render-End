# 01 - Architecture

[README](../README.md) - **Architecture** - [Phase 0](02-phase0-confirmations.md) - [Phase 1](03-phase1-instance-prep.md) - [Phase 2](04-phase2-watchdog.md) - [Phase 3](05-phase3-stop-sequence.md) - [Phase 4](06-phase4-safety-net.md) - [Phase 5](07-phase5-notifications.md)

## The whole picture

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

There are three independent ways the box can stop, ranked by how normal they are:

1. **Primary (in-guest, event-driven):** `Watchdog.ps1` -> `Stop-Sequence.ps1`
   -> guest shutdown -> instance stop. This is what fires on every clean job.
2. **Fallback (out-of-band, GPU-idle):** the CloudWatch alarm on the custom GPU
   metric stops the box after 30 minutes of sustained sub-5% GPU. This fires
   only when the primary path failed to.
3. **Optional hard cap (out-of-band, wall-clock):** the `max-lifetime-stop`
   Lambda stops the box once it has *run* longer than a ceiling, regardless of
   GPU load. This catches a job that stays "stuck busy" and never goes idle.

The three layers are intentionally uncorrelated in their failure modes. A crash
that kills the primary path does not touch the alarm; a job that defeats the
alarm (never idle) is still caught by the wall-clock cap.

## Design principles (expanded)

### 1. The primary stop needs no AWS credentials on the box

The instance stops itself by **shutting down its own OS** - a `Stop-Computer
-Force` from `Stop-Sequence.ps1`, equivalent to `shutdown /s /t 0`. What makes
that a *stop* instead of a *terminate* is a one-time control-plane setting:

```
aws ec2 modify-instance-attribute --instance-initiated-shutdown-behavior stop
```

(set by [`control-plane/01-set-shutdown-behavior.sh`](../control-plane/01-set-shutdown-behavior.sh)).

Consequences:

- No `ec2:StopInstances` permission is required on the box for the normal path.
- No AWS access keys are stored on the instance. The instance role
  ([`02-create-iam-role.sh`](../control-plane/02-create-iam-role.sh)) grants only
  `cloudwatch:PutMetricData` for the metric publisher; the `ec2:StopInstances`
  grant is optional (`INCLUDE_EC2_STOP=1`) and tag-scoped, provided only for
  operators who want a belt-and-suspenders API stop path.
- The only AWS calls the box makes at stop time are the *optional* best-effort
  S3 sync and SNS publish, and a failure in either never blocks the power-off.

### 2. The fallback is out-of-band

The GPU-idle alarm ([`03-create-idle-alarm.sh`](../control-plane/03-create-idle-alarm.sh))
lives in CloudWatch and acts through `arn:aws:automate:<region>:ec2:stop`, a
built-in alarm action that needs no IAM role and no code on the instance. It is
fed by `Push-GpuMetric.ps1`, but even if that publisher dies, the alarm's
`treat-missing-data notBreaching` keeps it from false-stopping on absent data.

A rejected alternative, documented right in
[`Stop-Sequence.ps1`](../in-guest/Stop-Sequence.ps1): an in-guest fallback timer
(`Start-Job` + `Stop-EC2Instance`). Such a job lives inside the very session
being torn down; when the guest shuts down, the job dies with it and could never
fire. Any reliable fallback **must** live outside the guest. See
[Appendix A](08-appendix-a-corrections.md).

### 3. Completion is event-driven, never a fixed timer

The watchdog never says "sleep N minutes, then assume done." It decides from
observable state:

- **Child-`ffmpeg` lifecycle.** Topaz spawns `ffmpeg.exe` children to encode a
  queued job. The watchdog matches `ffmpeg` processes whose `ParentProcessId`
  is a live Topaz GUI PID. "Queue complete" = GUI still up, but **no** such
  child for `DebounceSec` (the debounce absorbs transient live-preview
  children).
- **Stall detection.** If an `ffmpeg` child is alive but the output folder has
  not grown for `StallSec`, the job is treated as stalled and the box stops
  anyway.
- **File-unlock gate.** Before handing off to the stop step, the watchdog waits
  (up to `UnlockTimeoutMin`) for every non-`_temp` output file to be openable
  with no sharing - i.e. nothing still holds a write handle. Only then does it
  power off, so a stop can never truncate a file mid-write.

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
| Perform the stop | `Stop-Sequence.ps1` -> `Stop-Computer -Force` | In-guest |
| Publish GPU utilization | `Push-GpuMetric.ps1` (SYSTEM task) | In-guest |
| Idle safety net | `topaz-gpu-idle-autostop` alarm | Control plane |
| Wall-clock cap | `topaz-max-lifetime-stop` Lambda | Control plane (optional) |
| Least-privilege identity | `topaz-render-instance-role` | Control plane |

Continue to [Phase 0 - confirmations](02-phase0-confirmations.md).
