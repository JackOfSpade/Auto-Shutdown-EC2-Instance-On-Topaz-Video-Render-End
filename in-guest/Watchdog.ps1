<#
.SYNOPSIS
    Detects when the Topaz render QUEUE finishes (or stalls) and hands off to
    the guest stop step.

.DESCRIPTION
    Runs as a SYSTEM scheduled task (see Register-ScheduledTasks.ps1). It never
    touches the Topaz CLI (EULA-forbidden). Instead it OBSERVES only:

        * the Topaz GUI process (matched via CIM Win32_Process LIKE pattern),
        * its child encoder worker(s) that actually encode a queued job (plus
          any worker ORPHANED by a crashed/closed Topaz GUI -- see
          Get-TopazWorkers below), and
        * (optionally) GPU utilization, and
        * the size of the output folder on disk.

    "Active render" is decided by CompletionSignal (Config.ps1):
        WorkerOnly  - a child encoder worker is present (most specific; default)
        GpuOnly     - GPU utilization >= GpuBusyPercent
        WorkerOrGpu - either of the above (most robust to Topaz process changes)

    Both the worker and GPU signals are three-valued ($true / $false / $null,
    where $null means "could not be read this poll"). When Test-RenderActive
    itself comes back $null (neither signal can be trusted), the watchdog
    freezes its idle/stall bookkeeping for that poll instead of guessing --
    see Resolve-RenderActive in Config.ps1 for the full truth table.

    A render queue is "complete" when it has been NOT active for DebounceSec
    (the debounce absorbs transient live-preview workers and short inter-clip
    lulls) AND at least one active period was seen. If a render is active but
    the output folder stops growing for StallSec, the job is treated as stalled
    and we stop anyway. After deciding to stop, it waits (up to UnlockTimeoutMin)
    for the finished output files to become unlocked, RE-VERIFIES a 'completed'
    decision once (in case the operator queued another export during that
    wait), and only then invokes Stop-Sequence.ps1. If Stop-Sequence.ps1 runs
    under DryRun, the watchdog re-arms and resumes monitoring instead of
    exiting for good.

    All configuration comes from Config.ps1 - nothing is hard-coded here.

.NOTES
    Target : Windows PowerShell 5.1 on Windows Server (EC2 GPU instance).
    Uses CIM (Get-CimInstance), not the deprecated Get-WmiObject.
#>

[CmdletBinding()]
param()

# --- Load shared config + helpers ------------------------------------------
. "$PSScriptRoot\Config.ps1"
$cfg = Get-TopazAutoStopConfig

# --- Orphan-worker tracking state -------------------------------------------
# Windows does not kill children when a parent process dies: if the Topaz GUI
# crashes or is closed mid-export, its ffmpeg child keeps encoding but would
# otherwise vanish the instant the GUI PID disappears from Get-TopazPids, and
# the watchdog would misread "no worker" as "queue complete" and power off
# mid-encode. This table remembers every worker process we have positively
# attributed to a live Topaz GUI PID at least once, keyed by
# "<PID>|<CreationDate.Ticks>" (CreationDate guards against PID reuse), so
# Get-TopazWorkers can keep counting an orphan as active until it actually
# exits. See Get-TopazWorkers below.
$script:KnownWorkers = @{}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Get-TopazPids {
    <#
    .SYNOPSIS
        Process IDs of every running Topaz GUI process.
    .DESCRIPTION
        Returns an array (possibly empty, when the query succeeded but found
        nothing) on success, or $null if the underlying CIM query itself
        failed. Callers MUST treat $null as "unknown", never as "no Topaz GUI
        running" -- see Get-TopazWorkers, which relies on that distinction to
        avoid mis-attributing orphaned workers.
    #>
    try {
        $procs = Get-CimInstance -ClassName Win32_Process `
            -Filter "Name LIKE '$($cfg.TopazNameLike)'" -ErrorAction Stop
        return @($procs | ForEach-Object { $_.ProcessId })
    }
    catch {
        Write-TopazLog -Component 'watchdog' -Level 'WARN' `
            -Message "Get-TopazPids failed: $($_.Exception.Message)"
        return $null
    }
}

function Get-TopazWorkers {
    <#
    .SYNOPSIS
        Encoder worker processes that count as an active render worker.
    .DESCRIPTION
        Runs the WorkerNameLike CIM query UNCONDITIONALLY -- even when the
        Topaz GUI PID list is empty or itself unreadable -- because an
        orphaned worker (see $script:KnownWorkers above) can still be
        encoding after its parent GUI process has exited or crashed.

        A worker process counts as an active render worker if:
          (a) its ParentProcessId is one of the CURRENT live Topaz GUI PIDs
              (also records it in $script:KnownWorkers), OR
          (b) its PID+CreationDate is already in $script:KnownWorkers (an
              orphan keeps counting after its parent GUI is gone).
        If the Topaz PID query itself failed ($null from Get-TopazPids),
        parent attribution is skipped (unknowable) and only KnownWorkers
        matches are counted.

        Returns:
          $null  - the worker CIM query itself failed, OR the Topaz PID query
                   failed AND no known orphan is alive to confirm activity
                   either way (genuinely unknown -- NOT "no worker").
          @()    - the worker query succeeded and nothing matched.
          array  - the worker query succeeded and found matching worker(s).
    #>
    $topazPids = Get-TopazPids   # $null = PID query failed (unknown), @() = none running

    try {
        $workers = @(Get-CimInstance -ClassName Win32_Process `
            -Filter "Name LIKE '$($cfg.WorkerNameLike)'" -ErrorAction Stop)
    }
    catch {
        Write-TopazLog -Component 'watchdog' -Level 'WARN' `
            -Message "Get-TopazWorkers failed: $($_.Exception.Message)"
        return $null
    }

    $matched  = New-Object System.Collections.Generic.List[object]
    $seenKeys = @{}

    foreach ($w in $workers) {
        $key = "$($w.ProcessId)|$($w.CreationDate.Ticks)"
        $seenKeys[$key] = $true

        if (($null -ne $topazPids) -and ($topazPids -contains $w.ParentProcessId)) {
            # A current child of a live Topaz GUI PID: adopt it as known.
            $script:KnownWorkers[$key] = $true
            $matched.Add($w)
        }
        elseif ($script:KnownWorkers.ContainsKey($key)) {
            # Not (currently provably) a child of a live GUI, but this exact
            # process (same PID + CreationDate) was adopted earlier: it is an
            # orphan that is still encoding after its parent GUI exited.
            $matched.Add($w)
        }
    }

    # The worker query succeeded, so any KnownWorkers entry that did not show
    # up in this poll's results has exited -- prune it, or a stale entry
    # would keep counting a long-gone process as an active worker forever.
    foreach ($key in @($script:KnownWorkers.Keys)) {
        if (-not $seenKeys.ContainsKey($key)) {
            $script:KnownWorkers.Remove($key)
        }
    }

    if (($null -eq $topazPids) -and ($matched.Count -eq 0)) {
        # PID query failed AND no known orphan is alive to confirm activity
        # either way: we genuinely cannot tell. Unknown, not "no worker".
        return $null
    }

    return @($matched)
}

function Get-OutputBytes {
    <#
    .SYNOPSIS
        Total size (bytes) of all files under the output directory, recursive.
        Returns 0 if the folder is missing or empty.
    #>
    if (-not (Test-Path -LiteralPath $cfg.OutputDir)) { return [int64]0 }

    $sum = (Get-ChildItem -LiteralPath $cfg.OutputDir -Recurse -File `
                -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum

    if ($null -eq $sum) { return [int64]0 }
    return [int64]$sum
}

function Test-FileUnlocked {
    <#
    .SYNOPSIS
        $true if the file can be opened for read with no sharing (i.e. nothing
        else holds a write/append handle on it), otherwise $false.
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

function Test-RenderActive {
    <#
    .SYNOPSIS
        Decide whether a render is currently active, per CompletionSignal.
    .DESCRIPTION
        Combines the worker-process signal and the GPU signal according to
        $cfg.CompletionSignal via the pure, unit-tested Resolve-RenderActive
        in Config.ps1. Both raw signals -- and the return value itself -- are
        three-valued ($true / $false / $null). $null means "could not be
        read/decided this poll"; callers must treat that as unknown and
        freeze rather than infer idle or active. Emits the raw inputs via
        [ref] params for logging.
    #>
    param(
        [Parameter(Mandatory)][ref]$WorkerActive,
        [Parameter(Mandatory)][ref]$GpuValue
    )

    $workers = Get-TopazWorkers
    $workerActive = if ($null -eq $workers) { $null } else { $workers.Count -gt 0 }
    $WorkerActive.Value = $workerActive

    # Only pay the nvidia-smi cost when the GPU signal is actually used.
    $gpu = $null
    if ($cfg.CompletionSignal -ne 'WorkerOnly') {
        $gpu = Get-GpuUtilizationMax
    }
    $GpuValue.Value = $gpu

    # Delegate the actual decision to the pure, unit-tested helper in Config.ps1.
    return Resolve-RenderActive -WorkerActive $workerActive -GpuUtil $gpu `
        -Signal $cfg.CompletionSignal -GpuBusyPercent $cfg.GpuBusyPercent
}

# ---------------------------------------------------------------------------
# 1. Wait for the Topaz GUI so we do not race its startup.
# ---------------------------------------------------------------------------

Write-TopazLog -Component 'watchdog' -Level 'INFO' `
    -Message "Watchdog starting. Signal=$($cfg.CompletionSignal). Waiting for a Topaz GUI process (LIKE '$($cfg.TopazNameLike)')."

# Get-TopazPids now returns $null on a CIM query failure (vs. @() for "query
# succeeded, nothing found"). Treat $null the same as "not seen yet" here and
# keep retrying -- testing $null.Count directly would silently treat a query
# failure as "0 found -> Topaz GUI detected", which is backwards.
while ($true) {
    $topazPids = Get-TopazPids
    if ($topazPids -and $topazPids.Count -gt 0) { break }
    Start-Sleep -Seconds $cfg.PollSec
}

Write-TopazLog -Component 'watchdog' -Level 'INFO' `
    -Message "Topaz GUI detected. Monitoring render queue (poll=$($cfg.PollSec)s, debounce=$($cfg.DebounceSec)s, stall=$($cfg.StallSec)s, worker LIKE '$($cfg.WorkerNameLike)')."

# ---------------------------------------------------------------------------
# 2-4. Monitor the queue, gate on unlocked outputs, then stop -- wrapped in an
#      outer loop so the watchdog RESUMES monitoring instead of exiting for
#      good when: (a) re-verifying a 'completed' decision finds the operator
#      queued another export during the debounce+unlock wait, or (b) the stop
#      step ran under DryRun (nothing would otherwise watch the next queue
#      until a reboot re-triggered the scheduled task).
# ---------------------------------------------------------------------------

$idleSec     = 0            # seconds with no active render
$stallSec    = 0            # seconds a render is active but output not growing
$sawActivity = $false       # have we ever observed an active render?
$lastBytes   = Get-OutputBytes

:outer while ($true) {

    $reason = 'completed'

    # ---------------------------------------------------------------------------
    # 2. Main monitoring loop.
    # ---------------------------------------------------------------------------

    while ($true) {
        Start-Sleep -Seconds $cfg.PollSec

        $workerActive = $null
        $gpuValue     = $null
        $active = Test-RenderActive -WorkerActive ([ref]$workerActive) -GpuValue ([ref]$gpuValue)
        $gpuText    = if ($null -eq $gpuValue) { 'n/a' } else { "$gpuValue%" }
        $workerText = if ($null -eq $workerActive) { 'unknown' } else { $workerActive }

        if ($null -eq $active) {
            # Neither signal could be trusted this poll (e.g. the worker CIM
            # query failed with no known orphan alive to confirm activity either
            # way, and/or the GPU read failed too). Do NOT touch idleSec/
            # stallSec/sawActivity/lastBytes on a blind poll: nudging idleSec
            # could false-complete a queue that is actually still rendering, and
            # nudging stallSec could false-stall a healthy one. Just wait for a
            # better read on the next poll.
            Write-TopazLog -Component 'watchdog' -Level 'WARN' `
                -Message "worker+GPU signals unreadable; freezing watchdog state this poll (worker=$workerText gpu=$gpuText)."
            continue
        }

        if ($active) {
            # A render is active: not idle. Record that a render actually began so
            # the completion path below may arm.
            $idleSec     = 0
            $sawActivity = $true

            $currentBytes = Get-OutputBytes
            if ($currentBytes -ne $lastBytes) {
                # Output changed (grew OR shrank) -> healthy, reset stall
                # tracking. A genuinely stalled worker writes nothing at all, so
                # ANY delta means it is alive. Comparing for growth-only left a
                # high-water-mark bug: when Topaz deletes a large _temp scratch
                # file the output folder can SHRINK, and a healthy next job
                # growing back up from that lower base could then sit under the
                # old high-water mark for the whole StallSec window and get
                # killed as "stalled" mid-render.
                $stallSec  = 0
                $lastBytes = $currentBytes
            }
            else {
                # Active but byte count unchanged -> accrue stall time.
                $stallSec += $cfg.PollSec
                Write-TopazLog -Component 'watchdog' -Level 'INFO' `
                    -Message "Render active (worker=$workerText gpu=$gpuText) but output not growing (stall=${stallSec}s / $($cfg.StallSec)s, bytes=$currentBytes)."

                if ($stallSec -ge $cfg.StallSec) {
                    Write-TopazLog -Component 'watchdog' -Level 'WARN' `
                        -Message "Output stalled for ${stallSec}s with an active render. Treating render as STALLED."
                    $reason = 'stalled'
                    break
                }
            }
        }
        else {
            # No active render. Could be between queue items or genuinely done.
            $stallSec = 0
            $idleSec += $cfg.PollSec

            if (-not $sawActivity) {
                # No render has started yet. "GUI up, nothing rendering" is also the
                # normal pre-render setup state (opening a project, adding clips,
                # configuring the export). Do NOT treat that as a completed queue,
                # or we would stop the instance before any render begins.
                Write-TopazLog -Component 'watchdog' -Level 'INFO' `
                    -Message "Topaz GUI up but no render has started yet (idle=${idleSec}s, worker=$workerText gpu=$gpuText). Waiting for the first render before arming completion."
            }
            else {
                Write-TopazLog -Component 'watchdog' -Level 'INFO' `
                    -Message "No active render (idle=${idleSec}s / $($cfg.DebounceSec)s debounce, worker=$workerText gpu=$gpuText)."

                if ($idleSec -ge $cfg.DebounceSec) {
                    Write-TopazLog -Component 'watchdog' -Level 'INFO' `
                        -Message "No active render for ${idleSec}s (>= debounce). Render QUEUE considered COMPLETE."
                    $reason = 'completed'
                    break
                }
            }
        }
    }

    # ---------------------------------------------------------------------------
    # 3. Confirm every finished output file is unlocked before we power off.
    #    Ignore Topaz scratch/temp files: name matches TempMarker ANCHORED via
    #    Test-TopazTempFile, so a real deliverable that merely CONTAINS the
    #    marker text (e.g. 'Reel_Template_Final.mp4') is not skipped.
    # ---------------------------------------------------------------------------

    Write-TopazLog -Component 'watchdog' -Level 'INFO' `
        -Message "Reason='$reason'. Waiting up to $($cfg.UnlockTimeoutMin) min for output files to unlock."

    $deadline = (Get-Date).AddMinutes($cfg.UnlockTimeoutMin)

    while ($true) {
        $locked = @()

        if (Test-Path -LiteralPath $cfg.OutputDir) {
            $candidates = Get-ChildItem -LiteralPath $cfg.OutputDir -Recurse -File `
                -ErrorAction SilentlyContinue |
                Where-Object { -not (Test-TopazTempFile -Name $_.Name -TempMarker $cfg.TempMarker) }

            foreach ($f in $candidates) {
                if (-not (Test-FileUnlocked -Path $f.FullName)) {
                    $locked += $f.FullName
                }
            }
        }

        if ($locked.Count -eq 0) {
            Write-TopazLog -Component 'watchdog' -Level 'INFO' `
                -Message "All output files are unlocked."
            break
        }

        if ((Get-Date) -ge $deadline) {
            Write-TopazLog -Component 'watchdog' -Level 'WARN' `
                -Message "Unlock wait timed out after $($cfg.UnlockTimeoutMin) min. Still locked: $($locked -join ', '). Proceeding with stop anyway."
            break
        }

        Start-Sleep -Seconds 10
    }

    # ---------------------------------------------------------------------------
    # 3b. Re-verify a 'completed' decision once: the operator may have queued
    #     another export while we were debouncing + waiting for the unlock gate
    #     above. A 'stalled' decision is NEVER re-verified here -- a stalled
    #     worker is still "active" by definition, so re-checking it would just
    #     loop this step forever instead of ever stopping.
    # ---------------------------------------------------------------------------

    if ($reason -eq 'completed') {
        $rvWorker = $null
        $rvGpu    = $null
        $reverify = Test-RenderActive -WorkerActive ([ref]$rvWorker) -GpuValue ([ref]$rvGpu)

        if ($reverify) {
            # Only a clean $true re-verify resumes monitoring. The original
            # completion decision was made on a clean $true/$false read (the
            # debounce loop above only breaks 'completed' when Test-RenderActive
            # returned $false), so an unreadable ($null) or still-inactive
            # ($false) re-check does not change the outcome -- fall through and
            # proceed to stop below.
            $rvGpuText    = if ($null -eq $rvGpu) { 'n/a' } else { "$rvGpu%" }
            $rvWorkerText = if ($null -eq $rvWorker) { 'unknown' } else { $rvWorker }
            Write-TopazLog -Component 'watchdog' -Level 'INFO' `
                -Message "Re-verify after the unlock gate found an active render (worker=$rvWorkerText gpu=$rvGpuText) -- another export was queued. Resuming monitoring instead of stopping."

            $idleSec     = 0
            $stallSec    = 0
            $sawActivity = $true
            $lastBytes   = Get-OutputBytes
            continue outer
        }
    }

    # ---------------------------------------------------------------------------
    # 4. Hand off to the stop step.
    # ---------------------------------------------------------------------------

    Write-TopazLog -Component 'watchdog' -Level 'INFO' `
        -Message "Invoking Stop-Sequence.ps1 (reason=$reason)."

    & (Join-Path $PSScriptRoot 'Stop-Sequence.ps1') -Reason $reason

    if ($cfg.DryRun) {
        # DryRun suppresses the actual power-off (see Stop-Sequence.ps1). Without
        # re-arming here the watchdog would just exit and nothing would watch the
        # next queue until a reboot re-triggered the scheduled task. Reset state
        # and go back to monitoring.
        Write-TopazLog -Component 'watchdog' -Level 'INFO' `
            -Message "DRY RUN: stop suppressed; re-arming for the next queue."

        $idleSec     = 0
        $stallSec    = 0
        $sawActivity = $false
        $lastBytes   = Get-OutputBytes
        continue outer
    }

    # Not a dry run: the instance is stopping. Let the script end.
    break outer

}
