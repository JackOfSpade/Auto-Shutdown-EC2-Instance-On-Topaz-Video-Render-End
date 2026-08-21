<#
.SYNOPSIS
    Publishes the two safety-net metrics to CloudWatch: whether an encoder
    worker is running, and current GPU utilization.

.DESCRIPTION
    Runs once per minute as a SYSTEM scheduled task (see
    Register-ScheduledTasks.ps1). The out-of-band CloudWatch "instance idle"
    alarm feeds on these to stop the box if the in-guest watchdog ever fails to.

    TWO METRICS, AND WHICH ONE THE ALARM USES:

    * RenderActive (1/0) -- THE ALARM SIGNAL. 1 when at least one encoder
      worker process is alive. See Test-RenderWorkerPresent in Config.ps1 for
      why this is matched loosely and statelessly rather than reusing the
      watchdog's own ancestry-based worker detection.

    * GPUUtilization (%) -- TELEMETRY ONLY, and no longer safe to alarm on.
      MEASURED 2026-07-27: a confirmed-healthy 4K render sat under 5% for 25
      consecutive minutes, five short of the old alarm's 30-minute breach
      window (docs/15); and a connected DCV session holds the same GPU at
      14-58% with nothing rendering (docs/12). Wrong in both directions. It is
      still published because it remains genuinely useful for reading a run
      back afterwards -- it is what showed the 25-minute streak in the first
      place -- but control-plane/03-create-idle-alarm.sh now defaults to
      RenderActive.

    Windows has no native CloudWatch collector for NVIDIA GPU utilization (the
    unified CloudWatch agent's NVIDIA support is Linux-only), so we shell out to
    nvidia-smi and publish the value with the AWS CLI. The published value is
    the MAXIMUM utilization across all GPUs (via the shared Get-GpuUtilizationMax
    helper), so a multi-GPU instance where Topaz loads a single GPU is not
    misreported as idle. Both metrics are dimensioned by InstanceId and pushed
    into the region, discovered via IMDSv2 (shared Get-Ec2Identity helper - uses
    placement/region, correct for all zone types).

    THE TWO METRICS FAIL INDEPENDENTLY. Each is read and published on its own,
    so one broken reader cannot silence the other. That is not cosmetic: this
    script previously returned early when nvidia-smi failed, which -- once the
    alarm keys on RenderActive -- would have let a broken GPU reader take down
    the alarm's only signal and quietly disarm the safety net.

    Every external call (nvidia-smi, CIM, IMDS, aws) is wrapped so that a
    failure publishes nothing FOR THAT METRIC that minute. Publishing nothing is
    deliberate over publishing a guess: the alarm's treat-missing-data
    notBreaching then holds its state rather than counting an unreadable minute
    as an idle one. The script ALWAYS exits 0 so the scheduled task never
    error-spams.

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
# 1. Read both signals. Neither read may abort the other -- see the header note
#    on independent failure. $null from either means "unknown this cycle".
#
#    RenderActive is read FIRST, for the same reason it is published first
#    (see step 3): it is the metric the alarm evaluates. Get-GpuUtilizationMax
#    spawns nvidia-smi and is allowed to burn its full bounded wait (15s, see
#    Config.ps1) before returning -- on a box with a wedged GPU driver, which
#    is precisely the case that bound exists for, reading it first delayed the
#    alarm's ONLY signal by that much in every one-minute cycle, purely to
#    fetch a metric the header above documents as telemetry only. The two
#    reads share no state, so the order is free to fix.
# ---------------------------------------------------------------------------

$workerPresent = Test-RenderWorkerPresent -WorkerNamesLike $cfg.WorkerNamesLike
if ($null -eq $workerPresent) {
    # Louder than the GPU failure on purpose: this is the metric the idle alarm
    # actually keys on, so an unreadable worker query is the safety net going
    # blind, not just a gap in telemetry.
    Write-TopazLog -Component 'metric' -Level 'ERROR' `
        -Message "Worker-presence query FAILED; publishing no $($cfg.RenderActiveMetricName) this cycle. The idle alarm has no fresh datapoint to evaluate."
}

$util = Get-GpuUtilizationMax
if ($null -eq $util) {
    Write-TopazLog -Component 'metric' -Level 'ERROR' `
        -Message "Failed to read GPU utilization. Publishing no $($cfg.MetricName) this cycle."
}

if ($null -eq $util -and $null -eq $workerPresent) {
    Write-TopazLog -Component 'metric' -Level 'ERROR' `
        -Message "Both signals unreadable. Publishing nothing this cycle."
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
# 3. Publish each available metric via the AWS CLI.
#
#    Two calls rather than one batched --metric-data payload: the shorthand for
#    a multi-metric batch is markedly more fragile to build, and separate calls
#    mean one metric failing to publish does not take the other with it. Each is
#    bounded by AwsCliTimeoutSec independently.
# ---------------------------------------------------------------------------

# RenderActive first: it is the metric the alarm evaluates, so if this minute is
# going to be slow enough that only one call lands, it should be this one.
if ($null -ne $workerPresent) {
    $activeValue = if ($workerPresent) { 1 } else { 0 }

    $activeArgs = Build-AwsCliArgs -Base @(
        'cloudwatch', 'put-metric-data',
        '--namespace', $cfg.MetricNamespace,
        '--metric-name', $cfg.RenderActiveMetricName,
        '--unit', 'None',
        '--value', $activeValue,
        '--dimensions', "InstanceId=$instanceId"
    ) -Region $region

    [void] (Invoke-TopazAwsCli -Arguments $activeArgs -TimeoutSec $cfg.AwsCliTimeoutSec `
        -Component 'metric' `
        -SuccessMessage "Published $($cfg.MetricNamespace)/$($cfg.RenderActiveMetricName)=$activeValue (worker present=$workerPresent) for $instanceId in $region." `
        -FailureVerb 'aws put-metric-data')
}

if ($null -ne $util) {
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
}

# Scheduled task must never error-spam; always succeed.
exit 0
