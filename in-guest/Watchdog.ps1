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
        # -OperationTimeoutSec bounds the call the same way Get-GpuUtilizationMax
        # and Invoke-TopazAwsCli bound their child processes. A wedged WMI/CIM
        # provider would otherwise hang this call forever inside a SYSTEM task,
        # and the watchdog would simply stop polling -- no error, no log line,
        # and nothing left to ever stop the instance. On timeout this throws,
        # which the catch below turns into $null ("unknown"), and the state
        # machine then freezes its bookkeeping for that poll rather than
        # guessing. Degrading to "unknown" is safe; hanging silently is not.
        $procs = Get-CimInstance -ClassName Win32_Process `
            -Filter "Name LIKE '$($cfg.TopazNameLike)'" -OperationTimeoutSec 30 -ErrorAction Stop
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

function Resolve-ProcessDescendants {
    <#
    .SYNOPSIS
        Pure: every PID that descends from any of $RootPids, to unlimited
        depth. No CIM calls of its own, so it is fully unit-testable.
    .DESCRIPTION
        THE REASON THIS EXISTS. The watchdog used to attribute a worker to
        Topaz by testing the worker's ParentProcessId against the GUI's PID
        -- a ONE-LEVEL check. On current Topaz builds the real process tree is

            Topaz Video.exe  ->  neuroserver.exe  ->  ffmpeg.exe

        so ffmpeg.exe is a GRANDCHILD and a one-level test never matches it.
        With the old default (worker = 'ffmpeg.exe', signal = WorkerOnly) the
        watchdog therefore observed "no worker" for the entire life of every
        render, never set SawActivity, and consequently never fired at all --
        an auto-stop pipeline that silently did nothing. Matching by ANCESTRY
        fixes that, and keeps working if Topaz nests its workers deeper still.

        Walks breadth-first from the roots over a parent->children index. The
        $seen guard is load-bearing rather than an optimisation: Windows
        recycles PIDs, so a stale ParentProcessId can point at a
        later-created process and produce a CYCLE in the apparent tree, which
        would otherwise spin this loop forever inside a SYSTEM task.

        The roots themselves are NOT included in the result -- callers are
        looking for worker processes spawned BY the GUI, never the GUI itself.
    .PARAMETER AllProcesses
        A snapshot of every process on the box; each item needs .ProcessId and
        .ParentProcessId.
    .PARAMETER RootPids
        $null = the root PID query failed (unknown); @() = it succeeded and
        found none running; array = the live root PIDs.
    .OUTPUTS
        $null if $RootPids is $null (ancestry is unknowable this poll),
        otherwise an array (possibly empty) of descendant PIDs.
    #>
    param(
        [AllowEmptyCollection()][array]$AllProcesses,
        [AllowNull()]$RootPids
    )

    # Ancestry is only meaningful relative to a known root set. Preserve the
    # caller's null-vs-empty distinction rather than collapsing "unknown" into
    # "no descendants" -- see Resolve-WorkerAttribution's own contract.
    if ($null -eq $RootPids) { return $null }

    $childrenByParent = @{}
    foreach ($p in $AllProcesses) {
        $parentId = [int]$p.ParentProcessId
        if (-not $childrenByParent.ContainsKey($parentId)) {
            $childrenByParent[$parentId] = New-Object System.Collections.Generic.List[int]
        }
        [void]$childrenByParent[$parentId].Add([int]$p.ProcessId)
    }

    $seen  = @{}
    $queue = New-Object System.Collections.Generic.Queue[int]
    foreach ($r in $RootPids) { $queue.Enqueue([int]$r) }

    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        if (-not $childrenByParent.ContainsKey($current)) { continue }

        foreach ($child in $childrenByParent[$current]) {
            # A PID already seen has already been enqueued; re-enqueueing it
            # is how a PID-reuse cycle would become an infinite loop.
            if ($seen.ContainsKey($child)) { continue }
            $seen[$child] = $true
            $queue.Enqueue($child)
        }
    }

    # Leading unary comma: see Get-TopazPids -- without it a zero- or
    # one-element result collapses to $null / a bare scalar through the
    # return chain, destroying the null-vs-empty distinction above.
    return , @($seen.Keys)
}

function Resolve-WorkerAttribution {
    <#
    .SYNOPSIS
        Pure matching/adoption/pruning: which of this poll's worker processes
        count as an active render worker, given the PIDs that descend from a
        live Topaz GUI.
    .DESCRIPTION
        Extracted from Get-TopazWorkers so the attribution logic (adoption of
        a live GUI's descendants, orphan survival, and pruning of exited
        workers) is independently unit-testable, with no CIM calls of its
        own.

        MUTATES $KnownWorkers IN PLACE -- hashtables are reference types in
        PowerShell, so the caller's table is updated directly (adopted keys
        added, exited keys removed), not a copy. Callers must pass the SAME
        $script:KnownWorkers table across polls for orphan survival to work.

        A worker process counts as an active render worker if:
          (a) its PID is a DESCENDANT of a live Topaz GUI PID at any depth
              (also records it in $KnownWorkers), OR
          (b) its PID+CreationDate is already in $KnownWorkers (an orphan
              keeps counting after its parent GUI is gone).
        If $DescendantPids is $null (the ancestry query itself failed),
        descendant attribution is skipped (unknowable) and only KnownWorkers
        matches are counted.
    .PARAMETER DescendantPids
        $null = ancestry could not be resolved (unknown); @() = it resolved
        and the GUI has no descendants; array = the descendant PIDs.
        See Resolve-ProcessDescendants.
    .PARAMETER Workers
        This poll's worker processes (already CIM-queried by the caller);
        each needs .ProcessId, .ParentProcessId, .CreationDate.
    .PARAMETER KnownWorkers
        The running table of previously-adopted "<PID>|<CreationDate.Ticks>"
        keys, mutated in place (see above).
    .OUTPUTS
        $null  - $DescendantPids was $null AND no known orphan is alive to
                 confirm activity either way (genuinely unknown -- NOT "no
                 worker").
        @()    - $Workers had nothing that matched, and ancestry was known.
        array  - the matched worker(s).
    #>
    param(
        [AllowNull()]$DescendantPids,
        [AllowEmptyCollection()][array]$Workers,
        [Parameter(Mandatory)][hashtable]$KnownWorkers
    )

    $matched  = New-Object System.Collections.Generic.List[object]
    $seenKeys = @{}

    foreach ($w in $Workers) {
        $key = "$($w.ProcessId)|$($w.CreationDate.Ticks)"
        $seenKeys[$key] = $true

        if (($null -ne $DescendantPids) -and ($DescendantPids -contains $w.ProcessId)) {
            # Descends from a live Topaz GUI PID (child, grandchild, deeper):
            # adopt it as known.
            $KnownWorkers[$key] = $true
            $matched.Add($w)
        }
        elseif ($KnownWorkers.ContainsKey($key)) {
            # Not (currently provably) descended from a live GUI, but this
            # exact process (same PID + CreationDate) was adopted earlier: it
            # is an orphan that is still encoding after its parent GUI exited.
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

    if (($null -eq $DescendantPids) -and ($matched.Count -eq 0)) {
        # Ancestry unknown AND no known orphan is alive to confirm activity
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
        Runs the WorkerNamesLike CIM query UNCONDITIONALLY -- even when the
        Topaz GUI PID list is empty or itself unreadable -- because an
        orphaned worker (see $script:KnownWorkers above) can still be
        encoding after its parent GUI process has exited or crashed.

        Attribution is by ANCESTRY, not direct parentage: Topaz spawns
        neuroserver.exe as a child of the GUI and ffmpeg.exe as a child of
        THAT, so a one-level parent test misses the encoder entirely. The
        cheap ProcessId/ParentProcessId snapshot below is what lets
        Resolve-ProcessDescendants walk the whole subtree. Both that and the
        matching/adoption/pruning logic are pure functions above, so they are
        independently unit-testable.
    .OUTPUTS
        See Resolve-WorkerAttribution.
    #>
    $topazPids = Get-TopazPids   # $null = PID query failed (unknown), @() = none running

    # Ancestry snapshot. Only two properties are selected because this query
    # covers EVERY process on the box and runs on every poll; pulling full
    # Win32_Process instances here would be needlessly expensive.
    try {
        $allProcesses = @(Get-CimInstance -ClassName Win32_Process `
            -Property ProcessId, ParentProcessId -OperationTimeoutSec 30 -ErrorAction Stop |
            Select-Object ProcessId, ParentProcessId)
    }
    catch {
        Write-TopazLog -Component 'watchdog' -Level 'WARN' `
            -Message "Get-TopazWorkers process-tree query failed: $($_.Exception.Message)"
        $allProcesses = @()
        # Ancestry is now unknowable this poll. Force the $null contract
        # rather than silently attributing nothing: with an empty process
        # table Resolve-ProcessDescendants would return @() ("the GUI has no
        # descendants"), which reads as a CONFIRMED idle box and could
        # complete the queue mid-render.
        $topazPids = $null
    }

    $descendantPids = Resolve-ProcessDescendants -AllProcesses $allProcesses -RootPids $topazPids

    try {
        $workerFilter = Build-WorkerWqlFilter -Patterns $cfg.WorkerNamesLike
        $workers = @(Get-CimInstance -ClassName Win32_Process `
            -Filter $workerFilter -OperationTimeoutSec 30 -ErrorAction Stop)
    }
    catch {
        Write-TopazLog -Component 'watchdog' -Level 'WARN' `
            -Message "Get-TopazWorkers failed: $($_.Exception.Message)"
        return $null
    }

    return Resolve-WorkerAttribution -DescendantPids $descendantPids -Workers $workers -KnownWorkers $script:KnownWorkers
}

function Get-WorkerIoBytes {
    <#
    .SYNOPSIS
        Pure: total cumulative bytes read+written by the supplied worker
        processes, or $null when the worker set itself is unknown. No I/O of
        its own, so it is fully unit-testable.
    .DESCRIPTION
        THE REASON THIS EXISTS. The stall detector originally asked "has the
        output FOLDER grown?", summing Get-ChildItem lengths. On NTFS that is
        not a reliable progress signal: while a writer holds a file handle
        open, the directory entry's length is only refreshed on an occasional
        metadata flush, not on every write. Measured on this deployment during
        a demonstrably healthy render, the reported length of the output file
        sat frozen for 476 seconds between two updates, and stayed at its
        initial value for 699 seconds from the start of the job -- roughly
        78% of the 900s stall budget that was the default, burned by a job
        doing nothing wrong.

        A process's ReadTransferCount/WriteTransferCount are kernel-maintained
        counters. They advance on every single write regardless of file-handle
        or metadata-flush behaviour, which makes them the signal the stall
        detector actually wants. The folder-size check is retained alongside
        this one (see Get-NextWatchdogState) purely as a second opinion.

        Counters are cumulative PER PROCESS, so the sum can DROP when one
        worker exits and another starts (Topaz runs one neuroserver per queue
        item). Callers must therefore treat ANY delta -- up or down -- as
        proof of life, exactly as they already do for the folder byte count.
    .PARAMETER Workers
        The matched worker processes, or $null if the worker signal was
        unreadable this poll. Each item is expected to expose
        .ReadTransferCount / .WriteTransferCount; missing values contribute 0.
    .OUTPUTS
        [int64] total, or $null when $Workers is $null.
    #>
    param([AllowNull()]$Workers)

    if ($null -eq $Workers) { return $null }

    $total = [int64]0
    foreach ($w in $Workers) {
        if ($null -ne $w.ReadTransferCount)  { $total += [int64]$w.ReadTransferCount }
        if ($null -ne $w.WriteTransferCount) { $total += [int64]$w.WriteTransferCount }
    }
    return $total
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
        [pscustomobject]@{ Active = <bool|$null>; WorkerActive = <bool|$null>;
        GpuValue = <double|$null>; IoBytes = <int64|$null> }

        IoBytes is the workers' cumulative read+write byte total this poll, or
        $null when the worker signal was unreadable. It is carried here rather
        than re-queried by the caller so that it describes EXACTLY the same
        worker set the Active decision was made from -- re-querying would race
        against a worker exiting between the two calls.
    #>
    param()

    $workers = Get-TopazWorkers
    $workerActive = if ($null -eq $workers) { $null } else { $workers.Count -gt 0 }
    $ioBytes = Get-WorkerIoBytes -Workers $workers

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
        IoBytes      = $ioBytes
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
    .PARAMETER LastIoBytes
        The worker I/O byte total as of the last poll, or $null if it was
        never established.
    .PARAMETER CurrentIoBytes
        The freshly-measured worker I/O byte total (see Get-WorkerIoBytes), or
        $null if the worker signal was unreadable this poll.

        PROGRESS IS THE UNION OF THE TWO SIGNALS. A render counts as making
        progress if the output folder changed size OR the workers' cumulative
        I/O counters moved. The folder-size signal alone is not trustworthy on
        NTFS -- an open writer's directory entry was measured frozen for 476
        consecutive seconds mid-render on this deployment -- so relying on it
        alone lets a healthy job accrue stall time until it is killed. The I/O
        counters move on every write and carry the signal in practice; the
        folder size is kept as corroboration for the case where a worker is
        replaced between polls and its counters reset.
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
        [int]$ActiveSec = 0,
        [int]$ArmSec = 0,
        [Parameter(Mandatory)][int64]$LastBytes,
        [AllowNull()]$Active,
        [AllowNull()]$CurrentBytes,
        [AllowNull()]$LastIoBytes,
        [AllowNull()]$CurrentIoBytes,
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
            # Frozen along with everything else: an unreadable poll is not
            # evidence the worker went away, so it must not reset the arm
            # counter and force a genuine render to re-earn its 90 seconds.
            ActiveSec    = $ActiveSec
            LastBytes    = $LastBytes
            LastIoBytes  = $LastIoBytes
            BytesChanged = $false
            Verdict      = 'continue'
        }
    }

    if ($Active) {
        # A render is active: not idle.
        $newIdleSec   = 0
        $newActiveSec = $ActiveSec + $PollSec

        # ARM DEBOUNCE. SawActivity is what makes the watchdog willing to ever
        # declare a queue complete, so setting it on a single active poll is
        # too eager: Topaz spawns short-lived ffmpeg/ffprobe helpers for
        # previews and thumbnails, and one of those (measured at under 32
        # seconds) once armed the watchdog on a box where no render had run,
        # very nearly stopping it. Requiring ArmSec of CONTINUOUS activity
        # first distinguishes a real job -- whose neuroserver.exe lives for
        # minutes to hours -- from GUI noise.
        #
        # Once armed it STAYS armed ($SawActivity -or ...): a real render that
        # later pauses between queue items must not disarm itself, or the
        # completion path could never fire.
        $newSawActivity = $SawActivity -or ($newActiveSec -ge $ArmSec)

        # Output changed (grew OR shrank) -> healthy. A genuinely stalled
        # worker writes nothing at all, so ANY delta means it is alive.
        # Comparing for growth-only left a high-water-mark bug: when Topaz
        # deletes a large _temp scratch file the output folder can SHRINK,
        # and a healthy next job growing back up from that lower base could
        # then sit under the old high-water mark for the whole StallSec
        # window and get killed as "stalled" mid-render.
        $bytesProgressed = ($CurrentBytes -ne $LastBytes)

        # The workers' cumulative I/O counters moved -> also healthy, and far
        # more reliable than the byte count above (see the CurrentIoBytes
        # parameter notes). Both sides must be known for a delta to mean
        # anything: an unreadable counter is not evidence of a stall.
        # The counters are per-process and reset when Topaz swaps in a fresh
        # worker for the next queue item, so -ne (not -gt) is deliberate --
        # any movement, in either direction, proves something is alive.
        $ioProgressed = ($null -ne $CurrentIoBytes) -and
                        ($null -ne $LastIoBytes) -and
                        ($CurrentIoBytes -ne $LastIoBytes)

        # Carry the I/O reading forward whenever we actually got one, so a
        # single unreadable poll does not erase the baseline and manufacture
        # a false delta on the next one.
        $newIoBytes = if ($null -ne $CurrentIoBytes) { $CurrentIoBytes } else { $LastIoBytes }

        if ($bytesProgressed -or $ioProgressed) {
            return [pscustomobject]@{
                IdleSec      = $newIdleSec
                StallSec     = 0
                SawActivity  = $newSawActivity
                ActiveSec    = $newActiveSec
                LastBytes    = $CurrentBytes
                LastIoBytes  = $newIoBytes
                BytesChanged = $true
                Verdict      = 'continue'
            }
        }

        # Active but NEITHER progress signal moved -> accrue stall time.
        $newStallSec = $StallSec + $PollSec
        $verdict = if ($newStallSec -ge $StallLimitSec) { 'stalled' } else { 'continue' }

        return [pscustomobject]@{
            IdleSec      = $newIdleSec
            StallSec     = $newStallSec
            SawActivity  = $newSawActivity
            ActiveSec    = $newActiveSec
            LastBytes    = $LastBytes
            LastIoBytes  = $newIoBytes
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
            # The worker is gone, so any partial arm progress is discarded. A
            # burst of short-lived preview helpers must never accumulate
            # towards ArmSec across the gaps between them.
            ActiveSec    = 0
            LastBytes    = $LastBytes
            LastIoBytes  = $LastIoBytes
            BytesChanged = $false
            Verdict      = 'continue'
        }
    }

    $verdict = if ($newIdleSec -ge $DebounceSec) { 'completed' } else { 'continue' }

    return [pscustomobject]@{
        IdleSec      = $newIdleSec
        StallSec     = $newStallSec
        SawActivity  = $SawActivity
        ActiveSec    = 0
        LastBytes    = $LastBytes
        LastIoBytes  = $LastIoBytes
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
        -Message "Topaz GUI detected. Monitoring render queue (poll=$($cfg.PollSec)s, debounce=$($cfg.DebounceSec)s, stall=$($cfg.StallSec)s, workers matching [$($cfg.WorkerNamesLike -join ', ')] by ancestry)."

    # ---------------------------------------------------------------------------
    # 2-4. Monitor the queue, gate on unlocked outputs, then stop -- wrapped in an
    #      outer loop so the watchdog RESUMES monitoring instead of exiting for
    #      good when: (a) re-verifying a 'completed' decision finds the operator
    #      queued another export during the debounce+unlock wait, or (b) the stop
    #      step ran under DryRun (nothing would otherwise watch the next queue
    #      until a reboot re-triggered the scheduled task).
    # ---------------------------------------------------------------------------

    $idleSec     = 0            # seconds with no active render
    $stallSec    = 0            # seconds a render is active but making no progress
    $sawActivity = $false       # have we ever observed a SUSTAINED active render?
    $activeSec   = 0            # consecutive seconds active, for the arm debounce
    $lastBytes   = Get-OutputBytes
    $lastIoBytes = $null        # workers' cumulative I/O total; $null until first read

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
            $ioBytes      = $result.IoBytes
            $gpuText    = if ($null -eq $gpuValue) { 'n/a' } else { "$gpuValue%" }
            $workerText = if ($null -eq $workerActive) { 'unknown' } else { $workerActive }
            $ioText     = if ($null -eq $ioBytes) { 'n/a' } else { $ioBytes }

            # Only measure output size when it will actually be consulted (Active
            # $true) -- mirrors the original loop, which never bothered on an
            # inactive/unknown poll.
            $currentBytes = if ($active -eq $true) { Get-OutputBytes } else { $null }

            $state = Get-NextWatchdogState -IdleSec $idleSec -StallSec $stallSec -SawActivity $sawActivity `
                -ActiveSec $activeSec -ArmSec $cfg.ArmSec `
                -LastBytes $lastBytes -Active $active -CurrentBytes $currentBytes `
                -LastIoBytes $lastIoBytes -CurrentIoBytes $ioBytes -PollSec $cfg.PollSec `
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
            $activeSec   = $state.ActiveSec
            $lastBytes   = $state.LastBytes
            $lastIoBytes = $state.LastIoBytes

            if ($active) {
                if (-not $state.BytesChanged) {
                    # Active but byte count unchanged -> accruing stall time (a
                    # healthy byte-delta reset logs nothing, same as before).
                    $armText = if ($sawActivity) { 'armed' } else { "arming ${activeSec}s/$($cfg.ArmSec)s" }
                    Write-TopazLog -Component 'watchdog' -Level 'INFO' `
                        -Message "Render active (worker=$workerText gpu=$gpuText, $armText) but NO progress on either signal (stall=${stallSec}s / $($cfg.StallSec)s, outputBytes=$currentBytes, workerIoBytes=$ioText)."

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
                        -Message "Topaz GUI up but no render has started yet (idle=${idleSec}s, worker=$workerText gpu=$gpuText). Waiting for $($cfg.ArmSec)s of sustained worker activity before arming completion."
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
                # A render was just re-verified as genuinely active, so it has
                # already earned its arm; start the counter at ArmSec rather
                # than 0 so a mid-queue lull cannot un-arm it.
                $activeSec   = $cfg.ArmSec
                $lastBytes   = Get-OutputBytes
                # Drop the I/O baseline: it belongs to the worker set from
                # before this gap. Re-baselining on the next poll avoids
                # comparing against counters from a process that has exited.
                $lastIoBytes = $null
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
            # Fully disarmed for the next queue: the next render must again
            # prove itself with ArmSec of sustained activity.
            $activeSec   = 0
            $lastBytes   = Get-OutputBytes
            $lastIoBytes = $null
            continue outer
        }

        # Not a dry run: the instance is stopping. Let the script end.
        break outer

    }

}
