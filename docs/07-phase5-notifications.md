# 07 - Phase 5: Notifications (optional)

[README](../README.md) - [Architecture](01-architecture.md) - [Phase 0](02-phase0-confirmations.md) - [Phase 1](03-phase1-instance-prep.md) - [Phase 2](04-phase2-watchdog.md) - [Phase 3](05-phase3-stop-sequence.md) - [Phase 4](06-phase4-safety-net.md) - **Phase 5**

Notifications are entirely optional. When configured, the stop sequence publishes
a single "render complete/stalled - stopping" message to an SNS topic just before
it powers the box off, so you get a heads-up (email, SMS, etc., depending on your
topic's subscriptions) that a job finished and the instance is stopping.

## Enabling it

Set `SnsTopicArn` in the `OPERATOR SETTINGS` / optional-behaviour block of
[`Config.ps1`](../in-guest/Config.ps1) to your topic ARN:

```powershell
SnsTopicArn = 'arn:aws:sns:<region>:<account-id>:topaz-render-notify'
```

Leave it empty (the default) to skip notifications entirely. After changing it,
re-run [`Install.ps1`](../in-guest/Install.ps1) so the installed copy the SYSTEM
task runs picks up the new value.

## What it sends

From [`Stop-Sequence.ps1`](../in-guest/Stop-Sequence.ps1), after the optional S3
sync and before the power-off:

- **Subject / message when actually stopping:**
  `Topaz render <completed|stalled> - stopping <instance-id>`, with a one-line
  summary of the reason, the instance id, and a timestamp, noting that the guest
  is powering off (which stops the instance).
- **Subject / message under `DryRun`:**
  `Topaz render <completed|stalled> - DRY RUN (no stop) - <instance-id>`, stating
  explicitly that `DryRun` is enabled and the power-off was **suppressed** - the
  instance is still running. The wording is deliberately different so a `DryRun`
  test run can never be mistaken for a real stop notification. See the `DryRun`
  caveat in [Phase 3](05-phase3-stop-sequence.md): this SNS gating is purely a
  courtesy of the in-guest path and has no bearing on the out-of-band safety
  nets in [Phase 4](06-phase4-safety-net.md), which are never suppressed.

The instance id is the best-effort IMDSv2 value from
[Phase 3](05-phase3-stop-sequence.md) (a placeholder if IMDS was unreachable).

It publishes with:

```
aws sns publish --topic-arn <SnsTopicArn> --subject <...> --message <...> --region <discovered-region>
```

The `--region` flag is required, not cosmetic - see the IMDSv2 discovery note in
[Phase 3](05-phase3-stop-sequence.md); without it the SYSTEM account's `aws`
invocation has no default region and the publish call fails client-side.

## Best-effort: it never blocks the stop

The notification is strictly best-effort. If `aws sns publish` returns a non-zero
exit code or throws, the failure is **logged as a warning and ignored** - the box
still powers off. A notification problem must never keep a cost-accruing instance
alive. This is the same discipline as the optional S3 sync
([Phase 3](05-phase3-stop-sequence.md)).

## Required permission

The publish uses the instance role's credentials, so if you enable notifications
the role needs **`sns:Publish`** on the target topic. The default instance role
from [`02-create-iam-role.sh`](../control-plane/02-create-iam-role.sh) grants only
`cloudwatch:PutMetricData`; add an `sns:Publish` statement (scoped to your topic
ARN) to the role yourself. Without it the publish call fails - harmlessly, per the
best-effort behavior above, but you will get no notification.

A minimal statement to add to the instance role:

```json
{
  "Sid": "PublishRenderNotifications",
  "Effect": "Allow",
  "Action": "sns:Publish",
  "Resource": "arn:aws:sns:<region>:<account-id>:topaz-render-notify"
}
```

That completes the phased setup. See [Appendix A](08-appendix-a-corrections.md)
for the corrected assumptions this design encodes, and
[Appendix B](09-appendix-b-boundaries.md) for the decided scope boundaries.
