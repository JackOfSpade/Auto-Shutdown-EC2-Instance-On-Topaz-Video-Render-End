<#
.SYNOPSIS
    Best-effort artifact sync + notification, then powers the guest off so the
    EC2 instance STOPS.

.DESCRIPTION
    Invoked by Watchdog.ps1 once the Topaz render queue is complete or stalled.

    The configured StopStrategy normally calls ec2:StopInstances against this
    instance first, then can fall back to a guest shutdown. Optional AWS CLI
    work (S3 sync and SNS) runs before the stop action and is best-effort; the
    verified Google Drive upload is the exception when OutputDir is ephemeral.

    Order of operations:
        1. (optional) aws s3 sync OutputDir -> S3SyncTarget.
        2. Upload and verify OutputDir with rclone; this blocks an ephemeral stop.
        3. (optional) aws sns publish a notification.
        4. If effective DryRun: log the decision and return WITHOUT powering off.
        5. Otherwise follow StopStrategy (EC2 API stop, guest shutdown, or both).

    THE WHOLE BODY LIVES IN Invoke-TopazStopSequence, and the script's own tail
    is three lines. That is a test seam, not decoration: this file is the
    highest-consequence decision path in the repo -- it encodes the refusals
    that keep an un-uploaded render alive -- and while it was straight-line
    top-level code, nothing could load it without executing a real stop
    attempt, so not one of its ORDERING invariants was covered. See
    in-guest/tests/Stop-Sequence.Tests.ps1, which dot-sources this file with
    -LibraryOnly (the same seam Initialize-ScratchDisk.ps1 uses) and pins them.

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
    [ValidateSet('completed', 'stalled', 'maxlifetime')]
    [string]$Reason = 'completed',

    # Overrides Config.ps1's DryRun for THIS invocation only. Exists for the
    # timed hard-stop task (see Register-TimedStop.ps1), whose entire purpose
    # is to stop the box on a wall clock regardless of what the watchdog is
    # doing -- while the watchdog itself stays in DryRun. Never set this from
    # the watchdog path.
    [switch]$IgnoreDryRun,

    # Translate a REFUSED stop into exit code 2 (and a performed/suppressed one
    # into 0) instead of only returning $false.
    #
    # OPT-IN, and deliberately NOT keyed on how the script was invoked. Under
    # Task Scheduler's `powershell.exe -File`, a `return $false` is only an
    # object on stdout: the host prints 'False' and exits 0, so a refused
    # wall-clock backstop showed LastTaskResult=0 -- the exit code
    # Register-TimedStop.ps1's .NOTES tells the operator to inspect. Keying the
    # exit on $MyInvocation instead would ALSO fire on Watchdog.ps1's
    # `& (Join-Path $PSScriptRoot 'Stop-Sequence.ps1')` call, whose result then
    # becomes $null rather than $false -- and Watchdog.ps1 tests
    # `$stopResult -eq $false` to decide whether to re-arm, so the retry path
    # that keeps an un-uploaded render recoverable would silently stop running.
    # Only Register-TimedStop.ps1's action string passes this switch.
    [switch]$ExitCodeOnRefusal,

    # Test/import seam: dot-source this file to get its functions WITHOUT
    # attempting a stop (no config load, no IMDS round trip, no stop.log
    # lines). Scheduled tasks and the watchdog never pass it.
    [switch]$LibraryOnly
)

# --- Load shared config + logging ------------------------------------------
. "$PSScriptRoot\Config.ps1"

function Resolve-EphemeralUploadRefusal {
    <#
    .SYNOPSIS
        Pure: does the EPHEMERAL INTERLOCK refuse this stop?
    .DESCRIPTION
        Everything else in this script is best-effort by design: a failed S3
        sync or SNS publish must never stop the box from powering off. This
        decision is the one exception, and the reason is asymmetry.

        When OutputDir sits on the instance-store scratch drive
        (OutputIsEphemeral), the volume is ERASED the instant the instance
        stops. If the upload has not succeeded by then, a multi-hour render is
        destroyed with no copy anywhere -- no local file, no snapshot, no
        recycle bin. Against that, the cost of NOT stopping is a few dollars of
        idle instance time, and the render stays recoverable: fix the upload,
        re-run it, stop the box.

        Pure, because this is the decision whose failure produced the incident
        in docs/16-render-loss-incident.md and it must be pinnable by a test
        that neither runs rclone nor powers anything off. The caller owns the
        (long, deliberately specific) log wording for each refusal; this
        function owns only the branch.
    .PARAMETER UploadTarget
        $cfg.UploadTarget. Empty/whitespace means no upload was configured.
    .PARAMETER OutputIsEphemeral
        $cfg.OutputIsEphemeral -- whether OutputDir is erased by the stop.
    .PARAMETER UploadSucceeded
        $null when no upload was attempted, otherwise Invoke-TopazRenderUpload's
        [bool] result.
    .OUTPUTS
        [pscustomobject]@{ ShouldStop = [bool]; RefusalReason = [string] }
        RefusalReason is $null when ShouldStop is $true, otherwise
        'NoUploadTarget' or 'UploadFailed'.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$UploadTarget,
        [bool]$OutputIsEphemeral,
        $UploadSucceeded = $null
    )

    if (-not $OutputIsEphemeral) {
        # Persistent output: a failed or absent upload costs a copy, not the
        # render itself, so it stays best-effort exactly as before.
        return [pscustomobject]@{ ShouldStop = $true; RefusalReason = $null }
    }

    if ([string]::IsNullOrWhiteSpace($UploadTarget)) {
        return [pscustomobject]@{ ShouldStop = $false; RefusalReason = 'NoUploadTarget' }
    }

    if ($UploadSucceeded -eq $false) {
        return [pscustomobject]@{ ShouldStop = $false; RefusalReason = 'UploadFailed' }
    }

    return [pscustomobject]@{ ShouldStop = $true; RefusalReason = $null }
}

function Invoke-TopazStopSequence {
    <#
    .SYNOPSIS
        Runs the whole stop sequence. Returns $false if the stop was REFUSED or
        never took effect, $true if it was performed or deliberately suppressed
        by DryRun.
    .DESCRIPTION
        THE ORDER OF THE STEPS BELOW IS THE SAFETY PROPERTY. In particular the
        ephemeral interlock runs before the completed-stop safety gate, and both
        run before the SNS publish and before the DryRun guard, so neither can
        announce or claim a stop that an interlock has refused. Every refusal
        returns $false, which is what makes Watchdog.ps1 re-arm and retry rather
        than exit and leave a still-billing box unwatched.
    .PARAMETER Config
        The Get-TopazAutoStopConfig object. Passed in rather than loaded here so
        tests can drive every branch from a plain [pscustomobject].
    .PARAMETER Reason
        'completed' | 'stalled' | 'maxlifetime'.
    .PARAMETER IgnoreDryRun
        Overrides Config's DryRun for this invocation (the timed hard stop).
    .OUTPUTS
        [bool] -- and NOTHING else on the output stream. Watchdog.ps1 tests the
        result with `-eq $false`, and Write-TopazLog writes to the
        Information/Warning/Error streams precisely so it cannot contaminate it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [ValidateSet('completed', 'stalled', 'maxlifetime')]
        [string]$Reason = 'completed',
        [bool]$IgnoreDryRun = $false
    )

    $cfg = $Config

    # A timed hard-stop deliberately passes -IgnoreDryRun. Every downstream
    # message must describe the effective behavior, not merely Config.ps1's value.
    $effectiveDryRun = $cfg.DryRun -and -not $IgnoreDryRun

    Write-TopazLog -Component 'stop' -Level 'INFO' `
        -Message "Stop sequence invoked (reason=$Reason, effectiveDryRun=$effectiveDryRun, configuredDryRun=$($cfg.DryRun), ignoreDryRun=$IgnoreDryRun)."

    # -----------------------------------------------------------------------
    # Best-effort: discover this instance's id + region (ONE IMDSv2 round trip)
    # via the shared helper. The instance id is for nicer notifications; the
    # region is REQUIRED by the AWS CLI calls below - the SYSTEM account has no
    # default region configured anywhere in this pipeline, so without --region
    # both `aws s3 sync` and `aws sns publish` fail client-side with
    # NoRegionError every single time (silently, since it is only a WARN in a
    # log nobody reads until after the box is off). Never let discovery block
    # the stop.
    # -----------------------------------------------------------------------

    $identity   = Get-Ec2Identity
    $instanceId = $identity.InstanceId
    if ([string]::IsNullOrWhiteSpace($instanceId)) { $instanceId = 'i-XXXXXXXXXXXXXXXXX' }

    $region = $identity.Region
    if ([string]::IsNullOrWhiteSpace($region)) {
        Write-TopazLog -Component 'stop' -Level 'WARN' `
            -Message "IMDSv2 region discovery failed; any S3 sync / SNS publish below will run without --region and may fail without a configured default region."
    }

    # -----------------------------------------------------------------------
    # 1. Optional S3 sync (runs BEFORE power off so artifacts are safe).
    # -----------------------------------------------------------------------

    if (-not [string]::IsNullOrWhiteSpace($cfg.S3SyncTarget)) {
        Write-TopazLog -Component 'stop' -Level 'INFO' `
            -Message "Syncing '$($cfg.OutputDir)' -> '$($cfg.S3SyncTarget)' before power off."

        $syncArgs = Build-AwsCliArgs -Base @('s3', 'sync', $cfg.OutputDir, $cfg.S3SyncTarget, '--only-show-errors') -Region $region
        [void] (Invoke-TopazAwsCli -Arguments $syncArgs -TimeoutSec $cfg.S3SyncTimeoutSec `
            -Component 'stop' `
            -SuccessMessage 'S3 sync completed successfully.' `
            -FailureVerb 'S3 sync' `
            -FailureContext 'continuing to stop')
    }
    else {
        Write-TopazLog -Component 'stop' -Level 'INFO' `
            -Message "No S3SyncTarget configured; skipping artifact sync."
    }

    # -----------------------------------------------------------------------
    # 1b. Upload finished renders (rclone -> Google Drive), and THE EPHEMERAL
    #     INTERLOCK. See Resolve-EphemeralUploadRefusal for the asymmetry that
    #     makes this the one step allowed to abort the stop.
    # -----------------------------------------------------------------------

    $uploadOk = $null   # $null = not attempted, $true/$false = attempted

    if (-not [string]::IsNullOrWhiteSpace($cfg.UploadTarget)) {
        $uploadOk = Invoke-TopazRenderUpload -Config $cfg -Reason $Reason
    }
    elseif (-not $cfg.OutputIsEphemeral) {
        Write-TopazLog -Component 'stop' -Level 'INFO' `
            -Message "No UploadTarget configured; skipping render upload."
    }

    $ephemeralRefusal = Resolve-EphemeralUploadRefusal -UploadTarget $cfg.UploadTarget `
        -OutputIsEphemeral ([bool]$cfg.OutputIsEphemeral) -UploadSucceeded $uploadOk

    if (-not $ephemeralRefusal.ShouldStop) {
        if ($ephemeralRefusal.RefusalReason -eq 'NoUploadTarget') {
            Write-TopazLog -Component 'stop' -Level 'ERROR' `
                -Message "OutputDir '$($cfg.OutputDir)' is on EPHEMERAL storage but no UploadTarget is configured. Stopping would erase every render in it. REFUSING TO STOP."
            Write-TopazLog -Component 'stop' -Level 'ERROR' `
                -Message "Fix: set UploadTarget in Config.ps1 (and re-run Install.ps1), or move OutputDir onto the persistent C: drive and set OutputIsEphemeral = `$false."
        }
        else {
            # Invoke-TopazRenderUpload already made TWO attempts (1 initial + 1
            # retry, per Resolve-UploadRetryDecision) before returning $false
            # here -- see its own comment for why a single blip no longer
            # refuses the stop outright. Say so explicitly: a reader landing on
            # just this ERROR line (without having scrolled up through both
            # attempts) must not conclude only one try was made.
            Write-TopazLog -Component 'stop' -Level 'ERROR' `
                -Message "UPLOAD FAILED after 2 attempts (1 initial + 1 retry -- see the 'Upload attempt' lines above for both) and OutputDir '$($cfg.OutputDir)' is on EPHEMERAL storage. Stopping now would PERMANENTLY DESTROY the renders in it. REFUSING TO STOP -- the instance stays up so the render can still be recovered."
            Write-TopazLog -Component 'stop' -Level 'ERROR' `
                -Message "Recover with:  & '$($cfg.RclonePath)' --config '$($cfg.RcloneConfigPath)' copy '$($cfg.OutputDir)' '$($cfg.UploadTarget)' -P   then re-run this script."
        }

        # $false tells Watchdog.ps1 the stop was REFUSED rather than performed, so
        # it re-arms and tries again instead of exiting. Without that the watchdog
        # would quit here, nothing would ever retry the upload, and the render
        # would sit on a volume that the out-of-band CloudWatch idle alarm is about
        # to erase -- turning a recoverable upload failure into a permanent loss.
        return $false
    }

    # -----------------------------------------------------------------------
    # 1c. A completed render gets one final, fail-closed safety check after all
    #     potentially long upload/recovery work. This deliberately runs BEFORE
    #     SNS and the DryRun guard so neither can claim a stop that this interlock
    #     has refused. Stalled and timed hard-stop reasons retain their deliberate
    #     existing semantics; neither gets a new activity gate here.
    # -----------------------------------------------------------------------

    if ($Reason -eq 'completed') {
        if (-not (Test-TopazCompletedStopSafetyGate -Config $cfg)) {
            Write-TopazLog -Component 'stop' -Level 'ERROR' `
                -Message 'FINAL COMPLETION SAFETY GATE REFUSED the stop. The instance stays up and Watchdog.ps1 will re-arm rather than power off during a possible new or still-writing render.'
            return $false
        }
    }

    # -----------------------------------------------------------------------
    # 2. Optional SNS notification (best-effort; never blocks the stop).
    # -----------------------------------------------------------------------

    if (-not [string]::IsNullOrWhiteSpace($cfg.SnsTopicArn)) {
        # DryRun never powers off (see step 3 below), so the notification text
        # must not claim the box is stopping - that would be a false alarm to
        # whoever is subscribed to the topic. Get-TopazStopNotification reproduces
        # both branches' wording exactly.
        $notification = Get-TopazStopNotification -Reason $Reason -InstanceId $instanceId -DryRun $effectiveDryRun

        Write-TopazLog -Component 'stop' -Level 'INFO' `
            -Message "Publishing SNS notification to '$($cfg.SnsTopicArn)'."

        $snsArgs = Build-AwsCliArgs -Base @('sns', 'publish', '--topic-arn', $cfg.SnsTopicArn, '--subject', $notification.Subject, '--message', $notification.Message) -Region $region
        [void] (Invoke-TopazAwsCli -Arguments $snsArgs -TimeoutSec $cfg.AwsCliTimeoutSec `
            -Component 'stop' `
            -SuccessMessage 'SNS notification published.' `
            -FailureVerb 'SNS publish' `
            -FailureContext 'continuing to stop')
    }
    else {
        Write-TopazLog -Component 'stop' -Level 'INFO' `
            -Message "No SnsTopicArn configured; skipping notification."
    }

    # -----------------------------------------------------------------------
    # 3. Dry-run guard.
    # -----------------------------------------------------------------------

    if ($effectiveDryRun) {
        Write-TopazLog -Component 'stop' -Level 'INFO' `
            -Message "DRY RUN - would stop now (reason=$Reason). No stop performed."
        # $true, not $false: nothing FAILED here. The stop was deliberately
        # suppressed, and the watchdog's own DryRun re-arm path already handles
        # resuming. Returning $false would conflate "suppressed on purpose" with
        # "refused because the render is not safe".
        return $true
    }

    if ($cfg.DryRun -and $IgnoreDryRun) {
        Write-TopazLog -Component 'stop' -Level 'WARN' `
            -Message "DryRun is enabled in Config.ps1 but -IgnoreDryRun was passed: performing a REAL stop (reason=$Reason)."
    }

    # -----------------------------------------------------------------------
    # 4. Stop the instance, following the configured StopStrategy plan in order
    #    until one action succeeds.
    #
    #    Ec2ApiStop is attempted FIRST under the default 'Auto' strategy because
    #    it is the only action that provably ends BILLING. A guest shutdown only
    #    stops the instance when InstanceInitiatedShutdownBehavior happens to be
    #    'stop'; where it is not, the guest powers off and AWS keeps charging for
    #    a still-'running' instance -- a silent, expensive failure that looks
    #    exactly like success from inside the box.
    # -----------------------------------------------------------------------

    # Do NOT wrap this in @(). Resolve-StopPlan returns `, @(...)`, so its
    # pipeline output is ONE object that IS the array; @() would capture that
    # single object and produce a 1-element array whose only element is the
    # plan, silently reducing every multi-action plan to one iteration. Plain
    # assignment unrolls it correctly, and the unary comma is precisely what
    # guarantees a single-action plan still arrives as an array rather than a
    # bare string -- see Resolve-StopPlan's own comment, which names indexing
    # as a supported caller pattern.
    $plan = Resolve-StopPlan -Strategy $cfg.StopStrategy

    Write-TopazLog -Component 'stop' -Level 'INFO' `
        -Message "Stopping now (reason=$Reason). StopStrategy='$($cfg.StopStrategy)', plan=[$($plan -join ' -> ')]."

    # Indexed rather than foreach ONLY so the waits below can say whether
    # another action actually follows. With StopStrategy='Ec2ApiStop' the plan
    # is a single action, and the post-wait WARN used to promise an escalation
    # that could not happen -- immediately before the ERROR saying every action
    # had been attempted. Config.ps1 records why a wrong line here is expensive:
    # a previous version of this same wait produced a false diagnosis that
    # "would send the next person debugging a perfectly healthy IAM grant", and
    # these logs are the only post-mortem once the box is off.
    for ($i = 0; $i -lt $plan.Count; $i++) {

        $action = $plan[$i]
        $nextAction = if ($i -lt ($plan.Count - 1)) { $plan[$i + 1] } else { $null }

        if ($action -eq 'Ec2ApiStop') {

            if ($instanceId -eq 'i-XXXXXXXXXXXXXXXXX') {
                Write-TopazLog -Component 'stop' -Level 'WARN' `
                    -Message "Ec2ApiStop skipped: IMDS never yielded a real instance id, so there is nothing to stop by id."
                continue
            }

            $stopArgs = Build-AwsCliArgs -Base @('ec2', 'stop-instances', '--instance-ids', $instanceId) -Region $region
            $apiOk = Invoke-TopazAwsCli -Arguments $stopArgs -TimeoutSec $cfg.AwsCliTimeoutSec `
                -Component 'stop' `
                -SuccessMessage "ec2:StopInstances accepted for $instanceId. The instance should transition to 'stopping' shortly." `
                -FailureVerb 'EC2 API stop' `
                -FailureContext "instance=$instanceId. If this is an AccessDenied, the instance role is missing ec2:StopInstances -- see docs/11-deploying-on-this-instance.md."

            if ($apiOk) {
                # The API returns as soon as the request is accepted; the actual
                # teardown follows. Stay alive for StopVerifySec so that, if the
                # stop really is happening, this process simply dies here and no
                # further action in the plan ever runs. Surviving the wait means
                # the call was accepted but did not take effect, which is worth
                # escalating over.
                Write-TopazLog -Component 'stop' -Level 'INFO' `
                    -Message "Waiting up to $($cfg.StopVerifySec)s for the instance to actually go down."

                Start-Sleep -Seconds $cfg.StopVerifySec

                $escalation = if ($null -ne $nextAction) { "Escalating to the next action in the plan ($nextAction)." } else { 'No further actions remain in the plan.' }
                Write-TopazLog -Component 'stop' -Level 'WARN' `
                    -Message "Still running $($cfg.StopVerifySec)s after an accepted ec2:StopInstances. $escalation"
            }

            continue
        }

        if ($action -eq 'GuestShutdown') {
            Write-TopazLog -Component 'stop' -Level 'INFO' `
                -Message "Issuing guest shutdown (Stop-Computer -Force). NOTE: this ends billing ONLY if InstanceInitiatedShutdownBehavior='stop'."

            try {
                # Equivalent to `shutdown /s /t 0`. -Force so a hung or
                # dialog-blocking GUI application (Topaz itself, typically) cannot
                # veto the shutdown the way an interactive Start-menu shutdown can.
                Stop-Computer -Force -ErrorAction Stop
            }
            catch {
                Write-TopazLog -Component 'stop' -Level 'ERROR' `
                    -Message "Guest shutdown failed: $($_.Exception.Message)"
                continue
            }

            # Stop-Computer RETURNS IMMEDIATELY once the shutdown is initiated; the
            # OS tears this process down a few seconds later. Without this wait the
            # loop would fall straight through to the "every action was attempted
            # and the instance is STILL RUNNING" ERROR below and write that line on
            # the SUCCESS path -- leaving a log that reports failure at the exact
            # moment the stop worked. Since these logs are the only post-mortem
            # available once the box is off, that lie is worth blocking on.
            Write-TopazLog -Component 'stop' -Level 'INFO' `
                -Message "Guest shutdown initiated. Waiting up to $($cfg.StopVerifySec)s for the OS to tear this process down."

            Start-Sleep -Seconds $cfg.StopVerifySec

            Write-TopazLog -Component 'stop' -Level 'WARN' `
                -Message "Still alive $($cfg.StopVerifySec)s after issuing a guest shutdown; it appears not to have taken effect."

            continue
        }
    }

    Write-TopazLog -Component 'stop' -Level 'ERROR' `
        -Message "Every action in the stop plan [$($plan -join ' -> ')] was attempted and the instance is STILL RUNNING. It is very likely still being billed. Fix the stop path per docs/11-deploying-on-this-instance.md."

    # Reaching here means no action in the plan took effect. Report it as a refusal
    # so the watchdog keeps monitoring rather than exiting into a state where
    # nothing is watching a box that is still running and still billing.
    return $false
}

# ---------------------------------------------------------------------------
# Dot-source seam. Referenced (not just declared) so PSReviewUnusedParameter
# stays quiet, and placed here so a dot-sourcing test makes NO IMDS round trip,
# loads no config, and writes no stop.log line.
# ---------------------------------------------------------------------------

if ($LibraryOnly) { return }

$stopPerformed = Invoke-TopazStopSequence -Config (Get-TopazAutoStopConfig) `
    -Reason $Reason -IgnoreDryRun ([bool]$IgnoreDryRun)

# See the -ExitCodeOnRefusal comment above: ONLY the scheduled-task caller asks
# for an exit code. Everyone else -- above all Watchdog.ps1's `& <script>` --
# gets exactly one object on the output stream, $true or $false.
if ($ExitCodeOnRefusal) {
    if ($stopPerformed -eq $false) { exit 2 }
    exit 0
}

return $stopPerformed
