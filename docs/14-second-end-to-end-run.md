# 14 - Second End-to-End Run: A Five-Hour Render, Verified Upload, and a Clean Stop

[README](../README.md) - [Architecture](01-architecture.md) - [Phase 0](02-phase0-confirmations.md) - [Phase 1](03-phase1-instance-prep.md) - [Phase 2](04-phase2-watchdog.md) - [Phase 3](05-phase3-stop-sequence.md) - [Phase 4](06-phase4-safety-net.md) - [Phase 5](07-phase5-notifications.md) - [Appendix A](08-appendix-a-corrections.md) - [Appendix B](09-appendix-b-boundaries.md) - [Testing & CI](10-testing-and-ci.md) - [Deploying on this instance](11-deploying-on-this-instance.md) - [Empirical Findings](12-empirical-findings.md) - [First End-to-End Run](13-first-end-to-end-run.md) - **Second End-to-End Run**

## Method and provenance

This is a **read-only forensic reconstruction**, written the same way as
[docs/13](13-first-end-to-end-run.md). Nothing was started, stopped, killed, or modified to
produce it. Every fact below is a direct quote or direct read of:
`C:\topaz-autostop\logs\{watchdog,stop,rclone,scratch,metric,install,register,preflight,
test,timedstop}.log`, the Topaz `.tzlog` covering the render, the Windows System and
Application event logs, `(Get-CimInstance Win32_OperatingSystem).LastBootUpTime`, one
read-only `aws ec2 describe-instances`, `Get-Disk`/`Get-Volume`, and one read-only
`rclone lsl gdrive:temp`.

**Why this run is worth a second document.** [docs/13](13-first-end-to-end-run.md)
reconstructed the `06:14:58` cycle, which was the first to complete the full
render -> upload -> verify -> stop path. This run is the first to do so **on the code as
committed**, and it is a materially harder exercise of it:

| | First run (docs/13) | This run |
|---|---|---|
| Render length | 3 min 56 s | **4 h 58 m 25 s** |
| Output size | 1.26 GiB | **9.84 GiB** |
| Export attempts | 2 (one ffmpeg crash, auto-retried) | **1, no crash** |
| Unlock gate | timed out on the earlier cycle | **passed instantly** |
| Stop | accepted | **accepted, no escalation** |
| WARN/ERROR in window | none | **none** |

Three things were established from the logs before treating this as "the" run, rather than
assumed:

1. **The watchdog process that supervised this render was loaded from the current code.**
   `install.log`'s last entry is `[2026-07-27 07:37:53]`, and `watchdog.log`'s operative
   session banner is `[2026-07-27 07:37:57]` - four seconds later. This matters because
   PowerShell does not reload a running script: three earlier watchdog sessions
   (`06:25:03`, `07:04:41`, `07:31:49`) were superseded before any GUI was detected, and
   only the `07:37:57` session carried the cycle through. All eight deployed in-guest
   scripts were additionally confirmed byte-identical (SHA-256) to the repository working
   tree.
2. **This stop was watchdog-driven, not a manual invocation.** `Invoking Stop-Sequence.ps1`
   appears exactly three times in the whole of `watchdog.log` - `03:00:31`, `06:14:58`, and
   `12:51:35` - and each is immediately preceded by its own
   `Render QUEUE considered COMPLETE`. The `12:51:35` occurrence is this run.
3. **`stop.log` contains one other block in between that is NOT a fault.** A
   `REFUSING TO STOP` block at `07:04:01`-`07:04:02` is the deliberately induced failure
   described in commit `4444248` ("rclone.conf was moved aside"), logged 84 seconds before
   that commit was authored. It is evidence the interlock works, not evidence it fired in
   anger.

---

## A. The render, from Topaz's own log

Source: `2026-07-27-07-44-49-Main.tzlog` (3,207,636 bytes, 33,396 lines, last written
`12:54:40`). A short preceding log, `2026-07-27-07-43-40-Main.tzlog`, records Topaz
starting at `07:43:40` and tearing itself down cleanly by `07:44:43` - an ordinary restart,
not a crash - before the session that did the work.

| Time (Topaz clock) | Event |
|---|---|
| `07:47:38.489` | `Trying to open the file "D:/SDR_Render_video.mp4" false` |
| `07:47:38.494` | `Input #0, mov,mp4,m4a,3gp,3g2,mj2` - 3840x2160 HEVC 8-bit, 24 fps, `Duration 00:02:00.87` |
| `07:48:11.225` | `EventTracker: Video Export Started {"models":["slp-2.5"], ... "output-path D:/SDR_Render_video_638940915.mov" ... "cleanupPass":"...D:/Renders/SDR_Render_video_slp.mov"}` |
| `07:48:11.294` | `Runner process started 25 CMD: ...neuroserver --once --input-path D:/SDR_Render_video.mp4 --output-path D:/SDR_Render_video_638940915.mov --start-frame-idx 0 --end-frame-idx 2898 ... --filters [{"model": "slp-25"}] --output-width 3840 --output-height 2160 --upscale-factor 1 --ffmpeg-encoding -c:v dnxhd -pix_fmt yuv422p10le` |
| `07:48:37`-`12:37:39` | Model load, then per-frame diffusion compute: `[DiT Timing SERIALIZED] Load: Nms \| Compute: ~26000ms \| Total: ~26000ms`, repeated for 2,899 frames |
| **`12:45:46.378`** | `process exited: 25 0 0` - the enhance pass exits **cleanly** |
| `12:45:46.384` | Mux pass starts: `ffmpeg -i D:/SDR_Render_video_638940915.mov -i D:/SDR_Render_video.mp4 ... -c:v copy -map 0:v -map 1:a:0 ... D:/Renders/SDR_Render_video_slp.mov` |
| **`12:46:36.113`** | `process exited: 25 0 0` - the mux exits **cleanly**; the intermediate is deleted (`Going to delete path: "D:/SDR_Render_video_638940915.mov"`) |

**One export, one attempt, no crash, no retry.** The whole log contains exactly two
`process exited` lines and both are `0 0`. The strings `process exited error occurred`,
`No space left on device`, `Conversion failed`, and even the bare word `failed` are
**NOT OBSERVED** anywhere in the file. This is a direct contrast with
[docs/13 §A](13-first-end-to-end-run.md#a-did-the-render-complete-successfully), where
ffmpeg sub-process 18 crashed and Topaz auto-retried.

ffmpeg's own closing summary for the mux:

```
video:10308844KiB audio:4722KiB subtitle:0KiB other streams:0KiB global headers:0KiB muxing overhead: 0.000702%
frame= 2899 fps= 59 q=-1.0 Lsize=10313638KiB time=00:02:00.79 bitrate=699463.2kbits/s speed=2.44x elapsed=0:00:49.51
```

**Duration:** export start `07:48:11.225` -> final process exit `12:46:36.113` =
**4 h 58 m 24.888 s**, of which the mux was 49.7 s. The 225 `WARNING` lines in the log are
Qt/QML UI noise (`DynamicTabBar.qml: Unable to assign [undefined] to QString` and similar);
none falls inside the render window.

## B. Did the watchdog arm correctly?

`watchdog.log`, `[2026-07-27 07:43:43]`:

```
Topaz GUI detected. Monitoring render queue (poll=15s, debounce=300s, stall=1800s, workers matching [neuroserver.exe, ffmpeg.exe] by ancestry).
```

Arming was **not** clean on the first attempt, and correctly so. A short-lived helper
armed briefly at `07:44:05` (`Render active (worker=True gpu=n/a, arming 15s/90s)`), then
vanished, and the log fell back to twelve consecutive polls of

```
Topaz GUI up but no render has started yet (idle=15s..180s, worker=False gpu=n/a). Waiting for 90s of sustained worker activity before arming completion.
```

between `07:44:40` and `07:47:26` - i.e. `ArmSec` did exactly the job
[Config.ps1](../in-guest/Config.ps1) describes, refusing to arm on GUI noise. The real
worker (`neuroserver`, started `07:48:11.294`) then earned its 90 s, and unlike the first
run there **is** an explicit armed line to quote, at `[2026-07-27 07:50:01]`:

```
Render active (worker=True gpu=n/a, armed) but NO progress on either signal (stall=15s / 1800s, outputBytes=0, workerIoBytes=171474595).
```

**Reading that line correctly matters.** `stall=15s` does not mean the render was stalling;
it means the *previous* poll detected progress and reset the counter to 0, and this one
did not. [Watchdog.ps1:900](../in-guest/Watchdog.ps1#L900) logs **only** when
`-not $state.BytesChanged`, so a healthy, progressing poll writes nothing at all. The
`workerIoBytes=` figure is the current cumulative counter, not a delta.

Three no-progress runs occurred all cycle, none remotely close to the limit:

| Run | Window | Peak stall | Explanation |
|---|---|---|---|
| 1 | `07:50:01`-`07:54:03` (17 polls) | `255s / 1800s` | `neuroserver` loading the diffusion model; `outputBytes=0` throughout |
| 2 | `07:55:18`-`07:55:33` | `30s / 1800s` | `workerIoBytes` 171,474,595 -> 201,189,595 |
| 3 | `12:44:33`-`12:44:48` | `30s / 1800s` | end of compute; `workerIoBytes` had reached 114,372,836,050 |

**Peak stall all run was 255 s against an 1800 s limit - 14 %.** The stall path has still
never fired in production on this box.

## C. The four-hour-forty-nine-minute silence

From `[2026-07-27 07:55:33]` to `[2026-07-27 12:44:33]` **`watchdog.log` contains no lines
at all.** This is by design (§B: progressing polls log nothing) and `workerIoBytes` growing
from 201 MB to 114 GB across the gap proves the render was progressing throughout. It is
nonetheless the longest silence in the file by a wide margin, and it is a genuine
debuggability weakness: for four hours and forty-nine minutes the log offers no positive
evidence the watchdog was alive. A working watchdog and one that had crashed, wedged on a
hung CIM query, or been killed all produce **exactly the same evidence** - nothing - and
they do so across the longest and least-supervised window in the whole cycle.

**Fixed after this run** by a heartbeat that bounds the silence (§K.5). Had it been in
place, this stretch would have carried ~59 lines instead of zero.

## D. Queue completion and the unlock gate

The worker disappeared between the `12:46:34` and `12:46:49` polls (the mux exited at
`12:46:36.113`). Idle then accrued **twenty consecutive polls with no gaps and no resets**:

```
[2026-07-27 12:46:49] No active render (idle=15s / 300s debounce, worker=False gpu=n/a).
   ... 18 further polls, +15s each ...
[2026-07-27 12:51:35] No active render (idle=300s / 300s debounce, worker=False gpu=n/a).
[2026-07-27 12:51:35] No active render for 300s (>= debounce). Render QUEUE considered COMPLETE.
```

300 s / 15 s = 20 polls, first at `idle=15s`, last at `idle=300s`: **exactly `DebounceSec`,
to the second.** (One tick ran 16 s rather than 15 - ordinary timer jitter; the `idle`
value still stepped by exactly 15.)

The unlock gate passed in the same second:

```
[2026-07-27 12:51:35] Reason='completed'. Waiting up to 5 min for output files to unlock.
[2026-07-27 12:51:35] All output files are unlocked.
```

As in [docs/13 §D](13-first-end-to-end-run.md#d-did-the-unlock-gate-pass-or-time-out), this
works because `OutputDir` (`D:\Renders`) holds only the finished `.mov` and is disjoint from
Topaz's working files.

## E. *** DID THE UPLOAD RUN AND VERIFY? ***

**Yes.** `stop.log`:

```
[2026-07-27 12:51:35] Stop sequence invoked (reason=completed, dryRun=False).
[2026-07-27 12:51:35] Uploading 1 file(s), 9.84 GB, from 'D:\Renders' to 'gdrive:temp' (reason=completed). This MUST finish before the instance may stop.
[2026-07-27 12:54:20] rclone copy completed. See 'C:\topaz-autostop\logs\rclone.log' for transfer detail.
[2026-07-27 12:54:38] rclone check VERIFIED every file in 'D:\Renders' is present and intact at 'gdrive:temp'.
[2026-07-27 12:54:38] Upload verified: 1 file(s), 9.84 GB now safely in 'gdrive:temp'. Safe to stop.
```

`rclone.log`'s independent record:

```
2026/07/27 12:52:38 ... Transferred: 3.572 GiB / 9.836 GiB, 36%, ... ETA 1m39s
2026/07/27 12:53:38 ... Transferred: 7.424 GiB / 9.836 GiB, 75%, ... ETA 39s
2026/07/27 12:54:20 INFO  : SDR_Render_video_slp.mov: Copied (new)
Transferred:            9.836 GiB / 9.836 GiB, 100%, 59.735 MiB/s, ETA 0s
Transferred:            1 / 1, 100%
Elapsed time:      2m41.8s

2026/07/27 12:54:20 INFO  : Using md5 for hash comparisons
2026/07/27 12:54:38 NOTICE: Google drive root 'temp': 0 differences found
2026/07/27 12:54:38 NOTICE: Google drive root 'temp': 1 matching files
Elapsed time:        17.9s
```

**Timing:** upload + verify spanned `12:51:35` -> `12:54:38` = **3 min 3 s**; the copy alone
was 2 m 41.8 s at 59.735 MiB/s, and the md5 verification pass a further 17.9 s. Transfer
progress is monotonic (36 % -> 75 % -> 100 %) with no restarts or retries.

**Chain of custody closes exactly.** Four independent sources agree on the same file:

| Source | Value |
|---|---|
| ffmpeg's own summary | `Lsize=10313638KiB` -> 10,561,165,312 (KiB-rounded) |
| `stop.log` | `1 file(s), 9.84 GB` |
| `rclone` copy + check | `9.836 GiB`, `1 / 1`, `0 differences found` |
| `rclone lsl gdrive:temp` (live) | **10,561,165,286 bytes** |

The 26-byte discrepancy is ffmpeg rounding to whole KiB: 10,561,165,286 / 1024 =
10,313,637.97, which it reports as `10313638KiB`. **The bytes in Drive are the bytes ffmpeg
wrote.**

## F. Was the stop accepted, and did it escalate?

Accepted, with no escalation:

```
[2026-07-27 12:54:38] Stopping now (reason=completed). StopStrategy='Auto', plan=[Ec2ApiStop -> GuestShutdown].
[2026-07-27 12:54:40] ec2:StopInstances accepted for i-029f35d589bec9b9c. The instance should transition to 'stopping' shortly.
[2026-07-27 12:54:40] Waiting up to 300s for the instance to actually go down.
```

That is the **last line of `stop.log`**. On the first run the equivalent absence was read as
suggestive; here it can be settled outright. Windows recorded the power-off at
**`12:54:42`** (§G) - **2 seconds** after the accepted API call. The `GuestShutdown`
fallback is gated behind `Start-Sleep -Seconds $cfg.StopVerifySec` and a WARN line at
[Stop-Sequence.ps1:238-241](../in-guest/Stop-Sequence.ps1#L238-L241), i.e. it cannot be
reached until 300 s have elapsed and the WARN has been written. Neither happened.
**`Stop-Computer -Force` provably never ran**; AWS's ACPI shutdown request tore the process
down inside its own wait.

This is worth stating plainly because Windows itself cannot distinguish the two paths -
see §G.

## G. Independent confirmation that the box really stopped

**Windows' own records** (System event log) corroborate a clean, orderly shutdown:

| Event | Time | Detail |
|---|---|---|
| `1074` User32 | `12:54:42` | `winlogon.exe ... on behalf of user NT AUTHORITY\SYSTEM ... Reason Code: 0x500ff, Shutdown Type: power off` |
| `6006` EventLog | `12:54:43` | Event log service stopped - clean shutdown marker |
| `13` Kernel-General | `12:54:48.968` | `The operating system is shutting down at system time 2026-07-27T12:54:48.968210500Z` (concurrent Kernel-Power `109`, `Reason: Kernel API`) |
| `12` Kernel-General | `13:25:35.500` | `The operating system started` - Kernel-Boot `27` boot type `0x0` (cold boot, not a hibernate resume) |
| `6005` EventLog | `13:25:40` | Event log service started |

**`6008` (unexpected shutdown) and Kernel-Power `41` (dirty shutdown) are NOT OBSERVED
anywhere on the day** - the strongest available evidence against a hard power-cut. The
service-stop cascade to kernel halt took **6 seconds**, single-pass, no retries.

**Important limitation, recorded so nobody re-derives it:** Event `1074` attributes this
shutdown to `winlogon.exe`/SYSTEM with reason `0x500ff` - *byte-for-byte identical* to the
`06:15:27` shutdown from the previous cycle. Windows produces that same signature whether an
AWS-delivered `ec2:StopInstances` or an in-guest `Stop-Computer -Force` initiated it, so
**the event log alone cannot tell the normal path from the fallback.** The
`Microsoft-Windows-TaskScheduler/Operational` log, which would have shown which task fired,
is **disabled** on this box. The determination in §F rests on `stop.log`'s timing against
the code's own 300 s gate.

**AWS's record:** a read-only `aws ec2 describe-instances` returns `"State": "running"` with
**`"LaunchTime": "2026-07-27T13:25:27+00:00"`**, 8 seconds before Windows finished booting -
the expected order. `LastBootUpTime` = `2026-07-27 13:25:35`.

**Outage: `12:54:40` -> `13:25:27` = 30 min 47 s.** Which external actor started the
instance again is **not recorded in any guest-side log - NOT OBSERVED**. This instance's
role cannot start itself, so something outside the guest did it, as on the previous cycle.

## H. Google Drive and the scratch wipe

`rclone lsl gdrive:temp --config C:\topaz-autostop\rclone.conf` (read-only) returns exactly
one entry:

```
10561165286 2026-07-27 12:46:36.065000000 SDR_Render_video_slp.mov
```

Byte-identical to §E, and its modification time is the moment the mux finished. `D:\Renders`
exists and is **empty**; `D:\Source` does not exist. Both are expected: the volume was
destroyed by the stop and re-created at boot.

**The 1.26 GiB render from the first run is no longer in `gdrive:temp`.** This analysis
initially flagged that as an unexplained disappearance, matching the pattern
[docs/13 §H](13-first-end-to-end-run.md#h-is-the-render-now-in-google-drive-is-drenders-empty)
recorded for its probe files. **Resolved: the operator deleted it manually.** No further
mechanism needs to be sought. The observation is kept because the reasoning was sound -
`gdrive:temp` is the *only* copy of a render once the scratch volume is wiped, so files
leaving it unaccountably is worth questioning until explained.

## I. Scratch re-provisioning on the new boot

```
[2026-07-27 06:25:07] Selected Disk 1 (419.1 GB, serial=094C_89A3_824F_F4FC_0100_0000_00CD_B440.) as the instance-store scratch disk.
[2026-07-27 13:25:55] Selected Disk 1 (419.1 GB, serial=356A_1701_07C2_962F_0100_0000_00CD_B440.) as the instance-store scratch disk.
[2026-07-27 13:25:58] Scratch drive ready: D: 'RenderScratch' 419.1 GB, output directory 'D:\Renders' created (only this directory is uploaded).
```

The `SerialNumber` changed across the stop (`...824F_F4FC.` -> `...07C2_962F.`) -
physical-layer proof of a freshly issued instance-store device, and therefore of a genuine
stop/start rather than an OS reboot. `Get-Disk` confirms the live Disk 1 carries the new
serial. Provisioning completed **23 s after `LastBootUpTime`**, on the boot trigger as
intended. `scratch.log` contains **no WARN or ERROR on any boot**, and no boot ever failed to
produce `D:`. The partial-format recovery path added in commit `e8b00d0` was **not** needed
and has still not been exercised in production.

## J. Errors, warnings, and anomalies

**Within this run's window (`07:37:57`-`13:26:25`) the pipeline logged zero WARN and zero
ERROR lines** across `watchdog.log`, `stop.log`, `scratch.log`, and `metric.log`. `[ERROR]`
does not appear anywhere in `watchdog.log` at all. `metric.log` published on **89 of 89
attempts** between `11:30` and `13:30` with zero `AccessDenied`.

GPU utilisation tracks the render exactly: 77-100 % from `12:00` to `12:43:22`, then **0 %
from `12:44:22` through `12:53:22`** (compute finished; the remaining work was the
I/O-bound mux and the upload), then 33 % at `12:54:22`. The only metric gap over 3 minutes
is `12:54:22` -> `13:26:25` = **32 m 3 s**, the outage itself.

| Time | Source | Item |
|---|---|---|
| `06:25:03`, `07:04:41`, `07:31:49` | watchdog.log | Three watchdog sessions started and were superseded without ever detecting a GUI - restart churn from the code deployments. Not an error (no WARN/ERROR logged), but over an hour of dead time. |
| `07:42:35` | preflight.log | `Preflight verdict=GO pass=14 warn=2 fail=0.` **The detail of the two WARNs was not persisted** - only the summary line was ever written. Their content could not be recovered. Fixed; see §K. |
| `07:55:33`-`12:44:33` | watchdog.log | The 4 h 49 m silence (§C). |
| `12:53:40` | Application log | `DCVWindowsCredentialsProvider` ID 256 x2, `Unable to cancel IO requests for the credential polling thread. Error code: 1168.` Benign; DCV credential-provider thread teardown. |
| `13:27:46` | Application log | `Security-SPP` 16398, routine post-boot licensing grace-period message. |
| `13:30:45` | System log | `TPM-WMI` 1796 x5 / 1801 x1 - Secure Boot DB certificate rollout failing because Secure Boot is not enabled in firmware. Expected on this AMI; unrelated to the pipeline. **No disk, storage, or NVMe error/critical events at all**, despite the instance-store volume being destroyed and reissued. |
| ongoing | - | `Microsoft-Windows-TaskScheduler/Operational` is **disabled**, so no task-level trail exists to corroborate which scheduled task ran when (§G). Left disabled - enabling it is an operator decision, not a forensic one. |

**Two standing exposures, neither caused by this run:**

- **`TopazAutoStop-TimedStop` does not exist.** `timedstop.log` shows it armed at
  `2026-07-26 21:03:37` and deliberately removed at `2026-07-27 00:47:20`. It has not been
  re-armed, so the in-guest wall-clock cost cap is currently absent.
- **The CloudWatch idle alarm cannot fire while an operator is connected over DCV.** DCV
  encodes the remote display on the same L40S; measured at `13:38` with *no* Topaz process
  running, the GPU read **26 %** (`dwm.exe`, `dcvagent.exe`, `explorer.exe`, Edge WebView).
  The alarm's threshold is sustained **sub-5 %**
  ([`03-create-idle-alarm.sh`](../control-plane/03-create-idle-alarm.sh)). The repo documents
  this alarm firing *too eagerly*
  ([Phase 4](06-phase4-safety-net.md#safety-net-operational-windows)) but not the inverse:
  with a session connected it is inert, leaving the watchdog - which requires a GUI and an
  armed render - as the only active stop path. A box left at the desktop with no render is
  stopped by neither. Note also that the instance role is denied
  `cloudwatch:DescribeAlarms`, `lambda:ListFunctions` and `events:ListRules`, so **whether
  the alarm or the max-lifetime Lambda are deployed at all cannot be verified from inside
  the guest.**

## K. What this run changed in the code

The analysis produced five fixes, all made after the cycle completed:

1. **Log timestamps now carry milliseconds and an explicit UTC offset**
   (`yyyy-MM-dd HH:mm:ss.fff zzz`). Whole-second stamps had lost ordering: the entire
   completion handoff in §D - queue complete, unlock wait, unlock confirmed, Stop-Sequence
   invoked - shares the single stamp `[2026-07-27 12:51:35]`, so the log cannot say how long
   the unlock scan took. The offset removes the local-versus-UTC guess this document had to
   make repeatedly when correlating against AWS (UTC) and the `.tzlog` (box-local).
2. **WARN and ERROR are timestamped on the console too.** They previously printed the bare
   message while the log file received a stamped copy, so a live console transcript of a
   failure could not be aligned with the file it mirrored.
3. **`preflight.log` now records every individual check**, not just the verdict line - the
   gap that lost the two WARNs at `07:42:35`. The write is deliberately non-terminating so a
   `FAIL` cannot abort the remaining checks.
4. **Sizes are labelled `GiB`, not `GB`, and the raw byte count is logged alongside.**
   PowerShell's `1GB` literal is 2^30, so `stop.log`'s "9.84 GB" disagreed with rclone's
   "9.836 GiB" for the same transfer by ~7 %. The byte count is what made §E's chain of
   custody checkable.
5. **The watchdog now emits a heartbeat after `HeartbeatSec` (default 300 s) of logging
   nothing**, closing the 4 h 49 m void in §C. The clock measures *silence*, not wall time -
   every branch that already logs resets it - so a stalling render, which logs every poll,
   gains no extra output and the heartbeat only ever appears where there would otherwise be
   a gap. The decision is the pure, unit-tested `Get-NextHeartbeatState`
   ([Watchdog.ps1](../in-guest/Watchdog.ps1)); setting `HeartbeatSec = 0` restores the old
   silent-while-healthy behaviour. Cost on a render of this length: about 59 lines.
   A heartbeat line carries the same diagnostics the stall line does:

   ```
   Render progressing (worker=True gpu=n/a, armed): active=17400s, outputBytes=8931234816, workerIoBytes=114372836050. Heartbeat every 300s while healthy.
   ```

Also added: a persisted record from `Set-GoogleDriveAuth.ps1` (which previously wrote to no
log file at all, despite provisioning the credential every upload depends on), and UTC
offsets on the timed-stop deadline and SNS notification text.

---

## Verdict

**Yes - end-to-end, first attempt, no faults.** Topaz rendered 2,899 frames of 4K through a
diffusion model in 4 h 58 m with no crash and no retry (§A); the watchdog refused to arm on
GUI noise and armed only on the real worker (§B); it declared the queue complete after
exactly the configured 300 s debounce, counted poll-by-poll with no gaps or resets (§D); the
unlock gate passed instantly (§D); 9.84 GiB was uploaded and md5-verified with 0 differences
before anything was allowed to stop (§E); `ec2:StopInstances` was accepted and the guest went
down 2 seconds later, proving the forced-shutdown fallback never ran (§F); Windows and AWS
independently confirm a clean cold stop/start with no unexpected-shutdown record (§G); the
render is byte-for-byte intact in Drive and the scratch volume was correctly destroyed and
re-provisioned 23 s after the next boot (§H, §I); and the pipeline logged zero warnings or
errors throughout (§J).

Nothing about the render, the upload, the verification, or the stop decision fell short.
What this run did expose was **observability**, not correctness: 4 h 49 m of silence in the
watchdog log, a preflight whose warnings evaporated, and timestamps too coarse to order the
events of the final second. All three are fixed (§K). The two standing exposures in §J -
the removed timed stop and the DCV-defeated idle alarm - are cost-control gaps that predate
this run and remain open.

---

Back to the [README](../README.md).
