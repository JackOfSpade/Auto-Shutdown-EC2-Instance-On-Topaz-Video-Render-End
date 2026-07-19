<#
.SYNOPSIS
    Registers the two SYSTEM scheduled tasks for the Topaz auto-stop pipeline.
    Must be run ELEVATED. Idempotent.

.DESCRIPTION
    Creates (or re-creates) two scheduled tasks that run as the SYSTEM account:

        * Watchdog task   - runs Watchdog.ps1 at system startup, unlimited run
          time, so it is always watching for a completed/stalled render queue.
        * GPU metric task - runs Push-GpuMetric.ps1 once per minute forever, to
          feed the out-of-band CloudWatch idle alarm.

    SYSTEM is chosen because it holds SeShutdownPrivilege (needed for the guest
    shutdown that stops the instance) and can enumerate user-session processes
    via CIM (so the watchdog can see the Topaz GUI + its ffmpeg children even
    though those run in an interactive user session).

    The tasks point at the INSTALLED copies under InstallDir (see Install.ps1),
    not at the repo checkout. Re-running this script unregisters any existing
    same-name task first, so it is safe to run repeatedly.

.NOTES
    Target : Windows PowerShell 5.1 on Windows Server (EC2 GPU instance).
    Run from an elevated (Administrator) PowerShell:  .\Register-ScheduledTasks.ps1
    Verify afterwards with:  Get-ScheduledTask -TaskName 'TopazAutoStop-*'
#>

[CmdletBinding()]
param()

# --- Load shared config + logging ------------------------------------------
. "$PSScriptRoot\Config.ps1"
$cfg = Get-TopazAutoStopConfig

# ---------------------------------------------------------------------------
# Elevation check (registering a SYSTEM task requires admin).
# ---------------------------------------------------------------------------

$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-TopazLog -Component 'register' -Level 'ERROR' `
        -Message "This script must be run from an ELEVATED (Administrator) PowerShell. Aborting."
    throw "Register-ScheduledTasks.ps1 requires elevation."
}

$watchdogScript = Join-Path $cfg.InstallDir 'Watchdog.ps1'
$metricScript   = Join-Path $cfg.InstallDir 'Push-GpuMetric.ps1'

if (-not (Test-Path -LiteralPath $watchdogScript)) {
    Write-TopazLog -Component 'register' -Level 'WARN' `
        -Message "Expected '$watchdogScript' not found. Run Install.ps1 first so the task points at an installed copy."
}
if (-not (Test-Path -LiteralPath $metricScript)) {
    Write-TopazLog -Component 'register' -Level 'WARN' `
        -Message "Expected '$metricScript' not found. Run Install.ps1 first so the task points at an installed copy."
}

# ---------------------------------------------------------------------------
# Shared principal: run as SYSTEM, highest privileges.
# ---------------------------------------------------------------------------

$principalObj = New-ScheduledTaskPrincipal `
    -UserId 'SYSTEM' `
    -LogonType ServiceAccount `
    -RunLevel Highest

function Register-PipelineTask {
    <#
    .SYNOPSIS
        Idempotently (re)registers one scheduled task: unregister any existing
        same-name task, then register the supplied definition.
    #>
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)]$Action,
        [Parameter(Mandatory)]$Trigger,
        [Parameter(Mandatory)]$Settings,
        [Parameter(Mandatory)]$Principal,
        [Parameter(Mandatory)][string]$Description
    )

    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-TopazLog -Component 'register' -Level 'INFO' `
            -Message "Removed existing task '$TaskName' before re-registering."
    }

    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $Action `
        -Trigger $Trigger `
        -Settings $Settings `
        -Principal $Principal `
        -Description $Description `
        -Force | Out-Null

    Write-TopazLog -Component 'register' -Level 'INFO' `
        -Message "Registered task '$TaskName'."
}

# ---------------------------------------------------------------------------
# 1. Watchdog task - runs at startup, unlimited run time.
# ---------------------------------------------------------------------------

$watchdogAction = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument ("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"{0}`"" -f $watchdogScript)

$watchdogTrigger = New-ScheduledTaskTrigger -AtStartup

# ExecutionTimeLimit=Zero means no time limit (the watchdog runs indefinitely).
# RestartCount/RestartInterval: the watchdog is the PRIMARY stop path - the
# CloudWatch idle alarm is only a cost backstop, not a substitute. Without a
# restart policy a crashed watchdog process stays dead until the next reboot,
# silently disabling auto-stop for the rest of the render. Task Scheduler will
# retry a failed run up to 3 times, one minute apart, before giving up.
$watchdogSettings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

Register-PipelineTask `
    -TaskName $cfg.WatchdogTaskName `
    -Action $watchdogAction `
    -Trigger $watchdogTrigger `
    -Settings $watchdogSettings `
    -Principal $principalObj `
    -Description 'Topaz auto-stop watchdog: stops the instance when the render queue finishes or stalls.'

# ---------------------------------------------------------------------------
# 2. GPU metric task - runs every minute forever.
# ---------------------------------------------------------------------------

$metricAction = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument ("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"{0}`"" -f $metricScript)

# New-ScheduledTaskTrigger has no "-RepetitionInterval" on all Win Server SKUs
# in the -Once form, and a repetition needs BOTH an interval AND a duration.
# Quirk: a repetition "duration" cannot be literally infinite, so we build a
# -Once trigger and then attach a repetition with a 1-minute interval and an
# effectively-forever duration (~10000 days). Task Scheduler treats such a very
# long duration as "repeat indefinitely", giving us a once-per-minute loop.
$metricTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date)
$repetition = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 1) `
    -RepetitionDuration (New-TimeSpan -Days 10000)
$metricTrigger.Repetition = $repetition.Repetition

$metricSettings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew   # skip a run if the previous minute is still going.

Register-PipelineTask `
    -TaskName $cfg.MetricTaskName `
    -Action $metricAction `
    -Trigger $metricTrigger `
    -Settings $metricSettings `
    -Principal $principalObj `
    -Description 'Topaz auto-stop GPU metric publisher: pushes GPU utilization to CloudWatch every minute.'

# ---------------------------------------------------------------------------
# Done.
# ---------------------------------------------------------------------------

Write-TopazLog -Component 'register' -Level 'INFO' `
    -Message "Both tasks registered. Verify with:  Get-ScheduledTask -TaskName '$($cfg.WatchdogTaskName)','$($cfg.MetricTaskName)'  (and Get-ScheduledTaskInfo for last-run details)."
