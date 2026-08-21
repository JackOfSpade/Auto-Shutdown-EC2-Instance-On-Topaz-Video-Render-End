<#
.SYNOPSIS
    On-box preflight "doctor" for the Topaz auto-stop pipeline. Run this
    BEFORE arming automation (Register-ScheduledTasks.ps1 / DryRun=$false)
    and it prints a GO / NO-GO verdict.

.DESCRIPTION
    Dot-sources Config.ps1 and runs a fixed series of named, independent
    checks against the live box: PowerShell/OS version, elevation, config
    sanity (including whether OutputIsEphemeral agrees with the volume
    OutputDir actually lives on, whether the rclone upload path -- the hard
    precondition for ever stopping an ephemeral box -- is present and
    authorised, and whether the copy being validated matches the INSTALLED
    copy the scheduled tasks run), nvidia-smi, the Topaz GUI process,
    worker-process discovery (with
    parent/child ancestry classification -- reusing Watchdog.ps1's OWN
    Get-TopazPids/Get-TopazWorkers/Resolve-ProcessDescendants, dot-sourced
    read-only below, so this check exercises the EXACT attribution logic the
    real watchdog uses instead of a hand-rolled reimplementation that could
    silently drift from it), the AWS CLI, IMDS, a real CloudWatch
    PutMetricData permission probe, the instanceInitiatedShutdownBehavior of
    THIS instance, DryRun consistency (StopStrategy-aware: a StopStrategy of
    'Ec2ApiStop' alone never falls back to a guest shutdown, per
    Resolve-StopPlan in Config.ps1), and scheduled-task registration.

    Every check prints exactly one line in the form:
        [PASS] <name> - <detail>
        [WARN] <name> - <detail>
        [FAIL] <name> - <detail>

    A WARN means "not individually blocking, but look at this" (e.g. a
    dependency that is missing but only needed for an optional feature, or a
    permission probe that came back denied on a role this box's operator does
    not control from inside the guest). A FAIL means the specific thing this
    check is proving did NOT hold and must be fixed before arming the
    pipeline for real.

    This script is read-only except for two narrowly-scoped, self-reversing
    probes it must actually exercise to tell the truth:
      * a transient write-then-delete probe file under LogDir, to prove it is
        writable (this mirrors what Write-TopazLog itself already does on
        every real log line);
      * ONE real `aws cloudwatch put-metric-data` of value 0, metric name
        'PreflightCanary', into $cfg.MetricNamespace (check 9 below) -- this
        is the one operation described in the task as an intentional,
        real permission probe, not an accident.
    It never registers/unregisters a scheduled task, never touches Topaz or
    any of its files, and never powers off, stops, or terminates anything.
    Safe to run repeatedly, at any time, including while a render is active.
    (`rclone listremotes` in check 3b is read-only and purely local -- it
    parses the config file and makes no network call, uploads nothing, and
    deletes nothing.)

.NOTES
    Target : Windows PowerShell 5.1 on Windows Server (EC2 GPU instance).
    Run from an elevated PowerShell for a meaningful elevation check:
        .\Test-Deployment.ps1
    Exit code: 0 if no FAIL was recorded (GO, possibly with WARNs), 1 if any
    FAIL was recorded (NO-GO).
    Never uses the Topaz CLI. Never stops/restarts/terminates this instance.
#>

[CmdletBinding()]
param(
    # Test/import seam, mirroring Initialize-ScratchDisk.ps1's: dot-source this
    # file to get its pure helpers WITHOUT running a single check, printing a
    # banner, or exiting. Operators never pass it; it exists so the
    # safety-relevant predicates below (which decide whether arming DryRun=$false
    # could TERMINATE this instance) are unit-testable at all -- this file has
    # no test coverage otherwise, because its checks talk to IMDS, the AWS CLI
    # and the live process table.
    [switch]$LibraryOnly
)

# ---------------------------------------------------------------------------
# Load shared config + helpers. A failure here (e.g. an invalid
# CompletionSignal, which Get-TopazAutoStopConfig validates and throws on via
# Assert-ValidCompletionSignal) means NONE of the checks below can run at
# all, so it is reported as its own immediate NO-GO instead of letting an
# uncaught exception blow past this script's whole point.
# ---------------------------------------------------------------------------

try {
    . "$PSScriptRoot\Config.ps1"
    $cfg = Get-TopazAutoStopConfig
}
catch {
    Write-Output "[FAIL] Config load - Get-TopazAutoStopConfig threw: $($_.Exception.Message)"
    Write-Output ''
    Write-Output '===================================================================='
    Write-Output 'SUMMARY'
    Write-Output '  PASS : 0'
    Write-Output '  WARN : 0'
    Write-Output '  FAIL : 1'
    Write-Output '===================================================================='
    Write-Output 'VERDICT: NO-GO'
    Write-Output 'Config.ps1 itself does not load; fix it before running any further checks.'
    exit 1
}

# ---------------------------------------------------------------------------
# Also dot-source Watchdog.ps1 (read-only -- never edited by this script) so
# checks 5/6 below can call its REAL Get-TopazPids / Get-TopazWorkers /
# Resolve-ProcessDescendants / Build-WorkerWqlFilter directly, instead of a
# separate reimplementation that could silently drift from whatever the
# actual watchdog does today (it already dot-sources Config.ps1 itself, so
# this is a superset of the load above, not a conflicting second copy).
# Watchdog.ps1's own top-level executable tail (the "wait for Topaz" / outer
# monitoring loop) is guarded by `if ($MyInvocation.InvocationName -ne '.')`,
# so dot-sourcing it here ONLY defines its functions -- it is never entered
# and never blocks, exactly as in-guest/tests/Watchdog.Tests.ps1 already
# relies on. A failure here is captured, not thrown: checks 5/6 degrade to a
# WARN explaining why, rather than this whole tool crashing.
# ---------------------------------------------------------------------------

$watchdogLoadError = $null
try {
    . "$PSScriptRoot\Watchdog.ps1"
}
catch {
    $watchdogLoadError = $_.Exception.Message
}

# ---------------------------------------------------------------------------
# Result tracking.
# ---------------------------------------------------------------------------

$script:PassCount = 0
$script:WarnCount = 0
$script:FailCount = 0

function Write-PreflightResult {
    <#
    .SYNOPSIS
        Prints one check-result line in the required "[STATUS] name - detail"
        form and tallies it into the script-scope PASS/WARN/FAIL counters.
    .PARAMETER Status
        'PASS', 'WARN', or 'FAIL'.
    .PARAMETER Name
        Short check name, e.g. 'Elevation' or "Worker discovery ('ffmpeg.exe')".
    .PARAMETER Detail
        Human-readable explanation, appearing after ' - '.
    .DESCRIPTION
        Each result is written to BOTH the console and preflight.log.

        Persisting every check used to be skipped, on the reasoning that the
        operator is sitting there reading the console. That reasoning failed
        the moment anyone had to read the result AFTERWARDS: a real run logged
        only its summary line --

            [2026-07-27 07:42:35] [WARN] Preflight verdict=GO pass=14 warn=2 fail=0.

        -- and the DETAIL of those two warnings existed only as console text
        that was never captured. A later post-mortem could establish that the
        box had been warned about something before a five-hour render, but not
        about WHAT, and the checks are not reproducible after the fact (the
        instance-store volume, the running process tree, and the IAM answers
        have all moved on).

        Since every check in this script already funnels through this one
        function, logging here captures all of them and nothing else needs to
        change. Status maps to level so the file stays greppable:
        PASS -> INFO, WARN -> WARN, FAIL -> ERROR.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('PASS', 'WARN', 'FAIL')][string]$Status,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Detail
    )

    Write-Output "[$Status] $Name - $Detail"

    $level = switch ($Status) {
        'FAIL'  { 'ERROR' }
        'WARN'  { 'WARN' }
        default { 'INFO' }
    }

    # -ErrorAction Continue is REQUIRED, not defensive noise. At 'ERROR' level
    # Write-TopazLog calls Write-Error, and this script never sets
    # $ErrorActionPreference -- so it inherits the caller's. Invoked from a
    # session (or CI step) preferring 'Stop', the FIRST failing check would
    # throw out of this function and abandon every remaining check, turning a
    # complete "NO-GO, here are all 3 problems" report into a partial one that
    # stops at the first. A preflight that hides later failures is worse than
    # no preflight. Passing the preference in makes the write non-terminating
    # inside Write-TopazLog while still emitting on the error stream.
    Write-TopazLog -Component 'preflight' -Level $level `
        -Message "[$Status] $Name - $Detail" -ErrorAction Continue

    switch ($Status) {
        'PASS' { $script:PassCount++ }
        'WARN' { $script:WarnCount++ }
        'FAIL' { $script:FailCount++ }
    }
}

function Invoke-BoundedCommand {
    <#
    .SYNOPSIS
        Runs an external executable bounded by a timeout, never hanging this
        preflight tool.
    .DESCRIPTION
        Mirrors Config.ps1's own deadlock-avoidance pattern (used by
        Get-GpuUtilizationMax and Invoke-TopazAwsCli): standard output AND
        standard error are read via ReadToEndAsync() BEFORE WaitForExit is
        called, because a synchronous ReadToEnd() first would block until the
        child closes that stream (normally at exit) -- exactly the hang this
        timeout exists to bound around. On timeout the process is Kill()ed.

        Generic over the executable/arguments (unlike Invoke-TopazAwsCli,
        which is aws-CLI-specific and logs via Write-TopazLog) so this one
        helper covers every external call this script makes: nvidia-smi,
        aws --version, and the two real aws CLI probes below.
    .PARAMETER FileName
        The executable to run, resolved via normal PATH search.
    .PARAMETER Arguments
        A single pre-joined argument string (ProcessStartInfo.Arguments) --
        PowerShell 5.1 has no array-valued ArgumentList, matching
        Invoke-TopazAwsCli's own PS 5.1-compatible calling convention.
    .PARAMETER TimeoutSec
        Bound on the whole call.
    .OUTPUTS
        [pscustomobject]@{ Ok; ExitCode; StdOut; StdErr; TimedOut; Error }
        Ok is $true only for a clean, non-timed-out launch (regardless of the
        process's own exit code -- callers decide what an exit code means).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FileName,
        [string]$Arguments = '',
        [int]$TimeoutSec = 15
    )

    $proc = $null
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $FileName
        $psi.Arguments = $Arguments
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        [void]$proc.Start()

        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()

        if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
            try { $proc.Kill() } catch { $null = $_ }
            return [pscustomobject]@{
                Ok       = $false
                ExitCode = $null
                StdOut   = ''
                StdErr   = ''
                TimedOut = $true
                Error    = "Timed out after ${TimeoutSec}s."
            }
        }

        return [pscustomobject]@{
            Ok       = $true
            ExitCode = $proc.ExitCode
            StdOut   = $stdoutTask.Result
            StdErr   = $stderrTask.Result
            TimedOut = $false
            Error    = $null
        }
    }
    catch {
        return [pscustomobject]@{
            Ok       = $false
            ExitCode = $null
            StdOut   = ''
            StdErr   = ''
            TimedOut = $false
            Error    = $_.Exception.Message
        }
    }
    finally {
        if ($proc) { $proc.Dispose() }
    }
}

function ConvertTo-AwsArgumentString {
    <#
    .SYNOPSIS
        Pure: joins an aws CLI argument array into ONE escaped string via
        Config.ps1's ConvertTo-TopazCliArgument, exactly as
        Invoke-TopazAwsCli does internally -- reused here so this script's
        own direct aws.exe invocations (via Invoke-BoundedCommand) build
        their command line the same battle-tested way.
    .PARAMETER ArgumentList
        The aws CLI argument list, unescaped.
    .OUTPUTS
        A single string ready for ProcessStartInfo.Arguments.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$ArgumentList)

    $escaped = $ArgumentList | ForEach-Object { ConvertTo-TopazCliArgument -Value $_ }
    return [string]::Join(' ', $escaped)
}

function Get-NvidiaSmiUtilizationSnapshot {
    <#
    .SYNOPSIS
        Per-GPU utilization percentages read from nvidia-smi, or $null if it
        could not be resolved/run/parsed within the timeout.
    .DESCRIPTION
        Uses the same bounded-process pattern as Config.ps1's own
        Get-GpuUtilizationMax, but returns every GPU's raw value (not just
        the maximum), so this preflight check can report both a value AND a
        GPU count in one call.
    .OUTPUTS
        An int[] of one utilization percentage per GPU, or $null.
    #>
    [CmdletBinding()]
    param([int]$TimeoutSec = 15)

    $result = Invoke-BoundedCommand -FileName 'nvidia-smi' `
        -Arguments '--query-gpu=utilization.gpu --format=csv,noheader,nounits' -TimeoutSec $TimeoutSec

    if ((-not $result.Ok) -or ($result.ExitCode -ne 0)) { return $null }

    $vals = @(($result.StdOut -split "`r?`n") |
        ForEach-Object { "$_".Trim() } |
        Where-Object { $_ -match '^\d+$' } |
        ForEach-Object { [int]$_ })

    if ($vals.Count -eq 0) { return $null }
    return , $vals
}

function Get-WorkerNamePattern {
    <#
    .SYNOPSIS
        Pure: the configured worker LIKE pattern(s) as a non-empty string[],
        regardless of which property name and shape the live $cfg object
        actually exposes.
    .DESCRIPTION
        The worker setting is being renamed/reshaped concurrently elsewhere
        in this repo (a single WorkerNameLike string -> a WorkerNamesLike
        array, e.g. @('neuroserver.exe', 'ffmpeg.exe') -- see
        docs/12-empirical-findings.md). Reading whichever property the live
        config object exposes, preferring the array-shaped WorkerNamesLike
        when both happen to be present, keeps this preflight tool working
        across that rename instead of hard-failing on a missing property.
    .PARAMETER Config
        The object returned by Get-TopazAutoStopConfig.
    .OUTPUTS
        A string[] of LIKE patterns (possibly empty, if neither property is
        present/populated).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)

    $propertyNames = $Config.PSObject.Properties.Name

    if ($propertyNames -contains 'WorkerNamesLike') {
        $raw = $Config.WorkerNamesLike
        if ($null -ne $raw) {
            $patterns = @($raw | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($patterns.Count -gt 0) { return , $patterns }
        }
    }

    if ($propertyNames -contains 'WorkerNameLike') {
        $raw = $Config.WorkerNameLike
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            return , @($raw)
        }
    }

    return , @()
}

function Test-StopPlanCanReachGuestShutdown {
    <#
    .SYNOPSIS
        Pure: can the configured StopStrategy ever reach Stop-Computer?
    .DESCRIPTION
        This single boolean is what decides whether checks 10 and 11 below FAIL
        or merely WARN -- i.e. whether the operator is told that arming
        DryRun=$false could TERMINATE (destroy) this instance rather than stop
        it. It was computed twice, verbatim, in two places roughly 40 lines
        apart. Nothing pinned the two copies together, and a future edit that
        fixed or inverted only ONE of them would send check 11 down its PASS
        branch for an 'Auto' plan on a 'terminate' box while every test in the
        repo stayed green. One implementation, one call site each.

        Resolve-StopPlan (Config.ps1) is the authority on what a strategy
        expands to: only 'Ec2ApiStop' alone never falls back to a guest
        shutdown. Every other value -- including the default 'Auto', an absent
        StopStrategy property, and any value Resolve-StopPlan does not
        recognize (its own `default` branch returns the two-action plan) -- CAN
        reach Stop-Computer. Treating the unknown cases as "can reach" is the
        fail-safe direction: it keeps the dangerous-combination FAIL armed
        rather than quietly downgrading it.
    .PARAMETER StopStrategy
        The configured StopStrategy, or $null/'' when the config has no such
        property.
    .OUTPUTS
        [bool] $true when a guest shutdown is reachable.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$StopStrategy)

    if ([string]::IsNullOrWhiteSpace($StopStrategy)) { return $true }
    return ($StopStrategy -ne 'Ec2ApiStop')
}

function Resolve-EphemeralOutputVerdict {
    <#
    .SYNOPSIS
        Pure: does OutputIsEphemeral agree with the volume OutputDir lives on?
    .DESCRIPTION
        OutputIsEphemeral is the single flag that arms the interlock which
        prevented a repeat of the render loss in docs/16. NOTHING in the
        pipeline cross-checks it against reality: Get-TopazAutoStopConfig
        validates CompletionSignal, StopStrategy and WorkerNamesLike, and this
        preflight only checked that OutputDir exists.

        The dangerous disagreement is renders-on-the-scratch-volume with the
        interlock DISARMED: a 'stalled' or 'maxlifetime' stop then powers the
        box off with no upload gate at all (Stop-Sequence.ps1 only runs the
        completion safety gate for reason='completed'), and the instance store
        is wiped. That is a FAIL.

        The opposite disagreement -- persistent output marked ephemeral -- costs
        no data; it just makes the interlock block stops for output that was
        never at risk. WARN.
    .PARAMETER OutputDir
        $cfg.OutputDir, e.g. 'D:\Renders'.
    .PARAMETER ScratchDriveLetter
        $cfg.ScratchDriveLetter. Accepts 'D' or 'D:'.
    .PARAMETER OutputIsEphemeral
        $cfg.OutputIsEphemeral.
    .OUTPUTS
        [pscustomobject]@{ Status = 'PASS'|'WARN'|'FAIL'; Detail = <string> }
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$OutputDir,
        [AllowNull()][AllowEmptyString()][string]$ScratchDriveLetter,
        [bool]$OutputIsEphemeral
    )

    # Get-TopazWindowsPathRoot, not [System.IO.Path]: OutputDir is always a
    # Windows path regardless of which OS runs this code, and .NET on Linux
    # returns '' for 'D:\Renders'. See its own comment in Config.ps1. Its -Path
    # is Mandatory, so an unset OutputDir is screened out here rather than
    # binding-erroring inside a config-sanity check.
    $outputRoot = if ([string]::IsNullOrWhiteSpace($OutputDir)) { '' } else { Get-TopazWindowsPathRoot -Path $OutputDir }
    if ([string]::IsNullOrWhiteSpace($outputRoot)) {
        return [pscustomobject]@{
            Status = 'WARN'
            Detail = "OutputDir '$OutputDir' is not a drive-letter-rooted Windows path, so it cannot be compared against ScratchDriveLetter '$ScratchDriveLetter'. OutputIsEphemeral=`$$OutputIsEphemeral could not be corroborated."
        }
    }

    # Trim the same way Get-ExistingScratchDriveValidation does: a config
    # carrying 'D:' rather than 'D' must not produce a spurious mismatch.
    $scratchLetter = "$ScratchDriveLetter".Trim().TrimEnd(':')
    $outputLetter = $outputRoot.Substring(0, 1)
    $onScratchVolume = [string]::Equals($outputLetter, $scratchLetter, [System.StringComparison]::OrdinalIgnoreCase)

    if ($onScratchVolume -and -not $OutputIsEphemeral) {
        return [pscustomobject]@{
            Status = 'FAIL'
            Detail = "*** DATA LOSS RISK *** OutputDir '$OutputDir' is on the instance-store scratch volume (${scratchLetter}:), which is ERASED on every instance stop, but OutputIsEphemeral is `$false -- so Stop-Sequence.ps1's upload interlock is DISARMED. A stalled or timed hard stop would power the box off without verifying the upload and destroy every finished render in that folder. Set OutputIsEphemeral = `$true, or move OutputDir onto the persistent C: drive."
        }
    }

    if (-not $onScratchVolume -and $OutputIsEphemeral) {
        return [pscustomobject]@{
            Status = 'WARN'
            Detail = "OutputDir '$OutputDir' is NOT on the scratch volume (${scratchLetter}:) yet OutputIsEphemeral is `$true. Nothing is at risk of being erased, but the interlock will refuse every stop whose upload fails, for output that actually survives a stop. Set OutputIsEphemeral = `$false if '$outputRoot' really is persistent."
        }
    }

    $where = if ($onScratchVolume) { "on the wiped instance-store volume (${scratchLetter}:)" } else { "on persistent storage ($outputRoot)" }
    return [pscustomobject]@{
        Status = 'PASS'
        Detail = "OutputDir '$OutputDir' is $where and OutputIsEphemeral=`$$OutputIsEphemeral agrees with that."
    }
}

# ---------------------------------------------------------------------------
# Dot-source seam. Everything above is a helper definition; everything below
# actually probes the box. Referenced (not merely declared) so
# PSReviewUnusedParameter stays quiet.
# ---------------------------------------------------------------------------

if ($LibraryOnly) { return }

# ---------------------------------------------------------------------------
# Best-effort refresh of THIS PROCESS's own copy of PATH from the registry,
# before any resolvability check below runs. This process's environment was
# captured when its shell started; a dependency installed afterwards (the
# documented AWS CLI v2 install on this exact box is the motivating case)
# would otherwise report a false negative instead of the box's TRUE current
# state, which is the entire point of a preflight tool. This only mutates
# THIS PROCESS's in-memory environment block -- never the registry, never
# any other process, and it is silently best-effort (a failure here just
# means the checks below fall back to this session's existing PATH).
#
# Below the -LibraryOnly seam on purpose: dot-sourcing this file for its pure
# helpers must not touch even this process's environment.
# ---------------------------------------------------------------------------

try {
    $machinePathValue = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPathValue = [System.Environment]::GetEnvironmentVariable('Path', 'User')
    $refreshedPathParts = @($machinePathValue, $userPathValue) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if ($refreshedPathParts.Count -gt 0) {
        $env:Path = [string]::Join(';', $refreshedPathParts)
    }
}
catch {
    $null = $_
}

# ---------------------------------------------------------------------------
# Banner.
#
# $PSScriptRoot and InstallDir are printed because this tool validates
# WHICHEVER copy of the pipeline it was launched from: it dot-sources
# "$PSScriptRoot\Config.ps1", while the scheduled tasks run the InstallDir
# copies. Run from the repo checkout after editing Config.ps1 but before
# re-running Install.ps1, every result below describes a pipeline that is not
# the one the box will actually execute -- a drift documented in docs/11 as a
# known failure mode. Check 3 compares the two copies; this line says which
# one was measured.
# ---------------------------------------------------------------------------

Write-Output '===================================================================='
Write-Output "Topaz Auto-Stop Preflight - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')"
Write-Output "Host=$env:COMPUTERNAME User=$env:USERDOMAIN\$env:USERNAME"
Write-Output "Validating : $PSScriptRoot"
Write-Output "InstallDir : $($cfg.InstallDir)   (what the scheduled tasks run)"
Write-Output '===================================================================='
Write-Output ''

# ---------------------------------------------------------------------------
# 1. OS + PowerShell version.
# ---------------------------------------------------------------------------

Write-Output '-- 1. OS + PowerShell version --'

$psVersion = $PSVersionTable.PSVersion
$isWindowsPlatform = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
$psVersionOk = ($psVersion.Major -gt 5) -or (($psVersion.Major -eq 5) -and ($psVersion.Minor -ge 1))

if ($isWindowsPlatform -and $psVersionOk) {
    Write-PreflightResult -Status 'PASS' -Name 'PowerShell version' `
        -Detail "PowerShell $psVersion on Windows ($([System.Environment]::OSVersion.VersionString))."
}
else {
    Write-PreflightResult -Status 'WARN' -Name 'PowerShell version' `
        -Detail "Expected Windows PowerShell 5.1+; found PowerShell $psVersion on platform $([System.Environment]::OSVersion.Platform)."
}

# ---------------------------------------------------------------------------
# 2. Elevation.
# ---------------------------------------------------------------------------

Write-Output ''
Write-Output '-- 2. Elevation --'

$windowsIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$windowsPrincipal = New-Object Security.Principal.WindowsPrincipal($windowsIdentity)
$isElevated = $windowsPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($isElevated) {
    Write-PreflightResult -Status 'PASS' -Name 'Elevation' `
        -Detail "Running as '$($windowsIdentity.Name)', which IS in the Administrator role."
}
else {
    Write-PreflightResult -Status 'FAIL' -Name 'Elevation' `
        -Detail "Running as '$($windowsIdentity.Name)', which is NOT an Administrator. Scheduled task registration (Register-ScheduledTasks.ps1) requires elevation."
}

# ---------------------------------------------------------------------------
# 3. Config sanity.
# ---------------------------------------------------------------------------

Write-Output ''
Write-Output '-- 3. Config sanity --'

if (Test-Path -LiteralPath $cfg.OutputDir -PathType Container) {
    Write-PreflightResult -Status 'PASS' -Name 'Config: OutputDir' `
        -Detail "'$($cfg.OutputDir)' exists and is a directory."
}
else {
    Write-PreflightResult -Status 'FAIL' -Name 'Config: OutputDir' `
        -Detail "'$($cfg.OutputDir)' does not exist or is not a directory. Topaz cannot write outputs there and the watchdog's growth/unlock checks will never see real files."
}

try {
    if (-not (Test-Path -LiteralPath $cfg.LogDir)) {
        New-Item -ItemType Directory -Path $cfg.LogDir -Force -ErrorAction Stop | Out-Null
    }
    $probeFile = Join-Path $cfg.LogDir ("preflight-write-probe-{0}.tmp" -f [guid]::NewGuid())
    Set-Content -LiteralPath $probeFile -Value 'preflight' -Encoding UTF8 -ErrorAction Stop
    Remove-Item -LiteralPath $probeFile -Force -ErrorAction Stop
    Write-PreflightResult -Status 'PASS' -Name 'Config: LogDir writable' `
        -Detail "'$($cfg.LogDir)' exists (or was created) and a probe file could be written and removed."
}
catch {
    Write-PreflightResult -Status 'FAIL' -Name 'Config: LogDir writable' `
        -Detail "'$($cfg.LogDir)' could not be created/written to: $($_.Exception.Message). Every component's log would silently go nowhere."
}

try {
    Assert-ValidCompletionSignal -Signal $cfg.CompletionSignal
    Write-PreflightResult -Status 'PASS' -Name 'Config: CompletionSignal' `
        -Detail "'$($cfg.CompletionSignal)' is a legal value (WorkerOnly, GpuOnly, WorkerOrGpu)."
}
catch {
    Write-PreflightResult -Status 'FAIL' -Name 'Config: CompletionSignal' `
        -Detail $_.Exception.Message
}

$timingPositiveOk = ($cfg.PollSec -gt 0) -and ($cfg.DebounceSec -gt 0) -and ($cfg.StallSec -gt 0)
$timingOrderOk = $cfg.DebounceSec -gt $cfg.PollSec

if ($timingPositiveOk -and $timingOrderOk) {
    Write-PreflightResult -Status 'PASS' -Name 'Config: timing values' `
        -Detail "PollSec=$($cfg.PollSec) DebounceSec=$($cfg.DebounceSec) StallSec=$($cfg.StallSec); all positive and DebounceSec > PollSec."
}
else {
    $timingProblems = @()
    if (-not $timingPositiveOk) {
        $timingProblems += "PollSec/DebounceSec/StallSec must all be positive (got PollSec=$($cfg.PollSec) DebounceSec=$($cfg.DebounceSec) StallSec=$($cfg.StallSec))"
    }
    if (-not $timingOrderOk) {
        $timingProblems += "DebounceSec ($($cfg.DebounceSec)) must be greater than PollSec ($($cfg.PollSec)), or a single missed poll can already satisfy the debounce"
    }
    Write-PreflightResult -Status 'FAIL' -Name 'Config: timing values' -Detail ($timingProblems -join '; ')
}

# --- 3a. OutputIsEphemeral vs. the volume OutputDir actually lives on -------
#
# Pure decision, so it lives in Resolve-EphemeralOutputVerdict above and is unit
# tested; only the reporting is here.

$ephemeralVerdict = Resolve-EphemeralOutputVerdict -OutputDir $cfg.OutputDir `
    -ScratchDriveLetter $cfg.ScratchDriveLetter -OutputIsEphemeral ([bool]$cfg.OutputIsEphemeral)
Write-PreflightResult -Status $ephemeralVerdict.Status -Name 'Config: OutputIsEphemeral vs OutputDir volume' `
    -Detail $ephemeralVerdict.Detail

# --- 3b. The upload path, which is a hard precondition for stopping at all --
#
# WHY THIS IS A FAIL AND NOT A NICETY. With the shipped defaults
# (OutputIsEphemeral=$true, UploadTarget='gdrive:temp'),
# Invoke-TopazRenderUpload returns $false the moment either rclone path is
# missing, Stop-Sequence.ps1's ephemeral interlock then REFUSES the stop, and
# the watchdog re-arms every DebounceSec forever. A box where
# Set-GoogleDriveAuth.ps1 was never run is structurally incapable of ever
# stopping -- and this preflight used to print VERDICT: GO for it. The word
# 'rclone' did not appear in this file at all.
#
# The FAIL conditions below are exactly the conditions Stop-Sequence.ps1 and
# Test-TopazCompletedStopSafetyGate actually refuse on; nothing broader.

if ($cfg.OutputIsEphemeral -and [string]::IsNullOrWhiteSpace($cfg.UploadTarget)) {
    Write-PreflightResult -Status 'FAIL' -Name 'Config: UploadTarget' `
        -Detail "OutputDir '$($cfg.OutputDir)' is marked ephemeral but no UploadTarget is configured. Stop-Sequence.ps1 REFUSES every stop in that state (there is nowhere to save renders that the stop is about to erase), so this instance can never stop itself. Set UploadTarget in Config.ps1 and re-run Install.ps1."
}
elseif ([string]::IsNullOrWhiteSpace($cfg.UploadTarget)) {
    Write-PreflightResult -Status 'WARN' -Name 'Config: UploadTarget' `
        -Detail "No UploadTarget configured. Renders are never uploaded before a stop. That is only safe because OutputIsEphemeral is `$false, i.e. '$($cfg.OutputDir)' survives the stop."
}
else {
    Write-PreflightResult -Status 'PASS' -Name 'Config: UploadTarget' `
        -Detail "'$($cfg.UploadTarget)' is configured as the verified upload destination for '$($cfg.OutputDir)'."

    $uploadIsMandatory = [bool]$cfg.OutputIsEphemeral
    $rcloneMissingStatus = if ($uploadIsMandatory) { 'FAIL' } else { 'WARN' }
    $rcloneStakes = if ($uploadIsMandatory) {
        'Until it exists, EVERY stop is REFUSED and this instance keeps billing.'
    }
    else {
        'Renders will not be uploaded before a stop (not fatal: OutputDir is persistent).'
    }

    $rcloneExeOk = Test-Path -LiteralPath $cfg.RclonePath -PathType Leaf
    if ($rcloneExeOk) {
        Write-PreflightResult -Status 'PASS' -Name 'rclone executable' `
            -Detail "Found at the configured RclonePath '$($cfg.RclonePath)'."
    }
    else {
        Write-PreflightResult -Status $rcloneMissingStatus -Name 'rclone executable' `
            -Detail "NOT found at the configured RclonePath '$($cfg.RclonePath)'. $rcloneStakes Install rclone there, or fix RclonePath in Config.ps1."
    }

    $rcloneConfigOk = Test-Path -LiteralPath $cfg.RcloneConfigPath -PathType Leaf
    if ($rcloneConfigOk) {
        Write-PreflightResult -Status 'PASS' -Name 'rclone config' `
            -Detail "Found at '$($cfg.RcloneConfigPath)' (the Drive remote has been authorised)."
    }
    else {
        Write-PreflightResult -Status $rcloneMissingStatus -Name 'rclone config' `
            -Detail "NOT found at '$($cfg.RcloneConfigPath)': the Google Drive remote has never been authorised on this box. $rcloneStakes Run Set-GoogleDriveAuth.ps1 (elevated, from an interactive DCV session)."
    }

    # `rclone listremotes` is local and read-only -- it parses the config file
    # and makes no network call, so it stays inside this tool's read-only
    # contract. WARN only: a remote that cannot be listed is diagnosable, while
    # the FAILs above are keyed on the two conditions the stop path itself
    # refuses on.
    if ($rcloneExeOk -and $rcloneConfigOk) {
        $expectedRemote = ($cfg.UploadTarget -split ':')[0]
        $listRemotesArgs = ConvertTo-AwsArgumentString -ArgumentList @('listremotes', '--config', $cfg.RcloneConfigPath)
        $listRemotesResult = Invoke-BoundedCommand -FileName $cfg.RclonePath -Arguments $listRemotesArgs -TimeoutSec 15

        $foundRemotes = @()
        if ($listRemotesResult.Ok -and ($listRemotesResult.ExitCode -eq 0)) {
            $foundRemotes = @(($listRemotesResult.StdOut -split "`r?`n") |
                ForEach-Object { "$_".Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }

        if ($foundRemotes -contains "${expectedRemote}:") {
            Write-PreflightResult -Status 'PASS' -Name "rclone remote '${expectedRemote}:'" `
                -Detail "Present in '$($cfg.RcloneConfigPath)', matching UploadTarget '$($cfg.UploadTarget)'."
        }
        else {
            $listRemotesErrText = "$($listRemotesResult.StdOut)$($listRemotesResult.StdErr)".Trim()
            if ([string]::IsNullOrWhiteSpace($listRemotesErrText)) { $listRemotesErrText = $listRemotesResult.Error }
            Write-PreflightResult -Status 'WARN' -Name "rclone remote '${expectedRemote}:'" `
                -Detail "UploadTarget is '$($cfg.UploadTarget)', whose remote is '${expectedRemote}:', but 'rclone listremotes' did not report it (found: $($foundRemotes -join ', ')$listRemotesErrText). Re-run Set-GoogleDriveAuth.ps1 -RemoteName '$expectedRemote', or fix UploadTarget."
        }
    }
}

# --- 3c. Which copy of the pipeline did this run actually validate? ---------
#
# This script dot-sources "$PSScriptRoot\Config.ps1", but the scheduled tasks
# run the InstallDir copies. Run from the repo checkout after editing
# Config.ps1 and before re-running Install.ps1, every check in this report
# describes a pipeline the box will never execute -- docs/11 lists exactly that
# ("DryRun is still $true in the installed copy") as a known failure mode, and
# this tool was silent about it.
#
# Severity ladder matches check 12's convention: not-installed-yet is a WARN
# (the preflight is documented as runnable before Install.ps1), an INCOMPLETE
# install is a FAIL, and content drift is a WARN naming each file.

if ($PSScriptRoot -eq $cfg.InstallDir) {
    Write-PreflightResult -Status 'PASS' -Name 'Repo vs installed copy' `
        -Detail "Running from InstallDir itself ('$($cfg.InstallDir)'), so this report describes exactly the files the scheduled tasks execute."
}
else {
    # Config.ps1/Watchdog.ps1/Stop-Sequence.ps1 are the pipeline; the other two
    # are the boot/metric tasks. All five are what Install.ps1 copies.
    $installedNames = @('Config.ps1', 'Watchdog.ps1', 'Stop-Sequence.ps1', 'Push-GpuMetric.ps1', 'Initialize-ScratchDisk.ps1')
    $requiredNames = @('Config.ps1', 'Watchdog.ps1', 'Stop-Sequence.ps1')

    $presentInstalled = @($installedNames | Where-Object { Test-Path -LiteralPath (Join-Path $cfg.InstallDir $_) -PathType Leaf })

    if ($presentInstalled.Count -eq 0) {
        Write-PreflightResult -Status 'WARN' -Name 'Repo vs installed copy' `
            -Detail "This run validated '$PSScriptRoot', but the pipeline is not installed in '$($cfg.InstallDir)' yet (none of $($installedNames -join ', ') are there). Run Install.ps1, then re-run this preflight so it measures what the scheduled tasks will actually execute."
    }
    else {
        $missingInstalled = @($requiredNames | Where-Object { $presentInstalled -notcontains $_ })
        if ($missingInstalled.Count -gt 0) {
            Write-PreflightResult -Status 'FAIL' -Name 'Repo vs installed copy' `
                -Detail "'$($cfg.InstallDir)' is a PARTIAL install: missing $($missingInstalled -join ', '). Every installed script dot-sources Config.ps1 by literal name and Watchdog.ps1 invokes Stop-Sequence.ps1, so the tasks would fail at run time. Re-run Install.ps1 and check its log for copy errors."
        }

        $driftedFiles = @()
        foreach ($name in $presentInstalled) {
            $repoCopy = Join-Path $PSScriptRoot $name
            if (-not (Test-Path -LiteralPath $repoCopy -PathType Leaf)) { continue }
            try {
                # Get-FileHash exists in Windows PowerShell 5.1; read-only, and
                # at most five small files.
                $repoHash = (Get-FileHash -LiteralPath $repoCopy -Algorithm SHA256 -ErrorAction Stop).Hash
                $installedHash = (Get-FileHash -LiteralPath (Join-Path $cfg.InstallDir $name) -Algorithm SHA256 -ErrorAction Stop).Hash
                if ($repoHash -ne $installedHash) { $driftedFiles += $name }
            }
            catch {
                $driftedFiles += "$name (could not be hashed: $($_.Exception.Message))"
            }
        }

        if ($driftedFiles.Count -gt 0) {
            Write-PreflightResult -Status 'WARN' -Name 'Repo vs installed copy' `
                -Detail "This run validated '$PSScriptRoot', but the INSTALLED copy the scheduled tasks run differs in: $($driftedFiles -join ', '). Anything this report says about those files (DryRun, UploadTarget, timings, detection logic) may not describe the running pipeline. Re-run Install.ps1, then re-run this preflight."
        }
        elseif ($missingInstalled.Count -eq 0) {
            Write-PreflightResult -Status 'PASS' -Name 'Repo vs installed copy' `
                -Detail "'$PSScriptRoot' and the installed copy in '$($cfg.InstallDir)' are byte-identical for $($presentInstalled -join ', ')."
        }
    }
}

# ---------------------------------------------------------------------------
# 4. nvidia-smi.
# ---------------------------------------------------------------------------

Write-Output ''
Write-Output '-- 4. nvidia-smi --'

$gpuSignalNeedsNvidiaSmi = ($cfg.CompletionSignal -eq 'GpuOnly') -or ($cfg.CompletionSignal -eq 'WorkerOrGpu')
$gpuSnapshot = Get-NvidiaSmiUtilizationSnapshot

# NOT `if ($gpuSnapshot)`. Get-NvidiaSmiUtilizationSnapshot returns an int[],
# and PowerShell converts a ONE-element array to bool by converting its single
# element -- so @(0) is FALSY while @(37) and @(0,0) are truthy. The target
# g6e.2xlarge has exactly one GPU, and an idle GPU reads 0%, which is the
# normal state when the operator runs this preflight BEFORE starting a render.
# The old condition therefore reported a perfectly working nvidia-smi as
# unreadable, and on CompletionSignal='GpuOnly'/'WorkerOrGpu' turned that into
# a spurious FAIL and VERDICT: NO-GO. $null is still the only failure signal
# (see the function's own returns).
if ($null -ne $gpuSnapshot -and $gpuSnapshot.Count -gt 0) {
    $gpuMax = ($gpuSnapshot | Measure-Object -Maximum).Maximum
    $gpuUtilizationList = ($gpuSnapshot | ForEach-Object { "$_%" }) -join ', '
    Write-PreflightResult -Status 'PASS' -Name 'nvidia-smi' `
        -Detail "Resolved; $($gpuSnapshot.Count) GPU(s) detected, utilization=[$gpuUtilizationList] max=$gpuMax%."
}
elseif ($gpuSignalNeedsNvidiaSmi) {
    Write-PreflightResult -Status 'FAIL' -Name 'nvidia-smi' `
        -Detail "Could not be resolved/read, and CompletionSignal='$($cfg.CompletionSignal)' depends on the GPU signal. The watchdog's GPU read will always be `$null and this signal source will never confirm activity."
}
else {
    Write-PreflightResult -Status 'WARN' -Name 'nvidia-smi' `
        -Detail "Could not be resolved or read. Not fatal because CompletionSignal='$($cfg.CompletionSignal)' does not use the GPU signal, and the CloudWatch idle alarm's default IDLE_SIGNAL=render evaluates RenderActive, a CIM worker query that does not need nvidia-smi either -- but Push-GpuMetric.ps1's GPUUtilization metric will not publish without it, which costs GPU telemetry and matters if the alarm is instead run with the legacy IDLE_SIGNAL=gpu."
}

# ---------------------------------------------------------------------------
# 5. Topaz GUI process.
# ---------------------------------------------------------------------------

Write-Output ''
Write-Output '-- 5. Topaz GUI process --'

if ($watchdogLoadError) {
    Write-PreflightResult -Status 'WARN' -Name 'Topaz GUI process' `
        -Detail "Watchdog.ps1 failed to load ($watchdogLoadError), so this check cannot call its own Get-TopazPids. Fix Watchdog.ps1 first."
    $topazPids = $null
}
else {
    # Get-TopazPids is Watchdog.ps1's OWN function (dot-sourced above): $null =
    # the CIM query itself failed (unknown), @() = it succeeded and found none,
    # array = the live GUI PIDs. Reused here (rather than a separate query)
    # so both this check and check 6 below see EXACTLY the PID set the real
    # watchdog would see this instant.
    $topazPids = Get-TopazPids

    if ($null -eq $topazPids) {
        Write-PreflightResult -Status 'WARN' -Name 'Topaz GUI process' `
            -Detail "Get-TopazPids reported a CIM query failure; could not enumerate processes."
    }
    elseif ($topazPids.Count -gt 0) {
        Write-PreflightResult -Status 'PASS' -Name 'Topaz GUI process' `
            -Detail "Found $($topazPids.Count) process(es) matching '$($cfg.TopazNameLike)': PID(s) $($topazPids -join ', ')."
    }
    else {
        Write-PreflightResult -Status 'WARN' -Name 'Topaz GUI process' `
            -Detail "No process matches '$($cfg.TopazNameLike)' right now. Expected if Topaz is simply not open yet."
    }
}

# ---------------------------------------------------------------------------
# 6. Worker discovery + parent/child ancestry classification.
# ---------------------------------------------------------------------------

Write-Output ''
Write-Output '-- 6. Worker discovery (process ancestry) --'

$workerPatterns = Get-WorkerNamePattern -Config $cfg

if ($watchdogLoadError) {
    Write-PreflightResult -Status 'WARN' -Name 'Worker discovery' `
        -Detail "Watchdog.ps1 failed to load ($watchdogLoadError), so this check cannot call its own Get-TopazWorkers/Build-WorkerWqlFilter. Fix Watchdog.ps1 first."
}
elseif ($workerPatterns.Count -eq 0) {
    Write-PreflightResult -Status 'FAIL' -Name 'Worker discovery' `
        -Detail "cfg exposes neither a populated 'WorkerNameLike' nor 'WorkerNamesLike'. The watchdog has no worker pattern to match and will never see an active render via the worker signal."
}
else {
    # Build-WorkerWqlFilter is Config.ps1's OWN function: the exact WQL OR-filter
    # Get-TopazWorkers itself builds from these same patterns.
    try {
        $workerFilter = Build-WorkerWqlFilter -Patterns $workerPatterns
        $allMatchingWorkers = @(Get-CimInstance -ClassName Win32_Process -Filter $workerFilter -ErrorAction Stop)
        $workerCimError = $null
    }
    catch {
        $allMatchingWorkers = $null
        $workerCimError = $_.Exception.Message
    }

    if ($null -eq $allMatchingWorkers) {
        Write-PreflightResult -Status 'WARN' -Name 'Worker discovery' `
            -Detail "Could not enumerate worker-matching processes (CIM failure): $workerCimError"
    }
    elseif ($allMatchingWorkers.Count -eq 0) {
        Write-PreflightResult -Status 'WARN' -Name 'Worker discovery' `
            -Detail "No running process currently matches any configured worker pattern ($($workerPatterns -join ', ')). Expected when no render is active right now -- re-run this preflight WHILE a render is in progress to actually exercise this check."
    }
    else {
        # Get-TopazWorkers is Watchdog.ps1's REAL, production attribution
        # function (Get-TopazPids + a full-process ancestry snapshot +
        # Resolve-ProcessDescendants + Resolve-WorkerAttribution). Calling it
        # directly -- rather than reimplementing ancestry matching here --
        # means this check can never silently drift from what the watchdog
        # itself will actually do. $script:KnownWorkers is reset first so this
        # one-shot snapshot reflects pure ancestry only, with no orphan
        # carry-over from a state that does not exist for a single run.
        $script:KnownWorkers = @{}
        $attributedWorkers = Get-TopazWorkers
        $attributedIds = if ($null -eq $attributedWorkers) { @() } else { @($attributedWorkers | ForEach-Object { [int]$_.ProcessId }) }

        foreach ($w in $allMatchingWorkers) {
            $workerPid = [int]$w.ProcessId
            $isAttributed = $attributedIds -contains $workerPid
            $isDirectChild = ($null -ne $topazPids) -and ($topazPids -contains $w.ParentProcessId)

            if ($isAttributed -and $isDirectChild) {
                Write-PreflightResult -Status 'PASS' -Name "Worker discovery ('$($w.Name)')" `
                    -Detail "PID $workerPid (parent PID $($w.ParentProcessId)) is a DIRECT CHILD of a live Topaz GUI PID and IS attributed as an active worker by Get-TopazWorkers."
            }
            elseif ($isAttributed) {
                Write-PreflightResult -Status 'PASS' -Name "Worker discovery ('$($w.Name)')" `
                    -Detail "PID $workerPid (parent PID $($w.ParentProcessId)) is a DESCENDANT (grandchild or deeper) of a live Topaz GUI PID and IS attributed as an active worker by Get-TopazWorkers via ancestry (Resolve-ProcessDescendants) -- the historical direct-child-only bug documented in docs/12-empirical-findings.md is fixed in the current Watchdog.ps1."
            }
            elseif ($null -eq $topazPids) {
                Write-PreflightResult -Status 'WARN' -Name "Worker discovery ('$($w.Name)')" `
                    -Detail "PID $workerPid (parent PID $($w.ParentProcessId)) matches, but the Topaz GUI PID query itself failed this run, so ancestry/attribution could not be determined."
            }
            elseif ($topazPids.Count -eq 0) {
                Write-PreflightResult -Status 'WARN' -Name "Worker discovery ('$($w.Name)')" `
                    -Detail "PID $workerPid (parent PID $($w.ParentProcessId)) matches, but no Topaz GUI process is currently running to attribute it to."
            }
            else {
                Write-PreflightResult -Status 'WARN' -Name "Worker discovery ('$($w.Name)')" `
                    -Detail "PID $workerPid (parent PID $($w.ParentProcessId)) is UNRELATED to any live Topaz GUI PID -- NOT attributed by Get-TopazWorkers. If WorkerNamesLike/WorkerNameLike is unintentionally broad, the watchdog could misread unrelated activity as an active render."
            }
        }

        if (($null -ne $topazPids) -and ($topazPids.Count -gt 0)) {
            if ($attributedIds.Count -gt 0) {
                Write-PreflightResult -Status 'PASS' -Name 'Worker discovery rollup' `
                    -Detail "Get-TopazWorkers attributes $($attributedIds.Count) of $($allMatchingWorkers.Count) matching process(es) as active worker(s) right now; the worker signal can be attributed correctly."
            }
            else {
                Write-PreflightResult -Status 'FAIL' -Name 'Worker discovery rollup' `
                    -Detail "A live Topaz GUI is running and $($allMatchingWorkers.Count) process(es) match the configured worker pattern(s), but Get-TopazWorkers attributes NONE of them as active. The worker signal will NEVER read active with this configuration -- investigate before relying on it."
            }
        }
    }
}

# ---------------------------------------------------------------------------
# 7. AWS CLI.
# ---------------------------------------------------------------------------

Write-Output ''
Write-Output '-- 7. AWS CLI --'

$awsCommand = Get-Command -Name 'aws' -ErrorAction SilentlyContinue

if (-not $awsCommand) {
    Write-PreflightResult -Status 'WARN' -Name 'AWS CLI' `
        -Detail "'aws' is not resolvable on PATH in this session. S3 sync / SNS notify / the CloudWatch + shutdown-behavior probes below all depend on it."
}
else {
    $versionResult = Invoke-BoundedCommand -FileName 'aws' -Arguments '--version' -TimeoutSec $cfg.AwsCliTimeoutSec
    $versionText = "$($versionResult.StdOut)$($versionResult.StdErr)".Trim()

    if ($versionResult.Ok -and ($versionResult.ExitCode -eq 0) -and $versionText) {
        Write-PreflightResult -Status 'PASS' -Name 'AWS CLI' -Detail "Resolved at '$($awsCommand.Source)'. $versionText"
    }
    else {
        Write-PreflightResult -Status 'WARN' -Name 'AWS CLI' `
            -Detail "Resolved at '$($awsCommand.Source)' but '--version' did not return cleanly ($($versionResult.Error) $versionText)."
    }
}

# ---------------------------------------------------------------------------
# 8. IMDS.
# ---------------------------------------------------------------------------

Write-Output ''
Write-Output '-- 8. IMDS --'

$ec2Identity = Get-Ec2Identity

if ((-not [string]::IsNullOrWhiteSpace($ec2Identity.InstanceId)) -and (-not [string]::IsNullOrWhiteSpace($ec2Identity.Region))) {
    Write-PreflightResult -Status 'PASS' -Name 'IMDS' `
        -Detail "instance-id=$($ec2Identity.InstanceId) region=$($ec2Identity.Region)."
}
else {
    Write-PreflightResult -Status 'WARN' -Name 'IMDS' `
        -Detail "IMDSv2 did not return both instance-id and region (instance-id='$($ec2Identity.InstanceId)' region='$($ec2Identity.Region)'). AWS CLI calls needing --region and per-instance dimensioning will be affected."
}

# ---------------------------------------------------------------------------
# 9. cloudwatch:PutMetricData permission probe (ONE real call).
# ---------------------------------------------------------------------------

Write-Output ''
Write-Output '-- 9. CloudWatch PutMetricData permission probe --'

if (-not $awsCommand) {
    Write-PreflightResult -Status 'WARN' -Name 'CloudWatch PutMetricData probe' `
        -Detail "Skipped: 'aws' is not resolvable (see the AWS CLI check above)."
}
elseif ([string]::IsNullOrWhiteSpace($ec2Identity.Region)) {
    Write-PreflightResult -Status 'WARN' -Name 'CloudWatch PutMetricData probe' `
        -Detail "Skipped: IMDS did not return a region (see the IMDS check above), and the AWS CLI needs --region for this call."
}
else {
    $putMetricArgs = ConvertTo-AwsArgumentString -ArgumentList @(
        'cloudwatch', 'put-metric-data',
        '--namespace', $cfg.MetricNamespace,
        '--metric-name', 'PreflightCanary',
        '--value', '0',
        '--region', $ec2Identity.Region
    )
    $putMetricResult = Invoke-BoundedCommand -FileName 'aws' -Arguments $putMetricArgs -TimeoutSec $cfg.AwsCliTimeoutSec

    if ($putMetricResult.Ok -and ($putMetricResult.ExitCode -eq 0)) {
        Write-PreflightResult -Status 'PASS' -Name 'CloudWatch PutMetricData probe' `
            -Detail "Successfully put a value=0 'PreflightCanary' metric into namespace '$($cfg.MetricNamespace)'."
    }
    else {
        $putMetricErrText = "$($putMetricResult.StdOut)$($putMetricResult.StdErr)".Trim()
        if ([string]::IsNullOrWhiteSpace($putMetricErrText)) { $putMetricErrText = $putMetricResult.Error }
        Write-PreflightResult -Status 'WARN' -Name 'CloudWatch PutMetricData probe' `
            -Detail "DENIED or failed: $putMetricErrText -- This means the out-of-band CloudWatch idle-alarm safety net (Push-GpuMetric.ps1 + the alarm + the max-lifetime Lambda) will NOT work from this instance role. It must be fixed (grant cloudwatch:PutMetricData to the instance role) from an admin workstation before you rely on that safety net."
    }
}

# ---------------------------------------------------------------------------
# 10. SHUTDOWN BEHAVIOR (instanceInitiatedShutdownBehavior).
# ---------------------------------------------------------------------------

Write-Output ''
Write-Output '-- 10. *** SHUTDOWN BEHAVIOR *** --'

$shutdownBehaviorValue = $null

if (-not $awsCommand) {
    Write-PreflightResult -Status 'WARN' -Name 'SHUTDOWN BEHAVIOR (instanceInitiatedShutdownBehavior)' `
        -Detail "UNVERIFIED: 'aws' is not resolvable, so this cannot be probed. DryRun MUST remain `$true until it is verified from an admin workstation."
}
elseif ([string]::IsNullOrWhiteSpace($ec2Identity.InstanceId) -or [string]::IsNullOrWhiteSpace($ec2Identity.Region)) {
    Write-PreflightResult -Status 'WARN' -Name 'SHUTDOWN BEHAVIOR (instanceInitiatedShutdownBehavior)' `
        -Detail "UNVERIFIED: cannot probe without a known instance-id AND region (see the IMDS check above). DryRun MUST remain `$true until it is verified from an admin workstation."
}
else {
    $describeArgs = ConvertTo-AwsArgumentString -ArgumentList @(
        'ec2', 'describe-instance-attribute',
        '--instance-id', $ec2Identity.InstanceId,
        '--attribute', 'instanceInitiatedShutdownBehavior',
        '--region', $ec2Identity.Region,
        '--output', 'text'
    )
    $describeResult = Invoke-BoundedCommand -FileName 'aws' -Arguments $describeArgs -TimeoutSec $cfg.AwsCliTimeoutSec

    if ($describeResult.Ok -and ($describeResult.ExitCode -eq 0)) {
        # --output text prints e.g. "INSTANCEATTRIBUTE i-xxxx" then "stop"/"terminate" on their own
        # line(s); search the whole output case-insensitively rather than parse column position,
        # since the exact text layout is a CLI-version-dependent formatting detail this probe
        # should not be brittle against.
        if ($describeResult.StdOut -match '(?i)\bterminate\b') { $shutdownBehaviorValue = 'terminate' }
        elseif ($describeResult.StdOut -match '(?i)\bstop\b') { $shutdownBehaviorValue = 'stop' }
    }

    # StopStrategy (Config.ps1/Resolve-StopPlan) is read defensively -- like
    # WorkerNamesLike, it may not exist on every shape this config object has
    # taken. The "can this plan reach Stop-Computer?" question itself lives in
    # the pure Test-StopPlanCanReachGuestShutdown above (see its .DESCRIPTION
    # for why it is one function rather than two copies of the same expression).
    $stopStrategyValue = if ($cfg.PSObject.Properties.Name -contains 'StopStrategy') { $cfg.StopStrategy } else { $null }
    $canReachGuestShutdown = Test-StopPlanCanReachGuestShutdown -StopStrategy $stopStrategyValue
    $stopStrategyNote = if ($null -ne $stopStrategyValue) { " (StopStrategy='$stopStrategyValue')" } else { '' }

    if ($shutdownBehaviorValue -eq 'stop') {
        Write-PreflightResult -Status 'PASS' -Name 'SHUTDOWN BEHAVIOR (instanceInitiatedShutdownBehavior)' `
            -Detail "Confirmed 'stop'. A guest shutdown will STOP this instance, not terminate it$stopStrategyNote."
    }
    elseif ($shutdownBehaviorValue -eq 'terminate') {
        if ($canReachGuestShutdown) {
            Write-PreflightResult -Status 'FAIL' -Name 'SHUTDOWN BEHAVIOR (instanceInitiatedShutdownBehavior)' `
                -Detail "*** DANGER *** Confirmed 'terminate'$stopStrategyNote. Any code path that falls back to a guest shutdown (Stop-Computer) would DESTROY this instance, not stop it. Do NOT set DryRun=`$false until this is changed to 'stop' (see control-plane/01-set-shutdown-behavior.sh) from an admin workstation."
        }
        else {
            Write-PreflightResult -Status 'WARN' -Name 'SHUTDOWN BEHAVIOR (instanceInitiatedShutdownBehavior)' `
                -Detail "Confirmed 'terminate'$stopStrategyNote, but Resolve-StopPlan for 'Ec2ApiStop' alone never falls back to Stop-Computer, so this specific plan does not depend on it. Still dangerous if StopStrategy is ever changed to 'Auto' or 'GuestShutdown' without re-running this preflight."
        }
    }
    else {
        $describeErrText = "$($describeResult.StdOut)$($describeResult.StdErr)".Trim()
        if ([string]::IsNullOrWhiteSpace($describeErrText)) { $describeErrText = $describeResult.Error }
        if ($canReachGuestShutdown) {
            Write-PreflightResult -Status 'WARN' -Name 'SHUTDOWN BEHAVIOR (instanceInitiatedShutdownBehavior)' `
                -Detail "*** UNVERIFIED ***$stopStrategyNote describe-instance-attribute was DENIED or failed: $describeErrText -- Because this cannot be proven, DryRun MUST remain `$true. The operator MUST verify instanceInitiatedShutdownBehavior='stop' from an admin workstation with real credentials before ever setting DryRun=`$false. A denial here is the EXPECTED outcome while the instance role has no ec2:DescribeInstanceAttribute permission."
        }
        else {
            Write-PreflightResult -Status 'WARN' -Name 'SHUTDOWN BEHAVIOR (instanceInitiatedShutdownBehavior)' `
                -Detail "UNVERIFIED${stopStrategyNote}: describe-instance-attribute was DENIED or failed: $describeErrText -- Resolve-StopPlan for 'Ec2ApiStop' alone never falls back to Stop-Computer, so this specific plan does not depend on it. This preflight does NOT itself probe ec2:StopInstances permission (that would require actually attempting the stop API)."
        }
    }
}

# ---------------------------------------------------------------------------
# 11. DryRun state.
# ---------------------------------------------------------------------------

Write-Output ''
Write-Output '-- 11. DryRun state --'

$shutdownBehaviorDisplay = if ($null -eq $shutdownBehaviorValue) { 'UNVERIFIED' } else { $shutdownBehaviorValue }
$stopStrategyValue = if ($cfg.PSObject.Properties.Name -contains 'StopStrategy') { $cfg.StopStrategy } else { $null }
# Same predicate as check 10, deliberately -- these two checks disagreeing is
# how a 'terminate' box on an 'Auto' plan would slip through as a PASS.
$canReachGuestShutdown = Test-StopPlanCanReachGuestShutdown -StopStrategy $stopStrategyValue
$stopStrategyDisplay = if ($null -ne $stopStrategyValue) { $stopStrategyValue } else { '(not present in this config)' }

if ($cfg.DryRun) {
    Write-PreflightResult -Status 'PASS' -Name 'DryRun state' `
        -Detail "DryRun=`$true. The pipeline will log every decision but will NEVER power off the instance."
}
elseif (-not $canReachGuestShutdown) {
    Write-PreflightResult -Status 'PASS' -Name 'DryRun state' `
        -Detail "DryRun=`$false and StopStrategy='$stopStrategyDisplay' only -- Resolve-StopPlan never falls back to a guest shutdown for that value, so the shutdown-behavior check above does not gate this combination. (This preflight does NOT probe ec2:StopInstances permission itself; if that call is denied at stop time, Stop-Sequence.ps1 logs an error and the instance is simply left running -- a cost risk, not a destruction risk.)"
}
elseif ($shutdownBehaviorValue -eq 'stop') {
    Write-PreflightResult -Status 'PASS' -Name 'DryRun state' `
        -Detail "DryRun=`$false, StopStrategy='$stopStrategyDisplay' can reach a guest shutdown, and instanceInitiatedShutdownBehavior is confirmed 'stop'. A completed/stalled render will actually power off the guest, which stops (not terminates) the instance."
}
else {
    Write-PreflightResult -Status 'FAIL' -Name 'DryRun state' `
        -Detail "*** DANGEROUS COMBINATION *** DryRun=`$false, StopStrategy='$stopStrategyDisplay' CAN fall back to a guest shutdown (Stop-Computer), but check 10 above did NOT confirm 'stop' (shutdown behavior is '$shutdownBehaviorDisplay'). Arming a real power-off risks TERMINATING (destroying) this instance instead of stopping it. Set DryRun=`$true in Config.ps1 until shutdown behavior is verified from an admin workstation."
}

# ---------------------------------------------------------------------------
# 12. Scheduled tasks.
# ---------------------------------------------------------------------------

Write-Output ''
Write-Output '-- 12. Scheduled tasks --'

# The SCRATCH task is checked alongside the other two because its absence is
# invisible until the next boot: check 3's 'Config: OutputDir' PASSes on
# D:\Renders that exists right now, from this boot, while nothing would
# re-create it after the next stop wipes the instance store -- and then Topaz
# has nowhere to export and every stop is refused. Register-ScheduledTasks.ps1
# registers all three independently, so this really can be the one that failed.
#
# WARN, not FAIL, matching this check's existing convention: the preflight is
# documented as runnable BEFORE Register-ScheduledTasks.ps1, and a FAIL here
# would report NO-GO for the normal pre-registration run. The extra stakes go
# in the detail text instead.
$scratchTaskStakes = "This is the BOOT task that re-creates the instance-store scratch drive; the volume is wiped on every stop, so without it '$($cfg.OutputDir)' will not exist after the next start and every stop will be refused."

foreach ($taskName in @($cfg.WatchdogTaskName, $cfg.ScratchTaskName, $cfg.MetricTaskName)) {
    $taskStakes = if ($taskName -eq $cfg.ScratchTaskName) { " $scratchTaskStakes" } else { '' }
    try {
        $scheduledTask = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
        $scheduledTaskInfo = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction Stop
        Write-PreflightResult -Status 'PASS' -Name "Scheduled task '$taskName'" `
            -Detail "Registered. State=$($scheduledTask.State) LastRunTime=$($scheduledTaskInfo.LastRunTime) LastTaskResult=$($scheduledTaskInfo.LastTaskResult)."
    }
    catch {
        Write-PreflightResult -Status 'WARN' -Name "Scheduled task '$taskName'" `
            -Detail "Not registered (or could not be queried): $($_.Exception.Message). Run Register-ScheduledTasks.ps1 (elevated) before arming the pipeline.$taskStakes"
    }
}

# ---------------------------------------------------------------------------
# Summary + verdict.
# ---------------------------------------------------------------------------

Write-Output ''
Write-Output '===================================================================='
Write-Output 'SUMMARY'
Write-Output "  PASS : $script:PassCount"
Write-Output "  WARN : $script:WarnCount"
Write-Output "  FAIL : $script:FailCount"
Write-Output '===================================================================='

if ($script:FailCount -gt 0) {
    Write-Output 'VERDICT: NO-GO'
    Write-Output "$script:FailCount FAIL check(s) above must be resolved before arming the auto-stop pipeline (Register-ScheduledTasks.ps1 / DryRun=`$false)."
}
else {
    Write-Output 'VERDICT: GO'
    if ($script:WarnCount -gt 0) {
        Write-Output "$script:WarnCount WARN check(s) above are not individually blocking, but review them -- several point at incomplete external verification (CloudWatch permissions / shutdown behavior) that this box cannot fully self-certify from inside the guest."
    }
}

$preflightLogLevel = if ($script:FailCount -gt 0) { 'ERROR' } elseif ($script:WarnCount -gt 0) { 'WARN' } else { 'INFO' }
$preflightVerdict = if ($script:FailCount -gt 0) { 'NO-GO' } else { 'GO' }
Write-TopazLog -Component 'preflight' -Level $preflightLogLevel `
    -Message "Preflight verdict=$preflightVerdict pass=$script:PassCount warn=$script:WarnCount fail=$script:FailCount."

if ($script:FailCount -gt 0) {
    exit 1
}
exit 0
