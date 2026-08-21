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

function Protect-RcloneConfigFile {
    <#
    .SYNOPSIS
        Restrict the OAuth-token file to SYSTEM and Administrators, then verify it.
    .DESCRIPTION
        This is intentionally called BEFORE any network verification. A failed
        `rclone about` or upload probe must not leave a newly-created refresh
        token readable through its inherited ACLs.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "rclone config '$Path' was not created or is not a file."
    }

    $allowedSids = @('S-1-5-18', 'S-1-5-32-544') # SYSTEM, BUILTIN\\Administrators
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) {
        [void]$acl.RemoveAccessRuleAll($rule)
    }

    foreach ($sid in $allowedSids) {
        $identity = New-Object System.Security.Principal.SecurityIdentifier($sid)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $identity, 'FullControl', 'None', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop

    $verifiedAcl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    if (-not $verifiedAcl.AreAccessRulesProtected) {
        throw "ACL verification failed: '$Path' still inherits access rules from its parent."
    }
    $verifiedRules = @($verifiedAcl.Access)
    if ($verifiedRules.Count -ne $allowedSids.Count) {
        throw "ACL verification failed: '$Path' must have exactly $($allowedSids.Count) access rules, found $($verifiedRules.Count)."
    }

    $verifiedSids = @()
    foreach ($rule in $verifiedRules) {
        $sid = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
        if ($allowedSids -notcontains $sid) {
            throw "ACL verification failed: unexpected identity $sid can access '$Path'."
        }
        if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow -or
            $rule.FileSystemRights -ne [System.Security.AccessControl.FileSystemRights]::FullControl -or
            $rule.InheritanceFlags -ne [System.Security.AccessControl.InheritanceFlags]::None -or
            $rule.PropagationFlags -ne [System.Security.AccessControl.PropagationFlags]::None) {
            throw "ACL verification failed: $sid must have an explicit Allow/FullControl rule on '$Path'."
        }
        $verifiedSids += $sid
    }
    foreach ($sid in $allowedSids) {
        if (($verifiedSids | Where-Object { $_ -eq $sid }).Count -ne 1) {
            throw "ACL verification failed: required identity $sid does not have exactly one rule on '$Path'."
        }
    }
}

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

# rclone config creates (or rewrites) the file above. Harden it immediately,
# before listremotes/about/probe failures can leave the refresh token exposed.
Protect-RcloneConfigFile -Path $configPath
Write-Output "  [PASS] locked '$configPath' down to SYSTEM + Administrators"

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
    Write-TopazLog -Component 'driveauth' -Level 'ERROR' -ErrorAction Continue `
        -Message "Drive auth FAILED: remote '${RemoteName}:' is not present in '$configPath' (found: $($remotes -join ', ')). Every later upload will fail until this is fixed."
    exit 1
}
Write-Output "  [PASS] remote '${RemoteName}:' exists"

# about = a real authenticated API call; fails clearly on a bad/expired token.
$about = & $rclone about "${RemoteName}:" --config $configPath 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Output "  [FAIL] could not query the Drive account (token bad or access denied):"
    $about | ForEach-Object { "         $_" }
    Write-TopazLog -Component 'driveauth' -Level 'ERROR' -ErrorAction Continue `
        -Message "Drive auth FAILED: 'rclone about ${RemoteName}:' returned exit $LASTEXITCODE -- the refresh token is bad, expired, or access was revoked."
    exit 1
}
Write-Output "  [PASS] authenticated to Google Drive:"
$about | ForEach-Object { "         $_" }

# Round-trip a tiny file into the ACTUAL upload target, so the destination
# path and write permission are proven, not assumed.
#
# try/finally, because every failure branch below exits: without it each
# `exit 1` (and every successful -VerifyOnly run) left another GUID-named
# directory under %TEMP% on the C: drive, which -- unlike the scratch volume
# -- is NOT wiped by a stop, so debugging Drive auth slowly littered the OS
# disk. `exit` inside a try still runs finally in Windows PowerShell 5.1, so
# this covers the exit paths as well as the fall-through.
$probeDir  = Join-Path $env:TEMP ("topaz-probe-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $probeDir -Force | Out-Null

try {
    $probeFile = Join-Path $probeDir 'topaz-upload-probe.txt'
    Set-Content -LiteralPath $probeFile -Value "topaz-autostop upload probe $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')" -Encoding UTF8

    & $rclone copy $probeDir $cfg.UploadTarget --config $configPath 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Output "  [FAIL] could not upload a probe file to '$($cfg.UploadTarget)'"
        Write-TopazLog -Component 'driveauth' -Level 'ERROR' -ErrorAction Continue `
            -Message "Drive auth FAILED: probe upload to '$($cfg.UploadTarget)' returned exit $LASTEXITCODE. The destination path or write permission is wrong."
        exit 1
    }
    Write-Output "  [PASS] probe file uploaded to '$($cfg.UploadTarget)'"

    & $rclone check $probeDir $cfg.UploadTarget --config $configPath --one-way 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Output "  [FAIL] probe uploaded but could not be VERIFIED at the destination"
        Write-TopazLog -Component 'driveauth' -Level 'ERROR' -ErrorAction Continue `
            -Message "Drive auth FAILED: probe uploaded to '$($cfg.UploadTarget)' but 'rclone check --one-way' returned exit $LASTEXITCODE, so the upload could not be verified."
        exit 1
    }
    Write-Output "  [PASS] probe verified at the destination"

    # Every other rclone call in this script checks its exit code; this one used
    # to pipe to Out-Null and then announce the removal unconditionally. A failed
    # delete (revoked scope, rate limit, transient 5xx) then left
    # topaz-upload-probe.txt sitting in the very folder every render is uploaded
    # to, while the operator was told it had been cleaned up -- the one line in a
    # script whose whole closing argument is that its outcome must be trustworthy
    # after the fact. A failure here does NOT exit 1: authentication is already
    # proven by this point, and a stray probe file is a tidiness problem.
    & $rclone delete "$($cfg.UploadTarget)/topaz-upload-probe.txt" --config $configPath 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Output "  [WARN] probe file could NOT be removed from '$($cfg.UploadTarget)' (rclone exit $LASTEXITCODE); delete 'topaz-upload-probe.txt' there manually."
        Write-TopazLog -Component 'driveauth' -Level 'WARN' -ErrorAction Continue `
            -Message "Drive auth: probe file 'topaz-upload-probe.txt' could NOT be deleted from '$($cfg.UploadTarget)' (rclone exit $LASTEXITCODE). Auth itself is proven; remove the stray file manually."
    }
    else {
        Write-Output "  [INFO] probe file removed from Drive"
    }
}
finally {
    # -ErrorAction SilentlyContinue: a failed cleanup must never mask the
    # verification result this script exists to report.
    if ($probeDir -and (Test-Path -LiteralPath $probeDir)) {
        Remove-Item -LiteralPath $probeDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Persist the outcome. Until now this script -- the one-time step that
# provisions the credential EVERY later automated upload depends on -- wrote
# nothing to any log file. A post-mortem asking "why did the 03:00 upload
# fail?" could not tell whether Drive auth had ever been set up on this boot,
# when it was last verified, or whether it had actually passed.
Write-TopazLog -Component 'driveauth' -Level 'INFO' `
    -Message "Drive auth VERIFIED: remote '${RemoteName}:' authenticated, probe file round-tripped and verified at '$($cfg.UploadTarget)', config at '$configPath'. Renders in '$($cfg.OutputDir)' can now be uploaded before a stop."

Write-Output ""
Write-Output "  Google Drive upload is ready. Renders in $($cfg.OutputDir) will be"
Write-Output "  uploaded to $($cfg.UploadTarget) and VERIFIED before the instance stops."
Write-Output ""
