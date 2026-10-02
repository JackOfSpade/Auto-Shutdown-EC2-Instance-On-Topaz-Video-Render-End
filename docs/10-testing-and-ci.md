# 10 - Testing & CI

[Architecture](01-architecture.md) - [Phase 0](02-phase0-confirmations.md) - [Phase 1](03-phase1-instance-prep.md) - [Phase 2](04-phase2-watchdog.md) - [Phase 3](05-phase3-stop-sequence.md) - [Phase 4](06-phase4-safety-net.md) - [Phase 5](07-phase5-notifications.md) - [Appendix A](08-appendix-a-corrections.md) - [Appendix B](09-appendix-b-boundaries.md) - **Testing & CI**

This project is split across three languages (Bash, PowerShell, Python), each
with its own linter and, where the code has meaningful logic to exercise, its
own test suite. All of it is defined in one workflow
([`.github/workflows/ci.yml`](../.github/workflows/ci.yml)) so a bad change is
caught before it reaches an EC2 box that bills by the hour.

## Where CI runs

GitHub Actions is the authoritative gate. `ci.yml` runs on every push and pull
request, and can be started manually with `workflow_dispatch`. It checks code on
GitHub-hosted Ubuntu runners, with the PowerShell suite also running on
Windows. New commits cancel stale in-progress runs for the same ref.

The security workflows run independently: dependency review evaluates pull
requests, CodeQL scans supported source on pushes, pull requests, and a weekly
schedule, and Dependabot opens routine dependency updates. None requires AWS,
GCP, or other production credentials.

## What CI checks

| Area | Path | Lint | Tests |
|------|------|------|-------|
| Shell (control plane, `scripts/`, `tests/`) | every `*.sh` in the tree (discovered, not listed) | `shellcheck` 0.10.0, bash-3.2 grep lint, `actionlint` | every `tests/test_*.sh` (discovered, not listed) |
| IAM policy documents | `control-plane/iam/*.json` | `python3 -c json.load` | - |
| In-guest pipeline | `in-guest/` | PSScriptAnalyzer (incl. PS 5.1 syntax compat) | Pester (`in-guest/tests/`) |
| Max-lifetime Lambda | `lambda/max-lifetime-stop/` | `ruff` | `pytest` |

- **`shellcheck`** lints every `*.sh` in the tree for common shell scripting bugs
  (unquoted expansions, unchecked exit codes, etc.), run with
  `-x --source-path=SCRIPTDIR` so a `# shellcheck source=` directive (e.g.
  `tests/test_auto_merge_logic.sh` sourcing `../scripts/auto_merge_decision.sh`)
  resolves relative to the *sourcing* file's own directory instead of failing
  with `SC1091`. The file list comes from `find`, not a hand-written glob: the
  previous four-glob list quietly excluded `tests/fixtures/*.sh`, and those
  fixtures decide which branch of the deploy scripts the tests exercise, so a
  quoting bug in one turns a passing test into a test of the wrong code path.
  shellcheck is pinned to **0.10.0** and installed from the upstream release
  rather than `apt`, because that is the version bundled inside the pinned
  `actionlint` image below - so shell files on disk and bash embedded in a
  workflow are held to one standard. Bump the two together.
- **bash-3.2 lint** - one `grep` over `control-plane/`, `scripts/` and `tests/`
  that fails the build on the bash 4 case-modification expansions. These scripts
  are run by the operator from a Mac, where `/bin/bash` is still 3.2, and there
  the construct is not a no-op but a fatal `bad substitution` parse error;
  shellcheck does not flag it by default, so nothing else in the pipeline would
  catch it. Use `tr '[:lower:]' '[:upper:]'` instead. Whole-line `#` comments are
  filtered out of the matches **on purpose**, so a fix site can keep a rationale
  comment naming the expansion it replaced right where the temptation to regress
  lives (see [`control-plane/00-verify-prerequisites.sh`](../control-plane/00-verify-prerequisites.sh));
  a lint that forbids explaining itself would push that rationale out of the
  scripts. An expansion in *code* still fails, including when a trailing comment
  follows it on the same line.
- **IAM policy JSON validation** - `control-plane/iam/*.json` is handed verbatim
  to AWS by `02-create-iam-role.sh`, `04-deploy-max-lifetime-lambda.sh` and
  `05-grant-audit-reads.sh` via `file://`, and nothing else in the pipeline
  parses JSON. Without this check, a stray comma surfaces only mid-deploy as an
  opaque `MalformedPolicyDocument`, after the deploy script has already tagged
  the instance, zipped the code and created the role. `python3`'s `json.load` is
  used rather than `jq empty` because it accepts exactly one document, where
  `jq` would accept a stream of two concatenated objects that AWS still rejects.
- **Executable-bit assertion** - every operator-run `control-plane/[0-9]*.sh` and
  `tests/test_*.sh` must carry its exec bit, because the runbooks invoke them as
  `./control-plane/NN-*.sh`. Git tracks the bit through clone and checkout, so a
  script committed `644` dies with "permission denied" at the *first* command of
  a deployment while CI stays green - CI always ran them as `bash <file>`. Two of
  the six numbered scripts were committed `644` exactly that way (fixed
  2026-08-21). The check names each offender and prints the `chmod +x` fix.
- **`actionlint`** (pinned Docker tag, not `:latest`, so an unrelated actionlint
  release can't silently turn this job red) statically checks the workflow YAML
  under `.github/workflows/` **and** shells out to `shellcheck` on every
  embedded `run:` block - the only gate that covers the bash written directly
  inline in a workflow step (e.g. the merge loop in
  [`auto-merge-claude.yml`](../.github/workflows/auto-merge-claude.yml)), which
  the standalone `shellcheck` sweep above never sees because it only looks at
  `*.sh` files on disk.
- **The bash test suites** are discovered with a `tests/test_*.sh` glob rather
  than listed step by step, so a new suite is gated from the moment it lands
  instead of only if whoever wrote it also remembered to edit `ci.yml`. The loop
  stops at the first failing suite and names it. An empty glob fails the build:
  a discovery gate that matches nothing has proved nothing, and this project has
  a whole incident write-up ([docs/16](16-render-loss-incident.md)) about
  trusting a check that was not actually doing anything.
- **`tests/test_control_plane_validation.sh`** exercises the pure predicates in
  [`control-plane/lib/validation.sh`](../control-plane/lib/validation.sh) (the
  `IDLE_MINUTES`/`MAX_LIFETIME_HOURS`/shutdown-behavior/profile-name checks
  shared by `control-plane/01..04-*.sh`) and the idempotency wrapper in
  [`control-plane/lib/aws-idempotent.sh`](../control-plane/lib/aws-idempotent.sh),
  by sourcing the same files the production scripts source - no AWS
  credentials or network access needed.
- **PSScriptAnalyzer 1.25.0** lints the PowerShell under `in-guest/` for style and
  correctness issues. **Error/ParseError** severity always fails the build;
  **Warning** severity now also fails the build **unless** the specific rule is
  on an explicit, commented allowlist in
  [`ci.yml`](../.github/workflows/ci.yml) (currently
  `PSAvoidUsingEmptyCatchBlock` and `PSUseSingularNouns`, each with a comment
  explaining the deliberate design choice it is silencing). A security-class
  rule (credential/secret handling, injection, etc.) is never allowlisted. This
  closes a gap where a real Warning-level finding could previously pass CI
  silently as long as it was not an Error/ParseError. Each allowlist entry
  enumerates every site it silences, by file and function rather than by line
  number, so the list can be diffed against the tree; the analyzer command that
  regenerates it is in the comment beside it.
- **PSScriptAnalyzer's `PSUseCompatibleSyntax`** (`TargetVersions = 5.1, 7.0`)
  is the **only** automated check that the `in-guest/` scripts still parse under
  **Windows PowerShell 5.1**, which is what the EC2 Windows Server guest runs.
  Everything else that touches this code - the CI runners, Pester, a developer's
  Mac - is pwsh 7, so a PS7-only construct (`??`, `?.`, ternary, `?[]`) passes
  every other gate green and then fails on the box that matters. On 5.1 it is
  not a runtime warning but a parse error covering the whole file, and because
  every in-guest script dot-sources `Config.ps1` by literal name, one such
  construct there stops `Watchdog.ps1` from starting at all: the render is never
  signalled complete and the GPU instance keeps billing. The rule is opt-in (it
  does not fire from the default rule set) and reports at Error severity, so the
  existing blocking filter fails the build on it with no allowlist change.
  Enabling it added zero diagnostics to the tree as it stood, so it gates new
  code without re-litigating existing code.
- **Pester 5.x** runs the unit tests in [`in-guest/tests/`](../in-guest/tests/),
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
  [`in-guest/tests/Stop-Sequence.Tests.ps1`](../in-guest/tests/Stop-Sequence.Tests.ps1)
  pins the stop contract itself: that `Stop-Sequence.ps1` emits **exactly one
  boolean** and nothing else on the output stream (the property
  `Resolve-StopSequenceResult` in the watchdog refuses to trust anything but -
  see [Phase 3](05-phase3-stop-sequence.md)), that the watchdog's call path never
  `exit`s, the ordering of the ephemeral safety gate against the `DryRun` guard,
  and `-ExitCodeOnRefusal`.
  [`in-guest/tests/Test-Deployment.Tests.ps1`](../in-guest/tests/Test-Deployment.Tests.ps1)
  covers the preflight's two destruction-relevant predicates. Both of those load
  their target through the **`-LibraryOnly`** dot-source seam - the same idea as
  the Watchdog suite's top-level guard, made an explicit switch: the file defines
  its functions without loading config, touching IMDS, printing a verdict or
  attempting a stop.
- **`ruff`** lints the Lambda handler in
  [`lambda/max-lifetime-stop/`](../lambda/max-lifetime-stop/). CI installs the
  committed `requirements-dev.txt`, which pins its reviewed Python test and
  lint toolchain (including Ruff 0.15.22) rather than resolving new releases
  on every run. The ruleset itself is committed too:
  [`lambda/max-lifetime-stop/pyproject.toml`](../lambda/max-lifetime-stop/pyproject.toml)
  selects a substantive family set (`E,W,F,I,B,UP,RUF,DTZ,RET,SIM` - `DTZ`'s
  naive-datetime ban is the load-bearing one for a handler whose whole job is
  tz-aware clock arithmetic) instead of ruff's near-empty default selection.
- **`pytest`** runs [`test_handler.py`](../lambda/max-lifetime-stop/test_handler.py),
  which uses `botocore.stub.Stubber` to exercise the handler's
  running/stopped, over-ceiling/under-ceiling, and missing-instance branches
  without making real AWS calls - see
  [`lambda/max-lifetime-stop/README.md`](../lambda/max-lifetime-stop/README.md).

## The auto-merge-to-main workflow and its tests

[`.github/workflows/auto-merge-claude.yml`](../.github/workflows/auto-merge-claude.yml)
merges at most one branch into `main` automatically once both that branch and
the exact current `main` commit have a green `CI` run (triggered on
`workflow_run` completion of the `CI` workflow, plus a manual
`workflow_dispatch` escape hatch). After it pushes that one merge, it
explicitly dispatches a CI run for the resulting `main` SHA (`gh workflow run
ci.yml --ref main` - a `GITHUB_TOKEN` push creates no workflow run on its own,
which is why `ci.yml` carries a `workflow_dispatch` trigger), and that run
must be green before a later workflow run can merge another branch.
The CI-gate, retry, and ancestry predicates that decide "is this branch
mergeable" are
factored out into sourceable functions in
[`scripts/auto_merge_decision.sh`](../scripts/auto_merge_decision.sh) - `git`
plumbing (fetch/checkout/merge/push, the conflict-PR fallback, branch
listing/filtering) stays inline in the workflow, but every predicate the
workflow calls comes from that one file, so production and tests run the
*identical* implementation with no shadow copy to drift.

Notable behavior encoded there:

- **Fail-closed CI gate:** only an exact `"success"` conclusion counts as green;
  in-progress, failure, missing, or an API error all block the merge.
- **Main-history gate and one-merge cycle:** the exact current `origin/main`
  SHA must be green before any candidate is merged, and a successful candidate
  ends the cycle. This prevents individually-green branches from forming an
  untested combined `main`; already-contained branch cleanup can still batch.
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

[`tests/test_deploy_max_lifetime_scheduler.sh`](../tests/test_deploy_max_lifetime_scheduler.sh)
uses a fake AWS CLI to exercise the EventBridge Scheduler and classic
CloudWatch Events fallback paths in the max-lifetime deployment script without
AWS credentials or network access. Run it locally with:

```bash
bash tests/test_deploy_max_lifetime_scheduler.sh
```

## Running the Lambda tests locally

```bash
python -m pip install -r lambda/max-lifetime-stop/requirements-dev.txt && python -m pytest lambda/ -q
```

## Running the Pester tests locally

CI runs Pester under **PowerShell 7 (`pwsh`)** on a Linux runner. (Pester 5
itself also supports Windows PowerShell 5.1 - which matters here, because 5.1 is
the in-guest target - but nothing in CI exercises that combination.)

CI installs Pester 5.7.1 and then asserts that the *loaded* module's version
string is exactly `5.7.1`, throwing otherwise. That is stricter than a
major-version check: it blocks both a runner's preinstalled legacy Pester 3.4
and any newer PSGallery release from silently changing the test runner. If you
run the suite locally with a different 5.x, expect that assertion to fire - it
is not a bug in your setup. Install the pinned version with:

```powershell
Install-Module Pester -RequiredVersion 5.7.1 -Force -Scope CurrentUser
```

The same pattern applies to PSScriptAnalyzer, which is imported with
`-RequiredVersion 1.25.0` and asserted the same way, because its exact ruleset
is what the warning allowlist above was established against.

Then:

```powershell
Invoke-Pester -Path in-guest/tests -CI
```

There is nothing Windows-specific about the tests themselves (see above), so
this also works on a non-Windows machine with `pwsh` installed - you do not
need an EC2 GPU box just to run the unit tests.

## Known gaps

Accepted, deliberate holes in the above. They are written down because an
unlisted gap eventually gets mistaken for coverage.

- **Two control-plane deploy scripts are still lint-only.** `00`, `02`, `03` and
  `04` are each executed by a `tests/test_*.sh` suite against the fake-AWS
  fixtures ([`test_verify_prerequisites.sh`](../tests/test_verify_prerequisites.sh),
  [`test_create_iam_role.sh`](../tests/test_create_iam_role.sh),
  [`test_create_idle_alarm.sh`](../tests/test_create_idle_alarm.sh),
  [`test_deploy_max_lifetime_scheduler.sh`](../tests/test_deploy_max_lifetime_scheduler.sh)).
  `01-set-shutdown-behavior.sh` and `05-grant-audit-reads.sh` get `shellcheck`,
  the bash-3.2 grep and the exec-bit assertion and nothing more, so the *shape*
  of the AWS calls those two make is unverified. The fixture harness to close it
  exists and is proven - a new `tests/test_*.sh` is picked up by CI
  automatically - so this is a small, well-understood remaining hole rather than
  an open question about how.

  For the record of what closing it bought: `03-create-idle-alarm.sh` provisions
  the CloudWatch alarm that can stop the instance from outside the guest
  entirely, where a wrong `--period` / `--evaluation-periods` / `--threshold`
  produces a stop that bypasses every in-guest refusal. `test_create_idle_alarm.sh`
  now pins exactly that: the `ENABLE_IDLE_ALARM` opt-in gate, the
  statistic/threshold pairing, `ActionsEnabled` preservation across a re-run, and
  the teardown path.
