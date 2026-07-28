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

    INCREMENTAL UPLOAD (CORRECTION 3, 2026-07-28 operator instruction): every
    poll, regardless of whether a render is currently active, the loop also
    checks OutputDir for a file that looks FINISHED (unlocked and size-stable
    for UploadStableSec) and uploads it immediately via rclone, rather than
    waiting for the whole queue to drain. This is what protects a completed
    multi-GB deliverable during every subsequent queue item's render, instead
    of leaving it unprotected on the ephemeral scratch volume for hours. See
    Invoke-TopazIncrementalUploadPoll below; switch off via Config.ps1's
    UploadWhenReady. The final Stop-Sequence.ps1 upload sweep is unchanged and
    still runs regardless -- it is the catch-all for anything this pass
    missed or failed to upload.

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

# --- Incremental-upload tracking state --------------------------------------
# CORRECTION 3 (2026-07-28): per-file bookkeeping for "upload each render as
# it finishes" (see Invoke-TopazIncrementalUploadPoll below), keyed by a
# file's FullName -> @{ SizeLastSeen; SecondsStable; UploadedSize;
# UploadedWriteTimeUtc }.
#
# UploadedSize/UploadedWriteTimeUtc (both $null until a successful upload)
# replace the old bare "AlreadyUploaded" boolean -- FINDING 2 of the
# 2026-07-28 adversarial review (see Resolve-IncrementalUploadEligibility's
# own comment for the full rationale). Keying "already uploaded" on FullName
# ALONE was wrong on this box specifically: independent forensic verification
# of the 2026-07-28 incident proved Topaz's own crash-recovery path reloads
# the project and re-queues the export through a different internal code path
# after a worker crash (the log shows "export_source" flip from "export_as"
# to "quick"), which does NOT carry forward the user-chosen output folder and
# leaves a previously-uploaded file's path holding new, different bytes. A
# path-only key would exclude that corrected content from ever being
# re-uploaded by this incremental path for the rest of the process's life.
# Keying on path PLUS the size/write-time actually uploaded means a file that
# changes after its upload becomes eligible again automatically -- see
# Invoke-TopazIncrementalUploadPoll below for where that re-upload is
# additionally logged as a distinct, greppable event.
#
# Declared ONCE here, outside the ':outer' re-arm loop, so it survives a
# DryRun re-arm or a Stop-Sequence refusal-and-retry -- there is no reason to
# forget a file is already uploaded just because the watchdog looped back to
# monitoring. IN-MEMORY ONLY: a watchdog PROCESS restart (as opposed to a
# re-arm within the same process) loses this table entirely, which is
# harmless, not just tolerable -- rclone `copy`/`check` are idempotent
# against a destination file that already matches by size, so a redundant
# re-upload after a restart costs bandwidth and time, never correctness.
$script:UploadTracking = @{}

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

# Test-FileUnlocked MOVED to Config.ps1 (2026-07-28): it is now shared with
# the recovery scan (Find-RenderRecoveryCandidates) and the incremental
# per-file upload pass (Invoke-TopazIncrementalUploadPoll, below), not just
# the unlock-gate loop at the bottom of this file. Config.ps1 is dot-sourced
# above, so the name resolves exactly as before -- see its own comment there.

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

function Resolve-IncrementalUploadEligibility {
    <#
    .SYNOPSIS
        Pure: is this ONE OutputDir file eligible for an incremental
        (upload-as-it-finishes) upload RIGHT NOW? No I/O, so it is fully
        unit-testable -- CORRECTION 3 (2026-07-28 operator instruction),
        expressed as a pure decision per this file's own convention (mirrors
        Get-NextWatchdogState's own stall/idle verdict).
    .DESCRIPTION
        FIVE conditions ALL gate eligibility -- every one of them is load-
        bearing, not defence-in-depth padding:
          1. NOT a Topaz temp/scratch file (IsTemp, via Test-TopazTempFile).
             Topaz may leave scratch files behind after a successful export;
             uploading them wastes bandwidth and clutters the destination.
          2. Unlocked THIS poll (IsUnlocked, via Test-FileUnlocked).
          3. That size has held for at least StableThresholdSec of
             consecutive polls (SecondsStable -ge StableThresholdSec).
          4. The size reported NOW still matches the size the caller tracked
             as of the LAST poll (SizeNow -eq SizeLastSeen). Belt-and-braces
             alongside #3: even if a caller bug mis-tracked SecondsStable, a
             file whose size just changed cannot become eligible here.
          5. NOT already uploaded earlier this session WITH THIS SAME CONTENT
             (UploadedSize/UploadedWriteTimeUtc) -- this is what stops the
             SAME finished file being re-uploaded on every subsequent poll,
             while still allowing a file that has genuinely changed SINCE its
             upload to become eligible again. See "WHY IDENTITY IS SIZE+
             WRITE-TIME, NOT JUST FULLNAME" below.

        WHY UNLOCKED ALONE IS NOT ENOUGH (conditions 2 AND 3+4 TOGETHER, not
        either alone). Some encoders/muxers briefly release and reacquire
        their write handle between internal buffer flushes, so a file mid-
        write can read as momentarily unlocked on any single poll. Requiring
        the SAME size across multiple consecutive polls in addition to being
        unlocked on the poll that actually triggers the upload is what
        distinguishes "genuinely finished" from "caught between two writes".

        WHY IDENTITY IS SIZE+WRITE-TIME, NOT JUST FULLNAME -- FINDING 2 of the
        2026-07-28 adversarial review, and NOT a hypothetical on this box.
        Independent forensic verification of the 2026-07-28 incident proved
        that a Topaz worker crashing mid-export is DOCUMENTED, RECURRING
        behaviour here: on a crash, Topaz reloads the project and re-queues
        the export through a different internal code path (the log shows
        "export_source" flip from "export_as" to "quick"), and that path does
        not carry the user-chosen output folder forward. The crashed writer's
        handle is released (unlocked) while its partial file sits at a stable
        -- but INCOMPLETE -- size for however long Topaz takes to notice the
        crash and resume, which is not bounded under StableThresholdSec. This
        function's five conditions CANNOT distinguish that partial from a
        genuinely finished file, so a partial CAN still be uploaded and
        verified. What condition 5 fixes is what happens NEXT: keying
        "already uploaded" on FullName alone would exclude that path from
        EVER being re-uploaded again, even after the resumed writer overwrote
        it with the correct, complete content -- so the stale partial would
        sit at the destination, believed "verified", until the final
        Stop-Sequence.ps1 sweep eventually re-copies everything (potentially
        hours later on a multi-export queue). Comparing SizeNow/WriteTimeNow
        against the size/write-time actually uploaded means the resumed
        writer's overwrite is detected the moment it restabilizes, and the
        correction reaches the destination on the very next eligible poll
        instead of waiting for that final sweep. This does NOT make
        unlocked+size-stable a reliable "finished" signal -- it makes the
        mistake self-correcting within one poll of the real writer finishing,
        rather than persisting for the rest of the process's life.
    .PARAMETER IsTemp
        Whether the file matches TempMarker (Test-TopazTempFile).
    .PARAMETER IsUnlocked
        Whether Test-FileUnlocked succeeded this poll.
    .PARAMETER SizeNow
        The file's length as of this poll.
    .PARAMETER SizeLastSeen
        The file's length as tracked as of the PREVIOUS poll this file was
        seen at, or $null if this is the first poll this file has been seen
        (a file can never be eligible on the very first poll it is observed:
        there is nothing yet to compare its size against).
    .PARAMETER SecondsStable
        Consecutive seconds the size has been observed unchanged, as already
        computed by the caller (see Get-NextUploadTrackingState below).
    .PARAMETER StableThresholdSec
        Config's UploadStableSec.
    .PARAMETER WriteTimeNow
        The file's LastWriteTimeUtc as of this poll.
    .PARAMETER UploadedSize
        The size that was actually uploaded for this file earlier this
        session, or $null if this file has never been successfully uploaded
        this session. $null here means conditions 3/4/5 below are the only
        gates that matter; a non-null value means this file was previously
        uploaded and is excluded UNLESS its content has since changed.
    .PARAMETER UploadedWriteTimeUtc
        The LastWriteTimeUtc that was actually uploaded alongside
        UploadedSize, or $null under the same condition as UploadedSize (the
        two are always set, and cleared, together by the caller).
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool]$IsTemp,
        [Parameter(Mandatory)][bool]$IsUnlocked,
        [Parameter(Mandatory)][int64]$SizeNow,
        [AllowNull()]$SizeLastSeen,
        [Parameter(Mandatory)][int]$SecondsStable,
        [Parameter(Mandatory)][int]$StableThresholdSec,
        [Parameter(Mandatory)][datetime]$WriteTimeNow,
        [AllowNull()]$UploadedSize,
        [AllowNull()]$UploadedWriteTimeUtc
    )

    if ($IsTemp) { return $false }
    if (-not $IsUnlocked) { return $false }

    # Condition 5, identity-based (FINDING 2 fix). $null UploadedSize means
    # "never uploaded this session" -- fall through to the ordinary stability
    # gates below exactly as before. A non-null UploadedSize means this exact
    # path WAS uploaded earlier; it stays excluded only while BOTH its size
    # and its write-time still match what was actually uploaded. Either one
    # differing means the content at this path has changed since that upload
    # (the crash-retry rewrite this fix targets) -- do NOT exclude here, let
    # the normal stability gates below decide whether the NEW content looks
    # finished yet.
    if ($null -ne $UploadedSize) {
        $unchangedSinceUpload = ([int64]$UploadedSize -eq $SizeNow) -and ($UploadedWriteTimeUtc -eq $WriteTimeNow)
        if ($unchangedSinceUpload) { return $false }
    }

    if ($null -eq $SizeLastSeen) { return $false }
    if ([int64]$SizeLastSeen -ne $SizeNow) { return $false }
    if ($SecondsStable -lt $StableThresholdSec) { return $false }

    return $true
}

function Get-NextUploadTrackingState {
    <#
    .SYNOPSIS
        Pure: combine one file's per-poll stability bookkeeping with the
        eligibility gate above, given the previous poll's tracked state for
        THIS ONE file and this poll's freshly measured signals. No I/O, so it
        is fully unit-testable.
    .DESCRIPTION
        Mirrors Get-NextWatchdogState's own shape (state transition + verdict
        in one pure call) at file granularity instead of queue granularity.
        Callers own the per-file table (Invoke-TopazIncrementalUploadPoll
        below) and are expected to call this once per tracked file, per poll.

        SIZE-CHANGED RESETS THE STABILITY CLOCK TO ZERO, mirroring
        Get-NextWatchdogState's own stall-clock reset on any progress signal:
        a file whose size just moved has, by definition, not been stable for
        any length of time yet.
    .PARAMETER IsTemp
        Whether the file matches TempMarker (Test-TopazTempFile).
    .PARAMETER IsUnlocked
        Whether Test-FileUnlocked succeeded this poll.
    .PARAMETER SizeNow
        The file's length as of this poll.
    .PARAMETER PreviousSizeLastSeen
        The file's tracked size as of the previous poll it was seen at, or
        $null if this is the first poll this file has been observed.
    .PARAMETER PreviousSecondsStable
        The tracked stability-clock value as of the previous poll (0 if this
        is the first poll this file has been observed).
    .PARAMETER WriteTimeNow
        The file's LastWriteTimeUtc as of this poll -- passed straight
        through to Resolve-IncrementalUploadEligibility; this function does
        not track a write-time stability clock of its own (the size-based
        clock above is unchanged by FINDING 2 -- see THE FIX below).
    .PARAMETER UploadedSize
        The size actually uploaded for this file earlier this session, or
        $null if never uploaded -- carried through unchanged; the caller
        updates it separately once an upload attempt actually succeeds. Pass
        straight through to Resolve-IncrementalUploadEligibility.
    .PARAMETER UploadedWriteTimeUtc
        The LastWriteTimeUtc actually uploaded alongside UploadedSize, same
        carry-through contract as UploadedSize.
    .PARAMETER PollSec
        Config's PollSec; how much the stability clock advances per poll when
        the size has not changed.
    .PARAMETER StableThresholdSec
        Config's UploadStableSec.
    .OUTPUTS
        [pscustomobject]@{ SizeLastSeen; SecondsStable; Eligible }
        SizeLastSeen/SecondsStable are the values the caller should persist
        for this file for the NEXT poll. Eligible is this poll's
        Resolve-IncrementalUploadEligibility verdict.

        THE FIX (FINDING 2, 2026-07-28 adversarial review) IS SCOPED TO
        IDENTITY, NOT TO THIS STABILITY CLOCK. UploadedSize/UploadedWriteTimeUtc
        only change condition 5 of Resolve-IncrementalUploadEligibility (was
        this exact content already uploaded?); the SizeLastSeen/SecondsStable
        clock computed here is exactly the same size-only calculation as
        before. A resumed writer that grows the file after a crash already
        resets this clock to 0 via the ordinary sizeUnchanged check below --
        the same mechanism that has always distinguished "still writing" from
        "finished" -- so the crash-resume case naturally has to re-earn
        StableThresholdSec of stability on its new, correct size before the
        identity check (which now sees a mismatch) lets it become eligible
        again. Nothing about this per-poll clock needed to change for that.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool]$IsTemp,
        [Parameter(Mandatory)][bool]$IsUnlocked,
        [Parameter(Mandatory)][int64]$SizeNow,
        [AllowNull()]$PreviousSizeLastSeen,
        [Parameter(Mandatory)][int]$PreviousSecondsStable,
        [Parameter(Mandatory)][datetime]$WriteTimeNow,
        [AllowNull()]$UploadedSize,
        [AllowNull()]$UploadedWriteTimeUtc,
        [Parameter(Mandatory)][int]$PollSec,
        [Parameter(Mandatory)][int]$StableThresholdSec
    )

    $sizeUnchanged = ($null -ne $PreviousSizeLastSeen) -and ([int64]$PreviousSizeLastSeen -eq $SizeNow)
    $nextSecondsStable = if ($sizeUnchanged) { $PreviousSecondsStable + $PollSec } else { 0 }

    $eligible = Resolve-IncrementalUploadEligibility -IsTemp $IsTemp -IsUnlocked $IsUnlocked `
        -SizeNow $SizeNow -SizeLastSeen $PreviousSizeLastSeen -SecondsStable $nextSecondsStable `
        -StableThresholdSec $StableThresholdSec -WriteTimeNow $WriteTimeNow `
        -UploadedSize $UploadedSize -UploadedWriteTimeUtc $UploadedWriteTimeUtc

    return [pscustomobject]@{
        SizeLastSeen  = $SizeNow
        SecondsStable = $nextSecondsStable
        Eligible      = $eligible
    }
}

function Invoke-TopazIncrementalUploadPoll {
    <#
    .SYNOPSIS
        One poll's worth of incremental (per-file, upload-as-it-finishes)
        work: enumerate OutputDir, update each file's stability bookkeeping in
        $Tracking, and upload any file that is now eligible. CORRECTION 3
        (2026-07-28 operator instruction) -- see Config.ps1's
        Invoke-TopazIncrementalUpload for the actual upload mechanics.
    .DESCRIPTION
        CALLED EVERY POLL, REGARDLESS OF WHETHER A RENDER IS CURRENTLY
        ACTIVE. The whole point is protecting a deliverable that finished
        writing WHILE THE NEXT QUEUE ITEM IS ALREADY RENDERING -- exactly the
        case that left a 2.3 GB completed render unprotected for the entire
        multi-hour duration of a SUBSEQUENT export in the 2026-07-28
        incident. Gating this call on $active would silently reintroduce
        that exact hole, so the caller (the main monitoring loop below) must
        not do that.

        WHERE THIS SITS IN THE POLL LOOP, AND WHY. This is called AFTER the
        existing idle/stall/arm state-machine update and its logging for the
        poll (Get-NextWatchdogState and everything that reacts to its
        Verdict) -- never before it, and never interleaved with it. Two
        reasons:
          1. This pass can BLOCK for up to UploadTimeoutSec per rclone
             attempt (see Invoke-TopazIncrementalUpload's own comment on the
             accepted blind window) -- reading the render-active signal FIRST
             keeps the safety-critical idle/stall bookkeeping's timing as
             close to the real PollSec cadence as this loop ever achieves.
             Running the upload first would delay that read by however long
             the upload took, on every single poll, not just the rare
             eligible one.
          2. It never touches $idleSec/$stallSec/$sawActivity/$activeSec/
             $lastBytes/$lastIoBytes -- it is a fully independent concern from
             the completion state machine, so its result cannot corrupt that
             bookkeeping regardless of where it runs. Placing it after,
             rather than before or inside, keeps that independence visibly
             true in the code, not just true in principle.

        NEVER THROWS, NEVER LEAVES THE POLL LOOP WORSE OFF THAN BEFORE THE
        CALL. A failure anywhere in this pass (enumerating OutputDir,
        checking one file's lock state, an upload attempt) is caught and
        logged; it must never take down the poll loop, the single most
        safety-critical loop in the project. A failed incremental upload for
        one file is NOT fatal: it is logged, the file is left unmarked in
        $Tracking, and a later poll (or the final Stop-Sequence.ps1 sweep)
        retries it.

        $Tracking IS MUTATED IN PLACE (hashtables are reference types in
        PowerShell -- same pattern as $script:KnownWorkers above) and is
        IN-MEMORY ONLY. See $script:UploadTracking's own declaration comment
        for why losing it across a process restart is harmless, not just
        tolerable.
    .PARAMETER Config
        Get-TopazAutoStopConfig object.
    .PARAMETER Tracking
        Hashtable keyed by a file's FullName -> @{ SizeLastSeen;
        SecondsStable; UploadedSize; UploadedWriteTimeUtc }, mutated in place
        across polls. UploadedSize/UploadedWriteTimeUtc are $null until this
        file's first successful upload, and thereafter hold the size/
        LastWriteTimeUtc that were ACTUALLY uploaded -- see
        Resolve-IncrementalUploadEligibility's own comment (FINDING 2,
        2026-07-28) for why FullName alone is not a safe upload-identity key
        on this box.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][hashtable]$Tracking
    )

    $cfg = $Config

    if (-not $cfg.UploadWhenReady) { return }
    if ([string]::IsNullOrWhiteSpace($cfg.UploadTarget)) { return }

    try {
        if (-not (Test-Path -LiteralPath $cfg.OutputDir)) { return }

        $files    = @(Get-ChildItem -LiteralPath $cfg.OutputDir -Recurse -File -ErrorAction SilentlyContinue)
        $seenKeys = @{}

        foreach ($f in $files) {
            $key = $f.FullName
            $seenKeys[$key] = $true

            $prev              = $Tracking[$key]
            $prevSize          = if ($prev) { $prev.SizeLastSeen } else { $null }
            $prevStable        = if ($prev) { $prev.SecondsStable } else { 0 }
            $uploadedSize      = if ($prev) { $prev.UploadedSize } else { $null }
            $uploadedWriteTime = if ($prev) { $prev.UploadedWriteTimeUtc } else { $null }

            $isTemp     = Test-TopazTempFile -Name $f.Name -TempMarker $cfg.TempMarker
            $isUnlocked = Test-FileUnlocked -Path $f.FullName
            $writeTimeNow = $f.LastWriteTimeUtc

            $next = Get-NextUploadTrackingState -IsTemp $isTemp -IsUnlocked $isUnlocked `
                -SizeNow ([int64]$f.Length) -PreviousSizeLastSeen $prevSize `
                -PreviousSecondsStable $prevStable -WriteTimeNow $writeTimeNow `
                -UploadedSize $uploadedSize -UploadedWriteTimeUtc $uploadedWriteTime `
                -PollSec $cfg.PollSec -StableThresholdSec $cfg.UploadStableSec

            $nextUploadedSize      = $uploadedSize
            $nextUploadedWriteTime = $uploadedWriteTime

            if ($next.Eligible) {
                # A non-null $uploadedSize reaching here means this exact path
                # was uploaded once already THIS session, and Resolve-
                # IncrementalUploadEligibility just decided it is eligible
                # again anyway -- which, by that function's own identity gate,
                # can only happen because the size and/or write-time no longer
                # match what was uploaded. That is FINDING 2's re-upload path,
                # not routine first-time coverage, and it is this box's
                # documented, recurring signature of a Topaz worker crash +
                # crash-recovery re-queue (export_source flips from
                # "export_as" to "quick" -- see the 2026-07-28 incident and
                # Resolve-IncrementalUploadEligibility's own comment). Log it
                # distinctly and GREPPABLY (the literal string "SUPERSEDED")
                # so a reader of the log can tell this apart from an ordinary
                # first upload without having to reconstruct $Tracking state.
                if ($null -ne $uploadedSize) {
                    Write-TopazLog -Component 'watchdog' -Level 'WARN' `
                        -Message "Incremental upload: '$($f.FullName)' CHANGED since its earlier upload this session (was $uploadedSize bytes @ $($uploadedWriteTime.ToString('o')) UTC; now $($f.Length) bytes @ $($writeTimeNow.ToString('o')) UTC). The previously uploaded copy is SUPERSEDED and stale -- re-uploading the corrected content now rather than waiting for the final stop-sequence sweep. This is the expected signature of Topaz's crash-recovery re-queue path on this box, not a defect in this watchdog."
                }

                # BLOCKING (see this function's own .DESCRIPTION) -- bounded by
                # Invoke-TopazIncrementalUpload's own use of
                # Invoke-TopazAwsCli's WaitForExit timeout. A failure here is
                # caught by Invoke-TopazIncrementalUpload itself and returns
                # $false; it must never throw out to this loop.
                if (Invoke-TopazIncrementalUpload -Config $cfg -File $f) {
                    # Record the IDENTITY actually uploaded (this poll's size
                    # and write-time), not just a bool -- this is what lets a
                    # LATER change to this same path be detected again next
                    # time, instead of excluding it for the rest of the
                    # process's life (FINDING 2).
                    $nextUploadedSize      = [int64]$f.Length
                    $nextUploadedWriteTime = $writeTimeNow
                }
                # else: upload failed. Leave $nextUploadedSize/$nextUploadedWriteTime
                # exactly as they were -- if this was a first-ever upload attempt
                # they stay $null (unmarked, as before FINDING 2: a later poll
                # retries it). If this was a SUPERSEDED re-upload attempt that
                # failed, they stay pointed at the STALE prior upload; that is
                # correct, not a regression -- the next poll's identity compare
                # will still see the same mismatch and try again, exactly as a
                # first-time failure does today.
            }

            $Tracking[$key] = @{
                SizeLastSeen         = $next.SizeLastSeen
                SecondsStable        = $next.SecondsStable
                UploadedSize         = $nextUploadedSize
                UploadedWriteTimeUtc = $nextUploadedWriteTime
            }
        }

        # Prune entries for files no longer present in OutputDir (renamed,
        # deleted, or the volume was just wiped by a stop this table does not
        # yet know happened). Mirrors $script:KnownWorkers's own pruning --
        # a stale entry is harmless either way, but there is no reason to let
        # this table grow across a long, multi-item queue.
        foreach ($key in @($Tracking.Keys)) {
            if (-not $seenKeys.ContainsKey($key)) { $Tracking.Remove($key) }
        }
    }
    catch {
        # Best-effort, exactly like every other bounded I/O helper in this
        # pipeline (Get-GpuUtilizationMax, Invoke-TopazAwsCli,
        # Find-RenderRecoveryCandidates): ANY failure here must degrade
        # gracefully, never throw into the poll loop and take the watchdog
        # down with it.
        Write-TopazLog -Component 'watchdog' -Level 'WARN' `
            -Message "Incremental upload pass FAILED (best-effort, ignored): $($_.Exception.Message)"
    }
}

function Resolve-RefusalStallSec {
    <#
    .SYNOPSIS
        Pure: what the stall clock should be reset to after Stop-Sequence.ps1
        REFUSED to stop, given why the stop was attempted. No I/O.
    .DESCRIPTION
        THE REASON THIS IS NOT JUST "0".

        After a refusal the watchdog re-arms and retries, and how quickly the
        retry actually comes depends entirely on which branch of the state
        machine governs the next poll:

          reason='completed' - the worker has EXITED. The next poll reads
              Active=$false, so the idle branch governs and the retry arrives
              after DebounceSec. Resetting the stall clock to 0 is correct and
              irrelevant, because the stall clock is not what gates the retry.

          reason='stalled'   - the worker is HUNG, not gone. Stop-Sequence.ps1
              never touches Topaz processes, so that worker is still there on
              the very next poll: Active reads $true, the ACTIVE branch
              governs, and the retry is gated by the stall clock climbing all
              the way back to StallLimitSec. Resetting to 0 would therefore
              cost a FULL StallSec (1800s = 30 min) before the next attempt --
              not the DebounceSec the re-arm intends, and precisely the window
              in which the out-of-band CloudWatch idle alarm can stop the box
              and erase the un-uploaded render. That yields ONE retry where
              several were intended.

        So for 'stalled' the clock is carried back to DebounceSec short of the
        limit, making the next attempt due after DebounceSec of continued
        no-progress. If the worker recovers and makes progress in the
        meantime, the normal progress path resets the clock to 0 on its own,
        so this cannot manufacture a false stall.
    .PARAMETER Reason
        'completed' | 'stalled' | 'maxlifetime'.
    .PARAMETER StallLimitSec
        Config's StallSec.
    .PARAMETER DebounceSec
        Config's DebounceSec -- the retry cadence the re-arm is aiming for.
    .OUTPUTS
        [int] the value to assign to the stall clock.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Reason,
        [Parameter(Mandatory)][int]$StallLimitSec,
        [Parameter(Mandatory)][int]$DebounceSec
    )

    if ($Reason -ne 'stalled') { return 0 }

    $carried = $StallLimitSec - $DebounceSec
    if ($carried -lt 0) { return 0 }
    return [int]$carried
}

function Get-NextHeartbeatState {
    <#
    .SYNOPSIS
        Pure: advance the "how long have we logged nothing" clock and decide
        whether a heartbeat line is now due. No I/O.
    .DESCRIPTION
        WHY THIS EXISTS. The monitoring loop logs only on polls that are
        INTERESTING: a stall, an idle countdown, an unreadable signal. A
        healthy, actively progressing render logs nothing at all, deliberately,
        so that a long job does not fill the log with thousands of identical
        lines.

        SCOPE. Both of the watchdog's blocking loops use this, and the second
        one was added only after a real run proved the first was not enough:
          1. the pre-GUI wait loop, which polls for a Topaz GUI process and
             otherwise logs nothing at all, and
          2. the main monitoring loop's silent-while-healthy path.
        The 00d21ef version of this function was called only from (2). The
        14:06-14:56 cycle on 2026-07-27 then logged NOTHING for 361s inside
        (1) -- past the 300s bound this function is supposed to enforce -- for
        the mundane reason that the clock variable was declared below that loop
        (docs/15). Any future blocking loop added to this script needs a call
        here too, or it reintroduces exactly that hole.

        Taken to its conclusion that means a healthy render is INVISIBLE. A
        real 4K job on this box ran from 07:55:33 to 12:44:33 -- four hours
        and forty-nine minutes -- during which watchdog.log contains not one
        line (see docs/14). The render was fine, but the log could not
        distinguish that from a watchdog that had crashed, wedged on a hung
        CIM query, or been killed: the evidence for "still alive and working"
        was identical to the evidence for "dead". That is the single worst
        case for a post-mortem, because it is also the longest window.

        So silence is now bounded: after HeartbeatSec of logging nothing, one
        line is emitted. The clock measures SILENCE, not wall time -- every
        branch that logs resets it -- so a stalling render that already logs
        every poll gains no extra noise, and the heartbeat only ever appears
        where there would otherwise be a void.

        Cost at the defaults (PollSec=15, HeartbeatSec=300): one line per five
        minutes of healthy rendering, i.e. ~12/hour, ~60 lines for the
        five-hour render above -- against a 5 MB rotation threshold.
    .PARAMETER SilentSec
        Seconds of consecutive un-logged polls so far.
    .PARAMETER PollSec
        Config's PollSec; how much this poll adds.
    .PARAMETER HeartbeatSec
        Config's HeartbeatSec. Zero or negative DISABLES heartbeats entirely
        (restoring the previous silent-while-healthy behaviour), in which case
        the clock is pinned at 0 so it cannot quietly accumulate.
    .OUTPUTS
        [pscustomobject] @{ SilentSec = <int>; Due = <bool> }
        Due = $true means the caller should log now; SilentSec is already
        reset to 0 in that case, so the caller never has to remember to.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$SilentSec,
        [Parameter(Mandatory)][int]$PollSec,
        [Parameter(Mandatory)][int]$HeartbeatSec
    )

    if ($HeartbeatSec -le 0) {
        return [pscustomobject]@{ SilentSec = 0; Due = $false }
    }

    $next = $SilentSec + $PollSec
    if ($next -ge $HeartbeatSec) {
        return [pscustomobject]@{ SilentSec = 0; Due = $true }
    }

    return [pscustomobject]@{ SilentSec = $next; Due = $false }
}

function Get-TopazWaitHeartbeatMessage {
    <#
    .SYNOPSIS
        Pure: the heartbeat line the pre-GUI wait loop emits. No I/O.
    .DESCRIPTION
        Exists to make the wait loop's heartbeat TESTABLE. The loop itself sits
        inside the "$MyInvocation.InvocationName -ne '.'" guard at the bottom of
        this file, which dot-sourcing (and therefore Pester) never executes -- so
        anything expressed inline there is, structurally, untestable. This file
        already resolves that tension the same way everywhere else (see
        Get-NextWatchdogState, Get-NextHeartbeatState, Resolve-StopDecision):
        the DECISION is a pure function and the guarded block keeps only
        orchestration. This function carries the one piece of that heartbeat
        with any judgement in it.

        WHAT THE JUDGEMENT IS. Get-TopazPids returns $null when the CIM query
        FAILED and @() when it succeeded and found nothing. Both make the wait
        loop go round again, and before the heartbeat existed both looked
        identical in the log -- identical, too, to a watchdog that had died. A
        query failing every poll forever is a FAULT and needs to read as one; an
        operator who simply has not opened Topaz yet is the normal case. Saying
        which is which is the entire value of the line.
    .PARAMETER TopazPids
        The most recent Get-TopazPids result: $null (query failed) or a
        collection (query succeeded).
    .PARAMETER NameLike
        Config's TopazNameLike, echoed so the log says what it was looking for.
    .PARAMETER HeartbeatSec
        Config's HeartbeatSec, echoed so the reader knows the cadence to expect
        and can therefore spot a MISSING heartbeat.
    .OUTPUTS
        [string] the full log message.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]$TopazPids,
        [Parameter(Mandatory)][AllowEmptyString()][string]$NameLike,
        [Parameter(Mandatory)][int]$HeartbeatSec
    )

    $waitText = if ($null -eq $TopazPids) { 'CIM process query UNREADABLE' } else { 'not running' }
    return "Still waiting for a Topaz GUI process (LIKE '$NameLike'): $waitText. Heartbeat every ${HeartbeatSec}s while waiting."
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

    # Seconds of consecutive un-logged polls -- the heartbeat clock. Declared
    # HERE, above the wait loop, and not (as it first was) just above the
    # monitoring loop below.
    #
    # MEASURED 2026-07-27: this wait loop produced 361s of TOTAL silence
    # (14:06:57.451 -> 14:12:58.709, docs/15) which SURVIVED the heartbeat added
    # in 00d21ef, because the clock was declared below this loop and so could
    # not reach it. That left the one blind spot the heartbeat was supposed to
    # remove: a watchdog wedged on a hung CIM query here logs exactly what one
    # patiently waiting for the operator to open Topaz logs -- nothing.
    $silentSec = 0

    # Get-TopazPids now returns $null on a CIM query failure (vs. @() for "query
    # succeeded, nothing found"). Treat $null the same as "not seen yet" here and
    # keep retrying -- testing $null.Count directly would silently treat a query
    # failure as "0 found -> Topaz GUI detected", which is backwards.
    while ($true) {
        $topazPids = Get-TopazPids
        if ($topazPids -and $topazPids.Count -gt 0) { break }

        Start-Sleep -Seconds $cfg.PollSec

        $beat = Get-NextHeartbeatState -SilentSec $silentSec -PollSec $cfg.PollSec `
            -HeartbeatSec $cfg.HeartbeatSec
        $silentSec = $beat.SilentSec
        if ($beat.Due) {
            # The message (and the $null-vs-@() distinction that gives it its
            # value) is the pure Get-TopazWaitHeartbeatMessage above, so it is
            # unit-tested despite this loop living inside the dot-source guard.
            Write-TopazLog -Component 'watchdog' -Level 'INFO' `
                -Message (Get-TopazWaitHeartbeatMessage -TopazPids $topazPids `
                    -NameLike $cfg.TopazNameLike -HeartbeatSec $cfg.HeartbeatSec)
        }
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
    # RESET (not declaration -- see above the wait loop): the "Topaz GUI
    # detected" line immediately above just broke the silence, so the clock
    # restarts here rather than carrying the wait loop's tail into monitoring.
    $silentSec   = 0

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
                # This poll DID log, so the silence clock restarts.
                $silentSec = 0
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
                    $silentSec = 0

                    if ($state.Verdict -eq 'stalled') {
                        Write-TopazLog -Component 'watchdog' -Level 'WARN' `
                            -Message "Output stalled for ${stallSec}s with an active render. Treating render as STALLED."
                        $reason = 'stalled'
                        break
                    }
                }
                else {
                    # THE ONLY SILENT PATH IN THIS LOOP: a healthy, progressing
                    # render. Left alone it produces an unbroken void in the log
                    # for the entire length of a job -- 4 h 49 m on the render in
                    # docs/14 -- during which "working fine" and "watchdog dead"
                    # look exactly alike. Bound that silence with a heartbeat.
                    $hb = Get-NextHeartbeatState -SilentSec $silentSec `
                        -PollSec $cfg.PollSec -HeartbeatSec $cfg.HeartbeatSec
                    $silentSec = $hb.SilentSec

                    if ($hb.Due) {
                        $armText = if ($sawActivity) { 'armed' } else { "arming ${activeSec}s/$($cfg.ArmSec)s" }
                        Write-TopazLog -Component 'watchdog' -Level 'INFO' `
                            -Message "Render progressing (worker=$workerText gpu=$gpuText, $armText): active=${activeSec}s, outputBytes=$currentBytes, workerIoBytes=$ioText. Heartbeat every $($cfg.HeartbeatSec)s while healthy."
                    }
                }
            }
            else {
                # Every branch below logs, so the silence clock restarts here.
                $silentSec = 0
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

            # ---------------------------------------------------------------------------
            # CORRECTION 3 (2026-07-28): upload each render AS IT FINISHES, not
            # only after the whole queue drains. Deliberately placed AFTER the
            # idle/stall/arm state-machine update above (not before, not
            # interleaved with it) and UNCONDITIONALLY -- not inside either the
            # $active or the "no active render" branch -- because a file can
            # finish and need protecting WHILE THE NEXT QUEUE ITEM IS ALREADY
            # RENDERING, which is exactly the gap that left a 2.3 GB completed
            # render unprotected for the full duration of a subsequent export
            # in the 2026-07-28 incident. See Invoke-TopazIncrementalUploadPoll's
            # own comment for why this ordering is safe for the timing of the
            # bookkeeping above, and why a blocking rclone call inside this
            # single-threaded loop is an accepted, bounded tradeoff rather than
            # an oversight.
            Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:UploadTracking
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
        # 3a. Snapshot OutputDir's real file count + byte total AT HANDOFF, right
        #     after the unlock gate above -- not during the live poll loop.
        #
        #     THIS READING IS TRUSTWORTHY IN A WAY THE LIVE outputBytes SIGNAL IS
        #     NOT. Get-NextWatchdogState's outputBytes is read WHILE a render may
        #     still be writing, and NTFS does not reliably refresh an open
        #     handle's directory-entry length (measured frozen for up to 476s
        #     mid-render -- see Get-WorkerIoBytes's own comment), so a live
        #     reading can legitimately UNDERCOUNT a perfectly healthy job. By
        #     THIS point every non-scratch output file has just been confirmed
        #     unlocked (or the wait above timed out trying), so every handle
        #     that could still be growing a file is gone: whatever Get-ChildItem
        #     reports here is the ACTUAL, FINAL state of the folder, not a
        #     lagging snapshot.
        #
        #     THIS IS EXACTLY THE LINE THE 2026-07-28 INCIDENT WAS MISSING. The
        #     "Render QUEUE considered COMPLETE" line said nothing about what
        #     was actually produced; Stop-Sequence.ps1 independently re-read
        #     OutputDir moments later and logged "is empty; ... Safe to
        #     proceed" with nothing in watchdog.log to compare it against. Two
        #     independently-written logs agreeing (or, just as usefully,
        #     DISAGREEING because the folder changed between the two reads) is
        #     worth one extra line here.
        # ---------------------------------------------------------------------------

        $handoffFiles    = @(Get-ChildItem -LiteralPath $cfg.OutputDir -Recurse -File -ErrorAction SilentlyContinue)
        $handoffBytesSum = ($handoffFiles | Measure-Object -Property Length -Sum).Sum
        $handoffBytes    = if ($null -eq $handoffBytesSum) { [int64]0 } else { [int64]$handoffBytesSum }

        Write-TopazLog -Component 'watchdog' -Level 'INFO' `
            -Message "OutputDir '$($cfg.OutputDir)' at handoff (reason=$reason): $($handoffFiles.Count) file(s), $handoffBytes bytes. This is a post-unlock-gate reading (handles closed) -- unlike the live outputBytes logged during polling, this one is not subject to NTFS directory-entry lag and can be trusted as final."

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

        # Stop-Sequence.ps1 returns $false when it REFUSED to stop -- most
        # importantly when the renders in OutputDir could not be uploaded and
        # OutputDir is on the ephemeral scratch volume. This return value is
        # only trustworthy because Write-TopazLog no longer writes to the
        # output stream; see its comment in Config.ps1.
        $stopResult = & (Join-Path $PSScriptRoot 'Stop-Sequence.ps1') -Reason $reason

        if ($stopResult -eq $false) {
            # DO NOT exit. Exiting here would leave nothing watching a box that
            # is still running, still billing, and still holding an un-uploaded
            # render on a volume the out-of-band CloudWatch idle alarm will
            # erase within ~30 minutes. Re-arm instead, so the debounce elapses
            # again and the whole completed -> unlock -> upload path RETRIES
            # roughly every DebounceSec until the upload finally succeeds.
            #
            # SawActivity/ActiveSec are restored to their armed values rather
            # than reset: a render demonstrably happened, and forcing it to
            # re-earn ArmSec would mean the retry never fires at all once the
            # worker has exited.
            # Do NOT name a cause here. Stop-Sequence.ps1 returns $false for
            # three distinct reasons -- ephemeral OutputDir with no
            # UploadTarget, an upload that failed or could not be verified, and
            # every action in the stop plan failing (e.g. ec2:StopInstances
            # denied). Only stop.log knows which. Asserting "the upload failed"
            # would send an operator hunting through rclone while the actual
            # fault was an IAM permission.
            $stallSec = Resolve-RefusalStallSec -Reason $reason `
                -StallLimitSec $cfg.StallSec -DebounceSec $cfg.DebounceSec

            $retryInSec = if ($reason -eq 'stalled') { $cfg.StallSec - $stallSec } else { $cfg.DebounceSec }

            Write-TopazLog -Component 'watchdog' -Level 'WARN' `
                -Message "Stop-Sequence REFUSED to stop (reason=$reason). See stop.log for which guard fired: no UploadTarget on ephemeral storage, a failed/unverified upload, or every stop action failing. The instance stays UP so nothing is lost. Re-arming to retry in ~${retryInSec}s."

            $idleSec     = 0
            $sawActivity = $true
            $activeSec   = $cfg.ArmSec
            $lastBytes   = Get-OutputBytes
            $lastIoBytes = $null
            continue outer
        }

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
