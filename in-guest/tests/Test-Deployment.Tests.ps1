<#
.SYNOPSIS
    Pester 5 unit tests for the safety-relevant pure predicates in
    Test-Deployment.ps1.

.DESCRIPTION
    Test-Deployment.ps1 is the tool an operator consults before arming
    DryRun=$false. Two of its decisions are about DESTRUCTION rather than
    diagnostics:

      * Test-StopPlanCanReachGuestShutdown decides whether checks 10 and 11
        FAIL or merely WARN -- i.e. whether the operator is warned that a
        guest-shutdown fallback on a box whose instanceInitiatedShutdownBehavior
        is 'terminate' would DESTROY the instance instead of stopping it. The
        expression was previously duplicated verbatim in both call sites, with
        nothing pinning them together.

      * Resolve-EphemeralOutputVerdict decides whether OutputIsEphemeral agrees
        with the volume OutputDir actually lives on. Nothing anywhere in the
        pipeline cross-checked that, and the disagreement in one direction
        disarms the interlock that exists because of the render loss in
        docs/16.

    Both are pure, and the file is dot-sourced with -LibraryOnly (the same seam
    Initialize-ScratchDisk.ps1 and Stop-Sequence.ps1 use), so nothing here runs
    a check, probes IMDS, calls the AWS CLI, touches PATH or prints a verdict.

    DELIBERATELY OUT OF SCOPE: check 11's own DryRun verdict chain is left
    INLINE in Test-Deployment.ps1 and is not covered here. Its only
    decision-bearing input is Test-StopPlanCanReachGuestShutdown, which IS
    pinned above; everything the chain adds on top is message formatting over
    $cfg.DryRun and the $shutdownBehaviorValue that check 10 already verified,
    so extracting a Resolve-DryRunVerdict today would test PowerShell's `if`
    rather than a safety property. Recorded so the untested chain next to a
    tested predicate reads as a decision and not an oversight -- and so the
    trigger is explicit: the moment that chain grows a condition of its own,
    extract Resolve-DryRunVerdict and cover the full {DryRun} x {StopStrategy}
    x {shutdown behavior} matrix, the "*** DANGEROUS COMBINATION ***" branch
    first.

    Run with:
        Invoke-Pester -Path in-guest/tests -CI
#>

BeforeAll {
    . "$PSScriptRoot/../Test-Deployment.ps1" -LibraryOnly
}

Describe 'Test-StopPlanCanReachGuestShutdown' {

    It "returns `$false ONLY for 'Ec2ApiStop' alone -- the one plan Resolve-StopPlan never extends to Stop-Computer" {
        Test-StopPlanCanReachGuestShutdown -StopStrategy 'Ec2ApiStop' | Should -BeFalse
    }

    It "returns `$true for the shipped default 'Auto' and for 'GuestShutdown'" {
        Test-StopPlanCanReachGuestShutdown -StopStrategy 'Auto' | Should -BeTrue
        Test-StopPlanCanReachGuestShutdown -StopStrategy 'GuestShutdown' | Should -BeTrue
    }

    It 'fails SAFE for an absent or unrecognized StopStrategy' {
        # Resolve-StopPlan's own `default` branch returns the two-action plan,
        # so an unrecognized value really can reach Stop-Computer. Reporting
        # $false here would silently downgrade check 11's "DANGEROUS
        # COMBINATION" FAIL to a PASS on a box that terminates on shutdown.
        foreach ($strategy in @($null, '', '   ', 'Auto ', 'SomethingNew')) {
            Test-StopPlanCanReachGuestShutdown -StopStrategy $strategy |
                Should -BeTrue -Because "'$strategy' is not exactly 'Ec2ApiStop', so a guest shutdown may be reachable"
        }
    }

    It "matches Resolve-StopPlan's own case-insensitivity for 'Ec2ApiStop'" {
        # PowerShell's -ne, Assert-ValidStopStrategy's -notcontains and
        # Resolve-StopPlan's ValidateSet are ALL case-insensitive, so a config
        # carrying 'ec2apistop' really does produce the single-action plan.
        # Treating it as "can reach guest shutdown" here would raise a FAIL for
        # a plan that genuinely never calls Stop-Computer.
        Test-StopPlanCanReachGuestShutdown -StopStrategy 'ec2apistop' | Should -BeFalse
    }
}

Describe 'Resolve-EphemeralOutputVerdict' {

    It 'PASSes the shipped configuration: renders on the wiped scratch volume with the interlock ARMED' {
        $verdict = Resolve-EphemeralOutputVerdict -OutputDir 'D:\Renders' -ScratchDriveLetter 'D' -OutputIsEphemeral $true
        $verdict.Status | Should -Be 'PASS'
    }

    It 'PASSes persistent output with the interlock deliberately off' {
        $verdict = Resolve-EphemeralOutputVerdict -OutputDir 'C:\Renders' -ScratchDriveLetter 'D' -OutputIsEphemeral $false
        $verdict.Status | Should -Be 'PASS'
    }

    It 'FAILs renders-on-the-scratch-volume with the interlock DISARMED -- the data-loss combination' {
        # A 'stalled' or 'maxlifetime' stop never runs the completion safety
        # gate, so with OutputIsEphemeral=$false nothing checks the upload
        # before the instance store is erased.
        $verdict = Resolve-EphemeralOutputVerdict -OutputDir 'D:\Renders' -ScratchDriveLetter 'D' -OutputIsEphemeral $false
        $verdict.Status | Should -Be 'FAIL'
        $verdict.Detail | Should -BeLike '*DATA LOSS RISK*'
    }

    It 'WARNs (never FAILs) when persistent output is marked ephemeral -- it costs uptime, not renders' {
        $verdict = Resolve-EphemeralOutputVerdict -OutputDir 'C:\Renders' -ScratchDriveLetter 'D' -OutputIsEphemeral $true
        $verdict.Status | Should -Be 'WARN'
    }

    It "normalizes a ScratchDriveLetter written as 'D:' instead of 'D'" {
        # Get-ExistingScratchDriveValidation already trims this way; without the
        # same trim here a perfectly good config produced a spurious FAIL.
        (Resolve-EphemeralOutputVerdict -OutputDir 'D:\Renders' -ScratchDriveLetter 'D:' -OutputIsEphemeral $true).Status |
            Should -Be 'PASS'
    }

    It 'compares drive letters case-insensitively' {
        (Resolve-EphemeralOutputVerdict -OutputDir 'd:\Renders' -ScratchDriveLetter 'D' -OutputIsEphemeral $true).Status |
            Should -Be 'PASS'
        (Resolve-EphemeralOutputVerdict -OutputDir 'D:\Renders' -ScratchDriveLetter 'd' -OutputIsEphemeral $false).Status |
            Should -Be 'FAIL'
    }

    It 'WARNs rather than guessing when OutputDir has no drive-letter root' {
        # Get-TopazWindowsPathRoot returns '' for a UNC or relative path. There
        # is nothing to compare, and inventing a verdict either way would be
        # worse than saying so.
        foreach ($path in @('\\server\share\Renders', 'Renders', '')) {
            (Resolve-EphemeralOutputVerdict -OutputDir $path -ScratchDriveLetter 'D' -OutputIsEphemeral $true).Status |
                Should -Be 'WARN' -Because "'$path' has no drive-letter root"
        }
    }
}
