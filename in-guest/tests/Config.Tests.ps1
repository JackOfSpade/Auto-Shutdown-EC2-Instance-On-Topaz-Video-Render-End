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

Describe 'Write-TopazLog timestamp contract' {

    # WHAT THIS GUARDS. These logs are the ONLY post-mortem available once the
    # box has powered itself off, and reconstructing a render cycle means
    # reading them alongside two other clocks: AWS API timestamps (UTC, ISO
    # 8601) and Topaz's own .tzlog (box-local, millisecond precision). Two
    # concrete failures motivated this contract:
    #
    #   1. Whole-second stamps lost ORDERING. A real completion logged three
    #      consecutive lines all stamped [2026-07-27 12:51:35], so the log
    #      could not say how long the output-unlock scan took, nor in which
    #      order the handoff steps ran.
    #   2. WARN and ERROR printed the BARE message to the console while the
    #      log file received a timestamped copy, so a console transcript of a
    #      live failure could not be aligned with the file it mirrored.
    #
    # A missing offset additionally forces the reader to ASSUME the box's time
    # zone before comparing anything against AWS.

    BeforeAll {
        # [yyyy-MM-dd HH:mm:ss.fff +NN:NN] [LEVEL] -- millisecond precision and
        # an explicit signed UTC offset are both required.
        #
        # Built by CONCATENATION, deliberately: the regex quantifiers here
        # ({4}, {2}, {3}) collide with PowerShell's -f format placeholders, so
        # "pattern -f 'INFO'" throws "Index (zero based) must be greater than
        # or equal to zero and less than the size of the argument list".
        $script:StampPrefix = '^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} [+-]\d{2}:\d{2}\] \['
        $script:StampSuffix = '\] '
    }

    It 'stamps INFO with millisecond precision and an explicit UTC offset' {
        $info = Write-TopazLog -Component 'test' -Level 'INFO' -Message 'stamp check' 6>&1
        "$info" | Should -Match ($script:StampPrefix + 'INFO' + $script:StampSuffix)
    }

    It 'stamps WARN on the CONSOLE, not just in the log file' {
        $warn = Write-TopazLog -Component 'test' -Level 'WARN' -Message 'stamp check' 3>&1
        "$warn" | Should -Match ($script:StampPrefix + 'WARN' + $script:StampSuffix)
    }

    It 'stamps ERROR on the CONSOLE, not just in the log file' {
        $err = & {
            # Write-TopazLog calls Write-Error without -ErrorAction; a caller
            # preference of 'Stop' would turn this into a throw rather than a
            # capturable record.
            $ErrorActionPreference = 'Continue'
            Write-TopazLog -Component 'test' -Level 'ERROR' -Message 'stamp check' 2>&1
        }
        "$err" | Should -Match ($script:StampPrefix + 'ERROR' + $script:StampSuffix)
    }

    It 'still keeps WARN and ERROR off the output stream despite now passing the full line' {
        # The timestamp fix routes $line (not $Message) into Write-Warning and
        # Write-Error. Neither writes to the output stream -- but if anyone
        # "simplifies" them to Write-Output/Write-Host, the return-value
        # contract guarded above breaks again, this time on the failure paths
        # where it matters most.
        function Get-TestFalseAfterWarn {
            Write-TopazLog -Component 'test' -Level 'WARN'  -Message 'w' 3>$null
            Write-TopazLog -Component 'test' -Level 'ERROR' -Message 'e' 2>$null
            return $false
        }

        $result = Get-TestFalseAfterWarn

        @($result).Count | Should -Be 1
        $result | Should -BeOfType [bool]
        [bool]($result -eq $false) | Should -BeTrue
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

    It 'exposes RenderActiveMetricName as a non-empty string, and defaults it to "RenderActive"' {
        # This is the metric name control-plane/03-create-idle-alarm.sh's
        # IDLE_SIGNAL='render' default alarms on (docs/15). Pinned the same
        # way CompletionSignal/WorkerNamesLike are pinned above: if someone
        # renames it here, the control-plane side goes stale silently unless
        # they come here and change this assertion too.
        $cfg = Get-TopazAutoStopConfig
        $cfg.RenderActiveMetricName | Should -BeOfType [string]
        [string]::IsNullOrWhiteSpace($cfg.RenderActiveMetricName) | Should -Be $false
        $cfg.RenderActiveMetricName | Should -Be 'RenderActive'
    }

    It 'still exposes MetricNamespace and MetricName as non-empty strings (unchanged by the new safety-net metric)' {
        # RenderActiveMetricName is published ALONGSIDE these, not instead of
        # them -- Push-GpuMetric.ps1 now publishes both signals independently.
        $cfg = Get-TopazAutoStopConfig
        [string]::IsNullOrWhiteSpace($cfg.MetricNamespace) | Should -Be $false
        [string]::IsNullOrWhiteSpace($cfg.MetricName) | Should -Be $false
        $cfg.MetricNamespace | Should -Be 'TopazRender/GPU'
        $cfg.MetricName | Should -Be 'GPUUtilization'
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

Describe 'Test-RenderWorkerPresent' {
    # Test-RenderWorkerPresent feeds the RenderActive metric Push-GpuMetric.ps1
    # publishes for the out-of-band CloudWatch idle alarm (docs/15) -- see its
    # own .DESCRIPTION in Config.ps1 for why it is a deliberately loose,
    # STATELESS worker check rather than a reuse of Watchdog.ps1's
    # ancestry-based Get-TopazWorkers.
    #
    # Get-CimInstance's CimCmdlets module is Windows-only and not present on
    # non-Windows pwsh (this whole file is dot-sourced cross-platform per its
    # own header), so it cannot be Pester-`Mock`ed directly here -- Mock
    # requires the target command to already resolve to something. A plain
    # function definition in this Describe's own BeforeAll stands in for it
    # instead, exactly the pattern Watchdog.Tests.ps1 uses for its own
    # 'Get-TopazWorkers (real end-to-end delegation...)' Describe block:
    # PowerShell resolves an unqualified command name against the Function:
    # scope before Cmdlet:, so Test-RenderWorkerPresent's real, unmodified body
    # picks it up with no change to Config.ps1 itself.

    BeforeAll {
        function Get-CimInstance {
            # Deliberately shadows the built-in cmdlet name -- see this
            # Describe block's own comment above for why. Windows PowerShell
            # 5.1 production code never defines this function (this file is
            # test-only), so there is no risk of this shadow leaking into the
            # real pipeline.
            [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '')]
            # [CmdletBinding()] makes -ErrorAction a common parameter PowerShell
            # supports automatically, without declaring it by hand and
            # tripping PSReviewUnusedParameter for never reading it --
            # Test-RenderWorkerPresent's real Get-CimInstance call passes
            # -ErrorAction Stop, and a shadow that does not accept it would
            # fail with ParameterBindingException instead of exercising the
            # code under test.
            [CmdletBinding()]
            param(
                [string]$ClassName,
                [string]$Filter,
                [string[]]$Property,
                [int]$OperationTimeoutSec
            )

            # Every declared parameter is genuinely read below (ClassName is
            # asserted, the rest are captured for tests that want to pin the
            # exact call contract) -- both because that contract is worth
            # pinning and because PSReviewUnusedParameter would otherwise flag
            # an advanced-function parameter that is only ever consulted via
            # $PSBoundParameters, which this shadow does not need to do.
            if ($ClassName -ne 'Win32_Process') {
                throw "Test shadow Get-CimInstance only supports ClassName 'Win32_Process' (got '$ClassName')."
            }

            $script:CimCallCount++
            $script:CimCapturedFilter               = $Filter
            $script:CimCapturedProperty              = $Property
            $script:CimCapturedOperationTimeoutSec   = $OperationTimeoutSec

            if ($script:CimShouldThrow) {
                throw 'Simulated Get-CimInstance failure (WMI/CIM provider unreachable).'
            }

            return $script:CimReturnValue
        }
    }

    BeforeEach {
        # Reset every test's fixture explicitly -- BeforeAll's function
        # definition is shared across all Its in this Describe (Pester 5 runs
        # container-body BeforeAll once), but the $script:-scoped fixture
        # variables it reads must not leak assertions between Its.
        $script:CimShouldThrow                 = $false
        $script:CimReturnValue                 = @()
        $script:CimCapturedFilter              = $null
        $script:CimCapturedProperty            = $null
        $script:CimCapturedOperationTimeoutSec = $null
        $script:CimCallCount                   = 0
    }

    Context 'CIM query succeeds' {

        It 'returns $true when the CIM query yields one matching process' {
            $script:CimReturnValue = @([pscustomobject]@{ ProcessId = 111 })
            Test-RenderWorkerPresent -WorkerNamesLike @('neuroserver.exe', 'ffmpeg.exe') |
                Should -Be $true
        }

        It 'returns $true when the CIM query yields several matching processes' {
            $script:CimReturnValue = @(
                [pscustomobject]@{ ProcessId = 111 },
                [pscustomobject]@{ ProcessId = 222 },
                [pscustomobject]@{ ProcessId = 333 }
            )
            Test-RenderWorkerPresent -WorkerNamesLike @('neuroserver.exe', 'ffmpeg.exe') |
                Should -Be $true
        }

        It 'returns $false when the CIM query yields an empty collection (query worked, nothing running)' {
            $script:CimReturnValue = @()
            Test-RenderWorkerPresent -WorkerNamesLike @('neuroserver.exe', 'ffmpeg.exe') |
                Should -Be $false
        }
    }

    Context 'CIM query fails' {

        It 'returns $null when Get-CimInstance throws (the query-failed contract, distinct from $false)' {
            # Callers (Push-GpuMetric.ps1) must publish NOTHING on $null rather
            # than coercing it to 0 -- see Test-RenderWorkerPresent's own
            # .OUTPUTS. Conflating "query failed" with "confirmed idle" here
            # would let an unreadable poll count as an idle minute toward the
            # alarm's breach window.
            $script:CimShouldThrow = $true
            Test-RenderWorkerPresent -WorkerNamesLike @('neuroserver.exe', 'ffmpeg.exe') |
                Should -Be $null
        }
    }

    Context 'WorkerNamesLike is empty or whitespace-only (Build-WorkerWqlFilter itself throws)' {
        # THE TRAP THIS GUARDS. An empty filter would match EVERY process on
        # the box, so Build-WorkerWqlFilter refuses to build one and throws
        # instead (see its own tests above). Test-RenderWorkerPresent's catch
        # block must turn that into $null, exactly like a CIM failure -- NOT
        # $true, which would report a permanently active render and pin the
        # idle alarm "OK" forever regardless of what is actually running.

        It 'returns $null (never $true) when WorkerNamesLike is an empty array, and never even calls Get-CimInstance' {
            Test-RenderWorkerPresent -WorkerNamesLike @() | Should -Be $null
            $script:CimCallCount | Should -Be 0
        }

        It 'returns $null (never $true) when WorkerNamesLike is whitespace-only, and never even calls Get-CimInstance' {
            Test-RenderWorkerPresent -WorkerNamesLike @('   ', "`t") | Should -Be $null
            $script:CimCallCount | Should -Be 0
        }
    }

    Context 'the WQL filter really is name-matching and really is OR-joined' {

        It 'hands Get-CimInstance exactly the fragment Build-WorkerWqlFilter produces for the same patterns' {
            $patterns = @('neuroserver.exe', 'ffmpeg.exe')
            $script:CimReturnValue = @()

            [void] (Test-RenderWorkerPresent -WorkerNamesLike $patterns)

            $script:CimCapturedFilter | Should -Be (Build-WorkerWqlFilter -Patterns $patterns)
            $script:CimCapturedFilter | Should -Be "Name LIKE 'neuroserver.exe' OR Name LIKE 'ffmpeg.exe'"
        }

        It 'queries Win32_Process narrowed to ProcessId and bounds the call with -OperationTimeoutSec (the shadow throws on any other ClassName)' {
            $script:CimReturnValue = @()

            [void] (Test-RenderWorkerPresent -WorkerNamesLike @('neuroserver.exe'))

            # ClassName='Win32_Process' is asserted inside the shadow itself
            # (it throws otherwise) -- the call reaching this point at all is
            # part of that assertion. Property/OperationTimeoutSec are pinned
            # here so the real call never silently drifts from a bounded,
            # narrow query into an unbounded one that could hang the metric
            # task on a wedged CIM provider.
            $script:CimCapturedProperty            | Should -Be @('ProcessId')
            $script:CimCapturedOperationTimeoutSec | Should -Be 30
        }
    }

    Context 'statelessness (the property that motivated writing this function instead of reusing Get-TopazWorkers)' {
        # Get-TopazWorkers accumulates a $script:KnownWorkers table across
        # polls inside one long-lived watchdog process. Push-GpuMetric.ps1 is
        # relaunched by the scheduler EVERY MINUTE, so that table would always
        # start empty -- Test-RenderWorkerPresent exists precisely because it
        # carries NO memory of any previous call. These tests assert that
        # directly, independent of Get-CimInstance's own canned answer.

        It 'returns the SAME answer on two consecutive independent calls given the SAME mocked inputs' {
            $script:CimReturnValue = @([pscustomobject]@{ ProcessId = 111 })

            Test-RenderWorkerPresent -WorkerNamesLike @('neuroserver.exe') | Should -Be $true
            Test-RenderWorkerPresent -WorkerNamesLike @('neuroserver.exe') | Should -Be $true
        }

        It 'reflects a CHANGED mocked answer on the very next call -- nothing from the prior call is cached or carried forward' {
            $script:CimReturnValue = @([pscustomobject]@{ ProcessId = 111 })
            Test-RenderWorkerPresent -WorkerNamesLike @('neuroserver.exe') | Should -Be $true

            # Flip the underlying CIM answer between the two calls. A stateful
            # implementation (or one that accidentally memoized) would keep
            # returning $true here; this function must not.
            $script:CimReturnValue = @()
            Test-RenderWorkerPresent -WorkerNamesLike @('neuroserver.exe') | Should -Be $false
        }
    }
}

Describe 'Get-TopazAutoStopConfig (misplaced-output anomaly + upload-retry + incremental-upload config)' {
    # These knobs back the 2026-07-28 render-loss-incident fix and its two
    # same-day corrections (CORRECTION 1: scan runs regardless of OutputDir's
    # own contents; CORRECTION 3: upload each render as it finishes).
    # Sanity-checked the same way pre-existing config values are above: type,
    # non-emptiness, and (where the code has a hard assumption baked in) the
    # shipped value itself.

    BeforeAll {
        $script:cfg = Get-TopazAutoStopConfig
    }

    It 'RenderFileExtensions is a non-empty array, and every entry starts with a dot' {
        # Find-RenderRecoveryCandidates builds its extension set via
        # $e.ToLowerInvariant() as a hashtable key compared against
        # $entry.Extension (which .NET always returns WITH the leading dot,
        # e.g. '.mov') -- an entry missing the dot would never match anything,
        # silently turning the recovery scan into a no-op.
        $script:cfg.RenderFileExtensions | Should -Not -BeNullOrEmpty
        @($script:cfg.RenderFileExtensions).Count | Should -BeGreaterThan 0
        foreach ($ext in $script:cfg.RenderFileExtensions) {
            $ext | Should -BeOfType [string]
            $ext.Substring(0, 1) | Should -Be '.'
        }
    }

    It 'defaults RenderFileExtensions to the five known Topaz deliverable extensions' {
        $script:cfg.RenderFileExtensions | Should -Be @('.mov', '.mp4', '.mkv', '.avi', '.mxf')
    }

    It 'TopazLogsBasePath is a non-empty string' {
        $script:cfg.TopazLogsBasePath | Should -BeOfType [string]
        [string]::IsNullOrWhiteSpace($script:cfg.TopazLogsBasePath) | Should -Be $false
    }

    It 'RecoveryScanMaxFiles / RecoveryScanMaxDepth / RecoveryScanTimeoutSec are positive integers' {
        $script:cfg.RecoveryScanMaxFiles | Should -BeOfType [int]
        $script:cfg.RecoveryScanMaxFiles | Should -BeGreaterThan 0
        $script:cfg.RecoveryScanMaxDepth | Should -BeOfType [int]
        $script:cfg.RecoveryScanMaxDepth | Should -BeGreaterThan 0
        $script:cfg.RecoveryScanTimeoutSec | Should -BeOfType [int]
        $script:cfg.RecoveryScanTimeoutSec | Should -BeGreaterThan 0
    }

    It 'RecoveryMaxAgeMin is a positive integer (the recency bound Invoke-TopazOutputAnomalyHandling turns into -ModifiedAfter)' {
        $script:cfg.RecoveryMaxAgeMin | Should -BeOfType [int]
        $script:cfg.RecoveryMaxAgeMin | Should -BeGreaterThan 0
    }

    It 'TopazForensicMaxLines / TopazForensicTimeoutSec are positive integers' {
        $script:cfg.TopazForensicMaxLines | Should -BeOfType [int]
        $script:cfg.TopazForensicMaxLines | Should -BeGreaterThan 0
        $script:cfg.TopazForensicTimeoutSec | Should -BeOfType [int]
        $script:cfg.TopazForensicTimeoutSec | Should -BeGreaterThan 0
    }

    It 'UploadRetryDelaySec is a positive integer within the documented "a few seconds up to ~30s" bound' {
        # Config.ps1's own comment on UploadRetryDelaySec scopes it explicitly
        # to that range; pin both the type/positivity AND the upper bound so a
        # future edit cannot quietly turn a "short, bounded delay" into
        # something that meaningfully slows down every failed stop.
        $script:cfg.UploadRetryDelaySec | Should -BeOfType [int]
        $script:cfg.UploadRetryDelaySec | Should -BeGreaterThan 0
        $script:cfg.UploadRetryDelaySec | Should -BeLessOrEqual 30
        $script:cfg.UploadRetryDelaySec | Should -Be 15
    }

    It 'UploadStableSec is a positive integer (CORRECTION 3''s "unlocked + size-stable for N seconds" bound)' {
        $script:cfg.UploadStableSec | Should -BeOfType [int]
        $script:cfg.UploadStableSec | Should -BeGreaterThan 0
    }

    It 'UploadWhenReady is a boolean feature switch, defaulting to $true' {
        $script:cfg.UploadWhenReady | Should -BeOfType [bool]
        $script:cfg.UploadWhenReady | Should -Be $true
    }
}

Describe 'Resolve-UploadRetryDecision' {
    # Pure: (AttemptNumber, MaxAttempts, Succeeded) -> [bool] "try again?".
    # GENERIC helper (MaxAttempts is a parameter, not hardcoded to 2) -- the
    # production pin of "2 total attempts" lives at the CALL SITES inside
    # Invoke-TopazRenderUpload / Invoke-TopazRecoveryUpload / Invoke-TopazIncrementalUpload,
    # and is pinned separately below via call-count assertions on the real
    # retry loops, since this function alone cannot prove nobody raised the
    # literal `2` at a call site.

    Context 'success never retries, regardless of attempt number or cap' {
        It 'returns $false when attempt 1 of 2 succeeded' {
            Resolve-UploadRetryDecision -AttemptNumber 1 -MaxAttempts 2 -Succeeded $true | Should -Be $false
        }
        It 'returns $false when attempt 2 of 2 succeeded' {
            Resolve-UploadRetryDecision -AttemptNumber 2 -MaxAttempts 2 -Succeeded $true | Should -Be $false
        }
        It 'returns $false on a first-attempt success even against a much larger MaxAttempts' {
            Resolve-UploadRetryDecision -AttemptNumber 1 -MaxAttempts 10 -Succeeded $true | Should -Be $false
        }
    }

    Context 'failure retries only while attempts remain -- THE EXACT PRODUCTION BOUNDARY (MaxAttempts=2)' {
        It 'attempt 1 of 2 failed -> retry allowed ($true)' {
            Resolve-UploadRetryDecision -AttemptNumber 1 -MaxAttempts 2 -Succeeded $false | Should -Be $true
        }
        It 'attempt 2 of 2 failed -> NO further retry ($false) -- the cap is reached, not "more than one more"' {
            Resolve-UploadRetryDecision -AttemptNumber 2 -MaxAttempts 2 -Succeeded $false | Should -Be $false
        }
    }

    Context 'the helper is generic in MaxAttempts (proves the "2" is a caller choice, not baked into this function)' {
        It 'attempt 2 of 3 failed -> still retries (2 < 3)' {
            Resolve-UploadRetryDecision -AttemptNumber 2 -MaxAttempts 3 -Succeeded $false | Should -Be $true
        }
        It 'attempt 3 of 3 failed -> cap reached, no retry' {
            Resolve-UploadRetryDecision -AttemptNumber 3 -MaxAttempts 3 -Succeeded $false | Should -Be $false
        }
        It 'attempt 1 of 1 failed -> no retry (a MaxAttempts of 1 means no retry ever)' {
            Resolve-UploadRetryDecision -AttemptNumber 1 -MaxAttempts 1 -Succeeded $false | Should -Be $false
        }
    }
}

Describe 'Resolve-OutputAnomalyClass' {
    # Pure: (Reason, OutputDirHasFiles, CandidatesFound) -> 'NotApplicable' |
    # 'ErrorClassA' | 'ErrorClassB' | 'Normal'. Renamed (2026-07-28,
    # CORRECTION 1) from Resolve-EmptyOutputDirDecision, and gained a THIRD
    # input (OutputDirHasFiles) plus a fourth output ('Normal') -- OutputDir's
    # own emptiness is no longer what decides whether the scan runs, only one
    # of two now-independent facts the classification considers. This function
    # only LABELS the situation -- it never decides whether to stop. The
    # "must never refuse" guarantee is asserted at the
    # Invoke-TopazOutputAnomalyHandling level below.

    Context "Reason = 'completed', candidate FOUND -> ErrorClassA, regardless of OutputDirHasFiles" {
        It 'ErrorClassA when OutputDir is ALSO empty' {
            Resolve-OutputAnomalyClass -Reason 'completed' -OutputDirHasFiles $false -CandidatesFound $true | Should -Be 'ErrorClassA'
        }
        It 'ErrorClassA even when OutputDir already HAS its own correctly-placed file(s) -- the live counter-example this correction exists for (a misplaced SECOND deliverable behind a correct FIRST one)' {
            Resolve-OutputAnomalyClass -Reason 'completed' -OutputDirHasFiles $true -CandidatesFound $true | Should -Be 'ErrorClassA'
        }
    }

    Context "Reason = 'completed', NO candidate found -> depends entirely on OutputDirHasFiles" {
        It 'ErrorClassB when OutputDir is ALSO empty (the original 2026-07-28 incident shape)' {
            Resolve-OutputAnomalyClass -Reason 'completed' -OutputDirHasFiles $false -CandidatesFound $false | Should -Be 'ErrorClassB'
        }
        It "'Normal' when OutputDir has its own file(s) and nothing anomalous was found elsewhere -- the ordinary healthy case" {
            Resolve-OutputAnomalyClass -Reason 'completed' -OutputDirHasFiles $true -CandidatesFound $false | Should -Be 'Normal'
        }
    }

    Context "Reason = 'stalled' / 'maxlifetime' -> always 'NotApplicable', regardless of the other two inputs" {
        It 'stalled + OutputDirHasFiles=$false + CandidatesFound=$true' {
            Resolve-OutputAnomalyClass -Reason 'stalled' -OutputDirHasFiles $false -CandidatesFound $true | Should -Be 'NotApplicable'
        }
        It 'stalled + OutputDirHasFiles=$true + CandidatesFound=$false' {
            Resolve-OutputAnomalyClass -Reason 'stalled' -OutputDirHasFiles $true -CandidatesFound $false | Should -Be 'NotApplicable'
        }
        It 'maxlifetime + any combination' {
            Resolve-OutputAnomalyClass -Reason 'maxlifetime' -OutputDirHasFiles $true -CandidatesFound $true | Should -Be 'NotApplicable'
            Resolve-OutputAnomalyClass -Reason 'maxlifetime' -OutputDirHasFiles $false -CandidatesFound $false | Should -Be 'NotApplicable'
        }
    }

    Context 'unexpected/odd Reason values are rejected outright by the parameter contract' {
        It "throws for an unrecognised Reason ('bogus')" {
            { Resolve-OutputAnomalyClass -Reason 'bogus' -OutputDirHasFiles $false -CandidatesFound $false } | Should -Throw
        }
        It 'throws for an empty-string Reason' {
            { Resolve-OutputAnomalyClass -Reason '' -OutputDirHasFiles $false -CandidatesFound $false } | Should -Throw
        }
    }

    Context 'full input-space sweep: every combination of 3 Reason values x 2 OutputDirHasFiles x 2 CandidatesFound (12 combinations)' {
        It 'only ever returns one of the four known labels -- never $null, never a fifth value' {
            $knownLabels = @('NotApplicable', 'ErrorClassA', 'ErrorClassB', 'Normal')
            foreach ($reason in @('completed', 'stalled', 'maxlifetime')) {
                foreach ($outputDirHasFiles in @($true, $false)) {
                    foreach ($candidatesFound in @($true, $false)) {
                        $result = Resolve-OutputAnomalyClass -Reason $reason -OutputDirHasFiles $outputDirHasFiles -CandidatesFound $candidatesFound
                        $knownLabels | Should -Contain $result
                    }
                }
            }
        }

        It 'ErrorClassA, ErrorClassB, Normal and NotApplicable are four MUTUALLY DISTINCT labels' {
            $a  = Resolve-OutputAnomalyClass -Reason 'completed' -OutputDirHasFiles $false -CandidatesFound $true
            $b  = Resolve-OutputAnomalyClass -Reason 'completed' -OutputDirHasFiles $false -CandidatesFound $false
            $n  = Resolve-OutputAnomalyClass -Reason 'completed' -OutputDirHasFiles $true  -CandidatesFound $false
            $na = Resolve-OutputAnomalyClass -Reason 'stalled'   -OutputDirHasFiles $false -CandidatesFound $false
            ($a, $b, $n, $na) | Select-Object -Unique | Should -HaveCount 4
        }

        It 'CandidatesFound=$true NEVER yields ErrorClassB (Class A and Class B are mutually exclusive by construction)' {
            foreach ($outputDirHasFiles in @($true, $false)) {
                Resolve-OutputAnomalyClass -Reason 'completed' -OutputDirHasFiles $outputDirHasFiles -CandidatesFound $true |
                    Should -Not -Be 'ErrorClassB'
            }
        }

        It 'none of the four labels is (or contains) a refusal-shaped value such as $false, "Refuse", or "REFUSE"' {
            foreach ($reason in @('completed', 'stalled', 'maxlifetime')) {
                foreach ($outputDirHasFiles in @($true, $false)) {
                    foreach ($candidatesFound in @($true, $false)) {
                        $result = Resolve-OutputAnomalyClass -Reason $reason -OutputDirHasFiles $outputDirHasFiles -CandidatesFound $candidatesFound
                        $result | Should -Not -Match '(?i)refuse'
                        $result | Should -Not -BeOfType [bool]
                    }
                }
            }
        }
    }
}

Describe 'Find-RenderRecoveryCandidates' {
    # I/O-bound (Get-ChildItem/Test-Path/Test-FileUnlocked against the
    # OutputDir volume), so not pure, but fully MOCKABLE. Two real gotchas
    # found while writing these tests, worth recording here:
    #
    #   1. Get-ChildItem's real -LiteralPath parameter is typed [string[]], so
    #      Pester's generated proxy binds even a single-string call as a
    #      1-ELEMENT ARRAY -- a mock that uses $LiteralPath directly as a
    #      hashtable key never matches (silently, since the per-directory
    #      failure is swallowed by the function's own inner try/catch). Every
    #      mock below flattens it via "$LiteralPath" first.
    #   2. Test-FileUnlocked defaults to $true here (mocked) so existing
    #      exclusion/depth/recency tests do not have to additionally reason
    #      about lock state; the SkippedInProgress Context below overrides it
    #      per-file to test that bucket specifically.
    #
    # NOT tested via a real filesystem (subst'd drive, temp directory, etc.):
    # the function scans from [System.IO.Path]::GetPathRoot($OutputDir) --
    # the WHOLE volume root -- which on this repo's actual CI runner
    # (ubuntu-latest) is the entire "/" filesystem. Mocking is the only
    # reasonably testable approach here.

    BeforeEach {
        Mock Test-Path { $true }
        Mock Test-FileUnlocked { $true }
    }

    Context 'exclusion of OutputDir itself, "System Volume Information", and "$RECYCLE.BIN"' {

        It 'never even queries the excluded directories, and finds only the one real candidate' {
            $tree = @{
                'D:\' = @(
                    [pscustomobject]@{ PSIsContainer = $true;  FullName = 'D:\Renders' },
                    [pscustomobject]@{ PSIsContainer = $true;  FullName = 'D:\System Volume Information' },
                    [pscustomobject]@{ PSIsContainer = $true;  FullName = 'D:\$RECYCLE.BIN' },
                    [pscustomobject]@{ PSIsContainer = $false; FullName = 'D:\SDR_Render_video3_slp.mov'; Extension = '.mov'; LastWriteTime = (Get-Date) },
                    [pscustomobject]@{ PSIsContainer = $false; FullName = 'D:\notes.txt'; Extension = '.txt'; LastWriteTime = (Get-Date) }
                )
            }
            Mock Get-ChildItem {
                $key = "$LiteralPath"
                if ($tree.ContainsKey($key)) { return $tree[$key] }
                throw "Find-RenderRecoveryCandidates queried an excluded (or otherwise unexpected) path: '$key'"
            }

            $result = Find-RenderRecoveryCandidates -OutputDir 'D:\Renders' -Extensions @('.mov') `
                -ModifiedAfter (Get-Date).AddDays(-1) -MaxFiles 200 -MaxDepth 4 -MaxSeconds 60

            $result.ScanFailed | Should -Be $false
            $result.Truncated  | Should -Be $false
            $result.Candidates.Count | Should -Be 1
            $result.Candidates[0].FullName | Should -Be 'D:\SDR_Render_video3_slp.mov'
            Should -Invoke Get-ChildItem -Times 1 -Exactly
        }
    }

    Context 'MaxDepth bounds how far below the volume root the walk descends' {

        BeforeEach {
            $script:DepthTree = @{
                'D:\' = @(
                    [pscustomobject]@{ PSIsContainer = $true;  FullName = 'D:\Sub' },
                    [pscustomobject]@{ PSIsContainer = $false; FullName = 'D:\root.mov'; Extension = '.mov'; LastWriteTime = (Get-Date) }
                )
                'D:\Sub' = @(
                    [pscustomobject]@{ PSIsContainer = $true;  FullName = 'D:\Sub\Deeper' },
                    [pscustomobject]@{ PSIsContainer = $false; FullName = 'D:\Sub\depth1.mkv'; Extension = '.mkv'; LastWriteTime = (Get-Date) }
                )
                'D:\Sub\Deeper' = @(
                    [pscustomobject]@{ PSIsContainer = $false; FullName = 'D:\Sub\Deeper\depth2.mov'; Extension = '.mov'; LastWriteTime = (Get-Date) }
                )
            }
            Mock Get-ChildItem {
                $key = "$LiteralPath"
                if ($script:DepthTree.ContainsKey($key)) { return $script:DepthTree[$key] }
                return @()
            }
        }

        It 'MaxDepth=1 finds root and depth-1 files but never descends into depth 2' {
            $result = Find-RenderRecoveryCandidates -OutputDir 'D:\Renders' -Extensions @('.mov', '.mkv') `
                -ModifiedAfter (Get-Date).AddDays(-1) -MaxFiles 200 -MaxDepth 1 -MaxSeconds 60
            # Set comparison (not exact order): -Sort-Object's ordinal-vs-culture
            # comparison of these two specific paths is not the point of this
            # test and is fragile to depend on -- what matters is WHICH files
            # were found.
            $result.Candidates.Count | Should -Be 2
            $result.Candidates.FullName | Should -Contain 'D:\root.mov'
            $result.Candidates.FullName | Should -Contain 'D:\Sub\depth1.mkv'
            $result.Candidates.FullName | Should -Not -Contain 'D:\Sub\Deeper\depth2.mov'
        }

        It 'MaxDepth=2 also reaches the depth-2 file' {
            $result = Find-RenderRecoveryCandidates -OutputDir 'D:\Renders' -Extensions @('.mov', '.mkv') `
                -ModifiedAfter (Get-Date).AddDays(-1) -MaxFiles 200 -MaxDepth 2 -MaxSeconds 60
            $result.Candidates.Count | Should -Be 3
            $result.Candidates.FullName | Should -Contain 'D:\root.mov'
            $result.Candidates.FullName | Should -Contain 'D:\Sub\depth1.mkv'
            $result.Candidates.FullName | Should -Contain 'D:\Sub\Deeper\depth2.mov'
        }
    }

    Context 'recency filtering (ModifiedAfter / ExcludedByAge)' {

        It 'a file NEWER than ModifiedAfter is a Candidate; an OLDER file with the same matching extension is ExcludedByAge, not a Candidate' {
            $tree = @{
                'D:\' = @(
                    [pscustomobject]@{ PSIsContainer = $false; FullName = 'D:\just_finished.mov'; Extension = '.mov'; LastWriteTime = (Get-Date) },
                    [pscustomobject]@{ PSIsContainer = $false; FullName = 'D:\SDR_Render_video3.mov'; Extension = '.mov'; LastWriteTime = (Get-Date).AddHours(-3) }
                )
            }
            Mock Get-ChildItem {
                $key = "$LiteralPath"
                if ($tree.ContainsKey($key)) { return $tree[$key] }
                return @()
            }

            $result = Find-RenderRecoveryCandidates -OutputDir 'D:\Renders' -Extensions @('.mov') `
                -ModifiedAfter (Get-Date).AddMinutes(-60) -MaxFiles 200 -MaxDepth 4 -MaxSeconds 60

            $result.Candidates.Count | Should -Be 1
            $result.Candidates[0].FullName | Should -Be 'D:\just_finished.mov'
            $result.ExcludedByAge.Count | Should -Be 1
            $result.ExcludedByAge[0].FullName | Should -Be 'D:\SDR_Render_video3.mov'
        }

        It 'a file with LastWriteTime EXACTLY equal to ModifiedAfter counts as a Candidate (the boundary is inclusive, -ge not -gt)' {
            $cutoff = Get-Date
            $tree = @{
                'D:\' = @(
                    [pscustomobject]@{ PSIsContainer = $false; FullName = 'D:\edge.mov'; Extension = '.mov'; LastWriteTime = $cutoff }
                )
            }
            Mock Get-ChildItem {
                $key = "$LiteralPath"
                if ($tree.ContainsKey($key)) { return $tree[$key] }
                return @()
            }
            $result = Find-RenderRecoveryCandidates -OutputDir 'D:\Renders' -Extensions @('.mov') `
                -ModifiedAfter $cutoff -MaxFiles 200 -MaxDepth 4 -MaxSeconds 60
            $result.Candidates.Count | Should -Be 1
            $result.ExcludedByAge.Count | Should -Be 0
        }
    }

    Context 'lock-state filtering (SkippedInProgress) -- CORRECTION 2: a live, still-writing intermediate must never count as a recovery Candidate' {

        It 'a recent, extension-matching file that is still LOCKED goes to SkippedInProgress, not Candidates -- and never decides the error class' {
            $tree = @{
                'D:\' = @(
                    [pscustomobject]@{ PSIsContainer = $false; FullName = 'D:\SDR_Render_video3_227249191.mov'; Extension = '.mov'; LastWriteTime = (Get-Date) },
                    [pscustomobject]@{ PSIsContainer = $false; FullName = 'D:\finished.mov'; Extension = '.mov'; LastWriteTime = (Get-Date) }
                )
            }
            Mock Get-ChildItem {
                $key = "$LiteralPath"
                if ($tree.ContainsKey($key)) { return $tree[$key] }
                return @()
            }
            # The live intermediate is LOCKED; the finished deliverable is not.
            Mock Test-FileUnlocked {
                param($Path)
                return ($Path -ne 'D:\SDR_Render_video3_227249191.mov')
            }

            $result = Find-RenderRecoveryCandidates -OutputDir 'D:\Renders' -Extensions @('.mov') `
                -ModifiedAfter (Get-Date).AddDays(-1) -MaxFiles 200 -MaxDepth 4 -MaxSeconds 60

            $result.Candidates.Count | Should -Be 1
            $result.Candidates[0].FullName | Should -Be 'D:\finished.mov'
            $result.SkippedInProgress.Count | Should -Be 1
            $result.SkippedInProgress[0].FullName | Should -Be 'D:\SDR_Render_video3_227249191.mov'
        }

        It 'a LOCKED file is never placed in ExcludedByAge either -- the two buckets are for two different, independent facts (age vs. lock state)' {
            $tree = @{
                'D:\' = @(
                    [pscustomobject]@{ PSIsContainer = $false; FullName = 'D:\locked.mov'; Extension = '.mov'; LastWriteTime = (Get-Date) }
                )
            }
            Mock Get-ChildItem {
                $key = "$LiteralPath"
                if ($tree.ContainsKey($key)) { return $tree[$key] }
                return @()
            }
            Mock Test-FileUnlocked { $false }

            $result = Find-RenderRecoveryCandidates -OutputDir 'D:\Renders' -Extensions @('.mov') `
                -ModifiedAfter (Get-Date).AddDays(-1) -MaxFiles 200 -MaxDepth 4 -MaxSeconds 60

            $result.SkippedInProgress.Count | Should -Be 1
            $result.ExcludedByAge.Count | Should -Be 0
            $result.Candidates.Count | Should -Be 0
        }

        It 'an OLD file is never lock-checked at all -- age is decided before lock state, so Test-FileUnlocked is not even called for it' {
            $tree = @{
                'D:\' = @(
                    [pscustomobject]@{ PSIsContainer = $false; FullName = 'D:\ancient.mov'; Extension = '.mov'; LastWriteTime = (Get-Date).AddDays(-10) }
                )
            }
            Mock Get-ChildItem {
                $key = "$LiteralPath"
                if ($tree.ContainsKey($key)) { return $tree[$key] }
                return @()
            }
            Mock Test-FileUnlocked { throw 'must not be called for a file already excluded by age' }

            $result = Find-RenderRecoveryCandidates -OutputDir 'D:\Renders' -Extensions @('.mov') `
                -ModifiedAfter (Get-Date).AddDays(-1) -MaxFiles 200 -MaxDepth 4 -MaxSeconds 60

            $result.ExcludedByAge.Count | Should -Be 1
            Should -Invoke Test-FileUnlocked -Times 0 -Exactly
        }
    }

    Context 'extension matching is case-insensitive' {
        It "matches an upper-case '.MOV' file extension against a lower-case '.mov' configured extension" {
            $tree = @{
                'D:\' = @(
                    [pscustomobject]@{ PSIsContainer = $false; FullName = 'D:\UPPER.MOV'; Extension = '.MOV'; LastWriteTime = (Get-Date) }
                )
            }
            Mock Get-ChildItem {
                $key = "$LiteralPath"
                if ($tree.ContainsKey($key)) { return $tree[$key] }
                return @()
            }
            $result = Find-RenderRecoveryCandidates -OutputDir 'D:\Renders' -Extensions @('.mov') `
                -ModifiedAfter (Get-Date).AddDays(-1) -MaxFiles 200 -MaxDepth 4 -MaxSeconds 60
            $result.Candidates.Count | Should -Be 1
        }
    }

    Context 'MaxFiles truncation is REPORTED (Truncated=$true), not silently applied, and counts ALL THREE buckets combined' {
        It 'caps Candidates at MaxFiles and sets Truncated=$true when more matches exist than the cap' {
            $tree = @{
                'D:\' = @(
                    [pscustomobject]@{ PSIsContainer = $false; FullName = 'D:\a.mov'; Extension = '.mov'; LastWriteTime = (Get-Date) },
                    [pscustomobject]@{ PSIsContainer = $false; FullName = 'D:\b.mov'; Extension = '.mov'; LastWriteTime = (Get-Date) },
                    [pscustomobject]@{ PSIsContainer = $false; FullName = 'D:\c.mov'; Extension = '.mov'; LastWriteTime = (Get-Date) }
                )
            }
            Mock Get-ChildItem {
                $key = "$LiteralPath"
                if ($tree.ContainsKey($key)) { return $tree[$key] }
                return @()
            }
            $result = Find-RenderRecoveryCandidates -OutputDir 'D:\Renders' -Extensions @('.mov') `
                -ModifiedAfter (Get-Date).AddDays(-1) -MaxFiles 2 -MaxDepth 4 -MaxSeconds 60
            $result.Candidates.Count | Should -Be 2
            $result.Truncated | Should -Be $true
        }

        It 'the cap counts the COMBINED (Candidates + ExcludedByAge + SkippedInProgress) total -- a volume full of only OLD matches still truncates and reports it' {
            $old = (Get-Date).AddDays(-30)
            $tree = @{
                'D:\' = @(
                    [pscustomobject]@{ PSIsContainer = $true;  FullName = 'D:\Sub' },
                    [pscustomobject]@{ PSIsContainer = $false; FullName = 'D:\root_old.mov'; Extension = '.mov'; LastWriteTime = $old }
                )
                'D:\Sub' = @(
                    [pscustomobject]@{ PSIsContainer = $true;  FullName = 'D:\Sub\Deeper' },
                    [pscustomobject]@{ PSIsContainer = $false; FullName = 'D:\Sub\sub_old.mov'; Extension = '.mov'; LastWriteTime = $old }
                )
                'D:\Sub\Deeper' = @(
                    [pscustomobject]@{ PSIsContainer = $false; FullName = 'D:\Sub\Deeper\deeper_old.mov'; Extension = '.mov'; LastWriteTime = $old }
                )
            }
            Mock Get-ChildItem {
                $key = "$LiteralPath"
                if ($tree.ContainsKey($key)) { return $tree[$key] }
                return @()
            }

            $result = Find-RenderRecoveryCandidates -OutputDir 'D:\Renders' -Extensions @('.mov') `
                -ModifiedAfter (Get-Date).AddMinutes(-1) -MaxFiles 2 -MaxDepth 4 -MaxSeconds 60

            $result.Candidates.Count | Should -Be 0
            $result.Truncated | Should -Be $true
            Should -Invoke Get-ChildItem -ParameterFilter { "$LiteralPath" -eq 'D:\Sub\Deeper' } -Times 0 -Exactly
        }
    }

    Context 'a scan FAILURE is a distinct fact from "the scan completed and found nothing"' {

        It 'reports ScanFailed=$true (not merely empty Candidates) when the volume root does not "exist"' {
            Mock Test-Path { $false }
            Mock Get-ChildItem { throw 'must never be called once the root check fails' }

            $result = Find-RenderRecoveryCandidates -OutputDir 'D:\Renders' -Extensions @('.mov') `
                -ModifiedAfter (Get-Date).AddDays(-1) -MaxFiles 200 -MaxDepth 4 -MaxSeconds 60

            $result.ScanFailed | Should -Be $true
            $result.Candidates.Count | Should -Be 0
            Should -Invoke Get-ChildItem -Times 0 -Exactly
        }

        It 'reports ScanFailed=$true when an unexpected exception escapes the walk (e.g. Test-Path itself throwing)' {
            Mock Test-Path { throw 'simulated disk I/O failure' }

            { Find-RenderRecoveryCandidates -OutputDir 'D:\Renders' -Extensions @('.mov') `
                -ModifiedAfter (Get-Date).AddDays(-1) -MaxFiles 200 -MaxDepth 4 -MaxSeconds 60 } | Should -Not -Throw

            $result = Find-RenderRecoveryCandidates -OutputDir 'D:\Renders' -Extensions @('.mov') `
                -ModifiedAfter (Get-Date).AddDays(-1) -MaxFiles 200 -MaxDepth 4 -MaxSeconds 60
            $result.ScanFailed | Should -Be $true
        }

        It 'a genuinely EMPTY, successfully-scanned tree reports ScanFailed=$false with zero Candidates -- distinguishable from the failure case above only by ScanFailed, not by Candidates.Count (which is 0 in both)' {
            Mock Get-ChildItem { return @() }

            $result = Find-RenderRecoveryCandidates -OutputDir 'D:\Renders' -Extensions @('.mov') `
                -ModifiedAfter (Get-Date).AddDays(-1) -MaxFiles 200 -MaxDepth 4 -MaxSeconds 60

            $result.ScanFailed | Should -Be $false
            $result.Candidates.Count | Should -Be 0
        }
    }

    Context 'wall-clock bound (MaxSeconds) truncates even before touching the filesystem, if the deadline has already passed' {
        It 'reports Truncated=$true and never calls Get-ChildItem when Get-Date shows the deadline already elapsed' {
            $script:DateCall = 0
            $base = Get-Date
            Mock Get-Date {
                $i = $script:DateCall
                $script:DateCall++
                if ($i -eq 0) { return $base }
                return $base.AddSeconds(1000)
            }
            Mock Get-ChildItem { throw 'must never be called once the wall-clock deadline has already elapsed' }

            $result = Find-RenderRecoveryCandidates -OutputDir 'D:\Renders' -Extensions @('.mov') `
                -ModifiedAfter $base.AddDays(-1) -MaxFiles 200 -MaxDepth 4 -MaxSeconds 5

            $result.Truncated | Should -Be $true
            $result.ScanFailed | Should -Be $false
            Should -Invoke Get-ChildItem -Times 0 -Exactly
        }
    }
}

Describe 'Test-FileUnlocked' {
    # Moved into Config.ps1 from Watchdog.ps1 (CORRECTION 2) so
    # Find-RenderRecoveryCandidates can share it. Tested here against REAL
    # temporary files -- no mocking needed, and none of the ambiguity that
    # affects Get-ChildItem/Test-Path: this is a plain, single-purpose,
    # single-parameter function performing one real filesystem probe.

    BeforeEach {
        $script:TempFile = Join-Path ([System.IO.Path]::GetTempPath()) ("TopazUnlockTest_{0}.tmp" -f ([guid]::NewGuid().ToString('N')))
        Set-Content -LiteralPath $script:TempFile -Value 'probe' -Encoding UTF8
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:TempFile) { Remove-Item -LiteralPath $script:TempFile -Force -ErrorAction SilentlyContinue }
    }

    It 'returns $true for an ordinary, unheld file' {
        Test-FileUnlocked -Path $script:TempFile | Should -Be $true
    }

    It 'returns $false while another handle holds an exclusive lock on the file' {
        $stream = [System.IO.File]::Open($script:TempFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try {
            Test-FileUnlocked -Path $script:TempFile | Should -Be $false
        }
        finally {
            $stream.Close(); $stream.Dispose()
        }
    }

    It 'returns $true again once the exclusive handle is released' {
        $stream = [System.IO.File]::Open($script:TempFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $stream.Close(); $stream.Dispose()
        Test-FileUnlocked -Path $script:TempFile | Should -Be $true
    }

    It 'returns $false (not a thrown exception) for a path that does not exist' {
        { Test-FileUnlocked -Path 'Z:\does\not\exist.mov' } | Should -Not -Throw
        Test-FileUnlocked -Path 'Z:\does\not\exist.mov' | Should -Be $false
    }
}

Describe 'Invoke-TopazForensicCapture' {
    # Best-effort capture of Topaz's own *.tzlog "process exited"/"error
    # occurred" lines into stop.log. Void return; every observable effect goes
    # through Write-TopazLog, which is mocked and its messages captured for
    # assertion. NEVER writes to the real stop.log/component logs in these
    # tests -- Write-TopazLog is ALWAYS mocked below, deliberately, since this
    # box's real log directory (C:\topaz-autostop\logs) holds the actual
    # 2026-07-28 incident's forensic record.

    # NOTE: this helper must live inside a BeforeAll (not a bare Describe-body
    # statement) -- Pester's Discovery phase executes the Describe body once
    # to enumerate tests, but the RUN phase (where It blocks actually execute)
    # does not inherit a plain function defined outside Before*/It, so a bare
    # `function New-Foo {...}` here is invisible to the Its below at run time.
    #
    # Get-ChildItem is shadowed with a PLAIN FUNCTION here, not Pester's Mock
    # -- the same technique this suite already uses for Get-CimInstance in
    # 'Test-RenderWorkerPresent' below. Pester's `Mock Get-ChildItem` proxy
    # generation was found, empirically, to intermittently reject this
    # call site's exact `-LiteralPath -Filter '*.tzlog' -File -ErrorAction`
    # combination ("parameter 'File' cannot be found") when run as part of
    # this file's full suite (isolated repros of the same call did not
    # reproduce it, so it looks like cross-test proxy-caching interference
    # rather than something wrong with this specific call) -- a plain
    # function shadow sidesteps Pester's cmdlet-proxy machinery entirely and
    # is completely deterministic.
    BeforeAll {
        function Get-ForensicTestConfig {
            param($TopazLogsBasePath = 'Z:\does-not-exist\topaz\logs', $MaxLines = 40, $TimeoutSec = 10)
            [pscustomobject]@{
                TopazLogsBasePath       = $TopazLogsBasePath
                TopazForensicMaxLines   = $MaxLines
                TopazForensicTimeoutSec = $TimeoutSec
            }
        }

        function Get-ChildItem {
            # Deliberately shadows the built-in cmdlet name -- see this
            # Describe block's own comment above for why. Test-only file;
            # no risk of leaking into the real pipeline.
            [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '')]
            # [CmdletBinding()] makes -ErrorAction an automatic common
            # parameter (see the identical Get-CimInstance shadow above for
            # the same reasoning) rather than one this shadow must declare
            # and then be flagged for never reading.
            [CmdletBinding()]
            param([string]$LiteralPath, [string]$Filter, [switch]$File)

            # Captured (not just accepted) so PSReviewUnusedParameter has no
            # complaint, and so a test that cares can assert the real call
            # shape -- exactly the same rationale as the Get-CimInstance
            # shadow's own capture variables above.
            $script:GciForensicCapturedLiteralPath = $LiteralPath
            $script:GciForensicCapturedFilter      = $Filter
            $script:GciForensicCapturedFile        = $File.IsPresent

            if ($script:GciForensicShouldThrow) { throw 'simulated unreadable directory' }
            return $script:GciForensicResult
        }
    }

    BeforeEach {
        $script:LoggedMessages = New-Object System.Collections.Generic.List[string]
        Mock Write-TopazLog {
            param($Message, $Level)
            $script:LoggedMessages.Add("[$Level] $Message")
        }
        $script:GciForensicResult = @()
        $script:GciForensicShouldThrow = $false
    }

    It 'logs a SKIPPED WARN (and never throws) when TopazLogsBasePath does not exist' {
        Mock Test-Path { $false }
        $cfg = Get-ForensicTestConfig
        { Invoke-TopazForensicCapture -Config $cfg } | Should -Not -Throw
        ($script:LoggedMessages -join "`n") | Should -Match 'SKIPPED'
    }

    It 'logs that no *.tzlog file was found when the directory exists but is empty' {
        Mock Test-Path { $true }
        $script:GciForensicResult = @()
        $cfg = Get-ForensicTestConfig
        Invoke-TopazForensicCapture -Config $cfg
        ($script:LoggedMessages -join "`n") | Should -Match 'no \*\.tzlog file found'
    }

    It 'picks the MOST RECENTLY MODIFIED *.tzlog when several exist' {
        Mock Test-Path { $true }
        $script:GciForensicResult = @(
            [pscustomobject]@{ FullName = 'Z:\logs\older.tzlog'; Name = 'older.tzlog'; LastWriteTime = (Get-Date).AddHours(-2) },
            [pscustomobject]@{ FullName = 'Z:\logs\newest.tzlog'; Name = 'newest.tzlog'; LastWriteTime = (Get-Date) }
        )
        Mock Select-String { return @() }
        $cfg = Get-ForensicTestConfig
        Invoke-TopazForensicCapture -Config $cfg
        ($script:LoggedMessages -join "`n") | Should -Match ([regex]::Escape('newest.tzlog'))
        ($script:LoggedMessages -join "`n") | Should -Not -Match ([regex]::Escape('older.tzlog'))
    }

    It "logs that the file contains no 'process exited' line when Select-String finds nothing" {
        Mock Test-Path { $true }
        $script:GciForensicResult = @([pscustomobject]@{ FullName = 'Z:\logs\a.tzlog'; Name = 'a.tzlog'; LastWriteTime = (Get-Date) })
        Mock Select-String { return @() }
        $cfg = Get-ForensicTestConfig
        Invoke-TopazForensicCapture -Config $cfg
        ($script:LoggedMessages -join "`n") | Should -Match "contains no 'process exited' line"
    }

    It 'logs every matched line when the match count is within TopazForensicMaxLines, with no truncation warning' {
        Mock Test-Path { $true }
        $script:GciForensicResult = @([pscustomobject]@{ FullName = 'Z:\logs\a.tzlog'; Name = 'a.tzlog'; LastWriteTime = (Get-Date) })
        Mock Select-String {
            return @(
                [pscustomobject]@{ Line = 'process exited error occurred: 31 1' },
                [pscustomobject]@{ Line = 'process exited: 36 0 0' }
            )
        }
        $cfg = Get-ForensicTestConfig -MaxLines 40
        Invoke-TopazForensicCapture -Config $cfg
        $joined = $script:LoggedMessages -join "`n"
        $joined | Should -Match ([regex]::Escape('process exited error occurred: 31 1'))
        $joined | Should -Match ([regex]::Escape('process exited: 36 0 0'))
        $joined | Should -Not -Match 'logging only the last'
    }

    It 'when matches EXCEED TopazForensicMaxLines, logs a truncation WARN and keeps only the LAST N lines (the decisive failure, not the first)' {
        Mock Test-Path { $true }
        $script:GciForensicResult = @([pscustomobject]@{ FullName = 'Z:\logs\a.tzlog'; Name = 'a.tzlog'; LastWriteTime = (Get-Date) })
        Mock Select-String {
            return @(
                [pscustomobject]@{ Line = 'FIRST-should-be-dropped' },
                [pscustomobject]@{ Line = 'SECOND-should-be-dropped' },
                [pscustomobject]@{ Line = 'THIRD-kept' },
                [pscustomobject]@{ Line = 'FOURTH-kept' }
            )
        }
        $cfg = Get-ForensicTestConfig -MaxLines 2
        Invoke-TopazForensicCapture -Config $cfg
        $joined = $script:LoggedMessages -join "`n"
        $joined | Should -Match 'logging only the last 2'
        $joined | Should -Match 'THIRD-kept'
        $joined | Should -Match 'FOURTH-kept'
        $joined | Should -Not -Match 'FIRST-should-be-dropped'
        $joined | Should -Not -Match 'SECOND-should-be-dropped'
    }

    It 'is best-effort: an unexpected exception (Get-ChildItem throwing) is caught and logged as WARN, never propagated' {
        Mock Test-Path { $true }
        $script:GciForensicShouldThrow = $true
        $cfg = Get-ForensicTestConfig
        { Invoke-TopazForensicCapture -Config $cfg } | Should -Not -Throw
        ($script:LoggedMessages -join "`n") | Should -Match 'FAILED \(best-effort, ignored\)'
    }

    It 'is best-effort: Select-String throwing is also caught and logged as WARN, never propagated' {
        Mock Test-Path { $true }
        $script:GciForensicResult = @([pscustomobject]@{ FullName = 'Z:\logs\a.tzlog'; Name = 'a.tzlog'; LastWriteTime = (Get-Date) })
        Mock Select-String { throw 'simulated read failure mid-file' }
        $cfg = Get-ForensicTestConfig
        { Invoke-TopazForensicCapture -Config $cfg } | Should -Not -Throw
        ($script:LoggedMessages -join "`n") | Should -Match 'FAILED \(best-effort, ignored\)'
    }

    It 'never writes to any REAL log location: TopazLogsBasePath pointing at a fake path never touches the actual production tzlog directory' {
        # Guards the test suite itself: this box's TopazLogsBasePath default
        # ('C:\Users\Administrator\AppData\Roaming\Topaz Labs LLC\Topaz
        # Video\logs') is the REAL incident's own log folder. Every test
        # above deliberately uses a fake 'Z:\...' path and mocks Test-Path /
        # Get-ChildItem / Select-String so none of them ever reads it for
        # real -- this test just documents that constraint explicitly.
        Mock Test-Path { $false }
        $cfg = Get-ForensicTestConfig -TopazLogsBasePath 'Z:\fake\only'
        Invoke-TopazForensicCapture -Config $cfg
        Should -Invoke Test-Path -ParameterFilter { "$LiteralPath" -like '*Topaz Labs LLC*' } -Times 0 -Exactly
    }
}

Describe 'Invoke-TopazRenderUpload (upload retry loop + unconditional anomaly-scan delegation)' {
    # Invoke-TopazAwsCli / Write-TopazLog / Start-Sleep / Test-Path /
    # Get-ChildItem are all mocked -- rclone is NEVER actually invoked, and
    # nothing is written to a real log file. The retry LOOP itself is inline
    # (not its own testable helper), but it delegates its "retry or not"
    # decision to the pure Resolve-UploadRetryDecision tested above, and the
    # loop's own observable behaviour (exact call counts, exact outcomes) IS
    # fully testable by mocking Invoke-TopazAwsCli and counting invocations,
    # which is what pins the production "2 total attempts" cap below.

    BeforeAll {
        function Get-UploadTestConfig {
            param([bool]$OutputIsEphemeral = $true, [int]$RetryDelaySec = 0)
            [pscustomobject]@{
                RclonePath          = 'C:\fake\rclone.exe'
                RcloneConfigPath    = 'C:\fake\rclone.conf'
                OutputDir           = 'D:\Renders'
                UploadTarget        = 'gdrive:temp'
                LogDir              = 'C:\fake\logs'
                UploadTimeoutSec    = 14400
                UploadRetryDelaySec = $RetryDelaySec
                OutputIsEphemeral   = $OutputIsEphemeral
                ArmSec              = 90
                RenderFileExtensions   = @('.mov', '.mp4', '.mkv', '.avi', '.mxf')
                RecoveryMaxAgeMin      = 60
                RecoveryScanMaxFiles   = 200
                RecoveryScanMaxDepth   = 4
                RecoveryScanTimeoutSec = 60
                TopazLogsBasePath       = 'Z:\nope'
                TopazForensicMaxLines   = 40
                TopazForensicTimeoutSec = 10
            }
        }
    }

    BeforeEach {
        Mock Write-TopazLog { }
        Mock Start-Sleep { }
        Mock Test-Path { $true }
        Mock Get-ChildItem {
            return @([pscustomobject]@{ FullName = 'D:\Renders\out.mov'; Length = 123; LastWriteTime = (Get-Date) })
        }
        Mock Invoke-TopazOutputAnomalyHandling { return $true }
        $script:CallSeq = New-Object System.Collections.Generic.List[string]
    }

    Context 'first attempt succeeds -> no retry at all' {
        It 'returns $true and calls Invoke-TopazAwsCli EXACTLY twice (one copy, one check) -- a success must never trigger a retry' {
            Mock Invoke-TopazAwsCli {
                param($Arguments)
                $script:CallSeq.Add($Arguments[0])
                return $true
            }
            $cfg = Get-UploadTestConfig
            $result = Invoke-TopazRenderUpload -Config $cfg -Reason 'completed'
            $result | Should -Be $true
            $script:CallSeq | Should -Be @('copy', 'check')
            Should -Invoke Invoke-TopazAwsCli -Times 2 -Exactly
            Should -Invoke Start-Sleep -Times 0 -Exactly
        }

        It 'calls Invoke-TopazOutputAnomalyHandling with OutputDirHasFiles=$true (the misplaced-output scan now runs even on a healthy upload -- CORRECTION 1)' {
            Mock Invoke-TopazAwsCli { return $true }
            Mock Invoke-TopazOutputAnomalyHandling {
                param($OutputDirHasFiles)
                $script:SeenHasFiles = $OutputDirHasFiles
                return $true
            }
            $cfg = Get-UploadTestConfig
            [void] (Invoke-TopazRenderUpload -Config $cfg -Reason 'completed')
            $script:SeenHasFiles | Should -Be $true
            Should -Invoke Invoke-TopazOutputAnomalyHandling -Times 1 -Exactly
        }
    }

    Context 'attempt 1 fails, attempt 2 recovers -> retried exactly once, both attempts logged distinguishably' {
        It 'redoes BOTH copy and check on the retry (not just check) when attempt 1''s COPY failed outright' {
            $script:CopyCalls = 0
            Mock Invoke-TopazAwsCli {
                param($Arguments)
                $script:CallSeq.Add($Arguments[0])
                if ($Arguments[0] -eq 'copy') {
                    $script:CopyCalls++
                    return ($script:CopyCalls -ge 2)
                }
                return $true
            }
            $cfg = Get-UploadTestConfig
            $result = Invoke-TopazRenderUpload -Config $cfg -Reason 'completed'
            $result | Should -Be $true
            $script:CallSeq | Should -Be @('copy', 'copy', 'check')
            Should -Invoke Invoke-TopazAwsCli -Times 3 -Exactly
            Should -Invoke Start-Sleep -Times 1 -Exactly
        }

        It 'redoes BOTH copy and check when attempt 1''s CHECK failed on an otherwise-successful copy (the partial-transfer case)' {
            $script:CheckCalls = 0
            Mock Invoke-TopazAwsCli {
                param($Arguments)
                $script:CallSeq.Add($Arguments[0])
                if ($Arguments[0] -eq 'copy') { return $true }
                $script:CheckCalls++
                return ($script:CheckCalls -ge 2)
            }
            $cfg = Get-UploadTestConfig
            $result = Invoke-TopazRenderUpload -Config $cfg -Reason 'completed'
            $result | Should -Be $true
            $script:CallSeq | Should -Be @('copy', 'check', 'copy', 'check')
            Should -Invoke Invoke-TopazAwsCli -Times 4 -Exactly
        }
    }

    Context 'BOTH attempts fail -> the cap is exactly 2, never a 3rd try, and the outcome is REFUSE (returns $false)' {
        It 'calls Invoke-TopazAwsCli EXACTLY twice (not three or more times) and returns $false' {
            Mock Invoke-TopazAwsCli {
                param($Arguments)
                $script:CallSeq.Add($Arguments[0])
                return $false
            }
            $cfg = Get-UploadTestConfig
            $result = Invoke-TopazRenderUpload -Config $cfg -Reason 'completed'
            $result | Should -Be $false
            $script:CallSeq | Should -Be @('copy', 'copy')
            Should -Invoke Invoke-TopazAwsCli -Times 2 -Exactly
            Should -Invoke Start-Sleep -Times 1 -Exactly
        }

        It 'does NOT run the misplaced-output scan when OutputDir''s OWN upload failed -- the ephemeral interlock refuses first' {
            Mock Invoke-TopazAwsCli { return $false }
            $cfg = Get-UploadTestConfig
            [void] (Invoke-TopazRenderUpload -Config $cfg -Reason 'completed')
            Should -Invoke Invoke-TopazOutputAnomalyHandling -Times 0 -Exactly
        }

        It 'logs both attempts distinguishably ("attempt 1 of 2" / "attempt 2 of 2") and states plainly that both were exhausted' {
            $script:Logged = New-Object System.Collections.Generic.List[string]
            Mock Write-TopazLog {
                param($Message)
                $script:Logged.Add($Message)
            }
            Mock Invoke-TopazAwsCli { return $false }
            $cfg = Get-UploadTestConfig
            [void] (Invoke-TopazRenderUpload -Config $cfg -Reason 'completed')
            $joined = $script:Logged -join "`n"
            $joined | Should -Match 'attempt 1 of 2'
            $joined | Should -Match 'attempt 2 of 2'
            $joined | Should -Match 'Both attempts \(1 initial \+ 1 retry\) exhausted'
        }
    }

    Context 'empty OutputDir ALSO delegates to Invoke-TopazOutputAnomalyHandling (with OutputDirHasFiles=$false), and never touches rclone' {
        It 'returns $true, passes OutputDirHasFiles=$false and Reason through unchanged, with zero rclone calls' {
            Mock Get-ChildItem { return @() }
            Mock Invoke-TopazOutputAnomalyHandling {
                param($Reason, $OutputDirHasFiles)
                $script:SeenReason = $Reason
                $script:SeenHasFiles = $OutputDirHasFiles
                return $true
            }
            Mock Invoke-TopazAwsCli { throw 'must never be called when OutputDir is empty' }

            $cfg = Get-UploadTestConfig
            $result = Invoke-TopazRenderUpload -Config $cfg -Reason 'completed'

            $result | Should -Be $true
            $script:SeenReason | Should -Be 'completed'
            $script:SeenHasFiles | Should -Be $false
            Should -Invoke Invoke-TopazOutputAnomalyHandling -Times 1 -Exactly
            Should -Invoke Invoke-TopazAwsCli -Times 0 -Exactly
        }
    }
}

Describe 'Invoke-TopazRecoveryUpload (recovery upload retry loop -- ERROR CLASS A)' {
    # Same retry plumbing/cap as Invoke-TopazRenderUpload, reused via the same
    # Resolve-UploadRetryDecision helper -- but the TERMINAL behaviour is
    # deliberately different (see the function's own comment): this never
    # gates the stop, it only ever affects what gets logged as each file's
    # disposition.

    BeforeAll {
        function Get-RecoveryTestConfig {
            param([bool]$OutputIsEphemeral = $true, [int]$RetryDelaySec = 0, [bool]$RcloneAvailable = $true)
            [pscustomobject]@{
                RclonePath          = if ($RcloneAvailable) { 'C:\fake\rclone.exe' } else { 'C:\missing\rclone.exe' }
                RcloneConfigPath    = 'C:\fake\rclone.conf'
                OutputDir           = 'D:\Renders'
                UploadTarget        = 'gdrive:temp'
                LogDir              = 'C:\fake\logs'
                UploadTimeoutSec    = 14400
                UploadRetryDelaySec = $RetryDelaySec
                OutputIsEphemeral   = $OutputIsEphemeral
            }
        }

        function Get-TestCandidate {
            param([string]$Name = 'D:\SDR_Render_video3_slp.mov', [long]$Length = 2431234000)
            [pscustomobject]@{ FullName = $Name; Length = $Length; LastWriteTime = (Get-Date) }
        }
    }

    BeforeEach {
        Mock Start-Sleep { }
        $script:Logged = New-Object System.Collections.Generic.List[string]
        Mock Write-TopazLog {
            param($Message, $Level)
            $script:Logged.Add("[$Level] $Message")
        }
        $script:CallSeq = New-Object System.Collections.Generic.List[string]
    }

    It 'an EMPTY Candidates list returns AnyUnrecovered=$false immediately, with no logging and no rclone calls at all' {
        Mock Test-Path { $true }
        Mock Invoke-TopazAwsCli { throw 'must never be called for zero candidates' }
        $cfg = Get-RecoveryTestConfig
        $result = Invoke-TopazRecoveryUpload -Config $cfg -Candidates @()
        $result.AnyUnrecovered | Should -Be $false
        Should -Invoke Write-TopazLog -Times 0 -Exactly
        Should -Invoke Invoke-TopazAwsCli -Times 0 -Exactly
    }

    It 'when rclone/its config is unavailable, every candidate is logged NOT RECOVERED and AnyUnrecovered=$true, with zero rclone calls' {
        Mock Test-Path { $false }
        Mock Invoke-TopazAwsCli { throw 'must never be called when rclone itself is unavailable' }
        $cfg = Get-RecoveryTestConfig
        $result = Invoke-TopazRecoveryUpload -Config $cfg -Candidates @((Get-TestCandidate))
        $result.AnyUnrecovered | Should -Be $true
        ($script:Logged -join "`n") | Should -Match 'NOT RECOVERED'
        Should -Invoke Invoke-TopazAwsCli -Times 0 -Exactly
    }

    Context 'first attempt succeeds' {
        It 'returns AnyUnrecovered=$false, calls Invoke-TopazAwsCli exactly twice, and logs "uploaded+verified"' {
            Mock Test-Path { $true }
            Mock Invoke-TopazAwsCli {
                param($Arguments)
                $script:CallSeq.Add($Arguments[0])
                return $true
            }
            $cfg = Get-RecoveryTestConfig
            $result = Invoke-TopazRecoveryUpload -Config $cfg -Candidates @((Get-TestCandidate))
            $result.AnyUnrecovered | Should -Be $false
            $script:CallSeq | Should -Be @('copy', 'check')
            Should -Invoke Invoke-TopazAwsCli -Times 2 -Exactly
            ($script:Logged -join "`n") | Should -Match 'uploaded\+verified'
        }
    }

    Context 'both attempts fail entirely -> the SAME max-2 cap, and the log spells out the file is unrecoverable' {
        It 'calls Invoke-TopazAwsCli exactly twice (never a third attempt), returns AnyUnrecovered=$true' {
            Mock Test-Path { $true }
            Mock Invoke-TopazAwsCli {
                param($Arguments)
                $script:CallSeq.Add($Arguments[0])
                return $false
            }
            $cfg = Get-RecoveryTestConfig
            $result = Invoke-TopazRecoveryUpload -Config $cfg -Candidates @((Get-TestCandidate))
            $result.AnyUnrecovered | Should -Be $true
            $script:CallSeq | Should -Be @('copy', 'copy')
            Should -Invoke Invoke-TopazAwsCli -Times 2 -Exactly
        }

        It 'when OutputIsEphemeral=$true, the log states in PLAIN WORDS that the file will be destroyed and is unrecoverable' {
            Mock Test-Path { $true }
            Mock Invoke-TopazAwsCli { return $false }
            $cfg = Get-RecoveryTestConfig -OutputIsEphemeral $true
            [void] (Invoke-TopazRecoveryUpload -Config $cfg -Candidates @((Get-TestCandidate)))
            $joined = $script:Logged -join "`n"
            $joined | Should -Match 'PERMANENTLY DESTROYED'
            $joined | Should -Match 'UNRECOVERABLE'
        }

        It 'when OutputIsEphemeral=$false, the log does NOT claim destruction (the file survives; it just was not uploaded)' {
            Mock Test-Path { $true }
            Mock Invoke-TopazAwsCli { return $false }
            $cfg = Get-RecoveryTestConfig -OutputIsEphemeral $false
            [void] (Invoke-TopazRecoveryUpload -Config $cfg -Candidates @((Get-TestCandidate)))
            $joined = $script:Logged -join "`n"
            $joined | Should -Not -Match 'PERMANENTLY DESTROYED'
            $joined | Should -Match 'not.*destroyed'
        }

        It 'logs both attempts distinguishably ("attempt 1 of 2" / "attempt 2 of 2")' {
            Mock Test-Path { $true }
            Mock Invoke-TopazAwsCli { return $false }
            $cfg = Get-RecoveryTestConfig
            [void] (Invoke-TopazRecoveryUpload -Config $cfg -Candidates @((Get-TestCandidate)))
            $joined = $script:Logged -join "`n"
            $joined | Should -Match 'attempt 1 of 2'
            $joined | Should -Match 'attempt 2 of 2'
        }
    }

    Context 'copy succeeds but check never confirms it -> the distinct "uploaded-but-unverified" middle state' {
        It 'reports uploaded-but-unverified (neither fully safe nor fully lost), still AnyUnrecovered=$true' {
            Mock Test-Path { $true }
            Mock Invoke-TopazAwsCli {
                param($Arguments)
                if ($Arguments[0] -eq 'copy') { return $true }
                return $false
            }
            $cfg = Get-RecoveryTestConfig
            $result = Invoke-TopazRecoveryUpload -Config $cfg -Candidates @((Get-TestCandidate))
            $result.AnyUnrecovered | Should -Be $true
            ($script:Logged -join "`n") | Should -Match 'uploaded-but-unverified'
            ($script:Logged -join "`n") | Should -Match 'UNCONFIRMED'
        }
    }

    Context 'THE DELIBERATE ASYMMETRY with the normal upload path' {
        It 'a recovery upload failing twice does NOT return anything refusal-shaped -- it only reports AnyUnrecovered informationally; the caller (Invoke-TopazOutputAnomalyHandling) is the one that must still stop, tested separately below' {
            Mock Test-Path { $true }
            Mock Invoke-TopazAwsCli { return $false }
            $cfg = Get-RecoveryTestConfig
            $result = Invoke-TopazRecoveryUpload -Config $cfg -Candidates @((Get-TestCandidate))
            $result.PSObject.Properties.Name | Should -Be @('AnyUnrecovered')
            $result.AnyUnrecovered | Should -BeOfType [bool]
        }
    }
}

Describe 'Invoke-TopazOutputAnomalyHandling (orchestration + the never-refuse critical assertion)' {
    # TWO DIFFERENT CONCERNS are deliberately kept in TWO DIFFERENT groups of
    # tests below:
    #   1. "Given Find-RenderRecoveryCandidates/Invoke-TopazForensicCapture/
    #      Invoke-TopazRecoveryUpload behave as documented, does this
    #      function's OWN routing/return-value contract hold?" -- tested with
    #      those three functions MOCKED (Find-RenderRecoveryCandidates is
    #      mocked here to isolate orchestration from its own internals, which
    #      are already tested in their own Describe block above).
    #   2. A dedicated regression test near the bottom exercises the REAL
    #      (unmocked) Find-RenderRecoveryCandidates end to end, because an
    #      earlier revision of this exact call site was found DURING this
    #      test-writing session to be missing the (newly mandatory)
    #      -ModifiedAfter argument entirely -- a confirmed, reproducible
    #      ParameterBindingException that would have crashed the whole stop
    #      sequence on every real anomalous completion. That has SINCE BEEN
    #      FIXED (the call site now computes -ModifiedAfter from
    #      RecoveryMaxAgeMin) -- the test below is now a REGRESSION guard
    #      against that exact wiring gap reappearing, not a live bug report.

    BeforeAll {
        function Get-HandlingTestConfig {
            [pscustomobject]@{
                OutputDir = 'D:\Renders'
                ArmSec    = 90
                RenderFileExtensions   = @('.mov', '.mp4', '.mkv', '.avi', '.mxf')
                RecoveryMaxAgeMin      = 60
                RecoveryScanMaxFiles   = 200
                RecoveryScanMaxDepth   = 4
                RecoveryScanTimeoutSec = 60
                TopazLogsBasePath       = 'Z:\nope'
                TopazForensicMaxLines   = 40
                TopazForensicTimeoutSec = 10
                OutputIsEphemeral       = $true
            }
        }

        function Get-TestScanResult {
            param([array]$Candidates = @(), [array]$ExcludedByAge = @(), [array]$SkippedInProgress = @(), [bool]$ScanFailed = $false, [bool]$Truncated = $false)
            [pscustomobject]@{ Candidates = $Candidates; ExcludedByAge = $ExcludedByAge; SkippedInProgress = $SkippedInProgress; ScanFailed = $ScanFailed; Truncated = $Truncated }
        }
    }

    BeforeEach {
        $script:Logged = New-Object System.Collections.Generic.List[string]
        Mock Write-TopazLog {
            param($Message, $Level)
            $script:Logged.Add("[$Level] $Message")
        }
        Mock Invoke-TopazForensicCapture { }
    }

    Context "Reason is NOT 'completed' -> the scan is skipped entirely, regardless of OutputDirHasFiles" {
        It 'returns $true and never calls Find-RenderRecoveryCandidates for stalled' {
            Mock Find-RenderRecoveryCandidates { throw 'must not be called for a non-completed reason' }
            $cfg = Get-HandlingTestConfig
            Invoke-TopazOutputAnomalyHandling -Config $cfg -Reason 'stalled' -OutputDirHasFiles $true | Should -Be $true
        }
        It 'returns $true and never calls Find-RenderRecoveryCandidates for maxlifetime' {
            Mock Find-RenderRecoveryCandidates { throw 'must not be called for a non-completed reason' }
            $cfg = Get-HandlingTestConfig
            Invoke-TopazOutputAnomalyHandling -Config $cfg -Reason 'maxlifetime' -OutputDirHasFiles $false | Should -Be $true
        }
    }

    Context "Reason='completed' -> the scan runs REGARDLESS of OutputDirHasFiles (CORRECTION 1)" {
        It 'runs Find-RenderRecoveryCandidates even when OutputDirHasFiles=$true (a correctly-placed FIRST file must not mask a misplaced SECOND one)' {
            Mock Find-RenderRecoveryCandidates { return (Get-TestScanResult) }
            $cfg = Get-HandlingTestConfig
            Invoke-TopazOutputAnomalyHandling -Config $cfg -Reason 'completed' -OutputDirHasFiles $true | Should -Be $true
            Should -Invoke Find-RenderRecoveryCandidates -Times 1 -Exactly
        }
    }

    Context 'ErrorClassA routing: candidates found -> recovery attempted, distinct logging, forensic capture runs' {
        It 'calls Invoke-TopazRecoveryUpload with exactly the scan''s Candidates, logs RENDER-OUTSIDE-OUTPUTDIR distinctly (never RENDER-PRODUCED-NO-OUTPUT), captures forensics, and returns $true' {
            $candidate = [pscustomobject]@{ FullName = 'D:\SDR_Render_video3_slp.mov'; Length = 2431234000; LastWriteTime = (Get-Date) }
            Mock Find-RenderRecoveryCandidates { return (Get-TestScanResult -Candidates @($candidate)) }
            Mock Invoke-TopazRecoveryUpload {
                param($Candidates)
                $script:SeenCandidates = $Candidates
                return [pscustomobject]@{ AnyUnrecovered = $false }
            }
            $cfg = Get-HandlingTestConfig
            $result = Invoke-TopazOutputAnomalyHandling -Config $cfg -Reason 'completed' -OutputDirHasFiles $false
            $result | Should -Be $true
            $script:SeenCandidates.Count | Should -Be 1
            $joined = $script:Logged -join "`n"
            $joined | Should -Match 'RENDER-OUTSIDE-OUTPUTDIR'
            $joined | Should -Not -Match 'RENDER-PRODUCED-NO-OUTPUT'
            Should -Invoke Invoke-TopazRecoveryUpload -Times 1 -Exactly
            Should -Invoke Invoke-TopazForensicCapture -Times 1 -Exactly
        }

        It 'ALSO fires when OutputDirHasFiles=$true -- the live counter-example this correction exists for' {
            $candidate = [pscustomobject]@{ FullName = 'D:\second_misplaced.mov'; Length = 999; LastWriteTime = (Get-Date) }
            Mock Find-RenderRecoveryCandidates { return (Get-TestScanResult -Candidates @($candidate)) }
            Mock Invoke-TopazRecoveryUpload { return [pscustomobject]@{ AnyUnrecovered = $false } }
            $cfg = Get-HandlingTestConfig
            Invoke-TopazOutputAnomalyHandling -Config $cfg -Reason 'completed' -OutputDirHasFiles $true | Should -Be $true
            ($script:Logged -join "`n") | Should -Match 'RENDER-OUTSIDE-OUTPUTDIR'
        }
    }

    Context 'ErrorClassB routing: OutputDir empty AND nothing found -> logged distinctly, no recovery attempted' {
        It 'never calls Invoke-TopazRecoveryUpload, logs RENDER-PRODUCED-NO-OUTPUT distinctly (never RENDER-OUTSIDE-OUTPUTDIR), captures forensics, returns $true' {
            Mock Find-RenderRecoveryCandidates { return (Get-TestScanResult -Candidates @()) }
            Mock Invoke-TopazRecoveryUpload { throw 'must not be called when no candidates were found' }
            $cfg = Get-HandlingTestConfig
            $result = Invoke-TopazOutputAnomalyHandling -Config $cfg -Reason 'completed' -OutputDirHasFiles $false
            $result | Should -Be $true
            $joined = $script:Logged -join "`n"
            $joined | Should -Match 'RENDER-PRODUCED-NO-OUTPUT'
            $joined | Should -Not -Match 'RENDER-OUTSIDE-OUTPUTDIR'
            Should -Invoke Invoke-TopazRecoveryUpload -Times 0 -Exactly
            Should -Invoke Invoke-TopazForensicCapture -Times 1 -Exactly
        }
    }

    Context "'Normal' routing: OutputDir has files AND nothing anomalous found elsewhere -> logged as healthy, NO forensic capture (not free, not needed)" {
        It 'logs a plain informational line, never RENDER-OUTSIDE-OUTPUTDIR or RENDER-PRODUCED-NO-OUTPUT, and skips forensic capture' {
            Mock Find-RenderRecoveryCandidates { return (Get-TestScanResult -Candidates @()) }
            $cfg = Get-HandlingTestConfig
            $result = Invoke-TopazOutputAnomalyHandling -Config $cfg -Reason 'completed' -OutputDirHasFiles $true
            $result | Should -Be $true
            $joined = $script:Logged -join "`n"
            $joined | Should -Not -Match 'RENDER-OUTSIDE-OUTPUTDIR'
            $joined | Should -Not -Match 'RENDER-PRODUCED-NO-OUTPUT'
            $joined | Should -Match 'Nothing anomalous'
            Should -Invoke Invoke-TopazForensicCapture -Times 0 -Exactly
        }
    }

    Context 'FIXED (2026-07-28, during this test-writing session): ExcludedByAge and SkippedInProgress are now ALWAYS logged, unconditionally' {
        It "logs an ExcludedByAge entry's own full path even on the 'Normal' path (OutputDirHasFiles=$true, no error class)" {
            $tooOld = [pscustomobject]@{ FullName = 'D:\SDR_Render_video3.mov'; Length = 1616764730; LastWriteTime = (Get-Date).AddHours(-3) }
            Mock Find-RenderRecoveryCandidates { return (Get-TestScanResult -Candidates @() -ExcludedByAge @($tooOld)) }
            $cfg = Get-HandlingTestConfig
            Invoke-TopazOutputAnomalyHandling -Config $cfg -Reason 'completed' -OutputDirHasFiles $true | Out-Null
            $joined = $script:Logged -join "`n"
            $joined | Should -Match ([regex]::Escape('SDR_Render_video3.mov'))
            $joined | Should -Match 'EXCLUDED BY AGE'
        }

        It "logs a SkippedInProgress entry's own full path, distinctly worded from ExcludedByAge" {
            $inProgress = [pscustomobject]@{ FullName = 'D:\SDR_Render_video3_227249191.mov'; Length = 999; LastWriteTime = (Get-Date) }
            Mock Find-RenderRecoveryCandidates { return (Get-TestScanResult -Candidates @() -SkippedInProgress @($inProgress)) }
            $cfg = Get-HandlingTestConfig
            Invoke-TopazOutputAnomalyHandling -Config $cfg -Reason 'completed' -OutputDirHasFiles $false | Out-Null
            $joined = $script:Logged -join "`n"
            $joined | Should -Match ([regex]::Escape('SDR_Render_video3_227249191.mov'))
            $joined | Should -Match 'SKIPPED, IN PROGRESS'
        }
    }

    Context 'a scan FAILURE and a scan TRUNCATION are each logged distinctly' {
        It 'logs "RECOVERY SCAN FAILED" and still proceeds (ScanFailed alone does not change the Candidates-based classification), returning $true' {
            Mock Find-RenderRecoveryCandidates { return (Get-TestScanResult -ScanFailed $true) }
            $cfg = Get-HandlingTestConfig
            $result = Invoke-TopazOutputAnomalyHandling -Config $cfg -Reason 'completed' -OutputDirHasFiles $false
            $result | Should -Be $true
            ($script:Logged -join "`n") | Should -Match 'RECOVERY SCAN FAILED'
        }

        It 'logs "RECOVERY SCAN TRUNCATED" when the scan reports Truncated=$true' {
            Mock Find-RenderRecoveryCandidates { return (Get-TestScanResult -Truncated $true) }
            $cfg = Get-HandlingTestConfig
            Invoke-TopazOutputAnomalyHandling -Config $cfg -Reason 'completed' -OutputDirHasFiles $true | Should -Be $true
            ($script:Logged -join "`n") | Should -Match 'RECOVERY SCAN TRUNCATED'
        }
    }

    Context 'THE CRITICAL ASSERTION -- no input combination, including a recovery upload that fails completely or throws, may ever produce a refusal' {
        # The operator explicitly declined a "refuse to stop" interlock for
        # this case. A silent regression that reintroduced one here would
        # strand the box running (and billing) indefinitely.

        It 'returns $true for EVERY combination of Reason x OutputDirHasFiles x CandidatesFound x ScanFailed x Truncated x the recovery upload''s own AnyUnrecovered outcome' {
            foreach ($reason in @('completed', 'stalled', 'maxlifetime')) {
                foreach ($outputDirHasFiles in @($true, $false)) {
                    foreach ($candidatesFound in @($true, $false)) {
                        foreach ($scanFailed in @($true, $false)) {
                            foreach ($truncated in @($true, $false)) {
                                foreach ($anyUnrecovered in @($true, $false)) {
                                    $candidates = if ($candidatesFound) { @([pscustomobject]@{ FullName = 'x'; Length = 1; LastWriteTime = (Get-Date) }) } else { @() }
                                    Mock Find-RenderRecoveryCandidates { return (Get-TestScanResult -Candidates $candidates -ScanFailed $scanFailed -Truncated $truncated) }
                                    Mock Invoke-TopazRecoveryUpload { return [pscustomobject]@{ AnyUnrecovered = $anyUnrecovered } }

                                    $result = Invoke-TopazOutputAnomalyHandling -Config (Get-HandlingTestConfig) -Reason $reason -OutputDirHasFiles $outputDirHasFiles

                                    $result | Should -Be $true -Because "Reason=$reason OutputDirHasFiles=$outputDirHasFiles CandidatesFound=$candidatesFound ScanFailed=$scanFailed Truncated=$truncated AnyUnrecovered=$anyUnrecovered must never refuse"
                                }
                            }
                        }
                    }
                }
            }
        }

        It 'STILL returns $true even when the recovery upload THROWS outright (regression guard)' {
            # HISTORY: earlier in this test-writing session, this exact
            # scenario was found to propagate an uncaught exception all the
            # way out of Invoke-TopazOutputAnomalyHandling (which had no
            # top-level try/catch of its own, unlike Find-RenderRecoveryCandidates
            # and Invoke-TopazForensicCapture, both explicitly self-wrapped for
            # precisely this reason). That would have aborted the ENTIRE stop
            # sequence on an unanticipated failure inside the recovery path --
            # the opposite of the operator's explicit "always stop" instruction.
            # This was FIXED (a wrapping try/catch was added around this
            # function's body, matching the sibling functions' own pattern) --
            # this test is now a regression guard against that gap reappearing,
            # not a live bug report.
            Mock Find-RenderRecoveryCandidates { return (Get-TestScanResult -Candidates @([pscustomobject]@{ FullName = 'x'; Length = 1; LastWriteTime = (Get-Date) })) }
            Mock Invoke-TopazRecoveryUpload { throw 'simulated unexpected failure inside recovery upload' }

            { Invoke-TopazOutputAnomalyHandling -Config (Get-HandlingTestConfig) -Reason 'completed' -OutputDirHasFiles $false } | Should -Not -Throw
        }
    }

    Context 'REGRESSION GUARD: the real (unmocked) Find-RenderRecoveryCandidates call succeeds end to end -- no missing-argument crash' {
        # See this Describe block's own header comment: an earlier revision's
        # call to Find-RenderRecoveryCandidates omitted the (newly mandatory)
        # -ModifiedAfter argument entirely, which would have thrown a
        # ParameterBindingException on every real anomalous completion and
        # left the box running forever instead of stopping. Confirmed via
        # direct reproduction during this session; fixed before this test was
        # finalised. This test exercises the REAL function (only Get-ChildItem/
        # Test-Path/Test-FileUnlocked are mocked) to guard against that exact
        # wiring gap reappearing.
        BeforeEach {
            Mock Test-Path { $true }
            Mock Get-ChildItem { return @() }
            Mock Test-FileUnlocked { $true }
        }

        It 'does not throw, and still returns $true, for ErrorClassB (empty OutputDir, nothing found)' {
            $cfg = Get-HandlingTestConfig
            { Invoke-TopazOutputAnomalyHandling -Config $cfg -Reason 'completed' -OutputDirHasFiles $false } | Should -Not -Throw
            Invoke-TopazOutputAnomalyHandling -Config $cfg -Reason 'completed' -OutputDirHasFiles $false | Should -Be $true
        }

        It 'does not throw, and still returns $true, for the Normal path (OutputDir has files, nothing found elsewhere)' {
            $cfg = Get-HandlingTestConfig
            { Invoke-TopazOutputAnomalyHandling -Config $cfg -Reason 'completed' -OutputDirHasFiles $true } | Should -Not -Throw
        }
    }
}

Describe 'Invoke-TopazIncrementalUpload (CORRECTION 3 -- upload each render as it finishes)' {
    # CORRECTED (this test-writing session): an earlier pass of this comment
    # claimed Invoke-TopazIncrementalUploadPoll and Resolve-IncrementalUpload
    # Eligibility were "not actually defined in Watchdog.ps1 yet" and that this
    # function was dead code. That was wrong -- Watchdog.ps1 fully implements
    # and wires up both (Resolve-IncrementalUploadEligibility,
    # Get-NextUploadTrackingState, Invoke-TopazIncrementalUploadPoll), and the
    # poll loop calls Invoke-TopazIncrementalUploadPoll unconditionally every
    # cycle. See Watchdog.Tests.ps1 for the tests covering those three
    # functions, added alongside this fix. This function (the actual rclone
    # copy/check mechanics for ONE file) is tested here in isolation because it
    # lives in Config.ps1, same as Invoke-TopazRenderUpload/Invoke-TopazRecovery
    # Upload above -- not because it is unreachable. The retry mechanics mirror
    # those two exactly (same Resolve-UploadRetryDecision, same 2-attempt cap),
    # so the same style of call-count pinning applies.

    BeforeAll {
        function Get-IncrementalTestConfig {
            param([int]$RetryDelaySec = 0)
            [pscustomobject]@{
                RclonePath          = 'C:\fake\rclone.exe'
                RcloneConfigPath    = 'C:\fake\rclone.conf'
                OutputDir           = 'D:\Renders'
                UploadTarget        = 'gdrive:temp'
                LogDir              = 'C:\fake\logs'
                UploadTimeoutSec    = 14400
                UploadRetryDelaySec = $RetryDelaySec
            }
        }
    }

    BeforeEach {
        Mock Write-TopazLog { }
        Mock Start-Sleep { }
        Mock Test-Path { $true }
        $script:CallSeq = New-Object System.Collections.Generic.List[string]
        $script:File = [pscustomobject]@{ FullName = 'D:\Renders\finished.mov'; Name = 'finished.mov'; Length = 12345 }
    }

    It 'rclone/config unavailable -> returns $false immediately, no rclone calls' {
        Mock Test-Path { $false }
        Mock Invoke-TopazAwsCli { throw 'must never be called when rclone is unavailable' }
        $cfg = Get-IncrementalTestConfig
        Invoke-TopazIncrementalUpload -Config $cfg -File $script:File | Should -Be $false
        Should -Invoke Invoke-TopazAwsCli -Times 0 -Exactly
    }

    It 'first attempt succeeds -> returns $true, exactly 2 rclone calls, no retry' {
        Mock Invoke-TopazAwsCli {
            param($Arguments)
            $script:CallSeq.Add($Arguments[0])
            return $true
        }
        $cfg = Get-IncrementalTestConfig
        Invoke-TopazIncrementalUpload -Config $cfg -File $script:File | Should -Be $true
        $script:CallSeq | Should -Be @('copy', 'check')
        Should -Invoke Invoke-TopazAwsCli -Times 2 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'BOTH attempts fail -> the SAME max-2 cap (never a 3rd try), returns $false (non-fatal per this function''s own contract)' {
        Mock Invoke-TopazAwsCli {
            param($Arguments)
            $script:CallSeq.Add($Arguments[0])
            return $false
        }
        $cfg = Get-IncrementalTestConfig
        Invoke-TopazIncrementalUpload -Config $cfg -File $script:File | Should -Be $false
        $script:CallSeq | Should -Be @('copy', 'copy')
        Should -Invoke Invoke-TopazAwsCli -Times 2 -Exactly
    }

    It 'uses OutputDir -> UploadTarget directly (NOT a "/recovered" sub-path) -- the same destination the final sweep uses, so re-runs skip it' {
        Mock Invoke-TopazAwsCli {
            param($Arguments)
            $script:CallSeq.Add($Arguments -join ' ')
            return $true
        }
        $cfg = Get-IncrementalTestConfig
        [void] (Invoke-TopazIncrementalUpload -Config $cfg -File $script:File)
        ($script:CallSeq -join ' ') | Should -Match ([regex]::Escape('copy D:\Renders gdrive:temp'))
        ($script:CallSeq -join ' ') | Should -Not -Match 'recovered'
    }
}
