# 12 - Empirical Findings: Live-Measured Process Topology & I/O Behavior

[README](../README.md) - [Architecture](01-architecture.md) - [Phase 0](02-phase0-confirmations.md) - [Phase 1](03-phase1-instance-prep.md) - [Phase 2](04-phase2-watchdog.md) - [Phase 3](05-phase3-stop-sequence.md) - [Phase 4](06-phase4-safety-net.md) - [Phase 5](07-phase5-notifications.md) - [Appendix A](08-appendix-a-corrections.md) - [Appendix B](09-appendix-b-boundaries.md) - [Testing & CI](10-testing-and-ci.md) - **Empirical Findings**

## Method and provenance

Every claim in this document is derived from one of two live measurements taken
on the actual GPU instance (`i-029f35d589bec9b9c`, `g6e.2xlarge`, `us-west-2`)
while a real, operator-started Topaz Video AI export was in progress - not a
synthetic test, and nothing about the render was touched, paused, or killed to
produce this data:

1. **An NDJSON time-series sampler**, polling every 10 seconds and recording,
   per sample: GPU utilization/memory (`nvidia-smi`), the Topaz GUI's PID count
   and its **direct** CIM `Win32_Process` children (`name#pid`), every
   `neuroserver*`/`ffmpeg*`/`ffprobe*` process on the box with `{name, pid,
   ppid, ws, rd, wr}` (`rd`/`wr` are the process's cumulative
   `ReadTransferCount`/`WriteTransferCount` I/O counters), and `{name, len,
   mtime, locked}` for every file in the output directory
   (`C:\Users\Administrator\Downloads`).
2. **Direct, one-off live queries** run against the same, still-running
   processes: `Get-CimInstance Win32_Process` for exact command lines and
   parent PIDs, and `Get-Process ... | Select StartTime` for process-creation
   timestamps. These are called out explicitly below wherever they - rather
   than the NDJSON stream - are the source of a number, because the sampler
   was started *after* the render had already been underway for several
   minutes and cannot see anything before its own first sample.

**The window this document analyzes**: 94 consecutive samples, timestamps
`2026-07-26T20:40:58.3045215+00:00` through `2026-07-26T20:56:40.4245041+00:00`
(a **942.12 s / 15 min 42.1 s** span, sample-to-sample gaps consistently
~10.1-10.2 s). Across all 94 samples the box ran exactly **one** Topaz GUI
process (`guiCount == 1`), exactly **two** direct GUI children, and exactly
**two** worker entries - no sample ever showed a different count, and no
`ffprobe.exe` was ever observed (not observed in this window). At the last
sample analyzed the render had **not** completed - see [§6](#6-completion-transition).
The sampler kept running after this window closed; this document deliberately
freezes its analysis at sample 94 so every number below is reproducible against
a fixed, stated dataset instead of a moving target.

---

## 1. Observed process topology

```
explorer.exe (PID 3824)                         <- DCV interactive-session shell
  |
  +-- Topaz Video.exe (PID 11980)                <- GUI, StartTime 20:28:45
        |  (direct CIM children, EVERY one of the 94 samples, no exceptions)
        |
        +-- crashpad_handler.exe (PID 1644)      <- StartTime 20:28:46
        |     crash-reporter sidecar, spawned ONCE at GUI launch;
        |     unrelated to any queue item, present the whole session.
        |
        +-- neuroserver.exe (PID 10680)          <- StartTime 20:30:50, flag: --once
              |  (per-queue-item worker; see #2)
              |
              +-- ffmpeg.exe (PID 9396)           <- StartTime 20:40:32
                    GRANDCHILD of the GUI. Confirmed via
                    Get-CimInstance Win32_Process -Filter "ProcessId=9396":
                    ParentProcessId = 10680 (neuroserver), NOT 11980 (GUI).
```

**`ffmpeg.exe` is a grandchild of the GUI, never a direct child.** This was
verified directly (`Get-CimInstance Win32_Process` on the live PID), not
inferred: PID 9396's `ParentProcessId` is `10680`, and PID 10680's own
`ParentProcessId` is `11980`. Every one of the 94 NDJSON samples corroborates
this indirectly too - the GUI's own `children[]` array is `[crashpad_handler.exe#1644,
neuroserver.exe#10680]` in all 94 samples (one distinct set, never varying;
`ffmpeg.exe` never appears in it), while the separate `workers[]` array (which
scans the whole box by name, not by ancestry) shows `neuroserver.exe#10680` and
`ffmpeg.exe#9396` together in all 94 samples, with `ffmpeg.exe`'s own `ppid`
field reading `10680` in every single one.

A previously written project diagram ([01-architecture.md](01-architecture.md))
draws `Topaz Video AI (GUI) --spawns--> ffmpeg.exe` as a single, direct arrow.
That is now known - from this measurement, not assumption - to omit an
intermediate hop; `in-guest/Config.ps1`'s `WorkerNamesLike` comment already
documents the corrected three-level chain and cites this file. This document
does not edit `01-architecture.md`'s diagram (out of scope here), but the
discrepancy is recorded so it isn't silently rediscovered later.

**Corroborating evidence from the I/O counters themselves.** `neuroserver.exe`
pipes raw decoded video into `ffmpeg.exe`'s stdin (`ffmpeg`'s own command line
reads `-f rawvideo ... -i -`, i.e. "read raw frames from stdin" - see §2).
`neuroserver`'s cumulative **`wr`** (bytes it has written, i.e. pushed into
that pipe) tracks `ffmpeg`'s cumulative **`rd`** (bytes it has read from
stdin) to within a few hundred KB at every sample, confirmed at three widely
separated points in the window:

| Sample | ts (UTC) | neuroserver cumulative `wr` | ffmpeg cumulative `rd` | difference |
|---|---|---|---|---|
| 1  | 20:40:58 | 622,115,484   | 622,080,000   | 35,484 |
| 33 | 20:46:23 | 1,866,311,756 | 1,866,240,000 | 71,756 |
| 94 | 20:56:40 | 3,732,620,425 | 3,732,480,000 | 140,425 |

The difference is always tiny relative to the multi-gigabyte totals (< 0.004%
in every case, just the data still sitting in the OS pipe buffer) - this is a
live-measured, quantitative confirmation that the two processes are opposite
ends of one data pipeline, not two unrelated workers that merely happen to
run concurrently.

## 2. `neuroserver`'s invocation and what it implies

Captured live via `Get-CimInstance Win32_Process -Filter "ProcessId=10680" |
Select CommandLine` while the process was running:

```
"C:\Program Files\Topaz Labs LLC\Topaz Video\neuroserver\neuroserver"  --once
  --input-path C:/Users/Administrator/Downloads/SDR_Render_video.mp4
  --output-path C:/Users/Administrator/Downloads/SDR_Render_video_181094049.mov
  --start-frame-idx 0 --end-frame-idx 2898
  --ffmpeg-preproc-filters ""
  --max-gpu-mem 44
  --filters "[{\"model\": \"slp-25\"}]"
  --output-width 3840 --output-height 2160 --upscale-factor 1
  --ffmpeg-encoding "-c:v dnxhd -pix_fmt yuv422p10le -strict experimental
    -profile:v dnxhr_hqx -movflags
    frag_keyframe+empty_moov+delay_moov+use_metadata_tags+write_colr -bf 0"
```

| Argument | Value | Implication |
|---|---|---|
| `--once` | (flag) | Exactly one queue item is serviced per invocation; the process exits when that item finishes. This is the load-bearing fact behind §2's conclusion below. |
| `--input-path` | `.../SDR_Render_video.mp4` | Matches the input file held `locked` in `files[]` across all 94 samples - same job, start to finish, no PID churn. |
| `--output-path` | `.../SDR_Render_video_181094049.mov` | Matches the exact output filename tracked in every sample's `files[]`. |
| `--start-frame-idx` / `--end-frame-idx` | `0` / `2898` | A closed, numbered range (2,899 frames), not "until EOF" - this is how a multi-item / multi-segment queue is partitioned: each item gets its own `neuroserver` invocation with its own range. |
| `--ffmpeg-preproc-filters` | `""` | No pre-encode filter chain requested for this item. |
| `--max-gpu-mem` | `44` | GB budget on the 48 GB L40S, leaving headroom for the OS/DCV session. |
| `--filters` | `[{"model": "slp-25"}]` | A single AI model stage applied to the frames. |
| `--output-width` / `--output-height` | `3840` / `2160` | 4K UHD output. |
| `--upscale-factor` | `1` | Output resolution equals input resolution - this pass is not spatially upscaling despite the AI model stage (consistent with a restoration/denoise-class model rather than a super-resolution one). |
| `--ffmpeg-encoding` | `-c:v dnxhd -pix_fmt yuv422p10le ... -movflags frag_keyframe+empty_moov+delay_moov+...` | Passed **verbatim** into the grandchild `ffmpeg.exe`'s own argv (byte-identical, confirmed by separately capturing `ffmpeg`'s live command line). DNxHR HQX, 10-bit 4:2:2, with a **fragmented, delayed-moov** MOV container - directly relevant context for §3. |

**Conclusion:** `neuroserver`'s process lifetime **is** exactly one queue
item's lifetime. Every sample in the 94-sample window shows the same PID
(`10680`), the same `--input-path`/`--output-path` pair, and the process
still running with zero interruption from the moment the sampler started
(`20:40:58`) through its last sample (`20:56:40`) - and, per its own
`--once` flag plus the closed frame range, it will exit exactly once this
range has been fully processed and not before. `ffmpeg.exe`, by contrast, is
a shorter-lived sub-phase within that lifetime (see §4).

## 3. THE KEY EVIDENCE: reported file length vs. actual bytes written

For every sample, `files[]` reports the output `.mov`'s directory-entry
length (what `Get-ChildItem ... | Measure-Object -Property Length -Sum`
would sum), and `workers[]` reports `ffmpeg.exe`'s own cumulative
`WriteTransferCount` (`wr`) - the actual number of bytes the OS has recorded
that process as having written, independent of what any directory listing
says. The full 94-sample table:

| # | Wall clock (UTC) | GPU % | .mov dir-length (bytes) | ffmpeg WriteTransferCount (bytes) | delta since prior sample |
|---|---|---|---|---|---|
| 1 | 20:40:58 | 100 | 0 | 58,204,037 | - |
| 2 | 20:41:08 | 96 | 0 | 58,206,577 | 2,540 |
| 3 | 20:41:18 | 97 | 0 | 58,208,996 | 2,419 |
| 4 | 20:41:29 | 83 | 0 | 58,211,413 | 2,417 |
| 5 | 20:41:39 | 81 | 0 | 58,213,831 | 2,418 |
| 6 | 20:41:49 | 76 | 0 | 58,216,381 | 2,550 |
| 7 | 20:41:59 | 100 | 0 | 58,218,820 | 2,439 |
| 8 | 20:42:09 | 100 | 0 | 58,221,259 | 2,439 |
| 9 | 20:42:19 | 100 | 0 | 58,223,695 | 2,436 |
| 10 | 20:42:29 | 91 | 58,195,968 | 58,226,133 | 2,438 |
| 11 | 20:42:39 | 100 | 58,195,968 | 58,228,691 | 2,558 |
| 12 | 20:42:49 | 100 | 58,195,968 | 58,231,128 | 2,437 |
| 13 | 20:43:00 | 96 | 58,195,968 | 58,233,565 | 2,437 |
| 14 | 20:43:10 | 100 | 58,195,968 | 58,236,003 | 2,438 |
| 15 | 20:43:20 | 15 | 58,195,968 | 149,202,410 | 90,966,407 |
| 16 | 20:43:30 | 97 | 58,195,968 | 149,204,951 | 2,541 |
| 17 | 20:43:40 | 91 | 58,195,968 | 149,207,389 | 2,438 |
| 18 | 20:43:50 | 100 | 58,195,968 | 149,209,827 | 2,438 |
| 19 | 20:44:00 | 100 | 58,195,968 | 149,212,265 | 2,438 |
| 20 | 20:44:11 | 81 | 58,195,968 | 149,214,701 | 2,436 |
| 21 | 20:44:21 | 79 | 58,195,968 | 149,217,140 | 2,439 |
| 22 | 20:44:31 | 95 | 58,195,968 | 149,219,578 | 2,438 |
| 23 | 20:44:41 | 76 | 58,195,968 | 149,222,138 | 2,560 |
| 24 | 20:44:51 | 100 | 58,195,968 | 149,224,576 | 2,438 |
| 25 | 20:45:02 | 93 | 58,195,968 | 149,227,014 | 2,438 |
| 26 | 20:45:12 | 100 | 58,195,968 | 149,229,452 | 2,438 |
| 27 | 20:45:22 | 100 | 58,195,968 | 149,231,890 | 2,438 |
| 28 | 20:45:32 | 75 | 58,195,968 | 149,234,449 | 2,559 |
| 29 | 20:45:42 | 76 | 58,195,968 | 149,236,887 | 2,438 |
| 30 | 20:45:52 | 94 | 58,195,968 | 149,239,324 | 2,437 |
| 31 | 20:46:02 | 87 | 58,195,968 | 149,241,763 | 2,439 |
| 32 | 20:46:12 | 9 | 58,195,968 | 163,924,386 | 14,682,623 |
| 33 | 20:46:23 | 96 | 58,195,968 | 240,210,726 | 76,286,340 |
| 34 | 20:46:33 | 91 | 58,195,968 | 240,213,164 | 2,438 |
| 35 | 20:46:43 | 96 | 58,195,968 | 240,215,603 | 2,439 |
| 36 | 20:46:53 | 100 | 58,195,968 | 240,218,163 | 2,560 |
| 37 | 20:47:03 | 96 | 58,195,968 | 240,220,601 | 2,438 |
| 38 | 20:47:13 | 70 | 58,195,968 | 240,223,038 | 2,437 |
| 39 | 20:47:23 | 88 | 58,195,968 | 240,225,475 | 2,437 |
| 40 | 20:47:33 | 78 | 58,195,968 | 240,227,913 | 2,438 |
| 41 | 20:47:44 | 94 | 58,195,968 | 240,230,473 | 2,560 |
| 42 | 20:47:54 | 100 | 58,195,968 | 240,232,911 | 2,438 |
| 43 | 20:48:04 | 100 | 58,195,968 | 240,235,347 | 2,436 |
| 44 | 20:48:14 | 100 | 58,195,968 | 240,237,785 | 2,438 |
| 45 | 20:48:24 | 92 | 58,195,968 | 240,240,221 | 2,436 |
| 46 | 20:48:34 | 100 | 58,195,968 | 240,242,779 | 2,558 |
| 47 | 20:48:44 | 94 | 58,195,968 | 240,245,217 | 2,438 |
| 48 | 20:48:54 | 96 | 58,195,968 | 240,247,656 | 2,439 |
| 49 | 20:49:04 | 100 | 58,195,968 | 240,250,094 | 2,438 |
| 50 | 20:49:15 | 34 | 58,195,968 | 331,478,643 | 91,228,549 |
| 51 | 20:49:25 | 100 | 58,195,968 | 331,481,204 | 2,561 |
| 52 | 20:49:35 | 100 | 58,195,968 | 331,483,642 | 2,438 |
| 53 | 20:49:45 | 97 | 58,195,968 | 331,486,080 | 2,438 |
| 54 | 20:49:55 | 96 | 58,195,968 | 331,488,519 | 2,439 |
| 55 | 20:50:05 | 54 | 58,195,968 | 331,491,078 | 2,559 |
| 56 | 20:50:15 | 93 | 58,195,968 | 331,493,516 | 2,438 |
| 57 | 20:50:26 | 86 | 331,350,016 | 331,495,954 | 2,438 |
| 58 | 20:50:36 | 95 | 331,350,016 | 331,498,392 | 2,438 |
| 59 | 20:50:46 | 100 | 331,350,016 | 331,500,952 | 2,560 |
| 60 | 20:50:56 | 100 | 331,350,016 | 331,503,390 | 2,438 |
| 61 | 20:51:06 | 100 | 331,350,016 | 331,505,828 | 2,438 |
| 62 | 20:51:16 | 100 | 331,350,016 | 331,508,264 | 2,436 |
| 63 | 20:51:26 | 100 | 331,350,016 | 331,510,701 | 2,437 |
| 64 | 20:51:36 | 96 | 331,350,016 | 331,513,261 | 2,560 |
| 65 | 20:51:46 | 100 | 331,350,016 | 331,515,699 | 2,438 |
| 66 | 20:51:57 | 100 | 331,350,016 | 331,518,139 | 2,440 |
| 67 | 20:52:07 | 12 | 331,350,016 | 422,484,545 | 90,966,406 |
| 68 | 20:52:17 | 100 | 331,350,016 | 422,486,981 | 2,436 |
| 69 | 20:52:27 | 96 | 331,350,016 | 422,489,541 | 2,560 |
| 70 | 20:52:37 | 100 | 331,350,016 | 422,491,979 | 2,438 |
| 71 | 20:52:47 | 100 | 331,350,016 | 422,494,417 | 2,438 |
| 72 | 20:52:57 | 67 | 331,350,016 | 422,496,855 | 2,438 |
| 73 | 20:53:07 | 93 | 331,350,016 | 422,499,293 | 2,438 |
| 74 | 20:53:18 | 97 | 331,350,016 | 422,501,853 | 2,560 |
| 75 | 20:53:28 | 98 | 331,350,016 | 422,504,291 | 2,438 |
| 76 | 20:53:38 | 93 | 331,350,016 | 422,506,731 | 2,440 |
| 77 | 20:53:48 | 100 | 331,350,016 | 422,509,169 | 2,438 |
| 78 | 20:53:58 | 94 | 331,350,016 | 422,511,607 | 2,438 |
| 79 | 20:54:08 | 100 | 331,350,016 | 422,514,163 | 2,556 |
| 80 | 20:54:18 | 94 | 331,350,016 | 422,516,603 | 2,440 |
| 81 | 20:54:28 | 100 | 331,350,016 | 422,519,041 | 2,438 |
| 82 | 20:54:39 | 100 | 331,350,016 | 422,521,478 | 2,437 |
| 83 | 20:54:49 | 100 | 331,350,016 | 422,523,915 | 2,437 |
| 84 | 20:54:59 | 86 | 331,350,016 | 451,624,461 | 29,100,546 |
| 85 | 20:55:09 | 95 | 331,350,016 | 513,492,882 | 61,868,421 |
| 86 | 20:55:19 | 89 | 331,350,016 | 513,495,319 | 2,437 |
| 87 | 20:55:29 | 100 | 331,350,016 | 513,497,758 | 2,439 |
| 88 | 20:55:39 | 90 | 331,350,016 | 513,500,197 | 2,439 |
| 89 | 20:55:49 | 86 | 331,350,016 | 513,502,756 | 2,559 |
| 90 | 20:55:59 | 86 | 331,350,016 | 513,505,194 | 2,438 |
| 91 | 20:56:10 | 73 | 331,350,016 | 513,507,634 | 2,440 |
| 92 | 20:56:20 | 100 | 331,350,016 | 513,510,071 | 2,437 |
| 93 | 20:56:30 | 81 | 331,350,016 | 513,512,508 | 2,437 |
| 94 | 20:56:40 | 95 | 331,350,016 | 513,515,070 | 2,562 |

### The numbers

- **Total samples analyzed:** 94.
- **Wall-clock span:** 942.12 s (15 min 42.1 s), `20:40:58` -> `20:56:40`.
- **The directory-reported length held at exactly three constant values for
  the entire window**, never once tracking the encoder's actual write
  volume in between:
  - `0` for **9 samples / 81.3 s** (`20:40:58` -> `20:42:19`), while `ffmpeg`'s
    own counter still rose by 19,658 bytes.
  - `58,195,968` for **47 samples / 466.2 s (7 min 46.2 s)**
    (`20:42:29` -> `20:50:15`) - the longest, cleanest plateau - while
    `ffmpeg`'s `WriteTransferCount` climbed from `58,226,133` to
    `331,493,516`, a rise of **273,267,383 bytes (~260.6 MiB)**, entirely
    invisible to a directory listing.
  - `331,350,016` for **38 samples / 374.4 s (6 min 14.4 s) and still
    climbing** as of the last sample analyzed (`20:56:40`), during which
    `ffmpeg`'s counter rose a further **182,019,116 bytes**.
- **Total `WriteTransferCount` delta over the full 942.12 s window:**
  `513,515,070 - 58,204,037 =` **455,311,033 bytes (~434.2 MiB)** actually
  written by `ffmpeg`, versus a directory-length delta over that same
  start-to-end span of only `331,350,016 - 0 = 331,350,016` bytes - the
  directory listing under-reports even the **net**, start-to-finish change
  by **123,961,017 bytes (27.1%)**, before even counting the multi-minute
  stretches where it reports zero change at all.

### Supporting detail: the write pattern is bursty, and the bursts are round numbers

The large jumps in `ffmpeg`'s `WriteTransferCount` (samples 15, 32-33, 50, 67,
84-85) recur roughly every **172-183 s** and each totals **~90.97 million
bytes**, coinciding with brief GPU utilization dips (as low as **9%** at
sample 32 and **12%** at sample 67) - consistent with `neuroserver` handing
`ffmpeg` one batch of frames at a time rather than a continuous stream.
`neuroserver`'s own `rd`/`wr` counters (not shown in the table above, but
present in the raw samples) jump in lockstep, in steps of exactly
`622,080,000` bytes - which is exactly `3840 x 2160 x 3 x 25` (25 raw
`3840x2160` RGB24 frames), i.e. a 25-frame processing batch, compressed down
to the observed ~91 MB burst (a ~6.8:1 ratio), consistent with the
`dnxhr_hqx` encode requested via `--ffmpeg-encoding`. This is offered as
corroborating color, not a load-bearing claim of this document.

### The conclusion

**On NTFS, the directory entry for a file is not refreshed while a process
holds an open write handle on it.** Summing `Get-ChildItem ... Length` over
the output directory is therefore **not a valid render-progress signal**: for
466.2 seconds straight - with `ffmpeg` actively writing 260+ MiB of real
output and the GPU pegged at up to 100% - the reported size never moved. A
stall detector that treats "directory total unchanged for N seconds" as
"render dead" **will** fire a false `stalled` verdict during a perfectly
healthy render, for any threshold shorter than the freeze windows actually
observed here. The longest freeze measured so far (466.2 s) is comfortably
inside `in-guest/Config.ps1`'s configured `StallSec = 1800` (30 min), so this
specific render would **not** have false-stalled under the current setting -
but that is a matter of configured margin over a measured hazard, not proof
the byte-sum signal is sound; it is exactly why `Config.ps1` already
documents `Get-OutputBytes`/the folder byte-total as a **secondary** signal
only, never the sole basis for a stall verdict.

## 4. Timing of the analysis phase, and why `ffmpeg` alone is an unsafe "active" signal

`neuroserver.exe` (PID 10680) has `StartTime = 2026-07-26 20:30:50`;
`ffmpeg.exe` (PID 9396) has `StartTime = 2026-07-26 20:40:32` (both captured
live via `Get-Process ... | Select StartTime` against the still-running
processes - **this number is not visible in the NDJSON itself**, because the
sampler's own first sample, `20:40:58`, is already 26 seconds *after* `ffmpeg`
had started; the NDJSON alone cannot show the gap, only the direct process
metadata can, which is why it is called out here explicitly).

**Measured gap: `20:40:32 - 20:30:50 = 582 seconds (9 min 42 s)`** during
which `neuroserver` ran alone - the analysis phase - before `ffmpeg` existed
at all. This matches (and sharpens, from "roughly 20:40" to an exact
second-resolution figure) the phase boundary the render was already known to
have crossed. Once `ffmpeg` did appear, it stayed alive, under the same PID,
for the entire remainder of the 94-sample window with `neuroserver` still its
parent throughout - no restart, no PID churn on either process (`Distinct
neuroserver PIDs seen: 10680`; `Distinct ffmpeg PIDs seen: 9396`).

### Conclusion

A completion-detector that treats **"a live `ffmpeg` process" alone** as
"render active" is unsafe on a multi-item queue. Each queue item gets its own
fresh `neuroserver --once` invocation (§2), and each one of those must repeat
its own analysis phase before spawning its own `ffmpeg` child - so an
`ffmpeg`-only signal would show a **worker-absent window of similar
magnitude (measured here at 582 s) at the start of every single queued
item**, not just the first. `in-guest/Config.ps1`'s `DebounceSec` is `300`
(5 min) - **582 s > 300 s** - so if `ffmpeg` alone were the trusted signal,
the watchdog would accumulate idle time straight through a second item's
analysis phase, cross the debounce threshold, and declare the queue
`completed` mid-queue, powering the box off while a second, already-queued
input file (`SDR_Render_short.mp4` - see §6) still sits unprocessed.
`neuroserver.exe` does not have this gap: it is present, under one PID,
across the entire item lifetime, analysis phase included, which is exactly
why `Config.ps1`'s `WorkerNamesLike` lists it (and treats it as the primary
signal) rather than relying on `ffmpeg.exe` in isolation.

## 5. What this means for `Config.ps1`

The measurements above are not abstract; they map directly onto specific
tunables already defined in `in-guest/Config.ps1` (not modified by this
document - it is read-only evidence for values another engineer owns):

- **`WorkerNamesLike = @('neuroserver.exe', 'ffmpeg.exe')`, with
  `neuroserver.exe` as the load-bearing entry.** Forced by §2/§4:
  `neuroserver` spans a queue item's entire lifetime (measured continuously
  present for the full 942+ s window, including the 582 s analysis phase);
  `ffmpeg` only exists for the encode sub-phase and is absent for ~10 minutes
  at the start of every item.
- **Worker matching must be by ANCESTRY (any descendant of a live GUI PID),
  not "direct child of the GUI PID."** Forced by §1: `ffmpeg.exe`'s measured
  `ParentProcessId` is `neuroserver.exe`'s PID, not the GUI's. A same-generation
  match would never recognize `ffmpeg` as belonging to Topaz at all.
- **`StallSec = 1800` must stay generous relative to measured freeze
  windows**, and must never be lowered to something that "looks safe" on
  paper (e.g. a few minutes) without re-running this measurement. Forced by
  §3: a real, healthy render was observed with the output directory's
  reported size frozen for up to 466.2 s (and zero for the 81.3 s before
  that) while writing real data the whole time.
- **`Get-OutputBytes` (the recursive `Get-ChildItem`/`Measure-Object` byte
  total) must remain a *secondary*, corroborating signal, never the sole
  progress check.** Forced by §3 directly: it under-reports even the
  net, start-to-end write volume by 27.1% in the measured window, and sits
  exactly flat for minutes at a time in between.
- **The GPU is not a usable completion signal on this box - in EITHER
  direction.** Two independent measurements rule it out:
  - *Too low during a real render.* Per §3's burst pattern, GPU utilization
    dropped to **9%** (sample 32) and **12%** (sample 67), both below the
    configured `GpuBusyPercent = 15`, during a render that was by every other
    measure (live worker PIDs, climbing I/O counters) completely healthy. So
    `GpuOnly` would read "idle" every ~2-3 minutes mid-render.
  - *Too high when nothing is rendering.* Measured 2026-07-27 04:11-04:20 with
    an operator simply **connected over DCV and no render running at all**, the
    GPU sat at **14-55%** - DCV encodes the remote display on the same GPU. The
    watchdog logged `Render active (worker=False gpu=21%)`. Under
    `WorkerOrGpu` that sets `SawActivity`, defeating the guard against
    completing a queue before any render begins, and could power the box off
    under an operator who was only setting up.

  The two bounds overlap: there is no `GpuBusyPercent` that is simultaneously
  low enough to catch a real render's 9% troughs and high enough to ignore
  DCV's 55% peaks. **`CompletionSignal` is therefore `'WorkerOnly'`** on this
  deployment, relying on the ancestry-matched worker signal - which never
  flickered across all 94 samples of §3, nor across either complete queue item.
- **A second, independent measurement (2026-07-27) forces the same conclusion
  onto the out-of-band CloudWatch idle alarm, which - unlike `Resolve-RenderActive`
  above - was still keyed on `GPUUtilization` at the time.** `metric.log`
  recorded **25 consecutive one-per-minute samples reading under 5%** during a
  confirmed-healthy, actively-progressing 4K render (`workerIoBytes` climbing
  on the watchdog's own heartbeat throughout the same window):
  `14:16:25.209` -> `14:40:25.070`, values `0, 0, 2, 0, 0, 0, 0, 2, 2, 0, 1, 0,
  0, 0, 0, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0` - a **25-minute** sub-5% streak, five
  minutes short of the alarm's default 30-consecutive-minute breach window,
  broken only by a late burst of `100, 100, 28, 100` at
  `14:41:25`-`14:44:25.411` as the encode finished. Full detail, including the
  contrasting too-high-when-idle DCV numbers already established above, is in
  [docs/15 §K](15-third-end-to-end-run.md#k-gpu-telemetry-a-genuine-healthy-render-near-miss-for-the-idle-alarm).
  The same untrustworthiness that disqualified the GPU as a **completion**
  signal (immediately above) therefore also disqualifies it as the **alarm**
  signal: too low during a real render (this measurement, and the 9%/12%
  troughs above) and too high when idle (the DCV measurement above) are the
  same defect observed from two different consumers of the same metric. This
  is why the idle alarm's default was changed to key on a `RenderActive`
  worker-presence metric instead of `GPUUtilization` - see
  [docs/06](06-phase4-safety-net.md#why-the-alarm-no-longer-defaults-to-gpu-and-why-30-minutes--notbreaching).
  **That re-key narrowed the hazard; it did not remove the structural
  problem that any idle-presence signal cannot distinguish "abandoned" from
  "between two queue items" or "still setting up".** The operator decided on
  2026-07-28 to stop arming this alarm at all for this project, rather than
  trust a narrower-but-still-imperfect signal - see
  [docs/09 §5](09-appendix-b-boundaries.md#5-no-idle-alarm-no-timed-stop-the-watchdog-is-the-only-thing-that-will-ever-stop-this-box).
  The measurements in this document remain the empirical basis for the
  `RenderActive` signal itself (still true, and still what the watchdog's own
  `CompletionSignal='WorkerOnly'` relies on); they are no longer the basis for
  an armed alarm.
- **A newly measured, previously undocumented hazard for `UnlockTimeoutMin`:**
  both queued **input** files - `SDR_Render_short.mp4` and
  `SDR_Render_video.mp4` - were reported `locked: true` in **94 of 94
  samples (100%)**, for the entire ~26+ minute observed session, not merely
  while their own turn in the queue was active. `OutputDir` is the *same*
  folder as the inputs on this box, and `Watchdog.ps1`'s unlock gate scans
  `$cfg.OutputDir` recursively and only exempts names matching `TempMarker`
  (`_temp`) - which neither input file's name does. Consequently the
  post-completion unlock wait will, on this box, **always** run its full
  `UnlockTimeoutMin` (5 min) before proceeding, regardless of how quickly the
  actual export `.mov` itself unlocks, because the co-located input files
  never report unlocked while Topaz has the project loaded. This is not
  fatal - the code already proceeds anyway with a `WARN` after the timeout -
  but anyone tuning `UnlockTimeoutMin` expecting it to usually resolve early
  should know, from this measurement, that it will not on this box.

## 6. Completion transition

**Not observed in this window.** As of the last sample analyzed
(`2026-07-26T20:56:40Z`), the first queued item (`SDR_Render_video.mp4` ->
`SDR_Render_video_181094049.mov`) was still actively rendering:

- `ffmpeg.exe` (PID 9396) and `neuroserver.exe` (PID 10680) were both still
  running, same PIDs as sample 1.
- GPU utilization was 95% at the last sample (min/max/avg across the whole
  window: **9% / 100% / 89.9%**).
- The output file was still reported `331,350,016` bytes and `locked: true`.
- No second `neuroserver.exe` process ever appeared (`Distinct neuroserver
  PIDs seen: 10680` - one PID, the whole window).
- No `ffmpeg` exit, no unlock event on the output file, and no GPU idle
  period were observed at any point in the 94-sample window.

Consequently this document **cannot** characterize the completion
transition, the inter-item gap, or whether/when a second `neuroserver`
spawns for the second queued file (`SDR_Render_short.mp4`, present and
`locked: true` throughout, per §5, even though its own turn had not yet
started) - all of that remains **not observed in this window**. If the
render completes in a later capture, that transition should be measured and
appended here (or in a follow-up document) with the same rigor: the exact
order of `ffmpeg` exit / `neuroserver` exit / output unlock / GPU drop, and
the measured wall-clock gap (if any) before a second `neuroserver` starts -
rather than assumed from this write-up.

---

Back to the [README](../README.md).
