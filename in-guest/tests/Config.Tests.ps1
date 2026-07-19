<#
.SYNOPSIS
    Pester 5 unit tests for the pure decision functions Resolve-RenderActive
    and Test-TopazTempFile in in-guest/Config.ps1.

.DESCRIPTION
    Neither function under test does any I/O (no process/WMI/nvidia-smi/
    filesystem access), so dot-sourcing Config.ps1 to pull in their
    definitions is safe on any platform, including non-Windows pwsh:
    dot-sourcing only DEFINES the functions in this file, it does not execute
    any of the Windows-only cmdlets used elsewhere in the pipeline (those only
    run when explicitly invoked, which these tests never do).

    Run with:
        Invoke-Pester -Path in-guest/tests -CI
#>

BeforeAll {
    . "$PSScriptRoot/../Config.ps1"
}

Describe 'Resolve-RenderActive' {

    Context "Signal = 'WorkerOnly' (GPU is ignored entirely)" {

        It 'returns $true when WorkerActive is $true, regardless of GPU' {
            Resolve-RenderActive -WorkerActive $true -GpuUtil 90 -Signal 'WorkerOnly' -GpuBusyPercent 15 |
                Should -Be $true
        }

        It 'returns $false when WorkerActive is $false, even if GPU is busy' {
            Resolve-RenderActive -WorkerActive $false -GpuUtil 90 -Signal 'WorkerOnly' -GpuBusyPercent 15 |
                Should -Be $false
        }

        It 'returns $true when WorkerActive is $true and GpuUtil is $null' {
            Resolve-RenderActive -WorkerActive $true -GpuUtil $null -Signal 'WorkerOnly' -GpuBusyPercent 15 |
                Should -Be $true
        }

        It 'returns $false when WorkerActive is $false and GpuUtil is $null' {
            Resolve-RenderActive -WorkerActive $false -GpuUtil $null -Signal 'WorkerOnly' -GpuBusyPercent 15 |
                Should -Be $false
        }

        It 'returns $null when WorkerActive is $null, regardless of GPU' {
            Resolve-RenderActive -WorkerActive $null -GpuUtil 90 -Signal 'WorkerOnly' -GpuBusyPercent 15 |
                Should -Be $null
        }

        It 'returns $null when WorkerActive is $null and GpuUtil is also $null' {
            Resolve-RenderActive -WorkerActive $null -GpuUtil $null -Signal 'WorkerOnly' -GpuBusyPercent 15 |
                Should -Be $null
        }
    }

    Context "Signal = 'GpuOnly' (worker is ignored, unless GPU read failed)" {

        It 'returns $true when GpuUtil is above GpuBusyPercent' {
            Resolve-RenderActive -WorkerActive $false -GpuUtil 50 -Signal 'GpuOnly' -GpuBusyPercent 15 |
                Should -Be $true
        }

        It 'returns $false when GpuUtil is below GpuBusyPercent' {
            Resolve-RenderActive -WorkerActive $true -GpuUtil 5 -Signal 'GpuOnly' -GpuBusyPercent 15 |
                Should -Be $false
        }

        It 'returns $true when GpuUtil exactly equals GpuBusyPercent (boundary is inclusive)' {
            Resolve-RenderActive -WorkerActive $false -GpuUtil 15 -Signal 'GpuOnly' -GpuBusyPercent 15 |
                Should -Be $true
        }

        It 'falls back to $true (WorkerActive) when GpuUtil is $null and worker is active' {
            Resolve-RenderActive -WorkerActive $true -GpuUtil $null -Signal 'GpuOnly' -GpuBusyPercent 15 |
                Should -Be $true
        }

        It 'falls back to $false (WorkerActive) when GpuUtil is $null and worker is not active' {
            Resolve-RenderActive -WorkerActive $false -GpuUtil $null -Signal 'GpuOnly' -GpuBusyPercent 15 |
                Should -Be $false
        }

        It 'returns gpuActive (ignoring worker) when GpuUtil is readable and WorkerActive is $null' {
            Resolve-RenderActive -WorkerActive $null -GpuUtil 50 -Signal 'GpuOnly' -GpuBusyPercent 15 |
                Should -Be $true
        }

        It 'falls back to $null (WorkerActive) when GpuUtil is $null and WorkerActive is $null' {
            Resolve-RenderActive -WorkerActive $null -GpuUtil $null -Signal 'GpuOnly' -GpuBusyPercent 15 |
                Should -Be $null
        }
    }

    Context "Signal = 'WorkerOrGpu' (active if either signal is active)" {

        It 'returns $true when worker is inactive but GPU is busy' {
            Resolve-RenderActive -WorkerActive $false -GpuUtil 50 -Signal 'WorkerOrGpu' -GpuBusyPercent 15 |
                Should -Be $true
        }

        It 'returns $false when worker is inactive and GPU is idle' {
            Resolve-RenderActive -WorkerActive $false -GpuUtil 5 -Signal 'WorkerOrGpu' -GpuBusyPercent 15 |
                Should -Be $false
        }

        It 'returns $false when worker is inactive and GpuUtil is $null' {
            Resolve-RenderActive -WorkerActive $false -GpuUtil $null -Signal 'WorkerOrGpu' -GpuBusyPercent 15 |
                Should -Be $false
        }

        It 'returns $true when worker is active and GpuUtil is $null' {
            Resolve-RenderActive -WorkerActive $true -GpuUtil $null -Signal 'WorkerOrGpu' -GpuBusyPercent 15 |
                Should -Be $true
        }

        It 'returns $true when both worker is active and GPU is busy' {
            Resolve-RenderActive -WorkerActive $true -GpuUtil 90 -Signal 'WorkerOrGpu' -GpuBusyPercent 15 |
                Should -Be $true
        }

        It 'returns $true when GpuUtil exactly equals GpuBusyPercent, even with an inactive worker' {
            Resolve-RenderActive -WorkerActive $false -GpuUtil 15 -Signal 'WorkerOrGpu' -GpuBusyPercent 15 |
                Should -Be $true
        }

        It 'returns gpuActive ($true) when WorkerActive is $null and GPU is busy' {
            Resolve-RenderActive -WorkerActive $null -GpuUtil 50 -Signal 'WorkerOrGpu' -GpuBusyPercent 15 |
                Should -Be $true
        }

        It 'returns gpuActive ($false) when WorkerActive is $null and GPU is readable but idle' {
            Resolve-RenderActive -WorkerActive $null -GpuUtil 5 -Signal 'WorkerOrGpu' -GpuBusyPercent 15 |
                Should -Be $false
        }

        It 'returns $null when WorkerActive is $null and GpuUtil is also $null (both signals unreadable)' {
            Resolve-RenderActive -WorkerActive $null -GpuUtil $null -Signal 'WorkerOrGpu' -GpuBusyPercent 15 |
                Should -Be $null
        }
    }
}

Describe 'Test-TopazTempFile' {

    It "returns `$true for 'clip_temp.mp4' (marker followed by '.')" {
        Test-TopazTempFile -Name 'clip_temp.mp4' -TempMarker '_temp' | Should -Be $true
    }

    It "returns `$true for 'clip_temp_001.mov' (marker followed by '_')" {
        Test-TopazTempFile -Name 'clip_temp_001.mov' -TempMarker '_temp' | Should -Be $true
    }

    It "returns `$true for 'clip_temp' (marker at end of name)" {
        Test-TopazTempFile -Name 'clip_temp' -TempMarker '_temp' | Should -Be $true
    }

    It "returns `$true for 'my_TEMP.mp4' (case-insensitive match)" {
        Test-TopazTempFile -Name 'my_TEMP.mp4' -TempMarker '_temp' | Should -Be $true
    }

    It "returns `$false for 'Reel_Template_Final.mp4' (marker is a substring of a real word, not anchored)" {
        Test-TopazTempFile -Name 'Reel_Template_Final.mp4' -TempMarker '_temp' | Should -Be $false
    }

    It "returns `$false for 'temperature.mp4' (marker substring with no leading separator)" {
        Test-TopazTempFile -Name 'temperature.mp4' -TempMarker '_temp' | Should -Be $false
    }

    It "returns `$true for 'clip_temp.mp4' with the normal '_temp' marker (unchanged baseline behavior)" {
        Test-TopazTempFile -Name 'clip_temp.mp4' -TempMarker '_temp' | Should -Be $true
    }

    It 'returns $false for any name when TempMarker is an empty string (explicit no-op, not a binding error)' {
        Test-TopazTempFile -Name 'clip_temp.mp4' -TempMarker '' | Should -Be $false
        Test-TopazTempFile -Name 'Reel_Template_Final.mp4' -TempMarker '' | Should -Be $false
    }

    It 'returns $false for any name when TempMarker is whitespace-only (explicit no-op, not a binding error)' {
        Test-TopazTempFile -Name 'clip_temp.mp4' -TempMarker '   ' | Should -Be $false
        Test-TopazTempFile -Name 'anything.mp4' -TempMarker "`t" | Should -Be $false
    }
}

Describe 'Assert-ValidCompletionSignal' {

    It 'does not throw for WorkerOnly' {
        { Assert-ValidCompletionSignal -Signal 'WorkerOnly' } | Should -Not -Throw
    }

    It 'does not throw for GpuOnly' {
        { Assert-ValidCompletionSignal -Signal 'GpuOnly' } | Should -Not -Throw
    }

    It 'does not throw for WorkerOrGpu' {
        { Assert-ValidCompletionSignal -Signal 'WorkerOrGpu' } | Should -Not -Throw
    }

    It 'throws an actionable error naming the bad value for an invalid CompletionSignal' {
        { Assert-ValidCompletionSignal -Signal 'WorkerOny' } | Should -Throw '*WorkerOny*'
    }

    It 'names all three valid values in the error message' {
        { Assert-ValidCompletionSignal -Signal 'bogus' } |
            Should -Throw '*WorkerOnly*GpuOnly*WorkerOrGpu*'
    }
}

Describe 'Get-TopazAutoStopConfig' {

    It 'loads successfully with the default CompletionSignal (WorkerOnly)' {
        { Get-TopazAutoStopConfig } | Should -Not -Throw
        (Get-TopazAutoStopConfig).CompletionSignal | Should -Be 'WorkerOnly'
    }
}

Describe 'Convert-AzToRegion' {

    It "converts 'us-east-1a' -> 'us-east-1'" {
        Convert-AzToRegion -AvailabilityZone 'us-east-1a' | Should -Be 'us-east-1'
    }

    It "converts 'ap-southeast-2c' -> 'ap-southeast-2'" {
        Convert-AzToRegion -AvailabilityZone 'ap-southeast-2c' | Should -Be 'ap-southeast-2'
    }

    It "converts 'us-gov-west-1a' -> 'us-gov-west-1'" {
        Convert-AzToRegion -AvailabilityZone 'us-gov-west-1a' | Should -Be 'us-gov-west-1'
    }

    It "returns `$null for the Local Zone AZ 'us-west-2-lax-1a' (would otherwise strip to the invalid 'us-west-2-lax-1')" {
        Convert-AzToRegion -AvailabilityZone 'us-west-2-lax-1a' | Should -Be $null
    }

    It "returns `$null for a garbage string 'garbage'" {
        Convert-AzToRegion -AvailabilityZone 'garbage' | Should -Be $null
    }

    It 'returns $null for an empty string' {
        Convert-AzToRegion -AvailabilityZone '' | Should -Be $null
    }
}

Describe 'Build-AwsCliArgs' {

    # Assign to a variable before piping into Should -Be: piping a function
    # CALL directly into Should (vs. an already-assigned variable) binds
    # differently for a comma-protected array return (see Build-AwsCliArgs's
    # own comment on why the comma is there) and would otherwise make Should
    # see a 1-element collection wrapping the real array instead of the array
    # itself -- a Pester/pipeline binding quirk, not a Build-AwsCliArgs bug.

    It 'returns Base unchanged when Region is $null' {
        $base = @('s3', 'sync', 'D:\Exports', 's3://bucket/')
        $result = Build-AwsCliArgs -Base $base -Region $null
        $result | Should -Be $base
    }

    It "returns Base unchanged when Region is '' (empty string)" {
        $base = @('sns', 'publish')
        $result = Build-AwsCliArgs -Base $base -Region ''
        $result | Should -Be $base
    }

    It 'returns Base unchanged when Region is whitespace-only' {
        $base = @('sns', 'publish')
        $result = Build-AwsCliArgs -Base $base -Region '   '
        $result | Should -Be $base
    }

    It 'appends --region plus the value when a real region is given' {
        $base = @('s3', 'sync', 'D:\Exports', 's3://bucket/')
        $result = Build-AwsCliArgs -Base $base -Region 'us-east-1'
        $result | Should -Be @('s3', 'sync', 'D:\Exports', 's3://bucket/', '--region', 'us-east-1')
    }
}

Describe 'ConvertTo-TopazCliArgument' {

    # ConvertFrom-Win32CommandLine is a test-only reference parser implementing
    # the DOCUMENTED CommandLineToArgvW argv-parsing rules (the exact inverse
    # of what ConvertTo-TopazCliArgument encodes), so these tests can assert a
    # genuine round-trip through a known-correct parser instead of merely
    # matching a hand-computed expected string. Defined in a BeforeAll (not a
    # bare function statement at the Describe body's top level): Pester 5/6
    # run top-level Describe-body code during a separate Discovery pass, so a
    # function defined there is not reliably visible to code that runs later
    # during the Run phase (e.g. inside It blocks) -- BeforeAll's contents run
    # during Run and are visible to every It in this Describe.
    BeforeAll {
        function ConvertFrom-Win32CommandLine {
            param([Parameter(Mandatory)][AllowEmptyString()][string]$CommandLine)

            $argv      = New-Object System.Collections.Generic.List[string]
            $current   = New-Object System.Text.StringBuilder
            $inQuotes  = $false
            $started   = $false
            $i         = 0
            $len       = $CommandLine.Length

            while ($i -lt $len) {
                $ch = $CommandLine[$i]

                if ($ch -eq '\') {
                    $numBackslashes = 0
                    while ($i -lt $len -and $CommandLine[$i] -eq '\') {
                        $numBackslashes++
                        $i++
                    }
                    if ($i -lt $len -and $CommandLine[$i] -eq '"') {
                        [void]$current.Append('\' * [math]::Floor($numBackslashes / 2))
                        if ($numBackslashes % 2 -eq 1) {
                            [void]$current.Append('"')
                            $i++
                        }
                        else {
                            $inQuotes = -not $inQuotes
                            $i++
                        }
                    }
                    else {
                        [void]$current.Append('\' * $numBackslashes)
                    }
                    $started = $true
                    continue
                }

                if ($ch -eq '"') {
                    $inQuotes = -not $inQuotes
                    $started  = $true
                    $i++
                    continue
                }

                if ((-not $inQuotes) -and ($ch -match '\s')) {
                    if ($started) {
                        $argv.Add($current.ToString())
                        [void]$current.Clear()
                        $started = $false
                    }
                    $i++
                    continue
                }

                [void]$current.Append($ch)
                $started = $true
                $i++
            }

            if ($started) { $argv.Add($current.ToString()) }
            return , $argv.ToArray()
        }
    }

    It 'returns a plain argument with no whitespace or quote unchanged' {
        ConvertTo-TopazCliArgument -Value 's3' | Should -Be 's3'
    }

    It 'quotes an argument containing an embedded space' {
        ConvertTo-TopazCliArgument -Value 'C:\Users\x\My Renders' |
            Should -Be '"C:\Users\x\My Renders"'
    }

    It 'round-trips a value with BOTH an embedded space AND a trailing backslash (the OutputDir case)' {
        # This is the exact regression case: the OLD '"' -> '""' doubling
        # scheme let the trailing backslash merge with the closing quote and
        # swallow every subsequent CLI argument (S3 target, flags, --region).
        $value  = 'C:\Users\operator\My Renders\'
        $joined = 's3 sync ' + (ConvertTo-TopazCliArgument -Value $value) `
            + ' s3://my-bucket/renders/ --only-show-errors --region us-east-1'

        $argv = ConvertFrom-Win32CommandLine -CommandLine $joined

        $argv | Should -Be @('s3', 'sync', $value, 's3://my-bucket/renders/', '--only-show-errors', '--region', 'us-east-1')
    }

    It 'round-trips a value containing a literal embedded double quote' {
        $value   = 'He said "hello" to me'
        $escaped = ConvertTo-TopazCliArgument -Value $value
        $argv    = ConvertFrom-Win32CommandLine -CommandLine $escaped

        @($argv).Count | Should -Be 1
        $argv[0] | Should -Be $value
    }

    It 'round-trips a space-containing value ending in a MULTI-backslash run right before the closing quote' {
        # Regression coverage beyond the single-trailing-backslash OutputDir
        # case above: a run of 3 backslashes must be doubled to 6 (not just
        # incremented by one) when it sits directly before the quote this
        # function adds, per the 2N/2N+1 CommandLineToArgvW rule.
        $value  = 'spaced' + ' ' + ('\' * 3)
        $joined = 'prefix ' + (ConvertTo-TopazCliArgument -Value $value) + ' suffix'
        $argv   = ConvertFrom-Win32CommandLine -CommandLine $joined

        $argv | Should -Be @('prefix', $value, 'suffix')
    }
}

Describe 'Get-TopazStopNotification' {

    # 'DRY\s?RUN' (0-or-1 whitespace, case-insensitive like all -match/-Match)
    # matches BOTH the Subject's literal 'DRY RUN' and the Message's 'DryRun'
    # -- Stop-Sequence.ps1's own exact wording, which this function reproduces
    # verbatim, spells them slightly differently.
    Context 'DryRun $true' {
        It "Subject and Message both indicate DRY RUN and do not claim the instance is stopping" {
            $result = Get-TopazStopNotification -Reason 'completed' -InstanceId 'i-0123456789abcdef0' -DryRun $true
            $result.Subject  | Should -Match 'DRY\s?RUN'
            $result.Message  | Should -Match 'DRY\s?RUN'
            $result.Subject  | Should -Not -Match 'stopping'
            $result.Message  | Should -Not -Match 'powering off'
        }
    }

    Context 'DryRun $false' {
        It "Subject and Message say the instance is stopping and never indicate DRY RUN" {
            $result = Get-TopazStopNotification -Reason 'stalled' -InstanceId 'i-0123456789abcdef0' -DryRun $false
            $result.Subject  | Should -Match 'stopping'
            $result.Message  | Should -Match 'powering off'
            $result.Subject  | Should -Not -Match 'DRY\s?RUN'
            $result.Message  | Should -Not -Match 'DRY\s?RUN'
        }
    }
}
