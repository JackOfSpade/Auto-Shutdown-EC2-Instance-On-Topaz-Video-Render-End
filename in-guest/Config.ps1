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

function Get-TopazAutoStopConfig {
    [CmdletBinding()]
    param()

    [pscustomobject]@{
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

        # ------------------------------------------------------------------
        # PATHS
        # ------------------------------------------------------------------

        InstallDir       = 'C:\topaz-autostop'
        LogDir           = 'C:\topaz-autostop\logs'

        # ------------------------------------------------------------------
        # PHASE 4 - GPU METRIC (published by Push-GpuMetric.ps1)
        # ------------------------------------------------------------------

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
    if (-not $result.Region) {
        try {
            $az = ("$(Invoke-RestMethod -Method Get `
                -Uri 'http://169.254.169.254/latest/meta-data/placement/availability-zone' `
                -Headers $headers -TimeoutSec 3 -ErrorAction Stop)").Trim()
            if ($az) { $result.Region = ($az -replace '[a-z]$', '') }
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
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$TempMarker
    )

    $pattern = [regex]::Escape($TempMarker) + '([._-]|$)'
    return [bool]($Name -match $pattern)
}
