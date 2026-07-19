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
        # The leading unary comma is required, not decorative: PowerShell's
        # pipeline/return semantics collapse a returned array to a SCALAR when
        # it has exactly one element, and to $null when it has ZERO elements
        # (even through a chain of nested "return" calls). Without the comma,
        # the legitimate "query succeeded, found zero Topaz GUI processes"
        # case would be indistinguishable from a failed query to every caller
        # -- exactly the null-vs-empty distinction this function's contract
        # depends on.
        return , @($procs | ForEach-Object { $_.ProcessId })
    }
    catch {
        Write-TopazLog -Component 'watchdog' -Level 'WARN' `
            -Message "Get-TopazPids failed: $($_.Exception.Message)"
        return $null
    }
}

function Resolve-WorkerAttribution {
    <#
    .SYNOPSIS
        Pure matching/adoption/pruning: which of this poll's worker processes
        count as an active render worker, given the current Topaz GUI PIDs.
    .DESCRIPTION
        Extracted from Get-TopazWorkers so the attribution logic (adoption of
        a live GUI's children, orphan survival, and pruning of exited
        workers) is independently unit-testable, with no CIM calls of its
        own.

        MUTATES $KnownWorkers IN PLACE -- hashtables are reference types in
        PowerShell, so the caller's table is updated directly (adopted keys
        added, exited keys removed), not a copy. Callers must pass the SAME
        $script:KnownWorkers table across polls for orphan survival to work.

        A worker process counts as an active render worker if:
          (a) its ParentProcessId is one of the CURRENT live Topaz GUI PIDs
              (also records it in $KnownWorkers), OR
          (b) its PID+CreationDate is already in $KnownWorkers (an orphan
              keeps counting after its parent GUI is gone).
        If $TopazPids is $null (the PID query itself failed), parent
        attribution is skipped (unknowable) and only KnownWorkers matches are
        counted.
    .PARAMETER TopazPids
        $null = the Topaz GUI PID query failed (unknown); @() = it succeeded
        and found none running; array = the live GUI PIDs.
    .PARAMETER Workers
        This poll's worker processes (already CIM-queried by the caller);
        each needs .ProcessId, .ParentProcessId, .CreationDate.
    .PARAMETER KnownWorkers
        The running table of previously-adopted "<PID>|<CreationDate.Ticks>"
        keys, mutated in place (see above).
    .OUTPUTS
        $null  - $TopazPids was $null AND no known orphan is alive to confirm
                 activity either way (genuinely unknown -- NOT "no worker").
        @()    - $Workers had nothing that matched, and TopazPids was known.
        array  - the matched worker(s).
    #>
    param(
        [AllowNull()]$TopazPids,
        [AllowEmptyCollection()][array]$Workers,
        [Parameter(Mandatory)][hashtable]$KnownWorkers
    )

    $matched  = New-Object System.Collections.Generic.List[object]
    $seenKeys = @{}

    foreach ($w in $Workers) {
        $key = "$($w.ProcessId)|$($w.CreationDate.Ticks)"
        $seenKeys[$key] = $true

        if (($null -ne $TopazPids) -and ($TopazPids -contains $w.ParentProcessId)) {
            # A current child of a live Topaz GUI PID: adopt it as known.
            $KnownWorkers[$key] = $true
            $matched.Add($w)
        }
        elseif ($KnownWorkers.ContainsKey($key)) {
            # Not (currently provably) a child of a live GUI, but this exact
            # process (same PID + CreationDate) was adopted earlier: it is an
            # orphan that is still encoding after its parent GUI exited.
            $matched.Add($w)
        }
    }

    # The worker query succeeded, so any KnownWorkers entry that did not show
    # up in this poll's results has exited -- prune it, or a stale entry
    # would keep counting a long-gone process as an active worker forever.
    foreach ($key in @($KnownWorkers.Keys)) {
        if (-not $seenKeys.ContainsKey($key)) {
            $KnownWorkers.Remove($key)
        }
    }

    if (($null -eq $TopazPids) -and ($matched.Count -eq 0)) {
        # PID query failed AND no known orphan is alive to confirm activity
        # either way: we genuinely cannot tell. Unknown, not "no worker".
        return $null
    }

    # .ToArray() (not @($matched)) converts the List[object] to a plain array
    # without the array-subexpression operator's dynamic-binder overhead. The
    # leading unary comma is required, not decorative -- see Get-TopazPids's
    # comment: without it, a genuinely empty (or single-element) result
    # collapses to $null (or a bare scalar) through the return chain up to
    # Get-TopazWorkers's own caller, destroying the null-vs-empty distinction
    # this function exists to compute.
    return , $matched.ToArray()
}

function Get-TopazWorkers {
    <#
    .SYNOPSIS
        Encoder worker processes that count as an active render worker.
    .DESCRIPTION
        Runs the WorkerNameLike CIM query UNCONDITIONALLY -- even when the
        Topaz GUI PID list is empty or itself unreadable -- because an
        orphaned worker (see $script:KnownWorkers above) can still be
        encoding after its parent GUI process has exited or crashed. The
        actual matching/adoption/pruning logic lives in the pure
        Resolve-WorkerAttribution above so it is independently unit-testable.
    .OUTPUTS
        See Resolve-WorkerAttribution.
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

    return Resolve-WorkerAttribution -TopazPids $topazPids -Workers $workers -KnownWorkers $script:KnownWorkers
}

function Get-OutputBytes {
    <#
    .SYNOPSIS
        Total size (bytes) of all files under $Path, recursive. Returns 0 if
        the folder is missing or empty.
    .PARAMETER Path
        Defaults to the configured OutputDir; overridable so this is
        independently unit-testable against a throwaway test directory with
        no coupling to Config.ps1.
    #>
    param([string]$Path = $cfg.OutputDir)

    if (-not (Test-Path -LiteralPath $Path)) { return [int64]0 }

    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File `
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
        in Config.ps1. Both raw signals -- and the Active field of the return
        value -- are three-valued ($true / $false / $null). $null means
        "could not be read/decided this poll"; callers must treat that as
        unknown and freeze rather than infer idle or active.

        Returns a single object carrying the decision AND the raw inputs (for
        logging) instead of the [ref] out-param pattern this function used to
        use: PowerShell variable names are case-insensitive, so a local
        variable that differs from a [ref] parameter only by case (e.g.
        $workerActive assigned while $WorkerActive is the [ref] parameter)
        silently binds to that SAME variable, and assigning a plain value to
        it wraps the value in a second, disconnected PSReference -- which the
        Resolve-RenderActive call above then receives as a
        PSReference-of-PSReference and rejects via its own type validation.
        That was an unconditional terminating error on every single poll.
    .OUTPUTS
        [pscustomobject]@{ Active = <bool|$null>; WorkerActive = <bool|$null>; GpuValue = <double|$null> }
    #>
    param()

    $workers = Get-TopazWorkers
    $workerActive = if ($null -eq $workers) { $null } else { $workers.Count -gt 0 }

    # Only pay the nvidia-smi cost when the GPU signal is actually used.
    $gpu = $null
    if ($cfg.CompletionSignal -ne 'WorkerOnly') {
        $gpu = Get-GpuUtilizationMax
    }

    # Delegate the actual decision to the pure, unit-tested helper in Config.ps1.
    $active = Resolve-RenderActive -WorkerActive $workerActive -GpuUtil $gpu `
        -Signal $cfg.CompletionSignal -GpuBusyPercent $cfg.GpuBusyPercent

    return [pscustomobject]@{
        Active       = $active
        WorkerActive = $workerActive
        GpuValue     = $gpu
    }
}

function Get-NextWatchdogState {
    <#
    .SYNOPSIS
        Pure per-poll state transition for the main monitoring loop: given the
        current idle/stall bookkeeping and this poll's tri-state Active read
        (plus the freshly-measured output byte count, when Active), returns
        the NEXT bookkeeping plus a verdict of what the loop should do.
    .DESCRIPTION
        Extracted verbatim from the main monitoring loop so the stall/idle
        state machine is independently unit-testable. No I/O: callers own
        fetching CurrentBytes (Get-OutputBytes) and Active (Test-RenderActive)
        before calling this, and own all logging/looping after it returns.
    .PARAMETER IdleSec
        Current seconds-with-no-active-render bookkeeping.
    .PARAMETER StallSec
        Current seconds-active-but-not-growing bookkeeping.
    .PARAMETER SawActivity
        Whether an active render has ever been observed so far.
    .PARAMETER LastBytes
        The output byte total as of the last poll (high-water mark for the
        stall-reset comparison).
    .PARAMETER Active
        This poll's Resolve-RenderActive result: $true, $false, or $null
        (unreadable).
    .PARAMETER CurrentBytes
        The freshly-measured OutputDir byte total. Only consulted when
        Active is $true (mirrors the original loop, which never bothered
        measuring output size on an inactive/unknown poll) -- pass $null
        otherwise.
    .PARAMETER PollSec
        Seconds between polls (the increment added to Idle/StallSec).
    .PARAMETER DebounceSec
        Idle seconds (with prior activity seen) at/above which the queue is
        considered complete.
    .PARAMETER StallLimitSec
        Active-but-not-growing seconds at/above which the render is
        considered stalled.
    .OUTPUTS
        [pscustomobject]@{ IdleSec; StallSec; SawActivity; LastBytes;
        BytesChanged; Verdict = 'continue'|'stalled'|'completed' }
    #>
    param(
        [Parameter(Mandatory)][int]$IdleSec,
        [Parameter(Mandatory)][int]$StallSec,
        [Parameter(Mandatory)][bool]$SawActivity,
        [Parameter(Mandatory)][int64]$LastBytes,
        [AllowNull()]$Active,
        [AllowNull()]$CurrentBytes,
        [Parameter(Mandatory)][int]$PollSec,
        [Parameter(Mandatory)][int]$DebounceSec,
        [Parameter(Mandatory)][int]$StallLimitSec
    )

    if ($null -eq $Active) {
        # Neither signal could be trusted this poll (e.g. the worker CIM
        # query failed with no known orphan alive to confirm activity either
        # way, and/or the GPU read failed too). Do NOT touch idleSec/
        # stallSec/sawActivity/lastBytes on a blind poll: nudging idleSec
        # could false-complete a queue that is actually still rendering, and
        # nudging stallSec could false-stall a healthy one. Just wait for a
        # better read on the next poll.
        return [pscustomobject]@{
            IdleSec      = $IdleSec
            StallSec     = $StallSec
            SawActivity  = $SawActivity
            LastBytes    = $LastBytes
            BytesChanged = $false
            Verdict      = 'continue'
        }
    }

    if ($Active) {
        # A render is active: not idle. Record that a render actually began so
        # the completion path below may arm.
        $newIdleSec     = 0
        $newSawActivity = $true

        if ($CurrentBytes -ne $LastBytes) {
            # Output changed (grew OR shrank) -> healthy, reset stall
            # tracking. A genuinely stalled worker writes nothing at all, so
            # ANY delta means it is alive. Comparing for growth-only left a
            # high-water-mark bug: when Topaz deletes a large _temp scratch
            # file the output folder can SHRINK, and a healthy next job
            # growing back up from that lower base could then sit under the
            # old high-water mark for the whole StallSec window and get
            # killed as "stalled" mid-render.
            return [pscustomobject]@{
                IdleSec      = $newIdleSec
                StallSec     = 0
                SawActivity  = $newSawActivity
                LastBytes    = $CurrentBytes
                BytesChanged = $true
                Verdict      = 'continue'
            }
        }

        # Active but byte count unchanged -> accrue stall time.
        $newStallSec = $StallSec + $PollSec
        $verdict = if ($newStallSec -ge $StallLimitSec) { 'stalled' } else { 'continue' }

        return [pscustomobject]@{
            IdleSec      = $newIdleSec
            StallSec     = $newStallSec
            SawActivity  = $newSawActivity
            LastBytes    = $LastBytes
            BytesChanged = $false
            Verdict      = $verdict
        }
    }

    # No active render. Could be between queue items or genuinely done.
    $newStallSec = 0
    $newIdleSec  = $IdleSec + $PollSec

    if (-not $SawActivity) {
        # No render has started yet. "GUI up, nothing rendering" is also the
        # normal pre-render setup state (opening a project, adding clips,
        # configuring the export). Do NOT treat that as a completed queue, or
        # we would stop the instance before any render begins.
        return [pscustomobject]@{
            IdleSec      = $newIdleSec
            StallSec     = $newStallSec
            SawActivity  = $SawActivity
            LastBytes    = $LastBytes
            BytesChanged = $false
            Verdict      = 'continue'
        }
    }

    $verdict = if ($newIdleSec -ge $DebounceSec) { 'completed' } else { 'continue' }

    return [pscustomobject]@{
        IdleSec      = $newIdleSec
        StallSec     = $newStallSec
        SawActivity  = $SawActivity
        LastBytes    = $LastBytes
        BytesChanged = $false
        Verdict      = $verdict
    }
}

function Resolve-StopDecision {
    <#
    .SYNOPSIS
        Pure: decide whether to resume monitoring or proceed to stop.
    .DESCRIPTION
        Covers BOTH points in the loop that can turn a stop back into
        "keep monitoring": the post-unlock-gate re-verify of a 'completed'
        decision, and the post-Stop-Sequence.ps1 DryRun re-arm.

        A 'stalled' decision is NEVER re-verified/resumed via ReverifyActive
        -- a stalled worker is still "active" by definition, so re-checking
        it would just loop this step forever instead of ever stopping. Only
        a clean $true re-verify of a 'completed' decision resumes monitoring
        that way: the original completion decision was made on a clean
        $true/$false read (the debounce loop only breaks 'completed' when
        Test-RenderActive returned $false), so an unreadable ($null) or
        still-inactive ($false) re-check does not change the outcome.

        Independently of Reason/ReverifyActive, DryRun always resumes: it
        means Stop-Sequence.ps1 already ran (best-effort sync/notify) and
        deliberately suppressed the actual power-off, so the watchdog must
        re-arm or nothing would ever watch the next queue.
    .PARAMETER Reason
        'completed' or 'stalled'.
    .PARAMETER ReverifyActive
        Only meaningful when Reason is 'completed': the re-verify poll's
        Active tri-state ($true/$false/$null). Pass $null when there is no
        re-verify to consider (e.g. the post-Stop-Sequence.ps1 DryRun check).
    .PARAMETER DryRun
        Whether Stop-Sequence.ps1 ran (or would run) under DryRun.
    .OUTPUTS
        'resume' or 'stop'.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('completed', 'stalled')][string]$Reason,
        [AllowNull()]$ReverifyActive,
        [Parameter(Mandatory)][bool]$DryRun
    )

    if ($Reason -eq 'completed' -and $ReverifyActive -eq $true) {
        return 'resume'
    }

    if ($DryRun) {
        return 'resume'
    }

    return 'stop'
}

# ---------------------------------------------------------------------------
# Dot-sourcing safety guard: dot-sourcing (tests) must load functions only.
# On the Linux CI runner the wait loop and outer monitoring loop below would
# otherwise hang forever the instant this file is dot-sourced -- Get-CimInstance
# throws immediately on non-Windows, so Get-TopazPids returns $null forever and
# the wait loop's "-and $topazPids.Count -gt 0" break condition never fires.
# ---------------------------------------------------------------------------

if ($MyInvocation.InvocationName -ne '.') {

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
        # 2. Main monitoring loop. The stall/idle state machine itself lives in the
        #    pure Get-NextWatchdogState; this loop is orchestration: fetch inputs,
        #    call it, log, and act on its Verdict.
        # ---------------------------------------------------------------------------

        while ($true) {
            Start-Sleep -Seconds $cfg.PollSec

            $result       = Test-RenderActive
            $active       = $result.Active
            $workerActive = $result.WorkerActive
            $gpuValue     = $result.GpuValue
            $gpuText    = if ($null -eq $gpuValue) { 'n/a' } else { "$gpuValue%" }
            $workerText = if ($null -eq $workerActive) { 'unknown' } else { $workerActive }

            # Only measure output size when it will actually be consulted (Active
            # $true) -- mirrors the original loop, which never bothered on an
            # inactive/unknown poll.
            $currentBytes = if ($active -eq $true) { Get-OutputBytes } else { $null }

            $state = Get-NextWatchdogState -IdleSec $idleSec -StallSec $stallSec -SawActivity $sawActivity `
                -LastBytes $lastBytes -Active $active -CurrentBytes $currentBytes -PollSec $cfg.PollSec `
                -DebounceSec $cfg.DebounceSec -StallLimitSec $cfg.StallSec

            if ($null -eq $active) {
                # Neither signal could be trusted this poll (e.g. the worker CIM
                # query failed with no known orphan alive to confirm activity either
                # way, and/or the GPU read failed too). Get-NextWatchdogState freezes
                # ALL bookkeeping on a blind poll -- see its own comment -- so just
                # log and wait for a better read on the next poll.
                Write-TopazLog -Component 'watchdog' -Level 'WARN' `
                    -Message "worker+GPU signals unreadable; freezing watchdog state this poll (worker=$workerText gpu=$gpuText)."
                continue
            }

            $idleSec     = $state.IdleSec
            $stallSec    = $state.StallSec
            $sawActivity = $state.SawActivity
            $lastBytes   = $state.LastBytes

            if ($active) {
                if (-not $state.BytesChanged) {
                    # Active but byte count unchanged -> accruing stall time (a
                    # healthy byte-delta reset logs nothing, same as before).
                    Write-TopazLog -Component 'watchdog' -Level 'INFO' `
                        -Message "Render active (worker=$workerText gpu=$gpuText) but output not growing (stall=${stallSec}s / $($cfg.StallSec)s, bytes=$currentBytes)."

                    if ($state.Verdict -eq 'stalled') {
                        Write-TopazLog -Component 'watchdog' -Level 'WARN' `
                            -Message "Output stalled for ${stallSec}s with an active render. Treating render as STALLED."
                        $reason = 'stalled'
                        break
                    }
                }
            }
            else {
                # No active render. Could be between queue items or genuinely done.
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

                    if ($state.Verdict -eq 'completed') {
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

            Start-Sleep -Seconds $cfg.UnlockPollSec
        }

        # ---------------------------------------------------------------------------
        # 3b. Re-verify a 'completed' decision once: the operator may have queued
        #     another export while we were debouncing + waiting for the unlock gate
        #     above. Resolve-StopDecision NEVER resumes a 'stalled' reason here -- a
        #     stalled worker is still "active" by definition, so re-checking it
        #     would just loop this step forever instead of ever stopping.
        # ---------------------------------------------------------------------------

        if ($reason -eq 'completed') {
            $reverifyResult = Test-RenderActive
            $reverify = $reverifyResult.Active
            $rvWorker = $reverifyResult.WorkerActive
            $rvGpu    = $reverifyResult.GpuValue

            # DryRun is $false here on purpose: the DryRun-triggered resume (below,
            # after Stop-Sequence.ps1 actually runs) does not apply yet -- only the
            # re-verify outcome is being decided at this point.
            if ((Resolve-StopDecision -Reason $reason -ReverifyActive $reverify -DryRun $false) -eq 'resume') {
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

        if ((Resolve-StopDecision -Reason $reason -ReverifyActive $null -DryRun $cfg.DryRun) -eq 'resume') {
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

}
