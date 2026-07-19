# 08 - Appendix A: Corrections (bugs / wrong claims removed)

[README](../README.md) - [Architecture](01-architecture.md) - [Phase 0](02-phase0-confirmations.md) - [Phase 1](03-phase1-instance-prep.md) - [Phase 2](04-phase2-watchdog.md) - [Phase 3](05-phase3-stop-sequence.md) - [Phase 4](06-phase4-safety-net.md) - [Phase 5](07-phase5-notifications.md)

A prior write-up of this design contained eight bugs / wrong claims. They are
recorded here - each as **the wrong claim** followed by **what is actually true** -
so they are not silently re-introduced into the code or the docs. The finalized
scripts already encode the corrected behavior; several of them carry a warning
comment at the exact spot the wrong version would have gone.

## 1. "The box needs `ec2:StopInstances` (and credentials) to stop itself."

**Wrong.** The primary stop is a plain **guest-OS shutdown**
(`Stop-Computer -Force`). Because `InstanceInitiatedShutdownBehavior=stop` is set
at the AWS control plane ([`01-set-shutdown-behavior.sh`](../control-plane/01-set-shutdown-behavior.sh)),
that shutdown **stops** the instance with **no AWS API call and no credentials on
the box**. The instance role grants only `cloudwatch:PutMetricData`;
`ec2:StopInstances` is *optional*, tag-scoped, and off by default.

## 2. "Detect completion with a fixed timer / sleep."

**Wrong.** Completion is **event-driven**. The watchdog decides "done" from the
**lifecycle of Topaz's child `ffmpeg` worker** plus a **file-unlock gate** on the
output directory - never a wall-clock countdown. A fixed timer would stop too
early on a long job or waste money on a short one. See
[`Watchdog.ps1`](../in-guest/Watchdog.ps1) and [Phase 2](04-phase2-watchdog.md).

## 3. "Key the idle alarm on `CPUUtilization`."

**Wrong.** CPU is **blind to GPU load** - a Topaz render can peg the GPU while the
CPU sits near idle, so a CPU-based alarm would **false-stop an active render**. The
alarm keys on the **custom `TopazRender/GPU` `GPUUtilization` metric**. The
correction is called out in a banner comment in
[`03-create-idle-alarm.sh`](../control-plane/03-create-idle-alarm.sh).

## 4. "Add an in-guest fallback timer (`Start-Job` + `Stop-EC2Instance`) as a backstop."

**Wrong.** Such a job lives **inside the very session being torn down**; when the
guest shuts down, the job dies with it and could never reliably fire. The real
out-of-band safety net is the **CloudWatch GPU-idle alarm**, which lives in the
control plane and never shares fate with the guest. The rejection is documented in
[`Stop-Sequence.ps1`](../in-guest/Stop-Sequence.ps1); the replacement is
[Phase 4](06-phase4-safety-net.md).

## 5. "Use the CloudWatch agent to collect NVIDIA GPU metrics on Windows."

**Wrong.** The unified CloudWatch agent's **NVIDIA GPU support is Linux-only**. On
this Windows box the metric must be produced by shelling out to `nvidia-smi` and
publishing with the AWS CLI on a schedule - which is what
[`Push-GpuMetric.ps1`](../in-guest/Push-GpuMetric.ps1) does. See
[Phase 4](06-phase4-safety-net.md).

## 6. "Connect over RDP."

**Wrong.** An RDP connect/disconnect reconfigures the display stack and can detach
the NVIDIA **WDDM** driver from the session, interrupting or degrading GPU work -
so a render can stall the moment the operator disconnects. The display protocol is
**Amazon DCV**, which keeps the GPU session intact across disconnect. Verified in
[Phase 0](02-phase0-confirmations.md).

## 7. "GUI up with no `ffmpeg` worker means the queue is complete - stop the box."

**Wrong.** "GUI up, no worker" is **also the normal pre-render state** (opening a
project, adding clips, configuring the export). Treating it as "complete" would
stop the instance **before the first render even begins**. The watchdog uses a
`$sawActivity` guard: it only arms the completion path **after** it has observed at
least one active render (worker and/or GPU, per `CompletionSignal`). See
[`Watchdog.ps1`](../in-guest/Watchdog.ps1) and [Phase 2](04-phase2-watchdog.md).

## 8. "Drive / detect Topaz via its command-line interface."

**Wrong.** The Topaz EULA **bans the CLI under a Personal License**. Nothing in
this pipeline invokes the Topaz CLI. The watchdog **observes only** - the GUI
process, its `ffmpeg` children, and the output folder on disk - and never calls
Topaz. This keeps the deployment single-user and GUI-only. See the license note in
the [README](../README.md) and the boundaries in
[Appendix B](09-appendix-b-boundaries.md).

---

If you extend this project, check any change against these eight. Re-introducing
one of them is a regression, not a feature.
