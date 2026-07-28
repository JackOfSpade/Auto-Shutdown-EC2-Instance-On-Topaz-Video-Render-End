# 09 - Appendix B: Decided design boundaries

[README](../README.md) - [Architecture](01-architecture.md) - [Phase 0](02-phase0-confirmations.md) - [Phase 1](03-phase1-instance-prep.md) - [Phase 2](04-phase2-watchdog.md) - [Phase 3](05-phase3-stop-sequence.md) - [Phase 4](06-phase4-safety-net.md) - [Phase 5](07-phase5-notifications.md)

These are settled decisions about what this project **is** and **is not**. They
are recorded so future changes do not quietly cross a boundary that was chosen on
purpose.

## 1. Activation is resolved: single-user, GUI-only

Topaz Video AI is **live-confirmed unwatermarked** on this instance, so the
software is functionally usable here - the "will it even run / will output be
watermarked" question is settled. The deployment is deliberately constrained to
stay within a defensible reading of the license:

- **One operator**, driving the **Topaz GUI by hand**.
- **No CLI, ever.** The Topaz EULA bans the CLI under a Personal License, and it
  names cloud / virtualization environments among its restrictions. Nothing in
  this repo calls the Topaz CLI; the watchdog detects completion purely by
  *observing* the GUI process, its encoder-worker descendants
  (`neuroserver.exe`/`ffmpeg.exe`, matched by ancestry), and the output folder.

Running Topaz on a cloud/virtualized EC2 instance is **the operator's own informed
license decision.** This project does not grant any right to do so and is not
legal advice. If your license terms forbid this deployment, do not deploy it. (See
the license note in the [README](../README.md) and correction #8 in
[Appendix A](08-appendix-a-corrections.md).)

## 2. One manual Export click is the chosen start trigger

The operator's single manual act is: load the project into the Topaz GUI over a
DCV session, click **Export once**, and disconnect. That one click is the only
human step in the run.

Everything **after** the click is automated by machinery that was already running
from boot:

- the SYSTEM watchdog task observes the render, waits for the queue to drain,
  the output files to unlock, and the Google Drive upload to verify, then stops
  the box ([Phase 2](04-phase2-watchdog.md), [Phase 3](05-phase3-stop-sequence.md));
- the SYSTEM metric task publishes `RenderActive`/`GPUUtilization` telemetry
  every minute - **no alarm acts on it by default** for this project (decided
  2026-07-28; see [§5](#5-no-idle-alarm-no-timed-stop-the-watchdog-is-the-only-thing-that-will-ever-stop-this-box)
  below and [Phase 4](06-phase4-safety-net.md)).

We chose a manual Export click (rather than auto-starting the render) because it
keeps a human in control of *what* renders and *when*, while still fully
automating the expensive part - the unattended wait and the stop.

## 3. A GUI robot is explicitly out of scope

There is **no GUI automation** in this project. Nothing clicks buttons, scripts
the Topaz interface, injects input, or otherwise drives the GUI on the operator's
behalf. This is a deliberate boundary, for two reasons:

- **License posture.** Automating the GUI to simulate a headless / batch workflow
  would undercut the "single-user, GUI-only, no CLI" stance above.
- **Robustness.** GUI automation is brittle (window titles, control positions,
  version drift). Observing the process tree and the filesystem - which is what
  the watchdog does - is far more stable and is the same signal regardless of
  Topaz UI changes.

If you ever feel tempted to add "just a little" GUI scripting to auto-click
Export, that is a scope change, not a tweak - and it moves the deployment out of
the single-user GUI-only posture this design was built to preserve.

## 4. Control-plane attribution is impossible from the guest by default - and the optional remedy

The render instance role (`topaz-gpu-render-role` on this box;
`topaz-render-instance-role` if provisioned via
[`02-create-iam-role.sh`](../control-plane/02-create-iam-role.sh)) is
deliberately least-privilege: it grants only `cloudwatch:PutMetricData`
(namespace-scoped) plus, optionally, a tag-scoped `ec2:StopInstances`. That is
exactly right for **running** the pipeline. It has a real cost, though: it
also means the box **cannot answer its own question** after the fact - "what
actually stopped me? The watchdog? The idle alarm? The max-lifetime Lambda? A
human?" A forensic audit of a real render cycle
([docs/15-third-end-to-end-run.md](15-third-end-to-end-run.md)) hit exactly
this wall. Every read needed to attribute a stop came back `AccessDenied` from
the box:

- `cloudtrail:LookupEvents`
- `cloudwatch:DescribeAlarms`, `cloudwatch:DescribeAlarmHistory`,
  `cloudwatch:GetMetricStatistics`, `cloudwatch:ListMetrics`
- `logs:DescribeLogGroups`
- `lambda:ListFunctions`
- `iam:List*RolePolicies`

That denial is **working as designed**, not a bug - it is the same
least-privilege posture [Appendix A](08-appendix-a-corrections.md) and
[Phase 1](03-phase1-instance-prep.md) argue for everywhere else in this
project. But an honest boundaries document should say plainly that it has a
cost: without one of the two remedies below, the only account this project can
give of its own stop is guest-side logs (`stop.log`, `watchdog.log`), which
cannot distinguish "the watchdog's own `ec2:StopInstances` call succeeded"
from "something else stopped the instance out from under it at the same
moment."

**Two remedies, and which one to pick:**

- **Run the audit from an admin workstation instead (recommended for a
  one-off investigation).** `cloudtrail lookup-events`,
  `cloudwatch describe-alarms`, `lambda list-functions`, etc. all work fine
  from the same admin workstation that already ran
  [`01`](../control-plane/01-set-shutdown-behavior.sh)-[`04`](../control-plane/04-deploy-max-lifetime-lambda.sh) -
  it already holds broader credentials than this render box will ever need,
  and reaching for them costs the render box nothing: zero new privilege,
  zero new attack surface, nothing to remember to revoke later. **This is the
  better choice for investigating a single past incident**, which is why
  [`00-verify-prerequisites.sh`](../control-plane/00-verify-prerequisites.sh)
  and every numbered control-plane script already assume an admin workstation
  as the normal place to run AWS reads from.
- **[`05-grant-audit-reads.sh`](../control-plane/05-grant-audit-reads.sh)
  (optional, opt-in) - grant the render role those same reads, on-box.** This
  is the right call only when you specifically want an **on-box** post-mortem
  to be self-sufficient - e.g. no admin workstation is reachable at
  post-mortem time, or the post-mortem itself runs in-guest as part of some
  future automation. It is a deliberate, explicit widening of what the render
  box can do, attached as its own managed policy (separate from whatever `02`
  or `04` already granted) so it can be inspected and revoked independently.
  The pipeline itself needs **none** of it - every one of these permissions
  is for looking backward at what already happened, never for deciding what
  to do next. `cloudtrail:LookupEvents` in particular cannot be scoped to any
  resource at all (`Resource` must be `"*"`) - it is the least
  tightly-scopeable grant in that policy and the main reason the whole thing
  stays opt-in rather than folding into `02`'s baseline. Default posture stays
  least-privilege; running `05` is a conscious trade of a small amount of
  render-box privilege for on-box forensic self-sufficiency, not a
  correction to the design above.

## 5. No idle alarm, no timed stop: the watchdog is the only thing that will ever stop this box

**Decided 2026-07-28, deliberate and accepted, not an oversight.** The
operator decided against any idle-based auto-stop
([Phase 4](06-phase4-safety-net.md)) and has not deployed the optional
max-lifetime Lambda. The one-shot wall-clock timed stop
(`in-guest/Register-TimedStop.ps1`) that had been armed as an interim cost
backstop while the primary stop path was still being verified
([docs/11](11-deploying-on-this-instance.md)) was itself removed on
2026-07-27, once that verification succeeded. Put together:

| Layer | Status on this project |
|---|---|
| Watchdog completion -> verified upload -> `ec2:StopInstances` | **Armed. The only sanctioned auto-stop.** |
| CloudWatch idle alarm (`03-create-idle-alarm.sh`) | Opt-in, off by default, deleted for this instance (2026-07-28). |
| Max-lifetime Lambda (`04-deploy-max-lifetime-lambda.sh`) | Not deployed. |
| In-guest one-shot timed stop (`Register-TimedStop.ps1`) | Removed (2026-07-27), once the primary path was verified. |

**The honest cost of this.** With every fallback layer either never deployed
or deliberately not armed, **the watchdog completing a render is the only
event that will ever stop this box.** If any of the following happens, the
instance keeps running - and being billed at `g6e.2xlarge` rates - until a
human notices and stops it by hand:

- the watchdog process dies and its restart policy and 15-minute self-healing
  sweep ([Phase 2](04-phase2-watchdog.md)) both fail to revive it;
- Topaz is never opened at all in a given session (nothing to ever complete);
- the operator loads a project, then simply walks away without clicking
  Export;
- a render fails outright and the queue never produces the completion signal
  the watchdog is waiting for.

This is a **deliberate, accepted trade-off**, made with the alternative fully
in view: an idle-based safety net that had already, on 2026-07-27, come
within five minutes of stopping a live, healthy render
([docs/15 §K](15-third-end-to-end-run.md)), and that structurally cannot tell
an abandoned box apart from an operator who is merely between clicks. The
operator chose the smaller, well-understood risk (unbounded uptime on a rare
failure mode, always visible in the AWS bill and the console) over the
larger, harder-to-see one (a false stop silently destroying a render or a
setup session). See [docs/16](16-render-loss-incident.md) for a second,
independent illustration of why "stop more eagerly" is not a free improvement
either - the empty-`OutputDir` defect recorded there shows a stop decision
that was *too* eager to treat an ambiguous state as safe, in the opposite
direction from an idle alarm's false positive.

**Manual mitigations, if you want a bound without re-arming an automatic
layer:**

- **Stop it from the console/CLI yourself** the moment you know a session is
  done or abandoned - `aws ec2 stop-instances --instance-ids <id> --region
  <region>`, or the EC2 console's Stop action. This costs nothing to keep
  available and needs no code change.
- **Re-arm `in-guest/Register-TimedStop.ps1` for a bounded session.** It
  registers a SYSTEM task that fires a real stop a fixed number of hours from
  now (default 4), **bypassing `DryRun`** and **blind to render state** - it
  will kill an in-progress render if one is still running when it fires. Use
  it deliberately, for a specific session you want bounded (e.g. "I am about
  to walk away for the day and don't trust this queue to finish cleanly"),
  and cancel it (`.\Register-TimedStop.ps1 -Cancel`) once you know the
  watchdog will take over cleanly. This is exactly the tool that was armed as
  an interim backstop before 2026-07-27, kept available for the same purpose
  again, on purpose, per-session rather than left running permanently.
- **Re-enable the CloudWatch idle alarm** (`ENABLE_IDLE_ALARM=1
  ./control-plane/03-create-idle-alarm.sh`) for a specific window where you
  know its false-positive risk is acceptable (e.g. a long unattended
  overnight run you are willing to have stopped early), then tear it back
  down (`TEARDOWN=1`) afterward rather than leaving it as a permanent,
  silently-reintroduced default.

## Boundary summary

| Decision | Chosen | Rejected |
|----------|--------|----------|
| License posture | Single-user, GUI-only, no CLI | Any CLI / headless batch use |
| Run trigger | One manual Export click, then disconnect | Auto-starting renders |
| GUI interaction | Observe only (process tree + filesystem) | A GUI robot that clicks/drives Topaz |
| Responsibility for cloud use | The operator's own informed license call | (not something this project grants) |
| Control-plane attribution reads | Denied by default (least privilege); admin workstation is the default place to audit from | Granting them to the render role by default |
| Auto-stop layers armed | Watchdog completion -> verified upload -> `ec2:StopInstances` only (2026-07-28) | Idle alarm (any signal), max-lifetime Lambda, in-guest timed stop - all available, none armed by default |

Back to the [README](../README.md).
