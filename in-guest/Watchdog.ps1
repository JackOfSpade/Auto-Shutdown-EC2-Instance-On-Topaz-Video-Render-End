<#
.SYNOPSIS
    Detects when the Topaz render QUEUE finishes (or stalls) and hands off to
    the guest stop step.

.DESCRIPTION
    Runs as a SYSTEM scheduled task (see Register-ScheduledTasks.ps1). It never
    touches the Topaz CLI (EULA-forbidden). Instead it OBSERVES only:

        * the Topaz GUI process (matched via CIM Win32_Process LIKE pattern),
        * its child ffmpeg.exe worker(s) that actually encode a queued job, and
        * the size of the output folder on disk.

    A render queue is "complete" when the GUI is still alive but no ffmpeg
    worker has existed for DebounceSec (the debounce absorbs transient
    live-preview ffmpeg children). If an ffmpeg worker is alive but the output
    folder stops growing for StallSec, the job is treated as stalled and we stop
    anyway. After deciding to stop, it waits (up to UnlockTimeoutMin) for the
    finished output files to become unlocked, then invokes Stop-Sequence.ps1.

    All configuration comes from Config.ps1 - nothing is hard-coded here.

.NOTES
    Target : Windows PowerShell 5.1 on Windows Server (EC2 GPU instance).
    Author : Topaz auto-stop pipeline.
    Uses CIM (Get-CimInstance), not the deprecated Get-WmiObject.
#>

[CmdletBinding()]
param()

# --- Load shared config + logging ------------------------------------------
. "$PSScriptRoot\Config.ps1"
$cfg = Get-TopazAutoStopConfig

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Get-TopazPids {
    <#
    .SYNOPSIS
        Process IDs of every running Topaz GUI process. Returns an array
        (possibly empty) so callers can safely enumerate / test .Count.
    #>
    try {
        $procs = Get-CimInstance -ClassName Win32_Process `
            -Filter "Name LIKE '$($cfg.TopazNameLike)'" -ErrorAction Stop
        return @($procs | ForEach-Object { $_.ProcessId })
    }
    catch {
        Write-TopazLog -Component 'watchdog' -Level 'WARN' `
            -Message "Get-TopazPids failed: $($_.Exception.Message)"
        return @()
    }
}

function Get-TopazFfmpeg {
    <#
    .SYNOPSIS
        ffmpeg.exe processes whose parent is one of the current Topaz GUI
        processes. Returns an empty array when Topaz is not running.
    #>
    $topazPids = Get-TopazPids
    if (-not $topazPids -or $topazPids.Count -eq 0) { return @() }

    try {
        $ffmpeg = Get-CimInstance -ClassName Win32_Process `
            -Filter "Name = 'ffmpeg.exe'" -ErrorAction Stop
        return @($ffmpeg | Where-Object { $topazPids -contains $_.ParentProcessId })
    }
    catch {
        Write-TopazLog -Component 'watchdog' -Level 'WARN' `
            -Message "Get-TopazFfmpeg failed: $($_.Exception.Message)"
        return @()
    }
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

# ---------------------------------------------------------------------------
# 1. Wait for the Topaz GUI so we do not race its startup.
# ---------------------------------------------------------------------------

Write-TopazLog -Component 'watchdog' -Level 'INFO' `
    -Message "Watchdog starting. Waiting for a Topaz GUI process (LIKE '$($cfg.TopazNameLike)')."

while ((Get-TopazPids).Count -eq 0) {
    Start-Sleep -Seconds $cfg.PollSec
}

Write-TopazLog -Component 'watchdog' -Level 'INFO' `
    -Message "Topaz GUI detected. Monitoring render queue (poll=$($cfg.PollSec)s, debounce=$($cfg.DebounceSec)s, stall=$($cfg.StallSec)s)."

# ---------------------------------------------------------------------------
# 2. Main monitoring loop.
# ---------------------------------------------------------------------------

$reason      = 'completed'
$idleSec     = 0            # seconds with a Topaz GUI but no ffmpeg worker
$stallSec    = 0            # seconds an ffmpeg worker is alive but output not growing
$sawWorker   = $false       # have we ever observed a real ffmpeg encode worker?
$lastBytes   = Get-OutputBytes

while ($true) {
    Start-Sleep -Seconds $cfg.PollSec

    $workers = Get-TopazFfmpeg

    if ($workers.Count -gt 0) {
        # A real encode worker is alive: not idle. Record that a render has
        # actually begun so the completion path below may arm.
        $idleSec   = 0
        $sawWorker = $true

        $currentBytes = Get-OutputBytes
        if ($currentBytes -gt $lastBytes) {
            # Output is growing -> healthy, reset stall tracking.
            $stallSec  = 0
            $lastBytes = $currentBytes
        }
        else {
            # Worker alive but no growth -> accrue stall time.
            $stallSec += $cfg.PollSec
            Write-TopazLog -Component 'watchdog' -Level 'INFO' `
                -Message "ffmpeg worker alive but output not growing (stall=${stallSec}s / $($cfg.StallSec)s, bytes=$currentBytes)."

            if ($stallSec -ge $cfg.StallSec) {
                Write-TopazLog -Component 'watchdog' -Level 'WARN' `
                    -Message "Output stalled for ${stallSec}s with a live ffmpeg worker. Treating render as STALLED."
                $reason = 'stalled'
                break
            }
        }
    }
    else {
        # No ffmpeg worker. Could be between queue items or genuinely done.
        $stallSec = 0
        $idleSec += $cfg.PollSec

        if (-not $sawWorker) {
            # No render has started yet. "GUI up, no ffmpeg worker" is also the
            # normal pre-render setup state (opening a project, adding clips,
            # configuring the export). Do NOT treat that as a completed queue,
            # or we would stop the instance before any render begins.
            Write-TopazLog -Component 'watchdog' -Level 'INFO' `
                -Message "Topaz GUI up but no ffmpeg worker has started yet (idle=${idleSec}s). Waiting for the first render before arming completion."
        }
        else {
            Write-TopazLog -Component 'watchdog' -Level 'INFO' `
                -Message "No ffmpeg worker (idle=${idleSec}s / $($cfg.DebounceSec)s debounce)."

            if ($idleSec -ge $cfg.DebounceSec) {
                Write-TopazLog -Component 'watchdog' -Level 'INFO' `
                    -Message "No ffmpeg worker for ${idleSec}s (>= debounce). Render QUEUE considered COMPLETE."
                $reason = 'completed'
                break
            }
        }
    }
}

# ---------------------------------------------------------------------------
# 3. Confirm every finished output file is unlocked before we power off.
#    Ignore Topaz scratch/temp files (name contains TempMarker).
# ---------------------------------------------------------------------------

Write-TopazLog -Component 'watchdog' -Level 'INFO' `
    -Message "Reason='$reason'. Waiting up to $($cfg.UnlockTimeoutMin) min for output files to unlock."

$deadline = (Get-Date).AddMinutes($cfg.UnlockTimeoutMin)

while ($true) {
    $locked = @()

    if (Test-Path -LiteralPath $cfg.OutputDir) {
        $candidates = Get-ChildItem -LiteralPath $cfg.OutputDir -Recurse -File `
            -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike "*$($cfg.TempMarker)*" }

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
# 4. Hand off to the stop step.
# ---------------------------------------------------------------------------

Write-TopazLog -Component 'watchdog' -Level 'INFO' `
    -Message "Invoking Stop-Sequence.ps1 (reason=$reason)."

& (Join-Path $PSScriptRoot 'Stop-Sequence.ps1') -Reason $reason
