# 13 - First End-to-End Run: Render, Upload-Verify, and Stop Forensics

[README](../README.md) - [Architecture](01-architecture.md) - [Phase 0](02-phase0-confirmations.md) - [Phase 1](03-phase1-instance-prep.md) - [Phase 2](04-phase2-watchdog.md) - [Phase 3](05-phase3-stop-sequence.md) - [Phase 4](06-phase4-safety-net.md) - [Phase 5](07-phase5-notifications.md) - [Appendix A](08-appendix-a-corrections.md) - [Appendix B](09-appendix-b-boundaries.md) - [Testing & CI](10-testing-and-ci.md) - [Deploying on this instance](11-deploying-on-this-instance.md) - [Empirical Findings](12-empirical-findings.md) - **First End-to-End Run**

## Method and provenance

This is a **read-only forensic reconstruction**. Nothing was started, stopped, killed, or
modified to produce it except this file. Every fact below is a direct quote or a direct
read of: `C:\topaz-autostop\logs\{watchdog,stop,rclone,scratch,metric,install,register,
preflight,test,timedstop}.log`, the newest Topaz `.tzlog`, `(Get-CimInstance
Win32_OperatingSystem).LastBootUpTime`, one read-only `aws ec2 describe-instances` call, the
live contents of `D:\Renders` / `D:\Source`, and one read-only `rclone ls gdrive:temp`.

**This box's log files span many overlapping install/test/dry-run cycles, not one clean
run.** `install.log` alone shows the pipeline files being copied into
`C:\topaz-autostop` **eight** separate times between `2026-07-26 21:02:48` and
`2026-07-27 05:58:44`, and `register.log` shows the scheduled tasks being torn down and
re-registered four times in the same window. Before treating any single render as "the"
run, three things were established from the logs themselves, not assumed:

1. **Only two stop cycles in `watchdog.log` were ever triggered by the watchdog itself**
   (the string `Invoking Stop-Sequence.ps1` appears exactly twice in the whole file: line 68,
   `2026-07-27 03:00:31`, and line 526, `2026-07-27 06:14:58`). The three other
   `stop.log` entries timestamped `05:17:11`, `05:20:03`, and `05:52:02` - each uploading
   "0 GB" (a few-byte placeholder text file: `_pipeline-probe.txt`, `_pipeline-probe.txt`
   again, `_final-probe.txt`) - have **no** corresponding `Invoking Stop-Sequence.ps1` or
   `Render QUEUE considered COMPLETE` line anywhere near them in `watchdog.log`. They were
   therefore **manual, out-of-band invocations of `Stop-Sequence.ps1`** (an operator or
   harness testing the upload/verify/stop mechanics directly against placeholder files),
   not watchdog-driven completions. This document does not analyze them further except
   where they corroborate the upload plumbing (§E).
2. **The first watchdog-triggered stop (`03:00:31`) predates the Google-Drive-upload
   feature entirely.** Its `stop.log` block (`03:00:31`-`03:02:03`) has no `Uploading`
   line at all - it goes straight from "No S3SyncTarget configured" to
   `ec2:StopInstances accepted`. `install.log` confirms `Initialize-ScratchDisk.ps1` and
   `Set-GoogleDriveAuth.ps1` are not copied to the box until the `05:07:16` install entry,
   i.e. after this stop. This cycle is therefore the **pre-upload-feature** design (matches
   [Empirical Findings §6](12-empirical-findings.md#6-completion-transition)'s render), and
   it is the one whose escalation-to-guest-shutdown is quoted in §F below for contrast.
3. **The second watchdog-triggered stop (`06:14:58`) is the only cycle with all of: a
   watchdog-detected queue completion, a real (1.26 GB) render uploaded and verified, an
   accepted `ec2:StopInstances`, and independent proof the instance actually powered off and
   rebooted.** This is the run this document reconstructs in detail.

The render behind that final cycle is captured in Topaz's own
`2026-07-27-04-10-55-Main.tzlog` (395,479 bytes, last written `06:15:26`, i.e. the GUI
session that was open across the whole `04:10:55`-`06:15:26` stretch, including the final
export).

---

## A. Did the render complete successfully?

**Yes, but not on the first attempt** - Topaz's own log shows the export crashed once and
was retried automatically before it succeeded. Reconstructed from
`2026-07-27-04-10-55-Main.tzlog`:

| Time | Event |
|---|---|
| `06-06-05.704` | `Trying to open the file "D:/Source/SDR_Render_short.mp4"` |
| `06-06-32.807`-`06-06-51.060` | ffmpeg sub-process **`18`** starts encoding, writes intermediate output to `Output #0, mov, to 'D:/Source/SDR_Render_short_36229686.mov'` |
| `06-07-13.391` | **`process exited error occurred: 18 1`** / **`process exited: 18 62097 1`** - sub-process 18 (PID 62097) exited with a nonzero/error status |
| `06-07-22.176`-`06-07-26.881` | Topaz closes and deletes the failed intermediate, re-opens `SDR_Render_short.mp4` from both `C:\Users\Administrator\Downloads` and `D:\Source`, and restarts the export |
| `06-08-01.075`-`06-08-11.075` | ffmpeg sub-process **`22`** re-encodes, `Output #0, mov, to 'D:/Source/SDR_Render_short_75371859.mov'` |
| `06-10-00.911` | `process exited: 22 0 0` - clean exit |
| `06-10-01.072` | Final mux: `Output #0, mov, to 'D:/Renders/SDR_Render_short_prob4.mov'` (reads both the just-produced intermediate and the original source as Input #0/#1) |
| `06-10-01.615` | `process exited: 22 0 0` - clean exit. Final deliverable is now sitting in `D:\Renders`. |

No `No space left on device` or `Conversion failed` string appears anywhere in this
tzlog - **not observed**. The literal phrase `total processing time` also does not appear in
this log; the closest first-party timing data is ffmpeg's own progress line for the
AI-encode pass: `frame= 1474 fps= 12 q=1.0 Lsize= 1323467KiB time=00:01:01.41
bitrate=176529.3kbits/s speed=0.515x elapsed=0:01:59.26` (1 min 59.26 s of encode wall time
for a 61.4 s source clip), followed by a near-instant remux pass (`elapsed=0:00:00.53`).
No literal `neuroserver --input-path/--output-path/--end-frame-idx` command line appears in
this tzlog either (this build logs ffmpeg's own stdout under "FF Process Output", not
`neuroserver`'s invocation) - **not observed in this log**; unlike
[§2 of Empirical Findings](12-empirical-findings.md#2-neuroservers-invocation-and-what-it-implies),
that command line was only ever captured by a live `Get-CimInstance` query while the process
was running, and no such live query was available for this after-the-fact analysis (the
process had already exited).

**Output file:** `D:\Renders\SDR_Render_short_prob4.mov`. Its size is confirmed two ways:
`rclone.log` at `06:15:21` reports `1.262 GiB / 1.262 GiB, 100%`, and the file currently
sitting in Google Drive (§H) is exactly **1,354,887,153 bytes** (`1354887153 / 1073741824 =
1.2618 GiB`, matching). `stop.log` independently reports `1.26 GB` for the same file.
`prob4` in the filename is not a manual test artifact: Topaz's own
`GET video/status` response (tzlog line 4227) lists `"prob-4"` as one of its
`supportedModels`, confirming this is simply the AI model name used for the export.

## B. Did the watchdog arm correctly, and how long did the render run?

`watchdog.log` reports the config as `poll=15s, debounce=300s, stall=1800s` at every GUI
detection, and (from the `05:58:45` session onward, once a newer `Watchdog.ps1` build had
been reinstalled at `05:58:44` per `install.log`) explicitly `90s of sustained worker
activity` for the arm gate. The final render's arming was **not clean on the first try**,
which lines up exactly with the process-18 crash in §A:

```
[2026-07-27 06:06:20] [INFO] Render active (worker=True gpu=n/a, arming 15s/90s) but NO progress on either signal (stall=15s / 1800s, outputBytes=0, workerIoBytes=9878702).
[2026-07-27 06:07:22] [INFO] Topaz GUI up but no render has started yet (idle=15s, worker=False gpu=n/a). Waiting for 90s of sustained worker activity before arming completion.
[2026-07-27 06:07:53] [INFO] Topaz GUI up but no render has started yet (idle=15s, worker=False gpu=n/a). Waiting for 90s of sustained worker activity before arming completion.
```

The worker (sub-process 18) was seen for only ~15-68 s before it crashed at `06:07:13`,
short of the 90 s `ArmSec` requirement, so the watchdog correctly did **not** arm on that
attempt and fell back to "no render has started yet" (the `$sawActivity=false` branch in
`Watchdog.ps1`). There is then a quiet gap in the log from `06:07:53` to `06:10:11`: by
design (`Watchdog.ps1` lines 843-857), an **active render whose output bytes are changing
every poll logs nothing** - only a stalled/no-progress poll gets a log line. The next line,

```
[2026-07-27 06:10:11] [INFO] No active render (idle=15s / 300s debounce, worker=False gpu=n/a).
```

is only reachable from the `$sawActivity=true` branch, which proves arming succeeded
silently, without an explicit "ARMED" line, sometime during that quiet, healthily-progressing
stretch (the retried sub-process 22, `06:08:01`-`06:10:00`, comfortably exceeds the 90 s arm
requirement). **There is no explicit "armed" log line to quote for this run** - that text
(`$armText = 'armed'`) only fires on a stalled/no-progress poll, and this render never
stalled once armed - so the arm event is proven by this branch transition, not by a
dedicated message.

**Render duration** (from the tzlog, the authoritative source): source opened `06:06:05.704`,
final output process exit `06:10:01.615` -> **3 min 55.9 s** end-to-end, including the one
crash-and-retry. The productive (successful) sub-process alone ran `06:08:01`-`06:10:01`
(~2 min).

## C. Did the watchdog declare the queue COMPLETE?

Yes, at `2026-07-27 06:14:58`, after exactly the configured 300 s debounce:

```
[2026-07-27 06:14:58] [INFO] No active render (idle=300s / 300s debounce, worker=False gpu=n/a).
[2026-07-27 06:14:58] [INFO] No active render for 300s (>= debounce). Render QUEUE considered COMPLETE.
```

Idle accrual is traceable poll-by-poll from `06:10:11` (`idle=15s`) through fifteen further
15 s polls to `06:14:58` (`idle=300s`), with no gaps and no resets in between.

## D. Did the unlock gate pass or time out?

**Passed instantly** - the very same second:

```
[2026-07-27 06:14:58] [INFO] Reason='completed'. Waiting up to 5 min for output files to unlock.
[2026-07-27 06:14:58] [INFO] All output files are unlocked.
```

This is a marked contrast with the hazard documented in
[Empirical Findings §5](12-empirical-findings.md#5-what-this-means-for-configps1): on this
run `OutputDir` (`D:\Renders`) is on the scratch disk and holds only the finished
`.mov` - it is disjoint from Topaz's own working files under
`C:\Users\Administrator\Downloads` and `D:\Source`, so the unlock scan never has to wait on
an unrelated, still-open input file. (Contrast with the earlier, pre-upload-feature cycle,
where the unlock gate **did** time out: `[2026-07-27 03:00:31] [WARN] Unlock wait timed out
after 5 min. Still locked: C:\Users\Administrator\Downloads\SDR_Render_short.mp4,
C:\Users\Administrator\Downloads\SDR_Render_video.mp4. Proceeding with stop anyway.`)

## E. *** DID THE UPLOAD RUN AND VERIFY? ***

**Yes - upload, copy-completion, verification, and the "safe to stop" gate all fired,
in order, in `stop.log`:**

```
[2026-07-27 06:14:58] [INFO] Uploading 1 file(s), 1.26 GB, from 'D:\Renders' to 'gdrive:temp' (reason=completed). This MUST finish before the instance may stop.
[2026-07-27 06:15:21] [INFO] rclone copy completed. See 'C:\topaz-autostop\logs\rclone.log' for transfer detail.
[2026-07-27 06:15:24] [INFO] rclone check VERIFIED every file in 'D:\Renders' is present and intact at 'gdrive:temp'.
[2026-07-27 06:15:24] [INFO] Upload verified: 1 file(s), 1.26 GB now safely in 'gdrive:temp'. Safe to stop.
```

`rclone.log`'s own record of the same copy + check:

```
2026/07/27 06:15:21 INFO  : SDR_Render_short_prob4.mov: Copied (new)
Transferred:            1.262 GiB / 1.262 GiB, 100%, 60.613 MiB/s, ETA 0s
Elapsed time:        21.8s

2026/07/27 06:15:21 INFO  : Using md5 for hash comparisons
2026/07/27 06:15:24 NOTICE: Google drive root 'temp': 0 differences found
2026/07/27 06:15:24 NOTICE: Google drive root 'temp': 1 matching files
Elapsed time:         2.5s
```

**Timing:** `stop.log` timestamps put the whole upload+verify step at
`06:14:58` -> `06:15:24` = **26 s**. `rclone`'s own internal clock for just the copy is
**21.8 s**, at a self-reported **60.613 MiB/s**; the `md5`-hash verification pass (`rclone
check`) took a further **2.5 s** and found **0 differences / 1 matching file(s)**. The
sequence returned **"Safe to stop."** exactly as designed.

## F. Did ec2:StopInstances get accepted? Did the instance go down, or escalate?

Accepted immediately:

```
[2026-07-27 06:15:24] [INFO] Stopping now (reason=completed). StopStrategy='Auto', plan=[Ec2ApiStop -> GuestShutdown].
[2026-07-27 06:15:25] [INFO] ec2:StopInstances accepted for i-029f35d589bec9b9c. The instance should transition to 'stopping' shortly.
[2026-07-27 06:15:25] [INFO] Waiting up to 300s for the instance to actually go down.
```

That is the **last line in `stop.log`** - there is no subsequent `WARN`/escalation/guest-shutdown
line, unlike the earlier, pre-upload-feature cycle, which *did* need to escalate:

```
[2026-07-27 03:00:33] [INFO] ec2:StopInstances accepted for i-029f35d589bec9b9c. The instance should transition to 'stopping' shortly.
[2026-07-27 03:00:33] [INFO] Waiting up to 90s for the instance to actually go down.
[2026-07-27 03:02:03] [WARN] Still running 90s after an accepted ec2:StopInstances. Escalating to the next action in the plan.
[2026-07-27 03:02:03] [INFO] Issuing guest shutdown (Stop-Computer -Force). NOTE: this ends billing ONLY if InstanceInitiatedShutdownBehavior='stop'.
[2026-07-27 03:02:03] [INFO] Guest shutdown initiated. Waiting up to 90s for the OS to tear this process down.
```

For the final run, the absence of any further line is itself the evidence: the
`StopVerifySec` wait (300 s this time, vs. 90 s on the earlier cycle - a config value that
changed between the two cycles) never got to log a timeout, because the guest OS - and the
PowerShell process that would have logged it - was torn down by the EC2-level stop itself
before that could happen. §G confirms the instance did, in fact, go down and come back.

## G. Did the instance really stop and restart?

**Yes**, confirmed two independent ways:

- `(Get-CimInstance Win32_OperatingSystem).LastBootUpTime` = **`2026-07-27 06:24:49`**.
- A read-only `aws ec2 describe-instances --instance-ids i-029f35d589bec9b9c` (permitted
  under the read-only-AWS-calls rule) returns `"State": "running"`, **`"LaunchTime":
  "2026-07-27T06:24:41+00:00"`** - AWS's own record of when this instance last started,
  8 seconds before Windows itself finished booting, exactly the expected order.

Gap from the accepted stop (`06:15:25`) to the new boot (`06:24:49`) is **9 min 24 s**. Which
external actor issued the subsequent start is **not recorded in any of these guest-side
logs - not observed** (this instance's role is not able to start/stop itself per prior
findings; something outside the guest did it). The wipe-and-reissue of the instance-store
NVMe (different `SerialNumber` before/after, see §I) is independent, physical-layer proof
that this was a genuine stop/start cycle and not, say, a mere OS-level reboot.

## H. Is the render now in Google Drive? Is D:\Renders empty?

`rclone ls gdrive:temp --config C:\topaz-autostop\rclone.conf` (read-only) currently returns
exactly one entry:

```
1354887153 SDR_Render_short_prob4.mov
```

Byte-for-byte identical to the size reported at upload time (§A/§E). `D:\Renders` is
currently **empty** (`Get-ChildItem -Force` returns nothing) - the scratch wipe on stop
worked as designed. `D:\Source` (where Topaz staged its working copy of the input,
per the tzlog) **does not exist at all** (`Test-Path 'D:\Source'` = `False`) - this is by
design, not a defect: `Initialize-ScratchDisk.ps1` only ever (re)creates `$cfg.OutputDir`
(`D:\Renders`); its own banner text says plainly "Drop source footage anywhere else on D:
... only $outputDir is uploaded, so sources are never sent to Drive" and "the ENTIRE volume
is ERASED every time the instance stops."

**Resolved after this analysis was written.** The probe files were deleted deliberately, by
the same operator session that uploaded them, immediately after each verification succeeded:

```
rclone delete gdrive:temp/_pipeline-probe.txt --config C:\topaz-autostop\rclone.conf
rclone delete gdrive:temp/_final-probe.txt    --config C:\topaz-autostop\rclone.conf
```

Those commands were invoked ad hoc rather than through `Invoke-TopazRenderUpload`, so they were
never passed `--log-file` and left no entry in `rclone.log` - which is precisely why the
analysis below could find an upload but no matching deletion. The original wording is kept
below because the reasoning was right: the evidence genuinely did not support a conclusion, and
saying so was better than guessing.

**What the analysis could not explain at the time:** the two tiny placeholder probe files uploaded
earlier in this same session (`_pipeline-probe.txt` at `06:15:21`... no - at `05:17:30` and
`05:20:38`, and `_final-probe.txt` at `05:52:04`, per `rclone.log`) are **no longer present**
in the current `gdrive:temp` listing - only the real render is. `rclone.conf` was not
modified again after `05:50:50` (its last-write time, before all three probe uploads had even
finished), so this isn't explained by a remote/config change. No log available to this
analysis records a deletion. **Not observed / mechanism unknown** - flagged here rather than
guessed at.

## I. Did Initialize-ScratchDisk.ps1 re-create D: correctly on the new boot?

Yes. `scratch.log`, comparing the boot immediately before this cycle to the one immediately
after:

```
[2026-07-27 05:03:08] [INFO] Selected Disk 1 (419.1 GB, serial=4EDC_1323_0B3C_92CC_0100_0000_00CD_B440.) as the instance-store scratch disk.
[2026-07-27 05:03:12] [INFO] Scratch drive ready: D: 'RenderScratch' 419.1 GB, output directory 'D:\Renders' created.
[2026-07-27 05:08:08] [INFO] Scratch drive D: already present (419 GB free of 419.1 GB). Nothing to do.
[2026-07-27 06:25:07] [INFO] Selected Disk 1 (419.1 GB, serial=094C_89A3_824F_F4FC_0100_0000_00CD_B440.) as the instance-store scratch disk.
[2026-07-27 06:25:11] [INFO] Scratch drive ready: D: 'RenderScratch' 419.1 GB, output directory 'D:\Renders' created.
```

The `SerialNumber` of "Disk 1" changed (`...92CC.` -> `...824F_F4FC.`) between the two
boots - physical-layer proof this is a freshly-issued instance-store device, not a relabel of
the same disk - and `Initialize-ScratchDisk.ps1` correctly re-formatted it and recreated
`D:\Renders` at `06:25:11`, **18 s** after `LastBootUpTime` (`06:24:49`), i.e. right on the
scheduled-task startup trigger as intended. This matches the currently-empty, currently-fresh
`D:\Renders` observed live in §H.

## J. Errors, warnings, and anomalies

**Within the final run's own window (`2026-07-27 05:58:45` - `06:25:11`), `watchdog.log`
contains zero `WARN`/`ERROR` lines** (verified directly - all `WARN`/`ERROR` lines in the
whole file are timestamped `2026-07-26 20:56`-`2026-07-27 03:00`, strictly before this
run). Likewise `metric.log` published successfully on every attempt inside this window
(`06:06:33` through `06:15:22`, GPU values 19%/3%/56%/56%/0%/.../31%, all `[INFO] Published`,
zero `AccessDenied`). Specific items worth recording:

| Time | Source | Anomaly |
|---|---|---|
| `06:07:13.391` | Topaz tzlog | ffmpeg sub-process 18 (PID 62097) crashed (`process exited error occurred: 18 1`) mid-encode; Topaz auto-retried as sub-process 22, which then succeeded. This is the direct cause of the arm reset documented in §B. |
| `06:08:01` (`06:08:01.446`) | Topaz tzlog | `WARNING: ModelManager: Ignoring model: "C:\ProgramData\Topaz Labs LLC\Topaz Video\models\neuroserver.json"` - cause not explained further in the log; did not visibly affect the retried export's success. |
| `05:58:44` | install.log | `Watchdog.ps1` was reinstalled **one second before** `05:58:45`'s "Topaz GUI detected" line that begins this run - the watchdog process actually monitoring this render was loaded from a version updated only moments earlier (this is also why only this run's log lines carry the newer `arming Ns/90s` text; every earlier session in the same file lacks it, having been loaded from an older on-disk copy that never got the update while running). |
| `06:05:39` | preflight.log | `Preflight verdict=GO pass=15 warn=1 fail=0`, run mid-session, before the render started. The one `WARN`'s detail was not persisted to `preflight.log` (only the summary line is logged); its content could not be recovered by this analysis. |

**Outside the final run's window, but present in the same log files (historical context,
already fixed by the time of this run):**

| Time | Source | Anomaly |
|---|---|---|
| `2026-07-26 20:56:08` - `2026-07-27 01:43:24` | watchdog.log | Repeated `Get-TopazWorkers`/`Get-TopazPids` `WARN`s ("A parameter cannot be found that matches parameter name 'Property'" then later `'OperationTimeoutSec'"), from an older code path; absent from every line after `01:44:45`. |
| `2026-07-26 21:03:53` - `2026-07-27 00:58:52` | metric.log | Every `aws cloudwatch put-metric-data` call was denied (`AccessDenied ... not authorized to perform: cloudwatch:PutMetricData`), ~236 consecutive failures. The **very next** attempt, `2026-07-27 00:59:52`, succeeded (`Published TopazRender/GPU/GPUUtilization=100%`) and every attempt after that - including all of them inside the final run's window - succeeded too. The instance role's CloudWatch permission was evidently granted from outside the guest sometime in that one-hour gap. |
| `2026-07-27 03:00:31` | watchdog.log | `Unlock wait timed out after 5 min` (see §D) - specific to the earlier, pre-upload-feature cycle's shared input/output directory, not reproduced on the final run. |
| `2026-07-27 05:06:40` | stop.log | `[ERROR] rclone config not found at 'C:\topaz-autostop\rclone.conf'` - one of the manual/out-of-band `Stop-Sequence.ps1` invocations (see Method, item 1) ran before `Set-GoogleDriveAuth.ps1` had created the config (`rclone.conf`'s own `CreationTime` is `05:13:28`, after this error). Not present in the final run. |

---

## Verdict

**Yes, end-to-end, on the second internal attempt of the render itself.** For the run
analyzed here: Topaz's export crashed once (§A) and auto-retried successfully; the watchdog
correctly withheld arming until the retried worker had been present and progressing well past
90 s (§B, proven by branch transition rather than an explicit log line); it declared the
queue complete after exactly the configured 300 s debounce (§C); the unlock gate passed
instantly because `OutputDir` no longer shares a folder with Topaz's working files (§D); the
1.26 GB output was uploaded to `gdrive:temp`, `rclone check` verified it byte-for-byte via
md5, and the pipeline logged "Safe to stop" (§E); `ec2:StopInstances` was accepted and this
time the instance went down without needing the guest-shutdown escalation fallback (§F); the
instance provably stopped and rebooted (`LastBootUpTime`/`LaunchTime` both ~`06:24:4x`, a
fresh instance-store `SerialNumber`, §G); the file is confirmed still sitting in Drive right
now at the exact uploaded size, and `D:\Renders` is confirmed empty on the new boot (§H);
and `Initialize-ScratchDisk.ps1` re-provisioned the scratch volume correctly, 18 s after
boot (§I).

Two things fell short of "clean," both disclosed above rather than smoothed over: the render
needed one internal crash-and-retry before it produced output (§A/§B/J), and the earlier
probe files uploaded during this same session have since vanished from Google Drive by a
mechanism this analysis could not identify (§H). Neither affects the correctness of the
render, upload, verification, or stop decision that is this document's subject.

---

Back to the [README](../README.md).
