<#
.SYNOPSIS
    One-time interactive setup of the rclone Google Drive remote used to
    upload finished renders. Run this once, from a DCV session, as the
    operator. Verifies the result end to end.

.DESCRIPTION
    The render pipeline uploads via rclone, which speaks the Google Drive REST
    API directly -- no browser and no Google Drive desktop client are involved
    at run time. The single exception is THIS script: minting the OAuth
    refresh token requires one interactive consent in a browser. After that
    the token is stored and renews itself, and every subsequent upload is
    headless.

    WHY THE CONFIG PATH IS FORCED. The uploads run from a SYSTEM scheduled
    task. SYSTEM's %APPDATA% is C:\Windows\System32\config\systemprofile\...,
    which is NOT where an interactive `rclone config` would write its file.
    Left to default, this is the classic "it works when I run it by hand and
    fails from the scheduled task" trap. Both this script and
    Invoke-TopazRenderUpload therefore pass --config explicitly, pointing at
    Config.ps1's RcloneConfigPath.

    The config file holds a credential. It is written under InstallDir and
    this script tightens its ACL to SYSTEM + Administrators only.

.NOTES
    Run ELEVATED, from an interactive DCV session (a browser has to open).
    Target: Windows PowerShell 5.1.
#>

[CmdletBinding()]
param(
    # rclone remote name. Must match the prefix used in Config.ps1's
    # UploadTarget (e.g. UploadTarget 'gdrive:TopazRenders' -> 'gdrive').
    [string]$RemoteName = 'gdrive',

    # Only run the verification checks against an already-configured remote.
    [switch]$VerifyOnly
)

. "$PSScriptRoot\Config.ps1"
$cfg = Get-TopazAutoStopConfig

$rclone     = $cfg.RclonePath
$configPath = $cfg.RcloneConfigPath

if (-not (Test-Path -LiteralPath $rclone)) {
    throw "rclone not found at '$rclone'. Install it first, or fix RclonePath in Config.ps1."
}

$configDir = Split-Path -Parent $configPath
if (-not (Test-Path -LiteralPath $configDir)) {
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
}

# Derive the expected remote name from UploadTarget so a mismatch between the
# two is caught here rather than at 3am when the stop sequence runs.
$targetRemote = ($cfg.UploadTarget -split ':')[0]
if ($targetRemote -and $targetRemote -ne $RemoteName) {
    Write-Warning "Config.ps1's UploadTarget is '$($cfg.UploadTarget)', whose remote is '$targetRemote', but -RemoteName is '$RemoteName'. They must match or uploads will fail."
}

if (-not $VerifyOnly) {
    Write-Output ""
    Write-Output "  Google Drive authorisation"
    Write-Output "  --------------------------"
    Write-Output "  rclone config : $configPath"
    Write-Output "  remote name   : $RemoteName"
    Write-Output ""
    Write-Output "  An interactive rclone config session will now start. Answer:"
    Write-Output "    n                    (new remote)"
    Write-Output "    $RemoteName                 (name - must match exactly)"
    Write-Output "    drive                (storage type: Google Drive)"
    Write-Output "    <blank>              (client_id  - press Enter for rclone's default)"
    Write-Output "    <blank>              (client_secret - press Enter)"
    Write-Output "    1                    (scope: full access)"
    Write-Output "    <blank>              (service_account_file - press Enter)"
    Write-Output "    n                    (advanced config: No)"
    Write-Output "    y                    (use web browser to authenticate: Yes)"
    Write-Output "       -> a browser opens; sign in and grant access"
    Write-Output "    n                    (configure as Shared Drive: No, for a personal account)"
    Write-Output "    y                    (keep this remote)"
    Write-Output "    q                    (quit config)"
    Write-Output ""

    & $rclone config --config $configPath
}

# ---------------------------------------------------------------------------
# Verify. A remote that merely EXISTS is not proof it works, so actually touch
# the destination: list it, then round-trip a probe file.
# ---------------------------------------------------------------------------

Write-Output ""
Write-Output "  Verifying..."

$remotes = & $rclone listremotes --config $configPath 2>&1
if ($remotes -notcontains "${RemoteName}:") {
    Write-Output "  [FAIL] remote '${RemoteName}:' is not present in $configPath"
    Write-Output "         found: $($remotes -join ', ')"
    exit 1
}
Write-Output "  [PASS] remote '${RemoteName}:' exists"

# about = a real authenticated API call; fails clearly on a bad/expired token.
$about = & $rclone about "${RemoteName}:" --config $configPath 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Output "  [FAIL] could not query the Drive account (token bad or access denied):"
    $about | ForEach-Object { "         $_" }
    exit 1
}
Write-Output "  [PASS] authenticated to Google Drive:"
$about | ForEach-Object { "         $_" }

# Round-trip a tiny file into the ACTUAL upload target, so the destination
# path and write permission are proven, not assumed.
$probeDir  = Join-Path $env:TEMP ("topaz-probe-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $probeDir -Force | Out-Null
$probeFile = Join-Path $probeDir 'topaz-upload-probe.txt'
Set-Content -LiteralPath $probeFile -Value "topaz-autostop upload probe $(Get-Date -Format 's')" -Encoding UTF8

& $rclone copy $probeDir $cfg.UploadTarget --config $configPath 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Output "  [FAIL] could not upload a probe file to '$($cfg.UploadTarget)'"
    exit 1
}
Write-Output "  [PASS] probe file uploaded to '$($cfg.UploadTarget)'"

& $rclone check $probeDir $cfg.UploadTarget --config $configPath --one-way 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Output "  [FAIL] probe uploaded but could not be VERIFIED at the destination"
    exit 1
}
Write-Output "  [PASS] probe verified at the destination"

& $rclone delete "$($cfg.UploadTarget)/topaz-upload-probe.txt" --config $configPath 2>&1 | Out-Null
Write-Output "  [INFO] probe file removed from Drive"

# ---------------------------------------------------------------------------
# The config holds a refresh token. Restrict it to SYSTEM + Administrators.
# ---------------------------------------------------------------------------

try {
    $acl = Get-Acl -LiteralPath $configPath
    $acl.SetAccessRuleProtection($true, $false)   # drop inherited ACEs
    foreach ($who in @('NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators')) {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $who, 'FullControl', 'None', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $configPath -AclObject $acl
    Write-Output "  [PASS] locked '$configPath' down to SYSTEM + Administrators"
}
catch {
    Write-Output "  [WARN] could not tighten permissions on '$configPath': $($_.Exception.Message)"
}

Write-Output ""
Write-Output "  Google Drive upload is ready. Renders in $($cfg.OutputDir) will be"
Write-Output "  uploaded to $($cfg.UploadTarget) and VERIFIED before the instance stops."
Write-Output ""
