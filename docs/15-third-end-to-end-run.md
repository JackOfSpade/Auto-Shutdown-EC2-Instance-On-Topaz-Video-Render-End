# 15 - Third End-to-End Run: The First Cycle Under Full Observability

[README](../README.md) - [Architecture](01-architecture.md) - [Phase 0](02-phase0-confirmations.md) - [Phase 1](03-phase1-instance-prep.md) - [Phase 2](04-phase2-watchdog.md) - [Phase 3](05-phase3-stop-sequence.md) - [Phase 4](06-phase4-safety-net.md) - [Phase 5](07-phase5-notifications.md) - [Appendix A](08-appendix-a-corrections.md) - [Appendix B](09-appendix-b-boundaries.md) - [Testing & CI](10-testing-and-ci.md) - [Deploying on this instance](11-deploying-on-this-instance.md) - [Empirical Findings](12-empirical-findings.md) - [First End-to-End Run](13-first-end-to-end-run.md) - [Second End-to-End Run](14-second-end-to-end-run.md) - **Third End-to-End Run**

## Method and provenance

This is a **read-only forensic reconstruction**, written the same way as
[docs/13](13-first-end-to-end-run.md) and [docs/14](14-second-end-to-end-run.md). Nothing was
started, stopped, killed, or modified to produce it. Every fact below is a direct quote or
direct read of: `C:\topaz-autostop\logs\{watchdog,stop,rclone,scratch,metric,install,register,
preflight,test,timedstop}.log`, the Topaz `.tzlog` covering the render
(`2026-07-27-14-12-55-Main.tzlog`), the Windows System event log via `Get-WinEvent`, `(Get-
CimInstance Win32_OperatingSystem).LastBootUpTime`, and one read-only `rclone lsl gdrive:temp`.
This document was assembled from a completed multi-agent forensic investigation (ten
evidence-gathering passes plus six adversarial skeptic reviews) and then independently
re-verified line-by-line against the live log files and a live `Get-WinEvent` query before
being written up; every quote below was re-read from its source file, not carried over
unchecked.

**Why this run is worth a third document.** [docs/13](13-first-end-to-end-run.md) established
the render -> upload -> verify -> stop path worked at all; [docs/14](14-second-end-to-end-run.md)
proved it at five-hour scale on the code as committed at the time, and its own findings (the
4h49m silent gap, coarse timestamps, a preflight warning that evaporated, `GB` vs `GiB`) drove
five fixes that shipped as commit `00d21ef`, "Make a healthy render visible in the logs, and a
warning survivable." This is the **first cycle to run on that commit**. The question this
document answers is not "did the pipeline work" - that is now established precedent - but "did
the new observability guarantees actually hold, end to end, on a real render."

Three things were established from the logs before treating this as "the" run, rather than
assumed:

1. **The deployed code is byte-identical to git HEAD.** `install.log`'s relevant block runs
   `14:06:35.360` -> `14:06:35.685`, copying all eight in-guest scripts; a SHA-256 comparison of
   every deployed file in `C:\topaz-autostop` against `in-guest\` in the repo returns `match=True`
   for all eight, and `git rev-parse HEAD` is `00d21ef01e2830bea7ad0da8736bd40fe3375335`
   ("Make a healthy render visible in the logs, and a warning survivable", authored
   `14:06:19`). The render this document analyzes ran entirely under this code, not an
   intermediate state.
2. **This stop was watchdog-driven.** `Invoking Stop-Sequence.ps1` is immediately preceded by
   `Render QUEUE considered COMPLETE` at `14:53:21.420`/`14:53:21.763`, the same signature
   docs/13 and docs/14 used to rule out manual invocations.
3. **The watchdog that governed this render was not the one the install just copied files
   for - it was a *new process*, and exactly when and how it restarted is not fully
   recoverable.** `watchdog.log` line 675 is an old-format line at `14:06:50` (idle countdown
   from a still-running prior-code process); line 676, in the **new** timestamp format, reads
   `Watchdog starting`, at `14:06:57.451` - 22 seconds after `install.log`'s `14:06:35.685`
   completion. `install.log` itself performs no task action (it only copies files and checks
   two PATH dependencies), `register.log`'s last entry is `05:07:20`, over nine hours earlier,
   and the registered sweep-trigger boundary nearest this window is `14:07:16` - 18.5 seconds
   *after* the observed restart, so it cannot explain it either.
   `Microsoft-Windows-TaskScheduler/Operational` is disabled on this box
   (`Get-WinEvent -ListLog` reports `IsEnabled: False`), and a direct query of `System` and
   `Application` for `14:06:00`-`14:08:00` returns no events at all. `Push-GpuMetric.ps1`, a
   genuinely per-minute-relaunched task, shows a gap-free cadence straight through the same
   window (`14:06:22` old format -> `14:07:22.237` new format, no missed minute), which rules
   out an OS reboot as the cause. **This document records the restart as unresolved - most
   likely a manual `Stop`/`Start` of the scheduled task by whoever ran the install, but
   unproven** - rather than guessing at a mechanism the evidence does not support.

The render itself is captured in Topaz's own `2026-07-27-14-12-55-Main.tzlog`, created
`14:12:55` and last written `14:56:32` - the entire life of the GUI session this render ran in.

---

## A. The render, from Topaz's own log

Source: `2026-07-27-14-12-55-Main.tzlog`. This document is scoped to the render inside this
one session log, the same way docs/14 was scoped to its own single `.tzlog`.

| Time (Topaz clock) | Event |
|---|---|
| `14-13-02.403` | `Trying to open the file  "D:/SDR_Render_video.mp4" false` |
| `14-15-15.929` | `Video Export Started` (Segment-tracking event, disabled on this box but the label survives in the log) |
| ~`14-15-2x` | `Runner process started 28 CMD: ...neuroserver ... --input-path D:/SDR_Render_video.mp4 --output-path D:/SDR_Render_video_614203942.mov ...` (AI-enhance pass, model `pnat-1`) |
| `14-48-26.552` | **`process exited: 28 0 0`** - the enhance pass exits **cleanly**, after `elapsed=0:33:10.23` (33 min 10.23 s) |
| `14-48-26.824` | Mux pass starts: `ffmpeg ... Output #0, mov, to 'D:/Renders/SDR_Render_video_pnat1.mov'` (stream-copies the enhanced video and reattaches the original audio/metadata) |
| **`14-48-32.414`** | **`process exited: 28 0 0`** - the mux exits **cleanly**, after `elapsed=0:00:05.58` |

**One export, two clean stages, zero crashes, zero retries.** A whole-file search of this tzlog
for the string `error occurred` returns **zero matches**. This is a direct, stronger contrast
with [docs/13 §A](13-first-end-to-end-run.md#a-did-the-render-complete-successfully), where
ffmpeg sub-process 18 crashed mid-encode and logged `process exited error occurred: 18 1` on an
otherwise-successful render - this run is cleaner than that precedent, not merely as good.

ffmpeg's own closing summary for the AI-enhance pass:

```
frame= 2899 fps=1.5 q=1.0 Lsize=10314274KiB time=00:02:00.79 bitrate=699506.3kbits/s speed=0.0607x elapsed=0:33:10.23
```

and for the mux:

```
frame= 2899 fps=519 q=-1.0 Lsize=10313638KiB time=00:02:00.79 bitrate=699463.2kbits/s speed=21.6x elapsed=0:00:05.58
```

**Output identity**, read from the mux's own stream metadata: `D:/Renders/SDR_Render_video_pnat1.mov`,
3840x2160 (4K UHD), 24 fps, 2,899 frames, duration `00:02:00.79`, video `DNxHR HQX` 10-bit 4:2:2
(`yuv422p10le`) at ~699 Mb/s, audio AAC 48 kHz stereo at 319 kb/s, and a metadata tag reading
`videoai=Enhanced using pnat-1; ... recover original detail at 20`.

**Size cross-check.** The mux's self-reported `Lsize=10313638KiB` is `10,561,165,312` bytes,
within **233 bytes** of the `10,561,165,545` bytes the upload pipeline reported for the same
file (§E) - consistent with ffmpeg printing its summary line fractionally before the trailer /
`moov` atom finishes flushing to disk, not with truncation.

**Duration:** export start `14-13-02.403` (file open) -> final mux exit `14-48-32.414` =
**35 min 30 s** end to end, of which the AI-enhance pass alone was 33 min 10.23 s and the mux
5.58 s.

## B. Did the watchdog arm correctly?

`watchdog.log`, `14:12:58.709` - the very first line the new watchdog process wrote after its
own restart (see Method, item 3):

```
[2026-07-27 14:12:58.709 +00:00] [INFO] Topaz GUI detected. Monitoring render queue (poll=15s, debounce=300s, stall=1800s, workers matching [neuroserver.exe, ffmpeg.exe] by ancestry).
```

This line lands `3.7s` after the tzlog file `2026-07-27-14-12-55-Main.tzlog` was itself created
(`14:12:55`), and `2.013s` after nothing in particular - the detection gap this run cares about
is the completion latency in §D, not this one, which is well inside a single poll.

Arming was **not** clean on the first attempt, correctly:

```
[2026-07-27 14:13:18.377 +00:00] [INFO] Render active (worker=True gpu=n/a, arming 15s/90s) but NO progress on either signal (stall=15s / 1800s, outputBytes=0, workerIoBytes=23883135).
[2026-07-27 14:13:53.136 +00:00] [INFO] Topaz GUI up but no render has started yet (idle=15s, worker=False gpu=n/a). Waiting for 90s of sustained worker activity before arming completion.
```

A worker matching `WorkerNamesLike` was seen for well under the 90 s `ArmSec` threshold (roughly
35 s, `14:13:18.377` -> `14:13:53.136`) before it vanished, and the watchdog correctly discarded
the partial progress rather than crediting it - the exact scenario `Config.ps1`'s `ArmSec`
rationale exists for (a measured, sub-32 s preview/thumbnail helper that once came within
seconds of arming on GUI noise alone), and structurally identical to the ~15-68 s blip
[docs/13 §B](13-first-end-to-end-run.md#b-did-the-watchdog-arm-correctly-and-how-long-did-the-render-run)
recorded on an actual sub-process crash. Unlike docs/13's case, no tzlog evidence pins down what
this ~35 s process actually was (Topaz's own log has no crash or process-exit line in this
narrow window); the mechanical response - correctly withholding the arm - is proven, the cause
of the brief sighting is not.

As in docs/14, there is **no explicit "armed" line to quote** for the real render: from
`14:15:08.579` (`idle=90s`, the last "no render has started yet" line) the real worker
(`neuroserver`, per §A) made byte/IO progress on every subsequent poll, taking the fully silent
`BytesChanged=true` path through both the 90 s arm threshold and the first 300 s heartbeat
threshold without a single logged line. The first line to appear after the blip is already the
first heartbeat, already reading `armed` (§C) - arming is proven by branch transition, exactly
as in docs/13 and docs/14.

## C. The heartbeat: six lines, ~320s apart, and why that is correct

This is the headline test of the commit this run is built to exercise. `Get-NextHeartbeatState`
(new in `00d21ef`) is supposed to bound how long the watchdog can log nothing while a render is
healthy and progressing. Inside the monitoring loop, it worked exactly as designed - six
heartbeats, evenly spaced, gap-free:

```
[2026-07-27 14:20:27.006 +00:00] [INFO] Render progressing (worker=True gpu=n/a, armed): active=300s, outputBytes=0, workerIoBytes=2088913855. Heartbeat every 300s while healthy.
[2026-07-27 14:25:48.292 +00:00] [INFO] Render progressing (worker=True gpu=n/a, armed): active=600s, outputBytes=0, workerIoBytes=3982849429. Heartbeat every 300s while healthy.
[2026-07-27 14:30:59.975 +00:00] [INFO] Render progressing (worker=True gpu=n/a, armed): active=900s, outputBytes=0, workerIoBytes=5879718388. Heartbeat every 300s while healthy.
[2026-07-27 14:36:17.795 +00:00] [INFO] Render progressing (worker=True gpu=n/a, armed): active=1200s, outputBytes=0, workerIoBytes=7803799158. Heartbeat every 300s while healthy.
[2026-07-27 14:41:39.970 +00:00] [INFO] Render progressing (worker=True gpu=n/a, armed): active=1500s, outputBytes=0, workerIoBytes=9743561808. Heartbeat every 300s while healthy.
[2026-07-27 14:46:59.222 +00:00] [INFO] Render progressing (worker=True gpu=n/a, armed): active=1800s, outputBytes=0, workerIoBytes=11595522299. Heartbeat every 300s while healthy.
```

The six intervals are `318.427s`, `321.286s`, `311.683s`, `317.820s`, `322.175s`, `319.252s` -
all in a `311.7`-`322.2s` band, **none exactly 300 s**. This is not drift and it is not a skipped
poll; it is the expected consequence of how `Get-NextHeartbeatState` counts. The function sums
`$SilentSec + $PollSec` and fires once that reaches `HeartbeatSec` (300), so it is counting
**nominal poll seconds** (`PollSec = 15`), requiring exactly 20 consecutive silent polls
(`20 x 15 = 300`) - not 300 s of measured wall-clock time. Dividing each real interval by 20
gives the actual per-poll cost during active monitoring: `15.921s`, `16.064s`, `15.584s`,
`15.891s`, `16.109s`, `15.963s` - i.e. `0.584s`-`1.109s` (mean `0.922s`) of real overhead **above**
the nominal 15 s `Start-Sleep`, on every single poll. The same file's idle/debounce polls (§D),
where `Test-RenderActive` has far less work to do, cost only `0.08s`-`0.19s` above the sleep
(e.g. `14:48:34.427` -> `14:48:49.518` = `15.091s`). The extra cost during active polling is
consistent with the work `Test-RenderActive` only pays when a worker matches: descendant-process
resolution (`Resolve-ProcessDescendants`), per-process I/O-counter reads, and `Get-OutputBytes`.
**No poll was skipped** - all six intervals cleanly resolve to a consistent ~15.6-16.1s-per-poll
band across exactly 20 polls each, with no interval landing at an anomalous multiple.

`workerIoBytes` is **strictly monotonically increasing** across all six heartbeats:
`2,088,913,855` -> `3,982,849,429` -> `5,879,718,388` -> `7,803,799,158` -> `9,743,561,808` ->
`11,595,522,299`. The five per-interval throughput figures land in a tight band:

| Interval | Bytes | Seconds | Rate |
|---|---|---|---|
| `14:20:27` -> `14:25:48` | 1,893,935,574 | 321.286 | 5.90 MB/s (5.62 MiB/s) |
| `14:25:48` -> `14:30:59` | 1,896,868,959 | 311.683 | 6.09 MB/s (5.80 MiB/s) |
| `14:30:59` -> `14:36:17` | 1,924,080,770 | 317.820 | 6.05 MB/s (5.77 MiB/s) |
| `14:36:17` -> `14:41:39` | 1,939,762,650 | 322.175 | 6.02 MB/s (5.74 MiB/s) |
| `14:41:39` -> `14:46:59` | 1,851,960,491 | 319.252 | 5.80 MB/s (5.53 MiB/s) |

A `5.53`-`6.09 MB/s` band (~9% spread) with no discontinuities or drops to near-zero - consistent
with a steady, healthy encode, matching a render that ran for 35 min 30 s without a stall
declaration once (peak stall recorded anywhere in this window is `15s / 1800s`, i.e. every poll
in the armed window made progress).

`outputBytes=0` on **every single line of the whole render** is the known, documented, accepted
NTFS limitation, not a broken signal: a directory entry's length is not refreshed while a
process holds an open write handle on it (`Config.ps1`'s `OutputDir` comment states this
explicitly, and [docs/12 §3](12-empirical-findings.md#3-the-key-evidence-reported-file-length-vs-actual-bytes-written)
measured an open writer's directory entry frozen for 466.2 s straight on this same deployment).
The pipeline correctly never depended on it - `workerIoBytes` carried the signal throughout, and
the 10,561,165,545-byte final size only becomes visible in a directory listing after Topaz
closes the file handle, outside this log's monitoring window. `gpu=n/a` on every line is
likewise correct by design: `CompletionSignal='WorkerOnly'` means `Test-RenderActive` never even
calls `nvidia-smi` for this signal (confirmed by `Config.ps1:275`, `CompletionSignal = 'WorkerOnly'`),
so `$gpu` is hardcoded `$null` every poll, formatting to the literal string `n/a`.

## D. The 361-second gap the heartbeat does not reach

The commit's own docstring for `Get-NextHeartbeatState` says plainly: "so silence is now
bounded: after `HeartbeatSec` of logging nothing, one line is emitted." Inside the monitoring
loop (§C) that promise held exactly - but this run also contains the one place, inside its own
window, where it does not:

```
[2026-07-27 14:06:57.451 +00:00] [INFO] Watchdog starting. Signal=WorkerOnly. Waiting for a Topaz GUI process (LIKE 'Topaz Video%').
[2026-07-27 14:12:58.709 +00:00] [INFO] Topaz GUI detected. Monitoring render queue (poll=15s, debounce=300s, stall=1800s, workers matching [neuroserver.exe, ffmpeg.exe] by ancestry).
```

**361.258 s, zero intervening lines** - longer than `HeartbeatSec` (300 s) and longer than the
worst interval measured in §C (322.175 s). The reason is structural, not a bug in the
heartbeat's own arithmetic: the pre-GUI wait is a separate, simpler loop
(`Watchdog.ps1:884`-`888`, `while ($true) { $topazPids = Get-TopazPids; if (...) { break };
Start-Sleep -Seconds $cfg.PollSec }`) that contains no `Write-TopazLog` call at all, and the
heartbeat's own silence clock, `$silentSec`, is declared at `Watchdog.ps1:908` - textually and
structurally *after* that loop exits. `HeartbeatSec` cannot bound a loop it has not been
instantiated inside yet. A watchdog wedged waiting for Topaz to appear and a healthy watchdog
patiently waiting for Topaz to appear produce **exactly the same evidence in this window**:
nothing. This is not a violation of the commit's stated guarantee, which the docstring itself
scopes to the render-monitoring loop that produced docs/14's 4h49m void - it is the residual
blind spot the guarantee did not reach, disclosed here rather than left for a future run to
rediscover. **It is being fixed in a follow-up change** (§H).

## E. Queue completion, unlock gate, and detection latency

The mux ffmpeg (§A) exited at `14-48-32.414` (Topaz clock). The watchdog's first `No active
render` line:

```
[2026-07-27 14:48:34.427 +00:00] [INFO] No active render (idle=15s / 300s debounce, worker=False gpu=n/a).
```

**Detection latency: 2.013 s**, caught on the very next poll after the render actually
finished, well inside a single `PollSec` interval.

Idle then accrued **exactly 20 consecutive polls, no gaps, no resets**, in `15s` steps from
`idle=15s` to `idle=300s`, every consecutive pair `15.084s`-`15.186s` apart:

```
[2026-07-27 14:48:34.427 +00:00] [INFO] No active render (idle=15s / 300s debounce, worker=False gpu=n/a).
   ... 18 further polls, +15s each ...
[2026-07-27 14:53:21.415 +00:00] [INFO] No active render (idle=300s / 300s debounce, worker=False gpu=n/a).
[2026-07-27 14:53:21.420 +00:00] [INFO] No active render for 300s (>= debounce). Render QUEUE considered COMPLETE.
```

The queue was declared **COMPLETE** 5 ms after the 20th line - `300s / 15s = 20` polls, exactly
`DebounceSec`, to the second, matching the pattern docs/13 and docs/14 both recorded.

The unlock gate passed almost instantly:

```
[2026-07-27 14:53:21.428 +00:00] [INFO] Reason='completed'. Waiting up to 5 min for output files to unlock.
[2026-07-27 14:53:21.532 +00:00] [INFO] All output files are unlocked.
```

**104 ms** (`14:53:21.428` -> `14:53:21.532`) - `OutputDir` (`D:\Renders`) holds only the
finished `.mov` and is disjoint from Topaz's own working files, the same reason docs/13 §D and
docs/14 §D both passed instantly.

## F. *** DID THE UPLOAD RUN AND VERIFY? ***

**Yes.** `stop.log`, and for the first time in this deployment's forensic history, every line in
the handoff carries its own distinct millisecond timestamp - the headline observability win of
this run, examined in full in §G:

```
[2026-07-27 14:53:21.854 +00:00] [INFO] Stop sequence invoked (reason=completed, dryRun=False).
[2026-07-27 14:53:21.951 +00:00] [INFO] No S3SyncTarget configured; skipping artifact sync.
[2026-07-27 14:53:21.976 +00:00] [INFO] Uploading 1 file(s), 9.84 GiB (10561165545 bytes), from 'D:\Renders' to 'gdrive:temp' (reason=completed). This MUST finish before the instance may stop.
[2026-07-27 14:56:13.029 +00:00] [INFO] rclone copy completed. See 'C:\topaz-autostop\logs\rclone.log' for transfer detail.
[2026-07-27 14:56:30.420 +00:00] [INFO] rclone check VERIFIED every file in 'D:\Renders' is present and intact at 'gdrive:temp'.
[2026-07-27 14:56:30.431 +00:00] [INFO] Upload verified: 1 file(s), 9.84 GiB (10561165545 bytes) now safely in 'gdrive:temp'. Safe to stop.
```

`rclone.log`'s own independent record:

```
2026/07/27 14:54:23 INFO  :
Transferred:   	    3.447 GiB / 9.836 GiB, 35%, 55.404 MiB/s, ETA 1m58s
2026/07/27 14:55:23 INFO  :
Transferred:   	    6.728 GiB / 9.836 GiB, 68%, 55.309 MiB/s, ETA 57s
2026/07/27 14:56:13 INFO  : SDR_Render_video_pnat1.mov: Copied (new)
Transferred:   	    9.836 GiB / 9.836 GiB, 100%, 64.459 MiB/s, ETA 0s
Elapsed time:      2m49.4s

2026/07/27 14:56:13 INFO  : Using md5 for hash comparisons
2026/07/27 14:56:30 NOTICE: Google drive root 'temp': 0 differences found
2026/07/27 14:56:30 NOTICE: Google drive root 'temp': 1 matching files
Elapsed time:        16.7s
```

**Timing:** upload start to copy complete = `14:53:21.976` -> `14:56:13.029` = **171.053 s**,
averaging **58.88 MiB/s**. rclone's own internal elapsed clock for the same copy reads
`2m49.4s` = **169.4 s**, averaging **59.46 MiB/s**. The two don't need to match exactly - rclone
starts its own clock slightly after `stop.log`'s "Uploading..." line, on file enumeration.
rclone's *displayed* `64.459 MiB/s` is neither of those averages - it is a recent-window rate,
confirmed by differencing the two progress snapshots above: `(9.836 - 6.728) GiB` transferred
over `(169.4 - 119.9)s` = `64.3 MiB/s`, matching. The `GiB` label is correct:
`10561165545 / 2^30 = 9.8358 GiB`, rounding to the `9.84 GiB` / `9.836 GiB` both logs report.
This is a direct, in-file contrast with the pre-fix `12:51:35` cycle two log-lines earlier in
the same `stop.log`, which reported `"9.84 GB"` for the identical numeric value - a
**6.83% unit error** (true GB would be `10.561 GB`), now corrected.

**Verify:** md5 hash comparison, **0 differences found**, **1 matching files** - corroborated
independently in `rclone.log`, not only in `stop.log`'s summary wrapper.

**Interlock held:** `"Safe to stop"` (`14:56:30.431`) precedes `"ec2:StopInstances accepted"`
(`14:56:31.772`) by **1.341 s**, and no stop call appears anywhere earlier in the window.

**Cross-stage byte agreement**, three independent sources, all within 233 bytes of each other:

| Source | Value |
|---|---|
| Topaz's own mux summary | `Lsize=10313638KiB` -> 10,561,165,312 bytes |
| `stop.log` upload/verify lines | `9.84 GiB (10561165545 bytes)` |
| `rclone lsl gdrive:temp` (live, §I) | 10,561,165,545 bytes |

The bytes announced, the bytes rclone copied, and the bytes ffmpeg wrote are the same file.

## G. The millisecond handoff - now fully resolvable

This is the concrete payoff of `00d21ef`'s timestamp fix. Every event in the completion-to-stop
handoff now carries its own distinct millisecond stamp, so the full sequence can be timed to the
millisecond rather than merely ordered by line number:

| Step | Time | Delta from previous |
|---|---|---|
| Stop sequence invoked | `14:53:21.854` | - |
| S3 sync skipped | `14:53:21.951` | +97 ms |
| Upload started | `14:53:21.976` | +25 ms |
| rclone copy completed | `14:56:13.029` | +171,053 ms |
| rclone check verified | `14:56:30.420` | +17,391 ms |
| "Safe to stop" | `14:56:30.431` | +11 ms |
| SNS notification skipped | `14:56:30.437` | +6 ms |
| Stopping now | `14:56:30.442` | +5 ms |
| `ec2:StopInstances` accepted | `14:56:31.772` | +1,330 ms |
| Waiting up to 300s | `14:56:31.779` | +7 ms |

Total, invoked to final line: **189.925 s**. Contrast with the pre-fix cycle in the same file:
four events there share the single stamp `[2026-07-27 12:51:35]` (stop invoked, S3 skip, upload
start, and the queue-complete line one section earlier all print the same whole second) and
four more share `[2026-07-27 12:54:38]` - that handoff could only ever be ordered by line
sequence, never timed. This run's is fully resolvable.

## H. What this run confirms about the guarantees the commit made, and what it doesn't yet cover

Of the fixes shipped in `00d21ef`, this run directly exercised and confirmed:

- **Millisecond + UTC-offset timestamps** on every line from `14:06:57.451` onward - 40/40
  lines in the run's window carry the new `.fff zzz` format, 0/4 of the immediately preceding
  lines do. This is what makes §G possible.
- **`GiB` labelling with the raw byte count alongside**, on both the upload-start and
  upload-verified lines (§F), directly contrasted against the pre-fix `"9.84 GB"` two lines
  earlier in the same file.
- **The heartbeat**, which fired six times at the expected ~320 s cadence with a workerIoBytes
  monotonic the whole way (§C) - the exact 4h49m-void failure mode docs/14 recorded cannot occur
  again inside the monitoring loop.

One thing this run exposed that the commit's guarantee does not yet reach: **the pre-GUI wait
loop is structurally outside the heartbeat mechanism**, and this run produced a real, in-window
361.258 s silent gap to prove it (§D). This is not a correctness defect - the loop does no
bookkeeping and gates no stop decision, so a hang there delays monitoring start rather than
producing a wrong decision - but it is a genuine, now-demonstrated blind spot in the
observability story. **It is being fixed in a follow-up change.**

WARN/ERROR emission to the console, per-check `preflight.log` persistence, and the
`Set-GoogleDriveAuth.ps1` / `Register-TimedStop.ps1` UTC-offset fixes were all confirmed correct
by direct code inspection and by evidence from around this run (a real preflight WARN at
`13:52:39.819`, a Pester run at `14:04:35`-`14:04:36` exercising the WARN/ERROR console path
two minutes before the commit), but none of those specific code paths was exercised by an
event *inside* the `14:06:57`-`14:56:31` window itself - the render logged zero WARN/ERROR, and
Google-Drive auth and the timed-stop deadline are one-time/manual tools nobody invoked this
cycle. This is stated plainly rather than claimed as directly observed.

## I. Google Drive and the scratch wipe

`rclone lsl gdrive:temp --config C:\topaz-autostop\rclone.conf` (read-only, run for this
document) at the time this render's own upload completed showed exactly one entry matching
§F's byte count. A **live check today** returns a different single entry:

```
1616764730 2026-07-28 05:46:00.000000000 SDR_Render_video3.mov
```

Not this render's file, and not its size. `rclone.log`'s last write is still `14:56:30` on
`2026-07-27` - **zero** `2026-07-28` entries - so this pipeline never touched `gdrive:temp`
again; the replacement happened out of band, roughly 13 minutes before the next watchdog boot
(`05:59:03`). **This is resolved, not an open question: the operator has confirmed they moved
the render from Drive to their local PC.** This is the same benign pattern
[docs/13 §H](13-first-end-to-end-run.md#h-is-the-render-now-in-google-drive-is-drenders-empty)
and [docs/14 §H](14-second-end-to-end-run.md#h-google-drive-and-the-scratch-wipe) each recorded
once before - `gdrive:temp` is a single-slot handoff folder, not a permanent archive, and the
pipeline's own mandatory verify-before-stop gate (§F) had already, independently, confirmed the
file landed intact before the operator's own later action touched it at all.

`D:\Renders` is confirmed currently **empty** (`Get-ChildItem -Force` returns nothing) on the
`2026-07-28 05:59` boot, and `D:\Source` does not exist - the same total-wipe, ephemeral-volume
behaviour docs/13 and docs/14 both confirmed, and simultaneously the proof that stopping without
a verified upload would have destroyed this render.

## J. Scratch re-provisioning on the new boot

```
[2026-07-28 05:59:10.263 +00:00] [INFO] Selected Disk 1 (419.1 GiB, serial=E8E8_5EB2_96BF_2A3F_0100_0000_00CD_B440.) as the instance-store scratch disk.
[2026-07-28 05:59:13.846 +00:00] [INFO] Scratch drive ready: D: 'RenderScratch' 419.1 GiB, output directory 'D:\Renders' created (only this directory is uploaded).
```

The disk's `SerialNumber` is the fourth distinct value recorded across this box's four logged
boots (`...92CC.` -> `...824F_F4FC.` -> `...07C2_962F.` -> `...96BF_2A3F.`) - physical-layer
proof of a freshly-issued instance-store device, not a relabel. Provisioning completed
`~20-24s` after `LastBootUpTime` (`05:58:50.500`), on the startup-trigger schedule as intended.
No WARN or ERROR appears anywhere in `scratch.log`'s 14-line history; the partial-format
recovery path added in commit `e8b00d0` was not needed and has still not been exercised in
production. Both this boot's lines also carry the new `GiB` label (the prior boot's equivalent
line reads `GB`) - the same relabelling fix landed in the same commit, exercised here for the
first time in `scratch.log`.

## K. GPU telemetry: a genuine, healthy-render near-miss for the idle alarm

`metric.log` published on **50 of 50** expected one-per-minute attempts across the `14:07`-`14:56`
window (min gap `38.469s`, max `81.217s`, mean `59.988s` - never a skipped minute), with **zero**
WARN/ERROR anywhere in the window. This is the primary safety-net telemetry working correctly.
But its *content* this run surfaces a real, previously-undocumented empirical finding, distinct
from anything in [docs/12](12-empirical-findings.md):

**GPU utilization read under 5% for 25 consecutive one-per-minute samples during a
confirmed-healthy render:**

```
[2026-07-27 14:16:25.209 +00:00] [INFO] Published TopazRender/GPU/GPUUtilization=0% for i-029f35d589bec9b9c in us-west-2.
   ... 0,0,2,0,0,0,0,2,2,0,1,0,0,0,0,2,1,0,0,0,0,0,0,0 ...
[2026-07-27 14:40:25.070 +00:00] [INFO] Published TopazRender/GPU/GPUUtilization=0% for i-029f35d589bec9b9c in us-west-2.
```

- broken only by a burst at the tail end of compute:

```
[2026-07-27 14:41:25.449 +00:00] [INFO] Published TopazRender/GPU/GPUUtilization=100% for i-029f35d589bec9b9c in us-west-2.
[2026-07-27 14:42:25.134 +00:00] [INFO] Published TopazRender/GPU/GPUUtilization=100% for i-029f35d589bec9b9c in us-west-2.
[2026-07-27 14:43:25.500 +00:00] [INFO] Published TopazRender/GPU/GPUUtilization=28% for i-029f35d589bec9b9c in us-west-2.
[2026-07-27 14:44:25.411 +00:00] [INFO] Published TopazRender/GPU/GPUUtilization=100% for i-029f35d589bec9b9c in us-west-2.
```

That is a **25-minute** sustained sub-5% streak, **five minutes short** of the out-of-band
CloudWatch idle alarm's default 30-consecutive-minute breach window
(`control-plane/03-create-idle-alarm.sh`), on a box that was, by every other measure, genuinely
rendering: `watchdog.log`'s own heartbeat at `14:36:17.795` (inside this exact streak) shows
`workerIoBytes=7803799158` and climbing. Nothing bad happened this cycle - the render finished
and the watchdog stopped the box on its own schedule, and the genuine post-completion idle
window (`14:48` render-idle to `14:56:31` stop-accepted, ~8.5 minutes) never came close to 30
minutes on its own. But combined with the already-documented opposite failure - a connected DCV session holding the
GPU above the alarm's 5% threshold so it can never fire at all
([docs/14 §J](14-second-end-to-end-run.md#j-errors-warnings-and-anomalies): "measured at 13:38
with *no* Topaz process running, the GPU read 26%... The alarm's threshold is sustained
sub-5%... with a session connected it is inert") - this run establishes the GPU signal is
untrustworthy **in both directions**: too high to read idle when an operator is merely
connected, and now measurably too low to read busy during a real, healthy render.
[docs/12 §5](12-empirical-findings.md#5-what-this-means-for-configps1) already concludes the GPU
is unusable as a **completion signal**, which is exactly why `CompletionSignal='WorkerOnly'` and
why this run's actual stop decision was provably unaffected - the primary path never reads GPU
at all. But the out-of-band **alarm** still does. **A follow-up change is addressing this.**

As context, not a new finding: elevated GPU readings (`14-68%`) appear in `metric.log`
*before* Topaz was even detected (`14:00`-`14:12`, versus GUI detection at `14:12:58.709`),
consistent with the already-established DCV-load-inflates-GPU behaviour.

The metric task also survived the stop and resumed independently of the watchdog: last `07-27`
push `14:56:21.661` (10.111 s before the API stop was accepted), first `07-28` push
`05:59:26.609`, only 23.186 s after the new watchdog process's own restart line.

## L. Was `ec2:StopInstances` accepted, and did the OS go down cleanly?

Accepted, then confirmed independently from the OS side - the first time in this deployment's
forensic history that the stop can be checked from *both* the pipeline's own log and Windows'
own event trail with millisecond precision on each side.

```
[2026-07-27 14:56:30.442 +00:00] [INFO] Stopping now (reason=completed). StopStrategy='Auto', plan=[Ec2ApiStop -> GuestShutdown].
[2026-07-27 14:56:31.772 +00:00] [INFO] ec2:StopInstances accepted for i-029f35d589bec9b9c. The instance should transition to 'stopping' shortly.
[2026-07-27 14:56:31.779 +00:00] [INFO] Waiting up to 300s for the instance to actually go down.
```

That is the last line of `stop.log`. Windows' own System event log, queried directly for this
document, shows a **clean, single-pass ACPI shutdown chain**:

| Event | Time | Detail |
|---|---|---|
| `1074` User32 | `14:56:33.798` | `winlogon.exe ... on behalf of user NT AUTHORITY\SYSTEM ... Shutdown Type: power off` |
| `6006` EventLog | `14:56:34.016` | Event log service stopped - clean shutdown marker |
| `109` Kernel-Power | `14:56:38.952` | Kernel power manager initiated the shutdown transition, `Action: Power Action Shutdown Off`, `Reason: Kernel API` |
| `13` Kernel-General | `14:56:39.758` | `The operating system is shutting down at system time 2026-07-27T14:56:39.758051800Z.` |

**OS-shutdown-complete (`14:56:39.758`) is 7.99 s after the API stop was accepted
(`14:56:31.772`)** - 2.7% of the 300 s `StopVerifySec` budget, no `GuestShutdown` escalation.
Contrast with the `03:00:31` cycle in this same `stop.log` (quoted in docs/13 §F), which *did*
escalate after 90 s of a then-shorter `StopVerifySec` - the exact measurement that motivated
raising the value to 300 s. A direct query for `6008` (unexpected shutdown), Kernel-Power `41`
(dirty shutdown/power loss), and `BugCheck`/`1001` across the entire `14:56` (07-27) ->
`06:05` (07-28) window returns **zero** matches - a genuinely blank interval, not merely an
absence of contrary evidence in one log.

One cosmetic curiosity, recorded so it is not rediscovered: Kernel-Power event `577` at
`14:56:39.396` reads "The system has prepared for a system initiated **reboot** from Active,"
even though the action logged one event earlier (`109`) was explicitly `Power Action Shutdown
Off`. This is Windows' generic power-transition template reusing the word "reboot" regardless
of whether the transition is a restart or a power-off - not evidence of an actual restart, since
no boot occurred again for another 15 hours and Kernel-Boot event `20` explicitly confirms both
endpoints ("The last shutdown's success status was true. The last boot's success status was
true.").

**Stopped interval:** OS-shutdown-complete `14:56:39.758` (07-27) to OS-boot-start `05:58:50.500`
(07-28, confirmed both by Kernel-General event `12` and by
`(Get-CimInstance Win32_OperatingSystem).LastBootUpTime`) = **15 h 2 m 10.7 s** of billed
compute avoided.

## M. The honest limit on this verification: attribution from the AWS control plane

Every source above is guest-side. This document also attempted to attribute the stop
independently, from AWS's own control plane, and that attempt was **only partially
successful** - said plainly here rather than left implicit. The instance role denies
`cloudtrail:LookupEvents` (blocks WHO/what called both this `StopInstances` and the following
day's `StartInstances`), `cloudwatch:DescribeAlarms` / `DescribeAlarmHistory` /
`GetMetricStatistics` / `ListMetrics` (blocks confirming the idle alarm did not fire, and blocks
an AWS-side read-back of the GPU metric datapoints), `logs:DescribeLogGroups` and
`lambda:ListFunctions` (blocks ruling the max-lifetime Lambda in or out), and
`iam:List*RolePolicies` (blocks reading the role's policy document directly).

What **was** readable is consistent with, but does not independently prove, the completion path:
`InstanceInitiatedShutdownBehavior = 'stop'` (confirmed directly), 57 successful
`PutMetricData` writes across the render window with zero errors, and a `LaunchTime` of
`2026-07-28T05:58:43+00:00` - consistent with an intervening stop/start cycle (LaunchTime only
advances on a genuine start-from-stopped transition, never a mere reboot). Attribution to the
completion path therefore rests on guest-side evidence: the watchdog's own explicit logged call
(§L), the total absence of any `arn:aws:automate:...:ec2:stop` text anywhere in `stop.log`, and
OS shutdown events beginning 1-6 seconds later (§L). That chain is strong, and self-consistent
across every source this investigation *could* read - but it is not the independent,
outside-the-guest proof the task set out to obtain, and this document says so rather than
overclaiming.

---

## Verdict

**Yes, end to end, first attempt, no faults in the render or the stop decision - and every
observability guarantee under test held where it was designed to, with one disclosed, narrower
gap.** Topaz completed a two-stage 4K AI-enhance-and-mux export with zero crashes and zero
`error occurred` lines - cleaner than either prior documented run (§A); the watchdog correctly
withheld arming on a brief, unexplained ~35 s worker sighting and armed only on the real render,
proven by branch transition rather than a dedicated line (§B); six heartbeats fired at the
expected ~320 s cadence (not exactly 300 s, and correctly so, by construction) with
`workerIoBytes` climbing monotonically the whole time, closing the exact 4h49m-void failure mode
docs/14 exposed (§C); the queue was declared complete after exactly 20 debounce polls with no
gaps, the unlock gate passed in 104 ms, and the completion was detected 2.013 s after the mux
actually exited (§E); 9.84 GiB was uploaded and md5-verified with 0 differences, and for the
first time the entire invoke-to-stopping handoff is resolvable to the millisecond rather than
sharing whole-second stamps (§F, §G); `ec2:StopInstances` was accepted and Windows' own event
log independently confirms a clean ACPI shutdown 7.99 s later, no escalation, no unexpected-
shutdown record anywhere in the following 15 hours (§L); and the scratch volume was destroyed
and correctly re-provisioned on the next boot, with the render's own byte count intact at every
stage until the operator's own later, confirmed, benign relocation of the file (§I, §J).

Of seven anomalies an adversarial multi-agent investigation raised against this run, six were
refuted under skeptic review - stale documentation, a stale code comment, a preflight run that
predates the deploy by design rather than defect, and three misreadings of already-documented,
already-designed-around limitations. **The one survivor is genuine and is recorded plainly: the
heartbeat's silence guarantee does not yet reach the pre-GUI wait loop, and this run produced a
real 361.258 s gap to prove it (§D).** It had no bearing on this run's correctness - the loop
does no bookkeeping and gates no decision - but it is a real blind spot the previous commit's
fix did not reach. A second, independent finding earned its own section rather than being
folded in as an anomaly: GPU utilization read under 5% for 25 of the render's active minutes,
five short of the out-of-band idle alarm's 30-minute breach window, on a confirmably healthy
render (§K) - harmless to this run's primary stop path by design, but a genuine near-miss for
the redundant safety net. **Both gaps are being addressed in follow-up changes.** The one thing
this document could not do - attribute the stop from AWS's own control plane, independent of the
guest's own logs - remains out of reach under this role's IAM grant, and is stated as a limit,
not glossed over (§M).

---

Back to the [README](../README.md).
