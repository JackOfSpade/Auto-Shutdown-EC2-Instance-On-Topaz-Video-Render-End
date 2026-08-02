<#
.SYNOPSIS
    Formats the EC2 instance-store NVMe as the render scratch drive and creates
    the output directory on it. Idempotent. Must run at every boot.

.DESCRIPTION
    A g6e.2xlarge ships with a local NVMe instance store (~419 GB on this
    instance). It is free, is far faster than gp3 EBS, and is easily large
    enough for the ~105 GB peak a 10-minute 4K DNxHR HQX export needs (the
    output, plus the full second copy Topaz's final mux pass writes).

    *** IT IS WIPED EVERY TIME THE INSTANCE STOPS. *** Not just on terminate --
    on stop, which is exactly what this project does automatically. It comes
    back RAW and unpartitioned on the next boot, which is why this script has
    to run at every startup rather than once at install time.

    Because renders land here, the stop sequence MUST NOT power the instance
    off until the upload of those renders has been verified. See
    Stop-Sequence.ps1's ephemeral interlock and Config.ps1's
    OutputIsEphemeral.

.NOTES
    *** THE DANGEROUS PART OF THIS SCRIPT IS DISK SELECTION. ***

    Formatting the wrong disk destroys the operating system. Selection is
    therefore deliberately paranoid, and every condition must hold:

      - BusType is NVMe
      - PartitionStyle is RAW (an already-formatted disk is never touched)
      - IsBoot is $false      <- the OS disk fails this
      - IsSystem is $false    <- the OS disk fails this
      - SerialNumber does NOT start with 'vol'  <- every EBS volume's serial
                                                   is its vol-xxxx id; the
                                                   instance store's is not
      - Size is within the expected instance-store range

    On top of that, if the filter matches anything other than EXACTLY ONE
    disk, this script refuses to act at all. Ambiguity is treated as a fault,
    never resolved by guessing.

    Target : Windows PowerShell 5.1 on Windows Server (EC2 GPU instance).
    Run elevated. Registered to run at startup by Register-ScheduledTasks.ps1.
#>

[CmdletBinding()]
param(
    # Set to skip the actual format and only report what WOULD happen.
    [switch]$WhatIfOnly,

    # Test/import seam for the pure existing-drive validation below. This is
    # intentionally undocumented for operators; scheduled tasks never pass it.
    # It lets Pester exercise the fail-closed predicate without loading Windows
    # storage cmdlets or touching a disk.
    [switch]$LibraryOnly
)

. "$PSScriptRoot\Config.ps1"
$cfg = Get-TopazAutoStopConfig

$driveLetter = $cfg.ScratchDriveLetter
$label       = $cfg.ScratchVolumeLabel
$outputDir   = $cfg.OutputDir

function Test-IsElevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ExistingScratchDriveValidation {
    <#
    .SYNOPSIS
        Pure: validates that an already-mounted scratch drive is the configured
        EC2 instance-store volume, rather than merely any formatted volume using
        the same drive letter.
    .DESCRIPTION
        Initialize-ScratchDisk.ps1 runs at every boot. The old early-return path
        accepted any formatted D: volume and then created OutputDir on it. A
        drive-letter collision with an EBS or data volume therefore silently
        changed what the rest of the pipeline treated as ephemeral scratch.

        This is intentionally stricter than a simple label check. It reuses
        Test-IsScratchDiskCandidate's fail-closed origin checks (NVMe,
        non-boot, non-system, non-EBS serial, known size in bounds). That helper
        normally rejects formatted disks because it is selecting a disk to
        FORMAT; here the disk is expected to be formatted already, so only its
        provenance portion is reused. The volume's filesystem, drive letter,
        label, and OutputDir root are independently checked here.

        Returns a reason-bearing object so the operational path can refuse with
        a precise remediation while tests can cover every branch without storage
        cmdlets.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Volume,
        [Parameter(Mandatory)]$Disk,
        [Parameter(Mandatory)][string]$DriveLetter,
        [Parameter(Mandatory)][string]$ExpectedLabel,
        [Parameter(Mandatory)][string]$OutputDir,
        [Parameter(Mandatory)][int64]$MinBytes,
        [Parameter(Mandatory)][int64]$MaxBytes
    )

    $letter = $DriveLetter.Trim().TrimEnd(':')
    if ($letter -notmatch '^[A-Za-z]$') {
        return [pscustomobject]@{ IsValid = $false; Reason = "ScratchDriveLetter '$DriveLetter' is not a single drive letter." }
    }

    # Do NOT use [System.IO.Path] here. The configuration deliberately carries
    # Windows paths, but Pester also runs this pure helper on Linux where .NET
    # treats 'D:\Renders' as an ordinary relative filename and returns no root.
    # Parse the only accepted shape explicitly, accepting either slash spelling
    # while requiring an anchored Windows drive root.
    $expectedRoot = "${letter}:\"
    $outputRootMatch = [regex]::Match($OutputDir, '^(?<drive>[A-Za-z]):[\\/]')
    if (-not $outputRootMatch.Success -or
        -not [string]::Equals($outputRootMatch.Groups['drive'].Value, $letter, [System.StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ IsValid = $false; Reason = "OutputDir '$OutputDir' is not rooted on configured scratch drive '$expectedRoot'." }
    }

    if ([string]::IsNullOrWhiteSpace([string]$Volume.DriveLetter) -or
        -not [string]::Equals(([string]$Volume.DriveLetter), $letter, [System.StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ IsValid = $false; Reason = "Mounted volume drive letter '$($Volume.DriveLetter)' does not match configured scratch drive '${letter}:'." }
    }

    if ([string]::IsNullOrWhiteSpace([string]$Volume.FileSystemType) -or $Volume.FileSystemType -eq 'Unknown') {
        return [pscustomobject]@{ IsValid = $false; Reason = "Mounted volume ${letter}: has no known filesystem." }
    }

    if (-not [string]::Equals(([string]$Volume.FileSystemLabel), $ExpectedLabel, [System.StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ IsValid = $false; Reason = "Mounted volume ${letter}: has label '$($Volume.FileSystemLabel)', expected '$ExpectedLabel'." }
    }

    # Pass HasFormattedVolume=$false ONLY because this helper validates a volume
    # that is already mounted. The shared predicate then supplies every
    # provenance check used before formatting, without incorrectly rejecting the
    # very filesystem this path is supposed to recognize.
    if (-not (Test-IsScratchDiskCandidate -Disk $Disk -MinBytes $MinBytes -MaxBytes $MaxBytes -HasFormattedVolume $false)) {
        return [pscustomobject]@{ IsValid = $false; Reason = "Backing disk $($Disk.Number) failed instance-store provenance checks (requires NVMe, non-boot, non-system, non-EBS serial, and configured size bounds)." }
    }

    return [pscustomobject]@{ IsValid = $true; Reason = $null }
}

if ($LibraryOnly) { return }

if (-not (Test-IsElevated)) {
    Write-TopazLog -Component 'scratch' -Level 'ERROR' `
        -Message "Must run ELEVATED to partition a disk. Aborting."
    throw "Initialize-ScratchDisk.ps1 requires elevation."
}

# ---------------------------------------------------------------------------
# Already done? Then this is a no-op. Runs at every boot, so it must be cheap
# and safe to re-enter.
# ---------------------------------------------------------------------------

$existing = Get-Volume -DriveLetter $driveLetter -ErrorAction SilentlyContinue
if ($existing -and $existing.FileSystemType -ne 'Unknown') {
    try {
        # Get-Volume tells us what is mounted at D:, but not whether D: belongs
        # to the expected instance-store disk. Resolve its partition and backing
        # disk before accepting the idempotent path; never format/relabel an
        # existing mismatch, even if its name happens to look familiar.
        $existingPartition = Get-Partition -DriveLetter $driveLetter -ErrorAction Stop
        $existingDisk = Get-Disk -Number $existingPartition.DiskNumber -ErrorAction Stop
    }
    catch {
        $message = "Could not resolve mounted ${driveLetter}: to its backing disk; refusing to treat it as scratch: $($_.Exception.Message)"
        Write-TopazLog -Component 'scratch' -Level 'ERROR' -Message $message
        throw "Initialize-ScratchDisk.ps1: $message"
    }

    $existingValidation = Get-ExistingScratchDriveValidation -Volume $existing -Disk $existingDisk `
        -DriveLetter $driveLetter -ExpectedLabel $label -OutputDir $outputDir `
        -MinBytes $cfg.ScratchMinBytes -MaxBytes $cfg.ScratchMaxBytes
    if (-not $existingValidation.IsValid) {
        $message = "Mounted ${driveLetter}: is NOT the configured instance-store scratch volume: $($existingValidation.Reason) Refusing to create '$outputDir', format, or relabel anything. Fix the drive-letter/label/config mismatch manually."
        Write-TopazLog -Component 'scratch' -Level 'ERROR' -Message $message
        throw "Initialize-ScratchDisk.ps1: $message"
    }

    # Re-assert OutputDir even when the volume already exists: this script is
    # the only thing that recreates it after a stop wipes the volume. This is
    # safe only after the label, path root, and backing-disk provenance checks
    # above confirmed it is the configured instance-store volume.
    if (-not (Test-Path -LiteralPath $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force -ErrorAction Stop | Out-Null
        Write-TopazLog -Component 'scratch' -Level 'INFO' `
            -Message "Created output directory '$outputDir' on existing ${driveLetter}:."
    }
    Write-TopazLog -Component 'scratch' -Level 'INFO' `
        -Message "Validated existing instance-store scratch drive ${driveLetter}: (Disk $($existingDisk.Number), label '$label', $([math]::Round($existing.SizeRemaining/1GB,1)) GiB free of $([math]::Round($existing.Size/1GB,1)) GiB). Nothing to do."
    return
}

# ---------------------------------------------------------------------------
# Select the instance-store disk. See the .NOTES block above -- every one of
# these conditions is load-bearing.
# ---------------------------------------------------------------------------

function Test-DiskHasFormattedVolume {
    <#
    .SYNOPSIS
        Does ANY partition on this disk carry a mountable filesystem? This is
        the decisive data-safety check behind Test-IsScratchDiskCandidate, so
        it fails CLOSED: any error is reported as $true ("assume it holds
        data"), which disqualifies the disk rather than risking its contents.
    #>
    param([Parameter(Mandatory)][uint32]$DiskNumber)

    try {
        $vols = @(Get-Partition -DiskNumber $DiskNumber -ErrorAction Stop |
            Get-Volume -ErrorAction SilentlyContinue |
            Where-Object { $_.FileSystemType -and $_.FileSystemType -ne 'Unknown' })
        return ($vols.Count -gt 0)
    }
    catch {
        # No partitions at all throws here on some builds -- that genuinely
        # means no filesystem. Distinguish it from a real failure.
        if ($_.Exception.Message -match 'No MSFT_Partition|ObjectNotFound') { return $false }
        Write-TopazLog -Component 'scratch' -Level 'WARN' `
            -Message "Could not enumerate volumes on disk $DiskNumber ($($_.Exception.Message)); treating it as holding data and EXCLUDING it."
        return $true
    }
}

$candidates = @(Get-Disk | Where-Object {
        Test-IsScratchDiskCandidate -Disk $_ `
            -MinBytes $cfg.ScratchMinBytes -MaxBytes $cfg.ScratchMaxBytes `
            -HasFormattedVolume (Test-DiskHasFormattedVolume -DiskNumber $_.Number)
    })

if ($candidates.Count -eq 0) {
    Write-TopazLog -Component 'scratch' -Level 'ERROR' `
        -Message "No instance-store disk found (NVMe + RAW + non-boot + non-system + non-EBS serial + size in range). The scratch drive will NOT exist, so renders written to '$outputDir' would land nowhere. Not formatting anything."
    throw "Initialize-ScratchDisk.ps1: no candidate instance-store disk."
}

if ($candidates.Count -gt 1) {
    # Refuse rather than guess. Picking wrong here destroys a disk.
    $desc = ($candidates | ForEach-Object { "Disk $($_.Number) ($([math]::Round($_.Size/1GB,1))GiB serial=$($_.SerialNumber))" }) -join '; '
    Write-TopazLog -Component 'scratch' -Level 'ERROR' `
        -Message "AMBIGUOUS: $($candidates.Count) disks matched the instance-store filter ($desc). Refusing to format any of them. Resolve manually."
    throw "Initialize-ScratchDisk.ps1: ambiguous disk selection ($($candidates.Count) matches)."
}

$disk = $candidates[0]

# Belt and braces: re-assert the two conditions whose failure is catastrophic,
# immediately before the destructive call. Cheap, and guards against the filter
# above being edited carelessly later.
if ($disk.IsBoot -or $disk.IsSystem) {
    throw "Initialize-ScratchDisk.ps1: REFUSING to format Disk $($disk.Number) - it is the boot/system disk."
}
if ($disk.SerialNumber -match '^vol') {
    throw "Initialize-ScratchDisk.ps1: REFUSING to format Disk $($disk.Number) - serial '$($disk.SerialNumber)' looks like an EBS volume id."
}

Write-TopazLog -Component 'scratch' -Level 'INFO' `
    -Message "Selected Disk $($disk.Number) ($([math]::Round($disk.Size/1GB,1)) GiB, serial=$($disk.SerialNumber)) as the instance-store scratch disk."

if ($WhatIfOnly) {
    Write-Output "WHAT-IF: would initialize Disk $($disk.Number) as GPT, create one full-size NTFS partition labelled '$label' as ${driveLetter}:, then create '$outputDir'."
    return
}

# ---------------------------------------------------------------------------
# Format. Only reached once the disk has passed every check above.
# ---------------------------------------------------------------------------

try {
    # RECOVER FROM A PARTIAL PROVISION. If a previous boot got part-way -- disk
    # initialized but New-Partition or Format-Volume then failed -- the disk is
    # left GPT with no usable filesystem. Initialize-Disk would fail on it
    # ("The disk has already been initialized"), and before Test-IsScratchDisk-
    # Candidate stopped keying on PartitionStyle it would never be selected
    # again either, bricking the scratch drive on every subsequent boot.
    #
    # Clear-Disk returns it to RAW. It is safe here ONLY because selection has
    # already established this disk carries no mountable filesystem; that check
    # fails closed, so a disk whose volumes could not even be enumerated was
    # excluded rather than cleared.
    if ($disk.PartitionStyle -ne 'RAW') {
        Write-TopazLog -Component 'scratch' -Level 'WARN' `
            -Message "Disk $($disk.Number) is $($disk.PartitionStyle), not RAW, but carries no mountable filesystem -- treating it as a partially provisioned scratch disk from an earlier failed run and clearing it."
        Clear-Disk -Number $disk.Number -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop
        $disk = Get-Disk -Number $disk.Number -ErrorAction Stop
    }

    Initialize-Disk -Number $disk.Number -PartitionStyle GPT -ErrorAction Stop

    $part = New-Partition -DiskNumber $disk.Number -UseMaximumSize -DriveLetter $driveLetter -ErrorAction Stop

    # -Full:$false = quick format. A full format would zero 419 GB and take a
    # long time at every single boot, delaying the point at which renders can
    # start, for no benefit on a volume that is wiped anyway.
    Format-Volume -Partition $part -FileSystem NTFS -NewFileSystemLabel $label `
        -Confirm:$false -Full:$false -ErrorAction Stop | Out-Null

    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

    $vol = Get-Volume -DriveLetter $driveLetter -ErrorAction Stop
    Write-TopazLog -Component 'scratch' -Level 'INFO' `
        -Message "Scratch drive ready: ${driveLetter}: '$label' $([math]::Round($vol.Size/1GB,1)) GiB, output directory '$outputDir' created (only this directory is uploaded)."

    Write-Output ""
    Write-Output "  Scratch drive ready"
    Write-Output "  -------------------"
    Write-Output "  Disk        : $($disk.Number) (instance store, serial $($disk.SerialNumber))"
    Write-Output "  Mounted as  : ${driveLetter}:  label '$label'"
    Write-Output "  Size        : $([math]::Round($vol.Size/1GB,1)) GiB"
    Write-Output "  Output dir  : $outputDir   (the ONLY thing uploaded to Drive)"
    Write-Output ""
    Write-Output "  Drop source footage anywhere else on ${driveLetter}: (the root is fine) -"
    Write-Output "  only $outputDir is uploaded, so sources are never sent to Drive."
    Write-Output ""
    Write-Output "  REMINDER: the ENTIRE volume is ERASED every time the instance stops,"
    Write-Output "  source footage included. Point Topaz's export location at $outputDir"
    Write-Output "  so finished renders are uploaded before that happens."
    Write-Output ""
}
catch {
    Write-TopazLog -Component 'scratch' -Level 'ERROR' `
        -Message "Failed to prepare the scratch disk: $($_.Exception.Message)"
    throw
}
