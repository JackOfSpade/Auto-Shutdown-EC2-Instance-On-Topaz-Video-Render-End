<#
.SYNOPSIS
    Best-effort artifact sync + notification, then powers the guest off so the
    EC2 instance STOPS.

.DESCRIPTION
    Invoked by Watchdog.ps1 once the Topaz render queue is complete or stalled.

    Because the instance's InstanceInitiatedShutdownBehavior is set to "stop"
    at the AWS level, a plain in-guest shutdown STOPS the instance - there is
    NO AWS API call and NO credentials involved in the stop itself. Optional
    steps that DO use the AWS CLI (S3 sync, SNS publish) run first and are
    strictly best-effort: a failure there must never block the power off.

    Order of operations:
        1. (optional) aws s3 sync OutputDir -> S3SyncTarget   (BEFORE power off,
           so finished artifacts are safe even if something later goes wrong).
        2. (optional) aws sns publish a "render complete/stalled" notification.
        3. If DryRun: log the decision and return WITHOUT powering off.
        4. Otherwise: Stop-Computer -Force  (guest shutdown => instance stop).

.PARAMETER Reason
    Why we are stopping: 'completed' (queue drained) or 'stalled' (a worker was
    alive but produced no output for too long).

.NOTES
    Target : Windows PowerShell 5.1 on Windows Server (EC2 GPU instance).
    Never uses the Topaz CLI. Never embeds AWS credentials.

    Deliberately NO in-guest Start-Job / Stop-EC2Instance fallback timer: such a
    job lives inside the very session being torn down and could never fire. The
    real out-of-band safety net is the CloudWatch idle alarm (fed by
    Push-GpuMetric.ps1).
#>

[CmdletBinding()]
param(
    [ValidateSet('completed', 'stalled')]
    [string]$Reason = 'completed'
)

# --- Load shared config + logging ------------------------------------------
. "$PSScriptRoot\Config.ps1"
$cfg = Get-TopazAutoStopConfig

Write-TopazLog -Component 'stop' -Level 'INFO' `
    -Message "Stop sequence invoked (reason=$Reason, dryRun=$($cfg.DryRun))."

# ---------------------------------------------------------------------------
# Best-effort: discover this instance's id + region (ONE IMDSv2 round trip)
# via the shared helper. The instance id is for nicer notifications; the
# region is REQUIRED by the AWS CLI calls below - the SYSTEM account has no
# default region configured anywhere in this pipeline, so without --region
# both `aws s3 sync` and `aws sns publish` fail client-side with
# NoRegionError every single time (silently, since it is only a WARN in a
# log nobody reads until after the box is off). Never let discovery block
# the stop.
# ---------------------------------------------------------------------------

$identity   = Get-Ec2Identity
$instanceId = $identity.InstanceId
if ([string]::IsNullOrWhiteSpace($instanceId)) { $instanceId = 'i-XXXXXXXXXXXXXXXXX' }

$region = $identity.Region
if ([string]::IsNullOrWhiteSpace($region)) {
    Write-TopazLog -Component 'stop' -Level 'WARN' `
        -Message "IMDSv2 region discovery failed; any S3 sync / SNS publish below will run without --region and may fail without a configured default region."
}

# ---------------------------------------------------------------------------
# 1. Optional S3 sync (runs BEFORE power off so artifacts are safe).
# ---------------------------------------------------------------------------

if (-not [string]::IsNullOrWhiteSpace($cfg.S3SyncTarget)) {
    Write-TopazLog -Component 'stop' -Level 'INFO' `
        -Message "Syncing '$($cfg.OutputDir)' -> '$($cfg.S3SyncTarget)' before power off."
    try {
        # Splat the arg list (rather than a long backtick-continued command) so
        # --region can be appended only when discovery succeeded, PS 5.1-clean.
        $syncArgs = @('s3', 'sync', $cfg.OutputDir, $cfg.S3SyncTarget, '--only-show-errors')
        if (-not [string]::IsNullOrWhiteSpace($region)) { $syncArgs += @('--region', $region) }
        $out = & aws @syncArgs 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-TopazLog -Component 'stop' -Level 'INFO' `
                -Message "S3 sync completed successfully."
        }
        else {
            Write-TopazLog -Component 'stop' -Level 'WARN' `
                -Message "S3 sync exited with code $LASTEXITCODE. Output: $out"
        }
    }
    catch {
        Write-TopazLog -Component 'stop' -Level 'WARN' `
            -Message "S3 sync failed (continuing to stop): $($_.Exception.Message)"
    }
}
else {
    Write-TopazLog -Component 'stop' -Level 'INFO' `
        -Message "No S3SyncTarget configured; skipping artifact sync."
}

# ---------------------------------------------------------------------------
# 2. Optional SNS notification (best-effort; never blocks the stop).
# ---------------------------------------------------------------------------

if (-not [string]::IsNullOrWhiteSpace($cfg.SnsTopicArn)) {
    # DryRun never powers off (see step 3 below), so the notification text
    # must not claim the box is stopping - that would be a false alarm to
    # whoever is subscribed to the topic.
    if ($cfg.DryRun) {
        $subject = "Topaz render $Reason - DRY RUN (no stop) - $instanceId"
        $message = "Topaz watchdog decided '$Reason' on instance $instanceId at $(Get-Date -Format 's'). DryRun is enabled, so the power-off was suppressed and the instance is still running."
    }
    else {
        $subject = "Topaz render $Reason - stopping $instanceId"
        $message = "Topaz render queue reported '$Reason' on instance $instanceId at $(Get-Date -Format 's'). The guest is powering off, which stops the EC2 instance."
    }

    Write-TopazLog -Component 'stop' -Level 'INFO' `
        -Message "Publishing SNS notification to '$($cfg.SnsTopicArn)'."
    try {
        # Splat the arg list (rather than a long backtick-continued command) so
        # --region can be appended only when discovery succeeded, PS 5.1-clean.
        $snsArgs = @('sns', 'publish', '--topic-arn', $cfg.SnsTopicArn, '--subject', $subject, '--message', $message)
        if (-not [string]::IsNullOrWhiteSpace($region)) { $snsArgs += @('--region', $region) }
        $out = & aws @snsArgs 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-TopazLog -Component 'stop' -Level 'INFO' `
                -Message "SNS notification published."
        }
        else {
            Write-TopazLog -Component 'stop' -Level 'WARN' `
                -Message "SNS publish exited with code $LASTEXITCODE. Output: $out"
        }
    }
    catch {
        Write-TopazLog -Component 'stop' -Level 'WARN' `
            -Message "SNS publish failed (continuing to stop): $($_.Exception.Message)"
    }
}
else {
    Write-TopazLog -Component 'stop' -Level 'INFO' `
        -Message "No SnsTopicArn configured; skipping notification."
}

# ---------------------------------------------------------------------------
# 3. Dry-run guard.
# ---------------------------------------------------------------------------

if ($cfg.DryRun) {
    Write-TopazLog -Component 'stop' -Level 'INFO' `
        -Message "DRY RUN - would stop now (reason=$Reason). No power off performed."
    return
}

# ---------------------------------------------------------------------------
# 4. Power off. Guest shutdown => EC2 instance STOP (no API call, no creds).
# ---------------------------------------------------------------------------

Write-TopazLog -Component 'stop' -Level 'INFO' `
    -Message "Powering off now (reason=$Reason). Guest shutdown will STOP the instance."

# Stop-Computer -Force is equivalent to `shutdown /s /t 0`.
Stop-Computer -Force
