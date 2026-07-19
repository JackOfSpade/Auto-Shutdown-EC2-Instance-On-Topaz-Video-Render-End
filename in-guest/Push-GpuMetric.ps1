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

    The published value is the MAXIMUM utilization across all GPUs (via the
    shared Get-GpuUtilizationMax helper), so a multi-GPU instance where Topaz
    loads a single GPU is not misreported as idle. The metric is dimensioned by
    InstanceId and pushed into the region, both discovered via IMDSv2 (shared
    Get-Ec2Identity helper - uses placement/region, correct for all zone types).

    Every external call (nvidia-smi, IMDS, aws) is wrapped so that a failure
    publishes nothing that minute. The script ALWAYS exits 0 so the scheduled
    task never error-spams.

.NOTES
    Target : Windows PowerShell 5.1 on Windows Server (EC2 GPU instance).
    Requires nvidia-smi.exe and aws.exe on PATH (Install.ps1 warns if missing).
    Never uses the Topaz CLI. Never embeds AWS credentials.
#>

[CmdletBinding()]
param()

# --- Load shared config + helpers ------------------------------------------
. "$PSScriptRoot\Config.ps1"
$cfg = Get-TopazAutoStopConfig

# ---------------------------------------------------------------------------
# 1. Read GPU utilization (max across all GPUs) via the shared helper.
# ---------------------------------------------------------------------------

$util = Get-GpuUtilizationMax
if ($null -eq $util) {
    Write-TopazLog -Component 'metric' -Level 'ERROR' `
        -Message "Failed to read GPU utilization. Publishing nothing this cycle."
    exit 0
}

# ---------------------------------------------------------------------------
# 2. IMDSv2: instance-id + region via the shared helper.
# ---------------------------------------------------------------------------

$identity   = Get-Ec2Identity
$instanceId = $identity.InstanceId
$region     = $identity.Region

if ([string]::IsNullOrWhiteSpace($instanceId) -or [string]::IsNullOrWhiteSpace($region)) {
    Write-TopazLog -Component 'metric' -Level 'ERROR' `
        -Message "IMDSv2 returned empty instance-id or region. Publishing nothing this cycle."
    exit 0
}

# ---------------------------------------------------------------------------
# 3. Publish the metric via the AWS CLI.
# ---------------------------------------------------------------------------

$metricArgs = Build-AwsCliArgs -Base @(
    'cloudwatch', 'put-metric-data',
    '--namespace', $cfg.MetricNamespace,
    '--metric-name', $cfg.MetricName,
    '--unit', 'Percent',
    '--value', $util,
    '--dimensions', "InstanceId=$instanceId"
) -Region $region

[void] (Invoke-TopazAwsCli -Arguments $metricArgs -TimeoutSec $cfg.AwsCliTimeoutSec `
    -Component 'metric' `
    -SuccessMessage "Published $($cfg.MetricNamespace)/$($cfg.MetricName)=$util% for $instanceId in $region." `
    -FailureVerb 'aws put-metric-data')

# Scheduled task must never error-spam; always succeed.
exit 0
