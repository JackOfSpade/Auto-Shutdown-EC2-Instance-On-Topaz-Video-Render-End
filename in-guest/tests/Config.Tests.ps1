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

Describe 'Test-IsScratchDiskCandidate' {

    # WHAT THIS GUARDS. This predicate decides which disk gets FORMATTED at
    # every boot. A wrong $true destroys the operating system. It previously
    # lived inline in Initialize-ScratchDisk.ps1 with no test coverage at all.
    #
    # Every rejection below is a scenario that could plausibly occur on an EC2
    # Windows box, and each must fail CLOSED.

    BeforeAll {
        function Get-TestDisk {
            param(
                [string]$BusType = 'NVMe',
                $IsBoot = $false,
                $IsSystem = $false,
                [string]$SerialNumber = '4EDC_1323_0B3C_92CC',
                $Size = 450GB
            )
            [pscustomobject]@{
                BusType = $BusType; IsBoot = $IsBoot; IsSystem = $IsSystem
                SerialNumber = $SerialNumber; Size = $Size
            }
        }
        $script:MinB = [int64]300GB
        $script:MaxB = [int64]600GB
    }

    It 'ACCEPTS the real instance-store disk' {
        Test-IsScratchDiskCandidate -Disk (Get-TestDisk) -MinBytes $script:MinB -MaxBytes $script:MaxB -HasFormattedVolume $false |
            Should -BeTrue
    }

    It 'REJECTS the boot disk' {
        Test-IsScratchDiskCandidate -Disk (Get-TestDisk -IsBoot $true) -MinBytes $script:MinB -MaxBytes $script:MaxB -HasFormattedVolume $false |
            Should -BeFalse
    }

    It 'REJECTS the system disk' {
        Test-IsScratchDiskCandidate -Disk (Get-TestDisk -IsSystem $true) -MinBytes $script:MinB -MaxBytes $script:MaxB -HasFormattedVolume $false |
            Should -BeFalse
    }

    It 'REJECTS an EBS volume, identified by its vol-xxxx serial' {
        Test-IsScratchDiskCandidate -Disk (Get-TestDisk -SerialNumber 'vol0fa15d0249a65882a_00000001') -MinBytes $script:MinB -MaxBytes $script:MaxB -HasFormattedVolume $false |
            Should -BeFalse
    }

    It 'REJECTS a disk with a BLANK serial (unidentifiable provenance)' {
        # The trap this guards: '' -notmatch '^vol' is $TRUE, so a naive EBS
        # exclusion silently passes a disk whose origin cannot be established.
        foreach ($s in @('', '   ', $null)) {
            Test-IsScratchDiskCandidate -Disk (Get-TestDisk -SerialNumber $s) -MinBytes $script:MinB -MaxBytes $script:MaxB -HasFormattedVolume $false |
                Should -BeFalse
        }
    }

    It 'REJECTS a disk whose IsBoot/IsSystem could not be read ($null)' {
        # $null must not be read as "false, therefore safe".
        Test-IsScratchDiskCandidate -Disk (Get-TestDisk -IsBoot $null) -MinBytes $script:MinB -MaxBytes $script:MaxB -HasFormattedVolume $false |
            Should -BeFalse
        Test-IsScratchDiskCandidate -Disk (Get-TestDisk -IsSystem $null) -MinBytes $script:MinB -MaxBytes $script:MaxB -HasFormattedVolume $false |
            Should -BeFalse
    }

    It 'REJECTS disks outside the expected instance-store size range' {
        Test-IsScratchDiskCandidate -Disk (Get-TestDisk -Size 100GB) -MinBytes $script:MinB -MaxBytes $script:MaxB -HasFormattedVolume $false |
            Should -BeFalse
        Test-IsScratchDiskCandidate -Disk (Get-TestDisk -Size 900GB) -MinBytes $script:MinB -MaxBytes $script:MaxB -HasFormattedVolume $false |
            Should -BeFalse
    }

    It 'REJECTS any disk carrying a mountable filesystem, however it looks otherwise' {
        # The decisive data-safety condition: a formatted disk may hold data
        # somebody wants, so it is never a candidate for reformatting.
        Test-IsScratchDiskCandidate -Disk (Get-TestDisk) -MinBytes $script:MinB -MaxBytes $script:MaxB -HasFormattedVolume $true |
            Should -BeFalse
    }

    It 'REJECTS a non-NVMe disk' {
        Test-IsScratchDiskCandidate -Disk (Get-TestDisk -BusType 'SATA') -MinBytes $script:MinB -MaxBytes $script:MaxB -HasFormattedVolume $false |
            Should -BeFalse
    }

    It 'ACCEPTS a partially provisioned disk (PartitionStyle is deliberately not consulted)' {
        # A previous boot that initialized the disk but failed before formatting
        # leaves it GPT with no filesystem. Keying on PartitionStyle -eq 'RAW'
        # would exclude it forever and brick the scratch drive on every
        # subsequent boot. It is safe to reclaim precisely because it carries
        # no mountable volume.
        Test-IsScratchDiskCandidate -Disk (Get-TestDisk) -MinBytes $script:MinB -MaxBytes $script:MaxB -HasFormattedVolume $false |
            Should -BeTrue
    }
}

Describe 'Write-TopazLog output-stream hygiene' {

    # WHAT THIS GUARDS. Write-TopazLog used to emit INFO lines with
    # Write-Output. In PowerShell a function returns EVERYTHING written to the
    # output stream, so any function that logged and then returned a value
    # actually returned @('<log line>', $value) -- an array, not the value.
    #
    # That silently defeated the ephemeral-upload interlock in
    # Stop-Sequence.ps1. The guard there is:
    #
    #     if ($cfg.OutputIsEphemeral -and ($uploadOk -eq $false)) { <refuse to stop> }
    #
    # With a polluted return, `$uploadOk -eq $false` evaluates as an ARRAY
    # FILTER rather than a comparison: it yields @($false), which PowerShell
    # unwraps to $false in a boolean context, so the branch never fired. A
    # FAILED upload therefore read as success, and the instance would have
    # stopped -- erasing the instance-store scratch volume and permanently
    # destroying the render the upload had just failed to save.
    #
    # These tests fail if anyone routes Write-TopazLog back to the output
    # stream. Do not "fix" them by changing the assertions.

    It 'does not contaminate the return value of a function that logs then returns $false' {
        function Get-TestFalseAfterLog {
            Write-TopazLog -Component 'test' -Level 'INFO' -Message 'progress line'
            return $false
        }

        $result = Get-TestFalseAfterLog

        @($result).Count | Should -Be 1
        $result | Should -BeOfType [bool]
    }

    It 'keeps "-eq $false" working as a COMPARISON, which is what the interlock relies on' {
        function Get-TestFalseAfterLog2 {
            Write-TopazLog -Component 'test' -Level 'INFO' -Message 'progress line'
            return $false
        }

        $result = Get-TestFalseAfterLog2

        # Both spellings appear in the stop path; both must detect the failure.
        [bool]($result -eq $false) | Should -BeTrue
        [bool](-not $result)       | Should -BeTrue
    }

    It 'does not contaminate a $true return either' {
        function Get-TestTrueAfterLog {
            Write-TopazLog -Component 'test' -Level 'INFO' -Message 'progress line'
            Write-TopazLog -Component 'test' -Level 'INFO' -Message 'second line'
            return $true
        }

        $result = Get-TestTrueAfterLog

        @($result).Count | Should -Be 1
        $result | Should -BeOfType [bool]
        $result | Should -BeTrue
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
        # WorkerOnly is the default on THIS deployment for a measured reason
        # (see Config.ps1's own comment): Amazon DCV encodes the remote display
        # on the same GPU, running 14-49% with no render in progress. Under
        # 'WorkerOrGpu' that alone was enough to log
        # "Render active (worker=False gpu=21%)" and set SawActivity, which
        # defeats the guard that stops a queue being completed before any
        # render has begun -- i.e. it could power the box off under an operator
        # who was merely setting up over DCV.
        #
        # This assertion is deliberately pinned to the shipped value: if
        # someone flips the default back to a GPU-inclusive signal, they should
        # have to come here and justify it against that measurement.
        { Get-TopazAutoStopConfig } | Should -Not -Throw
        (Get-TopazAutoStopConfig).CompletionSignal | Should -Be 'WorkerOnly'
    }

    It 'loads successfully with the default StopStrategy (Auto)' {
        (Get-TopazAutoStopConfig).StopStrategy | Should -Be 'Auto'
    }

    It 'defaults WorkerNamesLike to the neuroserver.exe + ffmpeg.exe ARRAY (grandchild-aware ancestry match)' {
        # A single string ('ffmpeg.exe') cannot describe the real Topaz
        # process tree (GUI -> neuroserver.exe -> ffmpeg.exe) -- see
        # WorkerNamesLike's own comment in Config.ps1.
        (Get-TopazAutoStopConfig).WorkerNamesLike | Should -Be @('neuroserver.exe', 'ffmpeg.exe')
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

Describe 'Assert-ValidStopStrategy' {

    It 'does not throw for Ec2ApiStop' {
        { Assert-ValidStopStrategy -Strategy 'Ec2ApiStop' } | Should -Not -Throw
    }

    It 'does not throw for GuestShutdown' {
        { Assert-ValidStopStrategy -Strategy 'GuestShutdown' } | Should -Not -Throw
    }

    It 'does not throw for Auto' {
        { Assert-ValidStopStrategy -Strategy 'Auto' } | Should -Not -Throw
    }

    It 'throws an actionable error naming the bad value for a typo''d StopStrategy' {
        { Assert-ValidStopStrategy -Strategy 'Ec2ApiStp' } | Should -Throw '*Ec2ApiStp*'
    }

    It 'names all three valid values in the error message' {
        { Assert-ValidStopStrategy -Strategy 'bogus' } |
            Should -Throw '*Ec2ApiStop*GuestShutdown*Auto*'
    }
}

Describe 'Resolve-StopPlan' {
    # 'Auto' must try Ec2ApiStop FIRST: it is the only action that PROVABLY
    # ends billing. A guest shutdown ends billing only when
    # InstanceInitiatedShutdownBehavior happens to be 'stop' -- ordering the
    # cheap-but-unreliable action first would, on a box where that is not
    # true, either destroy the box (if it were 'terminate') or quietly keep
    # billing it forever. See Resolve-StopPlan's own comment in Config.ps1.

    It "returns exactly @('Ec2ApiStop', 'GuestShutdown') IN THAT ORDER for 'Auto'" {
        $result = Resolve-StopPlan -Strategy 'Auto'
        @($result).Count | Should -Be 2
        $result | Should -Be @('Ec2ApiStop', 'GuestShutdown')
    }

    # These single-strategy cases guard against PowerShell's own scalar
    # collapse: a function that `return`s a one-element array hands the
    # caller a bare STRING instead unless the return uses the leading unary
    # comma (see Resolve-StopPlan's own comment) -- Stop-Sequence.ps1's `foreach
    # ($action in $plan)` would still "work" against a bare string (iterating
    # its characters would not even throw), silently skipping the configured
    # stop action entirely. Asserting -is [array] here is what would catch a
    # regression that drops the comma.

    It "returns a single-element ARRAY (not a collapsed scalar) for 'Ec2ApiStop'" {
        $result = Resolve-StopPlan -Strategy 'Ec2ApiStop'
        $result -is [array] | Should -Be $true
        @($result).Count | Should -Be 1
        $result[0] | Should -Be 'Ec2ApiStop'
    }

    It "returns a single-element ARRAY (not a collapsed scalar) for 'GuestShutdown'" {
        $result = Resolve-StopPlan -Strategy 'GuestShutdown'
        $result -is [array] | Should -Be $true
        @($result).Count | Should -Be 1
        $result[0] | Should -Be 'GuestShutdown'
    }
}

Describe 'Build-WorkerWqlFilter' {

    It 'OR-joins multiple patterns into a single WQL filter fragment' {
        Build-WorkerWqlFilter -Patterns @('neuroserver.exe', 'ffmpeg.exe') |
            Should -Be "Name LIKE 'neuroserver.exe' OR Name LIKE 'ffmpeg.exe'"
    }

    It 'builds a filter with no OR for a single pattern' {
        Build-WorkerWqlFilter -Patterns @('neuroserver.exe') | Should -Be "Name LIKE 'neuroserver.exe'"
    }

    It "escapes an embedded single quote by DOUBLING it (WQL's own escaping rule)" {
        # Without this, a pattern containing an apostrophe would terminate the
        # WQL string literal early and produce a malformed query -- which
        # Get-CimInstance surfaces as a thrown exception, i.e. the worker
        # signal reads "unknown" on EVERY poll and the watchdog freezes
        # forever. See Build-WorkerWqlFilter's own comment in Config.ps1.
        Build-WorkerWqlFilter -Patterns @("weird'name.exe") | Should -Be "Name LIKE 'weird''name.exe'"
    }

    It 'drops whitespace-only entries but still builds a filter from the remaining usable patterns' {
        # Deliberately whitespace ('   ', a tab), not a literal '' -- a
        # genuinely EMPTY string element trips PowerShell's own Mandatory
        # parameter binding for -Patterns (a ParameterBindingValidationException
        # thrown before Build-WorkerWqlFilter's body ever runs, since the
        # parameter has no [AllowEmptyString()]), which is a DIFFERENT thing
        # from the whitespace-filtering this function's own body performs.
        Build-WorkerWqlFilter -Patterns @('ffmpeg.exe', '   ', "`t") | Should -Be "Name LIKE 'ffmpeg.exe'"
    }

    It 'throws when every supplied pattern is whitespace-only (an empty filter would match EVERY process on the box)' {
        { Build-WorkerWqlFilter -Patterns @('   ', "`t") } | Should -Throw '*no non-empty*'
    }

    It 'throws when Patterns is an empty array' {
        { Build-WorkerWqlFilter -Patterns @() } | Should -Throw '*no non-empty*'
    }
}
