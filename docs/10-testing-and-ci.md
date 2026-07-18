# 10 - Testing & CI

[README](../README.md) - [Architecture](01-architecture.md) - [Phase 0](02-phase0-confirmations.md) - [Phase 1](03-phase1-instance-prep.md) - [Phase 2](04-phase2-watchdog.md) - [Phase 3](05-phase3-stop-sequence.md) - [Phase 4](06-phase4-safety-net.md) - [Phase 5](07-phase5-notifications.md) - [Appendix A](08-appendix-a-corrections.md) - [Appendix B](09-appendix-b-boundaries.md) - **Testing & CI**

This project is split across three languages (Bash, PowerShell, Python), each
with its own linter and, where the code has meaningful logic to exercise, its
own test suite. All of it is wired into GitHub Actions
([`.github/workflows/ci.yml`](../.github/workflows/ci.yml)) so a bad change is
caught before it reaches an EC2 box that bills by the hour.

## What CI checks

| Area | Path | Lint | Tests |
|------|------|------|-------|
| Control plane | `control-plane/*.sh` | `shellcheck` | - |
| In-guest pipeline | `in-guest/` | PSScriptAnalyzer | Pester (`in-guest/tests/`) |
| Max-lifetime Lambda | `lambda/max-lifetime-stop/` | `ruff` | `pytest` |

- **`shellcheck`** lints every control-plane script for common shell scripting
  bugs (unquoted expansions, unchecked exit codes, etc.).
- **PSScriptAnalyzer** lints the PowerShell under `in-guest/` for style and
  correctness issues.
- **Pester** runs the unit tests in [`in-guest/tests/`](../in-guest/tests/),
  which exercise `Resolve-RenderActive` (the pure completion-decision helper in
  [`in-guest/Config.ps1`](../in-guest/Config.ps1)) across all three
  `CompletionSignal` modes - see [Phase 2](04-phase2-watchdog.md). Because
  `Resolve-RenderActive` does no process/WMI/filesystem I/O, dot-sourcing
  `Config.ps1` to load it is safe on any platform, including a non-Windows CI
  runner: dot-sourcing only *defines* the functions in that file, it never
  executes the Windows-only cmdlets used elsewhere in the pipeline.
- **`ruff`** lints the Lambda handler in
  [`lambda/max-lifetime-stop/`](../lambda/max-lifetime-stop/).
- **`pytest`** runs [`test_handler.py`](../lambda/max-lifetime-stop/test_handler.py),
  which uses `botocore.stub.Stubber` to exercise the handler's
  running/stopped, over-ceiling/under-ceiling, and missing-instance branches
  without making real AWS calls - see
  [`lambda/max-lifetime-stop/README.md`](../lambda/max-lifetime-stop/README.md).

## Running the Lambda tests locally

```bash
pip install -r lambda/max-lifetime-stop/requirements-dev.txt && pytest lambda/ -q
```

## Running the Pester tests locally

Pester 5 requires **PowerShell 7+ (`pwsh`)**, which is what CI runs it under.
If you have `pwsh` installed:

```powershell
Invoke-Pester -Path in-guest/tests -CI
```

There is nothing Windows-specific about the tests themselves (see above), so
this also works on a non-Windows machine with `pwsh` installed - you do not
need an EC2 GPU box just to run the unit tests.

Back to the [README](../README.md).
