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

        It 'does not throw and returns Active=$true / WorkerActive=$true as plain booleans' {
            { Test-RenderActive } | Should -Not -Throw
            $result = Test-RenderActive

            $result.Active | Should -Not -BeOfType [System.Management.Automation.PSReference]
            $result.Active | Should -BeOfType [bool]
            $result.Active | Should -Be $true

            $result.WorkerActive | Should -BeOfType [bool]
            $result.WorkerActive | Should -Be $true
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

        It 'does not throw and returns Active=$false / WorkerActive=$false (WorkerOnly signal)' {
            { Test-RenderActive } | Should -Not -Throw
            $result = Test-RenderActive

            $result.Active | Should -Not -BeOfType [System.Management.Automation.PSReference]
            $result.Active | Should -BeOfType [bool]
            $result.Active | Should -Be $false

            $result.WorkerActive | Should -BeOfType [bool]
            $result.WorkerActive | Should -Be $false
        }
    }

    Context 'workers unknown ($null)' {
        BeforeEach {
            Mock Get-TopazWorkers { return $null }
            Mock Get-GpuUtilizationMax { return $null }
        }

        It 'does not throw and returns Active=$null (not a PSReference, not a guessed value)' {
            { Test-RenderActive } | Should -Not -Throw
            $result = Test-RenderActive

            $result.Active | Should -Not -BeOfType [System.Management.Automation.PSReference]
            $result.Active | Should -Be $null

            $result.WorkerActive | Should -Be $null
        }
    }
}

Describe 'Resolve-WorkerAttribution' {

    It 'adopts a worker parented to a live Topaz GUI PID and records it in KnownWorkers' {
        $known  = @{}
        $worker = [pscustomobject]@{ ProcessId = 500; ParentProcessId = 100; CreationDate = [datetime]'2026-01-01T00:00:00' }

        $result = Resolve-WorkerAttribution -TopazPids @(100) -Workers @($worker) -KnownWorkers $known

        @($result).Count | Should -Be 1
        $result[0].ProcessId | Should -Be 500
        $key = "500|$($worker.CreationDate.Ticks)"
        $known.ContainsKey($key) | Should -Be $true
    }

    It 'keeps counting an orphan whose key is already in KnownWorkers, even when TopazPids is @() (empty, not $null)' {
        $worker = [pscustomobject]@{ ProcessId = 500; ParentProcessId = 999; CreationDate = [datetime]'2026-01-01T00:00:00' }
        $key    = "500|$($worker.CreationDate.Ticks)"
        $known  = @{ $key = $true }

        $result = Resolve-WorkerAttribution -TopazPids @() -Workers @($worker) -KnownWorkers $known

        @($result).Count | Should -Be 1
        $result[0].ProcessId | Should -Be 500
    }

    It 'returns $null when TopazPids is $null and no KnownWorkers entry matches (genuinely unknown, not "no worker")' {
        $known  = @{}
        $result = Resolve-WorkerAttribution -TopazPids $null -Workers @() -KnownWorkers $known

        $result | Should -Be $null
    }

    It 'matches via KnownWorkers when TopazPids is $null but the worker is already known' {
        $worker = [pscustomobject]@{ ProcessId = 500; ParentProcessId = 999; CreationDate = [datetime]'2026-01-01T00:00:00' }
        $key    = "500|$($worker.CreationDate.Ticks)"
        $known  = @{ $key = $true }

        $result = Resolve-WorkerAttribution -TopazPids $null -Workers @($worker) -KnownWorkers $known

        @($result).Count | Should -Be 1
        $result[0].ProcessId | Should -Be 500
    }

    It 'prunes a KnownWorkers key that does not appear in this poll''s Workers' {
        $known  = @{ 'stale|123' = $true }
        $result = Resolve-WorkerAttribution -TopazPids @() -Workers @() -KnownWorkers $known

        @($result).Count | Should -Be 0
        $known.ContainsKey('stale|123') | Should -Be $false
    }

    It 'does NOT match the same ProcessId under a different CreationDate (distinct process; old key is pruned)' {
        $oldCreation = [datetime]'2026-01-01T00:00:00'
        $newCreation = [datetime]'2026-01-02T00:00:00'
        $oldKey      = "500|$($oldCreation.Ticks)"
        $known       = @{ $oldKey = $true }
        $newWorker   = [pscustomobject]@{ ProcessId = 500; ParentProcessId = 999; CreationDate = $newCreation }

        $result = Resolve-WorkerAttribution -TopazPids @() -Workers @($newWorker) -KnownWorkers $known

        @($result).Count | Should -Be 0
        $known.ContainsKey($oldKey) | Should -Be $false
    }
}

Describe 'Get-TopazWorkers (real end-to-end delegation, not just Resolve-WorkerAttribution in isolation)' {
    # The Describe block above tests Resolve-WorkerAttribution directly, which
    # never exercises Get-TopazWorkers's own delegation line (Watchdog.ps1:216:
    # `return Resolve-WorkerAttribution -TopazPids $topazPids -Workers $workers
    # -KnownWorkers $script:KnownWorkers`) or Get-TopazPids's own
    # comma-protected CIM-wrapping return (Watchdog.ps1:91). These tests let
    # BOTH real function bodies run, with only the underlying Get-CimInstance
    # CIM call replaced.
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
    # comma from Get-TopazPids's `return , @(...)` (Watchdog.ps1:91): doing so
    # does not change what the Resolve-WorkerAttribution tests above see (they
    # call it directly with an already-flat array), but it DOES turn the "0
    # Topaz GUIs / 0 workers" case from a confident empty array into $null
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
            [CmdletBinding()]
            param([string]$ClassName, [string]$Filter)

            if ($ClassName -ne 'Win32_Process') {
                throw "Test shadow Get-CimInstance only supports ClassName 'Win32_Process' (got '$ClassName')."
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
