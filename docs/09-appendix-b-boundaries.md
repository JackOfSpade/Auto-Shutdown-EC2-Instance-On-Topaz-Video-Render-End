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

- the SYSTEM watchdog task observes the render, waits for the queue to drain and
  the output files to unlock, and stops the box ([Phase 2](04-phase2-watchdog.md),
  [Phase 3](05-phase3-stop-sequence.md));
- the SYSTEM metric task feeds the out-of-band idle alarm
  ([Phase 4](06-phase4-safety-net.md)).

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

## Boundary summary

| Decision | Chosen | Rejected |
|----------|--------|----------|
| License posture | Single-user, GUI-only, no CLI | Any CLI / headless batch use |
| Run trigger | One manual Export click, then disconnect | Auto-starting renders |
| GUI interaction | Observe only (process tree + filesystem) | A GUI robot that clicks/drives Topaz |
| Responsibility for cloud use | The operator's own informed license call | (not something this project grants) |

Back to the [README](../README.md).
