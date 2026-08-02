<#
.SYNOPSIS
    Unit tests for the existing-mounted-scratch-drive validation seam.

.DESCRIPTION
    These tests intentionally dot-source Initialize-ScratchDisk.ps1 with
    -LibraryOnly, so they exercise only the pure validation function and never
    call Get-Volume, Get-Partition, Get-Disk, format a volume, or require a
    Windows EC2 host.
#>

Describe 'Get-ExistingScratchDriveValidation' {
    BeforeAll {
        $initializer = Join-Path $PSScriptRoot '..\Initialize-ScratchDisk.ps1'
        . $initializer -LibraryOnly

        function Get-TestExistingVolume {
            param(
                [string]$DriveLetter = 'D',
                [string]$FileSystemType = 'NTFS',
                [string]$FileSystemLabel = 'RenderScratch'
            )

            [pscustomobject]@{
                DriveLetter = $DriveLetter
                FileSystemType = $FileSystemType
                FileSystemLabel = $FileSystemLabel
            }
        }

        function Get-TestExistingDisk {
            param(
                [string]$BusType = 'NVMe',
                $IsBoot = $false,
                $IsSystem = $false,
                [string]$SerialNumber = '4EDC_1323_0B3C_92CC',
                $Size = 450GB,
                [uint32]$Number = 2
            )

            [pscustomobject]@{
                BusType = $BusType
                IsBoot = $IsBoot
                IsSystem = $IsSystem
                SerialNumber = $SerialNumber
                Size = $Size
                Number = $Number
            }
        }

        function Test-Validation {
            param(
                $Volume = (Get-TestExistingVolume),
                $Disk = (Get-TestExistingDisk),
                [string]$DriveLetter = 'D',
                [string]$ExpectedLabel = 'RenderScratch',
                [string]$OutputDir = 'D:\Renders'
            )

            Get-ExistingScratchDriveValidation -Volume $Volume -Disk $Disk `
                -DriveLetter $DriveLetter -ExpectedLabel $ExpectedLabel -OutputDir $OutputDir `
                -MinBytes ([int64]300GB) -MaxBytes ([int64]600GB)
        }
    }

    It 'accepts a labelled, mounted instance-store volume on the configured drive' {
        (Test-Validation).IsValid | Should -BeTrue
    }

    It 'accepts drive letters and labels case-insensitively with forward-slash Windows paths' {
        (Test-Validation -Volume (Get-TestExistingVolume -DriveLetter 'd' -FileSystemLabel 'renderscratch') `
            -DriveLetter 'D' -ExpectedLabel 'RenderScratch' -OutputDir 'd:/Renders').IsValid | Should -BeTrue
    }

    It 'rejects an OutputDir rooted on another drive before creating it' {
        $result = Test-Validation -OutputDir 'E:\Renders'
        $result.IsValid | Should -BeFalse
        $result.Reason | Should -Match 'not rooted'
    }

    It 'rejects a mounted volume whose label does not identify the configured scratch volume' {
        $result = Test-Validation -Volume (Get-TestExistingVolume -FileSystemLabel 'Data')
        $result.IsValid | Should -BeFalse
        $result.Reason | Should -Match 'expected'
    }

    It 'rejects a volume without a known filesystem' {
        (Test-Validation -Volume (Get-TestExistingVolume -FileSystemType 'Unknown')).IsValid | Should -BeFalse
    }

    It 'rejects a backing boot/system disk or one with untrusted provenance' {
        foreach ($disk in @(
            (Get-TestExistingDisk -IsBoot $true),
            (Get-TestExistingDisk -IsSystem $true),
            (Get-TestExistingDisk -SerialNumber 'vol0abc123'),
            (Get-TestExistingDisk -SerialNumber ''),
            (Get-TestExistingDisk -BusType 'SATA'),
            (Get-TestExistingDisk -Size 100GB),
            (Get-TestExistingDisk -Size 900GB)
        )) {
            (Test-Validation -Disk $disk).IsValid | Should -BeFalse
        }
    }

    It 'fails closed when the backing disk has unreadable boot/system flags' {
        (Test-Validation -Disk (Get-TestExistingDisk -IsBoot $null)).IsValid | Should -BeFalse
        (Test-Validation -Disk (Get-TestExistingDisk -IsSystem $null)).IsValid | Should -BeFalse
    }
}
