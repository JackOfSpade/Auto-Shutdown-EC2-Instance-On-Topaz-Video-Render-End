<#
.SYNOPSIS
    Unit tests for Initialize-ScratchDisk.ps1's fail-closed disk-safety seam:
    the existing-mounted-drive validation, the shared OutputDir root test, and
    Test-DiskHasFormattedVolume's error classification.

.DESCRIPTION
    These tests intentionally dot-source Initialize-ScratchDisk.ps1 with
    -LibraryOnly, so they exercise only the pure/validation functions and never
    call the real Get-Volume, Get-Partition, Get-Disk, format a volume, or
    require a Windows EC2 host.
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

Describe 'Test-TopazOutputDirRootedOnDrive' {
    # The root test the already-mounted path always applied, now shared with the
    # FORMAT path. Before it was shared, one configuration behaved two ways
    # depending on boot order: the boot after a stop formatted the scratch drive
    # and then created OutputDir on WHATEVER drive OutputDir named (the OS disk,
    # typically) while logging that it was on the volume that gets wiped; every
    # later boot threw instead.

    BeforeAll {
        $initializer = Join-Path $PSScriptRoot '..\Initialize-ScratchDisk.ps1'
        . $initializer -LibraryOnly
    }

    It 'accepts the configured shape' {
        Test-TopazOutputDirRootedOnDrive -OutputDir 'D:\Renders' -DriveLetter 'D' | Should -BeTrue
    }

    It 'accepts either slash spelling and either case' {
        Test-TopazOutputDirRootedOnDrive -OutputDir 'd:/Renders' -DriveLetter 'D' | Should -BeTrue
        Test-TopazOutputDirRootedOnDrive -OutputDir 'D:\Renders' -DriveLetter 'd' | Should -BeTrue
    }

    It "normalizes a ScratchDriveLetter written as 'D:' rather than 'D'" {
        Test-TopazOutputDirRootedOnDrive -OutputDir 'D:\Renders' -DriveLetter 'D:' | Should -BeTrue
        Test-TopazOutputDirRootedOnDrive -OutputDir 'D:\Renders' -DriveLetter ' D: ' | Should -BeTrue
    }

    It 'rejects an OutputDir rooted on another drive -- the OS disk being the dangerous case' {
        Test-TopazOutputDirRootedOnDrive -OutputDir 'C:\Renders' -DriveLetter 'D' | Should -BeFalse
    }

    It 'rejects anything that is not an anchored Windows drive root' {
        # [System.IO.Path] is deliberately not used here, so these must be
        # rejected by the regex itself and must behave identically on the Linux
        # CI runner and the Windows guest.
        foreach ($path in @('Renders', 'D:Renders', '\\server\share\Renders', '/Renders', '')) {
            Test-TopazOutputDirRootedOnDrive -OutputDir $path -DriveLetter 'D' |
                Should -BeFalse -Because "'$path' is not rooted at 'D:\'"
        }
    }

    It 'rejects a ScratchDriveLetter that is not a single letter' {
        foreach ($letter in @('', 'DD', '1', 'D:\')) {
            Test-TopazOutputDirRootedOnDrive -OutputDir 'D:\Renders' -DriveLetter $letter |
                Should -BeFalse -Because "'$letter' is not a drive letter"
        }
    }
}

Describe 'Test-DiskHasFormattedVolume' {
    # THE decisive data-safety check: its answer is what
    # Test-IsScratchDiskCandidate uses to decide whether a disk may be
    # formatted. Its entire contract is error CLASSIFICATION -- which failures
    # mean "no filesystem" and which mean "unknown, keep away" -- so both
    # directions are pinned here, especially the fail-CLOSED branch that
    # protects a disk whose volumes simply could not be read.
    #
    # Get-Partition/Get-Volume are Windows-only (the Storage module does not
    # exist on non-Windows pwsh), so they cannot be Pester-`Mock`ed -- Mock
    # requires the target command to already resolve. Plain function
    # definitions in this Describe's BeforeAll stand in for them, exactly the
    # pattern Config.Tests.ps1 and Watchdog.Tests.ps1 use for Get-CimInstance:
    # PowerShell resolves an unqualified name against Function: before Cmdlet:,
    # so the real, unmodified body under test picks them up.

    BeforeAll {
        $initializer = Join-Path $PSScriptRoot '..\Initialize-ScratchDisk.ps1'
        . $initializer -LibraryOnly

        function Get-Partition {
            # Deliberately shadows the built-in cmdlet name -- see this Describe
            # block's own comment above for why. Windows PowerShell 5.1
            # production code never defines this function (this file is
            # test-only), so there is no risk of the shadow leaking into the
            # real pipeline.
            [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '')]
            # [CmdletBinding()] makes -ErrorAction a common parameter PowerShell
            # supports automatically, as the real call passes -ErrorAction Stop.
            [CmdletBinding()]
            param([uint32]$DiskNumber)

            $script:PartitionDiskNumber = $DiskNumber

            if ($null -ne $script:PartitionThrow) { throw $script:PartitionThrow }
            return $script:PartitionResult
        }

        function Get-Volume {
            [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '')]
            [CmdletBinding()]
            param([Parameter(ValueFromPipeline = $true)]$Partition)

            process {
                # One volume per piped partition, keyed by the partition's own
                # index into the fixture -- the real cmdlet resolves each
                # partition to its volume the same way.
                if ($null -ne $Partition) { $script:VolumeResult[$Partition.Index] }
            }
        }

        function Get-PartitionNotFoundError {
            # Get-, not New-: PSUseShouldProcessForStateChangingFunctions (a
            # Warning that is NOT on ci.yml's allowlist) fires on a New- verb,
            # and this builder changes no state at all.
            <#
                Builds the ErrorRecord shape the CDXML Get-Partition raises for a
                disk with NO partitions -- the state a wiped instance store is in
                on EVERY boot-after-stop. Constructed rather than provoked so the
                three properties the classifier reads (category, id, message) can
                be varied independently.
            #>
            param(
                [System.Management.Automation.ErrorCategory]$Category = [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                [string]$ErrorId = 'CmdletizationQuery_NotFound_DiskNumber',
                [string]$Message = 'No MSFT_Partition objects found with property DiskNumber equal to 2.'
            )

            $exception = New-Object System.Management.Automation.ItemNotFoundException $Message
            return New-Object System.Management.Automation.ErrorRecord($exception, $ErrorId, $Category, $null)
        }
    }

    BeforeEach {
        Mock Write-TopazLog { param($Message, $Level) $script:ScratchLogLines.Add("$Level|$Message") }
        $script:ScratchLogLines   = New-Object System.Collections.Generic.List[string]
        $script:PartitionThrow    = $null
        $script:PartitionResult   = @()
        $script:VolumeResult      = @{}
        $script:PartitionDiskNumber = [uint32]0
    }

    It 'returns $true when any partition carries a mountable filesystem' {
        $script:PartitionResult = @([pscustomobject]@{ Index = 0 }, [pscustomobject]@{ Index = 1 })
        $script:VolumeResult = @{
            0 = [pscustomobject]@{ FileSystemType = 'Unknown' }
            1 = [pscustomobject]@{ FileSystemType = 'NTFS' }
        }

        Test-DiskHasFormattedVolume -DiskNumber 2 | Should -BeTrue
        $script:PartitionDiskNumber | Should -Be 2
    }

    It "returns `$false when every partition's filesystem is 'Unknown'" {
        $script:PartitionResult = @([pscustomobject]@{ Index = 0 })
        $script:VolumeResult = @{ 0 = [pscustomobject]@{ FileSystemType = 'Unknown' } }

        Test-DiskHasFormattedVolume -DiskNumber 2 | Should -BeFalse
    }

    It 'returns $false when the disk has no partitions at all (no throw)' {
        Test-DiskHasFormattedVolume -DiskNumber 2 | Should -BeFalse
    }

    It 'returns $false on an ObjectNotFound-category throw, and says WHICH predicate matched' {
        # The normal boot path for a freshly wiped instance store. Keyed on the
        # structured category, not on the English message, because Windows
        # localizes that text -- on a non-English AMI the old text-only
        # predicate excluded the instance store at every boot, leaving no
        # candidate disk, no D:\Renders, and every stop refused forever.
        $script:PartitionThrow = Get-PartitionNotFoundError -Message 'Es wurden keine MSFT_Partition-Objekte gefunden.'

        Test-DiskHasFormattedVolume -DiskNumber 2 | Should -BeFalse
        @($script:ScratchLogLines | Where-Object { $_ -like '*ErrorCategory=ObjectNotFound*' }).Count | Should -Be 1
    }

    It 'returns $false on the CDXML not-found error id even when the category is something else' {
        $script:PartitionThrow = Get-PartitionNotFoundError `
            -Category ([System.Management.Automation.ErrorCategory]::InvalidOperation) `
            -Message 'Es wurden keine MSFT_Partition-Objekte gefunden.'

        Test-DiskHasFormattedVolume -DiskNumber 2 | Should -BeFalse
        @($script:ScratchLogLines | Where-Object { $_ -like '*CmdletizationQuery_NotFound*' }).Count | Should -Be 1
    }

    It 'still honours the legacy English message, and labels it as the fragile predicate' {
        $script:PartitionThrow = Get-PartitionNotFoundError `
            -Category ([System.Management.Automation.ErrorCategory]::InvalidOperation) `
            -ErrorId 'SomethingElse'

        Test-DiskHasFormattedVolume -DiskNumber 2 | Should -BeFalse
        @($script:ScratchLogLines | Where-Object { $_ -like '*fragile legacy predicate*' }).Count | Should -Be 1
    }

    It 'FAILS CLOSED ($true, "assume it holds data") on any other error -- this is the branch that protects the OS disk' {
        $script:PartitionThrow = Get-PartitionNotFoundError `
            -Category ([System.Management.Automation.ErrorCategory]::PermissionDenied) `
            -ErrorId 'AccessDenied' -Message 'Access is denied.'

        Test-DiskHasFormattedVolume -DiskNumber 0 | Should -BeTrue
        @($script:ScratchLogLines | Where-Object { $_ -like '*EXCLUDING it*' }).Count | Should -Be 1
    }

    It 'does NOT widen to unrelated *NotFound* error ids -- a broad match would format a disk it could not read' {
        # The rejected alternative: '-match "NotFound"' on FullyQualifiedErrorId
        # would also swallow a PathNotFound/FileNotFound-shaped failure and call
        # the disk empty. That is the one misclassification that destroys data.
        $script:PartitionThrow = Get-PartitionNotFoundError `
            -Category ([System.Management.Automation.ErrorCategory]::InvalidOperation) `
            -ErrorId 'PathNotFound,Microsoft.PowerShell.Commands.GetItemCommand' `
            -Message 'Cannot find path.'

        Test-DiskHasFormattedVolume -DiskNumber 0 | Should -BeTrue
    }
}
