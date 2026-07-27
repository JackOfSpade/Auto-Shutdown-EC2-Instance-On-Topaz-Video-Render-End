<#
.SYNOPSIS
    Pester 5 unit tests for the pure/testable helpers in in-guest/Watchdog.ps1.

.DESCRIPTION
    Watchdog.ps1 dot-sources Config.ps1 itself, so dot-sourcing Watchdog.ps1
    here pulls in both files' functions in one step. This is safe on any
    platform, including non-Windows pwsh, because of the dot-source guard
    around Watchdog.ps1's top-level executable tail (the "wait for Topaz" /
    outer monitoring loop): dot-sourcing only DEFINES functions, it never
    runs that Windows-only, blocking code.

    Run with:
        Invoke-Pester -Path in-guest/tests -CI
#>

BeforeAll {
    . "$PSScriptRoot/../Watchdog.ps1"
}

Describe 'Test-RenderActive (regression for the A1 [ref]/PSReference bug)' {
    # The bug: Test-RenderActive used to take [ref]$WorkerActive/[ref]$GpuValue
    # out-params, then assign to local $workerActive/$gpuValue -- PowerShell
    # variable names are case-insensitive, so those locals WERE the [ref]
    # parameters, and assigning a plain value to them wrapped it in a second,
    # disconnected PSReference. The Resolve-RenderActive call inside then
    # received a PSReference-of-PSReference and rejected it via its own type
    # validation -- an uncaught terminating error on every single poll. These
    # tests assert the fixed, ref-free contract: a plain pscustomobject whose
    # Active/WorkerActive fields are real booleans or $null, never PSReference.

    Context 'workers present' {
        BeforeEach {
            Mock Get-TopazWorkers { return @([pscustomobject]@{ ProcessId = 111 }) }
            Mock Get-GpuUtilizationMax { return $null }
        }

        It 'does not throw and returns Active=$true / WorkerActive=$true as plain booleans, plus an IoBytes total (0 when the fake worker exposes no transfer counters)' {
            { Test-RenderActive } | Should -Not -Throw
            $result = Test-RenderActive

            $result.Active | Should -Not -BeOfType [System.Management.Automation.PSReference]
            $result.Active | Should -BeOfType [bool]
            $result.Active | Should -Be $true

            $result.WorkerActive | Should -BeOfType [bool]
            $result.WorkerActive | Should -Be $true

            # IoBytes describes the SAME worker set the Active decision came
            # from (see Test-RenderActive's own comment on why it is carried
            # here rather than re-queried) -- 1 worker with no
            # ReadTransferCount/WriteTransferCount property contributes 0, not
            # $null: the worker signal itself IS readable here.
            $result.IoBytes | Should -Be 0
        }
    }

    Context 'no workers' {
        BeforeEach {
            # The leading comma matters: a bare 'return @()' collapses to
            # $null through PowerShell's pipeline/return semantics (the same
            # array-vs-null landmine Get-TopazPids/Resolve-WorkerAttribution
            # guard against with their own comma), which would make this mock
            # indistinguishable from the "unknown" case it is NOT testing.
            Mock Get-TopazWorkers { return , @() }
            Mock Get-GpuUtilizationMax { return $null }
        }

        It 'does not throw and returns Active=$false / WorkerActive=$false (WorkerOrGpu signal, GPU unreadable), IoBytes=0 (worker signal readable, zero workers)' {
            { Test-RenderActive } | Should -Not -Throw
            $result = Test-RenderActive

            $result.Active | Should -Not -BeOfType [System.Management.Automation.PSReference]
            $result.Active | Should -BeOfType [bool]
            $result.Active | Should -Be $false

            $result.WorkerActive | Should -BeOfType [bool]
            $result.WorkerActive | Should -Be $false

            $result.IoBytes | Should -Be 0
        }
    }

    Context 'workers unknown ($null)' {
        BeforeEach {
            Mock Get-TopazWorkers { return $null }
            Mock Get-GpuUtilizationMax { return $null }
        }

        It 'does not throw and returns Active=$null (not a PSReference, not a guessed value), IoBytes=$null (worker signal itself unreadable)' {
            { Test-RenderActive } | Should -Not -Throw
            $result = Test-RenderActive

            $result.Active | Should -Not -BeOfType [System.Management.Automation.PSReference]
            $result.Active | Should -Be $null

            $result.WorkerActive | Should -Be $null

            $result.IoBytes | Should -Be $null
        }
    }
}

Describe 'Resolve-ProcessDescendants' {
    # THE REASON THIS FUNCTION EXISTS: see its own header comment in
    # Watchdog.ps1. The watchdog used to attribute a worker to Topaz by
    # testing the worker's ParentProcessId against the GUI's PID directly (a
    # ONE-LEVEL check). The real Topaz process tree is
    #     Topaz Video.exe  ->  neuroserver.exe  ->  ffmpeg.exe
    # so ffmpeg.exe is a GRANDCHILD, and a one-level test never matches it --
    # the watchdog observed "no worker" for the entire life of every render
    # and never fired at all. These tests exercise the pure BFS-over-a-
    # parent/child index at every depth the real topology (and beyond) needs.

    BeforeAll {
        function Get-FakeProc {
            param([int]$ProcessId, [int]$ParentProcessId)
            [pscustomobject]@{ ProcessId = $ProcessId; ParentProcessId = $ParentProcessId }
        }
    }

    It 'returns a DIRECT CHILD of a single root' {
        $all = @(
            (Get-FakeProc -ProcessId 100 -ParentProcessId 1),   # root (GUI)
            (Get-FakeProc -ProcessId 200 -ParentProcessId 100)  # direct child
        )

        $result = Resolve-ProcessDescendants -AllProcesses $all -RootPids @(100)

        @($result) | Should -Be @(200)
    }

    It 'returns a GRANDCHILD -- the real Topaz topology: GUI -> neuroserver.exe -> ffmpeg.exe' {
        $all = @(
            (Get-FakeProc -ProcessId 100 -ParentProcessId 1),   # GUI (root)
            (Get-FakeProc -ProcessId 300 -ParentProcessId 100), # neuroserver.exe (child)
            (Get-FakeProc -ProcessId 500 -ParentProcessId 300)  # ffmpeg.exe (grandchild)
        )

        $result = Resolve-ProcessDescendants -AllProcesses $all -RootPids @(100)

        (@($result) | Sort-Object) | Should -Be @(300, 500)
    }

    It 'returns a GREAT-GRANDCHILD (depth 3), proving the walk is not hard-limited to 2 levels' {
        $all = @(
            (Get-FakeProc -ProcessId 100 -ParentProcessId 1),
            (Get-FakeProc -ProcessId 200 -ParentProcessId 100),
            (Get-FakeProc -ProcessId 300 -ParentProcessId 200),
            (Get-FakeProc -ProcessId 400 -ParentProcessId 300)
        )

        $result = Resolve-ProcessDescendants -AllProcesses $all -RootPids @(100)

        (@($result) | Sort-Object) | Should -Be @(200, 300, 400)
    }

    It 'unions descendants across MULTIPLE roots (e.g. two Topaz GUI instances running side by side)' {
        $all = @(
            (Get-FakeProc -ProcessId 100 -ParentProcessId 1),   # root A
            (Get-FakeProc -ProcessId 101 -ParentProcessId 1),   # root B
            (Get-FakeProc -ProcessId 200 -ParentProcessId 100), # child of A
            (Get-FakeProc -ProcessId 201 -ParentProcessId 101)  # child of B
        )

        $result = Resolve-ProcessDescendants -AllProcesses $all -RootPids @(100, 101)

        (@($result) | Sort-Object) | Should -Be @(200, 201)
    }

    It 'returns $null when RootPids is $null (ancestry unknowable -- never collapsed into "no descendants")' {
        $all = @((Get-FakeProc -ProcessId 100 -ParentProcessId 1))

        Resolve-ProcessDescendants -AllProcesses $all -RootPids $null | Should -Be $null
    }

    It 'returns an EMPTY array (not $null) when RootPids is @() -- the root query succeeded and simply found none' {
        $all = @((Get-FakeProc -ProcessId 100 -ParentProcessId 1))

        $result = Resolve-ProcessDescendants -AllProcesses $all -RootPids @()

        ($null -eq $result) | Should -Be $false
        @($result).Count | Should -Be 0
    }

    It 'EXCLUDES the roots themselves from the result -- callers want workers spawned BY the GUI, never the GUI itself' {
        $all = @(
            (Get-FakeProc -ProcessId 100 -ParentProcessId 1),
            (Get-FakeProc -ProcessId 200 -ParentProcessId 100)
        )

        $result = Resolve-ProcessDescendants -AllProcesses $all -RootPids @(100)

        @($result) -contains 100 | Should -Be $false
    }

    It 'terminates instead of hanging on a PID-REUSE cycle in the apparent tree' {
        # Windows recycles PIDs. The GUI (100)'s own ParentProcessId can, by
        # coincidence, equal the PID of a process that is CURRENTLY a live
        # child of the GUI (999) -- its ParentProcessId field was fixed at
        # creation time and never updated, so this is a plausible real
        # snapshot, not a contrived one. That makes 100 and 999 mutually
        # "children" of each other in the parent/child index built from
        # ParentProcessId alone. Without the $seen guard in
        # Resolve-ProcessDescendants this would spin the BFS queue forever
        # inside a SYSTEM task -- the only thing this test requires is that
        # the call returns at all (Pester's own run would hang/timeout
        # otherwise).
        $all = @(
            (Get-FakeProc -ProcessId 100 -ParentProcessId 999),
            (Get-FakeProc -ProcessId 999 -ParentProcessId 100)
        )

        $result = Resolve-ProcessDescendants -AllProcesses $all -RootPids @(100)

        # The call returned at all -- that is the regression this guards
        # against. 999 is unambiguously a descendant of 100 either way.
        @($result) -contains 999 | Should -Be $true
    }
}

Describe 'Resolve-WorkerAttribution' {
    # DescendantPids replaced TopazPids: attribution now keys off the WORKER's
    # OWN ProcessId being present in DescendantPids (the full-depth ancestry
    # set computed by Resolve-ProcessDescendants), not the worker's
    # ParentProcessId being a live Topaz GUI PID directly. Test fixtures below
    # therefore pass the worker's own PID in -DescendantPids, not its parent's
    # -- passing the parent's PID (the old semantics) would no longer match
    # anything and is exactly the regression this rewrite guards against.

    It 'adopts a worker whose PID is a live descendant of the Topaz GUI and records it in KnownWorkers' {
        $known  = @{}
        $worker = [pscustomobject]@{ ProcessId = 500; ParentProcessId = 100; CreationDate = [datetime]'2026-01-01T00:00:00' }

        $result = Resolve-WorkerAttribution -DescendantPids @(500) -Workers @($worker) -KnownWorkers $known

        @($result).Count | Should -Be 1
        $result[0].ProcessId | Should -Be 500
        $key = "500|$($worker.CreationDate.Ticks)"
        $known.ContainsKey($key) | Should -Be $true
    }

    It 'matches a GRANDCHILD worker (ffmpeg.exe under neuroserver.exe under the GUI) -- the exact regression that made the watchdog inert when attribution only checked one-level ParentProcessId' {
        # Real Topaz topology: Topaz Video.exe (100) -> neuroserver.exe (300)
        # -> ffmpeg.exe (500). ffmpeg's ParentProcessId is neuroserver's PID
        # (300), NOT the GUI's PID (100) -- a one-level ParentProcessId test
        # against the GUI's own PID would NEVER match it, which is exactly
        # how the watchdog used to observe "no worker" for the entire life of
        # every render and never fire at all. DescendantPids (computed over
        # the WHOLE tree by Resolve-ProcessDescendants) correctly contains
        # 500 at depth 2, and attribution here matches on the worker's OWN
        # PID, so the grandchild is matched.
        $known  = @{}
        $ffmpeg = [pscustomobject]@{ ProcessId = 500; ParentProcessId = 300; CreationDate = [datetime]'2026-01-01T00:00:00' }

        $result = Resolve-WorkerAttribution -DescendantPids @(300, 500) -Workers @($ffmpeg) -KnownWorkers $known

        @($result).Count | Should -Be 1
        $result[0].ProcessId | Should -Be 500
        $known.ContainsKey("500|$($ffmpeg.CreationDate.Ticks)") | Should -Be $true
    }

    It 'keeps counting an orphan whose key is already in KnownWorkers, even when DescendantPids is @() (empty, not $null)' {
        $worker = [pscustomobject]@{ ProcessId = 500; ParentProcessId = 999; CreationDate = [datetime]'2026-01-01T00:00:00' }
        $key    = "500|$($worker.CreationDate.Ticks)"
        $known  = @{ $key = $true }

        $result = Resolve-WorkerAttribution -DescendantPids @() -Workers @($worker) -KnownWorkers $known

        @($result).Count | Should -Be 1
        $result[0].ProcessId | Should -Be 500
    }

    It 'returns $null when DescendantPids is $null and no KnownWorkers entry matches (genuinely unknown, not "no worker")' {
        $known  = @{}
        $result = Resolve-WorkerAttribution -DescendantPids $null -Workers @() -KnownWorkers $known

        $result | Should -Be $null
    }

    It 'matches via KnownWorkers when DescendantPids is $null but the worker is already known' {
        $worker = [pscustomobject]@{ ProcessId = 500; ParentProcessId = 999; CreationDate = [datetime]'2026-01-01T00:00:00' }
        $key    = "500|$($worker.CreationDate.Ticks)"
        $known  = @{ $key = $true }

        $result = Resolve-WorkerAttribution -DescendantPids $null -Workers @($worker) -KnownWorkers $known

        @($result).Count | Should -Be 1
        $result[0].ProcessId | Should -Be 500
    }

    It 'prunes a KnownWorkers key that does not appear in this poll''s Workers' {
        $known  = @{ 'stale|123' = $true }
        $result = Resolve-WorkerAttribution -DescendantPids @() -Workers @() -KnownWorkers $known

        @($result).Count | Should -Be 0
        $known.ContainsKey('stale|123') | Should -Be $false
    }

    It 'does NOT match the same ProcessId under a different CreationDate (distinct process; old key is pruned)' {
        $oldCreation = [datetime]'2026-01-01T00:00:00'
        $newCreation = [datetime]'2026-01-02T00:00:00'
        $oldKey      = "500|$($oldCreation.Ticks)"
        $known       = @{ $oldKey = $true }
        $newWorker   = [pscustomobject]@{ ProcessId = 500; ParentProcessId = 999; CreationDate = $newCreation }

        $result = Resolve-WorkerAttribution -DescendantPids @() -Workers @($newWorker) -KnownWorkers $known

        @($result).Count | Should -Be 0
        $known.ContainsKey($oldKey) | Should -Be $false
    }
}

Describe 'Get-TopazWorkers (real end-to-end delegation, not just Resolve-WorkerAttribution in isolation)' {
    # The Describe block above tests Resolve-WorkerAttribution directly, which
    # never exercises Get-TopazWorkers's own delegation chain (Get-TopazPids's
    # comma-protected CIM-wrapping return, the ancestry snapshot query,
    # Resolve-ProcessDescendants, and finally
    # `Resolve-WorkerAttribution -DescendantPids ... -Workers ... -KnownWorkers ...`).
    # These tests let ALL of those real function bodies run, with only the
    # underlying Get-CimInstance CIM call replaced.
    #
    # Get-CimInstance's CimCmdlets module is Windows-only and not present on
    # non-Windows pwsh (this whole file is dot-sourced cross-platform, per the
    # file header), so it cannot be Pester-`Mock`ed directly here -- Mock
    # requires the target command to already resolve. A plain function
    # definition in this Describe's own BeforeAll stands in for it instead:
    # PowerShell resolves an unqualified command name against the Function:
    # scope before Cmdlet:, so Get-TopazPids/Get-TopazWorkers's real,
    # unmodified bodies pick it up with no change to Watchdog.ps1 itself.
    #
    # This is what would catch a regression like dropping the leading unary
    # comma from Get-TopazPids's `return , @(...)`: doing so does not change
    # what the Resolve-WorkerAttribution tests above see (they call it
    # directly with an already-flat array), but it DOES turn the "0 Topaz
    # GUIs / 0 workers" case from a confident empty array into $null
    # ("unknown") once it flows through Get-TopazWorkers's real call chain --
    # the first assertion below (`Should -Not -Be $null`) fails if that
    # happens.

    BeforeAll {
        function Get-CimInstance {
            # Deliberately shadows the built-in cmdlet name -- see this
            # Describe block's own comment above for why. Windows PowerShell
            # 5.1 production code never defines this function (this file is
            # test-only), so there is no risk of this shadow leaking into the
            # real pipeline.
            [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '')]
            # [CmdletBinding()] makes -ErrorAction a common parameter PowerShell
            # supports automatically (as the real Get-CimInstance calls in
            # Watchdog.ps1 pass -ErrorAction Stop), without declaring it by hand
            # and tripping PSReviewUnusedParameter for never reading it.
            # -OperationTimeoutSec is declared for the same reason as
            # -Property: every real Get-CimInstance call in Watchdog.ps1's
            # polling path now bounds itself with it (so a wedged CIM provider
            # cannot hang the watchdog forever), and a shadow that does not
            # accept the parameter fails those calls with
            # ParameterBindingException instead of exercising the code under
            # test. The value itself is irrelevant here -- this shadow never
            # blocks -- so it is accepted and ignored.
            [CmdletBinding()]
            param(
                [string]$ClassName,
                [string]$Filter,
                [string[]]$Property,
                [int]$OperationTimeoutSec
            )

            if ($ClassName -ne 'Win32_Process') {
                throw "Test shadow Get-CimInstance only supports ClassName 'Win32_Process' (got '$ClassName')."
            }

            # Get-TopazWorkers's ancestry snapshot query passes -Property (and
            # no -Filter at all) to pull EVERY process on the box, not just
            # the Topaz GUI or the worker subset -- Resolve-ProcessDescendants
            # needs the WHOLE tree (including any intermediate process, e.g.
            # neuroserver.exe) to walk from the GUI PID down to a grandchild
            # like ffmpeg.exe. Without this branch, that call fell through to
            # the -Filter matching below with an empty/absent -Filter and
            # silently returned only $script:FakeWorkerProcs, which is wrong
            # for a multi-hop tree. (Before this shadow accepted -Property at
            # all, this call threw ParameterBindingException -- the exact
            # regression this branch exists to fix in the tests.)
            if ($PSBoundParameters.ContainsKey('Property')) {
                return @($script:FakeTopazProcs + $script:FakeWorkerProcs)
            }

            if ($Filter -like "*$($cfg.TopazNameLike)*") { return $script:FakeTopazProcs }
            return $script:FakeWorkerProcs
        }

        function Get-FakeTopazProc {
            param([int]$ProcessId, [int]$ParentProcessId = 0)
            [pscustomobject]@{
                ProcessId       = $ProcessId
                ParentProcessId = $ParentProcessId
                CreationDate    = [datetime]'2026-01-01T00:00:00'
            }
        }
    }

    BeforeEach {
        $script:KnownWorkers    = @{}
        $script:FakeTopazProcs  = @()
        $script:FakeWorkerProcs = @()
    }

    It 'returns a flat, non-nested EMPTY array (not $null) for 0 Topaz GUIs / 0 workers' {
        $result = Get-TopazWorkers

        # ($null -eq $result), NOT '$result | Should -Not -Be $null': $result is
        # a genuinely 0-element array here, and PIPING a 0-element array into
        # Should delivers ZERO pipeline items -- Should never receives
        # $result at all, so it silently falls back to comparing its own
        # unset-default $null against $null and (wrongly) reports a match.
        # Evaluating the -eq comparison first (scalar $null on the LEFT, so no
        # array-unrolling) yields a plain boolean that pipes into Should with
        # exactly one item every time, regardless of $result's element count.
        ($null -eq $result) | Should -Be $false
        $result -is [array] | Should -Be $true
        @($result).Count | Should -Be 0
    }

    It 'returns a flat 1-element array for 1 Topaz GUI with 1 matching worker' {
        $script:FakeTopazProcs  = @(Get-FakeTopazProc -ProcessId 100)
        $script:FakeWorkerProcs = @(Get-FakeTopazProc -ProcessId 500 -ParentProcessId 100)

        $result = Get-TopazWorkers

        $result -is [array] | Should -Be $true
        @($result).Count | Should -Be 1
        $result[0].ProcessId | Should -Be 500
    }

    It 'returns a flat 2-element array for 1 Topaz GUI with 2 matching workers' {
        $script:FakeTopazProcs  = @(Get-FakeTopazProc -ProcessId 100)
        $script:FakeWorkerProcs = @(
            (Get-FakeTopazProc -ProcessId 500 -ParentProcessId 100),
            (Get-FakeTopazProc -ProcessId 501 -ParentProcessId 100)
        )

        $result = Get-TopazWorkers

        $result -is [array] | Should -Be $true
        @($result).Count | Should -Be 2
    }

    It 'attributes a GRANDCHILD worker end-to-end (GUI -> neuroserver.exe -> ffmpeg.exe), not just via Resolve-WorkerAttribution called directly' {
        # The WorkerNamesLike WQL filter matches BOTH configured patterns, so
        # the real worker CIM query would return neuroserver.exe (the direct
        # child) AND ffmpeg.exe (the grandchild) together. This exercises the
        # full chain -- Get-TopazPids -> ancestry snapshot ->
        # Resolve-ProcessDescendants -> Resolve-WorkerAttribution -- with no
        # shortcuts, so it would catch a regression anywhere in that chain,
        # not only in Resolve-WorkerAttribution's own matching logic.
        $script:FakeTopazProcs  = @(Get-FakeTopazProc -ProcessId 100)
        $script:FakeWorkerProcs = @(
            (Get-FakeTopazProc -ProcessId 300 -ParentProcessId 100), # neuroserver.exe (child)
            (Get-FakeTopazProc -ProcessId 500 -ParentProcessId 300)  # ffmpeg.exe (grandchild)
        )

        $result = Get-TopazWorkers

        @($result).Count | Should -Be 2
        (@($result | ForEach-Object { $_.ProcessId }) | Sort-Object) | Should -Be @(300, 500)
    }
}

Describe 'Get-WorkerIoBytes' {
    # THE REASON THIS FUNCTION EXISTS: see its own header comment in
    # Watchdog.ps1. The output-folder byte count is not a reliable progress
    # signal on NTFS (an open writer's directory entry was measured frozen
    # for 476 consecutive seconds mid-render on this deployment) -- a
    # process's ReadTransferCount/WriteTransferCount counters advance on
    # every write regardless, which is what the stall detector actually
    # wants.

    It 'returns $null when Workers is $null (the worker signal itself was unreadable this poll)' {
        Get-WorkerIoBytes -Workers $null | Should -Be $null
    }

    It 'returns 0 for an empty Workers array (worker signal readable, zero workers)' {
        Get-WorkerIoBytes -Workers @() | Should -Be 0
    }

    It 'sums ReadTransferCount + WriteTransferCount across MULTIPLE workers' {
        $workers = @(
            [pscustomobject]@{ ReadTransferCount = 100; WriteTransferCount = 50 },
            [pscustomobject]@{ ReadTransferCount = 200; WriteTransferCount = 25 }
        )

        Get-WorkerIoBytes -Workers $workers | Should -Be 375
    }

    It 'tolerates a worker missing a counter entirely (property absent, not just $null) by treating it as 0' {
        $workers = @(
            [pscustomobject]@{ ReadTransferCount = 100 },                      # WriteTransferCount absent
            [pscustomobject]@{ ReadTransferCount = 200; WriteTransferCount = 25 }
        )

        { Get-WorkerIoBytes -Workers $workers } | Should -Not -Throw
        Get-WorkerIoBytes -Workers $workers | Should -Be 325
    }
}

Describe 'Get-NextWatchdogState' {

    Context 'stall accrual' {
        It 'hits the stalled verdict exactly at the boundary poll, with unchanged bytes on repeated active polls' {
            $state = [pscustomobject]@{ IdleSec = 0; StallSec = 0; SawActivity = $false; LastBytes = [int64]1000 }

            # Poll 1: stall=10, below the 30s limit -> continue.
            $state = Get-NextWatchdogState -IdleSec $state.IdleSec -StallSec $state.StallSec -SawActivity $state.SawActivity `
                -LastBytes $state.LastBytes -Active $true -CurrentBytes 1000 -PollSec 10 -DebounceSec 120 -StallLimitSec 30
            $state.StallSec | Should -Be 10
            $state.Verdict  | Should -Be 'continue'

            # Poll 2: stall=20, still below the limit -> continue.
            $state = Get-NextWatchdogState -IdleSec $state.IdleSec -StallSec $state.StallSec -SawActivity $state.SawActivity `
                -LastBytes $state.LastBytes -Active $true -CurrentBytes 1000 -PollSec 10 -DebounceSec 120 -StallLimitSec 30
            $state.StallSec | Should -Be 20
            $state.Verdict  | Should -Be 'continue'

            # Poll 3: stall=30, exactly at the limit (-ge boundary) -> stalled.
            $state = Get-NextWatchdogState -IdleSec $state.IdleSec -StallSec $state.StallSec -SawActivity $state.SawActivity `
                -LastBytes $state.LastBytes -Active $true -CurrentBytes 1000 -PollSec 10 -DebounceSec 120 -StallLimitSec 30
            $state.StallSec | Should -Be 30
            $state.Verdict  | Should -Be 'stalled'
        }
    }

    Context 'byte-delta stall reset' {
        It 'resets the stall counter on a byte SHRINK, then again on the following GROWTH -- never stalls' {
            # Shrink: 1000 -> 500.
            $afterShrink = Get-NextWatchdogState -IdleSec 0 -StallSec 25 -SawActivity $true `
                -LastBytes 1000 -Active $true -CurrentBytes 500 -PollSec 10 -DebounceSec 120 -StallLimitSec 30
            $afterShrink.StallSec     | Should -Be 0
            $afterShrink.BytesChanged | Should -Be $true
            $afterShrink.Verdict      | Should -Be 'continue'
            $afterShrink.LastBytes    | Should -Be 500

            # Growth from the new lower base: 500 -> 800. Must NOT be judged
            # against the old high-water mark (1000) -- this is exactly the
            # bug the byte-delta (not growth-only) reset comment documents.
            $afterGrowth = Get-NextWatchdogState -IdleSec $afterShrink.IdleSec -StallSec $afterShrink.StallSec `
                -SawActivity $afterShrink.SawActivity -LastBytes $afterShrink.LastBytes -Active $true `
                -CurrentBytes 800 -PollSec 10 -DebounceSec 120 -StallLimitSec 30
            $afterGrowth.StallSec     | Should -Be 0
            $afterGrowth.BytesChanged | Should -Be $true
            $afterGrowth.Verdict      | Should -Be 'continue'
            $afterGrowth.LastBytes    | Should -Be 800
        }
    }

    Context 'pre-render sawActivity guard' {
        It 'never yields "completed" when Active is $false and SawActivity is $false, however much idle accrues' {
            $state = [pscustomobject]@{ IdleSec = 0; StallSec = 0; SawActivity = $false; LastBytes = [int64]0 }

            1..20 | ForEach-Object {
                $state = Get-NextWatchdogState -IdleSec $state.IdleSec -StallSec $state.StallSec -SawActivity $state.SawActivity `
                    -LastBytes $state.LastBytes -Active $false -CurrentBytes $null -PollSec 10 -DebounceSec 120 -StallLimitSec 900
                $state.Verdict     | Should -Be 'continue'
                $state.SawActivity | Should -Be $false
            }

            # 20 * 10s = 200s, well past the 120s debounce -- still never "completed".
            $state.IdleSec | Should -Be 200
        }
    }

    Context 'debounce -> completed' {
        It 'reaches "completed" exactly at the DebounceSec boundary when SawActivity is $true' {
            # idle=110 + poll=10 -> 120, exactly at the 120s debounce (-ge boundary).
            $state = Get-NextWatchdogState -IdleSec 110 -StallSec 0 -SawActivity $true `
                -LastBytes 1000 -Active $false -CurrentBytes $null -PollSec 10 -DebounceSec 120 -StallLimitSec 900
            $state.IdleSec | Should -Be 120
            $state.Verdict | Should -Be 'completed'

            # One poll earlier (110s) must NOT yet be "completed".
            $notYet = Get-NextWatchdogState -IdleSec 100 -StallSec 0 -SawActivity $true `
                -LastBytes 1000 -Active $false -CurrentBytes $null -PollSec 10 -DebounceSec 120 -StallLimitSec 900
            $notYet.IdleSec | Should -Be 110
            $notYet.Verdict | Should -Be 'continue'
        }
    }

    Context 'Active $null freeze' {
        It 'returns ALL bookkeeping unchanged (freeze), regardless of inputs' {
            $state = Get-NextWatchdogState -IdleSec 42 -StallSec 17 -SawActivity $true `
                -LastBytes 9999 -Active $null -CurrentBytes 123456 -PollSec 10 -DebounceSec 120 -StallLimitSec 900

            $state.IdleSec     | Should -Be 42
            $state.StallSec    | Should -Be 17
            $state.SawActivity | Should -Be $true
            $state.LastBytes   | Should -Be 9999
            $state.Verdict     | Should -Be 'continue'
        }
    }

    Context 'I/O-byte-delta stall reset (progress is the UNION of output bytes and worker I/O bytes)' {

        It 'resets StallSec on an I/O delta ALONE, even though output bytes are FROZEN -- the key fix (NTFS directory-entry lag)' {
            # Measured on this deployment: an open writer's directory entry
            # length can sit frozen for hundreds of seconds mid-render even
            # though the process is actively writing. LastBytes/CurrentBytes
            # are IDENTICAL here on purpose -- only the I/O counters move --
            # and progress must still be recognised, or a perfectly healthy
            # job accrues stall time until it is killed.
            $state = Get-NextWatchdogState -IdleSec 0 -StallSec 20 -SawActivity $true `
                -LastBytes 1000 -Active $true -CurrentBytes 1000 `
                -LastIoBytes 5000 -CurrentIoBytes 5200 `
                -PollSec 10 -DebounceSec 120 -StallLimitSec 30

            $state.StallSec     | Should -Be 0
            $state.BytesChanged | Should -Be $true
            $state.Verdict      | Should -Be 'continue'
            $state.LastIoBytes  | Should -Be 5200
            # The output-byte baseline is untouched by an I/O-only progress
            # reset -- it still reflects the (frozen) folder size.
            $state.LastBytes    | Should -Be 1000
        }

        It 'accrues StallSec toward "stalled" when NEITHER output bytes NOR I/O bytes move' {
            # Mirrors the plain 'stall accrual' Context above, but with a
            # non-null, UNCHANGING I/O baseline supplied on every poll -- this
            # is what proves the I/O signal is actually being compared, not
            # merely ignored because it happens to be $null.
            $state = [pscustomobject]@{ IdleSec = 0; StallSec = 0; SawActivity = $true; LastBytes = [int64]1000; LastIoBytes = [int64]5000 }

            # Poll 1: stall=10, below the 30s limit -> continue.
            $state = Get-NextWatchdogState -IdleSec $state.IdleSec -StallSec $state.StallSec -SawActivity $state.SawActivity `
                -LastBytes $state.LastBytes -Active $true -CurrentBytes 1000 `
                -LastIoBytes $state.LastIoBytes -CurrentIoBytes 5000 -PollSec 10 -DebounceSec 120 -StallLimitSec 30
            $state.StallSec | Should -Be 10
            $state.Verdict  | Should -Be 'continue'

            # Poll 2: stall=20, still below the limit -> continue.
            $state = Get-NextWatchdogState -IdleSec $state.IdleSec -StallSec $state.StallSec -SawActivity $state.SawActivity `
                -LastBytes $state.LastBytes -Active $true -CurrentBytes 1000 `
                -LastIoBytes $state.LastIoBytes -CurrentIoBytes 5000 -PollSec 10 -DebounceSec 120 -StallLimitSec 30
            $state.StallSec | Should -Be 20
            $state.Verdict  | Should -Be 'continue'

            # Poll 3: stall=30, exactly at the limit (-ge boundary) -> stalled.
            $state = Get-NextWatchdogState -IdleSec $state.IdleSec -StallSec $state.StallSec -SawActivity $state.SawActivity `
                -LastBytes $state.LastBytes -Active $true -CurrentBytes 1000 `
                -LastIoBytes $state.LastIoBytes -CurrentIoBytes 5000 -PollSec 10 -DebounceSec 120 -StallLimitSec 30
            $state.StallSec | Should -Be 30
            $state.Verdict  | Should -Be 'stalled'
        }

        It 'a $null CurrentIoBytes this poll does not manufacture a false I/O delta and does not erase the previous baseline' {
            # CurrentIoBytes $null means the worker signal was unreadable THIS
            # poll (see Get-WorkerIoBytes / Test-RenderActive) -- ioProgressed
            # requires BOTH LastIoBytes and CurrentIoBytes to be non-null, so
            # this must NOT read as progress. The carried-forward baseline
            # must still be the LAST GOOD reading (5000), not $null/nulled
            # out, so a single unreadable poll does not manufacture a false
            # delta against $null on the very next poll either.
            $state = Get-NextWatchdogState -IdleSec 0 -StallSec 10 -SawActivity $true `
                -LastBytes 1000 -Active $true -CurrentBytes 1000 `
                -LastIoBytes 5000 -CurrentIoBytes $null `
                -PollSec 10 -DebounceSec 120 -StallLimitSec 30

            # Neither signal counted as progress (output frozen, I/O
            # unreadable) -> stall time accrues rather than resetting.
            $state.StallSec     | Should -Be 20
            $state.BytesChanged | Should -Be $false
            $state.LastIoBytes  | Should -Be 5000
        }
    }
}

Describe 'Resolve-StopDecision' {

    It "('stalled', ReverifyActive=`$true) -> stop (a stalled reason is NEVER resumed via re-verify)" {
        Resolve-StopDecision -Reason 'stalled' -ReverifyActive $true -DryRun $false | Should -Be 'stop'
    }

    It "('completed', ReverifyActive=`$true) -> resume" {
        Resolve-StopDecision -Reason 'completed' -ReverifyActive $true -DryRun $false | Should -Be 'resume'
    }

    It "('completed', ReverifyActive=`$false) -> stop" {
        Resolve-StopDecision -Reason 'completed' -ReverifyActive $false -DryRun $false | Should -Be 'stop'
    }

    It "('completed', ReverifyActive=`$null) -> stop" {
        Resolve-StopDecision -Reason 'completed' -ReverifyActive $null -DryRun $false | Should -Be 'stop'
    }

    It 'DryRun always resumes after the stop step has run, regardless of Reason or ReverifyActive' {
        Resolve-StopDecision -Reason 'stalled'   -ReverifyActive $null  -DryRun $true | Should -Be 'resume'
        Resolve-StopDecision -Reason 'completed' -ReverifyActive $false -DryRun $true | Should -Be 'resume'
    }
}

Describe 'Get-OutputBytes' {

    It 'returns 0 for a nonexistent path' {
        Get-OutputBytes -Path (Join-Path $TestDrive 'does-not-exist') | Should -Be 0
    }

    It 'returns 0 for an empty directory' {
        $dir = Join-Path $TestDrive 'empty-dir'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        Get-OutputBytes -Path $dir | Should -Be 0
    }

    It 'returns the exact sum of two files of known size' {
        $dir = Join-Path $TestDrive 'sized-dir'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $dir 'a.bin'), (New-Object byte[] 100))
        [System.IO.File]::WriteAllBytes((Join-Path $dir 'b.bin'), (New-Object byte[] 250))

        Get-OutputBytes -Path $dir | Should -Be 350
    }
}

Describe 'Test-FileUnlocked' {

    It 'returns $true for a freshly written and closed file' {
        $file = Join-Path $TestDrive 'unlocked.txt'
        Set-Content -Path $file -Value 'hello' -NoNewline

        Test-FileUnlocked -Path $file | Should -Be $true
    }

    It 'returns $false while exclusively open, $true again after the handle is released' -Skip:(-not $IsWindows) {
        # Advisory-lock (FileShare) semantics for a second FileShare.None open
        # are enforced consistently on Windows, which is the ONLY platform
        # this function actually ships on (PowerShell 5.1 / Windows Server).
        # Empirically confirmed on macOS pwsh 7.5.2 too, but CI runs this on
        # ubuntu-latest, where cross-process/cross-thread advisory locking
        # behavior is not guaranteed the same way -- so the locked-case
        # assertion is gated to Windows only, per the task's own guidance.
        $file = Join-Path $TestDrive 'locked.txt'
        Set-Content -Path $file -Value 'hello' -NoNewline

        $handle = [System.IO.File]::Open(
            $file, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try {
            Test-FileUnlocked -Path $file | Should -Be $false
        }
        finally {
            $handle.Close()
            $handle.Dispose()
        }

        Test-FileUnlocked -Path $file | Should -Be $true
    }
}

Describe 'Arm debounce (transient preview workers must not arm the watchdog)' {

    # WHAT THIS GUARDS -- a real near-miss, 2026-07-27 05:49.
    #
    # Topaz spawns short-lived ffmpeg/ffprobe helpers for previews and
    # thumbnails whenever the operator touches the GUI. One appeared at
    # 05:49:11 and was gone by 05:49:43 -- under 32 seconds. That single active
    # poll set SawActivity, which is what makes the watchdog willing to declare
    # a queue complete. The box then sat idle, ran the 300s debounce down, and
    # came within ~90 seconds of stopping an instance on which NO render had
    # ever run, while the operator was actively working on it.
    #
    # DebounceSec guards the far side of a render (do not call it finished too
    # early). ArmSec guards the near side (do not call it started at all).
    # These tests pin that behaviour.

    It 'does NOT arm on a transient worker that lives well under ArmSec' {
        # 2 active polls = 30s of activity against a 90s ArmSec, then the
        # helper exits -- exactly the measured preview-ffmpeg shape.
        $state = [pscustomobject]@{ IdleSec = 0; StallSec = 0; SawActivity = $false; ActiveSec = 0; LastBytes = [int64]0; LastIoBytes = $null }

        foreach ($i in 1..2) {
            $state = Get-NextWatchdogState -IdleSec $state.IdleSec -StallSec $state.StallSec `
                -SawActivity $state.SawActivity -ActiveSec $state.ActiveSec -ArmSec 90 `
                -LastBytes $state.LastBytes -Active $true -CurrentBytes ([int64]0) `
                -LastIoBytes $state.LastIoBytes -CurrentIoBytes ([int64](100 * $i)) `
                -PollSec 15 -DebounceSec 300 -StallLimitSec 1800
        }

        $state.ActiveSec   | Should -Be 30
        $state.SawActivity | Should -BeFalse
    }

    It 'never reaches "completed" after a transient worker, even long past DebounceSec' {
        $state = [pscustomobject]@{ IdleSec = 0; StallSec = 0; SawActivity = $false; ActiveSec = 0; LastBytes = [int64]0; LastIoBytes = $null }

        # A 30s blip...
        foreach ($i in 1..2) {
            $state = Get-NextWatchdogState -IdleSec $state.IdleSec -StallSec $state.StallSec `
                -SawActivity $state.SawActivity -ActiveSec $state.ActiveSec -ArmSec 90 `
                -LastBytes $state.LastBytes -Active $true -CurrentBytes ([int64]0) `
                -LastIoBytes $state.LastIoBytes -CurrentIoBytes ([int64](100 * $i)) `
                -PollSec 15 -DebounceSec 300 -StallLimitSec 1800
        }

        # ...then 40 idle polls (600s, twice the debounce). This is the exact
        # sequence that would have stopped the instance.
        foreach ($i in 1..40) {
            $state = Get-NextWatchdogState -IdleSec $state.IdleSec -StallSec $state.StallSec `
                -SawActivity $state.SawActivity -ActiveSec $state.ActiveSec -ArmSec 90 `
                -LastBytes $state.LastBytes -Active $false -CurrentBytes $null `
                -LastIoBytes $state.LastIoBytes -CurrentIoBytes $null `
                -PollSec 15 -DebounceSec 300 -StallLimitSec 1800
            $state.Verdict | Should -Be 'continue'
        }

        $state.SawActivity | Should -BeFalse
    }

    It 'DOES arm once a genuine render sustains activity for ArmSec' {
        $state = [pscustomobject]@{ IdleSec = 0; StallSec = 0; SawActivity = $false; ActiveSec = 0; LastBytes = [int64]0; LastIoBytes = $null }

        # 6 polls x 15s = 90s, the arm threshold exactly.
        foreach ($i in 1..6) {
            $state = Get-NextWatchdogState -IdleSec $state.IdleSec -StallSec $state.StallSec `
                -SawActivity $state.SawActivity -ActiveSec $state.ActiveSec -ArmSec 90 `
                -LastBytes $state.LastBytes -Active $true -CurrentBytes ([int64]0) `
                -LastIoBytes $state.LastIoBytes -CurrentIoBytes ([int64](1000 * $i)) `
                -PollSec 15 -DebounceSec 300 -StallLimitSec 1800
        }

        $state.ActiveSec   | Should -Be 90
        $state.SawActivity | Should -BeTrue
    }

    It 'stays armed across a mid-queue lull once it has armed' {
        # Regression guard: arming must be sticky. If a gap between queue items
        # could DIS-arm the watchdog, a finished queue would never complete and
        # the box would run forever.
        $state = [pscustomobject]@{ IdleSec = 0; StallSec = 0; SawActivity = $true; ActiveSec = 90; LastBytes = [int64]0; LastIoBytes = $null }

        foreach ($i in 1..5) {
            $state = Get-NextWatchdogState -IdleSec $state.IdleSec -StallSec $state.StallSec `
                -SawActivity $state.SawActivity -ActiveSec $state.ActiveSec -ArmSec 90 `
                -LastBytes $state.LastBytes -Active $false -CurrentBytes $null `
                -LastIoBytes $state.LastIoBytes -CurrentIoBytes $null `
                -PollSec 15 -DebounceSec 300 -StallLimitSec 1800
        }

        $state.SawActivity | Should -BeTrue
        $state.ActiveSec   | Should -Be 0     # arm progress reset, but SawActivity sticky
    }

    It 'does not accumulate arm progress across separate transient bursts' {
        # Three separate 30s blips separated by idle gaps must not add up to
        # 90s and arm the watchdog by accident.
        $state = [pscustomobject]@{ IdleSec = 0; StallSec = 0; SawActivity = $false; ActiveSec = 0; LastBytes = [int64]0; LastIoBytes = $null }

        foreach ($burst in 1..3) {
            foreach ($i in 1..2) {
                $state = Get-NextWatchdogState -IdleSec $state.IdleSec -StallSec $state.StallSec `
                    -SawActivity $state.SawActivity -ActiveSec $state.ActiveSec -ArmSec 90 `
                    -LastBytes $state.LastBytes -Active $true -CurrentBytes ([int64]0) `
                    -LastIoBytes $state.LastIoBytes -CurrentIoBytes ([int64](100 * $burst * $i)) `
                    -PollSec 15 -DebounceSec 300 -StallLimitSec 1800
            }
            $state = Get-NextWatchdogState -IdleSec $state.IdleSec -StallSec $state.StallSec `
                -SawActivity $state.SawActivity -ActiveSec $state.ActiveSec -ArmSec 90 `
                -LastBytes $state.LastBytes -Active $false -CurrentBytes $null `
                -LastIoBytes $state.LastIoBytes -CurrentIoBytes $null `
                -PollSec 15 -DebounceSec 300 -StallLimitSec 1800
        }

        $state.SawActivity | Should -BeFalse
    }
}

Describe 'Multi-item render queue (inter-item worker gap)' {
    # Topaz spawns exactly ONE neuroserver.exe worker per queued item (see
    # WorkerNamesLike's own comment in Config.ps1: it is launched with
    # --once). Between two queued items the GUI tears down the PREVIOUS
    # worker before spawning the NEXT one, so there is a WORKER-ABSENT GAP
    # baked into completely normal, healthy multi-item queue operation. The
    # single most dangerous bug this pipeline can have is mistaking that gap
    # for "queue complete" and powering the box off while later items are
    # still unrendered.
    #
    # These tests drive Get-NextWatchdogState IN A LOOP exactly the way
    # Watchdog.ps1's own main monitoring loop does -- threading the returned
    # state object into the next call -- rather than probing it with
    # isolated one-shot calls, so they exercise the SAME state machine the
    # real multi-item scenario walks through poll-by-poll, not just its
    # individual branches in isolation.
    #
    # PollSec=15 / DebounceSec=300 / StallSec=1800 / GpuBusyPercent=15 below
    # are the REAL values shipped in Config.ps1's Get-TopazAutoStopConfig
    # (not small made-up numbers like the Describes above use), so a change
    # to those shipped defaults that weakens the safety margin shows up here
    # directly.

    Context 'item gap shorter than DebounceSec never completes' {
        It 'stays "continue" through a full item, a sub-debounce gap, and the next item starting -- and IdleSec resets to 0 the instant the worker reappears' {
            # THE REGRESSION THIS GUARDS AGAINST: if Get-NextWatchdogState (or
            # anything upstream of it) ever let a transient inter-item gap
            # read as "completed" before DebounceSec has actually elapsed,
            # the watchdog would power the box off between queue item 1 and
            # item 2 -- destroying every unrendered item after the first.
            $state = [pscustomobject]@{ IdleSec = 0; StallSec = 0; SawActivity = $false; LastBytes = [int64]1000; LastIoBytes = $null }
            $bytes = 1000

            # --- Item 1 rendering: 5 polls with the worker present. ---
            1..5 | ForEach-Object {
                $bytes += 500
                $state = Get-NextWatchdogState -IdleSec $state.IdleSec -StallSec $state.StallSec -SawActivity $state.SawActivity `
                    -LastBytes $state.LastBytes -Active $true -CurrentBytes $bytes `
                    -LastIoBytes $state.LastIoBytes -CurrentIoBytes $null `
                    -PollSec 15 -DebounceSec 300 -StallLimitSec 1800
                $state.Verdict | Should -Be 'continue'
            }
            $state.SawActivity | Should -Be $true
            $state.IdleSec     | Should -Be 0

            # --- Inter-item gap: the old worker has exited and item 2's
            #     worker has not been spawned yet. 10 polls * 15s = 150s,
            #     well under the 300s debounce -- this must NEVER read as
            #     "completed", at any single poll along the way.
            1..10 | ForEach-Object {
                $state = Get-NextWatchdogState -IdleSec $state.IdleSec -StallSec $state.StallSec -SawActivity $state.SawActivity `
                    -LastBytes $state.LastBytes -Active $false -CurrentBytes $null `
                    -LastIoBytes $state.LastIoBytes -CurrentIoBytes $null `
                    -PollSec 15 -DebounceSec 300 -StallLimitSec 1800
                $state.Verdict | Should -Be 'continue'
            }
            $state.IdleSec | Should -Be 150

            # --- Item 2 starts: the worker reappears. ---
            $bytes += 500
            $state = Get-NextWatchdogState -IdleSec $state.IdleSec -StallSec $state.StallSec -SawActivity $state.SawActivity `
                -LastBytes $state.LastBytes -Active $true -CurrentBytes $bytes `
                -LastIoBytes $state.LastIoBytes -CurrentIoBytes $null `
                -PollSec 15 -DebounceSec 300 -StallLimitSec 1800

            $state.Verdict | Should -Be 'continue'

            # The worker reappearing resets IdleSec to 0 immediately -- a
            # THIRD gap later (after item 2) would start its own debounce
            # clock from scratch; it does not carry over any of the 150s
            # accrued during the item 1/2 gap.
            $state.IdleSec | Should -Be 0
        }
    }

    Context 'gap exactly at the DebounceSec boundary' {
        It 'is "continue" one poll before DebounceSec, and "completed" on the poll that reaches it (pins the boundary so nobody weakens it accidentally)' {
            # 300s DebounceSec / 15s PollSec = exactly 20 polls. Poll 19 sits
            # at 285s (still short); poll 20 lands exactly on 300s. Pinning
            # BOTH sides of this boundary means nobody can quietly loosen the
            # debounce (e.g. by switching -ge to -gt in Get-NextWatchdogState,
            # or off-by-one-ing the increment) without a test failing.
            $state = [pscustomobject]@{ IdleSec = 0; StallSec = 0; SawActivity = $true; LastBytes = [int64]5000; LastIoBytes = $null }

            # Poll 1..19: 19 * 15s = 285s, one poll short of the 300s debounce.
            1..19 | ForEach-Object {
                $state = Get-NextWatchdogState -IdleSec $state.IdleSec -StallSec $state.StallSec -SawActivity $state.SawActivity `
                    -LastBytes $state.LastBytes -Active $false -CurrentBytes $null `
                    -LastIoBytes $state.LastIoBytes -CurrentIoBytes $null `
                    -PollSec 15 -DebounceSec 300 -StallLimitSec 1800
            }
            $state.IdleSec | Should -Be 285
            $state.Verdict | Should -Be 'continue'

            # Poll 20: 285s + 15s = exactly 300s -- the boundary itself.
            $state = Get-NextWatchdogState -IdleSec $state.IdleSec -StallSec $state.StallSec -SawActivity $state.SawActivity `
                -LastBytes $state.LastBytes -Active $false -CurrentBytes $null `
                -LastIoBytes $state.LastIoBytes -CurrentIoBytes $null `
                -PollSec 15 -DebounceSec 300 -StallLimitSec 1800
            $state.IdleSec | Should -Be 300
            $state.Verdict | Should -Be 'completed'
        }
    }

    Context "gap longer than DebounceSec DOES complete, but Resolve-StopDecision's re-verify can still rescue it" {
        It 'a too-long gap reaches "completed", but Resolve-StopDecision resumes when the re-verify poll finds a later item already active' {
            # A gap that outlasts DebounceSec is a legitimate "queue complete"
            # signal from Get-NextWatchdogState's point of view -- that part
            # is working as designed. The SECOND layer of defence is
            # Resolve-StopDecision's post-unlock-gate re-verify (see
            # Watchdog.ps1 step 3b): the operator may have queued another
            # export while the watchdog was debouncing and then waiting for
            # output files to unlock, so a fresh Test-RenderActive read is
            # taken right before the stop, and Resolve-StopDecision must turn
            # a confirmed-active re-verify back into "resume" rather than
            # stopping the box out from under a running item.
            $state = [pscustomobject]@{ IdleSec = 0; StallSec = 0; SawActivity = $true; LastBytes = [int64]5000; LastIoBytes = $null }

            # 25 polls * 15s = 375s, comfortably past the 300s debounce --
            # deliberately longer than the boundary test above so this test
            # is unambiguous about being past it, not sitting on the edge.
            1..25 | ForEach-Object {
                $state = Get-NextWatchdogState -IdleSec $state.IdleSec -StallSec $state.StallSec -SawActivity $state.SawActivity `
                    -LastBytes $state.LastBytes -Active $false -CurrentBytes $null `
                    -LastIoBytes $state.LastIoBytes -CurrentIoBytes $null `
                    -PollSec 15 -DebounceSec 300 -StallLimitSec 1800
            }
            $state.Verdict | Should -Be 'completed'

            # Re-verify finds a worker running again (another item was queued
            # during the debounce+unlock wait) -> resume monitoring, never
            # stop.
            Resolve-StopDecision -Reason 'completed' -ReverifyActive $true -DryRun $false | Should -Be 'resume'

            # A clean $false re-verify (still genuinely idle) confirms the
            # stop decision.
            Resolve-StopDecision -Reason 'completed' -ReverifyActive $false -DryRun $false | Should -Be 'stop'

            # An UNREADABLE re-verify ($null) must NOT resurrect a completed
            # decision either -- only a confirmed $true resumes. Treating an
            # unknown re-verify as "maybe still running" would let a single
            # flaky/unreadable poll keep the box up forever in the opposite
            # case, and treating it as "definitely still running" here would
            # be the wrong failure direction once the debounce has already
            # fired on a clean $false read.
            Resolve-StopDecision -Reason 'completed' -ReverifyActive $null -DryRun $false | Should -Be 'stop'
        }
    }

    Context "a 'stalled' reason is never resumed by the re-verify" {
        It "Resolve-StopDecision('stalled', ReverifyActive=`$true) still returns 'stop'" {
            # A stalled worker is, by definition, still "active" (it is
            # present, just making no progress) -- so re-verifying it would
            # always read Active=$true, and if 'stalled' resumed the same
            # way 'completed' does, this step would loop forever instead of
            # ever stopping a genuinely broken job. Resolve-StopDecision's
            # own contract deliberately excludes 'stalled' from the
            # ReverifyActive short-circuit for exactly this reason.
            Resolve-StopDecision -Reason 'stalled' -ReverifyActive $true -DryRun $false | Should -Be 'stop'
        }
    }

    Context 'GPU corroboration (WorkerOrGpu vs WorkerOnly) during the inter-item gap' {
        It 'WorkerOrGpu reports ACTIVE (the debounce never begins) while the GPU is still busy and the worker process is gone; WorkerOnly reports inactive in the exact same situation' {
            # THIS IS WHY THE SHIPPED DEFAULT (CompletionSignal='WorkerOrGpu')
            # EXISTS -- see Config.ps1's own comment on CompletionSignal.
            # Between two queue items the OLD neuroserver.exe has already
            # exited and the NEW one has not been spawned yet, so
            # WorkerActive briefly reads $false even on a perfectly healthy
            # queue -- but if the GPU is still busy (e.g. Topaz is still
            # flushing/finalizing the previous item), the GPU signal
            # corroborates that the box is not really idle. GpuBusyPercent=15
            # and GpuUtil=50 below are both realistic (real renders peg the
            # GPU well above this threshold per Config.ps1's own comment).
            $gpuBusyPercent = 15
            $gpuDuringGap   = 50

            $activeWorkerOrGpu = Resolve-RenderActive -WorkerActive $false -GpuUtil $gpuDuringGap `
                -Signal 'WorkerOrGpu' -GpuBusyPercent $gpuBusyPercent
            $activeWorkerOrGpu | Should -Be $true

            $activeWorkerOnly = Resolve-RenderActive -WorkerActive $false -GpuUtil $gpuDuringGap `
                -Signal 'WorkerOnly' -GpuBusyPercent $gpuBusyPercent
            $activeWorkerOnly | Should -Be $false

            # Thread each Active value into Get-NextWatchdogState exactly as
            # the main loop does: under WorkerOrGpu, IdleSec never leaves 0
            # (the debounce clock never even starts) for as long as the GPU
            # stays busy. Under WorkerOnly the SAME poll begins accruing
            # IdleSec toward the 300s debounce despite the render genuinely
            # still being alive.
            $afterWorkerOrGpu = Get-NextWatchdogState -IdleSec 0 -StallSec 0 -SawActivity $true `
                -LastBytes 1000 -Active $activeWorkerOrGpu -CurrentBytes 1000 `
                -LastIoBytes $null -CurrentIoBytes $null `
                -PollSec 15 -DebounceSec 300 -StallLimitSec 1800
            $afterWorkerOrGpu.IdleSec | Should -Be 0
            $afterWorkerOrGpu.Verdict | Should -Be 'continue'

            $afterWorkerOnly = Get-NextWatchdogState -IdleSec 0 -StallSec 0 -SawActivity $true `
                -LastBytes 1000 -Active $activeWorkerOnly -CurrentBytes $null `
                -LastIoBytes $null -CurrentIoBytes $null `
                -PollSec 15 -DebounceSec 300 -StallLimitSec 1800
            $afterWorkerOnly.IdleSec | Should -Be 15
            $afterWorkerOnly.Verdict | Should -Be 'continue'
        }
    }

    Context 'no completion before the first render ever starts' {
        It 'stays "continue" (never "completed") while SawActivity is $false, however far idle accrues past DebounceSec' {
            # The operator may sit with the Topaz GUI open (no worker, no
            # queue running yet) for a long time before ever clicking Export
            # -- building the project, adding clips, configuring the export
            # settings. Get-NextWatchdogState must not mistake THAT idle
            # period for a completed queue; SawActivity is the guard, exactly
            # as an inter-item gap is guarded by DebounceSec once a render
            # has actually started at least once.
            $state = [pscustomobject]@{ IdleSec = 0; StallSec = 0; SawActivity = $false; LastBytes = [int64]0; LastIoBytes = $null }

            # 30 polls * 15s = 450s -- well past the 300s debounce.
            1..30 | ForEach-Object {
                $state = Get-NextWatchdogState -IdleSec $state.IdleSec -StallSec $state.StallSec -SawActivity $state.SawActivity `
                    -LastBytes $state.LastBytes -Active $false -CurrentBytes $null `
                    -LastIoBytes $state.LastIoBytes -CurrentIoBytes $null `
                    -PollSec 15 -DebounceSec 300 -StallLimitSec 1800
                $state.Verdict     | Should -Be 'continue'
                $state.SawActivity | Should -Be $false
            }

            $state.IdleSec | Should -Be 450
        }
    }
}
