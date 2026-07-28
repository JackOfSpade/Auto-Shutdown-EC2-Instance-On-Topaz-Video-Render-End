<#
.SYNOPSIS
    Installs the Topaz auto-stop pipeline onto this box. Idempotent.

.DESCRIPTION
    Copies the pipeline scripts from the repo checkout into InstallDir (from
    Config.ps1) and creates the log directory, so the repo does not need to stay
    on disk afterwards. Safe to re-run: it simply overwrites the installed copy.

    It does NOT register the scheduled tasks - that step needs an elevated shell
    and is left to Register-ScheduledTasks.ps1, which this script points you to.

    As a convenience it warns (without failing) when nvidia-smi.exe or aws.exe
    are not resolvable on PATH, since Push-GpuMetric.ps1 needs both.

.NOTES
    Target : Windows PowerShell 5.1 on Windows Server (EC2 GPU instance).
    Run from the repo's in-guest folder (this script's own directory).
#>

[CmdletBinding()]
param()

# --- Load shared config + logging ------------------------------------------
. "$PSScriptRoot\Config.ps1"
$cfg = Get-TopazAutoStopConfig

Write-TopazLog -Component 'install' -Level 'INFO' `
    -Message "Installing Topaz auto-stop pipeline into '$($cfg.InstallDir)'."

# ---------------------------------------------------------------------------
# 1. Ensure InstallDir + LogDir exist.
# ---------------------------------------------------------------------------

foreach ($dir in @($cfg.InstallDir, $cfg.LogDir)) {
    if (-not (Test-Path -LiteralPath $dir)) {
        try {
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
            Write-TopazLog -Component 'install' -Level 'INFO' `
                -Message "Created directory '$dir'."
        }
        catch {
            # WHY: directory creation is foundational -- every downstream step
            # (Copy-Item into InstallDir, Write-TopazLog itself needing
            # LogDir) depends on these existing. Logging success here on a
            # failure (e.g. Access denied when not elevated) would leave the
            # operator staring at confusing copy errors with no idea why.
            # Abort immediately instead.
            Write-TopazLog -Component 'install' -Level 'ERROR' `
                -Message "Failed to create directory '$dir': $($_.Exception.Message). Aborting install."
            exit 1
        }
    }
    else {
        Write-TopazLog -Component 'install' -Level 'INFO' `
            -Message "Directory '$dir' already exists."
    }
}

# ---------------------------------------------------------------------------
# 2. Copy pipeline scripts into InstallDir. The scheduled tasks run these
#    installed copies, so the repo checkout need not stay on disk afterwards.
# ---------------------------------------------------------------------------

$scripts = @(
    'Config.ps1',
    'Watchdog.ps1',
    'Stop-Sequence.ps1',
    'Push-GpuMetric.ps1',
    # Runs at every boot: the instance-store scratch drive comes back RAW after
    # each stop, and renders have nowhere to go until it is re-created.
    'Initialize-ScratchDisk.ps1'
)

# Operator tools: useful to have alongside the pipeline so InstallDir is
# self-contained (they dot-source Config.ps1 from their own directory), but
# the pipeline runs fine without them. A missing one is therefore a WARNING,
# not the hard install failure that a missing $scripts entry is.
$optionalScripts = @(
    'Register-TimedStop.ps1',
    'Test-Deployment.ps1',
    'Set-GoogleDriveAuth.ps1'
)

# Tracked separately from $warningCount below: a missing source or failed
# copy is a hard install failure (the pipeline cannot run without its
# scripts), whereas a missing dependency is advisory. Mixing the two into one
# counter would make a merely-advisory nvidia-smi/aws warning read as fatal,
# or worse, let a genuine copy failure hide behind "it's just a warning".
$errorCount = 0

foreach ($name in $scripts) {
    $src = Join-Path $PSScriptRoot $name
    if (-not (Test-Path -LiteralPath $src)) {
        Write-TopazLog -Component 'install' -Level 'ERROR' `
            -Message "Source script '$src' not found; cannot install it."
        $errorCount++
        continue
    }
    try {
        Copy-Item -LiteralPath $src -Destination $cfg.InstallDir -Force -ErrorAction Stop
        Write-TopazLog -Component 'install' -Level 'INFO' `
            -Message "Copied '$name' -> '$($cfg.InstallDir)'."
    }
    catch {
        # WHY: without this catch, a failed copy (locked file, permissions,
        # full disk) still logged 'Copied' - masking a stale/missing installed
        # script from anyone reading the log. Log the failure and move on to
        # the next file rather than aborting the whole install.
        Write-TopazLog -Component 'install' -Level 'ERROR' `
            -Message "Failed to copy '$name': $($_.Exception.Message)"
        $errorCount++
    }
}

# ---------------------------------------------------------------------------
# 3. Dependency sanity check (warn only; never fail the install).
# ---------------------------------------------------------------------------

# Counted separately from $errorCount -- these are advisory (the operator can
# still install nvidia-smi/aws later, before relying on the idle alarm), so
# they must never turn an otherwise-clean install into a reported failure.
$warningCount = 0

foreach ($name in $optionalScripts) {
    $src = Join-Path $PSScriptRoot $name
    if (-not (Test-Path -LiteralPath $src)) {
        Write-TopazLog -Component 'install' -Level 'WARN' `
            -Message "Optional operator tool '$name' not found in '$PSScriptRoot'; skipping it."
        $warningCount++
        continue
    }
    try {
        Copy-Item -LiteralPath $src -Destination $cfg.InstallDir -Force -ErrorAction Stop
        Write-TopazLog -Component 'install' -Level 'INFO' `
            -Message "Copied optional tool '$name' -> '$($cfg.InstallDir)'."
    }
    catch {
        Write-TopazLog -Component 'install' -Level 'WARN' `
            -Message "Failed to copy optional tool '$name': $($_.Exception.Message)"
        $warningCount++
    }
}

foreach ($tool in @('nvidia-smi.exe', 'aws.exe')) {
    if (Get-Command $tool -ErrorAction SilentlyContinue) {
        Write-TopazLog -Component 'install' -Level 'INFO' `
            -Message "Dependency '$tool' found on PATH."
    }
    else {
        # WHY per-tool wording: the two tools are NOT equally load-bearing for
        # the idle alarm any more. aws.exe absence breaks BOTH metrics
        # Push-GpuMetric.ps1 publishes -- RenderActive (the default
        # IDLE_SIGNAL=render signal) and GPUUtilization -- so the alarm has
        # nothing to watch on any IDLE_SIGNAL. nvidia-smi.exe absence only
        # costs the GPUUtilization metric (telemetry, plus the legacy
        # IDLE_SIGNAL=gpu); RenderActive comes from a CIM worker query and
        # does not touch nvidia-smi at all. A single shared message would
        # either understate aws.exe's impact or overstate nvidia-smi.exe's.
        $toolImpact = switch ($tool) {
            'aws.exe' { "Push-GpuMetric.ps1 needs it to publish EITHER metric (RenderActive or GPUUtilization); without it the idle alarm has nothing to watch, on any IDLE_SIGNAL." }
            'nvidia-smi.exe' { "Push-GpuMetric.ps1 needs it only for the GPUUtilization metric (telemetry, and the legacy IDLE_SIGNAL=gpu); the default IDLE_SIGNAL=render's RenderActive metric does not use it." }
            default { "Push-GpuMetric.ps1 needs it." }
        }
        Write-TopazLog -Component 'install' -Level 'WARN' `
            -Message "Dependency '$tool' NOT found on PATH. $toolImpact Install/add it before relying on the idle alarm."
        $warningCount++
    }
}

# ---------------------------------------------------------------------------
# 4. Next-step guidance.
# ---------------------------------------------------------------------------

if ($errorCount -eq 0) {
    $warningNote = if ($warningCount -gt 0) { " ($warningCount dependency warning(s) above - advisory only)" } else { '' }
    Write-TopazLog -Component 'install' -Level 'INFO' `
        -Message "Install complete.$warningNote NEXT STEP: run Register-ScheduledTasks.ps1 from an ELEVATED (Administrator) PowerShell to create the SYSTEM scheduled tasks."
}
else {
    Write-TopazLog -Component 'install' -Level 'ERROR' `
        -Message "Install completed with $errorCount error(s) - review the log above before proceeding."
    exit 1
}
