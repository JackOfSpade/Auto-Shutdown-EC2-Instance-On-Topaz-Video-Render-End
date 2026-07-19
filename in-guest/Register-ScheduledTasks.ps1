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

# A missing installed script here means the task we are about to register
# would point at a nonexistent file -- silently falling through to "Both
# tasks registered." (the old behaviour) would tell the operator the
# pipeline is live when it cannot actually run. Escalate the same way the
# elevation check above does: throw and abort before registering anything.
$missingScripts = @()
if (-not (Test-Path -LiteralPath $watchdogScript)) { $missingScripts += $watchdogScript }
if (-not (Test-Path -LiteralPath $metricScript)) { $missingScripts += $metricScript }
if ($missingScripts.Count -gt 0) {
    $missingList = $missingScripts -join ', '
    Write-TopazLog -Component 'register' -Level 'ERROR' `
        -Message "Missing installed script(s): $missingList. Run Install.ps1 first so the tasks point at installed copies. Aborting."
    throw "Register-ScheduledTasks.ps1: missing installed script(s): $missingList. Run Install.ps1 first."
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
        same-name task, then register the supplied definition. Returns $true
        only once registration has been VERIFIED (Get-ScheduledTask finds the
        task afterwards); $false on any failure. Never throws -- the caller
        registers two independent tasks and one failing must not prevent the
        other attempt.
    #>
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)]$Action,
        [Parameter(Mandatory)]$Trigger,
        [Parameter(Mandatory)]$Settings,
        [Parameter(Mandatory)]$Principal,
        [Parameter(Mandatory)][string]$Description
    )

    try {
        $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($existing) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
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
            -Force -ErrorAction Stop | Out-Null

        # -ErrorAction SilentlyContinue (not Stop): on real Windows, a
        # not-found Get-ScheduledTask raises a non-terminating "No
        # MSFT_ScheduledTask objects found" error, which -ErrorAction Stop
        # would promote to terminating and route into the generic catch
        # below -- silently skipping the more specific diagnostic this
        # branch exists to log. SilentlyContinue lets a not-found result
        # actually flow through as $null so the check below can fire.
        $verify = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if (-not $verify) {
            Write-TopazLog -Component 'register' -Level 'ERROR' `
                -Message "Task '$TaskName' registration did not raise an error but Get-ScheduledTask could not find it afterwards."
            return $false
        }

        Write-TopazLog -Component 'register' -Level 'INFO' `
            -Message "Registered task '$TaskName'."
        return $true
    }
    catch {
        Write-TopazLog -Component 'register' -Level 'ERROR' `
            -Message "Failed to register task '$TaskName': $($_.Exception.Message)"
        return $false
    }
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

$watchdogRegistered = Register-PipelineTask `
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

# -ExecutionTimeLimit bounds a single run as OS-level defense-in-depth: even
# though Invoke-TopazAwsCli/Get-GpuUtilizationMax already bound their own
# child-process calls, a wedged run for any other reason (e.g. the PowerShell
# host itself hanging) would otherwise sit forever under MultipleInstances
# IgnoreNew, starving every future minute's run. 5 minutes is generous
# against a task that normally completes in seconds.
$metricSettings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

$metricRegistered = Register-PipelineTask `
    -TaskName $cfg.MetricTaskName `
    -Action $metricAction `
    -Trigger $metricTrigger `
    -Settings $metricSettings `
    -Principal $principalObj `
    -Description 'Topaz auto-stop GPU metric publisher: pushes GPU utilization to CloudWatch every minute.'

# ---------------------------------------------------------------------------
# Done. Both registrations were attempted independently above (one failing
# must not prevent the other attempt) -- report honestly which, if any,
# failed rather than claiming success regardless of outcome.
# ---------------------------------------------------------------------------

if ($watchdogRegistered -and $metricRegistered) {
    Write-TopazLog -Component 'register' -Level 'INFO' `
        -Message "Both tasks registered. Verify with:  Get-ScheduledTask -TaskName '$($cfg.WatchdogTaskName)','$($cfg.MetricTaskName)'  (and Get-ScheduledTaskInfo for last-run details)."
    exit 0
}

$failedTasks = @()
if (-not $watchdogRegistered) { $failedTasks += $cfg.WatchdogTaskName }
if (-not $metricRegistered) { $failedTasks += $cfg.MetricTaskName }

Write-TopazLog -Component 'register' -Level 'ERROR' `
    -Message "Registration failed for: $($failedTasks -join ', '). See the ERROR line(s) above for details. The pipeline is NOT fully live."
exit 1
