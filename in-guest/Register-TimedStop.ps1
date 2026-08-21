<#
.SYNOPSIS
    Registers a wall-clock hard stop: at a fixed time from now, stop this
    instance regardless of what the render queue is doing, RETRYING every
    RetryIntervalMinutes until a stop actually takes effect. Must be run
    ELEVATED. Idempotent.

.DESCRIPTION
    This is the in-guest stand-in for the optional max-lifetime Lambda in
    control-plane/04-deploy-max-lifetime-lambda.sh, for deployments where the
    AWS control plane cannot be reached from anywhere the operator currently
    is. It exists purely as a COST BACKSTOP.

    It registers a scheduled task that first runs, as SYSTEM, at (now + Hours)
    and then REPEATS every RetryIntervalMinutes until a stop actually takes
    effect (see the interlock note below -- a fired stop can be refused, and a
    task that fired once and gave up would be a cost cap that stopped capping).
    Each run invokes:

        Stop-Sequence.ps1 -Reason maxlifetime -IgnoreDryRun -ExitCodeOnRefusal

    -IgnoreDryRun is deliberate and is the whole point: the watchdog may still
    be running in DryRun while its detection logic is being validated, but the
    wall-clock backstop must actually stop the box or it is not a backstop.

    Stop-Sequence.ps1 then follows the configured StopStrategy, which by
    default tries ec2:StopInstances FIRST and falls back to a guest shutdown.
    That ordering matters here: only the API call provably ends billing, and
    the moment the instance role is granted ec2:StopInstances this task starts
    doing the right thing with no change to any of these scripts.

    *** THIS TASK IS BLIND TO RENDER PROGRESS. *** It does not consult
    Get-TopazWorkers, GPU utilization, or anything else the watchdog uses to
    decide whether a render is still going. When the clock runs out it stops
    the instance, and if a render is still running that render dies with it.
    The debounce, stall detector, unlock gate and re-verify are all bypassed by
    design, because a backstop that can be talked out of firing is not a
    backstop.

    ONE GUARD IS NOT BYPASSED, DELIBERATELY. Stop-Sequence.ps1's ephemeral
    upload interlock still applies: if OutputDir sits on the instance-store
    scratch volume and the finished renders in it have not been uploaded and
    verified, the stop is REFUSED even here. Erasing a completed render to save
    a few dollars of instance time is not a trade this project makes, so the
    cost cap yields to it.

    That means the cap is not absolute, and this task is therefore registered
    with a REPEATING trigger rather than as a one-shot: a refused stop is
    retried on RetryIntervalMinutes until it succeeds. A one-shot task that
    fired once, got refused, and never tried again would be a cost cap that
    silently did not cap anything.

    That is not theoretical: on this deployment a 4-hour timed stop was once
    armed against a render that was still running four hours later, and was
    cancelled with 16 minutes to spare. Size -Hours against the SLOWEST render
    you might plausibly queue, not the typical one, and prefer cancelling it
    once the watchdog itself is armed and verified.

    IMPORTANT LIMITATION. If the instance role does NOT grant
    ec2:StopInstances, and InstanceInitiatedShutdownBehavior is not 'stop',
    then this task will power the guest off without stopping the instance, and
    AWS will keep billing it. This script cannot detect that from inside the
    guest; run Test-Deployment.ps1 to see which stop paths are actually
    available.

.PARAMETER Hours
    How many hours from now to fire. Default 4.

.PARAMETER Cancel
    Remove any previously registered timed stop and exit without registering
    a new one.

.EXAMPLE
    .\Register-TimedStop.ps1
    Stops the instance 4 hours from now.

.EXAMPLE
    .\Register-TimedStop.ps1 -Hours 2

.EXAMPLE
    .\Register-TimedStop.ps1 -Cancel

.NOTES
    Target : Windows PowerShell 5.1 on Windows Server (EC2 GPU instance).
    Run from an elevated (Administrator) PowerShell.
    Inspect afterwards with:
        Get-ScheduledTask -TaskName 'TopazAutoStop-TimedStop' | Get-ScheduledTaskInfo

    READING LastTaskResult. The action passes -ExitCodeOnRefusal, so the task's
    exit code carries the outcome instead of hiding it:
        0 - the stop was performed (or deliberately suppressed by DryRun).
        2 - the stop was REFUSED (upload interlock, final completion gate, or
            every action in the stop plan failing). The box is still running
            and this task will try again on the next repetition. See stop.log
            for WHICH guard fired.
    Without that switch a refusal reported 0 -- "success" -- for a cost
    backstop that had not stopped anything and was about to keep not stopping
    it every RetryIntervalMinutes.
#>

[CmdletBinding()]
param(
    [ValidateRange(1, 168)]
    [double]$Hours = 4,

    # How often to retry after a REFUSED stop (see the interlock note in
    # .DESCRIPTION). Once a stop actually succeeds the instance is gone and the
    # repetition dies with it, so this only ever runs on the refusal path.
    [ValidateRange(5, 720)]
    [int]$RetryIntervalMinutes = 15,

    [switch]$Cancel
)

# --- Load shared config + logging ------------------------------------------
. "$PSScriptRoot\Config.ps1"
$cfg = Get-TopazAutoStopConfig

# ---------------------------------------------------------------------------
# Elevation check (registering a SYSTEM task requires admin).
# ---------------------------------------------------------------------------

$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-TopazLog -Component 'timedstop' -Level 'ERROR' `
        -Message "This script must be run from an ELEVATED (Administrator) PowerShell. Aborting."
    throw "Register-TimedStop.ps1 requires elevation."
}

$taskName = $cfg.TimedStopTaskName

# ---------------------------------------------------------------------------
# Cancel path.
# ---------------------------------------------------------------------------

if ($Cancel) {
    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
        Write-TopazLog -Component 'timedstop' -Level 'INFO' `
            -Message "Cancelled the timed stop: removed task '$taskName'."
    }
    else {
        Write-TopazLog -Component 'timedstop' -Level 'INFO' `
            -Message "No timed stop was registered (no task '$taskName'); nothing to cancel."
    }
    return
}

# ---------------------------------------------------------------------------
# The stop script must be the INSTALLED copy, not the repo checkout: the repo
# directory may be moved, edited, or deleted between now and when this fires,
# and a task pointing at a vanished script is a backstop that silently is not
# one.
# ---------------------------------------------------------------------------

$stopScript = Join-Path $cfg.InstallDir 'Stop-Sequence.ps1'

# Config.ps1 is checked alongside it because Stop-Sequence.ps1 dot-sources
# "$PSScriptRoot\Config.ps1" by literal name on its first executable line: an
# InstallDir holding the stop script but not its config is a backstop that
# throws on load and stops nothing, which is indistinguishable from a healthy
# one until the deadline passes. Install.ps1 does not abort on a failed copy,
# so that state is reachable.
$stopConfigScript = Join-Path $cfg.InstallDir 'Config.ps1'

$missingStopScripts = @()
if (-not (Test-Path -LiteralPath $stopScript)) { $missingStopScripts += $stopScript }
if (-not (Test-Path -LiteralPath $stopConfigScript)) { $missingStopScripts += $stopConfigScript }
if ($missingStopScripts.Count -gt 0) {
    $missingStopList = $missingStopScripts -join ', '
    Write-TopazLog -Component 'timedstop' -Level 'ERROR' `
        -Message "Missing installed script(s): $missingStopList. Run Install.ps1 first so the task points at a complete installed copy. Aborting."
    throw "Register-TimedStop.ps1: missing installed script(s): $missingStopList. Run Install.ps1 first."
}

$fireAt = (Get-Date).AddHours($Hours)

# -ExitCodeOnRefusal is passed ONLY here, never on the watchdog's own call.
# Under -File, Stop-Sequence.ps1's `return $false` refusal is just an object
# written to stdout: the host prints 'False' and exits 0, so
# Get-ScheduledTaskInfo (which .NOTES sends the operator to) reported
# LastTaskResult=0 -- success -- for a backstop that had refused to stop the
# box and would keep refusing. The switch makes THIS invocation translate the
# refusal into exit 2 while leaving Watchdog.ps1's `& <script>` call returning
# a bare $false, which is the value its re-arm branch tests with `-eq $false`.
$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument ("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"{0}`" -Reason maxlifetime -IgnoreDryRun -ExitCodeOnRefusal" -f $stopScript)

# Repeating, not one-shot. See .DESCRIPTION: the ephemeral upload interlock can
# REFUSE this stop, and a one-shot task would then never try again -- a cost cap
# that silently stopped capping. A repetition cannot be literally infinite, so
# ~10000 days stands in for "until it succeeds"; the successful stop ends the
# instance and the repetition with it.
$trigger = New-ScheduledTaskTrigger -Once -At $fireAt
$retryTrigger = New-ScheduledTaskTrigger -Once -At $fireAt `
    -RepetitionInterval (New-TimeSpan -Minutes $RetryIntervalMinutes) `
    -RepetitionDuration (New-TimeSpan -Days 10000)
$trigger.Repetition = $retryTrigger.Repetition

$principalObj = New-ScheduledTaskPrincipal `
    -UserId 'SYSTEM' `
    -LogonType ServiceAccount `
    -RunLevel Highest

# StartWhenAvailable matters: if the box happens to be asleep/busy at the
# scheduled moment, we still want the stop to run as soon as it can rather
# than being skipped outright. ExecutionTimeLimit is derived from every
# bounded operation in Stop-Sequence -- especially the default four-hour
# upload/check attempts and completed-stop final verification -- so Task
# Scheduler cannot kill a legitimate transfer before the stop action is
# reached.
$executionTimeLimit = Get-TopazStopSequenceExecutionTimeLimit -Config $cfg
$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit $executionTimeLimit

try {
    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
        Write-TopazLog -Component 'timedstop' -Level 'INFO' `
            -Message "Removed existing task '$taskName' before re-registering."
    }

    Register-ScheduledTask `
        -TaskName $taskName `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -Principal $principalObj `
        -Description "Topaz auto-stop wall-clock backstop: stops this instance at $($fireAt.ToString('yyyy-MM-dd HH:mm:ss zzz')) regardless of render state." `
        -Force -ErrorAction Stop | Out-Null

    # -ErrorAction SilentlyContinue (not Stop): a not-found Get-ScheduledTask
    # raises a NON-terminating error on real Windows, which -ErrorAction Stop
    # would promote into the generic catch below and hide this more specific
    # diagnostic. See Register-ScheduledTasks.ps1 for the same reasoning.
    $verify = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if (-not $verify) {
        Write-TopazLog -Component 'timedstop' -Level 'ERROR' `
            -Message "Task '$taskName' registration did not raise an error but Get-ScheduledTask could not find it afterwards."
        throw "Register-TimedStop.ps1: registration could not be verified."
    }

    # The fire time carries its UTC offset. Without it this line holds TWO
    # timestamps -- Write-TopazLog's own stamp and this embedded $fireAt -- that
    # look structurally identical, so a reader has no way to tell whether the
    # deadline is quoted in the same zone as the line it sits on. This is a
    # COST CAP; misreading it by a whole timezone is expensive in exactly the
    # direction nobody notices until the bill arrives.
    Write-TopazLog -Component 'timedstop' -Level 'INFO' `
        -Message "Timed stop ARMED: task '$taskName' will run Stop-Sequence.ps1 -Reason maxlifetime -IgnoreDryRun -ExitCodeOnRefusal at $($fireAt.ToString('yyyy-MM-dd HH:mm:ss zzz')) (in $Hours h), then retry every $RetryIntervalMinutes min while the stop is refused (LastTaskResult=2)."

    Write-Output ""
    Write-Output "  Timed stop armed"
    Write-Output "  ----------------"
    Write-Output "  Task        : $taskName"
    Write-Output "  Fires at    : $($fireAt.ToString('yyyy-MM-dd HH:mm:ss zzz')) (local)  -- in $Hours hour(s)"
    Write-Output "  Retries     : every $RetryIntervalMinutes min if the stop is REFUSED"
    Write-Output "                (the upload interlock can refuse it; see stop.log)"
    Write-Output "  Action      : Stop-Sequence.ps1 -Reason maxlifetime -IgnoreDryRun -ExitCodeOnRefusal"
    Write-Output "  Refusals    : show as LastTaskResult=2 in Get-ScheduledTaskInfo (0 = stopped)"
    Write-Output "  Max runtime : $executionTimeLimit per invocation (derived from configured sync/upload/stop bounds)"
    Write-Output "  StopStrategy: $($cfg.StopStrategy)  (plan: $((Resolve-StopPlan -Strategy $cfg.StopStrategy) -join ' -> '))"
    Write-Output ""
    Write-Output "  Cancel with :  .\Register-TimedStop.ps1 -Cancel"
    Write-Output ""
    Write-Output "  WARNING: this fires on the clock and is BLIND to render state. If a render"
    Write-Output "           is still running at that moment, it is killed. Cancel this once the"
    Write-Output "           watchdog is armed and verified."
    Write-Output ""

    # Surface any render that is live RIGHT NOW, so the operator sizing -Hours
    # can see what they are gambling against instead of having to guess.
    try {
        $liveWorkers = @(Get-CimInstance -ClassName Win32_Process `
            -Filter (Build-WorkerWqlFilter -Patterns $cfg.WorkerNamesLike) `
            -OperationTimeoutSec 15 -ErrorAction Stop)
        if ($liveWorkers.Count -gt 0) {
            Write-Output "  NOTE: a render appears to be ACTIVE right now -"
            foreach ($lw in $liveWorkers) {
                Write-Output ("         {0} (pid {1}, started {2})" -f $lw.Name, $lw.ProcessId, $lw.CreationDate)
            }
            Write-Output "         Make sure $Hours h is comfortably longer than it needs to finish."
            Write-Output ""
        }
    }
    catch {
        # Also persist it. This is a genuine caught failure, and the console is
        # not a record: if the courtesy check cannot see the process table, the
        # operator is arming a wall-clock stop WITHOUT the one warning that
        # would have told them a render is already running.
        Write-TopazLog -Component 'timedstop' -Level 'WARN' `
            -Message "Could not check for a live render before arming the timed stop: $($_.Exception.Message). The $Hours h deadline was set WITHOUT confirming whether a render is currently in progress."
        Write-Output "  (could not check for a live render: $($_.Exception.Message))"
        Write-Output ""
    }
}
catch {
    Write-TopazLog -Component 'timedstop' -Level 'ERROR' `
        -Message "Failed to register timed stop '$taskName': $($_.Exception.Message)"
    throw
}
