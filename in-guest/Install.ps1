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
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-TopazLog -Component 'install' -Level 'INFO' `
            -Message "Created directory '$dir'."
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
    'Push-GpuMetric.ps1'
)

foreach ($name in $scripts) {
    $src = Join-Path $PSScriptRoot $name
    if (-not (Test-Path -LiteralPath $src)) {
        Write-TopazLog -Component 'install' -Level 'ERROR' `
            -Message "Source script '$src' not found; cannot install it."
        continue
    }
    Copy-Item -LiteralPath $src -Destination $cfg.InstallDir -Force
    Write-TopazLog -Component 'install' -Level 'INFO' `
        -Message "Copied '$name' -> '$($cfg.InstallDir)'."
}

# ---------------------------------------------------------------------------
# 3. Dependency sanity check (warn only; never fail the install).
# ---------------------------------------------------------------------------

foreach ($tool in @('nvidia-smi.exe', 'aws.exe')) {
    if (Get-Command $tool -ErrorAction SilentlyContinue) {
        Write-TopazLog -Component 'install' -Level 'INFO' `
            -Message "Dependency '$tool' found on PATH."
    }
    else {
        Write-TopazLog -Component 'install' -Level 'WARN' `
            -Message "Dependency '$tool' NOT found on PATH. Push-GpuMetric.ps1 needs it; install/add it before relying on the idle alarm."
    }
}

# ---------------------------------------------------------------------------
# 4. Next-step guidance.
# ---------------------------------------------------------------------------

Write-TopazLog -Component 'install' -Level 'INFO' `
    -Message "Install complete. NEXT STEP: run Register-ScheduledTasks.ps1 from an ELEVATED (Administrator) PowerShell to create the SYSTEM scheduled tasks."
