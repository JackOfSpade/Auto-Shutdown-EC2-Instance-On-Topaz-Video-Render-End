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
        # DEFAULT IS 'WorkerOrGpu' here deliberately. The two signals fail in
        # different directions, and the asymmetry of the consequences decides
        # it: a false "idle" powers the box off MID-RENDER and destroys hours
        # of GPU time, while a false "busy" merely leaves the box up a little
        # longer (and the out-of-band CloudWatch idle alarm exists precisely
        # to catch that). Requiring BOTH signals to go quiet before calling a
        # queue complete is therefore the correct bias.
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

        # Bound (seconds) on how long the watchdog may log NOTHING while a
        # render is healthy and progressing. 0 disables heartbeats.
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
        # PHASE 4 - GPU METRIC (published by Push-GpuMetric.ps1)
        # ------------------------------------------------------------------

        # These two values are MIRRORED by control-plane/03-create-idle-alarm.sh
        # (METRIC_NAMESPACE/METRIC_NAME env overrides there). If you change
        # them here, re-run that script with matching overrides, or the idle
        # alarm silently keeps watching a dead metric.
        MetricNamespace  = 'TopazRender/GPU'
        MetricName       = 'GPUUtilization'

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

        # If set to an SNS topic ARN, Stop-Sequence.ps1 publishes a best-effort
        # "render complete / stalled" notification before stopping. Empty = skip.
        SnsTopicArn      = ''

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

        `copy` (not `move` or `sync`) is intentional: the scratch volume is
        wiped by the stop anyway, so spending instance time deleting the
        source afterwards would be pure waste. It also means re-running this
        after a partial failure is cheap -- rclone skips files already present
        at the destination.
    .PARAMETER Config
        The Get-TopazAutoStopConfig object.
    .PARAMETER Reason
        'completed' | 'stalled' | 'maxlifetime' -- logged for context only.
    .OUTPUTS
        [bool] $true only if the upload transferred AND verified.
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

    $files = @(Get-ChildItem -LiteralPath $cfg.OutputDir -Recurse -File -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) {
        Write-TopazLog -Component 'stop' -Level 'INFO' `
            -Message "OutputDir '$($cfg.OutputDir)' is empty; nothing to upload. Safe to proceed."
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

    $rcloneLog = Join-Path $cfg.LogDir 'rclone.log'

    # --drive-chunk-size trades memory for throughput on large files; 4
    # transfers x 128M is ~512 MB of buffers, trivial on a 64 GB box and much
    # faster than the 8 MiB default for multi-GB renders.
    $common = @(
        '--config', $cfg.RcloneConfigPath,
        '--log-file', $rcloneLog,
        '--log-level', 'INFO'
    )

    $copyArgs = @('copy', $cfg.OutputDir, $cfg.UploadTarget) + $common + @(
        '--transfers', '4',
        '--drive-chunk-size', '128M',
        '--retries', '3',
        '--low-level-retries', '10',
        '--stats', '1m'
    )

    $copied = Invoke-TopazAwsCli -FileName $cfg.RclonePath -Arguments $copyArgs `
        -TimeoutSec $cfg.UploadTimeoutSec `
        -Component 'stop' `
        -SuccessMessage "rclone copy completed. See '$rcloneLog' for transfer detail." `
        -FailureVerb 'rclone upload' `
        -FailureContext "target=$($cfg.UploadTarget). The instance will NOT be stopped while renders remain unuploaded on ephemeral storage."

    if (-not $copied) { return $false }

    # Independent verification pass. --one-way so pre-existing extra files at
    # the destination (previous sessions' renders) are not treated as errors.
    $checkArgs = @('check', $cfg.OutputDir, $cfg.UploadTarget) + $common + @('--one-way')

    $verified = Invoke-TopazAwsCli -FileName $cfg.RclonePath -Arguments $checkArgs `
        -TimeoutSec $cfg.UploadTimeoutSec `
        -Component 'stop' `
        -SuccessMessage "rclone check VERIFIED every file in '$($cfg.OutputDir)' is present and intact at '$($cfg.UploadTarget)'." `
        -FailureVerb 'rclone verify' `
        -FailureContext 'the upload could not be verified, so the renders are NOT safe to erase.'

    if (-not $verified) { return $false }

    Write-TopazLog -Component 'stop' -Level 'INFO' `
        -Message "Upload verified: $($files.Count) file(s), $([math]::Round($totalBytes/1GB,2)) GiB ($totalBytes bytes) now safely in '$($cfg.UploadTarget)'. Safe to stop."
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
