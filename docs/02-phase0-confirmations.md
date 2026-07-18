# 02 - Phase 0: Confirmations and the golden AMI

[README](../README.md) - [Architecture](01-architecture.md) - **Phase 0** - [Phase 1](03-phase1-instance-prep.md) - [Phase 2](04-phase2-watchdog.md) - [Phase 3](05-phase3-stop-sequence.md) - [Phase 4](06-phase4-safety-net.md) - [Phase 5](07-phase5-notifications.md)

Phase 0 is all manual observation. Do not install or register anything yet. The
goal is to prove the instance behaves the way the automation assumes, capture
the three facts the watchdog is keyed on, then freeze that known-good state into
a golden AMI. Everything downstream trusts these observations.

## 1. Confirm the render survives a disconnect (DCV, not RDP)

The operator's whole workflow is "click Export once, then disconnect." That only
works if disconnecting does not disturb the GPU render.

- **Use Amazon DCV as the display protocol.** DCV keeps the GPU-bound console
  session intact when you disconnect, so `ffmpeg` keeps encoding while nobody is
  attached.
- **Do not use RDP.** An RDP connect/disconnect reconfigures the display stack
  and can detach the NVIDIA WDDM driver from the session, interrupting or
  degrading GPU work. A render that was fine while you watched can stall the
  instant you disconnect over RDP.

**Test to run:** start a real export, disconnect the DCV session, wait, reconnect.
Confirm the output file kept growing the whole time and the job completed. If it
stalled on disconnect, fix the display path before going further.

## 2. Disable the Microsoft Basic Display Adapter so NVIDIA WDDM binds

On a fresh Windows Server GPU instance the generic **Microsoft Basic Display
Adapter** can hold the display, leaving the NVIDIA GPU without a WDDM display
binding - which is exactly what GPU-accelerated Topaz + DCV need.

- In Device Manager, **disable the Microsoft Basic Display Adapter** so the
  NVIDIA driver binds in **WDDM** mode.
- Confirm with `nvidia-smi` that the GPU is present and reporting, and that the
  driver mode is WDDM (not TCC), so the interactive session can use it.

This step is also why the metric publisher can read a real GPU utilization number
later - the GPU must be visible to `nvidia-smi` in the interactive context.

## 3. Observe the three facts the watchdog is keyed on

Open Topaz, run one real export, and write down exactly what you see. These map
one-to-one to the `OPERATOR SETTINGS` block in
[`in-guest/Config.ps1`](../in-guest/Config.ps1).

| Observe | Why | Config key | Default |
|---------|-----|-----------|---------|
| The **Topaz GUI process name** | The watchdog matches it with a CIM `LIKE` pattern; the `ffmpeg` workers are found as *children* of this process. | `TopazNameLike` | `'Topaz Video%'` (matches both `Topaz Video.exe` and `Topaz Video AI.exe`) |
| The **output directory** Topaz writes finished exports into | "No growth here while a worker is alive" is the stall signal; the file-unlock gate scans this folder. | `OutputDir` | `'D:\Exports'` |
| The **scratch / temp file naming** Topaz leaves behind | Files whose name contains this marker are excluded from the unlock check, so leftover scratch files never block the stop. | `TempMarker` | `'_temp'` |

Concretely, while an export runs, check:

- **Process tree:** confirm the GUI spawns `ffmpeg.exe` children during encode.
  In PowerShell: `Get-CimInstance Win32_Process -Filter "Name = 'ffmpeg.exe'"`
  and confirm the `ParentProcessId` is the Topaz GUI PID. This parent/child
  relationship is the core signal (see [Phase 2](04-phase2-watchdog.md)).
- **Output growth:** watch the output folder's byte total climb while encoding.
- **Scratch files:** note any partial/temporary files created during the render
  and whether their names contain `_temp` (or something else - update
  `TempMarker` to match).

If Topaz on your machine spawns transient `ffmpeg` children for the **live
preview** (not just the queued export), note roughly how long they live - you may
need to raise `DebounceSec` (see [Phase 2](04-phase2-watchdog.md)).

## 4. Bake a golden AMI (Sysprep)

Once the box is proven - DCV disconnect-safe, NVIDIA WDDM bound, Topaz installed
and confirmed unwatermarked, `nvidia-smi` and `aws` on PATH - capture it so you
never have to redo Phase 0:

- **Generalize with Sysprep** (the EC2 `EC2Launch`/Sysprep flow) so the image can
  launch fresh instances cleanly.
- Create the AMI from the sysprepped instance.
- Future runs launch from this golden AMI, then apply Phases 1-4.

> Baking the AMI **before** wiring up AutoAdminLogon keeps any stored logon
> password out of the shared image. See the AutoAdminLogon caveat in
> [Phase 1](03-phase1-instance-prep.md).

## Phase 0 exit checklist

- [ ] Render keeps running after a DCV disconnect (RDP not used).
- [ ] Microsoft Basic Display Adapter disabled; NVIDIA driver bound in WDDM.
- [ ] `nvidia-smi` reports the GPU in the interactive session.
- [ ] Real Topaz process name recorded -> `TopazNameLike`.
- [ ] Output directory recorded -> `OutputDir`.
- [ ] Scratch/temp naming recorded -> `TempMarker`.
- [ ] Topaz confirmed unwatermarked (see the license note in the [README](../README.md)).
- [ ] Golden AMI created via Sysprep.

Continue to [Phase 1 - instance prep](03-phase1-instance-prep.md).
