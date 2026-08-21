<#
.SYNOPSIS
    Pester 5 unit tests for Stop-Sequence.ps1's refuse-to-stop orchestration
    and the ORDER its safety interlocks run in.

.DESCRIPTION
    Stop-Sequence.ps1 is the highest-consequence file in this repo: it decides
    whether the instance may power off, which on the shipped configuration means
    whether the instance-store volume holding a finished render may be erased.
    Its individual helpers live in Config.ps1 and are well covered there; what
    was NOT covered is the wiring -- and the wiring is where the ordering
    guarantees live:

      * the ephemeral interlock runs BEFORE the completed-stop safety gate;
      * the safety gate runs BEFORE the SNS publish and BEFORE the DryRun guard,
        so neither can announce or claim a stop an interlock has refused;
      * every refusal returns exactly $false, because Watchdog.ps1 tests
        `$stopResult -eq $false` to decide whether to re-arm and retry. Anything
        else there ($null, an array, a log line) silently disables the retry
        path that keeps an un-uploaded render recoverable.

    Moving the safety gate below the DryRun guard, dropping a `return $false`,
    or letting `exit` leak onto the watchdog's call path would all leave the
    rest of this suite green. These tests exist to fail instead.

    Two layers, deliberately:

      1. Invoke-TopazStopSequence, reached through Stop-Sequence.ps1's
         -LibraryOnly seam (the same seam Initialize-ScratchDisk.ps1 uses), with
         every I/O-bound Config.ps1 function mocked. No rclone, no AWS CLI, no
         IMDS, no power-off, no log file.
      2. The script's own TAIL, exercised by running a copy of the real file
         beside a stand-in Config.ps1 (see the sandbox below). That is the only
         way to pin what `& Stop-Sequence.ps1` actually yields to Watchdog.ps1,
         which is the contract the whole retry path rests on.

    Run with:
        Invoke-Pester -Path in-guest/tests -CI
#>

BeforeAll {
    . "$PSScriptRoot/../Stop-Sequence.ps1" -LibraryOnly
}

Describe 'Resolve-EphemeralUploadRefusal (pure ephemeral interlock)' {

    Context 'OutputDir is PERSISTENT (OutputIsEphemeral = $false)' {
        # Nothing here can destroy a render, so a failed or absent upload stays
        # best-effort exactly as it always has.

        It 'allows the stop with no UploadTarget at all' {
            $decision = Resolve-EphemeralUploadRefusal -UploadTarget '' -OutputIsEphemeral $false
            $decision.ShouldStop | Should -BeTrue
            $decision.RefusalReason | Should -BeNullOrEmpty
        }

        It 'allows the stop even when the upload FAILED' {
            $decision = Resolve-EphemeralUploadRefusal -UploadTarget 'gdrive:temp' -OutputIsEphemeral $false -UploadSucceeded $false
            $decision.ShouldStop | Should -BeTrue
        }
    }

    Context 'OutputDir is EPHEMERAL (OutputIsEphemeral = $true)' {

        It 'REFUSES when no UploadTarget is configured -- stopping would erase every render' {
            $decision = Resolve-EphemeralUploadRefusal -UploadTarget '' -OutputIsEphemeral $true
            $decision.ShouldStop | Should -BeFalse
            $decision.RefusalReason | Should -Be 'NoUploadTarget'
        }

        It 'REFUSES a whitespace-only UploadTarget the same way (IsNullOrWhiteSpace, not -eq "")' {
            (Resolve-EphemeralUploadRefusal -UploadTarget "  `t " -OutputIsEphemeral $true).RefusalReason |
                Should -Be 'NoUploadTarget'
        }

        It 'REFUSES when the upload was attempted and FAILED' {
            $decision = Resolve-EphemeralUploadRefusal -UploadTarget 'gdrive:temp' -OutputIsEphemeral $true -UploadSucceeded $false
            $decision.ShouldStop | Should -BeFalse
            $decision.RefusalReason | Should -Be 'UploadFailed'
        }

        It 'allows the stop when the upload SUCCEEDED' {
            $decision = Resolve-EphemeralUploadRefusal -UploadTarget 'gdrive:temp' -OutputIsEphemeral $true -UploadSucceeded $true
            $decision.ShouldStop | Should -BeTrue
            $decision.RefusalReason | Should -BeNullOrEmpty
        }

        It 'does NOT treat "not attempted" ($null) as a failure when a target exists' {
            # $null means Invoke-TopazRenderUpload was never reached. Only an
            # explicit $false is a failed upload; conflating the two would refuse
            # every stop on a path that never tried to upload anything.
            (Resolve-EphemeralUploadRefusal -UploadTarget 'gdrive:temp' -OutputIsEphemeral $true -UploadSucceeded $null).ShouldStop |
                Should -BeTrue
        }
    }
}

Describe 'Invoke-TopazStopSequence (refusal orchestration + safety ordering)' {
    # Every external effect is mocked: Invoke-TopazRenderUpload (rclone),
    # Test-TopazCompletedStopSafetyGate (rclone check + worker query),
    # Invoke-TopazAwsCli (aws.exe), Get-Ec2Identity (IMDS), Stop-Computer
    # (the actual power-off) and Start-Sleep (StopVerifySec, 300s by default).
    # Resolve-StopPlan, Build-AwsCliArgs, Get-TopazStopNotification and
    # Resolve-EphemeralUploadRefusal are left REAL -- they are pure, and using
    # the genuine ones is what makes the ordering assertions meaningful.

    BeforeAll {
        function Stop-Computer {
            # Deliberately shadows the built-in cmdlet name, and NOT merely as a
            # safety measure against powering off the CI runner: Pester builds a
            # mock's parameter surface from the real command's metadata, and
            # Stop-Computer's -Force parameter does not exist on non-Windows
            # PowerShell, so `Mock Stop-Computer` alone made the production call
            # fail with "A parameter cannot be found that matches parameter name
            # 'Force'" -- silently exercising the catch branch instead of the
            # shutdown branch this suite is asserting on. Mocking THIS function
            # (Function: resolves before Cmdlet:) keeps Should -Invoke available
            # while accepting the parameters Stop-Sequence.ps1 really passes.
            # Windows PowerShell 5.1 production code never defines it; this file
            # is test-only.
            [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '')]
            # The name is fixed by the cmdlet it shadows, so the Stop- verb
            # cannot be renamed away; this stand-in changes no state whatsoever,
            # and PSUseShouldProcessForStateChangingFunctions is not on ci.yml's
            # Warning allowlist.
            [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
            [CmdletBinding()]
            param([switch]$Force)

            if (-not $Force) {
                throw 'Stop-Sequence.ps1 must always pass -Force: a dialog-blocking GUI must not be able to veto the shutdown.'
            }
        }

        function Get-StopTestConfig {
            param(
                [bool]$OutputIsEphemeral = $true,
                [string]$UploadTarget = 'gdrive:temp',
                [bool]$DryRun = $false,
                [string]$StopStrategy = 'Ec2ApiStop',
                [string]$SnsTopicArn = 'arn:aws:sns:us-east-1:123456789012:topaz',
                [string]$S3SyncTarget = ''
            )

            [pscustomobject]@{
                OutputDir         = 'D:\Renders'
                OutputIsEphemeral = $OutputIsEphemeral
                UploadTarget      = $UploadTarget
                RclonePath        = 'C:\fake\rclone.exe'
                RcloneConfigPath  = 'C:\fake\rclone.conf'
                LogDir            = 'C:\fake\logs'
                S3SyncTarget      = $S3SyncTarget
                S3SyncTimeoutSec  = 900
                SnsTopicArn       = $SnsTopicArn
                AwsCliTimeoutSec  = 60
                UploadTimeoutSec  = 14400
                StopStrategy      = $StopStrategy
                StopVerifySec     = 300
                DryRun            = $DryRun
            }
        }
    }

    BeforeEach {
        # $script:CallSeq is the ordering fixture: every mocked step appends its
        # own name, so an assertion on the LIST pins the sequence, not merely
        # that each step happened.
        $script:CallSeq = New-Object System.Collections.Generic.List[string]
        $script:LogLines = New-Object System.Collections.Generic.List[string]

        Mock Write-TopazLog {
            # Only the parameters this fixture reads are declared: Pester
            # splats the bound parameters by name, and an unread $Component
            # would trip PSReviewUnusedParameter.
            param($Message, $Level)
            $script:LogLines.Add("$Level|$Message")
        }
        Mock Get-Ec2Identity {
            [pscustomobject]@{ InstanceId = 'i-0abcdef0123456789'; Region = 'us-east-1' }
        }
        Mock Invoke-TopazRenderUpload {
            $script:CallSeq.Add('upload')
            return $script:UploadResult
        }
        Mock Test-TopazCompletedStopSafetyGate {
            $script:CallSeq.Add('gate')
            return $script:GateResult
        }
        Mock Invoke-TopazAwsCli {
            param($Arguments)
            $script:CallSeq.Add("aws:$($Arguments[0])")
            return $script:AwsResult
        }
        Mock Stop-Computer {
            param($Force)
            # Assert the -Force contract here rather than in a separate test:
            # every call in this suite flows through it. See docs/05 for why
            # -Force is safe (the workers have exited and the outputs are
            # unlocked before the stop is ever reached).
            if (-not $Force) { throw 'Stop-Computer was called without -Force.' }
            $script:CallSeq.Add('stop-computer')
        }
        Mock Start-Sleep { }

        $script:UploadResult = $true
        $script:GateResult   = $true
        $script:AwsResult    = $true
    }

    Context 'the ephemeral interlock refuses BEFORE anything else can act' {

        It 'returns $false, and never uploads/gates/notifies/stops, when OutputDir is ephemeral with no UploadTarget' {
            $cfg = Get-StopTestConfig -UploadTarget ''
            $result = Invoke-TopazStopSequence -Config $cfg -Reason 'completed'

            $result | Should -BeFalse
            $script:CallSeq | Should -BeNullOrEmpty
            Should -Invoke Invoke-TopazRenderUpload -Times 0 -Exactly
            Should -Invoke Test-TopazCompletedStopSafetyGate -Times 0 -Exactly
            Should -Invoke Invoke-TopazAwsCli -Times 0 -Exactly
            Should -Invoke Stop-Computer -Times 0 -Exactly
        }

        It 'returns $false and does NOT run the completion gate when the upload failed on ephemeral output' {
            $script:UploadResult = $false
            $cfg = Get-StopTestConfig

            $result = Invoke-TopazStopSequence -Config $cfg -Reason 'completed'

            $result | Should -BeFalse
            # 'upload' and nothing after it: the gate, the SNS publish and the
            # stop plan are all downstream of a refusal that already fired.
            $script:CallSeq | Should -Be @('upload')
            Should -Invoke Test-TopazCompletedStopSafetyGate -Times 0 -Exactly
            Should -Invoke Stop-Computer -Times 0 -Exactly
        }

        It 'still returns $false (never $true) when DryRun is on -- a refusal is not a suppressed stop' {
            # The DryRun guard returns $true ("suppressed on purpose"). If it
            # ever ran before the interlock, an upload failure on ephemeral
            # storage would be reported to Watchdog.ps1 as a successful stop and
            # the retry path would never fire.
            $script:UploadResult = $false
            $cfg = Get-StopTestConfig -DryRun $true

            Invoke-TopazStopSequence -Config $cfg -Reason 'completed' | Should -BeFalse
        }

        It 'proceeds to stop when OutputDir is PERSISTENT even though the upload failed' {
            $script:UploadResult = $false
            $cfg = Get-StopTestConfig -OutputIsEphemeral $false

            Invoke-TopazStopSequence -Config $cfg -Reason 'completed' | Should -Not -BeNullOrEmpty
            $script:CallSeq | Should -Contain 'aws:ec2'
        }
    }

    Context 'the completed-stop safety gate refuses BEFORE the SNS publish and the DryRun guard' {

        It 'returns $false and publishes NO notification when the gate refuses' {
            $script:GateResult = $false
            $cfg = Get-StopTestConfig

            $result = Invoke-TopazStopSequence -Config $cfg -Reason 'completed'

            $result | Should -BeFalse
            $script:CallSeq | Should -Be @('upload', 'gate')
            Should -Invoke Invoke-TopazAwsCli -Times 0 -Exactly
            Should -Invoke Stop-Computer -Times 0 -Exactly
        }

        It 'returns $false when the gate refuses even with DryRun on -- the guard must not claim the refused stop' {
            $script:GateResult = $false
            $cfg = Get-StopTestConfig -DryRun $true

            Invoke-TopazStopSequence -Config $cfg -Reason 'completed' | Should -BeFalse
        }

        It "runs the gate ONLY for reason='completed' -- stalled and maxlifetime keep their existing semantics" {
            foreach ($reason in @('stalled', 'maxlifetime')) {
                $script:CallSeq.Clear()
                Invoke-TopazStopSequence -Config (Get-StopTestConfig) -Reason $reason | Out-Null
                $script:CallSeq | Should -Not -Contain 'gate' -Because "reason='$reason' must not acquire a new activity gate"
            }
        }
    }

    Context 'the healthy path, in order' {

        It 'uploads, gates, notifies, then calls ec2:StopInstances -- in that order' {
            $cfg = Get-StopTestConfig -S3SyncTarget 's3://bucket/renders/'

            Invoke-TopazStopSequence -Config $cfg -Reason 'completed' | Out-Null

            $script:CallSeq | Should -Be @('aws:s3', 'upload', 'gate', 'aws:sns', 'aws:ec2')
        }

        It 'returns $true WITHOUT stopping anything when DryRun suppresses the power-off' {
            $cfg = Get-StopTestConfig -DryRun $true

            $result = Invoke-TopazStopSequence -Config $cfg -Reason 'completed'

            $result | Should -BeTrue
            $script:CallSeq | Should -Be @('upload', 'gate', 'aws:sns')
            Should -Invoke Stop-Computer -Times 0 -Exactly
        }

        It 'performs a REAL stop when DryRun is set but -IgnoreDryRun was passed (the timed backstop)' {
            $cfg = Get-StopTestConfig -DryRun $true

            Invoke-TopazStopSequence -Config $cfg -Reason 'maxlifetime' -IgnoreDryRun $true | Out-Null

            $script:CallSeq | Should -Contain 'aws:ec2'
        }

        It 'falls back to a guest shutdown when the API stop is refused under the Auto plan' {
            $script:AwsResult = $false
            $cfg = Get-StopTestConfig -StopStrategy 'Auto' -SnsTopicArn ''

            Invoke-TopazStopSequence -Config $cfg -Reason 'completed' | Out-Null

            $script:CallSeq | Should -Be @('upload', 'gate', 'aws:ec2', 'stop-computer')
        }

        It 'reports a refusal ($false) when every action in the plan was attempted and the box is still up' {
            # Surviving the StopVerifySec wait means the stop did not take
            # effect. Reporting that as success would leave Watchdog.ps1 exiting
            # with nothing watching a still-billing instance.
            $script:AwsResult = $false
            $cfg = Get-StopTestConfig -StopStrategy 'Auto' -SnsTopicArn ''

            Invoke-TopazStopSequence -Config $cfg -Reason 'completed' | Should -BeFalse
        }
    }

    Context 'the post-stop wait describes the plan it is actually in' {

        It "says no further actions remain when the plan is Ec2ApiStop alone" {
            Invoke-TopazStopSequence -Config (Get-StopTestConfig -SnsTopicArn '') -Reason 'completed' | Out-Null

            $warn = @($script:LogLines | Where-Object { $_ -like 'WARN|Still running*' })
            $warn.Count | Should -Be 1
            $warn[0] | Should -BeLike '*No further actions remain in the plan.*'
            $warn[0] | Should -Not -BeLike '*Escalating*'
        }

        It 'names the action it is escalating to when one actually follows' {
            Invoke-TopazStopSequence -Config (Get-StopTestConfig -StopStrategy 'Auto' -SnsTopicArn '') -Reason 'completed' | Out-Null

            $warn = @($script:LogLines | Where-Object { $_ -like 'WARN|Still running*' })
            $warn.Count | Should -Be 1
            $warn[0] | Should -BeLike '*Escalating to the next action in the plan (GuestShutdown).*'
        }
    }

    Context 'output-stream hygiene (the value Watchdog.ps1 compares with -eq $false)' {

        It 'emits EXACTLY ONE object, a [bool], on every refusal path' {
            $cases = @(
                @{ Upload = $true;  Gate = $false; Target = 'gdrive:temp' },
                @{ Upload = $false; Gate = $true;  Target = 'gdrive:temp' },
                @{ Upload = $true;  Gate = $true;  Target = '' }
            )
            foreach ($case in $cases) {
                $script:UploadResult = $case.Upload
                $script:GateResult   = $case.Gate
                $captured = @(Invoke-TopazStopSequence -Config (Get-StopTestConfig -UploadTarget $case.Target) -Reason 'completed')
                $captured.Count | Should -Be 1
                $captured[0] | Should -BeOfType [bool]
                $captured[0] | Should -BeFalse
            }
        }
    }
}

Describe 'Stop-Sequence.ps1 entry point (what the caller actually receives)' {
    # WHY A SANDBOX. Stop-Sequence.ps1 dot-sources "$PSScriptRoot\Config.ps1" by
    # literal name -- a contract this repo never changes -- so the only way to
    # run the REAL script tail off a live EC2 guest is to place a copy of it
    # beside a stand-in Config.ps1. That tail is small but load-bearing: it must
    # `return` the boolean (never `exit`) on the watchdog's path, because
    # Watchdog.ps1 tests `$stopResult -eq $false`, and `exit` makes the `&`
    # expression yield $null instead -- $null -eq $false is False, so the
    # re-arm/retry block would be skipped and an un-uploaded render would be
    # left for the CloudWatch idle alarm to erase.

    BeforeAll {
        $script:SandboxDir = Join-Path ([System.IO.Path]::GetTempPath()) ("topaz-stopseq-" + [guid]::NewGuid().ToString('N').Substring(0, 12))
        New-Item -ItemType Directory -Path $script:SandboxDir -Force | Out-Null

        Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\Stop-Sequence.ps1') `
            -Destination (Join-Path $script:SandboxDir 'Stop-Sequence.ps1') -Force

        # The stand-in Config.ps1. It defines ONLY the three functions the tail
        # reaches before returning, and the two scenarios it is driven with are
        # chosen so nothing else is ever called: 'refuse' hits the ephemeral
        # interlock (ephemeral output, no UploadTarget) and 'dryrun' falls
        # through to the DryRun guard with no upload, no gate and no SNS.
        $stubConfig = @'
function Get-TopazAutoStopConfig {
    [pscustomobject]@{
        OutputDir         = 'D:\Renders'
        OutputIsEphemeral = ($env:TOPAZ_TEST_STOP_MODE -eq 'refuse')
        UploadTarget      = ''
        RclonePath        = 'C:\fake\rclone.exe'
        RcloneConfigPath  = 'C:\fake\rclone.conf'
        LogDir            = 'C:\fake\logs'
        S3SyncTarget      = ''
        S3SyncTimeoutSec  = 900
        SnsTopicArn       = ''
        AwsCliTimeoutSec  = 60
        UploadTimeoutSec  = 14400
        StopStrategy      = 'Ec2ApiStop'
        StopVerifySec     = 1
        DryRun            = ($env:TOPAZ_TEST_STOP_MODE -eq 'dryrun')
    }
}

function Write-TopazLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][string]$Component,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    # Writes NOTHING to the output stream, exactly like the real one -- that
    # property is the reason the script's return value can be trusted at all.
    Add-Content -LiteralPath $env:TOPAZ_TEST_STOP_TRACE -Value "$Level|$Message"
}

function Get-Ec2Identity {
    [pscustomobject]@{ InstanceId = 'i-0abcdef0123456789'; Region = 'us-east-1' }
}
'@
        Set-Content -LiteralPath (Join-Path $script:SandboxDir 'Config.ps1') -Value $stubConfig -Encoding UTF8

        $script:SandboxStop = Join-Path $script:SandboxDir 'Stop-Sequence.ps1'
        $env:TOPAZ_TEST_STOP_TRACE = Join-Path $script:SandboxDir 'trace.log'
    }

    AfterAll {
        Remove-Item -LiteralPath $script:SandboxDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath 'Env:TOPAZ_TEST_STOP_TRACE' -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath 'Env:TOPAZ_TEST_STOP_MODE' -ErrorAction SilentlyContinue
    }

    Context "the watchdog's call: & Stop-Sequence.ps1 -Reason <x>" {

        BeforeEach { $env:TOPAZ_TEST_STOP_MODE = 'refuse' }

        It 'yields EXACTLY ONE object, $false, on the refusal path' {
            $captured = @(& $script:SandboxStop -Reason 'completed')

            $captured.Count | Should -Be 1
            $captured[0] | Should -BeOfType [bool]
            $captured[0] | Should -BeFalse
        }

        It 'sets no exit code, because the watchdog path must never `exit`' {
            $global:LASTEXITCODE = 0
            & $script:SandboxStop -Reason 'completed' | Out-Null
            $global:LASTEXITCODE | Should -Be 0
        }

        It 'yields $true, one object, when DryRun deliberately suppresses the stop' {
            $env:TOPAZ_TEST_STOP_MODE = 'dryrun'
            $captured = @(& $script:SandboxStop -Reason 'stalled')

            $captured.Count | Should -Be 1
            $captured[0] | Should -BeTrue
        }

        It 'defines its functions and does nothing at all when dot-sourced with -LibraryOnly' {
            # No config load, no IMDS, no stop.log line -- the seam these tests
            # rely on has to stay side-effect free.
            $captured = @(& $script:SandboxStop -Reason 'completed' -LibraryOnly)
            $captured.Count | Should -Be 0
        }
    }

    Context 'the scheduled-task call: -ExitCodeOnRefusal (Register-TimedStop.ps1 only)' {

        It 'exits 2 on a REFUSED stop, so Get-ScheduledTaskInfo stops reporting a refusal as success' {
            $env:TOPAZ_TEST_STOP_MODE = 'refuse'
            $global:LASTEXITCODE = 0

            $captured = @(& $script:SandboxStop -Reason 'completed' -ExitCodeOnRefusal)

            $global:LASTEXITCODE | Should -Be 2
            $captured.Count | Should -Be 0
        }

        It 'exits 0 when the stop was performed or deliberately suppressed' {
            $env:TOPAZ_TEST_STOP_MODE = 'dryrun'
            $global:LASTEXITCODE = 2

            & $script:SandboxStop -Reason 'stalled' -ExitCodeOnRefusal | Out-Null

            $global:LASTEXITCODE | Should -Be 0
        }
    }
}
