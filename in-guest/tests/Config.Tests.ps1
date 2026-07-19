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
}
