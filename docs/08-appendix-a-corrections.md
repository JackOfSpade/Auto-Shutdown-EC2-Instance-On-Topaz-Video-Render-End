# 08 - Appendix A: Corrections (bugs / wrong claims removed)

[README](../README.md) - [Architecture](01-architecture.md) - [Phase 0](02-phase0-confirmations.md) - [Phase 1](03-phase1-instance-prep.md) - [Phase 2](04-phase2-watchdog.md) - [Phase 3](05-phase3-stop-sequence.md) - [Phase 4](06-phase4-safety-net.md) - [Phase 5](07-phase5-notifications.md)

A prior write-up of this design contained eight bugs / wrong claims. They are
recorded here - each as **the wrong claim** followed by **what is actually true** -
so they are not silently re-introduced into the code or the docs. The finalized
scripts already encode the corrected behavior; several of them carry a warning
comment at the exact spot the wrong version would have gone.

## 1. "The box needs `ec2:StopInstances` (and credentials) to stop itself."

**Wrong, as originally designed.** The primary stop was a plain **guest-OS
shutdown** (`Stop-Computer -Force`). Because
`InstanceInitiatedShutdownBehavior=stop` is set at the AWS control plane
([`01-set-shutdown-behavior.sh`](../control-plane/01-set-shutdown-behavior.sh)),
that shutdown **stops** the instance with **no AWS API call and no credentials
on the box**. The instance role granted only `cloudwatch:PutMetricData`;
`ec2:StopInstances` was *optional*, tag-scoped, and off by default.

> **Update: this reasoning is retained, but the design has since evolved.**
> `Config.ps1`'s `StopStrategy` now defaults to `'Auto'`, which tries
> `ec2:StopInstances` **first** and falls back to the credential-free guest
> shutdown above only if that call is denied or does not take effect - because
> a guest shutdown only ends billing when `InstanceInitiatedShutdownBehavior`
> happens to be `stop`, and that fact cannot be verified from inside the guest
> without an extra permission. This box therefore does now hold a
> narrowly-scoped, tag-conditioned `ec2:StopInstances` grant that the original
> design deliberately avoided - an honest trade-off, not a silent regression
> of the correction above. The guest-shutdown leg is unconditionally retained
> as the fallback. See [docs/01-architecture.md](01-architecture.md) and
> [Phase 3](05-phase3-stop-sequence.md) for the full reasoning.

## 2. "Detect completion with a fixed timer / sleep."

**Wrong.** Completion is **event-driven**. The watchdog decides "done" from the
**lifecycle of Topaz's encoder-worker descendants** (`neuroserver.exe`/
`ffmpeg.exe`, matched by ancestry, not direct parentage - see
[Phase 2](04-phase2-watchdog.md)) plus a **file-unlock gate** on the output
directory - never a wall-clock countdown. A fixed timer would stop too early
on a long job or waste money on a short one. See
[`Watchdog.ps1`](../in-guest/Watchdog.ps1) and [Phase 2](04-phase2-watchdog.md).

## 3. "Key the idle alarm on `CPUUtilization`."

**Wrong.** CPU is **blind to GPU load** - a Topaz render can peg the GPU while the
CPU sits near idle, so a CPU-based alarm would **false-stop an active render**. The
alarm keys on the **custom `TopazRender/GPU` `GPUUtilization` metric**. The
correction is called out in a banner comment in
[`03-create-idle-alarm.sh`](../control-plane/03-create-idle-alarm.sh).

> **Update: this specific point has itself been superseded.**
> `GPUUtilization` is no longer what the alarm keys on by default - it was
> measured wrong in **both** directions on this box. A confirmed-healthy 4K
> render read `GPUUtilization` under 5% for 25 consecutive one-minute samples
> on 2026-07-27, five minutes short of breaching the 30-minute window, on a
> box that was genuinely rendering. And a connected Amazon DCV session encodes
> the remote display on the same GPU, holding `GPUUtilization` at 14-58% with
> nothing rendering at all, so the alarm could never fire while anyone was
> connected. Wrong in both directions is not a safety net. The alarm now
> defaults (`IDLE_SIGNAL=render`) to the new `RenderActive` metric (is an
> encoder worker process alive) instead; `GPUUtilization` is kept only as
> telemetry, with the old sub-5% behavior still available via
> `IDLE_SIGNAL=gpu`. See [docs/15 §K](15-third-end-to-end-run.md) for the
> measured streak and [Phase 4](06-phase4-safety-net.md) for the full
> reasoning.
>
> **Second update (2026-07-28): superseded again, more fundamentally.** Re-
> keying the signal narrowed the false-stop hazard but did not remove it
> structurally - no idle/presence signal can tell "abandoned" apart from "the
> operator is mid-setup" or "the queue is between two items". The operator
> decided, on 2026-07-28, to stop arming this alarm **at all** by default:
> `control-plane/03-create-idle-alarm.sh` now refuses to create or update
> anything unless explicitly passed `ENABLE_IDLE_ALARM=1`, and this box's own
> alarm has been deleted. The sole sanctioned auto-stop for this project is
> now watchdog-completion -> verified upload -> `ec2:StopInstances`. See
> [Phase 4](06-phase4-safety-net.md) and
> [docs/09 §5](09-appendix-b-boundaries.md#5-no-idle-alarm-no-timed-stop-the-watchdog-is-the-only-thing-that-will-ever-stop-this-box)
> for the accepted cost of running this way.

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

## 7. "GUI up with no active worker means the queue is complete - stop the box."

**Wrong.** "GUI up, no worker" is **also the normal pre-render state** (opening a
project, adding clips, configuring the export). Treating it as "complete" would
stop the instance **before the first render even begins**. The watchdog uses a
`$sawActivity` guard: it only arms the completion path **after** it has observed at
least one active render (worker and/or GPU, per `CompletionSignal`). See
[`Watchdog.ps1`](../in-guest/Watchdog.ps1) and [Phase 2](04-phase2-watchdog.md).

## 8. "Drive / detect Topaz via its command-line interface."

**Wrong.** The Topaz EULA **bans the CLI under a Personal License**. Nothing in
this pipeline invokes the Topaz CLI. The watchdog **observes only** - the GUI
process, its encoder-worker descendants (`neuroserver.exe`/`ffmpeg.exe`,
matched by ancestry), and the output folder on disk - and never calls Topaz.
This keeps the deployment single-user and GUI-only. See the license note in
the [README](../README.md) and the boundaries in
[Appendix B](09-appendix-b-boundaries.md).

---

If you extend this project, check any change against these eight. Re-introducing
one of them is a regression, not a feature.
