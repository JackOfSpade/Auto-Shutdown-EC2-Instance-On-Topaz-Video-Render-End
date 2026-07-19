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
| Control plane | `control-plane/*.sh`, `control-plane/lib/*.sh`, `scripts/*.sh`, `tests/*.sh` | `shellcheck`, `actionlint` | `bash tests/test_auto_merge_logic.sh`, `bash tests/test_control_plane_validation.sh` |
| In-guest pipeline | `in-guest/` | PSScriptAnalyzer | Pester (`in-guest/tests/`) |
| Max-lifetime Lambda | `lambda/max-lifetime-stop/` | `ruff` | `pytest` |

- **`shellcheck`** lints every control-plane / `scripts/` / `tests/` script for
  common shell scripting bugs (unquoted expansions, unchecked exit codes, etc.),
  run with `-x --source-path=SCRIPTDIR` so a `# shellcheck source=` directive
  (e.g. `tests/test_auto_merge_logic.sh` sourcing `../scripts/auto_merge_decision.sh`)
  resolves relative to the *sourcing* file's own directory instead of failing
  with `SC1091`.
- **`actionlint`** (pinned Docker tag, not `:latest`, so an unrelated actionlint
  release can't silently turn this job red) statically checks the workflow YAML
  under `.github/workflows/` **and** shells out to `shellcheck` on every
  embedded `run:` block - the only gate that covers the bash written directly
  inline in a workflow step (e.g. the merge loop in
  [`auto-merge-claude.yml`](../.github/workflows/auto-merge-claude.yml)), which
  the standalone `shellcheck` glob above never sees because it only looks at
  `*.sh` files on disk.
- **`tests/test_control_plane_validation.sh`** exercises the pure predicates in
  [`control-plane/lib/validation.sh`](../control-plane/lib/validation.sh) (the
  `IDLE_MINUTES`/`MAX_LIFETIME_HOURS`/shutdown-behavior/profile-name checks
  shared by `control-plane/01..04-*.sh`) and the idempotency wrapper in
  [`control-plane/lib/aws-idempotent.sh`](../control-plane/lib/aws-idempotent.sh),
  by sourcing the same files the production scripts source - no AWS
  credentials or network access needed.
- **PSScriptAnalyzer** lints the PowerShell under `in-guest/` for style and
  correctness issues. **Error/ParseError** severity always fails the build;
  **Warning** severity now also fails the build **unless** the specific rule is
  on an explicit, commented allowlist in
  [`ci.yml`](../.github/workflows/ci.yml) (currently
  `PSAvoidUsingEmptyCatchBlock` and `PSUseSingularNouns`, each with a comment
  explaining the deliberate design choice it is silencing). A security-class
  rule (credential/secret handling, injection, etc.) is never allowlisted. This
  closes a gap where a real Warning-level finding could previously pass CI
  silently as long as it was not an Error/ParseError.
- **Pester** runs the unit tests in [`in-guest/tests/`](../in-guest/tests/),
  which exercise `Resolve-RenderActive` (the pure completion-decision helper in
  [`in-guest/Config.ps1`](../in-guest/Config.ps1)) across all three
  `CompletionSignal` modes - see [Phase 2](04-phase2-watchdog.md). Because
  `Resolve-RenderActive` does no process/WMI/filesystem I/O, dot-sourcing
  `Config.ps1` to load it is safe on any platform, including a non-Windows CI
  runner: dot-sourcing only *defines* the functions in that file, it never
  executes the Windows-only cmdlets used elsewhere in the pipeline.
  `in-guest/tests/Watchdog.Tests.ps1` exercises `Watchdog.ps1`'s own pure
  helpers (worker attribution, the idle/stall state machine, the
  resume-vs-stop decision) the same safe way: dot-sourcing `Watchdog.ps1` only
  defines its functions, because a top-level guard skips the file's
  Windows-only wait-for-Topaz/monitoring loop whenever it is dot-sourced
  rather than run directly.
- **`ruff`** lints the Lambda handler in
  [`lambda/max-lifetime-stop/`](../lambda/max-lifetime-stop/).
- **`pytest`** runs [`test_handler.py`](../lambda/max-lifetime-stop/test_handler.py),
  which uses `botocore.stub.Stubber` to exercise the handler's
  running/stopped, over-ceiling/under-ceiling, and missing-instance branches
  without making real AWS calls - see
  [`lambda/max-lifetime-stop/README.md`](../lambda/max-lifetime-stop/README.md).

## The auto-merge-to-main workflow and its tests

[`.github/workflows/auto-merge-claude.yml`](../.github/workflows/auto-merge-claude.yml)
merges any branch into `main` automatically once its own `CI` run for that exact
commit SHA is green (triggered on `workflow_run` completion of the `CI`
workflow, plus a manual `workflow_dispatch` escape hatch). The CI-gate,
retry, and ancestry predicates that decide "is this branch mergeable" are
factored out into sourceable functions in
[`scripts/auto_merge_decision.sh`](../scripts/auto_merge_decision.sh) - `git`
plumbing (fetch/checkout/merge/push, the conflict-PR fallback, branch
listing/filtering) stays inline in the workflow, but every predicate the
workflow calls comes from that one file, so production and tests run the
*identical* implementation with no shadow copy to drift.

Notable behavior encoded there:

- **Fail-closed CI gate:** only an exact `"success"` conclusion counts as green;
  in-progress, failure, missing, or an API error all block the merge.
- **`per_page=10`, not `1`, when listing runs for a SHA:** a branch with an open
  PR gets **two** `CI` workflow runs per commit (one for the `push` event, one
  for the `pull_request` event), completing independently and in no guaranteed
  order. Fetching several runs and searching all of them for a `"success"`
  avoids parking a genuinely green branch behind its own duplicate in-progress
  or cancelled run.
- **A one-shot, content-free retry** for a branch whose CI failed on its first
  attempt (`gh run rerun --failed`), bounded to exactly one attempt ever per
  branch via GitHub's own `run_attempt` counter.

[`tests/test_auto_merge_logic.sh`](../tests/test_auto_merge_logic.sh) exercises
these functions against a scratch git repo plus canned `gh api` JSON fixtures,
and is wired into `ci.yml`'s `shell-lint` job (see the table above) so a change
to the merge/CI-gate logic is checked by more than shellcheck syntax alone. Run
it locally with:

```bash
bash tests/test_auto_merge_logic.sh
```

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
