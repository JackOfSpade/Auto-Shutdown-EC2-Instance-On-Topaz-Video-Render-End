<#
.SYNOPSIS
    Publishes current GPU utilization to CloudWatch as a custom metric.

.DESCRIPTION
    Runs once per minute as a SYSTEM scheduled task (see
    Register-ScheduledTasks.ps1). The out-of-band CloudWatch "instance idle"
    alarm feeds on this metric to stop the box if the in-guest watchdog ever
    fails to.

    Windows has no native CloudWatch collector for NVIDIA GPU utilization (the
    unified CloudWatch agent's NVIDIA support is Linux-only), so we shell out to
    nvidia-smi and publish the value with the AWS CLI.

    The metric is dimensioned by InstanceId (discovered via IMDSv2) and pushed
    into the region derived from the instance's availability zone.

    Every external call (nvidia-smi, IMDS, aws) is wrapped in try/catch. The
    script ALWAYS exits 0 so the scheduled task never error-spams; a bad read
    simply publishes nothing that minute.

.NOTES
    Target : Windows PowerShell 5.1 on Windows Server (EC2 GPU instance).
    Requires nvidia-smi.exe and aws.exe on PATH (Install.ps1 warns if missing).
    Never uses the Topaz CLI. Never embeds AWS credentials.
#>

[CmdletBinding()]
param()

# --- Load shared config + logging ------------------------------------------
. "$PSScriptRoot\Config.ps1"
$cfg = Get-TopazAutoStopConfig

# ---------------------------------------------------------------------------
# 1. Read GPU utilization via nvidia-smi (first GPU line).
# ---------------------------------------------------------------------------

$util = $null
try {
    $raw = & nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "nvidia-smi exited with code $LASTEXITCODE. Output: $raw"
    }

    # Take the first non-empty line, trim, cast to int.
    $firstLine = @($raw | Where-Object { "$_".Trim() -ne '' })[0]
    if ($null -eq $firstLine) {
        throw "nvidia-smi returned no utilization value."
    }
    $util = [int]("$firstLine".Trim())
}
catch {
    Write-TopazLog -Component 'metric' -Level 'ERROR' `
        -Message "Failed to read GPU utilization: $($_.Exception.Message). Publishing nothing this cycle."
    exit 0
}

# ---------------------------------------------------------------------------
# 2. IMDSv2: instance-id + availability zone -> region.
# ---------------------------------------------------------------------------

$instanceId = $null
$region     = $null
try {
    $token = Invoke-RestMethod -Method Put `
        -Uri 'http://169.254.169.254/latest/api/token' `
        -Headers @{ 'X-aws-ec2-metadata-token-ttl-seconds' = '60' } `
        -TimeoutSec 3 -ErrorAction Stop

    $imdsHeaders = @{ 'X-aws-ec2-metadata-token' = $token }

    $instanceId = ("$(Invoke-RestMethod -Method Get `
        -Uri 'http://169.254.169.254/latest/meta-data/instance-id' `
        -Headers $imdsHeaders -TimeoutSec 3 -ErrorAction Stop)").Trim()

    $az = ("$(Invoke-RestMethod -Method Get `
        -Uri 'http://169.254.169.254/latest/meta-data/placement/availability-zone' `
        -Headers $imdsHeaders -TimeoutSec 3 -ErrorAction Stop)").Trim()

    # Region = AZ with the trailing zone letter stripped (e.g. us-east-1a -> us-east-1).
    $region = $az -replace '[a-z]$', ''
}
catch {
    Write-TopazLog -Component 'metric' -Level 'ERROR' `
        -Message "IMDSv2 lookup failed: $($_.Exception.Message). Publishing nothing this cycle."
    exit 0
}

if ([string]::IsNullOrWhiteSpace($instanceId) -or [string]::IsNullOrWhiteSpace($region)) {
    Write-TopazLog -Component 'metric' -Level 'ERROR' `
        -Message "IMDSv2 returned empty instance-id or region. Publishing nothing this cycle."
    exit 0
}

# ---------------------------------------------------------------------------
# 3. Publish the metric via the AWS CLI.
# ---------------------------------------------------------------------------

try {
    $out = & aws cloudwatch put-metric-data `
        --region $region `
        --namespace $cfg.MetricNamespace `
        --metric-name $cfg.MetricName `
        --unit Percent `
        --value $util `
        --dimensions "InstanceId=$instanceId" 2>&1

    if ($LASTEXITCODE -eq 0) {
        Write-TopazLog -Component 'metric' -Level 'INFO' `
            -Message "Published $($cfg.MetricNamespace)/$($cfg.MetricName)=$util% for $instanceId in $region."
    }
    else {
        Write-TopazLog -Component 'metric' -Level 'WARN' `
            -Message "aws put-metric-data exited with code $LASTEXITCODE. Output: $out"
    }
}
catch {
    Write-TopazLog -Component 'metric' -Level 'WARN' `
        -Message "Failed to publish metric: $($_.Exception.Message)"
}

# Scheduled task must never error-spam; always succeed.
exit 0
