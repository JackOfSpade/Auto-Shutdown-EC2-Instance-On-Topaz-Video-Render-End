<#
.SYNOPSIS
    Shared module + single source of truth for the in-guest Topaz auto-stop
    pipeline.

.DESCRIPTION
    Every in-guest script dot-sources this file so that paths, process-match
    patterns, tuning knobs, and the small set of shared helpers are defined in
    exactly one place:

        . "$PSScriptRoot\Config.ps1"
        $cfg = Get-TopazAutoStopConfig

    Edit the values in the "OPERATOR SETTINGS" block to match what you observed
    in Phase 0 (output directory, GUI process name, worker process name,
    scratch-file naming). The rest are sensible defaults you can tune later.

    Besides configuration this file exposes a few helpers used by more than one
    script, so the logic lives once:
        Write-TopazLog        - timestamped console + file logging
        Get-Ec2Identity       - IMDSv2 instance-id + region (best-effort)
        Get-GpuUtilizationMax - highest GPU utilization across ALL GPUs

.NOTES
    Dot-sourcing this file has no side effects, so it is safe to load from any
    script (watchdog, stop sequence, metric publisher, installer, tests).
#>

function Assert-ValidCompletionSignal {
    <#
    .SYNOPSIS
        Pure: throws a clear, actionable error if $Signal is not one of the
        three CompletionSignal values Resolve-RenderActive accepts.
    .DESCRIPTION
        CompletionSignal is otherwise only enforced deep in the poll loop, by
        Resolve-RenderActive's own ValidateSet -- where the failure mode for a
        typo'd value is Test-RenderActive throwing (or, if that ValidateSet
        is ever loosened, silently returning $null forever), freezing the
        watchdog for the life of the instance. Validating here, at config
        load, fails loudly at script start instead.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Signal)

    $validSignals = @('WorkerOnly', 'GpuOnly', 'WorkerOrGpu')
    if ($validSignals -notcontains $Signal) {
        throw "Get-TopazAutoStopConfig: CompletionSignal '$Signal' is invalid. Valid values are: $($validSignals -join ', ')."
    }
}

function Assert-ValidStopStrategy {
    <#
    .SYNOPSIS
        Pure: throws a clear, actionable error if $Strategy is not one of the
        three StopStrategy values Resolve-StopPlan accepts.
    .DESCRIPTION
        Mirrors Assert-ValidCompletionSignal. A typo'd StopStrategy would
        otherwise surface only at the very end of a render, inside
        Stop-Sequence.ps1, at the exact moment the pipeline is supposed to
        save money -- and would silently produce an EMPTY stop plan, meaning
        the box runs forever. Validate at config load instead, so the failure
        is loud and immediate.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Strategy)

    $validStrategies = @('Ec2ApiStop', 'GuestShutdown', 'Auto')
    if ($validStrategies -notcontains $Strategy) {
        throw "Get-TopazAutoStopConfig: StopStrategy '$Strategy' is invalid. Valid values are: $($validStrategies -join ', ')."
    }
}

function Resolve-StopPlan {
    <#
    .SYNOPSIS
        Pure: the ORDERED list of stop actions to attempt for a given
        StopStrategy. No I/O, so it is fully unit-testable.
    .PARAMETER Strategy
        'Ec2ApiStop' | 'GuestShutdown' | 'Auto'.
    .DESCRIPTION
        'Auto' puts Ec2ApiStop FIRST and GuestShutdown second, deliberately.
        Only the API call provably ends billing; a guest shutdown ends billing
        only when InstanceInitiatedShutdownBehavior happens to be 'stop'.
        Ordering the cheap-but-unreliable action first would, on a box where
        that attribute is 'terminate' or where the guest shutdown simply does
        not stop the instance, either destroy the box or quietly keep billing
        it. Trying the authoritative action first and degrading to the
        best-effort one is the safe direction.
    .OUTPUTS
        A string array of action names, in the order they should be attempted.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Ec2ApiStop', 'GuestShutdown', 'Auto')][string]$Strategy
    )

    # The leading unary comma is required, not decorative -- see
    # Build-AwsCliArgs: a single-element array returned from a PowerShell
    # function collapses to a bare string, and callers here iterate the
    # result with foreach and index into it.
    switch ($Strategy) {
        'Ec2ApiStop'    { return , @('Ec2ApiStop') }
        'GuestShutdown' { return , @('GuestShutdown') }
        default         { return , @('Ec2ApiStop', 'GuestShutdown') }
    }
}

function Build-WorkerWqlFilter {
    <#
    .SYNOPSIS
        Pure: build the WQL filter that selects every configured worker
        process name, from the WorkerNamesLike array. No I/O.
    .PARAMETER Patterns
        One or more WQL LIKE patterns, e.g. @('neuroserver.exe','ffmpeg%').
    .DESCRIPTION
        The worker setting became an ARRAY (a single name cannot describe the
        real Topaz process tree -- see Config's WorkerNamesLike comment), so
        the single interpolated "Name LIKE '<x>'" filter the watchdog used to
        build no longer suffices. Patterns are OR-joined.

        Single quotes inside a pattern are doubled, which is WQL's own
        escaping rule. Without that, a pattern containing an apostrophe would
        terminate the string literal early and produce a malformed query --
        which Get-CimInstance surfaces as a thrown exception, i.e. the worker
        signal reads "unknown" on EVERY poll and the watchdog freezes forever.
    .OUTPUTS
        A WQL fragment, e.g. "Name LIKE 'neuroserver.exe' OR Name LIKE 'ffmpeg%'".
        Throws if no usable pattern is supplied -- an empty filter would match
        EVERY process on the box and make the watchdog think a render is
        permanently active.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Patterns
    )

    $usable = @($Patterns | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($usable.Count -eq 0) {
        throw "Build-WorkerWqlFilter: no non-empty worker name pattern supplied. Set WorkerNamesLike in Config.ps1."
    }

    return (($usable | ForEach-Object { "Name LIKE '$($_ -replace "'", "''")'" }) -join ' OR ')
}

function Get-TopazAutoStopConfig {
    [CmdletBinding()]
    param()

    $config = [pscustomobject]@{
        # ------------------------------------------------------------------
        # OPERATOR SETTINGS  (set these from your Phase 0 observations)
        # ------------------------------------------------------------------

        # Folder that Topaz writes finished exports into. The watchdog treats
        # "no progress" (while a render is active) as a stall -- but see
        # Get-WorkerIoBytes in Watchdog.ps1: growth of THIS folder is only a
        # secondary progress signal, because NTFS does not refresh a file's
        # directory-entry length while a writer holds the handle open.
        # Renders land on the INSTANCE-STORE scratch drive, not on C:. It is
        # free (included in the instance price), much faster than gp3 EBS, and
        # ~419 GB -- enough for the ~105 GB peak a 10-minute 4K DNxHR HQX
        # export needs once Topaz's final mux pass writes its full second copy.
        #
        # THE TRADE: this volume is ERASED on every instance stop. That is only
        # safe because OutputIsEphemeral below makes Stop-Sequence.ps1 refuse to
        # stop until the upload has been verified. Never point OutputDir at an
        # ephemeral volume without that interlock armed.
        OutputDir        = 'D:\Renders'

        # Marks OutputDir as living on storage that does not survive a stop.
        # When $true, a failed/absent upload BLOCKS the stop instead of being
        # best-effort: losing the box's uptime is recoverable, losing a
        # multi-hour render is not.
        OutputIsEphemeral = $true

        # Scratch-drive provisioning, consumed by Initialize-ScratchDisk.ps1.
        # The size bounds are a safety guard on disk SELECTION, not a
        # requirement -- see that script's .NOTES for the full filter.
        ScratchDriveLetter = 'D'
        ScratchVolumeLabel = 'RenderScratch'
        ScratchMinBytes    = 300GB
        ScratchMaxBytes    = 600GB

        # NOTE ON SOURCE FOOTAGE. The upload is scoped to OutputDir alone, so
        # anything the operator leaves elsewhere on the scratch volume -- at
        # D:\ root, say -- is simply never uploaded. That is the whole reason
        # renders go in a SUBDIRECTORY rather than at the root: it separates
        # "things to upload" from "things that are only here to be read"
        # without needing to guess which files are outputs.
        #
        # The entire volume is still erased on every stop, source footage
        # included. That is accepted and deliberate.

        # WMI/CIM LIKE pattern that matches the Topaz GUI process name.
        # Covers both 'Topaz Video.exe' and 'Topaz Video AI.exe' (rebrand-safe).
        TopazNameLike    = 'Topaz Video%'

        # WMI/CIM LIKE pattern(s) matching the WORKER process(es) Topaz spawns
        # to service an export job. An ARRAY, because a single name is not
        # enough on current Topaz builds: the observed topology is
        #
        #     Topaz Video.exe  ->  neuroserver.exe  ->  ffmpeg.exe
        #
        # i.e. ffmpeg is a GRANDCHILD of the GUI, not a child, and it does not
        # even exist for the first several minutes of a job while neuroserver
        # runs its analysis pass. neuroserver.exe is the load-bearing signal:
        # it is spawned with --once, so exactly one process lives for exactly
        # one queue item, spanning both the analysis and the encode. ffmpeg is
        # kept as a second, corroborating signal. Matching is by ANCESTRY (any
        # descendant of a live GUI), not by direct parentage -- see
        # Resolve-ProcessDescendants in Watchdog.ps1.
        #
        # Each entry is a WQL LIKE pattern, so '%' wildcards are allowed
        # (e.g. 'ffmpeg%'). See docs/12-empirical-findings.md for the measured
        # process tree this default is derived from.
        WorkerNamesLike  = @('neuroserver.exe', 'ffmpeg.exe')

        # Fragment found in Topaz scratch/temporary files. A file is treated
        # as a scratch file (and ignored by the "outputs unlocked?" check,
        # because Topaz may leave them behind after a successful export) when
        # its name matches this marker ANCHORED to a following '.', '_', '-',
        # or the end of the name -- see Test-TopazTempFile below, e.g.
        # 'clip_temp.mp4' or 'clip_temp_001.mov' match, but a bare substring
        # match would also (wrongly) catch a real deliverable like
        # 'Reel_Template_Final.mp4', which merely CONTAINS "_temp" inside
        # "_Template", and silently skip it from the unlock check.
        TempMarker       = '_temp'

        # ------------------------------------------------------------------
        # COMPLETION SIGNAL  (how the watchdog decides a render is "active")
        # ------------------------------------------------------------------

        # Which signal(s) count as "a render is currently active":
        #   'WorkerOnly'  - only the presence of a child encoder worker (the
        #                   original, most specific behaviour; DEFAULT).
        #   'GpuOnly'     - only GPU utilization >= GpuBusyPercent.
        #   'WorkerOrGpu' - active if EITHER a worker is present OR the GPU is
        #                   busy. Most robust against Topaz changing how/what it
        #                   spawns, at the cost of needing a sensible
        #                   GpuBusyPercent. Recommended if the worker process is
        #                   not reliably a child of the GUI on your version.
        # THE BIAS THAT DECIDES THIS. The signals fail in different directions,
        # and the asymmetry of the consequences settles which way to lean: a
        # false "idle" powers the box off MID-RENDER and destroys hours of GPU
        # time, while a false "busy" merely leaves the box up a little longer.
        # So whichever mode is chosen, it should be the one that is hardest to
        # fool into reading "idle".
        #
        # On a box where the GPU is NOT shared with a remote-display encoder
        # that argument selects 'WorkerOrGpu', because requiring BOTH signals
        # to go quiet is the strongest guard against a false "idle". On THIS
        # box it does not -- see the measured note below, which is why the
        # shipped value is 'WorkerOnly'. Do not read this paragraph as
        # describing the default; the executable value is at the end of this
        # block.
        # Every mode gracefully degrades: both the worker and GPU signals are
        # three-valued ($true/$false/$null, $null = "could not be read this
        # poll"). If a signal is $null, it simply stops contributing per
        # Resolve-RenderActive's truth table below; if NEITHER signal can be
        # trusted, the overall result is itself $null (unknown) and the
        # watchdog freezes its idle/stall bookkeeping for that poll rather
        # than guessing.
        # MEASURED 2026-07-27, and the reason this is 'WorkerOnly' rather than
        # 'WorkerOrGpu': on this box Amazon DCV encodes the remote display on
        # the SAME GPU, and while an operator is connected that alone runs at
        # 14-49% -- far above GpuBusyPercent. The watchdog logged
        # "Render active (worker=False gpu=21%)" with no render running at all.
        #
        # That is not merely noisy, it is harmful: the GPU signal sets the
        # internal SawActivity flag, which defeats the deliberate guard that
        # stops the watchdog from ever completing a queue before a render has
        # actually begun. The failure mode is an operator connecting over DCV,
        # spending twenty minutes setting a project up, pausing for five, and
        # having the box powered off underneath them.
        #
        # The GPU signal only existed as a hedge against unreliable worker
        # detection. Worker detection is now by ANCESTRY and has been validated
        # end-to-end across two complete queue items (analysis phase, encode
        # phase, and the standalone mux pass), so the hedge is all cost and no
        # benefit here. Switch back to 'WorkerOrGpu' only on a box where the
        # GPU is NOT shared with the remote-display encoder.
        CompletionSignal = 'WorkerOnly'

        # GPU utilization (%) at or above which the GPU counts as "actively
        # rendering", for the GpuOnly / WorkerOrGpu modes. Real Topaz renders
        # peg the GPU well above this; a disconnected idle desktop sits near 0.
        # Note: while you are CONNECTED over DCV, the remote-display encoder can
        # add some GPU load - this signal is meant for the DISCONNECTED render
        # window, which is exactly when auto-stop matters.
        GpuBusyPercent   = 15

        # ------------------------------------------------------------------
        # WATCHDOG TUNING
        # ------------------------------------------------------------------

        # How often the watchdog polls process + folder state (seconds).
        PollSec          = 15

        # A worker must be CONTINUOUSLY present for this long before the
        # watchdog accepts that a render has actually begun (before it sets
        # SawActivity and therefore becomes willing to ever declare the queue
        # complete).
        #
        # MEASURED 2026-07-27. Topaz spawns short-lived ffmpeg/ffprobe helpers
        # for previews and thumbnails whenever the operator interacts with the
        # GUI. One of those armed the watchdog at 05:49:11 and was gone by
        # 05:49:43 -- under 32 seconds -- after which the box sat idle, ran the
        # 300s debounce down, and came within ~90 seconds of stopping an
        # instance on which no render had ever run.
        #
        # The existing DebounceSec protects the far side of the render (do not
        # call it finished too early). This protects the near side (do not
        # call it started at all). A real job's neuroserver.exe lives for
        # minutes to hours, so 90s separates the two cases with enormous
        # margin while costing a genuine render nothing -- SawActivity simply
        # arms 90 seconds in, long before any queue could drain.
        ArmSec           = 90

        # With a render no longer active for this long (and one having been
        # seen), the queue is considered complete. This is the gap between two
        # queue items: the GUI finishes one export, tears down its neuroserver
        # worker, and only then spawns the next one. A false "complete" here
        # powers the box off MID-QUEUE, so the value is deliberately generous:
        # 300s buys five idle minutes at the end of a session and costs
        # essentially nothing, versus losing an entire unrendered queue.
        DebounceSec      = 300

        # A render is active but has made NO measurable progress for this long
        # => treat as a stall (broken job) and stop anyway. Progress is the
        # union of two signals (see Get-NextWatchdogState): the worker
        # processes' cumulative disk I/O counters, and the output folder byte
        # total. 1800s is intentionally generous because a healthy job can
        # legitimately spend many minutes in neuroserver's analysis pass
        # before the encoder starts producing output.
        StallSec         = 1800

        # Bound (seconds) on how long the watchdog may log NOTHING -- while a
        # render is healthy and progressing, AND while it is waiting for the
        # Topaz GUI to appear. 0 disables heartbeats.
        #
        # The poll loop is deliberately quiet: it logs stalls, idle countdowns
        # and unreadable signals, but a progressing render logs nothing, so a
        # long job does not produce thousands of identical lines. The cost of
        # that is a healthy render being indistinguishable from a dead
        # watchdog. MEASURED 2026-07-27: a 4K job left watchdog.log completely
        # empty from 07:55:33 to 12:44:33 -- 4 h 49 m with no evidence the
        # watchdog was alive at all (docs/14).
        #
        # 300s bounds that silence at five minutes. On a five-hour render that
        # is ~60 lines total, trivial against the 5 MB rotation threshold, and
        # it makes "the watchdog stopped logging" a real signal instead of the
        # normal case. See Get-NextHeartbeatState in Watchdog.ps1.
        #
        # This bound applies to BOTH of the watchdog's blocking loops. It did
        # not always: on 2026-07-27 the FIRST cycle to run the heartbeat still
        # logged nothing for 361s while waiting for the GUI, because the clock
        # was declared below that loop (docs/15). Note the consequence of the
        # clock measuring SILENCE rather than wall time -- a heartbeat interval
        # observes ~320s, not 300s, because it counts 20 nominal PollSec ticks
        # and an active poll really costs ~15.9-16.1s. That is by design.
        HeartbeatSec     = 300

        # After "done", the watchdog waits up to this many minutes for every
        # output file to become unlocked before it hands off to the stop step.
        UnlockTimeoutMin = 5

        # Seconds between file-unlock re-checks during the UnlockTimeoutMin
        # gate above.
        UnlockPollSec    = 10

        # Bound (seconds) on short best-effort aws CLI calls: sns publish and
        # cloudwatch put-metric-data. A hung aws CLI under the metric
        # scheduled task's MultipleInstances=IgnoreNew policy would
        # permanently kill the metric feed -- the task never gets a fresh run
        # while the wedged one sits open, so nothing would ever call it again.
        AwsCliTimeoutSec = 60

        # Bound (seconds) on the pre-stop `aws s3 sync`. Generous because it
        # may genuinely need to transfer a lot of rendered output before
        # power-off; an unbounded call in Stop-Sequence would block power-off
        # forever.
        S3SyncTimeoutSec = 1800

        # ------------------------------------------------------------------
        # PATHS
        # ------------------------------------------------------------------

        InstallDir       = 'C:\topaz-autostop'
        LogDir           = 'C:\topaz-autostop\logs'

        # ------------------------------------------------------------------
        # PHASE 4 - SAFETY-NET METRICS (published by Push-GpuMetric.ps1)
        # ------------------------------------------------------------------

        # These values are MIRRORED by control-plane/03-create-idle-alarm.sh
        # (METRIC_NAMESPACE/METRIC_NAME env overrides there). If you change
        # them here, re-run that script with matching overrides, or the idle
        # alarm silently keeps watching a dead metric.
        MetricNamespace  = 'TopazRender/GPU'
        MetricName       = 'GPUUtilization'

        # Name of the SECOND metric published every cycle: 1 when at least one
        # encoder worker process exists, 0 when none does. See
        # Test-RenderWorkerPresent below for why this exists and why it is
        # matched more loosely than the watchdog's own worker signal.
        #
        # WHY A SECOND METRIC. The idle alarm used to key on GPUUtilization,
        # and that metric is now known to be wrong in BOTH directions on this
        # box:
        #   * TOO HIGH when idle - a connected DCV session encodes the remote
        #     display on the same GPU and holds it at 14-58% with nothing
        #     rendering, so a 5% "idle" alarm can never fire while anyone is
        #     connected (docs/12).
        #   * TOO LOW when busy - MEASURED 2026-07-27: a confirmed-healthy 4K
        #     render read under 5% for 25 CONSECUTIVE one-minute samples
        #     (14:16:25 -> 14:40:25, mostly literal 0%), five minutes short of
        #     the alarm's 30-minute breach window, ON A BOX THAT WAS RENDERING
        #     (docs/15).
        # The second of those is the dangerous one: it means the safety net
        # could have stopped the box mid-render. docs/12 already concluded the
        # GPU is unusable as a COMPLETION signal, which is why CompletionSignal
        # is 'WorkerOnly' -- but the alarm went on reading it anyway. This
        # metric gives the alarm the same class of signal the watchdog itself
        # trusts. GPUUtilization is still published, as telemetry.
        RenderActiveMetricName = 'RenderActive'

        # ------------------------------------------------------------------
        # OPTIONAL BEHAVIOUR
        # ------------------------------------------------------------------

        # If set (e.g. 's3://my-bucket/renders/'), Stop-Sequence.ps1 runs
        # `aws s3 sync` against OutputDir BEFORE powering off. Empty = skip.
        S3SyncTarget     = ''

        # ------------------------------------------------------------------
        # UPLOAD BEFORE STOP  (rclone -> Google Drive)
        # ------------------------------------------------------------------

        # rclone destination for finished renders. Empty = no upload step.
        # When OutputIsEphemeral is $true this is effectively MANDATORY: it is
        # the only thing that gets a render off a volume that is about to be
        # erased.
        #
        # 'gdrive:temp' is an EXISTING folder at the root of the operator's
        # My Drive. rclone would happily create a missing destination folder,
        # which is exactly how a typo silently ends up delivering renders to a
        # folder nobody is watching -- so if this is ever changed, confirm the
        # new path with `rclone lsd gdrive: --config <RcloneConfigPath>` first.
        UploadTarget     = 'gdrive:temp'

        # Full path to rclone.exe. Resolved explicitly rather than via PATH
        # because the stop runs as SYSTEM, whose PATH and profile differ from
        # the interactive operator's.
        RclonePath       = 'C:\Program Files\rclone\rclone.exe'

        # rclone's config holds the Google OAuth refresh token. SYSTEM's
        # %APPDATA% is C:\Windows\System32\config\systemprofile\..., which is
        # NOT where an interactive `rclone config` writes. Pointing both at one
        # explicit path is what stops "works when I run it, fails from the
        # scheduled task".
        RcloneConfigPath = 'C:\topaz-autostop\rclone.conf'

        # Bound on the whole upload. A 10-minute 4K DNxHR HQX render is ~52 GB;
        # at ~100 Mbps to Drive that is ~70 minutes, so this is deliberately
        # generous. On timeout the upload counts as FAILED, which (with
        # OutputIsEphemeral) blocks the stop rather than discarding the render.
        UploadTimeoutSec = 14400

        # Delay between upload attempt 1 and the single retry (see
        # Resolve-UploadRetryDecision / Invoke-TopazRenderUpload). Long enough
        # for a transient Drive-side blip (rate limiting, a dropped TCP
        # connection mid-chunk) to clear; short enough that it never
        # meaningfully delays a legitimate stop, since it is paid AT MOST
        # ONCE, only on a failure, not on every stop. 15s split the difference
        # between "a few seconds" and the "~30s" ceiling this was scoped to.
        UploadRetryDelaySec = 15

        # ------------------------------------------------------------------
        # INCREMENTAL UPLOAD  (upload each render AS IT FINISHES)
        #
        # CORRECTION 3 (2026-07-28, operator instruction verbatim: "make the
        # improvement that it starts uploading after each render is done, not
        # waiting till after all render is done"). Before this, the ONLY
        # upload ran inside Stop-Sequence.ps1 after the whole QUEUE went idle
        # for DebounceSec -- so on a multi-export queue, a finished multi-GB
        # deliverable sat completely unprotected on the EPHEMERAL scratch
        # volume for the ENTIRE duration of every subsequent export (hours,
        # in the session this was written for). See
        # Invoke-TopazIncrementalUpload below and
        # Invoke-TopazIncrementalUploadPoll in Watchdog.ps1 for the fix: the
        # watchdog's own poll loop now uploads a file the moment it looks
        # finished, and the final Stop-Sequence.ps1 sweep is UNCHANGED --
        # it becomes a cheap catch-all, since rclone skips a destination file
        # that already matches by size.
        # ------------------------------------------------------------------

        # Feature switch. $false restores the pre-2026-07-28 behaviour
        # (upload only once, at the final stop) with no code changes -- flip
        # this rather than deleting the feature if it ever needs to be ruled
        # out while debugging something else.
        UploadWhenReady  = $true

        # How many CONSECUTIVE seconds an OutputDir file's size must sit
        # UNCHANGED, in addition to being unlocked (Test-FileUnlocked), before
        # the watchdog's poll loop treats it as "finished" and uploads it
        # early.
        #
        # UNLOCKED ALONE IS NOT ENOUGH. Some encoders/muxers briefly release
        # and reacquire their write handle between internal buffer flushes,
        # so a file mid-write can read as momentarily unlocked on any single
        # poll. Requiring the SAME size across multiple consecutive polls (at
        # PollSec=15s, 30s here is 2 polls) in addition to being unlocked on
        # the poll that actually triggers the upload is what distinguishes
        # "genuinely finished" from "between two writes". See
        # Resolve-IncrementalUploadEligibility in Watchdog.ps1 for the exact
        # decision.
        #
        # 30s is short relative to DebounceSec (300s) and the ~1-2 minutes a
        # real upload takes at this box's measured ~55-65 MiB/s -- the goal is
        # catching a finished file promptly, not building a large safety
        # margin the way RecoveryMaxAgeMin does; a real deliverable, once
        # written, does not change size again.
        UploadStableSec  = 30

        # If set to an SNS topic ARN, Stop-Sequence.ps1 publishes a best-effort
        # "render complete / stalled" notification before stopping. Empty = skip.
        SnsTopicArn      = ''

        # ------------------------------------------------------------------
        # MISPLACED-OUTPUT ANOMALY  (recovery scan + Topaz forensics)
        #
        # THE INCIDENT THIS EXISTS FOR (2026-07-28). Reason='completed' fires
        # only after ArmSec of confirmed worker activity, yet OutputDir was
        # empty: Topaz's own crash-recovery retry had silently dropped the
        # "Renders\" subfolder from its cleanupPass output path, so a real,
        # finished 2.3 GB render landed one directory up (D:\ root) and was
        # invisible to every check scoped to OutputDir alone -- then the stop
        # erased the ephemeral volume it sat on.
        #
        # CORRECTION 1 (also 2026-07-28, same day, before the fix above ever
        # shipped): an empty OutputDir was the wrong TRIGGER, not just the
        # wrong LABEL. The live counter-example was sitting on this very box:
        # OutputDir held a correctly-placed FIRST deliverable (pnat-1) while a
        # SECOND export was still writing its raw intermediate at the volume
        # root. Had that second export's mux repeated the same "Renders\"-
        # dropping bug, its output would have landed at D:\ root while
        # OutputDir was NON-empty -- an empty-OutputDir trigger would never
        # have fired, and the second render would have been erased exactly
        # like the first. So the scan below now runs whenever reason=
        # 'completed', REGARDLESS of whether OutputDir itself has files -- see
        # Resolve-OutputAnomalyClass / Find-RenderRecoveryCandidates /
        # Invoke-TopazForensicCapture / Invoke-TopazOutputAnomalyHandling
        # below for the fix. The operator's explicit instruction is to STILL
        # STOP either way, just to look first and record what happened --
        # never to refuse.
        # ------------------------------------------------------------------

        # Extensions Find-RenderRecoveryCandidates treats as "plausibly a
        # Topaz render deliverable" when scanning OUTSIDE OutputDir. This is a
        # forensic/recovery aid only -- it does not gate uploads of files
        # already inside OutputDir (Invoke-TopazRenderUpload uploads whatever
        # is there, of any extension) and does not replace TempMarker.
        RenderFileExtensions = @('.mov', '.mp4', '.mkv', '.avi', '.mxf')

        # Bounds on the recovery scan, so a forensic aid can never itself
        # become the reason a stop is slow or hung: stop collecting once this
        # many candidates are found (a cap this generous already means
        # something is very wrong; more precision would not change the
        # response) ...
        # Only files modified within this many minutes of the stop count as
        # RECOVERY candidates. Older matches are still FOUND and still LOGGED,
        # they are just not uploaded and do not decide the error class.
        #
        # WHY THIS EXISTS -- it is not a performance tweak, it is correctness.
        # Extension alone cannot tell a just-finished render from a file that
        # has legitimately sat on this volume for hours. The OutputDir comment
        # above says outright that source footage is expected to be staged at
        # the volume ROOT, and in the 2026-07-28 incident it was: the 1.6 GB
        # source D:\SDR_Render_video3.mov sat beside the lost render the whole
        # session, as did pnat-1's abandoned partial output. Without a recency
        # bound the scan would (a) re-upload multi-GB source footage that was
        # never at risk and is already safe, logging it as a "recovered
        # render", and much worse (b) make a render that produced NOTHING AT
        # ALL still report CandidatesFound = true purely because normal source
        # footage exists at the root -- misfiling a total render failure as a
        # merely-misplaced success, and destroying the one distinction the
        # operator asked for ("both errors must be recorded in logs").
        #
        # 60 minutes is generous: a real deliverable's last-write time IS the
        # moment the render finished, and the stop follows only DebounceSec
        # (300s) plus the unlock gate after that -- roughly five minutes, not
        # sixty. The margin covers a slow unlock or a watchdog restart without
        # widening far enough to readmit hours-old staged source.
        RecoveryMaxAgeMin      = 60

        RecoveryScanMaxFiles   = 200
        # ... do not descend more than this many directories below the
        # OutputDir volume's root (0 = the root's own files only) ...
        RecoveryScanMaxDepth   = 4
        # ... and never let the walk itself run longer than this many
        # seconds, checked BETWEEN directories (see Find-RenderRecoveryCandidates).
        RecoveryScanTimeoutSec = 60

        # OPERATOR SETTING: the folder Topaz itself writes its own *.tzlog
        # session logs into, for THIS box's interactive Windows account (NOT
        # the SYSTEM account Stop-Sequence.ps1 runs as -- SYSTEM has no way to
        # resolve another account's %APPDATA%, so this must be an explicit,
        # literal path). Defaults to the path observed on this deployment
        # during the 2026-07-28 incident. Invoke-TopazForensicCapture
        # tolerates this not existing (wrong account, or Topaz never opened)
        # -- it is strictly best-effort.
        TopazLogsBasePath = 'C:\Users\Administrator\AppData\Roaming\Topaz Labs LLC\Topaz Video\logs'

        # Cap on how many matched "process exited"/"error occurred" lines
        # Invoke-TopazForensicCapture copies out of the *.tzlog into stop.log.
        # A stuck/crash-looping render can produce many such lines; the LAST
        # N are what is actually diagnostic (the final, decisive failure),
        # not the first.
        TopazForensicMaxLines   = 40

        # Bound (seconds) on the whole Topaz-log forensic capture: locating
        # the newest *.tzlog plus scanning it for matching lines. Generous for
        # a single-file text scan, but still finite -- this must never be able
        # to hang or meaningfully delay the stop it is a side-note to.
        TopazForensicTimeoutSec = 10

        # ------------------------------------------------------------------
        # HOW THE STOP IS PERFORMED
        # ------------------------------------------------------------------

        # The original design of this project assumed a plain guest shutdown
        # would stop the instance, because InstanceInitiatedShutdownBehavior
        # was set to 'stop' at the control plane. That assumption does NOT
        # hold everywhere, and where it fails it fails EXPENSIVELY: the guest
        # powers off, the operator sees a dark box, and AWS keeps billing the
        # still-'running' instance. On this deployment a normal Windows
        # shutdown was observed NOT to stop the instance.
        #
        # So the stop method is explicit and ordered:
        #   'Ec2ApiStop'    - call ec2:StopInstances against ourselves. This is
        #                     the only method that PROVABLY ends billing. It
        #                     requires the instance role to grant
        #                     ec2:StopInstances on this instance.
        #   'GuestShutdown' - Stop-Computer -Force. Ends billing ONLY if
        #                     InstanceInitiatedShutdownBehavior=stop.
        #   'Auto'          - try Ec2ApiStop first; fall back to GuestShutdown
        #                     if the API call is denied or fails. DEFAULT.
        #
        # See Resolve-StopPlan below for the pure ordering logic, and
        # docs/11-deploying-on-this-instance.md for how to grant the
        # permission this needs.
        StopStrategy     = 'Auto'

        # After issuing an Ec2ApiStop, how long to keep the process alive
        # waiting for the hypervisor to actually tear us down before
        # concluding the call did not take effect and escalating to the next
        # action in the plan.
        #
        # MEASURED 2026-07-27: this was 90s and that was TOO SHORT. An accepted
        # ec2:StopInstances does not kill the instance immediately -- AWS first
        # asks the guest OS to shut down gracefully and only forces it after
        # several minutes. A Windows Server guest with the Topaz GUI open takes
        # longer than 90s to get there, so the watchdog wrongly concluded the
        # API stop had failed and escalated to Stop-Computer -Force. The box
        # stopped either way, but the log recorded a false diagnosis
        # ("Still running 90s after an accepted ec2:StopInstances") that would
        # send the next person debugging a perfectly healthy IAM grant.
        # 300s comfortably covers AWS's graceful-shutdown window.
        StopVerifySec    = 300

        # Safety switch: when $true, the watchdog + stop sequence log the
        # decision but DO NOT actually stop the instance. Flip to $false
        # once you have watched a couple of real jobs complete cleanly AND
        # you have confirmed a real stop path exists (see Test-Deployment.ps1
        # -- if neither ec2:StopInstances is granted nor
        # InstanceInitiatedShutdownBehavior is 'stop', arming this changes
        # nothing except that you stop getting told about it).
        DryRun           = $false

        # ------------------------------------------------------------------
        # SCHEDULED TASK NAMES (used by Register-ScheduledTasks.ps1)
        # ------------------------------------------------------------------

        WatchdogTaskName = 'TopazAutoStop-Watchdog'
        MetricTaskName   = 'TopazAutoStop-GpuMetric'

        # Boot task that re-creates the instance-store scratch drive. It must
        # exist for OutputDir to exist at all, since that volume is wiped on
        # every stop.
        ScratchTaskName  = 'TopazAutoStop-ScratchInit'

        # One-shot wall-clock hard stop registered by Register-TimedStop.ps1.
        # This is the in-guest equivalent of the optional max-lifetime Lambda,
        # for deployments where the control plane cannot be reached to deploy
        # that Lambda. It is a COST BACKSTOP, not a substitute for the
        # watchdog: it fires on a timer regardless of whether a render is
        # still running.
        TimedStopTaskName = 'TopazAutoStop-TimedStop'
    }

    Assert-ValidCompletionSignal -Signal $config.CompletionSignal
    Assert-ValidStopStrategy -Strategy $config.StopStrategy

    # Fail loudly at config load rather than deep in the poll loop: an empty
    # worker pattern list would make Build-WorkerWqlFilter throw on every
    # single poll, freezing the watchdog for the life of the instance.
    [void](Build-WorkerWqlFilter -Patterns $config.WorkerNamesLike)

    return $config
}

function Write-TopazLog {
    <#
    .SYNOPSIS
        Timestamped log line to both the console and a per-component log file.
    .PARAMETER Message
        The text to log.
    .PARAMETER Component
        Short tag used for the log file name, e.g. 'watchdog', 'stop', 'metric'.
    .PARAMETER Level
        INFO (default), WARN, or ERROR.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][string]$Component,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )

    $cfg = Get-TopazAutoStopConfig

    # Millisecond precision AND an explicit UTC offset. Both are load-bearing
    # for post-mortems, and both were learned from real analysis friction:
    #
    #   .fff  Whole-second stamps lose ORDERING. A real completion emitted
    #         three consecutive lines all stamped [2026-07-27 12:51:35] --
    #         "QUEUE considered COMPLETE", "waiting for output files to
    #         unlock", "All output files are unlocked" -- so the log could not
    #         show how long the unlock scan actually took, only that it was
    #         under a second. The same bunching hides the ordering of a stop
    #         handoff, which is exactly where a failure would need unpicking.
    #
    #   zzz   These logs are read side by side with AWS API timestamps (UTC,
    #         ISO 8601) and with Topaz's own .tzlog (box-local, millisecond).
    #         With no offset the reader has to ASSUME the box's zone; stating
    #         it removes a guess from every cross-source correlation. It also
    #         survives the box being re-imaged into another region.
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff zzz')
    $line = "[$stamp] [$Level] $Message"

    # INFO goes to the INFORMATION stream, never the output stream.
    #
    # This is not a style preference, it is a correctness requirement. In
    # PowerShell a function returns everything written to the output stream, so
    # a function that both logs and returns a value used to return
    # @('<log line>', '<log line>', $true) instead of $true. Callers that
    # discarded the result with [void] never noticed -- but the moment one
    # depended on it, the comparison silently broke:
    #
    #     $ok = Invoke-TopazRenderUpload ...   # -> @('...INFO...', $false)
    #     if ($ok -eq $false) { ... }          # -> @($false) -> FALSY -> never fires
    #
    # That defeated the ephemeral-upload interlock in Stop-Sequence.ps1: a
    # failed upload would have been read as success and the instance stopped,
    # erasing the render it had failed to save. Write-Information still
    # displays (InformationAction Continue) and still reaches the log file
    # below, but it cannot contaminate a return value.
    #
    # Every level emits the TIMESTAMPED $line, not the bare $Message. WARN and
    # ERROR used to print undated text to the console while the log FILE got a
    # timestamped copy, so a console transcript of a failure could not be lined
    # up against the file it was supposedly mirroring -- worst exactly when a
    # failure is being watched live. Neither Write-Warning nor Write-Error
    # touches the output stream, so passing $line here cannot contaminate a
    # return value the way Write-Output would.
    switch ($Level) {
        'WARN'  { Write-Warning     $line }
        'ERROR' { Write-Error       $line }
        default { Write-Information $line -InformationAction Continue }
    }

    try {
        if (-not (Test-Path -LiteralPath $cfg.LogDir)) {
            New-Item -ItemType Directory -Path $cfg.LogDir -Force | Out-Null
        }
        $logFile = Join-Path $cfg.LogDir ("{0}.log" -f $Component)

        # Simple size-based rotation: once the live log exceeds 5MB, roll it
        # to a single ".log.1" backup (replacing any previous one) instead of
        # letting it grow unbounded for the life of the instance.
        if (Test-Path -LiteralPath $logFile) {
            $existing = Get-Item -LiteralPath $logFile
            if ($existing.Length -gt 5MB) {
                $rotatedFile = Join-Path $cfg.LogDir ("{0}.log.1" -f $Component)
                Move-Item -LiteralPath $logFile -Destination $rotatedFile -Force
            }
        }

        Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
    }
    catch {
        # Logging must never take down the pipeline.
        Write-Warning "Failed to write log file: $($_.Exception.Message)"
    }
}

function Get-Ec2ImdsToken {
    <#
    .SYNOPSIS
        Fetch an IMDSv2 session token, or $null on any failure. Short timeout so
        a non-EC2 or network-isolated box fails fast instead of hanging.
    #>
    [CmdletBinding()]
    param([int]$TimeoutSec = 3)

    try {
        return Invoke-RestMethod -Method Put `
            -Uri 'http://169.254.169.254/latest/api/token' `
            -Headers @{ 'X-aws-ec2-metadata-token-ttl-seconds' = '60' } `
            -TimeoutSec $TimeoutSec -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function Convert-AzToRegion {
    <#
    .SYNOPSIS
        Pure: derive an EC2 region from an availability zone by stripping the
        trailing zone letter, but only when the result still looks like a
        standard region name.
    .DESCRIPTION
        A plain `-replace '[a-z]$', ''` strips the trailing letter from ANY
        AZ-shaped string, including Local Zone / Wavelength AZs such as
        'us-west-2-lax-1a', which would produce the INVALID region
        'us-west-2-lax-1' instead of the correct 'us-west-2'. This validates
        the stripped candidate against a standard region shape and returns
        $null (never a guess) for anything that does not fit -- callers
        should treat $null the same as a full IMDS failure (leave Region
        empty) rather than pass a malformed region string to the AWS CLI.
    .PARAMETER AvailabilityZone
        The AZ string, e.g. 'us-east-1a'. May be $null/empty.
    .OUTPUTS
        The region string, or $null if AvailabilityZone is not a standard AZ
        shape.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$AvailabilityZone)

    if ([string]::IsNullOrWhiteSpace($AvailabilityZone)) { return $null }

    # Only strip the trailing zone letter when it is preceded by "-<digits>",
    # e.g. 'us-east-1a' -> 'us-east-1'. A non-AZ-shaped string is left as-is
    # and will simply fail the region-shape check below.
    $candidate = $AvailabilityZone
    if ($AvailabilityZone -match '^(.+-\d+)[a-z]$') {
        $candidate = $Matches[1]
    }

    # Standard region shape, e.g. 'us-east-1', 'ap-southeast-2', 'us-gov-west-1'.
    # A Local Zone / Wavelength AZ ('us-west-2-lax-1a') strips down to
    # 'us-west-2-lax-1', which has an extra '-lax' segment and correctly fails
    # this shape check.
    if ($candidate -match '^[a-z]{2,3}-(gov-|iso[a-z]?-)?[a-z]+-\d+$') {
        return $candidate
    }

    return $null
}

function Get-Ec2Identity {
    <#
    .SYNOPSIS
        Best-effort EC2 instance-id + region via IMDSv2, using ONE token.
    .DESCRIPTION
        Returns a hashtable @{ InstanceId = <string|$null>; Region = <string|$null> }.
        Region is read from the dedicated placement/region endpoint (correct for
        Local Zones / Wavelength too); if that is unavailable it falls back to
        stripping the trailing zone letter from the availability zone. Any field
        may be $null if IMDS is unreachable - callers must handle that.
    #>
    [CmdletBinding()]
    param()

    $result = @{ InstanceId = $null; Region = $null }

    $token = Get-Ec2ImdsToken
    if (-not $token) { return $result }
    $headers = @{ 'X-aws-ec2-metadata-token' = $token }

    try {
        $result.InstanceId = ("$(Invoke-RestMethod -Method Get `
            -Uri 'http://169.254.169.254/latest/meta-data/instance-id' `
            -Headers $headers -TimeoutSec 3 -ErrorAction Stop)").Trim()
    }
    catch { }

    # Prefer the dedicated region endpoint (robust for all zone types).
    try {
        $region = ("$(Invoke-RestMethod -Method Get `
            -Uri 'http://169.254.169.254/latest/meta-data/placement/region' `
            -Headers $headers -TimeoutSec 3 -ErrorAction Stop)").Trim()
        if ($region) { $result.Region = $region }
    }
    catch { }

    # Fallback: derive region from the AZ if placement/region was unavailable.
    # Convert-AzToRegion returns $null (leaving Region empty, same as a full
    # IMDS failure) instead of a malformed region for Local Zone / Wavelength
    # AZs -- see its own comment.
    if (-not $result.Region) {
        try {
            $az = ("$(Invoke-RestMethod -Method Get `
                -Uri 'http://169.254.169.254/latest/meta-data/placement/availability-zone' `
                -Headers $headers -TimeoutSec 3 -ErrorAction Stop)").Trim()
            if ($az) { $result.Region = Convert-AzToRegion -AvailabilityZone $az }
        }
        catch { }
    }

    return $result
}

function Get-GpuUtilizationMax {
    <#
    .SYNOPSIS
        Highest GPU utilization (%) across ALL GPUs on the box, or $null if the
        value cannot be read.
    .DESCRIPTION
        nvidia-smi prints one line per GPU. Taking the MAXIMUM (not the first
        line) is essential on multi-GPU instances (e.g. g5.12xlarge = 4 GPUs):
        Topaz typically loads a single GPU, so the first GPU can read ~0% during
        an otherwise-busy render. Returns $null on any failure so callers can
        distinguish "idle" (0) from "unknown" ($null).

        Launched via System.Diagnostics.Process (not the '&' call operator)
        with an explicit 15s WaitForExit timeout: a wedged/hung GPU driver can
        make a bare '& nvidia-smi' invocation hang forever. Under the metric
        scheduled task's MultipleInstances=IgnoreNew policy, one hung instance
        would silently kill the metric feed for good -- and because the idle
        CloudWatch alarm is configured treatMissingData=notBreaching, the idle
        alarm would then never fire either, so the safety net dies silently.
        A bounded wait plus Kill() on timeout guarantees this call returns.

        Standard output is read via ReadToEndAsync() BEFORE WaitForExit is
        called: a synchronous ReadToEnd() first would block until the child
        process closes its output (normally at exit), which is exactly the
        hang this timeout exists to bound around.
    #>
    [CmdletBinding()]
    param()

    $proc = $null
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = 'nvidia-smi'
        $psi.Arguments              = '--query-gpu=utilization.gpu --format=csv,noheader,nounits'
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardOutput = $true
        $psi.CreateNoWindow         = $true

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        [void]$proc.Start()

        $outputTask = $proc.StandardOutput.ReadToEndAsync()

        if (-not $proc.WaitForExit(15000)) {
            try { $proc.Kill() } catch { }
            return $null
        }

        if ($proc.ExitCode -ne 0) { return $null }

        $raw = $outputTask.Result

        $vals = @(($raw -split "`r?`n") |
            ForEach-Object { "$_".Trim() } |
            Where-Object   { $_ -match '^\d+$' } |
            ForEach-Object { [int]$_ })

        if ($vals.Count -eq 0) { return $null }
        return ($vals | Measure-Object -Maximum).Maximum
    }
    catch {
        return $null
    }
    finally {
        if ($proc) { $proc.Dispose() }
    }
}

function Test-RenderWorkerPresent {
    <#
    .SYNOPSIS
        Is at least one encoder worker process alive right now? Deliberately
        loose, stateless worker check for the out-of-band safety-net metric.
    .DESCRIPTION
        Feeds the RenderActive metric that Push-GpuMetric.ps1 publishes, which
        the CloudWatch idle alarm keys on instead of GPUUtilization.

        WHY THIS IS NOT Get-TopazWorkers (Watchdog.ps1). Two reasons, and both
        of them matter:

        1. IT MUST BE STATELESS. Get-TopazWorkers attributes workers by
           ANCESTRY (descendants of a live Topaz GUI PID) and keeps a
           $script:KnownWorkers table so that a worker ORPHANED by a crashed
           GUI still counts as active. That table is built up across polls
           inside one long-lived process. Push-GpuMetric.ps1 is relaunched by
           the scheduler EVERY MINUTE, so it would start empty every single
           time: an orphaned encoder -- GUI gone, ffmpeg still writing -- would
           be attributed to nothing and read as IDLE, thirty of those in a row
           would breach the alarm, and the safety net would power the box off
           on top of a live render. Precisely the accident it exists to prevent.

        2. THE TWO CALLERS WANT OPPOSITE BIASES. The watchdog is deciding
           whether to STOP, so it needs a PRECISE signal -- an unrelated
           ffmpeg.exe belonging to someone else's tool must not hold the box up
           forever, hence ancestry. The alarm is deciding whether stopping is
           SAFE, so it needs a CONSERVATIVE one: if anything on this box looks
           remotely like an encoder, do not stop. Matching on name alone is the
           strictly safer error in that direction, and it happens to be exactly
           what makes it stateless. A stray ffmpeg here only ever costs uptime,
           never a render.

        DCV is unaffected by this signal, which is the other half of the fix:
        the remote-display encoder is dwm.exe/dcvagent.exe and matches no
        WorkerNamesLike pattern, so a connected session no longer suppresses
        the alarm the way GPU load did.
    .OUTPUTS
        $true  - at least one process matching WorkerNamesLike is alive.
        $false - the query succeeded and found none.
        $null  - the query FAILED, so presence is unknown this cycle. Callers
                 must publish NOTHING on $null rather than coercing it to 0;
                 the alarm's treat-missing-data=notBreaching then holds its
                 state instead of counting a failed query as an idle minute.
    .PARAMETER WorkerNamesLike
        Config's WorkerNamesLike patterns.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$WorkerNamesLike
    )

    try {
        $filter  = Build-WorkerWqlFilter -Patterns $WorkerNamesLike
        $workers = @(Get-CimInstance -ClassName Win32_Process -Filter $filter `
            -Property ProcessId -OperationTimeoutSec 30 -ErrorAction Stop)
        return ($workers.Count -gt 0)
    }
    catch {
        # Includes Build-WorkerWqlFilter throwing on an empty pattern list --
        # which would otherwise build a filter matching EVERY process and
        # report a permanently active render, pinning the alarm OK forever.
        return $null
    }
}

function Resolve-RenderActive {
    <#
    .SYNOPSIS
        Pure decision: is a render "active" given the raw signals? No I/O, so it
        is fully unit-testable.
    .PARAMETER WorkerActive
        Whether an encoder worker process is currently present: $true, $false,
        or $null when the worker signal itself is unknown this poll (e.g. the
        underlying CIM query failed and no adopted orphan worker is alive to
        confirm activity either way).
    .PARAMETER GpuUtil
        Highest GPU utilization (%), or $null if it could not be read (unknown).
    .PARAMETER Signal
        'WorkerOnly' | 'GpuOnly' | 'WorkerOrGpu'.
    .PARAMETER GpuBusyPercent
        GPU % at or above which the GPU counts as actively rendering.
    .DESCRIPTION
        Both signals are three-valued and degrade gracefully: whichever signal
        is $null (unreadable) simply stops contributing, and the OTHER signal
        decides. The overall result can itself be $true, $false, or $null (only
        when the applicable signal(s) are all unreadable) -- callers must treat
        a $null RESULT as "unknown this poll" and freeze state rather than
        infer idle or active.

        Truth table:
          WorkerOnly  - worker $null -> $null; otherwise the worker value.
          GpuOnly     - GPU read OK -> gpuActive; GPU $null -> the worker value
                        ($true/$false/$null passthrough).
          WorkerOrGpu - worker $true OR gpuActive -> $true;
                        worker $false + GPU read OK -> gpuActive result;
                        worker $false + GPU $null   -> $false;
                        worker $null  + GPU read OK -> gpuActive;
                        worker $null  + GPU $null   -> $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()]$WorkerActive,
        [AllowNull()]$GpuUtil,
        [Parameter(Mandatory)][ValidateSet('WorkerOnly', 'GpuOnly', 'WorkerOrGpu')][string]$Signal,
        [Parameter(Mandatory)][int]$GpuBusyPercent
    )

    if (($null -ne $WorkerActive) -and ($WorkerActive -isnot [bool])) {
        throw "Resolve-RenderActive: WorkerActive must be `$true, `$false, or `$null (got '$WorkerActive')."
    }

    $gpuReadOk = ($null -ne $GpuUtil)
    $gpuActive = ($gpuReadOk -and [int]$GpuUtil -ge $GpuBusyPercent)

    switch ($Signal) {
        'GpuOnly' {
            if ($gpuReadOk) { return $gpuActive } else { return $WorkerActive }
        }
        'WorkerOrGpu' {
            # $WorkerActive is truthy only when it is exactly $true ($null and
            # $false are both falsy in PowerShell's `if`), so this correctly
            # short-circuits to $true only on a confirmed active worker.
            if ($WorkerActive) { return $true }
            if ($gpuActive) { return $true }
            if ($gpuReadOk) { return $gpuActive }
            # GPU read failed too: GPU stops contributing. What remains is
            # $WorkerActive itself, which is either $false or $null here --
            # exactly the desired passthrough for those two rows.
            return $WorkerActive
        }
        default {
            # 'WorkerOnly'
            return $WorkerActive
        }
    }
}

function Test-TopazTempFile {
    <#
    .SYNOPSIS
        Pure decision: does $Name look like a Topaz scratch/temp file (per
        $TempMarker), as opposed to a real deliverable that merely CONTAINS
        the marker text as a substring? No I/O, so it is fully unit-testable.
    .PARAMETER Name
        The file name (not full path) to test.
    .PARAMETER TempMarker
        The configured scratch-file marker fragment (Config.ps1 TempMarker).
    .DESCRIPTION
        A plain "-like '*marker*'" substring match is too broad: a real
        deliverable such as 'Reel_Template_Final.mp4' contains '_temp' as a
        substring of "_Template" and would be silently skipped by the unlock
        gate. Anchoring the marker to a following separator ('.', '_', '-') or
        the end of the name (e.g. 'clip_temp', 'clip_temp.mp4',
        'clip_temp_001.mov') keeps matching real scratch files while letting
        'Reel_Template_Final.mp4' and 'temperature.mp4' through as real
        outputs. PowerShell's -match is case-insensitive by default, so
        'my_TEMP.mp4' still matches a '_temp' marker.

        An empty/whitespace TempMarker is a plausible operator setting
        meaning "my Topaz workflow leaves no scratch files" -- without
        AllowEmptyString the Mandatory+string binding throws a
        parameter-binding error on '', which (uncaught, inside Watchdog's
        Where-Object filter) silently empties the unlock-gate candidate list
        and lets the box power off mid-write. Treat it as an explicit no-op
        instead: nothing is ever classified as scratch.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$TempMarker
    )

    if ([string]::IsNullOrWhiteSpace($TempMarker)) { return $false }

    $pattern = [regex]::Escape($TempMarker) + '([._-]|$)'
    return [bool]($Name -match $pattern)
}

function Test-FileUnlocked {
    <#
    .SYNOPSIS
        $true if the file can be opened for read with no sharing (i.e. nothing
        else holds a write/append handle on it), otherwise $false.
    .DESCRIPTION
        MOVED HERE FROM Watchdog.ps1 (2026-07-28) so it can be shared with the
        recovery scan (Find-RenderRecoveryCandidates, below) and the
        incremental per-file upload pass (Invoke-TopazIncrementalUploadPoll in
        Watchdog.ps1) without duplicating the exact same
        FileShare.None-exclusive-open probe in three places. Watchdog.ps1 dot-
        sources this file, so every existing caller (its own unlock-gate loop,
        and Watchdog.Tests.ps1, which dot-sources Watchdog.ps1) keeps working
        unchanged -- the function is still visible under the same name, it
        just now lives one file over.

        THE REASON THIS MATTERS FOR RECOVERY (CORRECTION 2, 2026-07-28). Topaz
        writes a raw enhanced intermediate at the scratch volume ROOT
        (D:\SDR_Render_video3_<digits>.mov) WHILE an export is still running,
        then a separate mux pass combines it with the source's audio to
        produce the real deliverable. A bare extension+recency match at the
        volume root cannot tell that live intermediate apart from a genuinely
        finished, misplaced deliverable -- both are recent files with a
        render-shaped extension. Locked-ness is the signal that can: a file
        still being written holds an exclusive (or at least a
        write-incompatible) handle, so this probe fails for it and succeeds
        the instant the writer closes it. See Find-RenderRecoveryCandidates's
        own comment for how this keeps an in-progress render from being
        misread as recovery evidence.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $stream = $null
    try {
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::None)
        return $true
    }
    catch {
        return $false
    }
    finally {
        if ($stream) { $stream.Close(); $stream.Dispose() }
    }
}

function Get-TopazOutputFiles {
    <#
    .SYNOPSIS
        Strict recursive snapshot of an output directory's files.
    .DESCRIPTION
        The stop path must distinguish an empty OutputDir from one that could
        not be read. `Get-ChildItem -ErrorAction SilentlyContinue` returns a
        partial list after an access or I/O error, which can make an incomplete
        upload/check look complete and lose files when instance-store storage is
        stopped. This one helper is the only recursive OutputDir enumerator used
        by the watchdog and upload paths: it either returns the complete
        snapshot, or throws so the caller can fail closed.

        Filters out directories via PSIsContainer rather than Get-ChildItem's
        own -File switch. -File is a DYNAMIC parameter the FileSystem
        provider only contributes once it resolves $Path, so it is unavailable
        whenever that resolution fails -- including in unit tests, where
        Get-ChildItem is mocked and $Path is a placeholder that never resolves
        to any real provider. PSIsContainer needs no such resolution: it is a
        plain property on the real DirectoryInfo/FileInfo objects (false for
        files, filtered out here) and simply absent ($null, i.e. falsy, so
        "-not" keeps the item) on the plain test doubles Pester returns.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container -ErrorAction Stop)) {
        throw "Output directory '$Path' does not exist or is not a directory."
    }

    Get-ChildItem -LiteralPath $Path -Recurse -ErrorAction Stop | Where-Object { -not $_.PSIsContainer }
}

function Get-TopazStopSequenceExecutionTimeLimit {
    <#
    .SYNOPSIS
        Worst-case scheduled-task runtime for one Stop-Sequence invocation.
    .DESCRIPTION
        Register-TimedStop.ps1 must not kill its own bounded upload before the
        stop action runs. This derives the task limit from the same configured
        operation timeouts Stop-Sequence actually uses: optional S3 sync, the
        final upload and (when a recovery candidate exists) one recovery upload,
        each with two rclone copy/check attempts and one retry delay, the one
        completed-stop final rclone check, completed-render recovery scan and
        bounded forensic capture, optional SNS, every action in the resolved
        stop plan, and a five-minute process/setup margin. It intentionally
        describes one invocation, not the task's repeating lifetime.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)

    $seconds = [int64]300 # setup/teardown margin; all bounded operations below are explicit.

    if (-not [string]::IsNullOrWhiteSpace($Config.S3SyncTarget)) {
        $seconds += [int64]$Config.S3SyncTimeoutSec
    }
    if (-not [string]::IsNullOrWhiteSpace($Config.UploadTarget)) {
        # A final upload may be followed by one recovery upload. Each permits
        # two attempts with separately bounded copy AND check invocations.
        $seconds += ([int64]$Config.UploadTimeoutSec * 8) + ([int64]$Config.UploadRetryDelaySec * 2)
        # Completed stops also perform one final check-only verification after
        # the long upload work. Timed maxlifetime stops skip it, but this
        # generic bound remains safe for every Stop-Sequence reason.
        $seconds += [int64]$Config.UploadTimeoutSec
    }
    # Only a completed stop runs this path, but a scheduled-task limit must be
    # safe for every Stop-Sequence reason. Recovery upload is one batch, not
    # one timeout budget per candidate; its rclone call receives all candidates
    # in a single include list.
    $seconds += [int64]$Config.RecoveryScanTimeoutSec
    $seconds += [int64]$Config.TopazForensicTimeoutSec
    if (-not [string]::IsNullOrWhiteSpace($Config.SnsTopicArn)) {
        $seconds += [int64]$Config.AwsCliTimeoutSec
    }

    $plan = Resolve-StopPlan -Strategy $Config.StopStrategy
    if ($plan -contains 'Ec2ApiStop') { $seconds += [int64]$Config.AwsCliTimeoutSec }
    $seconds += ([int64]$plan.Count * [int64]$Config.StopVerifySec)
    return New-TimeSpan -Seconds $seconds
}

function Build-AwsCliArgs {
    <#
    .SYNOPSIS
        Pure: appends '--region <Region>' to $Base only when Region is set.
    .DESCRIPTION
        Centralizes the "only pass --region when IMDS region discovery
        succeeded" splat pattern duplicated across the aws CLI call sites in
        Stop-Sequence.ps1 and Push-GpuMetric.ps1 -- the SYSTEM account has no
        default region configured anywhere in this pipeline, so omitting
        --region when Region IS known would fail every call with
        NoRegionError, but appending a blank/whitespace --region would be
        just as broken.
    .PARAMETER Base
        The aws CLI argument list before any --region is added, e.g.
        @('s3', 'sync', $OutputDir, $Target, '--only-show-errors').
    .PARAMETER Region
        The discovered region, or $null/empty/whitespace if discovery failed.
    .OUTPUTS
        $Base unchanged, or $Base + @('--region', $Region).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Base,
        [string]$Region
    )

    # The leading unary comma on every return below is required, not
    # decorative: PowerShell's pipeline/return semantics collapse a returned
    # array to a bare scalar when it has exactly one element -- a caller
    # passing a single-element $Base (or splatting the single-element result)
    # would otherwise silently get a string back instead of an array.
    if ([string]::IsNullOrWhiteSpace($Region)) { return , $Base }
    return , ($Base + @('--region', $Region))
}

function Build-RcloneLogFileArgs {
    <#
    .SYNOPSIS
        Appends '--log-file <path>' to $Base, or leaves it unchanged if the
        path cannot be resolved.
    .DESCRIPTION
        Centralizes the rclone --log-file construction duplicated across
        Invoke-TopazRecoveryUpload, Invoke-TopazIncrementalUpload,
        Invoke-TopazRenderUpload, and Test-TopazCompletedStopSafetyGate.
        Join-Path throws when LogDir names a drive PowerShell cannot resolve
        on the current platform/provider (observed in CI: pwsh on a
        non-Windows runner has no 'C:' PSDrive, so the default Windows LogDir
        throws there even though the identical config works fine on the real
        Windows guest). The rclone log file is pure observability -- exactly
        like Write-TopazLog's own log file below -- so losing it must degrade
        to "no --log-file" rather than crash a real upload/verification
        attempt.
    .PARAMETER Base
        The rclone argument list before any --log-file is added.
    .PARAMETER LogDir
        The configured LogDir (Get-TopazAutoStopConfig's LogDir).
    .OUTPUTS
        $Base + @('--log-file', <path>), or $Base unchanged if the path could
        not be resolved.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Base,
        [Parameter(Mandatory)][string]$LogDir
    )

    try {
        # -ErrorAction Stop: Join-Path's DriveNotFoundException is a
        # NON-terminating error by default (an unresolvable drive letter
        # leaves $rcloneLog simply unassigned rather than throwing) -- without
        # Stop this catch never runs and $rcloneLog silently ends up $null,
        # reproducing the exact "--log-file <nothing>" bug this function
        # exists to prevent.
        $rcloneLog = Join-Path $LogDir 'rclone.log' -ErrorAction Stop
    }
    catch {
        return , $Base
    }
    return , ($Base + @('--log-file', $rcloneLog))
}

function Get-TopazWindowsPathRoot {
    <#
    .SYNOPSIS
        Pure: the drive-letter root of a Windows absolute path (e.g. 'D:\'
        for 'D:\Renders\file.mov'), or '' if $Path is not drive-letter-rooted.
    .DESCRIPTION
        [System.IO.Path]::GetPathRoot() is platform-aware, not a plain string
        operation: on non-Windows .NET it does not recognize drive-letter
        syntax at all and returns '' even for a well-formed 'D:\...' path --
        unlike on the real Windows guest this pipeline runs on, where the
        same call correctly returns 'D:\'. OutputDir/UploadTarget are always
        Windows paths regardless of which OS is running the CODE (dev/CI on
        a Mac/Linux runner vs. production on the Windows guest), so root
        extraction here uses a fixed regex against the 'X:\' convention
        instead of delegating to the executing platform's own path parser.
    .PARAMETER Path
        A Windows-style absolute path, e.g. $cfg.OutputDir.
    .OUTPUTS
        [string] The matched 'X:\' root, or '' if $Path has no such root.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if ($Path -match '^[A-Za-z]:\\') { return $Matches[0] }
    return ''
}

function ConvertTo-TopazCliArgument {
    <#
    .SYNOPSIS
        Pure: escapes a single argument for ProcessStartInfo.Arguments using
        the actual Win32 CommandLineToArgvW convention (mirrors .NET's own
        internal PasteArguments.AppendArgument), so Invoke-TopazAwsCli's
        hand-built argument string round-trips correctly through aws.exe's
        argv parser.
    .DESCRIPTION
        Arguments containing no whitespace and no double quote are returned
        unchanged. Otherwise the value is wrapped in double quotes, and while
        walking it: a run of backslashes immediately followed by a literal
        double quote is doubled, plus one more backslash, then the quote is
        escaped as \" ; a run of backslashes at the very END of the value
        (i.e. immediately before the closing quote this function adds) is
        also doubled, otherwise it would "eat" that closing quote and merge
        every subsequent shell-joined argument into this one -- exactly the
        bug this replaces (see Invoke-TopazAwsCli's own history: the previous
        '"' -> '""' doubling scheme neither doubled trailing backslashes nor
        used \" for an embedded quote, so it did not match this convention).
    .PARAMETER Value
        The raw, unescaped argument value.
    .OUTPUTS
        $Value unchanged if it needs no quoting, otherwise a properly
        quoted-and-escaped string safe to join with spaces into
        ProcessStartInfo.Arguments.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )

    if ($Value -notmatch '[\s"]') { return $Value }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')

    $backslashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '\') {
            $backslashes++
            continue
        }

        if ($ch -eq '"') {
            [void]$sb.Append('\' * ($backslashes * 2 + 1))
            [void]$sb.Append('"')
            $backslashes = 0
            continue
        }

        if ($backslashes -gt 0) {
            [void]$sb.Append('\' * $backslashes)
            $backslashes = 0
        }
        [void]$sb.Append($ch)
    }

    if ($backslashes -gt 0) {
        [void]$sb.Append('\' * ($backslashes * 2))
    }

    [void]$sb.Append('"')
    return $sb.ToString()
}

function Invoke-TopazAwsCli {
    <#
    .SYNOPSIS
        Runs the aws CLI bounded by a timeout, logging success/failure via
        Write-TopazLog. Returns $true on a clean exit 0, $false on timeout, a
        nonzero exit, or any exception -- every aws CLI call in this pipeline
        is strictly best-effort and must never let a failure here block
        anything else (S3 sync / SNS publish / CloudWatch metric push).
    .DESCRIPTION
        Mirrors Get-GpuUtilizationMax's deadlock-avoidance pattern: BOTH
        standard output and standard error are read via ReadToEndAsync()
        BEFORE WaitForExit is called, because a synchronous ReadToEnd() first
        would block until the child process closes that stream (normally at
        exit) -- exactly the hang this timeout exists to bound around. On
        timeout the process is Kill()ed so it cannot linger and keep holding
        the calling scheduled task's MultipleInstances=IgnoreNew slot open.

        PowerShell 5.1's ProcessStartInfo has no array-valued ArgumentList
        (that arrived only with .NET Core / PS 6+) -- following
        Get-GpuUtilizationMax's own precedent of a plain .Arguments STRING,
        $Arguments is joined into one escaped string here via the pure
        ConvertTo-TopazCliArgument, which implements the actual
        CommandLineToArgvW convention cmd.exe/aws.exe expect on Windows (see
        its own comment for why a naive '"' -> '""' doubling scheme, tried
        here previously, is NOT that convention and corrupts any argument
        that is both quoted and ends in a backslash).
    .PARAMETER FileName
        The executable to run. Defaults to 'aws' (resolved via PATH), which is
        what every original caller wants. Pass a full path to run a different
        bounded CLI -- rclone, for instance -- and reuse the deadlock-avoidance
        and timeout handling above rather than reimplementing it.
    .PARAMETER Arguments
        The aws CLI argument list, e.g. @('s3','sync',...,'--region','us-east-1').
    .PARAMETER TimeoutSec
        Bound on the whole call; on expiry the process is killed and this
        returns $false.
    .PARAMETER Component
        Write-TopazLog component tag (e.g. 'stop', 'metric').
    .PARAMETER SuccessMessage
        Logged at INFO on a clean exit 0.
    .PARAMETER FailureVerb
        Short present-tense phrase used in WARN messages, e.g. 'S3 sync' or
        'SNS publish'.
    .PARAMETER FailureContext
        Optional extra text appended to WARN messages (e.g. a target ARN).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][int]$TimeoutSec,
        [Parameter(Mandatory)][string]$Component,
        [Parameter(Mandatory)][string]$SuccessMessage,
        [Parameter(Mandatory)][string]$FailureVerb,
        [string]$FailureContext = '',
        [string]$FileName = 'aws'
    )

    $proc = $null
    try {
        $escapedArgs = $Arguments | ForEach-Object { ConvertTo-TopazCliArgument -Value $_ }

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $FileName
        $psi.Arguments              = [string]::Join(' ', $escapedArgs)
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.CreateNoWindow         = $true

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        [void]$proc.Start()

        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()

        if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
            try { $proc.Kill() } catch { }
            Write-TopazLog -Component $Component -Level 'WARN' `
                -Message "$FailureVerb timed out after ${TimeoutSec}s. $FailureContext"
            return $false
        }

        if ($proc.ExitCode -eq 0) {
            Write-TopazLog -Component $Component -Level 'INFO' -Message $SuccessMessage
            return $true
        }

        $tail = "$($stdoutTask.Result)$($stderrTask.Result)".Trim()
        Write-TopazLog -Component $Component -Level 'WARN' `
            -Message "$FailureVerb exited with code $($proc.ExitCode). Output: $tail $FailureContext"
        return $false
    }
    catch {
        Write-TopazLog -Component $Component -Level 'WARN' `
            -Message "$FailureVerb failed: $($_.Exception.Message) $FailureContext"
        return $false
    }
    finally {
        if ($proc) { $proc.Dispose() }
    }
}

function Test-IsScratchDiskCandidate {
    <#
    .SYNOPSIS
        Pure: is this disk the EC2 instance-store scratch disk, and therefore
        safe to destroy and reformat? No I/O, so it is fully unit-testable --
        which matters more here than anywhere else in this codebase, because
        the consequence of a wrong $true is formatting the operating system.
    .DESCRIPTION
        EVERY condition below is load-bearing. A disk qualifies only if all of
        them hold:

          BusType is NVMe          - both EBS and instance store present as
                                     NVMe on Nitro instances, so this alone
                                     excludes nothing; it is a sanity floor.
          IsBoot is $false         - the OS disk fails this.
          IsSystem is $false       - the OS disk fails this too.
          Serial does not start    - every EBS volume's serial IS its vol-xxxx
            with 'vol'               id. The instance store's is not. NOTE the
                                     explicit null/empty rejection below: a
                                     BLANK serial does not start with 'vol'
                                     either, so a naive -notmatch would let an
                                     unidentifiable disk through. Unknown
                                     provenance is treated as disqualifying,
                                     not as passing.
          Size within bounds       - guards against a future instance type
                                     whose instance store is a different size,
                                     where "the only RAW disk" might be
                                     something else entirely.
          No formatted volume      - the decisive data-safety check. A disk
                                     carrying any filesystem might hold data
                                     somebody wants. Only a disk with nothing
                                     mountable on it is a candidate.

        The PartitionStyle is deliberately NOT part of this predicate. A
        RAW disk is the normal case, but a PARTIALLY provisioned one (Initialize
        -Disk succeeded, then New-Partition or Format-Volume failed) is left
        GPT with no usable filesystem, and would otherwise never match again --
        bricking the scratch drive permanently on every subsequent boot. The
        "no formatted volume" condition is what makes it safe to reclaim such a
        disk regardless of its partition style.
    .PARAMETER Disk
        A Get-Disk object: needs .BusType, .IsBoot, .IsSystem, .SerialNumber, .Size.
    .PARAMETER MinBytes
        Lower size bound (Config's ScratchMinBytes).
    .PARAMETER MaxBytes
        Upper size bound (Config's ScratchMaxBytes).
    .PARAMETER HasFormattedVolume
        Whether ANY partition on this disk carries a mountable filesystem. The
        caller resolves this (it needs I/O); passing it in keeps this function
        pure.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Disk,
        [Parameter(Mandatory)][int64]$MinBytes,
        [Parameter(Mandatory)][int64]$MaxBytes,
        [Parameter(Mandatory)][bool]$HasFormattedVolume
    )

    if ($Disk.BusType -ne 'NVMe') { return $false }

    # -eq $true, not truthiness: a $null IsBoot/IsSystem (property absent or
    # unreadable) must NOT be read as "false, therefore safe".
    if ($Disk.IsBoot -eq $true)   { return $false }
    if ($Disk.IsSystem -eq $true) { return $false }
    if ($null -eq $Disk.IsBoot)   { return $false }
    if ($null -eq $Disk.IsSystem) { return $false }

    # A blank serial is unidentifiable provenance, and '' -notmatch '^vol' is
    # $true -- so without this the EBS exclusion silently passes it.
    if ([string]::IsNullOrWhiteSpace($Disk.SerialNumber)) { return $false }
    if ($Disk.SerialNumber -match '^vol')                 { return $false }

    if ($null -eq $Disk.Size)      { return $false }
    if ([int64]$Disk.Size -le $MinBytes) { return $false }
    if ([int64]$Disk.Size -ge $MaxBytes) { return $false }

    if ($HasFormattedVolume) { return $false }

    return $true
}

function Resolve-UploadRetryDecision {
    <#
    .SYNOPSIS
        Pure: given the attempt just completed, decide whether the caller
        should try again. No I/O, so it is fully unit-testable -- and it is
        the ONE place the "how many attempts total" number lives, rather than
        an inline loop counter duplicated at every call site.
    .DESCRIPTION
        THE BOUND IS THE POINT. This pipeline's whole design assumes that
        once Reason='completed'/'stalled' fires, EITHER the stop succeeds OR
        it refuses and leaves the box running for a human -- there is no
        longer any other automatic stop watching an ephemeral render (the
        out-of-band CloudWatch idle alarm cannot fire here either; see
        docs/12). An unbounded or "just retry a few more times" upload loop
        would instead sit burning instance-hours against a permanently broken
        credential with nobody watching. MaxAttempts is therefore a real
        parameter (so tests can pin the exact number), but every call site in
        this file passes a literal small constant (2 = one initial attempt
        plus one retry) -- it is deliberately not exposed as an
        OPERATOR-tunable Config.ps1 knob, so bumping it up is not a one-line
        config edit.
    .PARAMETER AttemptNumber
        The attempt that just ran (1-based).
    .PARAMETER MaxAttempts
        Total attempts allowed.
    .PARAMETER Succeeded
        Whether that attempt succeeded (copy AND verify both passed).
    .OUTPUTS
        [bool] $true if the caller should attempt again.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$AttemptNumber,
        [Parameter(Mandatory)][int]$MaxAttempts,
        [Parameter(Mandatory)][bool]$Succeeded
    )

    if ($Succeeded) { return $false }
    return ($AttemptNumber -lt $MaxAttempts)
}

function Resolve-OutputAnomalyClass {
    <#
    .SYNOPSIS
        Pure: classify the render-output situation at stop time, given why the
        stop was invoked, whether OutputDir itself has any files, and whether
        a best-effort scan of the OutputDir volume found any RECENT, UNLOCKED
        candidate render file elsewhere. No I/O, so it is fully unit-testable.
    .DESCRIPTION
        RENAMED from Resolve-EmptyOutputDirDecision (2026-07-28, CORRECTION 1).
        The old name and its single OutputDir-is-empty trigger were built
        around the SYMPTOM the first incident happened to produce, not the
        actual failure. Live counter-example, present on this box the day this
        was fixed:

            D:\Renders\SDR_Render_video3_pnat1.mov   2,311,449,636 bytes  (correct)
            D:\SDR_Render_video3_227249191.mov       growing              (live intermediate)
            D:\SDR_Render_video3.mov                 1,616,764,730 bytes  (source)

        OutputDir is NON-EMPTY here (it holds pnat-1's correctly placed
        output). If the SECOND export's mux again drops the "Renders\"
        prefix, its deliverable lands at D:\ root while OutputDir still has
        pnat-1's file sitting in it -- an empty-OutputDir trigger would never
        fire, and the second render would be erased exactly like the first.
        The real question was never "is OutputDir empty", it is "does a
        recent, complete render file exist OUTSIDE OutputDir that the stop is
        about to erase" -- which is orthogonal to whatever OutputDir itself
        contains. Hence CandidatesFound and OutputDirHasFiles are now two
        INDEPENDENT booleans, not one implied by the other.

        THE INCIDENT THIS STILL ENCODES. Reason='completed' only ever fires
        after ArmSec of CONTINUOUSLY observed worker activity (see ArmSec's
        own comment) -- so by the time it fires, a real render is known to
        have run. That is what makes "OutputDir has nothing AND nothing was
        found anywhere else" a genuine anomaly (ErrorClassB) rather than the
        unremarkable case it would be mid-render. 'stalled' and 'maxlifetime'
        carry no such guarantee (a render may simply not have produced a
        deliverable YET), so they are always 'NotApplicable' here, regardless
        of OutputDir's contents -- preserving the pipeline's original
        "nothing to upload from OutputDir itself, safe to proceed" behaviour
        for those two reasons.

        THE TWO ERROR CLASSES ARE NOW INDEPENDENT OF OutputDir's OWN STATE:
          ErrorClassA (RENDER-OUTSIDE-OUTPUTDIR) fires whenever a recent
            candidate is found elsewhere on the volume, WHETHER OR NOT
            OutputDir itself is empty -- a misplaced SECOND file is just as
            real a loss when OutputDir already holds a correct FIRST one.
          ErrorClassB (RENDER-PRODUCED-NO-OUTPUT) only ever applies when
            OutputDir is ALSO empty: if OutputDir has files, something was
            produced and correctly placed, so "no output" is false even if
            nothing extra was found outside it.
        Class A therefore takes priority when both conditions could
        theoretically be evaluated -- but by construction they cannot both be
        true simultaneously (CandidatesFound=true blocks ErrorClassB by
        definition), so this is a precedence rule in name only.

        THE OPERATOR'S CHOSEN BEHAVIOUR (verbatim; see Stop-Sequence.ps1's own
        comment for the full quote): stop the box EITHER WAY, after best-
        effort recovery and an unambiguous log record. This function only
        LABELS which situation occurred -- greppably and distinctly, so none
        of the four are ever confused when read later -- it does not decide
        whether to stop; nothing downstream of it may turn any class into a
        refusal.
    .PARAMETER Reason
        'completed' | 'stalled' | 'maxlifetime'.
    .PARAMETER OutputDirHasFiles
        Whether OutputDir itself currently has at least one file. No longer
        the trigger for running the scan (see CORRECTION 1 above) -- purely
        an input to the classification now.
    .PARAMETER CandidatesFound
        Whether Find-RenderRecoveryCandidates found ANY recent, UNLOCKED
        candidate file outside OutputDir. Only consulted when Reason is
        'completed'; harmless (ignored) otherwise.
    .OUTPUTS
        'NotApplicable' - Reason is not 'completed': the ArmSec guarantee that
                          makes an anomaly diagnosable does not hold yet, so
                          this function does not classify anything.
        'ErrorClassA'   - RENDER-OUTSIDE-OUTPUTDIR: reason='completed' and a
                          recent, unlocked candidate was found elsewhere on
                          the volume -- regardless of OutputDir's own state.
        'ErrorClassB'   - RENDER-PRODUCED-NO-OUTPUT: reason='completed',
                          OutputDir is empty, and nothing was found anywhere
                          else on the volume either.
        'Normal'        - reason='completed', OutputDir has file(s), and
                          nothing anomalous was found outside it. The ordinary,
                          healthy single-deliverable case.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('completed', 'stalled', 'maxlifetime')][string]$Reason,
        [Parameter(Mandatory)][bool]$OutputDirHasFiles,
        [Parameter(Mandatory)][bool]$CandidatesFound
    )

    if ($Reason -ne 'completed') { return 'NotApplicable' }
    if ($CandidatesFound) { return 'ErrorClassA' }
    if (-not $OutputDirHasFiles) { return 'ErrorClassB' }
    return 'Normal'
}

function Find-RenderRecoveryCandidates {
    <#
    .SYNOPSIS
        Best-effort scan of the volume housing OutputDir for candidate render
        files OUTSIDE OutputDir -- the forensic/recovery aid for the
        2026-07-28 incident, where a finished 2.3 GB render landed one
        directory above OutputDir (D:\ root, not D:\Renders) and was invisible
        to every check in this pipeline (all scoped to OutputDir alone) until
        the box was already gone.
    .DESCRIPTION
        SCOPE IS DELIBERATELY THE OUTPUTDIR VOLUME, NOT THE WHOLE MACHINE.
        Independent verification of the incident found that a render
        INTERMEDIATE also transiently touched C:\...\previews\ mid-job
        (Topaz's own internal concat/mux staging) -- but it self-deleted
        before the mux finished, and more to the point: C: is NOT the
        ephemeral volume, so nothing there is destroyed by the stop regardless
        of whether this scan sees it. This scan exists to catch exactly what
        the stop is about to ERASE, which (see OutputIsEphemeral) is scoped to
        OutputDir's own volume. Anything genuinely lost on a PERSISTENT volume
        was never at risk from the stop in the first place.

        BOUNDED on every axis that could turn a forensic aid into a delayed or
        hung stop:
          - depth-limited (MaxDepth), so a deeply nested project tree cannot
            blow up the walk;
          - count-limited (MaxFiles), so a volume full of small scratch files
            cannot make the candidate list unusable;
          - wall-clock-limited (MaxSeconds), checked BETWEEN directories (not
            only once at the very end) via a manual iterative walk rather
            than a single Get-ChildItem -Recurse, so a slow/degraded disk
            cannot hang the stop path this is strictly subordinate to;
          - wrapped in try/catch throughout: ANY failure here (including a
            single unreadable subdirectory) degrades gracefully rather than
            aborting the whole scan or throwing into the stop sequence.
        Like every other bounded I/O call in this file (Get-GpuUtilizationMax,
        Invoke-TopazAwsCli), this bound is cooperative, not preemptive: it
        cannot abort a single Get-ChildItem call that is itself wedged on a
        dead I/O path. That is an accepted, not a hidden, limitation -- the
        volume in question is the local instance-store scratch disk, not a
        network share, so a genuinely hung directory listing is not a
        realistic failure mode here the way a hung external process is.

        A CAP MUST NEVER READ AS "CONFIRMED NOTHING ELSE IS ON THE VOLUME",
        and a SCAN FAILURE MUST NEVER READ AS "CONFIRMED FOUND NOTHING"
        either -- those are three different facts, so all three are reported
        back distinctly (Candidates / Truncated / ScanFailed) for the caller
        to log distinctly.

        RECENCY IS PART OF THE MATCH, NOT AN OPTIMISATION. Extension alone
        cannot distinguish a render that finished minutes ago from source
        footage that has sat on this volume all session -- and OutputDir's own
        config comment states that staging source at the volume ROOT is the
        expected layout. In the 2026-07-28 incident the 1.6 GB source and
        pnat-1's abandoned partial output both sat at D:\ root alongside the
        lost render. Matching on extension alone would therefore re-upload
        already-safe source footage as though it were the recovery, and would
        make a render that produced NOTHING still report candidates -- turning
        "the render failed outright" into "the render was merely misplaced".
        So files older than ModifiedAfter are split out into ExcludedByAge:
        still found, still reported, never uploaded, and never allowed to
        decide the error class. Reporting rather than silently dropping them
        follows the same rule as the caps above -- the operator must be able
        to see everything the scan saw.

        OVER-RECOVERING IS ACCEPTED AND PREFERRED TO UNDER-RECOVERING. A
        recent, unlocked, extension-matching file that turns out to just be
        source footage staged at the root (rather than a lost deliverable)
        gets uploaded needlessly -- but rclone `copy`/`check` skip a
        destination file that already matches by size, so a re-upload of
        something already safe costs a little bandwidth and nothing else. The
        opposite mistake -- narrowing the match until a real deliverable slips
        through -- is UNRECOVERABLE once the stop erases this volume. Do not
        "tighten" ModifiedAfter, Extensions, or this margin later in the name
        of precision without weighing that asymmetry again.

        A THIRD BUCKET, SkippedInProgress, EXISTS FOR THE SAME REASON
        Test-FileUnlocked was moved into this file (CORRECTION 2, 2026-07-28):
        recency and extension alone cannot tell a just-finished, misplaced
        deliverable apart from Topaz's own LIVE intermediate
        (D:\SDR_Render_video3_<digits>.mov), which is written at the volume
        root WHILE an export is still running and is neither abandoned nor a
        recovery candidate -- it is the normal, expected shape of an
        in-progress job. A file that is recent AND extension-matches AND is
        still LOCKED (a writer holds it open) is exactly that case: it goes to
        SkippedInProgress, never Candidates, and -- critically -- never gets a
        vote in Resolve-OutputAnomalyClass's decision. Without this split, a
        live intermediate mid-mux would either (a) get uploaded half-written
        by Invoke-TopazRecoveryUpload, or (b) wrongly count as "found
        something", masking the fact that the REAL deliverable is still
        missing.
    .PARAMETER OutputDir
        The configured output folder (may or may not be empty -- see
        CORRECTION 1: this scan runs regardless of OutputDir's own contents).
        Excluded from the walk, along with "System Volume Information" and
        "$RECYCLE.BIN".
    .PARAMETER Extensions
        Config's RenderFileExtensions, e.g. @('.mov','.mp4','.mkv','.avi','.mxf').
    .PARAMETER ModifiedAfter
        Only files whose LastWriteTime is at or after this instant are
        considered for Candidates/SkippedInProgress; older extension-matches
        go to ExcludedByAge regardless of lock state.
    .PARAMETER MaxFiles
        Stop collecting once this many candidates are found.
    .PARAMETER MaxDepth
        Directory depth bound below the volume root (0 = the root's own files
        only).
    .PARAMETER MaxSeconds
        Wall-clock bound on the whole scan.
    .OUTPUTS
        [pscustomobject]@{
            Candidates       = @(<System.IO.FileInfo>, ...)  # recent, unlocked; possibly empty
            ExcludedByAge    = @(<System.IO.FileInfo>, ...)  # matched, too old
            SkippedInProgress = @(<System.IO.FileInfo>, ...) # recent, but still LOCKED (a live write)
            Truncated        = [bool]  # MaxFiles/MaxSeconds cut the scan short
            ScanFailed       = [bool]  # the scan itself could not run/complete
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OutputDir,
        [Parameter(Mandatory)][string[]]$Extensions,
        [Parameter(Mandatory)][datetime]$ModifiedAfter,
        [Parameter(Mandatory)][int]$MaxFiles,
        [Parameter(Mandatory)][int]$MaxDepth,
        [Parameter(Mandatory)][int]$MaxSeconds
    )

    $result = [pscustomobject]@{
        Candidates        = @()
        ExcludedByAge     = @()
        SkippedInProgress = @()
        Truncated         = $false
        ScanFailed        = $false
    }

    try {
        $root = Get-TopazWindowsPathRoot -Path $OutputDir
        if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root)) {
            $result.ScanFailed = $true
            return $result
        }

        # Plain concatenation, not Join-Path: $root is already guaranteed to
        # end in '\' (Get-TopazWindowsPathRoot's own contract), and Join-Path
        # -- like [System.IO.Path]::GetPathRoot() above -- fails to resolve a
        # drive-letter path when the executing platform has no such drive
        # (any non-Windows dev/CI box; see Get-TopazWindowsPathRoot's comment).
        $excluded = @(
            ($root + 'System Volume Information'),
            ($root + '$RECYCLE.BIN'),
            $OutputDir
        ) | ForEach-Object { $_.TrimEnd('\').ToLowerInvariant() }

        $extSet = @{}
        foreach ($e in $Extensions) {
            if (-not [string]::IsNullOrWhiteSpace($e)) { $extSet[$e.ToLowerInvariant()] = $true }
        }

        $deadline   = (Get-Date).AddSeconds($MaxSeconds)
        $found      = New-Object System.Collections.Generic.List[object]
        $tooOld     = New-Object System.Collections.Generic.List[object]
        $inProgress = New-Object System.Collections.Generic.List[object]

        # Manual iterative walk (not a single Get-ChildItem -Recurse) so the
        # wall-clock deadline and the file cap can both be checked BETWEEN
        # directories, not only after the whole recursive enumeration has
        # already finished -- the exact bound that matters on a large volume.
        $dirQueue = New-Object System.Collections.Generic.Queue[object]
        $dirQueue.Enqueue([pscustomobject]@{ Path = $root; Depth = 0 })

        while ($dirQueue.Count -gt 0) {
            if ((Get-Date) -ge $deadline) { $result.Truncated = $true; break }
            # Cap the COMBINED total across ALL THREE buckets, not just the
            # recent/candidate list: otherwise a volume full of old media (or
            # full of in-progress writes) would leave $found at 0, sail past
            # this bound, and let ExcludedByAge/SkippedInProgress grow without
            # limit.
            if (($found.Count + $tooOld.Count + $inProgress.Count) -ge $MaxFiles) { $result.Truncated = $true; break }

            $current = $dirQueue.Dequeue()

            if ($excluded -contains $current.Path.TrimEnd('\').ToLowerInvariant()) { continue }

            try {
                $entries = Get-ChildItem -LiteralPath $current.Path -Force -ErrorAction Stop
            }
            catch {
                # One unreadable directory (permissions, a transient handle)
                # should not sink the whole scan -- skip it and keep going.
                # It DOES mean the result cannot honestly be described as a
                # complete scan with no candidates, however.
                $result.ScanFailed = $true
                continue
            }

            foreach ($entry in $entries) {
                if (($found.Count + $tooOld.Count + $inProgress.Count) -ge $MaxFiles) {
                    $result.Truncated = $true; break
                }

                if ($entry.PSIsContainer) {
                    if ($current.Depth -lt $MaxDepth) {
                        $childPath = $entry.FullName.TrimEnd('\').ToLowerInvariant()
                        if ($excluded -notcontains $childPath) {
                            $dirQueue.Enqueue([pscustomobject]@{ Path = $entry.FullName; Depth = $current.Depth + 1 })
                        }
                    }
                    continue
                }

                if ($extSet.ContainsKey($entry.Extension.ToLowerInvariant())) {
                    # Recency decides RECOVERY, not discovery: an older match is
                    # still recorded so the log shows everything the scan saw,
                    # it is just not uploaded and cannot flip the error class
                    # (see .DESCRIPTION -- source footage lives here too).
                    if ($entry.LastWriteTime -ge $ModifiedAfter) {
                        # RECENT: still need to rule out a LIVE intermediate
                        # (CORRECTION 2). A file a writer still holds open is
                        # not abandoned and not a recovery candidate -- it is
                        # Topaz's normal in-progress layout (see
                        # Test-FileUnlocked's own comment on why this moved
                        # here). Locked-ness must NEVER decide the error class,
                        # so it goes to its own bucket, not ExcludedByAge (that
                        # bucket is for AGE, a different fact) and not
                        # Candidates.
                        if (Test-FileUnlocked -Path $entry.FullName) {
                            [void]$found.Add($entry)
                        }
                        else {
                            [void]$inProgress.Add($entry)
                        }
                    }
                    else {
                        [void]$tooOld.Add($entry)
                    }
                }
            }
        }

        $result.Candidates        = $found.ToArray()
        $result.ExcludedByAge     = $tooOld.ToArray()
        $result.SkippedInProgress = $inProgress.ToArray()
        return $result
    }
    catch {
        # Whatever failed, the scan itself did not complete -- this is a
        # DIFFERENT fact from "completed and found nothing" (see .DESCRIPTION).
        $result.ScanFailed = $true
        return $result
    }
}

function Invoke-TopazForensicCapture {
    <#
    .SYNOPSIS
        Best-effort: locate the most recently modified *.tzlog under
        TopazLogsBasePath and copy its "process exited"/"error occurred"
        lines into stop.log, so a future reader can see WHY Topaz's own
        render failed without needing a box that may already be gone.
    .DESCRIPTION
        THE GAP THIS CLOSES. Neither anomalous branch of
        Invoke-TopazOutputAnomalyHandling records anything about what Topaz
        itself did -- that information existed ONLY in Topaz's own session
        log. In the 2026-07-28 incident the .tzlog was the sole source that
        showed process 31/34 dying with "process exited error occurred: 31 1"
        / "...34 1", the crash-recovery reload that silently dropped
        "Renders\" from the retried export's cleanupPass path, and pnat-1's
        outright, unretried failure. Without this capture, "render failed"
        was completely invisible from this pipeline's OWN logs, and the whole
        incident was only reconstructable because the .tzlog happened to
        still be sitting on a persistent volume (C:) after the box stopped.

        STRICTLY BEST-EFFORT: every failure mode (missing/wrong
        TopazLogsBasePath, no *.tzlog present, an unreadable file, a
        Select-String failure, anything) is caught here and logged as a WARN,
        never allowed to throw, hang, or delay the stop sequence this is a
        side-note to. Time-bounded via TopazForensicTimeoutSec, checked
        between the file-listing and the content-scan steps.
    .PARAMETER Config
        Get-TopazAutoStopConfig object (uses TopazLogsBasePath,
        TopazForensicMaxLines, TopazForensicTimeoutSec).
    .OUTPUTS
        None -- writes directly via Write-TopazLog. Never throws.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)

    $cfg = $Config

    try {
        if ([string]::IsNullOrWhiteSpace($cfg.TopazLogsBasePath) -or -not (Test-Path -LiteralPath $cfg.TopazLogsBasePath)) {
            Write-TopazLog -Component 'stop' -Level 'WARN' `
                -Message "Topaz forensic capture SKIPPED: TopazLogsBasePath '$($cfg.TopazLogsBasePath)' does not exist (wrong account, or Topaz has never run on this box). No .tzlog forensics captured."
            return
        }

        $deadline = (Get-Date).AddSeconds($cfg.TopazForensicTimeoutSec)

        $latest = Get-ChildItem -LiteralPath $cfg.TopazLogsBasePath -Filter '*.tzlog' -File -ErrorAction Stop |
            Sort-Object -Property LastWriteTime -Descending |
            Select-Object -First 1

        if (-not $latest) {
            Write-TopazLog -Component 'stop' -Level 'WARN' `
                -Message "Topaz forensic capture: no *.tzlog file found under '$($cfg.TopazLogsBasePath)'."
            return
        }

        if ((Get-Date) -ge $deadline) {
            Write-TopazLog -Component 'stop' -Level 'WARN' `
                -Message "Topaz forensic capture ABORTED: locating the newest *.tzlog under '$($cfg.TopazLogsBasePath)' alone exceeded the $($cfg.TopazForensicTimeoutSec)s bound (TopazForensicTimeoutSec)."
            return
        }

        Write-TopazLog -Component 'stop' -Level 'INFO' `
            -Message "Topaz forensic capture: most recent session log is '$($latest.FullName)' (last write $($latest.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss.fff')))."

        $matched = @(Select-String -LiteralPath $latest.FullName `
            -Pattern 'process exited error occurred', 'process exited:' -ErrorAction Stop)

        if ((Get-Date) -ge $deadline) {
            Write-TopazLog -Component 'stop' -Level 'WARN' `
                -Message "Topaz forensic capture ABORTED after scanning '$($latest.FullName)': exceeded the $($cfg.TopazForensicTimeoutSec)s bound (TopazForensicTimeoutSec) before logging any matched line."
            return
        }

        if ($matched.Count -eq 0) {
            Write-TopazLog -Component 'stop' -Level 'INFO' `
                -Message "Topaz forensic capture: '$($latest.FullName)' contains no 'process exited' line."
            return
        }

        # The LAST N matches are the diagnostic ones (the final, decisive
        # failure), not the first -- a crash-looping render can log many.
        $capped = $matched | Select-Object -Last $cfg.TopazForensicMaxLines
        if ($matched.Count -gt $cfg.TopazForensicMaxLines) {
            Write-TopazLog -Component 'stop' -Level 'WARN' `
                -Message "Topaz forensic capture: $($matched.Count) matching line(s) found in '$($latest.FullName)'; logging only the last $($cfg.TopazForensicMaxLines) (TopazForensicMaxLines)."
        }

        foreach ($m in $capped) {
            Write-TopazLog -Component 'stop' -Level 'INFO' `
                -Message "TOPAZ-LOG [$($latest.Name)]: $($m.Line.Trim())"
        }
    }
    catch {
        # Best-effort, no exceptions: must never abort or delay the stop.
        Write-TopazLog -Component 'stop' -Level 'WARN' `
            -Message "Topaz forensic capture FAILED (best-effort, ignored): $($_.Exception.Message)"
    }
}

function Invoke-TopazRecoveryUpload {
    <#
    .SYNOPSIS
        Best-effort upload + independent verification of a SPECIFIC list of
        candidate render files found OUTSIDE OutputDir (ERROR CLASS A:
        "render landed outside OutputDir"). Logs an explicit per-file
        disposition. NEVER blocks the stop -- unlike
        Invoke-TopazRenderUpload's ephemeral interlock, the caller proceeds to
        stop regardless of what this function achieves.
    .DESCRIPTION
        REUSES THE SAME rclone copy + check PLUMBING AS THE NORMAL UPLOAD
        PATH, scoped down with `--include` filters to exactly the candidate
        files' paths relative to the OutputDir volume's root, rather than
        shelling out to rclone afresh or writing a per-file copyto loop. This
        is the "simplest approach that reuses existing, already-tested code"
        the task calls for: `copy`/`check` (not `copyto`, not a bespoke
        per-file command) with the SAME argument shape Invoke-TopazRenderUpload
        already uses, just with the source widened to the volume root and
        `--include` narrowing it back down to only the discovered candidates
        (each candidate can live in a different directory; a single `--include`
        list handles that without needing a common parent folder).

        THE DELIBERATE ASYMMETRY WITH THE NORMAL PATH. A normal-path upload
        failing twice REFUSES to stop (Stop-Sequence.ps1's ephemeral
        interlock), because OutputDir holding EXPECTED output is the common
        case this whole pipeline exists to protect, and losing a render nobody
        knows is broken yet is the worst outcome. This recovery path is
        different BY THE OPERATOR'S OWN EXPLICIT INSTRUCTION: it is already
        handling an anomaly the operator chose in advance to accept ("if
        human error and render lands in wrong folder, im fine with it
        shutting down but try best effort to find it first and complete the
        upload"). So a failure here still lets the caller STOP -- this
        function's whole job is to make the disposition of every file
        unambiguous in the log, not to gate the stop.
    .PARAMETER Config
        Get-TopazAutoStopConfig object.
    .PARAMETER Candidates
        FileInfo objects from Find-RenderRecoveryCandidates.
    .OUTPUTS
        [pscustomobject]@{ AnyUnrecovered = [bool] } -- informational only;
        the caller does not use this to decide whether to stop.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Candidates
    )

    $cfg = $Config

    if ($Candidates.Count -eq 0) { return [pscustomobject]@{ AnyUnrecovered = $false } }

    function Write-RecoveryDisposition {
        param([Parameter(Mandatory)]$File, [Parameter(Mandatory)][string]$Disposition, [string]$Detail = '')
        $sizeAndTime = "$($File.Length) bytes, last write $($File.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss.fff'))"
        Write-TopazLog -Component 'stop' -Level $(if ($Disposition -eq 'uploaded+verified') { 'INFO' } else { 'ERROR' }) `
            -Message "RECOVERY DISPOSITION: $Disposition -- '$($File.FullName)' ($sizeAndTime). $Detail".TrimEnd()
    }

    $notRecoveredDetail = if ($cfg.OutputIsEphemeral) {
        'This file will be PERMANENTLY DESTROYED when the stop wipes the ephemeral volume, and is UNRECOVERABLE after that.'
    }
    else {
        'OutputDir is not on ephemeral storage, so the file itself is not being destroyed by this stop -- but it was NOT uploaded anywhere and remains only on local disk.'
    }

    if (-not (Test-Path -LiteralPath $cfg.RclonePath) -or -not (Test-Path -LiteralPath $cfg.RcloneConfigPath) `
        -or [string]::IsNullOrWhiteSpace($cfg.UploadTarget)) {
        Write-TopazLog -Component 'stop' -Level 'ERROR' `
            -Message "RECOVERY UPLOAD SKIPPED: rclone ('$($cfg.RclonePath)'), its config ('$($cfg.RcloneConfigPath)'), or UploadTarget is not available. Every candidate below is NOT RECOVERED."
        foreach ($c in $Candidates) { Write-RecoveryDisposition -File $c -Disposition 'NOT RECOVERED' -Detail $notRecoveredDetail }
        return [pscustomobject]@{ AnyUnrecovered = $true }
    }

    $root     = Get-TopazWindowsPathRoot -Path $cfg.OutputDir
    $destBase = "$($cfg.UploadTarget.TrimEnd('/'))/recovered"

    $includeArgs = New-Object System.Collections.Generic.List[string]
    foreach ($c in $Candidates) {
        $rel = $c.FullName.Substring($root.Length).Replace('\', '/')
        [void]$includeArgs.Add('--include')
        [void]$includeArgs.Add($rel)
    }

    $common    = Build-RcloneLogFileArgs -LogDir $cfg.LogDir `
        -Base @('--config', $cfg.RcloneConfigPath, '--log-level', 'INFO')
    $tuning    = @('--transfers', '4', '--drive-chunk-size', '128M', '--retries', '3', '--low-level-retries', '10', '--stats', '1m')

    $copyArgs  = @('copy', $root, $destBase) + $common + $tuning + $includeArgs
    $checkArgs = @('check', $root, $destBase) + $common + @('--one-way') + $includeArgs

    Write-TopazLog -Component 'stop' -Level 'INFO' `
        -Message "Attempting best-effort recovery upload of $($Candidates.Count) candidate file(s) from '$root' -> '$destBase'."

    # Same MAX-ONE-RETRY policy as the normal upload path, via the SAME pure
    # Resolve-UploadRetryDecision helper -- it can only help a transient blip,
    # and the hard cap matters here too: this runs on every anomalous
    # completion, and an unbounded loop here would burn instance hours against
    # a broken credential just as readily as it would on the normal path.
    $maxAttempts  = 2
    $lastCopied   = $false
    $lastVerified = $false

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        Write-TopazLog -Component 'stop' -Level 'INFO' `
            -Message "Recovery upload attempt $attempt of $maxAttempts (rclone copy)."

        $lastCopied = Invoke-TopazAwsCli -FileName $cfg.RclonePath -Arguments $copyArgs `
            -TimeoutSec $cfg.UploadTimeoutSec -Component 'stop' `
            -SuccessMessage "Recovery upload attempt $attempt of ${maxAttempts}: rclone copy completed." `
            -FailureVerb "Recovery upload attempt $attempt of $maxAttempts (rclone copy)" `
            -FailureContext "target=$destBase."

        $lastVerified = $false
        if ($lastCopied) {
            Write-TopazLog -Component 'stop' -Level 'INFO' `
                -Message "Recovery upload attempt $attempt of $maxAttempts (rclone check)."

            $lastVerified = Invoke-TopazAwsCli -FileName $cfg.RclonePath -Arguments $checkArgs `
                -TimeoutSec $cfg.UploadTimeoutSec -Component 'stop' `
                -SuccessMessage "Recovery upload attempt $attempt of ${maxAttempts}: rclone check VERIFIED every candidate file." `
                -FailureVerb "Recovery upload attempt $attempt of $maxAttempts (rclone check)" `
                -FailureContext "target=$destBase."
        }

        if ($lastCopied -and $lastVerified) { break }

        if (Resolve-UploadRetryDecision -AttemptNumber $attempt -MaxAttempts $maxAttempts -Succeeded $false) {
            Write-TopazLog -Component 'stop' -Level 'WARN' `
                -Message "Recovery upload attempt $attempt of $maxAttempts failed (copied=$lastCopied verified=$lastVerified). Retrying once more in $($cfg.UploadRetryDelaySec)s."
            Start-Sleep -Seconds $cfg.UploadRetryDelaySec
        }
    }

    $anyUnrecovered = $false
    foreach ($c in $Candidates) {
        if ($lastCopied -and $lastVerified) {
            Write-RecoveryDisposition -File $c -Disposition 'uploaded+verified' -Detail "-> '$destBase'."
        }
        elseif ($lastCopied) {
            # rclone copy succeeded (and validates its own transfer hash) but
            # the independent `check` pass did not confirm it -- a real,
            # distinct middle state between "safe" and "lost", per the task.
            $anyUnrecovered = $true
            Write-RecoveryDisposition -File $c -Disposition 'uploaded-but-unverified' `
                -Detail "-> '$destBase', but rclone check could not confirm it after $maxAttempts attempt(s). Treat as UNCONFIRMED, not safe."
        }
        else {
            $anyUnrecovered = $true
            Write-RecoveryDisposition -File $c -Disposition 'NOT RECOVERED' `
                -Detail "Both recovery upload attempts failed to even copy it. $notRecoveredDetail"
        }
    }

    return [pscustomobject]@{ AnyUnrecovered = $anyUnrecovered }
}

function Invoke-TopazIncrementalUpload {
    <#
    .SYNOPSIS
        Best-effort upload + independent verification of ONE specific
        OutputDir file the watchdog's poll loop has already confirmed
        ELIGIBLE (Resolve-IncrementalUploadEligibility in Watchdog.ps1).
        CORRECTION 3 (2026-07-28 operator instruction): upload each render AS
        IT FINISHES, not only after the whole queue drains.
    .DESCRIPTION
        REUSES THE SAME rclone copy + check PLUMBING AS THE OTHER TWO UPLOAD
        PATHS in this file (Invoke-TopazRenderUpload, Invoke-TopazRecoveryUpload),
        but uses literal file-to-file `copyto` / `check` arguments rather than
        a glob-style `--include`. Source/destination are OutputDir ->
        UploadTarget -- the SAME pair the final Stop-Sequence.ps1 sweep uses
        (unlike Invoke-TopazRecoveryUpload's distinct ".../recovered"
        destination for files found OUTSIDE OutputDir) -- so that when the
        final sweep re-runs `rclone copy` over the whole of OutputDir at stop
        time, it sees this file already present and correctly sized at the
        SAME destination path and skips re-transferring it. That is what
        makes the final sweep "cost almost nothing" once this has already run.

        CALLED FROM INSIDE THE POLL LOOP -- THE MOST SAFETY-CRITICAL LOOP IN
        THE PROJECT. This function must never throw and must never block
        longer than its own bounded rclone calls: a failed incremental upload
        is NOT fatal, is logged, and is left for a later poll (or the final
        Stop-Sequence.ps1 sweep) to retry -- the caller (Invoke-TopazIncremental
        UploadPoll in Watchdog.ps1) must treat $false purely as "leave this
        file unmarked", never as a reason to stop polling or to escalate.

        THE BLIND WINDOW THIS CREATES IS DELIBERATE AND ACCEPTED, NOT AN
        OVERSIGHT. rclone runs SYNCHRONOUSLY on the watchdog's single polling
        thread, bounded by UploadTimeoutSec via Invoke-TopazAwsCli's own
        WaitForExit timeout (the SAME bound the final sweep uses -- this is
        "the existing rclone timeout plumbing" the fix was scoped to reuse,
        not a new, smaller number invented for this path). At the measured
        ~55-65 MiB/s on this box a 2.3 GB file takes ~1-2 minutes; both
        DebounceSec (300s) and StallSec (1800s) have enormous margin over
        that, and the upload only ever starts the instant a file looks
        finished -- exactly when a brief blind window costs the least, since
        nothing new can finish DURING it that the next poll would not also
        catch. Restructuring this into a background job/runspace was
        deliberately rejected: the added concurrency-control complexity in
        this specific loop is not worth it for a window this small and this
        well covered by DebounceSec/StallSec's own margins.

        Uses the SAME single-retry policy as the other two upload paths
        (Resolve-UploadRetryDecision, 2 attempts total, one retry after
        UploadRetryDelaySec) -- not a bespoke retry count for this path.
    .PARAMETER Config
        Get-TopazAutoStopConfig object.
    .PARAMETER File
        A single System.IO.FileInfo (from OutputDir) already confirmed
        eligible by the caller.
    .OUTPUTS
        [bool] $true only if copy AND check both succeeded within 2 attempts.
        $false on anything else (missing rclone/config/target, a copy
        failure, or a check failure) -- the caller must treat $false as
        "try again on a later poll", never as fatal.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$File
    )

    $cfg = $Config

    if (-not (Test-Path -LiteralPath $cfg.RclonePath) -or -not (Test-Path -LiteralPath $cfg.RcloneConfigPath) `
        -or [string]::IsNullOrWhiteSpace($cfg.UploadTarget)) {
        Write-TopazLog -Component 'watchdog' -Level 'WARN' `
            -Message "Incremental upload SKIPPED for '$($File.FullName)': rclone ('$($cfg.RclonePath)'), its config, or UploadTarget is not available. Will retry on a later poll or at the final stop-sequence sweep."
        return $false
    }

    # Path relative to OutputDir (not the volume root -- contrast
    # Invoke-TopazRecoveryUpload, whose candidates can live anywhere under the
    # root). copyto/check receive this as a literal destination file path, not
    # a --include filter: rclone filters are glob patterns, so a legitimate
    # output name containing '[', '*', or '?' could otherwise select a different
    # file and still get marked as uploaded.
    $outputRoot = $cfg.OutputDir.TrimEnd('\')
    $rel = $File.FullName.Substring($outputRoot.Length).TrimStart('\').Replace('\', '/')
    $destination = "$($cfg.UploadTarget.TrimEnd('/'))/$rel"

    $common = Build-RcloneLogFileArgs -LogDir $cfg.LogDir `
        -Base @('--config', $cfg.RcloneConfigPath, '--log-level', 'INFO')
    $tuning = @('--transfers', '4', '--drive-chunk-size', '128M', '--retries', '3', '--low-level-retries', '10', '--stats', '1m')

    $copyArgs  = @('copyto', $File.FullName, $destination) + $common + $tuning
    $checkArgs = @('check', $File.FullName, $destination) + $common + @('--one-way')

    Write-TopazLog -Component 'watchdog' -Level 'INFO' `
        -Message "Incremental upload: '$($File.FullName)' ($($File.Length) bytes) looks finished (unlocked + size-stable for $($cfg.UploadStableSec)s) -- uploading now instead of waiting for the whole queue to complete (CORRECTION 3)."

    $maxAttempts = 2
    $copied      = $false
    $verified    = $false

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $copied = Invoke-TopazAwsCli -FileName $cfg.RclonePath -Arguments $copyArgs `
            -TimeoutSec $cfg.UploadTimeoutSec -Component 'watchdog' `
            -SuccessMessage "Incremental upload attempt $attempt of ${maxAttempts}: rclone copy of '$($File.Name)' completed." `
            -FailureVerb "Incremental upload attempt $attempt of $maxAttempts (rclone copy) for '$($File.Name)'" `
            -FailureContext "target=$($cfg.UploadTarget)."

        $verified = $false
        if ($copied) {
            $verified = Invoke-TopazAwsCli -FileName $cfg.RclonePath -Arguments $checkArgs `
                -TimeoutSec $cfg.UploadTimeoutSec -Component 'watchdog' `
                -SuccessMessage "Incremental upload attempt $attempt of ${maxAttempts}: rclone check VERIFIED '$($File.Name)'." `
                -FailureVerb "Incremental upload attempt $attempt of $maxAttempts (rclone check) for '$($File.Name)'" `
                -FailureContext "target=$($cfg.UploadTarget)."
        }

        if ($copied -and $verified) { break }

        if (Resolve-UploadRetryDecision -AttemptNumber $attempt -MaxAttempts $maxAttempts -Succeeded $false) {
            Write-TopazLog -Component 'watchdog' -Level 'WARN' `
                -Message "Incremental upload attempt $attempt of $maxAttempts failed for '$($File.Name)' (copied=$copied verified=$verified). Retrying once more in $($cfg.UploadRetryDelaySec)s."
            Start-Sleep -Seconds $cfg.UploadRetryDelaySec
        }
    }

    if ($copied -and $verified) {
        Write-TopazLog -Component 'watchdog' -Level 'INFO' `
            -Message "Incremental upload verified: '$($File.FullName)' ($($File.Length) bytes) safely in '$($cfg.UploadTarget)'. Marked as already-uploaded for this session; the final Stop-Sequence sweep will see it already present and skip it."
        return $true
    }

    Write-TopazLog -Component 'watchdog' -Level 'WARN' `
        -Message "Incremental upload FAILED for '$($File.FullName)' after $maxAttempts attempt(s) (copied=$copied verified=$verified). NOT fatal -- left unmarked so a later poll or the final Stop-Sequence sweep retries it."
    return $false
}

function Invoke-TopazOutputAnomalyHandling {
    <#
    .SYNOPSIS
        Runs the misplaced-output recovery scan on EVERY reason='completed'
        stop, REGARDLESS of whether OutputDir itself has any files: scan for
        a recent, unlocked candidate elsewhere on the OutputDir volume,
        best-effort recover it if found, capture Topaz's own forensics on any
        anomaly, and log an unambiguous, greppable record of which (if any)
        of the two error classes occurred. 'stalled' / 'maxlifetime' are
        always a no-op here (see .DESCRIPTION).
    .DESCRIPTION
        RENAMED from Invoke-TopazEmptyOutputDirHandling, and no longer called
        only from Invoke-TopazRenderUpload's empty-OutputDir branch
        (CORRECTION 1, 2026-07-28). The old design ran this ONLY when
        OutputDir was empty -- which is exactly the hole that would let a
        SECOND misplaced deliverable hide behind a correctly-placed FIRST one
        already sitting in OutputDir. See Resolve-OutputAnomalyClass's own
        comment for the live counter-example that made this change necessary
        the same day the original fix shipped.

        ALWAYS RETURNS $true, AND NEVER THROWS. Per the operator's explicit,
        verbatim instruction (see Stop-Sequence.ps1's own comment for the full
        quote), no outcome of this scan may ever refuse the stop -- this
        function's entire job is best-effort recovery plus an unambiguous
        record, never a gate. Contrast Invoke-TopazRenderUpload's own
        retry-then-refuse path for the case where OutputDir's OWN upload
        fails twice: that asymmetry is deliberate and operator-chosen, not an
        inconsistency (see Invoke-TopazRecoveryUpload's own comment on it).
        The scan/recovery/forensic work below is wrapped in a single top-level
        try/catch for exactly the same reason Invoke-TopazForensicCapture
        wraps its own body: an UNEXPECTED exception here (a helper misbehaving
        in a way its own defences did not anticipate) must degrade to a
        logged WARN and a $true return, never propagate up through
        Invoke-TopazRenderUpload into Stop-Sequence.ps1 and turn a
        best-effort forensic aid into the reason a stop never happens at all
        -- which would be a WORSE outcome than the anomaly it exists to
        merely record.
    .PARAMETER Config
        Get-TopazAutoStopConfig object.
    .PARAMETER Reason
        'completed' | 'stalled' | 'maxlifetime'.
    .PARAMETER OutputDirHasFiles
        Whether OutputDir itself currently has at least one file. Purely an
        input to Resolve-OutputAnomalyClass now -- it does NOT gate whether
        this function runs its scan (that gating is on Reason alone; see
        CORRECTION 1).
    .OUTPUTS
        [bool] always $true.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][ValidateSet('completed', 'stalled', 'maxlifetime')][string]$Reason,
        [Parameter(Mandatory)][bool]$OutputDirHasFiles
    )

    $cfg = $Config

    if ($Reason -ne 'completed') {
        # 'stalled'/'maxlifetime' carry none of the "a real render definitely
        # ran" guarantee ArmSec gives 'completed' (see Resolve-OutputAnomalyClass's
        # own comment) -- a render may simply not have produced a deliverable
        # YET. Unchanged original behaviour: skip the scan entirely.
        Write-TopazLog -Component 'stop' -Level 'INFO' `
            -Message "Skipping the misplaced-output recovery scan (reason=$Reason, not 'completed'; OutputDirHasFiles=$OutputDirHasFiles)."
        return $true
    }

    $root = Get-TopazWindowsPathRoot -Path $cfg.OutputDir
    Write-TopazLog -Component 'stop' -Level 'INFO' `
        -Message "Reason='completed': scanning '$root' for recent render file(s) OUTSIDE OutputDir '$($cfg.OutputDir)' (OutputDirHasFiles=$OutputDirHasFiles) before this stop erases the volume. This scan runs EVERY completed stop now, not only when OutputDir is empty -- see CORRECTION 1 in this file's own MISPLACED-OUTPUT ANOMALY comment."

    try {
        $modifiedAfter = (Get-Date).AddMinutes(-$cfg.RecoveryMaxAgeMin)

        $scan = Find-RenderRecoveryCandidates -OutputDir $cfg.OutputDir -Extensions $cfg.RenderFileExtensions `
            -ModifiedAfter $modifiedAfter `
            -MaxFiles $cfg.RecoveryScanMaxFiles -MaxDepth $cfg.RecoveryScanMaxDepth -MaxSeconds $cfg.RecoveryScanTimeoutSec

        if ($scan.ScanFailed) {
            Write-TopazLog -Component 'stop' -Level 'WARN' `
                -Message "RECOVERY SCAN FAILED: the best-effort volume scan itself could not run/complete. This is NOT the same fact as 'the scan completed and found nothing' -- treat the volume as UNEXAMINED, not confirmed clear."
        }
        if ($scan.Truncated) {
            Write-TopazLog -Component 'stop' -Level 'WARN' `
                -Message "RECOVERY SCAN TRUNCATED: the file-count/time/depth bound was reached before the whole volume was examined (cap=$($cfg.RecoveryScanMaxFiles) files, $($cfg.RecoveryScanTimeoutSec)s, depth=$($cfg.RecoveryScanMaxDepth)). Additional candidates may exist beyond what is logged below -- this is NOT proof the volume holds nothing else."
        }

        # Log EVERY group the scan saw, distinctly -- not just whichever group
        # ends up deciding the error class below (CORRECTION 2: "the operator must
        # be able to see everything the scan saw and why each file was or was not
        # acted on"). ExcludedByAge and SkippedInProgress are logged here,
        # unconditionally, regardless of which branch runs next.
        foreach ($f in $scan.ExcludedByAge) {
            Write-TopazLog -Component 'stop' -Level 'INFO' `
                -Message "RECOVERY SCAN -- EXCLUDED BY AGE: '$($f.FullName)', $($f.Length) bytes, last write $($f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss.fff')) (older than RecoveryMaxAgeMin=$($cfg.RecoveryMaxAgeMin) min). Matched a render extension but treated as pre-existing (e.g. source footage), not a recovery candidate."
        }
        foreach ($f in $scan.SkippedInProgress) {
            Write-TopazLog -Component 'stop' -Level 'INFO' `
                -Message "RECOVERY SCAN -- SKIPPED, IN PROGRESS: '$($f.FullName)', $($f.Length) bytes as of this read, last write $($f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss.fff')). Recent and extension-matched, but still LOCKED (a writer holds it open) -- treated as Topaz's normal live intermediate, not a recovery candidate, and not allowed to decide the error class."
        }

        $decision = Resolve-OutputAnomalyClass -Reason $Reason -OutputDirHasFiles $OutputDirHasFiles `
            -CandidatesFound ($scan.Candidates.Count -gt 0)

        if ($decision -eq 'ErrorClassA') {
            # Best-effort forensic capture from Topaz's own session log -- only on
            # an actual anomaly (see Invoke-TopazForensicCapture's own comment:
            # that is what made the 2026-07-28 incident diagnosable at all). Not
            # run on 'Normal', since that path now runs on every single completed
            # stop and forensic capture is not free (bounded, but not zero-cost).
            Invoke-TopazForensicCapture -Config $cfg

            Write-TopazLog -Component 'stop' -Level 'ERROR' `
                -Message "RENDER-OUTSIDE-OUTPUTDIR: found $($scan.Candidates.Count) candidate render file(s) OUTSIDE OutputDir on the same volume (OutputDirHasFiles=$OutputDirHasFiles -- this can be true or false; a misplaced SECOND file is just as real a loss as a first one, see CORRECTION 1). Attempting best-effort recovery upload; the instance WILL STOP after this regardless of whether the recovery succeeds (operator-chosen behaviour -- see Stop-Sequence.ps1)."

            foreach ($c in $scan.Candidates) {
                Write-TopazLog -Component 'stop' -Level 'ERROR' `
                    -Message "RENDER-OUTSIDE-OUTPUTDIR candidate: '$($c.FullName)', $($c.Length) bytes, last write $($c.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss.fff'))."
            }

            # Invoke-TopazRecoveryUpload is itself defensively written (guard
            # clauses instead of throwing on a missing rclone/config/target),
            # but this call is still inside the OUTER try -- see this
            # function's own .DESCRIPTION on why an unanticipated exception
            # ANYWHERE in this block must never escape.
            [void] (Invoke-TopazRecoveryUpload -Config $cfg -Candidates $scan.Candidates)

            Write-TopazLog -Component 'stop' -Level 'INFO' `
                -Message "RENDER-OUTSIDE-OUTPUTDIR handling complete (see RECOVERY DISPOSITION line(s) above for the outcome per file). Proceeding to stop."
        }
        elseif ($decision -eq 'ErrorClassB') {
            Invoke-TopazForensicCapture -Config $cfg

            Write-TopazLog -Component 'stop' -Level 'ERROR' `
                -Message "RENDER-PRODUCED-NO-OUTPUT: reason='completed' but OutputDir is empty and no candidate render file was found anywhere on the OutputDir volume (scanFailed=$($scan.ScanFailed), truncated=$($scan.Truncated)). This is the signature of a render that FAILED OUTRIGHT without ever writing a deliverable (cf. the pnat-1 export in the 2026-07-28 incident, which died and was never retried). Proceeding to stop."
        }
        else {
            # 'Normal': the ordinary, healthy case -- OutputDir has its own
            # file(s) (or genuinely nothing was ever expected outside it either
            # way) and nothing anomalous was found elsewhere on the volume.
            Write-TopazLog -Component 'stop' -Level 'INFO' `
                -Message "RECOVERY SCAN: no misplaced render file(s) found outside OutputDir (OutputDirHasFiles=$OutputDirHasFiles, excludedByAge=$($scan.ExcludedByAge.Count), skippedInProgress=$($scan.SkippedInProgress.Count)). Nothing anomalous."
        }
    }
    catch {
        # Best-effort, exactly like Invoke-TopazForensicCapture's own body:
        # an UNANTICIPATED failure here (as opposed to the expected, already-
        # handled anomalies above) must never propagate. Propagating would
        # turn a forensic/recovery aid into an unhandled exception inside
        # Invoke-TopazRenderUpload, which Stop-Sequence.ps1 -- and, through
        # it, the watchdog's own handoff -- has no try/catch around. The
        # operator's instruction is to STILL STOP either way; a crash here
        # would be a worse failure than the anomaly this function exists to
        # merely record.
        Write-TopazLog -Component 'stop' -Level 'WARN' `
            -Message "Misplaced-output recovery scan FAILED UNEXPECTEDLY (best-effort, ignored): $($_.Exception.Message). Proceeding to stop regardless."
    }

    return $true
}

function Invoke-TopazRenderUpload {
    <#
    .SYNOPSIS
        Uploads everything in OutputDir to UploadTarget via rclone, VERIFIES
        it landed, and returns $true only if both steps succeeded.
    .DESCRIPTION
        This is the function the ephemeral interlock in Stop-Sequence.ps1
        depends on, so its return value carries real weight: $true is taken as
        permission to erase the scratch volume by stopping the instance.
        It must therefore be conservative -- ANY doubt returns $false, and a
        false negative merely costs some instance uptime while a false
        positive destroys the render.

        rclone drives the Google Drive REST API directly (no browser, no
        desktop sync client), uses resumable chunked uploads so a network blip
        resumes rather than restarting a 52 GB transfer, and validates Drive's
        returned MD5 against the local file so a silently corrupted upload
        fails loudly instead of passing.

        Two steps, deliberately:
          1. `rclone copy`  - transfers, and fails nonzero on any error.
          2. `rclone check --one-way` - independently re-compares source
             against destination afterwards. Belt and braces: step 1 already
             verifies hashes, but the cost of being wrong here is a lost
             multi-hour render, which is worth one extra pass.

        Both steps get ONE RETRY (2 attempts total, via the pure
        Resolve-UploadRetryDecision) if either fails -- a transient Drive-side
        blip used to refuse the stop on the very first failure, costing
        instance uptime for something a retry would often clear. See that
        function's own comment for why the attempt cap is a literal constant
        here, not a Config.ps1 knob.

        `copy` (not `move` or `sync`) is intentional: the scratch volume is
        wiped by the stop anyway, so spending instance time deleting the
        source afterwards would be pure waste. It also means re-running this
        after a partial failure is cheap -- rclone skips files already present
        at the destination.

        NEITHER AN EMPTY NOR A NON-EMPTY OutputDir IS UNCONDITIONALLY "SAFE TO
        PROCEED" ANYMORE -- see Resolve-OutputAnomalyClass /
        Invoke-TopazOutputAnomalyHandling, which this function now calls
        UNCONDITIONALLY (CORRECTION 1, 2026-07-28: the misplaced-output scan
        must run whether or not OutputDir has content, not only when it is
        empty). That call always returns $true (the operator's explicit
        instruction: never refuse to stop over a misplaced or missing
        render), so it cannot ITSELF trigger Stop-Sequence.ps1's ephemeral
        refusal below -- only OutputDir's OWN upload failing twice can.
    .PARAMETER Config
        The Get-TopazAutoStopConfig object.
    .PARAMETER Reason
        'completed' | 'stalled' | 'maxlifetime' -- also decides whether the
        misplaced-output scan runs at all (see Resolve-OutputAnomalyClass).
    .OUTPUTS
        [bool] $true if the upload transferred AND verified (within 2
        attempts), OR if OutputDir was empty (always -- see above). $false
        only when OutputDir has files and BOTH upload attempts failed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [string]$Reason = 'completed'
    )

    $cfg = $Config

    if (-not (Test-Path -LiteralPath $cfg.RclonePath)) {
        Write-TopazLog -Component 'stop' -Level 'ERROR' `
            -Message "rclone not found at '$($cfg.RclonePath)'. Cannot upload."
        return $false
    }

    if (-not (Test-Path -LiteralPath $cfg.RcloneConfigPath)) {
        Write-TopazLog -Component 'stop' -Level 'ERROR' `
            -Message "rclone config not found at '$($cfg.RcloneConfigPath)'. The Google Drive remote has not been authorised -- run Set-GoogleDriveAuth.ps1. Cannot upload."
        return $false
    }

    if (-not (Test-Path -LiteralPath $cfg.OutputDir)) {
        # On an ephemeral OutputDir this usually means the scratch drive never
        # got provisioned this boot, which is itself a fault worth blocking on:
        # if the directory is missing, renders went somewhere unexpected.
        Write-TopazLog -Component 'stop' -Level 'ERROR' `
            -Message "OutputDir '$($cfg.OutputDir)' does not exist. Cannot upload (did Initialize-ScratchDisk.ps1 run at boot?)."
        return $false
    }

    try {
        $files = @(Get-TopazOutputFiles -Path $cfg.OutputDir)
    }
    catch {
        Write-TopazLog -Component 'stop' -Level 'ERROR' `
            -Message "Could not enumerate every file under OutputDir '$($cfg.OutputDir)': $($_.Exception.Message). Refusing to treat a partial listing as uploadable."
        return $false
    }
    $outputDirHasFiles = $files.Count -gt 0

    if (-not $outputDirHasFiles) {
        Write-TopazLog -Component 'stop' -Level 'INFO' `
            -Message "OutputDir '$($cfg.OutputDir)' is empty; nothing to upload from OutputDir itself (reason=$Reason)."

        # An empty OutputDir is NOT unconditionally benign: see
        # Resolve-OutputAnomalyClass's own comment for why reason='completed'
        # + empty (with nothing found elsewhere either) is a contradiction
        # worth treating as an anomaly (the 2026-07-28 incident) rather than
        # "safe to proceed". Invoke-TopazOutputAnomalyHandling always returns
        # $true -- per the operator's explicit instruction this case never
        # refuses the stop -- so this call cannot newly trigger
        # Stop-Sequence.ps1's ephemeral-upload refusal below.
        [void] (Invoke-TopazOutputAnomalyHandling -Config $cfg -Reason $Reason -OutputDirHasFiles $false)
        return $true
    }

    # PowerShell's 1GB literal is 2^30, so $totalBytes/1GB yields GiB, not GB.
    # These lines used to label it "GB", which disagreed with rclone's own
    # "9.836 GiB" for the SAME transfer by ~7% and invited the reader to think
    # two different sizes were in play. The raw byte count is logged alongside
    # it because that is the only figure that can be compared EXACTLY against
    # rclone and against the destination listing when auditing whether a render
    # arrived intact.
    $totalBytes = ($files | Measure-Object -Property Length -Sum).Sum
    Write-TopazLog -Component 'stop' -Level 'INFO' `
        -Message "Uploading $($files.Count) file(s), $([math]::Round($totalBytes/1GB,2)) GiB ($totalBytes bytes), from '$($cfg.OutputDir)' to '$($cfg.UploadTarget)' (reason=$Reason). This MUST finish before the instance may stop."

    # --drive-chunk-size trades memory for throughput on large files; 4
    # transfers x 128M is ~512 MB of buffers, trivial on a 64 GB box and much
    # faster than the 8 MiB default for multi-GB renders.
    $common = Build-RcloneLogFileArgs -LogDir $cfg.LogDir -Base @(
        '--config', $cfg.RcloneConfigPath,
        '--log-level', 'INFO'
    )

    $copyArgs = @('copy', $cfg.OutputDir, $cfg.UploadTarget) + $common + @(
        '--transfers', '4',
        '--drive-chunk-size', '128M',
        '--retries', '3',
        '--low-level-retries', '10',
        '--stats', '1m'
    )

    # Independent verification pass. --one-way so pre-existing extra files at
    # the destination (previous sessions' renders) are not treated as errors.
    $checkArgs = @('check', $cfg.OutputDir, $cfg.UploadTarget) + $common + @('--one-way')

    # THE SINGLE UPLOAD RETRY. Previously a single copy+check failure returned
    # $false straight away, which (with OutputIsEphemeral) refused the stop on
    # the FIRST blip -- costing instance uptime for something a plain retry
    # would often fix (a dropped connection mid-chunk, transient Drive-side
    # rate limiting). $maxAttempts is a literal constant, not a Config.ps1
    # knob -- see Resolve-UploadRetryDecision's own comment on why that bound
    # is deliberately not operator-tunable. Each attempt redoes BOTH copy and
    # check (a partial transfer is exactly the case a retry should fix, and
    # re-running `check` alone against a partial copy would just re-confirm
    # the same failure).
    $maxAttempts = 2
    $copied      = $false
    $verified    = $false

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        Write-TopazLog -Component 'stop' -Level 'INFO' `
            -Message "Upload attempt $attempt of $maxAttempts (rclone copy)."

        $copied = Invoke-TopazAwsCli -FileName $cfg.RclonePath -Arguments $copyArgs `
            -TimeoutSec $cfg.UploadTimeoutSec `
            -Component 'stop' `
            -SuccessMessage "Upload attempt $attempt of ${maxAttempts}: rclone copy completed. See '$rcloneLog' for transfer detail." `
            -FailureVerb "Upload attempt $attempt of $maxAttempts (rclone copy)" `
            -FailureContext "target=$($cfg.UploadTarget)."

        $verified = $false
        if ($copied) {
            Write-TopazLog -Component 'stop' -Level 'INFO' `
                -Message "Upload attempt $attempt of $maxAttempts (rclone check)."

            $verified = Invoke-TopazAwsCli -FileName $cfg.RclonePath -Arguments $checkArgs `
                -TimeoutSec $cfg.UploadTimeoutSec `
                -Component 'stop' `
                -SuccessMessage "Upload attempt $attempt of ${maxAttempts}: rclone check VERIFIED every file in '$($cfg.OutputDir)' is present and intact at '$($cfg.UploadTarget)'." `
                -FailureVerb "Upload attempt $attempt of $maxAttempts (rclone check)" `
                -FailureContext "target=$($cfg.UploadTarget)."
        }

        if ($copied -and $verified) { break }

        if (Resolve-UploadRetryDecision -AttemptNumber $attempt -MaxAttempts $maxAttempts -Succeeded $false) {
            Write-TopazLog -Component 'stop' -Level 'WARN' `
                -Message "Upload attempt $attempt of $maxAttempts FAILED (copied=$copied verified=$verified). Retrying once more (attempt $($attempt + 1) of $maxAttempts) in $($cfg.UploadRetryDelaySec)s."
            Start-Sleep -Seconds $cfg.UploadRetryDelaySec
        }
        else {
            Write-TopazLog -Component 'stop' -Level 'ERROR' `
                -Message "Upload attempt $attempt of $maxAttempts FAILED (copied=$copied verified=$verified). Both attempts (1 initial + 1 retry) exhausted; the instance will NOT be stopped while renders remain unuploaded on ephemeral storage."
        }
    }

    if (-not ($copied -and $verified)) { return $false }

    Write-TopazLog -Component 'stop' -Level 'INFO' `
        -Message "Upload verified: $($files.Count) file(s), $([math]::Round($totalBytes/1GB,2)) GiB ($totalBytes bytes) now safely in '$($cfg.UploadTarget)'. Safe to stop."

    # CORRECTION 1 (2026-07-28): the misplaced-output scan runs here too, not
    # only on the empty-OutputDir branch above -- OutputDir having its OWN
    # correctly-uploaded file(s) says nothing about whether a SECOND,
    # misplaced deliverable is ALSO sitting outside it (see
    # Resolve-OutputAnomalyClass's own comment for the live counter-example).
    # Always returns $true; cannot turn this success back into a refusal.
    [void] (Invoke-TopazOutputAnomalyHandling -Config $cfg -Reason $Reason -OutputDirHasFiles $true)

    return $true
}

function Test-TopazOutputManifestUnchanged {
    <#
    .SYNOPSIS
        Pure: verifies file identity snapshots have the same paths, sizes, and write times.
    .DESCRIPTION
        The completed-stop safety gate takes a strict snapshot before its final
        rclone check and another after it. A filename alone cannot prove the
        checked bytes are still current: an in-place rewrite can retain the
        same path, and a same-size rewrite can retain the same length. The
        LastWriteTimeUtc comparison closes both cases without hashing the
        source a second time.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Before,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$After
    )

    try {
        if ($Before.Count -ne $After.Count) { return $false }

        $beforeByPath = @{}
        foreach ($file in $Before) {
            if ($null -eq $file -or [string]::IsNullOrWhiteSpace($file.FullName) -or
                $null -eq $file.Length -or $null -eq $file.LastWriteTimeUtc -or
                $beforeByPath.ContainsKey($file.FullName)) {
                return $false
            }
            $beforeByPath[$file.FullName] = "$([int64]$file.Length)|$(([datetime]$file.LastWriteTimeUtc).Ticks)"
        }

        foreach ($file in $After) {
            if ($null -eq $file -or -not $beforeByPath.ContainsKey($file.FullName) -or
                $null -eq $file.Length -or $null -eq $file.LastWriteTimeUtc) {
                return $false
            }
            $identity = "$([int64]$file.Length)|$(([datetime]$file.LastWriteTimeUtc).Ticks)"
            if ($beforeByPath[$file.FullName] -ne $identity) { return $false }
        }
        return $true
    }
    catch {
        # A malformed manifest must never be interpreted as unchanged.
        return $false
    }
}

function Test-TopazCompletedStopSafetyGate {
    <#
    .SYNOPSIS
        Final fail-closed interlock immediately before a completed stop.
    .DESCRIPTION
        A long final upload can finish after the watchdog's handoff snapshot,
        while an operator queues another render or a new file appears. This
        gate checks the conservative, stateless worker signal and (for
        ephemeral output) verifies every file is unlocked before one final
        rclone `check --one-way`. It repeats both checks after rclone finishes
        and compares strict pre/post manifests, because that check can itself
        run for hours. It never copies: a changed or newly created source file
        must refuse the stop and return control to the watchdog, rather than
        extending this last race window with another multi-hour transfer.

        The caller runs this only for Reason='completed'. Stalled and timed
        hard-stop paths have deliberately different semantics and must retain
        their existing bounded stop behavior.
    .PARAMETER Config
        Get-TopazAutoStopConfig object.
    .OUTPUTS
        [bool] $true only when the final state is safe to proceed. A worker
        query failure is deliberately $false (unknown is not idle).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)

    $cfg = $Config
    function Test-WorkerIdle {
        param([Parameter(Mandatory)][string]$Phase)
        $workerPresent = Test-RenderWorkerPresent -WorkerNamesLike $cfg.WorkerNamesLike
        if ($null -eq $workerPresent) {
            Write-TopazLog -Component 'stop' -Level 'ERROR' `
                -Message "FINAL COMPLETION SAFETY GATE REFUSED ($Phase): encoder-worker presence could not be queried. Unknown is not safe to stop; watchdog will re-arm."
            return $false
        }
        if ($workerPresent) {
            Write-TopazLog -Component 'stop' -Level 'ERROR' `
                -Message "FINAL COMPLETION SAFETY GATE REFUSED ($Phase): an encoder worker is present. A new or resumed render may be active; watchdog will re-arm."
            return $false
        }
        return $true
    }

    function Get-UnlockedOutputSnapshot {
        param([Parameter(Mandatory)][string]$Phase)
        try {
            $files = @(Get-TopazOutputFiles -Path $cfg.OutputDir)
        }
        catch {
            Write-TopazLog -Component 'stop' -Level 'ERROR' `
                -Message "FINAL COMPLETION SAFETY GATE REFUSED ($Phase): could not enumerate every OutputDir file: $($_.Exception.Message)"
            return [pscustomobject]@{ Safe = $false; Files = @() }
        }

        $locked = @($files | Where-Object { -not (Test-FileUnlocked -Path $_.FullName) })
        if ($locked.Count -gt 0) {
            Write-TopazLog -Component 'stop' -Level 'ERROR' `
                -Message "FINAL COMPLETION SAFETY GATE REFUSED ($Phase): $($locked.Count) OutputDir file(s) are still locked: $($locked.FullName -join ', ')."
            return [pscustomobject]@{ Safe = $false; Files = @() }
        }
        return [pscustomobject]@{ Safe = $true; Files = $files }
    }

    if (-not (Test-WorkerIdle -Phase 'before final rclone check')) {
        return $false
    }

    $beforeSnapshot = $null
    if ($cfg.OutputIsEphemeral) {
        $beforeSnapshot = Get-UnlockedOutputSnapshot -Phase 'before final rclone check'
        if (-not $beforeSnapshot.Safe) { return $false }
    }

    if ([string]::IsNullOrWhiteSpace($cfg.UploadTarget)) {
        if ($cfg.OutputIsEphemeral) {
            Write-TopazLog -Component 'stop' -Level 'ERROR' `
                -Message 'FINAL COMPLETION SAFETY GATE REFUSED: OutputDir is ephemeral but no UploadTarget exists for a final remote consistency check.'
            return $false
        }
        # Persistent local output is an allowed no-upload configuration. The
        # worker gate above still protects against a live render, but there is
        # no remote destination against which a check could be meaningful.
        Write-TopazLog -Component 'stop' -Level 'INFO' `
            -Message 'FINAL COMPLETION SAFETY GATE: no UploadTarget is configured; remote consistency check is not applicable.'
        return $true
    }

    if (-not (Test-Path -LiteralPath $cfg.RclonePath) -or -not (Test-Path -LiteralPath $cfg.RcloneConfigPath)) {
        Write-TopazLog -Component 'stop' -Level 'ERROR' `
            -Message 'FINAL COMPLETION SAFETY GATE REFUSED: rclone or its config is unavailable for the required final verification.'
        return $false
    }

    $common = Build-RcloneLogFileArgs -LogDir $cfg.LogDir -Base @(
        '--config', $cfg.RcloneConfigPath,
        '--log-level', 'INFO'
    )
    $checkArgs = @('check', $cfg.OutputDir, $cfg.UploadTarget) + $common + @('--one-way')

    $checkOk = [bool](Invoke-TopazAwsCli -FileName $cfg.RclonePath -Arguments $checkArgs `
        -TimeoutSec $cfg.UploadTimeoutSec -Component 'stop' `
        -SuccessMessage "FINAL COMPLETION SAFETY GATE: rclone check verified the current OutputDir against '$($cfg.UploadTarget)'." `
        -FailureVerb 'FINAL COMPLETION SAFETY GATE rclone check' `
        -FailureContext "source=$($cfg.OutputDir), target=$($cfg.UploadTarget); refusing to stop so watchdog can re-arm.")
    if (-not $checkOk) { return $false }

    if (-not (Test-WorkerIdle -Phase 'after final rclone check')) {
        return $false
    }

    if ($cfg.OutputIsEphemeral) {
        $afterSnapshot = Get-UnlockedOutputSnapshot -Phase 'after final rclone check'
        if (-not $afterSnapshot.Safe) { return $false }
        if (-not (Test-TopazOutputManifestUnchanged -Before $beforeSnapshot.Files -After $afterSnapshot.Files)) {
            Write-TopazLog -Component 'stop' -Level 'ERROR' `
                -Message 'FINAL COMPLETION SAFETY GATE REFUSED: OutputDir changed while the final rclone check ran. Watchdog will re-arm rather than stop with unchecked output.'
            return $false
        }
    }

    return $true
}

function Get-TopazStopNotification {
    <#
    .SYNOPSIS
        Pure: build the SNS subject + message for a given stop reason,
        reproducing Stop-Sequence.ps1's wording EXACTLY for both the DryRun
        and real-stop branches.
    .DESCRIPTION
        DryRun never powers off (Stop-Sequence.ps1's dry-run guard runs
        AFTER the notification is published), so its notification text must
        not claim the box is stopping -- that would be a false alarm to
        whoever is subscribed to the topic.
    .PARAMETER Reason
        'completed' or 'stalled'.
    .PARAMETER InstanceId
        The instance id to name in the text. Callers resolve any IMDS-failure
        fallback (e.g. a placeholder id) before calling this.
    .PARAMETER DryRun
        Whether the power-off is being suppressed.
    .OUTPUTS
        @{ Subject = <string>; Message = <string> }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Reason,
        [string]$InstanceId,
        [Parameter(Mandatory)][bool]$DryRun
    )

    if ($DryRun) {
        return @{
            Subject = "Topaz render $Reason - DRY RUN (no stop) - $InstanceId"
            Message = "Topaz watchdog decided '$Reason' on instance $InstanceId at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'). DryRun is enabled, so the power-off was suppressed and the instance is still running."
        }
    }

    return @{
        Subject = "Topaz render $Reason - stopping $InstanceId"
        Message = "Topaz render queue reported '$Reason' on instance $InstanceId at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'). The guest is powering off, which stops the EC2 instance."
    }
}
