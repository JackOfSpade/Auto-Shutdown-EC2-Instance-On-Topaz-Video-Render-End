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

        It 'never pays the nvidia-smi cost under the shipped WorkerOnly signal -- Get-GpuUtilizationMax is not called at all' {
            # PINS THE COST OPTIMISATION AT Watchdog.ps1's "Only pay the
            # nvidia-smi cost when the GPU signal is actually used". Nothing
            # asserted an invocation COUNT before, so a regression that called
            # Get-GpuUtilizationMax unconditionally would have left the whole
            # suite green while spawning an nvidia-smi child process with a 15s
            # WaitForExit every PollSec for the entire length of every render.
            # $cfg here is the real shipped config (CompletionSignal =
            # 'WorkerOnly', Config.ps1), so this is the branch the deployment
            # actually takes.
            Test-RenderActive | Out-Null

            Should -Invoke Get-GpuUtilizationMax -Times 0 -Exactly
        }
    }

    Context 'CompletionSignal = WorkerOrGpu (NOT the shipped value -- the other side of the branch)' {
        BeforeEach {
            Mock Get-TopazWorkers { return , @() }
            Mock Get-GpuUtilizationMax { return 50 }
        }

        It 'DOES call Get-GpuUtilizationMax, and a busy GPU alone reports Active=$true even with zero workers' {
            # $cfg here SHADOWS the one captured at Watchdog.ps1's dot-source
            # scope, for the duration of this It only. PowerShell resolves
            # unqualified variables dynamically up the CALL stack, which is the
            # very property the Get-TopazWorkers Describe's shadow
            # Get-CimInstance below already relies on to read $cfg -- so this
            # one wins for anything this test calls, and cannot leak anywhere
            # else. Declared in the It rather than a BeforeEach purely so the
            # assertions below can read it back in the same scope.
            $cfg = [pscustomobject]@{ CompletionSignal = 'WorkerOrGpu'; GpuBusyPercent = 15 }

            $result = Test-RenderActive

            Should -Invoke Get-GpuUtilizationMax -Times 1 -Exactly
            $result.WorkerActive | Should -Be $false
            $result.GpuValue     | Should -BeGreaterOrEqual $cfg.GpuBusyPercent
            $result.Active       | Should -Be $true
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

        It 'does not throw and returns Active=$false / WorkerActive=$false (WorkerOnly signal -- the shipped CompletionSignal), IoBytes=0 (worker signal readable, zero workers)' {
            # WorkerOnly, not WorkerOrGpu: Config.ps1 ships
            # CompletionSignal = 'WorkerOnly', and that is a MEASURED decision,
            # not a stale default -- DCV encodes the remote display on the same
            # GPU at 14-49%, so the GPU signal produced "Render active
            # (worker=False gpu=21%)" with no render running. Under WorkerOnly
            # Test-RenderActive never calls Get-GpuUtilizationMax at all, so the
            # mock above is inert here; the WorkerOrGpu branch has its own
            # Context below.
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
                # $script:FailAncestryQuery makes THIS query -- and only this
                # query -- fail, which is what a transient CIM/WMI provider
                # fault looks like from Get-TopazWorkers's point of view: the
                # every-process ancestry snapshot dies while the narrower
                # worker query still answers. See the two tests that use it.
                if ($script:FailAncestryQuery) {
                    throw 'simulated CIM ancestry-snapshot failure'
                }
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
        $script:KnownWorkers       = @{}
        $script:FakeTopazProcs     = @()
        $script:FakeWorkerProcs    = @()
        $script:FailAncestryQuery  = $false
        Mock Write-TopazLog { }
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

    Context 'the ancestry snapshot itself fails (transient CIM/WMI provider fault)' {
        # WHAT THIS GUARDS -- the single highest-consequence line in
        # Get-TopazWorkers. Its catch does TWO things: it empties
        # $allProcesses AND it forces `$topazPids = $null`. The second
        # assignment is the load-bearing one, and nothing exercised it: with an
        # empty process table but a still-non-null PID list,
        # Resolve-ProcessDescendants would return @() ("the GUI has no
        # descendants"), Resolve-WorkerAttribution would then return @() rather
        # than $null, Test-RenderActive would report a CONFIRMED-idle box, and
        # the debounce would start running down ON A BOX THAT IS ACTIVELY
        # RENDERING. Deleting that one line left all 334 tests green before
        # these two existed.

        It 'returns exactly $null (unknown), NOT an empty array (idle), when the ancestry query dies with a live GUI and a live worker' {
            $script:FakeTopazProcs    = @(Get-FakeTopazProc -ProcessId 100)
            $script:FakeWorkerProcs   = @(Get-FakeTopazProc -ProcessId 500 -ParentProcessId 100)
            $script:FailAncestryQuery = $true

            $result = Get-TopazWorkers

            # ($null -eq $result), not a pipe into Should -- see the
            # null-vs-empty note on the first test in this Describe. That
            # distinction is the entire point here: @() would mean "confirmed
            # no worker" and start the debounce mid-render.
            ($null -eq $result) | Should -Be $true
        }

        It 'still matches an ALREADY-KNOWN worker when the ancestry query dies, so the failure degrades to "unknown" without also losing orphan survival' {
            $script:FakeTopazProcs    = @(Get-FakeTopazProc -ProcessId 100)
            $script:FakeWorkerProcs   = @(Get-FakeTopazProc -ProcessId 500 -ParentProcessId 100)
            $script:FailAncestryQuery = $true
            # Get-FakeTopazProc pins CreationDate, so this poll's key is
            # computable up front -- the same "<PID>|<Ticks>" shape
            # Resolve-WorkerAttribution builds.
            $script:KnownWorkers = @{ "500|$(([datetime]'2026-01-01T00:00:00').Ticks)" = $true }

            $result = Get-TopazWorkers

            @($result).Count     | Should -Be 1
            $result[0].ProcessId | Should -Be 500
        }
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

    # -ActiveSec / -ArmSec ARE MANDATORY AND ARE PASSED ON EVERY CALL BELOW,
    # including in Contexts whose subject is the stall or debounce clock rather
    # than the arm debounce. They used to default to 0, and ArmSec=0 makes the
    # arm expression true on the FIRST active poll -- i.e. most of this
    # Describe was silently exercising a state machine the shipped
    # configuration never runs. ArmSec=90 below is the REAL shipped value
    # (Config.ps1), even where the surrounding PollSec/DebounceSec/StallLimitSec
    # are deliberately small made-up numbers that keep these boundary tests
    # short.

    Context 'stall accrual' {
        It 'hits the stalled verdict exactly at the boundary poll, with unchanged bytes on repeated active polls' {
            $state = [pscustomobject]@{ IdleSec = 0; StallSec = 0; SawActivity = $false; ActiveSec = 0; LastBytes = [int64]1000 }

            # Poll 1: stall=10, below the 30s limit -> continue.
            $state = Get-NextWatchdogState -IdleSec $state.IdleSec -StallSec $state.StallSec -SawActivity $state.SawActivity `
                -ActiveSec $state.ActiveSec -ArmSec 90 `
                -LastBytes $state.LastBytes -Active $true -CurrentBytes 1000 -PollSec 10 -DebounceSec 120 -StallLimitSec 30
            $state.StallSec | Should -Be 10
            $state.Verdict  | Should -Be 'continue'

            # Poll 2: stall=20, still below the limit -> continue.
            $state = Get-NextWatchdogState -IdleSec $state.IdleSec -StallSec $state.StallSec -SawActivity $state.SawActivity `
                -ActiveSec $state.ActiveSec -ArmSec 90 `
                -LastBytes $state.LastBytes -Active $true -CurrentBytes 1000 -PollSec 10 -DebounceSec 120 -StallLimitSec 30
            $state.StallSec | Should -Be 20
            $state.Verdict  | Should -Be 'continue'

            # Poll 3: stall=30, exactly at the limit (-ge boundary) -> stalled.
            $state = Get-NextWatchdogState -IdleSec $state.IdleSec -StallSec $state.StallSec -SawActivity $state.SawActivity `
                -ActiveSec $state.ActiveSec -ArmSec 90 `
                -LastBytes $state.LastBytes -Active $true -CurrentBytes 1000 -PollSec 10 -DebounceSec 120 -StallLimitSec 30
            $state.StallSec | Should -Be 30
            $state.Verdict  | Should -Be 'stalled'

            # The stall verdict does NOT depend on being armed: 30s of activity
            # is still short of ArmSec=90, so a stalled render is detected even
            # before the watchdog would be willing to call a queue complete.
            $state.SawActivity | Should -Be $false
        }
    }

    Context 'byte-delta stall reset' {
        It 'resets the stall counter on a byte SHRINK, then again on the following GROWTH -- never stalls' {
            # Shrink: 1000 -> 500.
            $afterShrink = Get-NextWatchdogState -IdleSec 0 -StallSec 25 -SawActivity $true `
                -ActiveSec 90 -ArmSec 90 `
                -LastBytes 1000 -Active $true -CurrentBytes 500 -PollSec 10 -DebounceSec 120 -StallLimitSec 30
            $afterShrink.StallSec     | Should -Be 0
            $afterShrink.BytesChanged | Should -Be $true
            $afterShrink.Verdict      | Should -Be 'continue'
            $afterShrink.LastBytes    | Should -Be 500

            # Growth from the new lower base: 500 -> 800. Must NOT be judged
            # against the old high-water mark (1000) -- this is exactly the
            # bug the byte-delta (not growth-only) reset comment documents.
            $afterGrowth = Get-NextWatchdogState -IdleSec $afterShrink.IdleSec -StallSec $afterShrink.StallSec `
                -SawActivity $afterShrink.SawActivity -ActiveSec $afterShrink.ActiveSec -ArmSec 90 `
                -LastBytes $afterShrink.LastBytes -Active $true `
                -CurrentBytes 800 -PollSec 10 -DebounceSec 120 -StallLimitSec 30
            $afterGrowth.StallSec     | Should -Be 0
            $afterGrowth.BytesChanged | Should -Be $true
            $afterGrowth.Verdict      | Should -Be 'continue'
            $afterGrowth.LastBytes    | Should -Be 800
        }
    }

    Context 'pre-render sawActivity guard' {
        It 'never yields "completed" when Active is $false and SawActivity is $false, however much idle accrues' {
            $state = [pscustomobject]@{ IdleSec = 0; StallSec = 0; SawActivity = $false; ActiveSec = 0; LastBytes = [int64]0 }

            1..20 | ForEach-Object {
                $state = Get-NextWatchdogState -IdleSec $state.IdleSec -StallSec $state.StallSec -SawActivity $state.SawActivity `
                    -ActiveSec $state.ActiveSec -ArmSec 90 `
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
            # ActiveSec=0 is what the real loop carries here: the worker has
            # already gone, so its arm progress was discarded on the first
            # inactive poll. SawActivity is what survives, and it is sticky.
            $state = Get-NextWatchdogState -IdleSec 110 -StallSec 0 -SawActivity $true `
                -ActiveSec 0 -ArmSec 90 `
                -LastBytes 1000 -Active $false -CurrentBytes $null -PollSec 10 -DebounceSec 120 -StallLimitSec 900
            $state.IdleSec | Should -Be 120
            $state.Verdict | Should -Be 'completed'

            # One poll earlier (110s) must NOT yet be "completed".
            $notYet = Get-NextWatchdogState -IdleSec 100 -StallSec 0 -SawActivity $true `
                -ActiveSec 0 -ArmSec 90 `
                -LastBytes 1000 -Active $false -CurrentBytes $null -PollSec 10 -DebounceSec 120 -StallLimitSec 900
            $notYet.IdleSec | Should -Be 110
            $notYet.Verdict | Should -Be 'continue'
        }
    }

    Context 'Active $null freeze' {
        It 'returns ALL bookkeeping unchanged (freeze), regardless of inputs -- ActiveSec and LastIoBytes included' {
            # ActiveSec and LastIoBytes are two of the six fields the $null
            # branch carries forward, and both have an explicit rationale
            # comment in Watchdog.ps1 -- but neither was supplied here, let
            # alone asserted, so a regression zeroing either one would have
            # left the whole suite green.
            #
            # ActiveSec matters most: an unreadable poll is not evidence the
            # worker went away, so resetting the arm counter would force a
            # genuine render to re-earn its 90 seconds. On a box with
            # intermittent CIM failures that means a real render can NEVER
            # accumulate ArmSec, and the watchdog silently becomes inert.
            $state = Get-NextWatchdogState -IdleSec 42 -StallSec 17 -SawActivity $true `
                -ActiveSec 75 -ArmSec 90 `
                -LastBytes 9999 -Active $null -CurrentBytes 123456 `
                -LastIoBytes 5000 -CurrentIoBytes 7777 `
                -PollSec 10 -DebounceSec 120 -StallLimitSec 900

            $state.IdleSec     | Should -Be 42
            $state.StallSec    | Should -Be 17
            $state.SawActivity | Should -Be $true
            $state.ActiveSec   | Should -Be 75
            $state.LastBytes   | Should -Be 9999
            $state.LastIoBytes | Should -Be 5000
            $state.Verdict     | Should -Be 'continue'
        }

        It 'blind polls neither ADVANCE nor RESET the arm counter: a render interrupted by unreadable polls still arms on its sixth genuinely-active poll' {
            # 3 active polls (45s), 2 blind polls, 3 more active polls. If the
            # blind polls reset ActiveSec the render would never arm at all; if
            # they advanced it, it would arm early (75s of real activity + 30s
            # of nothing). Neither is acceptable, and only walking the whole
            # sequence pins both directions at once.
            $state = [pscustomobject]@{ IdleSec = 0; StallSec = 0; SawActivity = $false; ActiveSec = 0; LastBytes = [int64]0; LastIoBytes = $null }

            foreach ($i in 1..3) {
                $state = Get-NextWatchdogState -IdleSec $state.IdleSec -StallSec $state.StallSec `
                    -SawActivity $state.SawActivity -ActiveSec $state.ActiveSec -ArmSec 90 `
                    -LastBytes $state.LastBytes -Active $true -CurrentBytes ([int64]0) `
                    -LastIoBytes $state.LastIoBytes -CurrentIoBytes ([int64](100 * $i)) `
                    -PollSec 15 -DebounceSec 300 -StallLimitSec 1800
            }
            $state.ActiveSec   | Should -Be 45
            $state.SawActivity | Should -BeFalse

            foreach ($i in 1..2) {
                $state = Get-NextWatchdogState -IdleSec $state.IdleSec -StallSec $state.StallSec `
                    -SawActivity $state.SawActivity -ActiveSec $state.ActiveSec -ArmSec 90 `
                    -LastBytes $state.LastBytes -Active $null -CurrentBytes $null `
                    -LastIoBytes $state.LastIoBytes -CurrentIoBytes $null `
                    -PollSec 15 -DebounceSec 300 -StallLimitSec 1800
                $state.ActiveSec | Should -Be 45      # frozen, not advanced, not reset
            }

            foreach ($i in 4..6) {
                $state = Get-NextWatchdogState -IdleSec $state.IdleSec -StallSec $state.StallSec `
                    -SawActivity $state.SawActivity -ActiveSec $state.ActiveSec -ArmSec 90 `
                    -LastBytes $state.LastBytes -Active $true -CurrentBytes ([int64]0) `
                    -LastIoBytes $state.LastIoBytes -CurrentIoBytes ([int64](100 * $i)) `
                    -PollSec 15 -DebounceSec 300 -StallLimitSec 1800
            }

            # 6 genuinely-active polls x 15s = the 90s arm threshold exactly.
            $state.ActiveSec   | Should -Be 90
            $state.SawActivity | Should -BeTrue
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
                -ActiveSec 90 -ArmSec 90 `
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
            $state = [pscustomobject]@{ IdleSec = 0; StallSec = 0; SawActivity = $true; ActiveSec = 90; LastBytes = [int64]1000; LastIoBytes = [int64]5000 }

            # Poll 1: stall=10, below the 30s limit -> continue.
            $state = Get-NextWatchdogState -IdleSec $state.IdleSec -StallSec $state.StallSec -SawActivity $state.SawActivity `
                -ActiveSec $state.ActiveSec -ArmSec 90 `
                -LastBytes $state.LastBytes -Active $true -CurrentBytes 1000 `
                -LastIoBytes $state.LastIoBytes -CurrentIoBytes 5000 -PollSec 10 -DebounceSec 120 -StallLimitSec 30
            $state.StallSec | Should -Be 10
            $state.Verdict  | Should -Be 'continue'

            # Poll 2: stall=20, still below the limit -> continue.
            $state = Get-NextWatchdogState -IdleSec $state.IdleSec -StallSec $state.StallSec -SawActivity $state.SawActivity `
                -ActiveSec $state.ActiveSec -ArmSec 90 `
                -LastBytes $state.LastBytes -Active $true -CurrentBytes 1000 `
                -LastIoBytes $state.LastIoBytes -CurrentIoBytes 5000 -PollSec 10 -DebounceSec 120 -StallLimitSec 30
            $state.StallSec | Should -Be 20
            $state.Verdict  | Should -Be 'continue'

            # Poll 3: stall=30, exactly at the limit (-ge boundary) -> stalled.
            $state = Get-NextWatchdogState -IdleSec $state.IdleSec -StallSec $state.StallSec -SawActivity $state.SawActivity `
                -ActiveSec $state.ActiveSec -ArmSec 90 `
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
                -ActiveSec 90 -ArmSec 90 `
                -LastBytes 1000 -Active $true -CurrentBytes 1000 `
                -LastIoBytes 5000 -CurrentIoBytes $null `
                -PollSec 10 -DebounceSec 120 -StallLimitSec 30

            # Neither signal counted as progress (output frozen, I/O
            # unreadable) -> stall time accrues rather than resetting.
            $state.StallSec     | Should -Be 20
            $state.BytesChanged | Should -Be $false
            $state.LastIoBytes  | Should -Be 5000
        }

        It 'unknown current or prior output bytes freeze the stall clock, while a known I/O delta still resets it' {
            $unknownCurrent = Get-NextWatchdogState -IdleSec 0 -StallSec 20 -SawActivity $true `
                -ActiveSec 90 -ArmSec 90 `
                -LastBytes 1000 -Active $true -CurrentBytes $null `
                -LastIoBytes 5000 -CurrentIoBytes 5000 `
                -PollSec 10 -DebounceSec 120 -StallLimitSec 30

            $unknownCurrent.StallSec  | Should -Be 20
            $unknownCurrent.LastBytes | Should -Be 1000
            $unknownCurrent.Verdict   | Should -Be 'continue'

            $unknownPrior = Get-NextWatchdogState -IdleSec 0 -StallSec 20 -SawActivity $true `
                -ActiveSec 90 -ArmSec 90 `
                -LastBytes $null -Active $true -CurrentBytes 1000 `
                -LastIoBytes 5000 -CurrentIoBytes 5000 `
                -PollSec 10 -DebounceSec 120 -StallLimitSec 30

            $unknownPrior.StallSec  | Should -Be 20
            $unknownPrior.LastBytes | Should -Be 1000
            $unknownPrior.Verdict   | Should -Be 'continue'

            $ioProgress = Get-NextWatchdogState -IdleSec 0 -StallSec 20 -SawActivity $true `
                -ActiveSec 90 -ArmSec 90 `
                -LastBytes 1000 -Active $true -CurrentBytes $null `
                -LastIoBytes 5000 -CurrentIoBytes 5200 `
                -PollSec 10 -DebounceSec 120 -StallLimitSec 30

            $ioProgress.StallSec    | Should -Be 0
            $ioProgress.LastBytes   | Should -Be 1000
            $ioProgress.LastIoBytes | Should -Be 5200
        }
    }
}

Describe 'Resolve-IncrementalUploadEligibility (CORRECTION 3 -- per-file incremental-upload gate)' {
    # THE PRODUCTION CONTEXT: this is the pure gate Get-NextUploadTrackingState
    # (below) and Invoke-TopazIncrementalUploadPoll consult every poll to decide
    # whether ONE OutputDir file looks finished enough to upload right now,
    # instead of waiting for the whole render queue to drain (Config.ps1's
    # INCREMENTAL UPLOAD comment / operator instruction, 2026-07-28). Every
    # input is a plain boolean/number/datetime -- no I/O -- so every gate is
    # pinned directly here, with no mocking required.
    #
    # PRIOR STATE OF THIS TEST FILE: this function (and Get-NextUploadTrackingState
    # / Invoke-TopazIncrementalUploadPoll below) had ZERO test coverage even
    # though Watchdog.ps1 fully implements and wires them into the poll loop --
    # an earlier pass of Config.Tests.ps1 had mistakenly documented them as
    # "not yet defined in Watchdog.ps1" dead code. See this file's own
    # Config.Tests.ps1 comment fix alongside this addition.
    #
    # FINDING 2 (2026-07-28 adversarial review) COVERAGE ADDED HERE: the old
    # bare "AlreadyUploaded" boolean was replaced by UploadedSize/
    # UploadedWriteTimeUtc ($null = never uploaded this session; non-null =
    # the size/write-time that WERE actually uploaded). $null values below are
    # the exact equivalent of the old "-AlreadyUploaded $false"; a non-null
    # pair that MATCHES SizeNow/WriteTimeNow is the exact equivalent of the
    # old "-AlreadyUploaded $true". The new behaviour under test is what
    # happens when a non-null pair does NOT match -- see the dedicated
    # "FINDING 2" Context below.

    Context 'the all-clear baseline: every condition satisfied, never uploaded before -> eligible' {
        It 'returns $true' {
            Resolve-IncrementalUploadEligibility -IsTemp $false -IsUnlocked $true `
                -SizeNow 1000 -SizeLastSeen 1000 -SecondsStable 30 -StableThresholdSec 30 `
                -WriteTimeNow ([datetime]'2026-07-28T10:00:00Z') `
                -UploadedSize $null -UploadedWriteTimeUtc $null | Should -Be $true
        }
    }

    Context 'LOCKED is disqualifying on its own -- THE case that stops a half-written render being uploaded as if finished' {
        It 'returns $false when IsUnlocked is $false, even with a perfectly stable, matching, non-temp, never-uploaded size' {
            Resolve-IncrementalUploadEligibility -IsTemp $false -IsUnlocked $false `
                -SizeNow 1000 -SizeLastSeen 1000 -SecondsStable 999 -StableThresholdSec 30 `
                -WriteTimeNow ([datetime]'2026-07-28T10:00:00Z') `
                -UploadedSize $null -UploadedWriteTimeUtc $null | Should -Be $false
        }
    }

    Context 'a SIZE CHANGE since the last poll is disqualifying on its own -- THE OTHER case that stops a half-written render being uploaded as if finished' {
        It 'returns $false when SizeNow differs from SizeLastSeen, even with SecondsStable already past the threshold' {
            # Belt-and-braces alongside the SecondsStable check (see the
            # function's own .DESCRIPTION, point 4): a caller bug that
            # mis-tracked SecondsStable must not be able to override a size
            # that plainly just moved.
            Resolve-IncrementalUploadEligibility -IsTemp $false -IsUnlocked $true `
                -SizeNow 1000 -SizeLastSeen 999 -SecondsStable 999 -StableThresholdSec 30 `
                -WriteTimeNow ([datetime]'2026-07-28T10:00:00Z') `
                -UploadedSize $null -UploadedWriteTimeUtc $null | Should -Be $false
        }
    }

    Context 'a Topaz temp/scratch file is never eligible' {
        It 'returns $false when IsTemp is $true, all else equal to the eligible baseline' {
            Resolve-IncrementalUploadEligibility -IsTemp $true -IsUnlocked $true `
                -SizeNow 1000 -SizeLastSeen 1000 -SecondsStable 30 -StableThresholdSec 30 `
                -WriteTimeNow ([datetime]'2026-07-28T10:00:00Z') `
                -UploadedSize $null -UploadedWriteTimeUtc $null | Should -Be $false
        }
    }

    Context 'a file already uploaded earlier this session, UNCHANGED since, is never re-uploaded' {
        It 'returns $false when UploadedSize/UploadedWriteTimeUtc both match SizeNow/WriteTimeNow exactly, all else equal to the eligible baseline' {
            Resolve-IncrementalUploadEligibility -IsTemp $false -IsUnlocked $true `
                -SizeNow 1000 -SizeLastSeen 1000 -SecondsStable 30 -StableThresholdSec 30 `
                -WriteTimeNow ([datetime]'2026-07-28T10:00:00Z') `
                -UploadedSize 1000 -UploadedWriteTimeUtc ([datetime]'2026-07-28T10:00:00Z') | Should -Be $false
        }
    }

    Context 'FINDING 2 (2026-07-28 adversarial review): a file that CHANGED since its earlier upload becomes eligible again' {
        # THE REGRESSION THIS GUARDS AGAINST. Keying "already uploaded" on
        # FullName alone would exclude a crash-resumed writer's CORRECTED
        # overwrite of a previously-uploaded partial forever, because the
        # path never changes even though the bytes at it do. See this
        # function's own .DESCRIPTION for the full crash-recovery mechanism
        # this defends against (Topaz's export_source flip from "export_as"
        # to "quick", 2026-07-28 incident).

        It 'is eligible when SizeNow differs from UploadedSize, even though UploadedWriteTimeUtc still matches WriteTimeNow' {
            Resolve-IncrementalUploadEligibility -IsTemp $false -IsUnlocked $true `
                -SizeNow 2000 -SizeLastSeen 2000 -SecondsStable 30 -StableThresholdSec 30 `
                -WriteTimeNow ([datetime]'2026-07-28T10:00:00Z') `
                -UploadedSize 1000 -UploadedWriteTimeUtc ([datetime]'2026-07-28T10:00:00Z') | Should -Be $true
        }

        It 'is eligible when WriteTimeNow differs from UploadedWriteTimeUtc, even though UploadedSize still matches SizeNow' {
            # A same-size overwrite is an unlikely real-world shape (a resumed
            # export usually differs in byte count too), but the identity
            # check is defined on BOTH fields independently, and each one
            # must be able to lift the exclusion on its own -- this pins that.
            Resolve-IncrementalUploadEligibility -IsTemp $false -IsUnlocked $true `
                -SizeNow 1000 -SizeLastSeen 1000 -SecondsStable 30 -StableThresholdSec 30 `
                -WriteTimeNow ([datetime]'2026-07-28T11:30:00Z') `
                -UploadedSize 1000 -UploadedWriteTimeUtc ([datetime]'2026-07-28T10:00:00Z') | Should -Be $true
        }

        It 'is NOT eligible if the content changed but has not yet restabilized (still short of StableThresholdSec on the new size)' {
            # A changed identity lifts condition 5, but conditions 3/4 (the
            # ordinary stability gates) still apply to the NEW content -- a
            # resumed writer must earn a fresh StableThresholdSec of stability
            # before it is uploaded again, exactly like a first-time upload.
            Resolve-IncrementalUploadEligibility -IsTemp $false -IsUnlocked $true `
                -SizeNow 2000 -SizeLastSeen 2000 -SecondsStable 15 -StableThresholdSec 30 `
                -WriteTimeNow ([datetime]'2026-07-28T11:30:00Z') `
                -UploadedSize 1000 -UploadedWriteTimeUtc ([datetime]'2026-07-28T10:00:00Z') | Should -Be $false
        }
    }

    Context 'a file seen for the FIRST time ever (no previous size to compare against) is never eligible on that poll' {
        It 'returns $false when SizeLastSeen is $null, however large SecondsStable claims to be' {
            Resolve-IncrementalUploadEligibility -IsTemp $false -IsUnlocked $true `
                -SizeNow 1000 -SizeLastSeen $null -SecondsStable 999 -StableThresholdSec 30 `
                -WriteTimeNow ([datetime]'2026-07-28T10:00:00Z') `
                -UploadedSize $null -UploadedWriteTimeUtc $null | Should -Be $false
        }
    }

    Context 'the stability threshold is a real -ge boundary, not an approximation' {
        It 'is NOT eligible one second short of StableThresholdSec' {
            Resolve-IncrementalUploadEligibility -IsTemp $false -IsUnlocked $true `
                -SizeNow 1000 -SizeLastSeen 1000 -SecondsStable 29 -StableThresholdSec 30 `
                -WriteTimeNow ([datetime]'2026-07-28T10:00:00Z') `
                -UploadedSize $null -UploadedWriteTimeUtc $null | Should -Be $false
        }

        It 'IS eligible exactly at StableThresholdSec' {
            Resolve-IncrementalUploadEligibility -IsTemp $false -IsUnlocked $true `
                -SizeNow 1000 -SizeLastSeen 1000 -SecondsStable 30 -StableThresholdSec 30 `
                -WriteTimeNow ([datetime]'2026-07-28T10:00:00Z') `
                -UploadedSize $null -UploadedWriteTimeUtc $null | Should -Be $true
        }

        It 'stays eligible well past the threshold (no upper bound)' {
            Resolve-IncrementalUploadEligibility -IsTemp $false -IsUnlocked $true `
                -SizeNow 1000 -SizeLastSeen 1000 -SecondsStable 3000 -StableThresholdSec 30 `
                -WriteTimeNow ([datetime]'2026-07-28T10:00:00Z') `
                -UploadedSize $null -UploadedWriteTimeUtc $null | Should -Be $true
        }
    }
}

Describe 'Get-NextUploadTrackingState (CORRECTION 3 -- per-file stability clock feeding the eligibility gate)' {
    # Mirrors Get-NextWatchdogState's own shape/tests above: state is threaded
    # through successive SIMULATED polls and the exact boundary is pinned,
    # rather than calling the function once in isolation.
    #
    # $null for -UploadedSize/-UploadedWriteTimeUtc below is this function's
    # equivalent of the old "-AlreadyUploaded $false" (see this file's
    # Resolve-IncrementalUploadEligibility Describe above for the full
    # rationale) -- these Contexts are otherwise UNCHANGED behaviour and exist
    # to prove FINDING 2's fix did not disturb the existing stability-clock
    # logic at all.

    Context 'first poll a file is ever observed' {
        It 'is never eligible (nothing yet to compare the size against), and seeds SizeLastSeen/SecondsStable at 0 for the next poll' {
            $next = Get-NextUploadTrackingState -IsTemp $false -IsUnlocked $true -SizeNow 1000 `
                -PreviousSizeLastSeen $null -PreviousSecondsStable 0 `
                -WriteTimeNow ([datetime]'2026-07-28T10:00:00Z') -UploadedSize $null -UploadedWriteTimeUtc $null `
                -PollSec 15 -StableThresholdSec 30

            $next.Eligible      | Should -Be $false
            $next.SizeLastSeen  | Should -Be 1000
            $next.SecondsStable | Should -Be 0
        }
    }

    Context 'a size held across consecutive polls climbs the stability clock to the exact boundary (PollSec=15, StableThresholdSec=30 -> 2 intervals)' {
        It 'is NOT yet eligible after 1 interval (15s), and IS eligible after 2 (30s)' {
            $state = [pscustomobject]@{ SizeLastSeen = 1000; SecondsStable = 0 }

            # This file was already seen once before at this same size (SizeLastSeen=1000
            # carried in from that prior poll) -- this call is the SECOND poll overall.
            $state = Get-NextUploadTrackingState -IsTemp $false -IsUnlocked $true -SizeNow 1000 `
                -PreviousSizeLastSeen $state.SizeLastSeen -PreviousSecondsStable $state.SecondsStable `
                -WriteTimeNow ([datetime]'2026-07-28T10:00:00Z') -UploadedSize $null -UploadedWriteTimeUtc $null `
                -PollSec 15 -StableThresholdSec 30
            $state.SecondsStable | Should -Be 15
            $state.Eligible      | Should -Be $false

            # Third poll overall: still the same size -> SecondsStable reaches 30, exactly at the threshold.
            $state = Get-NextUploadTrackingState -IsTemp $false -IsUnlocked $true -SizeNow 1000 `
                -PreviousSizeLastSeen $state.SizeLastSeen -PreviousSecondsStable $state.SecondsStable `
                -WriteTimeNow ([datetime]'2026-07-28T10:00:00Z') -UploadedSize $null -UploadedWriteTimeUtc $null `
                -PollSec 15 -StableThresholdSec 30
            $state.SecondsStable | Should -Be 30
            $state.Eligible      | Should -Be $true
        }
    }

    Context 'a size change resets the stability clock to zero, mirroring Get-NextWatchdogState''s own stall-clock reset' {
        It 'drops SecondsStable back to 0 the instant the size changes, even after several stable polls' {
            $state = [pscustomobject]@{ SizeLastSeen = 1000; SecondsStable = 45 }

            $state = Get-NextUploadTrackingState -IsTemp $false -IsUnlocked $true -SizeNow 2000 `
                -PreviousSizeLastSeen $state.SizeLastSeen -PreviousSecondsStable $state.SecondsStable `
                -WriteTimeNow ([datetime]'2026-07-28T10:00:00Z') -UploadedSize $null -UploadedWriteTimeUtc $null `
                -PollSec 15 -StableThresholdSec 30

            $state.SecondsStable | Should -Be 0
            $state.SizeLastSeen  | Should -Be 2000
            $state.Eligible      | Should -Be $false
        }

        It 'must climb the FULL threshold again from the new size before becoming eligible' {
            $state = [pscustomobject]@{ SizeLastSeen = 2000; SecondsStable = 0 }

            $state = Get-NextUploadTrackingState -IsTemp $false -IsUnlocked $true -SizeNow 2000 `
                -PreviousSizeLastSeen $state.SizeLastSeen -PreviousSecondsStable $state.SecondsStable `
                -WriteTimeNow ([datetime]'2026-07-28T10:00:00Z') -UploadedSize $null -UploadedWriteTimeUtc $null `
                -PollSec 15 -StableThresholdSec 30
            $state.Eligible | Should -Be $false

            $state = Get-NextUploadTrackingState -IsTemp $false -IsUnlocked $true -SizeNow 2000 `
                -PreviousSizeLastSeen $state.SizeLastSeen -PreviousSecondsStable $state.SecondsStable `
                -WriteTimeNow ([datetime]'2026-07-28T10:00:00Z') -UploadedSize $null -UploadedWriteTimeUtc $null `
                -PollSec 15 -StableThresholdSec 30
            $state.Eligible | Should -Be $true
        }
    }

    Context 'a LOCKED file still accrues the stability clock on an unchanged size, but is never Eligible while locked' {
        It 'SecondsStable advances normally even though IsUnlocked is $false; Eligible stays $false' {
            $state = [pscustomobject]@{ SizeLastSeen = 1000; SecondsStable = 15 }

            $state = Get-NextUploadTrackingState -IsTemp $false -IsUnlocked $false -SizeNow 1000 `
                -PreviousSizeLastSeen $state.SizeLastSeen -PreviousSecondsStable $state.SecondsStable `
                -WriteTimeNow ([datetime]'2026-07-28T10:00:00Z') -UploadedSize $null -UploadedWriteTimeUtc $null `
                -PollSec 15 -StableThresholdSec 30

            $state.SecondsStable | Should -Be 30
            $state.Eligible      | Should -Be $false
        }

        It 'becomes Eligible on the very next poll once unlocked, WITHOUT waiting through the threshold again -- the clock already satisfied it while locked' {
            $state = [pscustomobject]@{ SizeLastSeen = 1000; SecondsStable = 30 }

            $state = Get-NextUploadTrackingState -IsTemp $false -IsUnlocked $true -SizeNow 1000 `
                -PreviousSizeLastSeen $state.SizeLastSeen -PreviousSecondsStable $state.SecondsStable `
                -WriteTimeNow ([datetime]'2026-07-28T10:00:00Z') -UploadedSize $null -UploadedWriteTimeUtc $null `
                -PollSec 15 -StableThresholdSec 30

            $state.Eligible | Should -Be $true
        }
    }

    Context 'a file already uploaded this session, UNCHANGED since, stays excluded' {
        It 'stays ineligible even with a perfectly stable, matching, unlocked, non-temp size, when UploadedSize/UploadedWriteTimeUtc still match' {
            $state = Get-NextUploadTrackingState -IsTemp $false -IsUnlocked $true -SizeNow 1000 `
                -PreviousSizeLastSeen 1000 -PreviousSecondsStable 30 `
                -WriteTimeNow ([datetime]'2026-07-28T10:00:00Z') `
                -UploadedSize 1000 -UploadedWriteTimeUtc ([datetime]'2026-07-28T10:00:00Z') `
                -PollSec 15 -StableThresholdSec 30

            $state.Eligible | Should -Be $false
        }
    }

    Context 'FINDING 2 (2026-07-28 adversarial review): a file that changed since its earlier upload becomes eligible again through this function too' {
        It 'is Eligible when SizeNow differs from UploadedSize, given the size has also already restabilized at the NEW value' {
            $state = Get-NextUploadTrackingState -IsTemp $false -IsUnlocked $true -SizeNow 2000 `
                -PreviousSizeLastSeen 2000 -PreviousSecondsStable 30 `
                -WriteTimeNow ([datetime]'2026-07-28T11:30:00Z') `
                -UploadedSize 1000 -UploadedWriteTimeUtc ([datetime]'2026-07-28T10:00:00Z') `
                -PollSec 15 -StableThresholdSec 30

            $state.Eligible | Should -Be $true
        }

        It 'is Eligible when only WriteTimeNow differs from UploadedWriteTimeUtc (same size, already restabilized)' {
            $state = Get-NextUploadTrackingState -IsTemp $false -IsUnlocked $true -SizeNow 1000 `
                -PreviousSizeLastSeen 1000 -PreviousSecondsStable 30 `
                -WriteTimeNow ([datetime]'2026-07-28T11:30:00Z') `
                -UploadedSize 1000 -UploadedWriteTimeUtc ([datetime]'2026-07-28T10:00:00Z') `
                -PollSec 15 -StableThresholdSec 30

            $state.Eligible | Should -Be $true
        }
    }

    Context 'a temp file accrues stability bookkeeping like any other file, but is never Eligible' {
        It 'tracks SizeLastSeen/SecondsStable normally, Eligible stays $false' {
            $state = Get-NextUploadTrackingState -IsTemp $true -IsUnlocked $true -SizeNow 1000 `
                -PreviousSizeLastSeen 1000 -PreviousSecondsStable 30 `
                -WriteTimeNow ([datetime]'2026-07-28T10:00:00Z') -UploadedSize $null -UploadedWriteTimeUtc $null `
                -PollSec 15 -StableThresholdSec 30

            $state.SecondsStable | Should -Be 45
            $state.Eligible      | Should -Be $false
        }
    }
}

Describe 'Invoke-TopazIncrementalUploadPoll (CORRECTION 3 -- one poll''s worth of the incremental-upload pass)' {
    # Orchestration around the two pure functions above: walks THIS POLL'S
    # OutputDir snapshot, updates $Tracking in place, and uploads whatever is
    # now eligible. Every I/O boundary (Test-FileUnlocked,
    # Invoke-TopazIncrementalUpload, Write-TopazLog) is mocked;
    # Test-TopazTempFile is left REAL since it is itself a pure, already-tested
    # function -- using it for real here is simpler than mocking it and
    # exercises the actual TempMarker wiring too.
    #
    # THE SNAPSHOT IS NOW AN ARGUMENT, NOT SOMETHING THIS PASS FETCHES. The
    # monitoring loop enumerates OutputDir once per poll (Get-OutputFileSnapshot,
    # its own Describe below) and threads the result into BOTH the progress
    # signal and this pass, instead of each walking the multi-GB folder
    # separately at two different instants. So these fixtures build a $files
    # array directly and pass -Files, rather than mocking Get-ChildItem; the
    # enumeration-failure case is `-Files $null`.

    BeforeAll {
        function Get-PollTestConfig {
            param(
                [bool]$UploadWhenReady = $true,
                [string]$UploadTarget = 'gdrive:temp',
                [string]$OutputDir = 'D:\Renders',
                [int]$PollSec = 15,
                [int]$UploadStableSec = 30,
                [string]$TempMarker = '_temp'
            )
            [pscustomobject]@{
                UploadWhenReady = $UploadWhenReady
                UploadTarget    = $UploadTarget
                OutputDir       = $OutputDir
                PollSec         = $PollSec
                UploadStableSec = $UploadStableSec
                TempMarker      = $TempMarker
            }
        }

        function Get-FakeOutputFile {
            param(
                [Parameter(Mandatory)][string]$Name,
                [Parameter(Mandatory)][int64]$Length,
                # Fixed default (not Get-Date) so tests that do not care about
                # write-time get an IDENTICAL value across repeated polls -- a
                # real Get-Date default would risk the clock ticking over a
                # second mid-test and spuriously tripping FINDING 2's
                # write-time-changed re-upload path.
                [datetime]$LastWriteTimeUtc = [datetime]'2026-07-28T10:00:00Z'
            )
            [pscustomobject]@{
                FullName         = "D:\Renders\$Name"
                Name             = $Name
                Length           = $Length
                LastWriteTimeUtc = $LastWriteTimeUtc
            }
        }
    }

    BeforeEach {
        $script:Tracking = @{}
        Mock Write-TopazLog { }
        Mock Invoke-TopazIncrementalUpload { $true }
    }

    Context 'preconditions gate the whole pass before ANY per-file work' {
        It 'UploadWhenReady=$false -> returns immediately, touching neither Tracking nor the files' {
            $cfg   = Get-PollTestConfig -UploadWhenReady $false
            $files = @((Get-FakeOutputFile -Name 'done.mov' -Length 1000))
            Mock Test-FileUnlocked { throw 'must not be probed when UploadWhenReady is $false' }

            { Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files } | Should -Not -Throw
            $script:Tracking.Count | Should -Be 0
            Should -Invoke Invoke-TopazIncrementalUpload -Times 0 -Exactly
        }

        It 'UploadTarget empty -> returns immediately' {
            $cfg   = Get-PollTestConfig -UploadTarget ''
            $files = @((Get-FakeOutputFile -Name 'done.mov' -Length 1000))
            Mock Test-FileUnlocked { throw 'must not be probed when UploadTarget is empty' }

            { Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files } | Should -Not -Throw
            $script:Tracking.Count | Should -Be 0
        }

        It 'UploadTarget whitespace-only -> also treated as unset' {
            $cfg   = Get-PollTestConfig -UploadTarget '   '
            $files = @((Get-FakeOutputFile -Name 'done.mov' -Length 1000))
            Mock Test-FileUnlocked { throw 'must not be probed when UploadTarget is whitespace' }

            { Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files } | Should -Not -Throw
            $script:Tracking.Count | Should -Be 0
        }
    }

    Context 'no files in OutputDir' {
        It 'completes without error, leaves Tracking empty, never uploads' {
            # Plain '@()', not the leading-comma ', @()' idiom used elsewhere in
            # this file for Get-TopazPids/Get-TopazWorkers/Get-OutputFileSnapshot:
            # those need the comma because their RESULT crosses a return
            # boundary that would otherwise collapse an empty array to $null.
            # Here it is a plain local, assigned and passed by name, so no
            # collapse is possible -- and adding the comma would instead
            # double-wrap into a 1-element array containing an empty array, and
            # the pass would iterate once over that inner empty array instead of
            # zero times.
            $cfg = Get-PollTestConfig

            { Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files @() } | Should -Not -Throw
            $script:Tracking.Count | Should -Be 0
            Should -Invoke Invoke-TopazIncrementalUpload -Times 0 -Exactly
        }
    }

    Context 'a single file across successive polls: first seen, then stable-but-short, then eligible and uploaded exactly once' {
        It 'uploads on poll 3 (2 full PollSec intervals of a stable size), never again after' {
            $cfg   = Get-PollTestConfig -PollSec 15 -UploadStableSec 30
            $files = @((Get-FakeOutputFile -Name 'done.mov' -Length 1000))
            Mock Test-FileUnlocked { $true }

            Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files   # poll 1: first seen
            Should -Invoke Invoke-TopazIncrementalUpload -Times 0 -Exactly

            Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files   # poll 2: 15s stable, still short
            Should -Invoke Invoke-TopazIncrementalUpload -Times 0 -Exactly

            Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files   # poll 3: 30s stable -> eligible, uploaded
            Should -Invoke Invoke-TopazIncrementalUpload -Times 1 -Exactly

            Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files   # poll 4: unchanged since upload -> blocks a repeat
            Should -Invoke Invoke-TopazIncrementalUpload -Times 1 -Exactly

            $script:Tracking['D:\Renders\done.mov'].UploadedSize | Should -Be 1000
        }
    }

    Context 'a LOCKED file is never uploaded no matter how many stable-size polls pass' {
        It 'never calls Invoke-TopazIncrementalUpload while Test-FileUnlocked keeps returning $false' {
            $cfg   = Get-PollTestConfig -PollSec 15 -UploadStableSec 30
            $files = @((Get-FakeOutputFile -Name 'writing.mov' -Length 5000))
            Mock Test-FileUnlocked { $false }

            1..5 | ForEach-Object { Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files }

            Should -Invoke Invoke-TopazIncrementalUpload -Times 0 -Exactly
        }
    }

    Context 'a file whose size CHANGES between polls is never uploaded while it keeps changing, only once it finally settles' {
        It 'resets the stability clock on each size change and uploads only after the size holds for the full threshold' {
            $cfg = Get-PollTestConfig -PollSec 15 -UploadStableSec 30
            Mock Test-FileUnlocked { $true }

            $files = @((Get-FakeOutputFile -Name 'growing.mov' -Length 1000))
            Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files   # poll 1: first seen at 1000

            $files = @((Get-FakeOutputFile -Name 'growing.mov' -Length 2000))
            Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files   # poll 2: size changed -> clock resets
            Should -Invoke Invoke-TopazIncrementalUpload -Times 0 -Exactly

            Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files   # poll 3: stable for 1 interval (15s)
            Should -Invoke Invoke-TopazIncrementalUpload -Times 0 -Exactly

            Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files   # poll 4: stable for 2 intervals (30s) -> eligible
            Should -Invoke Invoke-TopazIncrementalUpload -Times 1 -Exactly
        }
    }

    Context 'a Topaz temp/scratch file is tracked but never uploaded, however long its size holds' {
        It 'never calls Invoke-TopazIncrementalUpload for a name matching TempMarker' {
            $cfg   = Get-PollTestConfig -PollSec 15 -UploadStableSec 30 -TempMarker '_temp'
            $files = @((Get-FakeOutputFile -Name 'scratch_temp.mov' -Length 1000))
            Mock Test-FileUnlocked { $true }

            1..5 | ForEach-Object { Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files }

            Should -Invoke Invoke-TopazIncrementalUpload -Times 0 -Exactly
        }
    }

    Context 'a FAILED incremental upload leaves the file unmarked so a later poll retries it -- NOT fatal, per Invoke-TopazIncrementalUpload''s own contract' {
        It 'UploadedSize stays $null after a failed attempt, and the next eligible poll retries the upload' {
            $cfg   = Get-PollTestConfig -PollSec 15 -UploadStableSec 30
            $files = @((Get-FakeOutputFile -Name 'flaky.mov' -Length 1000))
            Mock Test-FileUnlocked { $true }
            Mock Invoke-TopazIncrementalUpload { $false }

            Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files   # poll 1: first seen
            Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files   # poll 2: 15s stable, not yet eligible
            Should -Invoke Invoke-TopazIncrementalUpload -Times 0 -Exactly

            Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files   # poll 3: 30s stable -> eligible, attempted, fails
            Should -Invoke Invoke-TopazIncrementalUpload -Times 1 -Exactly
            $script:Tracking['D:\Renders\flaky.mov'].UploadedSize | Should -Be $null

            Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files   # poll 4: still eligible (unmarked) -> retried
            Should -Invoke Invoke-TopazIncrementalUpload -Times 2 -Exactly
        }
    }

    Context 'multiple files are tracked independently, without cross-contamination' {
        It 'uploads only the file that is actually eligible this poll, leaves the other alone' {
            $cfg = Get-PollTestConfig -PollSec 15 -UploadStableSec 30
            Mock Test-FileUnlocked { $true }

            $files = @(
                (Get-FakeOutputFile -Name 'ready.mov' -Length 1000),
                (Get-FakeOutputFile -Name 'still-growing.mov' -Length 500)
            )
            Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files   # poll 1: both first-seen
            Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files   # poll 2: both 15s stable

            $files = @(
                (Get-FakeOutputFile -Name 'ready.mov' -Length 1000),          # unchanged -> reaches 30s
                (Get-FakeOutputFile -Name 'still-growing.mov' -Length 900)    # changed -> resets
            )
            Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files   # poll 3

            Should -Invoke Invoke-TopazIncrementalUpload -Times 1 -Exactly -ParameterFilter { $File.Name -eq 'ready.mov' }
            $script:Tracking['D:\Renders\ready.mov'].UploadedSize         | Should -Be 1000
            $script:Tracking['D:\Renders\still-growing.mov'].UploadedSize | Should -Be $null
        }
    }

    Context 'FINDING 2 (2026-07-28 adversarial review): a file unchanged since its successful upload is never re-uploaded, however many further polls see it' {
        It 'calls Invoke-TopazIncrementalUpload exactly once total, across an initial upload plus many identical subsequent polls' {
            $cfg   = Get-PollTestConfig -PollSec 15 -UploadStableSec 30
            $files = @((Get-FakeOutputFile -Name 'stable.mov' -Length 1000))
            Mock Test-FileUnlocked { $true }

            Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files   # poll 1: first seen
            Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files   # poll 2: 15s stable
            Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files   # poll 3: 30s stable -> uploaded
            Should -Invoke Invoke-TopazIncrementalUpload -Times 1 -Exactly

            # Many further polls, same size, same write-time (Get-FakeOutputFile's
            # fixed default) -- THIS is the "must NOT turn into re-uploading the
            # same bytes every poll" requirement the fix is explicitly scoped not
            # to break.
            1..6 | ForEach-Object { Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files }

            Should -Invoke Invoke-TopazIncrementalUpload -Times 1 -Exactly
            $script:Tracking['D:\Renders\stable.mov'].UploadedSize | Should -Be 1000
        }

        It 'stops LOCK-PROBING a file once its uploaded identity matches, instead of re-opening a finished deliverable exclusively on every poll' {
            # THE COST THIS AVOIDS. Test-FileUnlocked opens the file with
            # FileShare.None; for a file whose tracked UploadedSize/
            # UploadedWriteTimeUtc already match what is on disk,
            # Resolve-IncrementalUploadEligibility returns $false at its
            # identity gate WITHOUT ever consulting IsUnlocked, so that
            # exclusive open was pure waste -- repeated for every finished file
            # on every poll for the rest of a multi-hour queue. It is also the
            # one operation in this pass that momentarily denies another
            # process access to a finished deliverable.
            $cfg   = Get-PollTestConfig -PollSec 15 -UploadStableSec 30
            $files = @((Get-FakeOutputFile -Name 'finished.mov' -Length 1000))
            Mock Test-FileUnlocked { $true }

            Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files   # poll 1
            Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files   # poll 2
            Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files   # poll 3 -> uploaded
            Should -Invoke Test-FileUnlocked -Times 3 -Exactly

            # Three more polls, nothing changed: not one further probe.
            1..3 | ForEach-Object { Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files }
            Should -Invoke Test-FileUnlocked -Times 3 -Exactly

            # ...and the stability bookkeeping keeps advancing regardless, since
            # it is computed from size alone and never reads IsUnlocked.
            $script:Tracking['D:\Renders\finished.mov'].SecondsStable | Should -Be 75
        }
    }

    Context 'FINDING 2 (2026-07-28 adversarial review): a file whose SIZE differs from what was uploaded becomes eligible again' {
        It 'uploads again once the new size restabilizes, records the NEW size as the uploaded identity, and logs the supersession distinctly' {
            $cfg = Get-PollTestConfig -PollSec 15 -UploadStableSec 30
            Mock Test-FileUnlocked { $true }

            $files = @((Get-FakeOutputFile -Name 'resized.mov' -Length 1000))
            Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files   # poll 1
            Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files   # poll 2 (15s)
            Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files   # poll 3 (30s) -> uploaded at 1000
            Should -Invoke Invoke-TopazIncrementalUpload -Times 1 -Exactly
            $script:Tracking['D:\Renders\resized.mov'].UploadedSize | Should -Be 1000

            # Size now differs from what was uploaded -- must restabilize at the
            # NEW size before re-upload, exactly like a first-time upload would.
            $files = @((Get-FakeOutputFile -Name 'resized.mov' -Length 4000))
            Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files   # poll 4: size changed -> clock resets
            Should -Invoke Invoke-TopazIncrementalUpload -Times 1 -Exactly

            Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files   # poll 5: 15s stable at 4000
            Should -Invoke Invoke-TopazIncrementalUpload -Times 1 -Exactly

            Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files   # poll 6: 30s stable at 4000 -> eligible again
            Should -Invoke Invoke-TopazIncrementalUpload -Times 2 -Exactly
            Should -Invoke Invoke-TopazIncrementalUpload -Times 1 -Exactly -ParameterFilter { $File.Length -eq 4000 }

            $script:Tracking['D:\Renders\resized.mov'].UploadedSize | Should -Be 4000

            # Greppable, distinct from an ordinary first-time upload log line.
            Should -Invoke Write-TopazLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'WARN' -and $Message -match 'SUPERSEDED'
            }
        }
    }

    Context 'FINDING 2 (2026-07-28 adversarial review): a file whose LAST-WRITE TIME differs from what was uploaded becomes eligible again, even at an unchanged size' {
        It 'uploads again the moment the write-time changes, without needing to re-earn the stability threshold since the size itself never moved' {
            $cfg = Get-PollTestConfig -PollSec 15 -UploadStableSec 30
            Mock Test-FileUnlocked { $true }
            $t0 = [datetime]'2026-07-28T10:00:00Z'
            $t1 = [datetime]'2026-07-28T11:30:00Z'

            $files = @((Get-FakeOutputFile -Name 'overwritten.mov' -Length 1000 -LastWriteTimeUtc $t0))
            Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files   # poll 1
            Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files   # poll 2 (15s)
            Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files   # poll 3 (30s) -> uploaded at (1000, t0)
            Should -Invoke Invoke-TopazIncrementalUpload -Times 1 -Exactly

            # Same size, but a NEW write-time. SizeLastSeen/SecondsStable were
            # already sitting at/past the threshold on this UNCHANGED size, so
            # (per Get-NextUploadTrackingState's own contract) the identity
            # mismatch alone is enough to re-open eligibility on this very poll
            # -- no extra stabilization pass required.
            $files = @((Get-FakeOutputFile -Name 'overwritten.mov' -Length 1000 -LastWriteTimeUtc $t1))
            Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files   # poll 4

            Should -Invoke Invoke-TopazIncrementalUpload -Times 2 -Exactly
            $script:Tracking['D:\Renders\overwritten.mov'].UploadedWriteTimeUtc | Should -Be $t1

            Should -Invoke Write-TopazLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'WARN' -and $Message -match 'SUPERSEDED'
            }
        }
    }

    Context 'FINDING 2 (2026-07-28 adversarial review) -- THE REGRESSION TEST: a crashed writer''s partial is uploaded, then the resumed writer overwrites it, and the corrected content is re-uploaded automatically' {
        It 'uploads the partial once stable, does not re-upload while the resumed writer keeps growing it, then uploads the FINAL corrected size once it restabilizes' {
            $cfg = Get-PollTestConfig -PollSec 15 -UploadStableSec 30
            Mock Test-FileUnlocked { $true }

            # PHASE 1: the crashed worker's partial. Its handle was released
            # (unlocked) and it sat at a stable-but-INCOMPLETE size for long
            # enough that this gate -- which cannot distinguish "finished" from
            # "crashed and not yet resumed" -- treats it as finished and
            # uploads it. THIS IS THE DOCUMENTED, ACCEPTED LIMITATION described
            # on Resolve-IncrementalUploadEligibility: a partial CAN still be
            # uploaded and verified in the first instance. That is NOT what
            # this test is pinning; what it pins is what happens next.
            $files = @((Get-FakeOutputFile -Name 'export.mov' -Length 900))
            Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files   # poll 1: first seen
            Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files   # poll 2: 15s stable
            Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files   # poll 3: 30s stable -> "finished", uploaded
            Should -Invoke Invoke-TopazIncrementalUpload -Times 1 -Exactly -ParameterFilter { $File.Length -eq 900 }
            $script:Tracking['D:\Renders\export.mov'].UploadedSize | Should -Be 900

            # PHASE 2: Topaz notices the crash, reloads the project, and
            # resumes the export through its "quick" re-queue path (see
            # Resolve-IncrementalUploadEligibility's own comment) -- the file
            # starts growing again. It must NOT be re-uploaded while still
            # moving, exactly like any other in-progress render.
            $files = @((Get-FakeOutputFile -Name 'export.mov' -Length 1500))
            Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files   # poll 4: size changed -> clock resets
            Should -Invoke Invoke-TopazIncrementalUpload -Times 1 -Exactly

            $files = @((Get-FakeOutputFile -Name 'export.mov' -Length 2200))
            Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files   # poll 5: still growing -> clock resets again
            Should -Invoke Invoke-TopazIncrementalUpload -Times 1 -Exactly

            # PHASE 3: the resumed export finishes for real, at its correct,
            # complete size.
            $files = @((Get-FakeOutputFile -Name 'export.mov' -Length 3000))
            Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files   # poll 6: size changed again -> clock resets
            Should -Invoke Invoke-TopazIncrementalUpload -Times 1 -Exactly

            Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files   # poll 7: 15s stable at 3000
            Should -Invoke Invoke-TopazIncrementalUpload -Times 1 -Exactly

            Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files   # poll 8: 30s stable at 3000 -> eligible again (differs from the uploaded 900)
            Should -Invoke Invoke-TopazIncrementalUpload -Times 2 -Exactly
            Should -Invoke Invoke-TopazIncrementalUpload -Times 1 -Exactly -ParameterFilter { $File.Length -eq 3000 }

            $script:Tracking['D:\Renders\export.mov'].UploadedSize | Should -Be 3000

            # The re-upload is logged as a DISTINCT, greppable event -- the
            # visible signature, on this box, of Topaz's crash-recovery
            # re-queue path having fired, not silent noise folded into an
            # ordinary "looks finished" line.
            Should -Invoke Write-TopazLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'WARN' -and $Message -match 'SUPERSEDED' -and $Message -match 'export\.mov'
            }
        }
    }

    Context 'pruning: a file no longer present in OutputDir is dropped from Tracking' {
        It 'removes the tracking entry once the snapshot stops containing it' {
            $cfg = Get-PollTestConfig
            Mock Test-FileUnlocked { $true }

            Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking `
                -Files @((Get-FakeOutputFile -Name 'gone-soon.mov' -Length 1000))
            $script:Tracking.ContainsKey('D:\Renders\gone-soon.mov') | Should -Be $true

            Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files @()
            $script:Tracking.ContainsKey('D:\Renders\gone-soon.mov') | Should -Be $false
        }
    }

    Context 'a failure is contained PER FILE, logged as a WARN, and never thrown into the caller -- the single most safety-critical loop in the project' {
        It 'preserves existing Tracking and makes no upload call when the snapshot itself failed (-Files $null), rather than pruning from a listing it never got' {
            $cfg = Get-PollTestConfig
            $key = 'D:\Renders\already-uploaded.mov'
            $script:Tracking[$key] = @{
                SizeLastSeen         = [int64]1000
                SecondsStable        = 30
                UploadedSize         = [int64]1000
                UploadedWriteTimeUtc = [datetime]'2026-07-28T10:00:00Z'
            }

            { Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $null } | Should -Not -Throw

            $script:Tracking.ContainsKey($key)  | Should -Be $true
            $script:Tracking[$key].UploadedSize | Should -Be 1000
            Should -Invoke Invoke-TopazIncrementalUpload -Times 0 -Exactly
        }

        It 'does not throw when Test-FileUnlocked itself throws for a tracked file, and says which file it skipped' {
            $cfg   = Get-PollTestConfig
            $files = @((Get-FakeOutputFile -Name 'weird.mov' -Length 1000))
            Mock Test-FileUnlocked { throw 'simulated lock-check failure' }

            { Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files } | Should -Not -Throw
            Should -Invoke Invoke-TopazIncrementalUpload -Times 0 -Exactly
            Should -Invoke Write-TopazLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'WARN' -and $Message -match 'SKIPPING' -and $Message -match 'weird\.mov'
            }
        }

        It 'keeps processing the files AFTER a failing one -- a persistent per-file fault must not disable incremental upload for the rest of the queue' {
            # THE REGRESSION THIS GUARDS AGAINST, and the reason the single
            # try/catch that used to wrap the whole foreach was not enough. With
            # pass-level containment, one throw abandoned every file ORDERED
            # AFTER it; enumeration order is stable, so a PERSISTENT per-file
            # fault (a path that does not sit under OutputDir, tripping
            # Invoke-TopazIncrementalUpload's relative-path arithmetic) silently
            # disabled incremental upload for those files on EVERY poll for the
            # life of the process -- with one WARN line per poll to show for it.
            # The previous version of this test used a SINGLE file, so it
            # asserted non-throwing while masking the abort entirely.
            $cfg = Get-PollTestConfig -PollSec 15 -UploadStableSec 30
            $files = @(
                (Get-FakeOutputFile -Name 'a.mov'   -Length 1000),
                (Get-FakeOutputFile -Name 'bad.mov' -Length 2000),
                (Get-FakeOutputFile -Name 'c.mov'   -Length 3000)
            )
            Mock Test-FileUnlocked {
                if ($Path -eq 'D:\Renders\bad.mov') { throw 'simulated persistent per-file failure' }
                return $true
            }

            # bad.mov was already tracked from earlier polls -- size-stable well
            # past the threshold, so it WOULD be uploaded this poll if its lock
            # probe did not blow up. Its entry is what proves the $seenKeys
            # marking still happens outside the per-file try: a file that is
            # plainly still in OutputDir must not be pruned just because its own
            # check failed, or its stability clock would reset on every
            # recurrence and it could never accumulate its way to eligible.
            # (UploadedSize stays $null here on purpose: a non-null one matching
            # the file on disk would short-circuit at the identity gate and skip
            # the lock probe altogether -- see the lock-probe Context above.)
            $script:Tracking['D:\Renders\bad.mov'] = @{
                SizeLastSeen         = [int64]2000
                SecondsStable        = 30
                UploadedSize         = $null
                UploadedWriteTimeUtc = $null
            }

            # Three polls: enough for the two healthy files to cross
            # UploadStableSec and actually be uploaded.
            1..3 | ForEach-Object {
                { Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files } | Should -Not -Throw
            }

            # THE FILE ORDERED AFTER THE FAILING ONE IS THE POINT: it must be
            # tracked, stability-clocked, and ultimately uploaded, not silently
            # invisible for the life of the process.
            Should -Invoke Invoke-TopazIncrementalUpload -Times 1 -Exactly -ParameterFilter { $File.Name -eq 'c.mov' }
            Should -Invoke Invoke-TopazIncrementalUpload -Times 1 -Exactly -ParameterFilter { $File.Name -eq 'a.mov' }
            Should -Invoke Invoke-TopazIncrementalUpload -Times 0 -Exactly -ParameterFilter { $File.Name -eq 'bad.mov' }

            $script:Tracking['D:\Renders\a.mov'].UploadedSize | Should -Be 1000
            $script:Tracking['D:\Renders\c.mov'].UploadedSize | Should -Be 3000

            # Not pruned, and not disturbed: the tracking write for a file lives
            # INSIDE the per-file try, so a skipped file keeps exactly the
            # bookkeeping it already had rather than being silently rewound.
            $script:Tracking.ContainsKey('D:\Renders\bad.mov')   | Should -Be $true
            $script:Tracking['D:\Renders\bad.mov'].SizeLastSeen  | Should -Be 2000
            $script:Tracking['D:\Renders\bad.mov'].SecondsStable | Should -Be 30

            # ...and every poll says so, once per poll, naming the file.
            Should -Invoke Write-TopazLog -Times 3 -Exactly -ParameterFilter {
                $Level -eq 'WARN' -and $Message -match 'SKIPPING' -and $Message -match 'bad\.mov'
            }

            # The pass as a whole never reports itself as failed -- that WARN is
            # reserved for a failure OUTSIDE the per-file containment.
            Should -Invoke Write-TopazLog -Times 0 -Exactly -ParameterFilter {
                $Message -match 'Incremental upload pass FAILED'
            }
        }

        It 'still falls back to the pass-level WARN for a failure OUTSIDE the per-file try, so the outer backstop is not dead code' {
            # The outer try/catch did not become redundant when the per-file one
            # was added: it still covers iterating the supplied snapshot,
            # computing each tracking key, and the prune. A snapshot entry with
            # no FullName trips the key computation, which sits outside the
            # per-file try deliberately (see the $seenKeys comment in
            # Watchdog.ps1) -- and the pass must still return quietly.
            $cfg   = Get-PollTestConfig
            $files = @([pscustomobject]@{
                FullName         = $null
                Name             = 'nameless.mov'
                Length           = [int64]1000
                LastWriteTimeUtc = [datetime]'2026-07-28T10:00:00Z'
            })
            Mock Test-FileUnlocked { $true }

            { Invoke-TopazIncrementalUploadPoll -Config $cfg -Tracking $script:Tracking -Files $files } | Should -Not -Throw

            Should -Invoke Write-TopazLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'WARN' -and $Message -match 'Incremental upload pass FAILED'
            }
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

Describe 'Get-OutputFileSnapshot (the ONE OutputDir walk per poll)' {

    # WHAT THIS REPLACED. An active poll used to enumerate OutputDir twice --
    # once for the progress/stall signal and once inside the incremental-upload
    # pass -- on a multi-GB folder, every PollSec, from two different instants.
    # The loop now takes this snapshot once and threads it into both, so this
    # function owns the null-vs-empty distinction BOTH of them depend on:
    # $null means "could not be read" (freeze the stall clock, skip the upload
    # pass), an empty array means "read fine, nothing there" (byte total 0,
    # prune every tracked file).

    It 'returns an EMPTY ARRAY, not $null, for a readable but empty directory' {
        $dir = Join-Path $TestDrive 'snapshot-empty'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $result = Get-OutputFileSnapshot -Path $dir

        # ($null -eq $result) rather than a pipe into Should -- piping a
        # 0-element array delivers ZERO items and Should then compares its own
        # unset default against $null and wrongly reports a match. See the same
        # note in the Get-TopazWorkers Describe above.
        ($null -eq $result) | Should -Be $false
        @($result).Count    | Should -Be 0
    }

    It 'returns every file under the path' {
        $dir = Join-Path $TestDrive 'snapshot-files'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $dir 'a.bin'), (New-Object byte[] 100))
        [System.IO.File]::WriteAllBytes((Join-Path $dir 'b.bin'), (New-Object byte[] 250))

        $result = Get-OutputFileSnapshot -Path $dir

        @($result).Count | Should -Be 2
        (@($result | ForEach-Object { $_.Name }) | Sort-Object) | Should -Be @('a.bin', 'b.bin')
    }

    It 'returns $null and logs a WARN when strict enumeration fails, never a partial listing' {
        # Get-TopazOutputFiles throws rather than returning a partial list (its
        # own comment in Config.ps1); this is where that throw becomes the
        # "unknown" both consumers must not confuse with "empty".
        Mock Write-TopazLog { }
        Mock Get-TopazOutputFiles { throw 'simulated access failure' }

        $result = Get-OutputFileSnapshot -Path 'D:\Renders'

        ($null -eq $result) | Should -Be $true
        Should -Invoke Write-TopazLog -Times 1 -Exactly -ParameterFilter {
            $Level -eq 'WARN' -and $Message -match 'Could not enumerate OutputDir'
        }
    }

    It 'returns $null for a nonexistent path' {
        Mock Write-TopazLog { }
        ($null -eq (Get-OutputFileSnapshot -Path (Join-Path $TestDrive 'no-such-dir'))) | Should -Be $true
    }
}

Describe 'Get-OutputBytes' {

    It 'returns $null for a nonexistent path' {
        Get-OutputBytes -Path (Join-Path $TestDrive 'does-not-exist') | Should -Be $null
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

    It 'returns $null when strict enumeration fails, never a partial byte total' {
        Mock Get-TopazOutputFiles { throw 'simulated access failure' }
        Get-OutputBytes -Path 'D:\Renders' | Should -Be $null
    }

    Context '-Files: summing a snapshot the caller already took' {
        # The monitoring loop enumerates once per poll and hands the result to
        # BOTH consumers. The null-vs-zero mapping stays here, in one place and
        # one Describe: collapsing "enumeration failed" ($null) into "empty
        # folder" (0) at a call site would let a failed read reset the stall
        # baseline, which Get-NextWatchdogState's unknown-bytes guard exists to
        # prevent.

        It 'maps a $null snapshot (enumeration failed) straight through to $null, never to 0' {
            Get-OutputBytes -Files $null | Should -Be $null
        }

        It 'maps an EMPTY snapshot (folder read fine, nothing in it) to 0, not $null' {
            $result = Get-OutputBytes -Files @()

            ($null -eq $result) | Should -Be $false
            $result | Should -Be 0
        }

        It 'sums the supplied snapshot and never touches the filesystem -- -Path is not consulted at all' {
            Mock Get-TopazOutputFiles { throw 'must not enumerate when -Files was supplied' }

            $files = @(
                [pscustomobject]@{ Length = [int64]100 },
                [pscustomobject]@{ Length = [int64]250 }
            )

            Get-OutputBytes -Path 'D:\Renders' -Files $files | Should -Be 350
        }
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

Describe 'Resolve-RefusalStallSec (retry cadence after a refused stop)' {

    # WHAT THIS GUARDS. When Stop-Sequence.ps1 refuses to stop (e.g. the render
    # upload failed and OutputDir is on the ephemeral scratch volume), the
    # watchdog re-arms and retries rather than exiting. How fast the retry
    # actually arrives depends on which state-machine branch governs the next
    # poll, and that differs by reason:
    #
    #   'completed' - the worker EXITED, so the next poll is Active=$false and
    #                 the idle/DebounceSec branch drives the retry. The stall
    #                 clock is irrelevant; 0 is fine.
    #   'stalled'   - the worker is HUNG, not gone. Stop-Sequence never touches
    #                 Topaz processes, so it is still there next poll, Active
    #                 reads $true, and the ACTIVE branch governs -- the retry is
    #                 gated by the stall clock reaching StallLimitSec again.
    #
    # The original implementation reset the clock to 0 unconditionally. On the
    # 'stalled' path that cost a full StallSec (1800s = 30 min) before the next
    # attempt -- exactly the window in which the out-of-band CloudWatch idle
    # alarm can stop the box and erase the un-uploaded render. The retry
    # mechanism built to survive that alarm would have got ONE attempt.

    It 'returns 0 for a completed-reason refusal (idle branch drives the retry)' {
        Resolve-RefusalStallSec -Reason 'completed' -StallLimitSec 1800 -DebounceSec 300 |
            Should -Be 0
    }

    It 'carries the stall clock to within DebounceSec of the limit for a stalled refusal' {
        # 1800 - 300 = 1500, so the next 'stalled' verdict is due after a
        # further 300s of no progress, matching the intended retry cadence.
        Resolve-RefusalStallSec -Reason 'stalled' -StallLimitSec 1800 -DebounceSec 300 |
            Should -Be 1500
    }

    It 'gives the stalled path the SAME retry cadence as the completed path' {
        $stallStart = Resolve-RefusalStallSec -Reason 'stalled' -StallLimitSec 1800 -DebounceSec 300
        # Seconds of continued no-progress before 'stalled' fires again:
        (1800 - $stallStart) | Should -Be 300
    }

    It 'never returns a negative clock when DebounceSec exceeds StallLimitSec' {
        # A misconfiguration, but it must not produce a negative stall clock
        # that would then take even longer to climb back to the limit.
        Resolve-RefusalStallSec -Reason 'stalled' -StallLimitSec 100 -DebounceSec 300 |
            Should -Be 0
    }

    It 'REJECTS a reason outside its domain rather than silently returning 0' {
        # This replaces a test that pinned 'maxlifetime' behaviour. That value
        # was documented on the parameter but was never reachable: it is a
        # Stop-Sequence.ps1 / Register-TimedStop.ps1 concept invoked directly by
        # the timed-stop task, while this function is called from exactly three
        # places in the watchdog, all passing a $reason that can only ever be
        # 'completed' or 'stalled'. Meanwhile Resolve-StopDecision, 150 lines
        # further down the same file, already constrained itself with
        # ValidateSet('completed','stalled') -- two adjacent functions
        # disagreeing about one domain.
        #
        # What the ValidateSet actually buys: every unrecognised value takes the
        # `-ne 'stalled'` branch and returns 0, so a future typo like 'stall'
        # would silently cost a full StallSec (1800s) before the next retry --
        # exactly the regression this function was written to prevent, arriving
        # without a sound. Failing at parameter binding is loud instead.
        { Resolve-RefusalStallSec -Reason 'maxlifetime' -StallLimitSec 1800 -DebounceSec 300 } |
            Should -Throw
        { Resolve-RefusalStallSec -Reason 'stall' -StallLimitSec 1800 -DebounceSec 300 } |
            Should -Throw
    }
}

Describe 'Resolve-StopSequenceResult (never let a multi-object return swallow a refusal)' {

    # WHAT THIS GUARDS. The watchdog used to test Stop-Sequence.ps1's return
    # value with `if ($stopResult -eq $false)`. Against a COLLECTION, -eq is a
    # filter rather than a comparison: @($true, $false) -eq $false yields the
    # one-element array @($false), which `if` unrolls to $false -- so the
    # refusal branch is skipped, Resolve-StopDecision returns 'stop', and the
    # watchdog breaks out of its outer loop for good with the render still
    # un-uploaded on the ephemeral scratch volume.
    #
    # This is not a hypothetical class of bug in THIS codebase: Config.ps1's own
    # comment on Write-TopazLog records that log lines contaminating a return
    # value once already turned `if ($ok -eq $false)` falsy and "defeated the
    # ephemeral-upload interlock in Stop-Sequence.ps1: a failed upload would
    # have been read as success and the instance stopped, erasing the render it
    # had failed to save".

    It "trusts a clean single `$true as 'stopped'" {
        Resolve-StopSequenceResult -RawResult $true | Should -Be 'stopped'
    }

    It "reads a clean single `$false as 'refused'" {
        Resolve-StopSequenceResult -RawResult $false | Should -Be 'refused'
    }

    It "treats `$null (e.g. Stop-Sequence.ps1 threw before returning) as 'untrustworthy'" {
        Resolve-StopSequenceResult -RawResult $null | Should -Be 'untrustworthy'
    }

    It "treats an EMPTY return as 'untrustworthy'" {
        Resolve-StopSequenceResult -RawResult @() | Should -Be 'untrustworthy'
    }

    It "treats @(`$true, `$false) -- THE array-filter case -- as 'untrustworthy', not as a stop" {
        # The exact shape that made `-eq $false` skip the refusal branch.
        Resolve-StopSequenceResult -RawResult @($true, $false) | Should -Be 'untrustworthy'
    }

    It "treats a non-boolean return as 'untrustworthy'" {
        Resolve-StopSequenceResult -RawResult 'yes' | Should -Be 'untrustworthy'
        Resolve-StopSequenceResult -RawResult 0     | Should -Be 'untrustworthy'
    }

    It "treats a boolean CONTAMINATED by stray output as 'untrustworthy' in BOTH directions" {
        # Stricter than "find the one boolean in there somewhere", deliberately.
        # A stray line alongside $false is the historical incident shape, and a
        # stray line alongside $true is the one that would cost the render -- so
        # neither is trusted. The safety bias is unambiguous: a wrongly-refused
        # stop costs money, a wrongly-trusted stop costs hours of paid render.
        Resolve-StopSequenceResult -RawResult @('a log line', $false) | Should -Be 'untrustworthy'
        Resolve-StopSequenceResult -RawResult @('a log line', $true)  | Should -Be 'untrustworthy'
    }

    It 'only ever returns one of the three documented outcomes' {
        $seen = @(
            (Resolve-StopSequenceResult -RawResult $true),
            (Resolve-StopSequenceResult -RawResult $false),
            (Resolve-StopSequenceResult -RawResult $null),
            (Resolve-StopSequenceResult -RawResult @()),
            (Resolve-StopSequenceResult -RawResult @($true, $true)),
            (Resolve-StopSequenceResult -RawResult ([pscustomobject]@{ Ok = $true }))
        )

        foreach ($outcome in $seen) {
            $outcome | Should -BeIn @('stopped', 'refused', 'untrustworthy')
        }
    }

    It 'is pure: repeated calls with the same input return the same outcome' {
        1..5 | ForEach-Object {
            Resolve-StopSequenceResult -RawResult @($true, $false) | Should -Be 'untrustworthy'
        }
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
    # PollSec=15 / DebounceSec=300 / StallSec=1800 / ArmSec=90 /
    # GpuBusyPercent=15 below are the REAL values shipped in Config.ps1's
    # Get-TopazAutoStopConfig (not small made-up numbers like the Describes
    # above use), so a change to those shipped defaults that weakens the
    # safety margin shows up here directly.
    #
    # ArmSec WAS MISSING FROM THAT LIST, AND FROM EVERY CALL, until it was
    # threaded through here: it defaulted to 0, so this entire Describe -- the
    # flagship multi-item scenario -- ran with the arm debounce switched OFF,
    # and "Item 1 rendering: 5 polls" (75s) only satisfied
    # `SawActivity | Should -Be $true` because of that. The two guards that
    # together decide whether a queue may EVER be declared complete are the
    # near-side ArmSec and the far-side DebounceSec, and they were never
    # exercised together anywhere in the suite: the Arm debounce Describe above
    # tests ArmSec with no multi-item structure, and this one tested multi-item
    # structure with ArmSec disabled.

    Context 'item gap shorter than DebounceSec never completes' {
        It 'stays "continue" through a full item, a sub-debounce gap, and the next item starting -- and IdleSec resets to 0 the instant the worker reappears' {
            # THE REGRESSION THIS GUARDS AGAINST: if Get-NextWatchdogState (or
            # anything upstream of it) ever let a transient inter-item gap
            # read as "completed" before DebounceSec has actually elapsed,
            # the watchdog would power the box off between queue item 1 and
            # item 2 -- destroying every unrendered item after the first.
            $state = [pscustomobject]@{ IdleSec = 0; StallSec = 0; SawActivity = $false; ActiveSec = 0; LastBytes = [int64]1000; LastIoBytes = $null }
            $bytes = 1000

            # --- Item 1 rendering: 6 polls with the worker present. SIX, not
            #     five: 6 * 15s = 90s is the shipped ArmSec exactly, so item 1
            #     genuinely EARNS the arm here instead of being handed it by a
            #     disabled debounce. A real queue item runs for minutes to
            #     hours, so lengthening this makes the scenario more faithful,
            #     not less. ---
            1..6 | ForEach-Object {
                $bytes += 500
                $state = Get-NextWatchdogState -IdleSec $state.IdleSec -StallSec $state.StallSec -SawActivity $state.SawActivity `
                    -ActiveSec $state.ActiveSec -ArmSec 90 `
                    -LastBytes $state.LastBytes -Active $true -CurrentBytes $bytes `
                    -LastIoBytes $state.LastIoBytes -CurrentIoBytes $null `
                    -PollSec 15 -DebounceSec 300 -StallLimitSec 1800
                $state.Verdict | Should -Be 'continue'
            }
            $state.ActiveSec   | Should -Be 90
            $state.SawActivity | Should -Be $true
            $state.IdleSec     | Should -Be 0

            # --- Inter-item gap: the old worker has exited and item 2's
            #     worker has not been spawned yet. 10 polls * 15s = 150s,
            #     well under the 300s debounce -- this must NEVER read as
            #     "completed", at any single poll along the way.
            1..10 | ForEach-Object {
                $state = Get-NextWatchdogState -IdleSec $state.IdleSec -StallSec $state.StallSec -SawActivity $state.SawActivity `
                    -ActiveSec $state.ActiveSec -ArmSec 90 `
                    -LastBytes $state.LastBytes -Active $false -CurrentBytes $null `
                    -LastIoBytes $state.LastIoBytes -CurrentIoBytes $null `
                    -PollSec 15 -DebounceSec 300 -StallLimitSec 1800
                $state.Verdict | Should -Be 'continue'
            }
            $state.IdleSec | Should -Be 150
            # The gap discarded item 1's arm PROGRESS but not the arm itself:
            # ActiveSec is back to 0 while SawActivity stays sticky, which is
            # what lets the queue still complete after the LAST item.
            $state.ActiveSec   | Should -Be 0
            $state.SawActivity | Should -Be $true

            # --- Item 2 starts: the worker reappears. ---
            $bytes += 500
            $state = Get-NextWatchdogState -IdleSec $state.IdleSec -StallSec $state.StallSec -SawActivity $state.SawActivity `
                -ActiveSec $state.ActiveSec -ArmSec 90 `
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

    Context 'the near-side (ArmSec) and far-side (DebounceSec) guards, exercised TOGETHER' {
        It 'a queue that never properly started can never complete, however long the following idle gap runs' {
            # THE COMBINED INVARIANT, which nothing pinned while -ArmSec
            # defaulted to 0. A 75s burst is a transient preview/thumbnail
            # helper, not a render: it is one poll SHORT of the 90s arm. The
            # 375s of idle that follows is comfortably PAST the 300s debounce,
            # so the far-side guard alone would say "completed" -- and under
            # the old default this exact shape DID arm on the first poll. Only
            # the near-side guard stops the box being powered off on a session
            # where no render ever ran.
            $state = [pscustomobject]@{ IdleSec = 0; StallSec = 0; SawActivity = $false; ActiveSec = 0; LastBytes = [int64]1000; LastIoBytes = $null }

            # 5 polls x 15s = 75s of "activity" -- one poll short of ArmSec.
            foreach ($i in 1..5) {
                $state = Get-NextWatchdogState -IdleSec $state.IdleSec -StallSec $state.StallSec -SawActivity $state.SawActivity `
                    -ActiveSec $state.ActiveSec -ArmSec 90 `
                    -LastBytes $state.LastBytes -Active $true -CurrentBytes ([int64](1000 + 500 * $i)) `
                    -LastIoBytes $state.LastIoBytes -CurrentIoBytes ([int64](100 * $i)) `
                    -PollSec 15 -DebounceSec 300 -StallLimitSec 1800
                $state.Verdict | Should -Be 'continue'
            }
            $state.ActiveSec   | Should -Be 75
            $state.SawActivity | Should -Be $false

            # 25 idle polls x 15s = 375s, well past the 300s debounce.
            foreach ($i in 1..25) {
                $state = Get-NextWatchdogState -IdleSec $state.IdleSec -StallSec $state.StallSec -SawActivity $state.SawActivity `
                    -ActiveSec $state.ActiveSec -ArmSec 90 `
                    -LastBytes $state.LastBytes -Active $false -CurrentBytes $null `
                    -LastIoBytes $state.LastIoBytes -CurrentIoBytes $null `
                    -PollSec 15 -DebounceSec 300 -StallLimitSec 1800
                $state.Verdict     | Should -Be 'continue'
                $state.SawActivity | Should -Be $false
            }

            $state.IdleSec | Should -Be 375
        }
    }

    Context 'gap exactly at the DebounceSec boundary' {
        It 'is "continue" one poll before DebounceSec, and "completed" on the poll that reaches it (pins the boundary so nobody weakens it accidentally)' {
            # 300s DebounceSec / 15s PollSec = exactly 20 polls. Poll 19 sits
            # at 285s (still short); poll 20 lands exactly on 300s. Pinning
            # BOTH sides of this boundary means nobody can quietly loosen the
            # debounce (e.g. by switching -ge to -gt in Get-NextWatchdogState,
            # or off-by-one-ing the increment) without a test failing.
            # SawActivity=$true / ActiveSec=0 is exactly the state the real
            # loop carries into an inter-item gap: the item that armed the
            # watchdog has finished and its worker is gone.
            $state = [pscustomobject]@{ IdleSec = 0; StallSec = 0; SawActivity = $true; ActiveSec = 0; LastBytes = [int64]5000; LastIoBytes = $null }

            # Poll 1..19: 19 * 15s = 285s, one poll short of the 300s debounce.
            1..19 | ForEach-Object {
                $state = Get-NextWatchdogState -IdleSec $state.IdleSec -StallSec $state.StallSec -SawActivity $state.SawActivity `
                    -ActiveSec $state.ActiveSec -ArmSec 90 `
                    -LastBytes $state.LastBytes -Active $false -CurrentBytes $null `
                    -LastIoBytes $state.LastIoBytes -CurrentIoBytes $null `
                    -PollSec 15 -DebounceSec 300 -StallLimitSec 1800
            }
            $state.IdleSec | Should -Be 285
            $state.Verdict | Should -Be 'continue'

            # Poll 20: 285s + 15s = exactly 300s -- the boundary itself.
            $state = Get-NextWatchdogState -IdleSec $state.IdleSec -StallSec $state.StallSec -SawActivity $state.SawActivity `
                -ActiveSec $state.ActiveSec -ArmSec 90 `
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
            $state = [pscustomobject]@{ IdleSec = 0; StallSec = 0; SawActivity = $true; ActiveSec = 0; LastBytes = [int64]5000; LastIoBytes = $null }

            # 25 polls * 15s = 375s, comfortably past the 300s debounce --
            # deliberately longer than the boundary test above so this test
            # is unambiguous about being past it, not sitting on the edge.
            1..25 | ForEach-Object {
                $state = Get-NextWatchdogState -IdleSec $state.IdleSec -StallSec $state.StallSec -SawActivity $state.SawActivity `
                    -ActiveSec $state.ActiveSec -ArmSec 90 `
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
            # WHAT THE TWO SIGNALS BUY, AND WHY THIS BOX SHIPS THE STRICTER
            # ONE. Config.ps1 ships CompletionSignal = 'WorkerOnly' -- NOT
            # WorkerOrGpu, whatever this comment used to claim -- because DCV
            # encodes the remote display on the same GPU at 14-49%, so the GPU
            # signal produced "Render active (worker=False gpu=21%)" on an idle
            # box and would have kept it up forever. This test pins what that
            # measured decision COSTS: between two queue items the OLD
            # neuroserver.exe has already exited and the NEW one has not been
            # spawned yet, so WorkerActive briefly reads $false even on a
            # perfectly healthy queue, and under WorkerOnly the debounce starts
            # accruing during that gap where WorkerOrGpu's GPU corroboration
            # would have suppressed it. DebounceSec is what covers that gap
            # instead. GpuBusyPercent=15 and GpuUtil=50 below are both
            # realistic (real renders peg the GPU well above this threshold per
            # Config.ps1's own comment).
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
                -ActiveSec 0 -ArmSec 90 `
                -LastBytes 1000 -Active $activeWorkerOrGpu -CurrentBytes 1000 `
                -LastIoBytes $null -CurrentIoBytes $null `
                -PollSec 15 -DebounceSec 300 -StallLimitSec 1800
            $afterWorkerOrGpu.IdleSec | Should -Be 0
            $afterWorkerOrGpu.Verdict | Should -Be 'continue'

            $afterWorkerOnly = Get-NextWatchdogState -IdleSec 0 -StallSec 0 -SawActivity $true `
                -ActiveSec 0 -ArmSec 90 `
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
            $state = [pscustomobject]@{ IdleSec = 0; StallSec = 0; SawActivity = $false; ActiveSec = 0; LastBytes = [int64]0; LastIoBytes = $null }

            # 30 polls * 15s = 450s -- well past the 300s debounce.
            1..30 | ForEach-Object {
                $state = Get-NextWatchdogState -IdleSec $state.IdleSec -StallSec $state.StallSec -SawActivity $state.SawActivity `
                    -ActiveSec $state.ActiveSec -ArmSec 90 `
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

Describe 'Get-NextHeartbeatState (bounding silence during a healthy render)' {

    # WHAT THIS GUARDS. The poll loop logs only interesting polls, so a healthy
    # progressing render logs NOTHING. On the render reconstructed in docs/14
    # that produced 4 h 49 m of completely empty watchdog.log -- during which a
    # working watchdog and a dead one were indistinguishable. The heartbeat
    # bounds that silence. These tests pin the two properties that matter:
    # it fires on schedule, and it is driven by SILENCE rather than wall time
    # (so branches that already log never accrue toward it).

    It 'does not fire before HeartbeatSec has elapsed' {
        $s = Get-NextHeartbeatState -SilentSec 0 -PollSec 15 -HeartbeatSec 300
        $s.Due       | Should -BeFalse
        $s.SilentSec | Should -Be 15
    }

    It 'fires exactly at the HeartbeatSec boundary and resets the clock itself' {
        # 285 + 15 = 300, the -ge boundary.
        $s = Get-NextHeartbeatState -SilentSec 285 -PollSec 15 -HeartbeatSec 300
        $s.Due       | Should -BeTrue
        $s.SilentSec | Should -Be 0
    }

    It 'fires after exactly HeartbeatSec/PollSec silent polls, then repeats on the same cadence' {
        # 300/15 = 20 polls per heartbeat. Walk 60 polls and count.
        $silent = 0
        $fired  = @()
        foreach ($poll in 1..60) {
            $s = Get-NextHeartbeatState -SilentSec $silent -PollSec 15 -HeartbeatSec 300
            $silent = $s.SilentSec
            if ($s.Due) { $fired += $poll }
        }
        $fired | Should -Be @(20, 40, 60)
    }

    It 'treats HeartbeatSec=0 as DISABLED and pins the clock at 0 so it cannot silently accumulate' {
        $silent = 0
        foreach ($poll in 1..500) {
            $s = Get-NextHeartbeatState -SilentSec $silent -PollSec 15 -HeartbeatSec 0
            $silent = $s.SilentSec
            $s.Due | Should -BeFalse
        }
        $silent | Should -Be 0
    }

    It 'treats a negative HeartbeatSec as disabled too, rather than firing every poll' {
        # A -ge comparison against a negative limit would otherwise be true
        # immediately, turning a nonsense config into a line every 15 seconds.
        $s = Get-NextHeartbeatState -SilentSec 0 -PollSec 15 -HeartbeatSec -1
        $s.Due       | Should -BeFalse
        $s.SilentSec | Should -Be 0
    }

    It 'still fires when a single poll overshoots the interval (PollSec > HeartbeatSec)' {
        $s = Get-NextHeartbeatState -SilentSec 0 -PollSec 600 -HeartbeatSec 300
        $s.Due       | Should -BeTrue
        $s.SilentSec | Should -Be 0
    }

    It 'measures SILENCE, not wall time: a reset part-way through defers the heartbeat' {
        # 19 silent polls (285s), then the caller logs something and resets to
        # 0. The heartbeat must NOT fire on the next poll just because 300s of
        # wall time has passed -- it is only due after 300s of CONTINUED
        # silence. This is what stops a stalling render (which logs every poll)
        # from also emitting heartbeats.
        $silent = 0
        foreach ($poll in 1..19) {
            $silent = (Get-NextHeartbeatState -SilentSec $silent -PollSec 15 -HeartbeatSec 300).SilentSec
        }
        $silent | Should -Be 285

        $silent = 0   # a logging branch fired

        $next = Get-NextHeartbeatState -SilentSec $silent -PollSec 15 -HeartbeatSec 300
        $next.Due | Should -BeFalse
    }

    It 'is a pure function of (SilentSec, PollSec, HeartbeatSec) alone -- the property the docs/15 fix actually relies on' {
        # Watchdog.ps1 now calls this from THREE blocking loops (the pre-GUI
        # wait loop, the main monitoring loop, and the unlock gate -- see its
        # own SCOPE section). That is only safe because the function has no
        # hidden coupling to which loop is calling it -- no $script:-scoped
        # clock of its own, no memory of a previous call. Two independent calls
        # with identical arguments, as if interleaved between two different
        # loops, must return identical results every time.
        $fromWaitLoop       = Get-NextHeartbeatState -SilentSec 285 -PollSec 15 -HeartbeatSec 300
        $fromMonitoringLoop = Get-NextHeartbeatState -SilentSec 285 -PollSec 15 -HeartbeatSec 300

        $fromWaitLoop.Due       | Should -Be $fromMonitoringLoop.Due
        $fromWaitLoop.SilentSec | Should -Be $fromMonitoringLoop.SilentSec

        1..5 | ForEach-Object {
            $s = Get-NextHeartbeatState -SilentSec 100 -PollSec 15 -HeartbeatSec 300
            $s.Due       | Should -BeFalse
            $s.SilentSec | Should -Be 115
        }
    }

    It 'bounds the UNLOCK GATE''s silence too, on that loop''s own UnlockPollSec cadence rather than PollSec' {
        # THE THIRD BLOCKING LOOP. This function's SCOPE section states the
        # invariant literally -- "Any future blocking loop added to this script
        # needs a call here too, or it reintroduces exactly that hole" -- and
        # the unlock gate was that future loop: between "Waiting up to N min for
        # output files to unlock" and either "All output files are unlocked" or
        # the timeout WARN it logged nothing at all, during the phase where the
        # box is about to power off and erase the scratch volume.
        #
        # The tick is UnlockPollSec (shipped 10s), NOT PollSec (15s). At the
        # shipped UnlockTimeoutMin=5 the gate can only run ~30 ticks, so the
        # heartbeat lands right at the deadline and this is mostly
        # future-proofing -- but UnlockTimeoutMin is an operator knob, and
        # raising it is exactly what would otherwise open a 30-minute void.
        $unlockPollSec = 10
        $silent = 0
        $fired  = @()

        # 90 ticks x 10s = 900s, i.e. what a raised UnlockTimeoutMin of 15 min
        # would actually walk through.
        foreach ($tick in 1..90) {
            $s = Get-NextHeartbeatState -SilentSec $silent -PollSec $unlockPollSec -HeartbeatSec 300
            $silent = $s.SilentSec
            if ($s.Due) { $fired += $tick }
        }

        # 300 / 10 = every 30th tick, three times over 900s -- and NOT every
        # 20th, which is what feeding it the monitoring loop's PollSec would
        # have produced.
        $fired | Should -Be @(30, 60, 90)
    }

    It 'HeartbeatSec<=0 pins SilentSec at 0 no matter which loop-shaped PollSec feeds it, so a disabled heartbeat cannot silently accumulate' {
        # PollSec varies here to prove the pin holds independent of the
        # caller's own poll cadence -- both loops' cadence and a deliberately
        # oversized one, so no loop-specific assumption is hiding in the pin.
        foreach ($pollSec in @(15, 30, 600)) {
            $s = Get-NextHeartbeatState -SilentSec 999999 -PollSec $pollSec -HeartbeatSec 0
            $s.Due       | Should -BeFalse
            $s.SilentSec | Should -Be 0
        }
    }
}

Describe 'Get-TopazWaitHeartbeatMessage (pre-GUI wait loop heartbeat text)' {

    # WHAT THIS GUARDS. Get-TopazPids returns $null when the CIM query FAILED
    # and @() when the query SUCCEEDED but simply found no Topaz GUI yet. Both
    # send the wait loop round again, and before this function existed both
    # looked identical in the log -- identical, too, to a watchdog that had
    # died outright. The $null-vs-@() branch below is the entire judgement
    # this function carries; the empty-collection test just below is the
    # single most important one in this Describe, because a regression there
    # silently restores the original ambiguity.

    It "renders `$null TopazPids as a CIM query fault, not as 'not running'" {
        $msg = Get-TopazWaitHeartbeatMessage -TopazPids $null -NameLike 'Topaz Video%' -HeartbeatSec 300
        $msg | Should -Match 'CIM process query UNREADABLE'
        $msg | Should -Not -Match 'not running'
    }

    It "renders an EMPTY collection as 'not running', never as UNREADABLE -- the exact distinction this fix exists to make" {
        $msg = Get-TopazWaitHeartbeatMessage -TopazPids @() -NameLike 'Topaz Video%' -HeartbeatSec 300
        $msg | Should -Match 'not running'
        $msg | Should -Not -Match 'UNREADABLE'
    }

    It "renders a NON-empty collection as 'not running' too -- only an unreadable query is a fault, not the GUI's plain absence" {
        $msg = Get-TopazWaitHeartbeatMessage -TopazPids @(1234) -NameLike 'Topaz Video%' -HeartbeatSec 300
        $msg | Should -Match 'not running'
        $msg | Should -Not -Match 'UNREADABLE'
    }

    It 'echoes NameLike verbatim, wildcard and all' {
        $msg = Get-TopazWaitHeartbeatMessage -TopazPids @() -NameLike 'Topaz Video%' -HeartbeatSec 300
        $msg | Should -Match ([regex]::Escape("LIKE 'Topaz Video%'"))
    }

    It 'echoes HeartbeatSec formatted as e.g. "300s" -- no space, and the ${HeartbeatSec}s brace form not silently broken' {
        # If a future edit dropped the braces (bare $HeartbeatSecs), PowerShell
        # would try to interpolate a nonexistent variable named "HeartbeatSecs"
        # and silently render an empty string instead -- "every s while
        # waiting" -- which the exact match below would catch.
        $msg = Get-TopazWaitHeartbeatMessage -TopazPids @() -NameLike 'Topaz Video%' -HeartbeatSec 300
        $msg | Should -Match 'every 300s while waiting'
        $msg | Should -Not -Match 'every 300 s'
    }

    It 'does not throw on an empty-string NameLike (the param is AllowEmptyString)' {
        { Get-TopazWaitHeartbeatMessage -TopazPids @() -NameLike '' -HeartbeatSec 300 } | Should -Not -Throw

        $msg = Get-TopazWaitHeartbeatMessage -TopazPids @() -NameLike '' -HeartbeatSec 300
        $msg | Should -Match "LIKE ''"
    }

    It 'is pure: two calls with identical arguments return an identical string' {
        $first  = Get-TopazWaitHeartbeatMessage -TopazPids @(111, 222) -NameLike 'Topaz Video%' -HeartbeatSec 300
        $second = Get-TopazWaitHeartbeatMessage -TopazPids @(111, 222) -NameLike 'Topaz Video%' -HeartbeatSec 300
        $second | Should -Be $first
    }

    It 'is side-effect free: it never logs, it only returns text for the caller to log' {
        # No Write-TopazLog convention exists elsewhere in this suite to lean
        # on, so this is deliberately simple: make the mock fail loudly if the
        # pure formatter ever calls it, on either the fault or normal path.
        Mock Write-TopazLog { throw 'Get-TopazWaitHeartbeatMessage must not log -- the wait loop does the logging, this function only builds the string' }

        { Get-TopazWaitHeartbeatMessage -TopazPids $null -NameLike 'Topaz Video%' -HeartbeatSec 300 } | Should -Not -Throw
        { Get-TopazWaitHeartbeatMessage -TopazPids @()   -NameLike 'Topaz Video%' -HeartbeatSec 300 } | Should -Not -Throw
    }
}
