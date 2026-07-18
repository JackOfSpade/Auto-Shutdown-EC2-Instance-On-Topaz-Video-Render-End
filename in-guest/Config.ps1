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

        # Fragment found in Topaz scratch/temporary files. Files whose name
        # contains this marker are ignored by the "outputs unlocked?" check,
        # because Topaz may leave them behind after a successful export.
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
        # Every mode gracefully degrades: if a GPU read fails, GPU stops
        # contributing and the worker signal decides that poll.
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
        # seen), the queue is considered complete. Raise this if Topaz's live
        # preview spawns transient workers, or if inter-clip model loads create
        # long lulls (45-90s is typical).
        DebounceSec      = 60

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
    #>
    [CmdletBinding()]
    param()

    try {
        $raw = & nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>&1
        if ($LASTEXITCODE -ne 0) { return $null }

        $vals = @($raw |
            ForEach-Object { "$_".Trim() } |
            Where-Object   { $_ -match '^\d+$' } |
            ForEach-Object { [int]$_ })

        if ($vals.Count -eq 0) { return $null }
        return ($vals | Measure-Object -Maximum).Maximum
    }
    catch {
        return $null
    }
}

function Resolve-RenderActive {
    <#
    .SYNOPSIS
        Pure decision: is a render "active" given the raw signals? No I/O, so it
        is fully unit-testable.
    .PARAMETER WorkerActive
        Whether an encoder worker process is currently present.
    .PARAMETER GpuUtil
        Highest GPU utilization (%), or $null if it could not be read (unknown).
    .PARAMETER Signal
        'WorkerOnly' | 'GpuOnly' | 'WorkerOrGpu'.
    .PARAMETER GpuBusyPercent
        GPU % at or above which the GPU counts as actively rendering.
    .DESCRIPTION
        Degrades gracefully: when the GPU value is $null (read failed) the GPU
        stops contributing and the worker signal decides - so a transient
        nvidia-smi failure can never be misread as "idle".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool]$WorkerActive,
        [AllowNull()]$GpuUtil,
        [Parameter(Mandatory)][ValidateSet('WorkerOnly', 'GpuOnly', 'WorkerOrGpu')][string]$Signal,
        [Parameter(Mandatory)][int]$GpuBusyPercent
    )

    $gpuReadOk = ($null -ne $GpuUtil)
    $gpuActive = ($gpuReadOk -and [int]$GpuUtil -ge $GpuBusyPercent)

    switch ($Signal) {
        'GpuOnly' {
            if ($gpuReadOk) { return $gpuActive } else { return $WorkerActive }
        }
        'WorkerOrGpu' {
            return ($WorkerActive -or $gpuActive)
        }
        default {
            # 'WorkerOnly'
            return $WorkerActive
        }
    }
}
