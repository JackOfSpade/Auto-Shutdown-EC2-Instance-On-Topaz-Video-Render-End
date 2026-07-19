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

function Get-TopazAutoStopConfig {
    [CmdletBinding()]
    param()

    $config = [pscustomobject]@{
        # ------------------------------------------------------------------
        # OPERATOR SETTINGS  (set these from your Phase 0 observations)
        # ------------------------------------------------------------------

        # Folder that Topaz writes finished exports into. The watchdog treats
        # "no growth here" (while a render is active) as a stall.
        OutputDir        = 'D:\Exports'

        # WMI/CIM LIKE pattern that matches the Topaz GUI process name.
        # Covers both 'Topaz Video.exe' and 'Topaz Video AI.exe' (rebrand-safe).
        TopazNameLike    = 'Topaz Video%'

        # WMI/CIM LIKE pattern that matches the encoder WORKER process Topaz
        # spawns per export job. Historically 'ffmpeg.exe'. Kept configurable
        # because the exact worker name is version-dependent; confirm it in
        # Phase 0. Use a LIKE pattern (e.g. 'ffmpeg%') if the name varies.
        WorkerNameLike   = 'ffmpeg.exe'

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
        # Every mode gracefully degrades: both the worker and GPU signals are
        # three-valued ($true/$false/$null, $null = "could not be read this
        # poll"). If a signal is $null, it simply stops contributing per
        # Resolve-RenderActive's truth table below; if NEITHER signal can be
        # trusted, the overall result is itself $null (unknown) and the
        # watchdog freezes its idle/stall bookkeeping for that poll rather
        # than guessing.
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

        # With a render no longer active for this long (and one having been
        # seen), the queue is considered complete. Inter-clip model-load lulls
        # typically run 45-90s; 120 clears that with margin so a mid-queue lull
        # is never misread as "done" (a false "complete" here stops the box
        # mid-queue), at the cost of only ~1 extra idle minute per session.
        DebounceSec      = 120

        # A render is active but the output folder has not grown for this long
        # => treat as a stall (broken job) and stop anyway.
        StallSec         = 900

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

        # If set to an SNS topic ARN, Stop-Sequence.ps1 publishes a best-effort
        # "render complete / stalled" notification before stopping. Empty = skip.
        SnsTopicArn      = ''

        # Safety switch: when $true, the watchdog + stop sequence log the
        # decision but DO NOT actually power the instance off. Flip to $false
        # once you have watched a couple of real jobs complete cleanly.
        DryRun           = $true

        # ------------------------------------------------------------------
        # SCHEDULED TASK NAMES (used by Register-ScheduledTasks.ps1)
        # ------------------------------------------------------------------

        WatchdogTaskName = 'TopazAutoStop-Watchdog'
        MetricTaskName   = 'TopazAutoStop-GpuMetric'
    }

    Assert-ValidCompletionSignal -Signal $config.CompletionSignal

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
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = "[$stamp] [$Level] $Message"

    switch ($Level) {
        'WARN'  { Write-Warning $Message }
        'ERROR' { Write-Error   $Message }
        default { Write-Output  $line }
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
        [string]$FailureContext = ''
    )

    $proc = $null
    try {
        $escapedArgs = $Arguments | ForEach-Object { ConvertTo-TopazCliArgument -Value $_ }

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = 'aws'
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
            Message = "Topaz watchdog decided '$Reason' on instance $InstanceId at $(Get-Date -Format 's'). DryRun is enabled, so the power-off was suppressed and the instance is still running."
        }
    }

    return @{
        Subject = "Topaz render $Reason - stopping $InstanceId"
        Message = "Topaz render queue reported '$Reason' on instance $InstanceId at $(Get-Date -Format 's'). The guest is powering off, which stops the EC2 instance."
    }
}
