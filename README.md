# rdd-workflow-e2e

External end-to-end test bed for [chisuhua/rdd-workflow](https://github.com/chisuhua/rdd-workflow).

Validates rdd-workflow from a **third-party project's perspective**:

1. Installs rdd-workflow via `install.sh --global` (or local symlink)
2. Drives the full `arch → planner → builder → archive` workflow in a fake project under `$BATS_TEST_TMPDIR`
3. Verifies all 36 `rddf` subcommands are exposed and functional
4. Verifies sub-skill frontmatter is well-formed

## Why

The internal test suite in `chisuhua/rdd-workflow/tests/` exercises components in-process.
This test bed exercises them **post-install** — same way a real user would run them.
Catches regressions that in-process tests miss:

- Install path breakage (symlink resolution, PYTHONPATH injection, rddf wrapper)
- Cross-repo coupling (env-var contracts between `rdd-arch`, `rdd-planner`, `rdd-builder`)
- Frontmatter drift in `skills/*/SKILL.md` (CI catches when version lines go stale)

## Usage

### Local

```bash
# 1. Install rdd-workflow (one of:)
./install_testbed.sh --clone     # git clone + install.sh --global
./install_testbed.sh --symlink   # symlink a local checkout (dev loop)
./install_testbed.sh --status    # show current state

# 2. Run all 36 tests
RDD_WORKFLOW_REPO="$HOME/.agents/skills/rdd-workflow" bats tests/

# Or single file:
RDD_WORKFLOW_REPO=~/.agents/skills/rdd-workflow bats tests/integration/test_full_workflow_e2e.bats
```

### CI

This repo's `.github/workflows/test.yml` runs on:

- **push** to `master`/`main`
- **pull_request** (validates PRs against rdd-workflow master)
- **workflow_dispatch** (manual trigger from Actions tab)
- **schedule** — nightly cron at 02:00 UTC, catches upstream rdd-workflow regressions within 24h

Each CI run executes `./install_testbed.sh --clone` (fresh install from latest rdd-workflow master) then `bats tests/`.

## Test suite breakdown (36 cases, ~20s)| File | Cases | What it validates |
|------|------:|-------------------|
| `tests/integration/test_full_workflow_e2e.bats` | 7 | Full arch→planner→builder→archive workflow with real handoff contracts (ADR-0016 v3 schema, planner-handoff-v1, builder-handoff-v1, iteration schema) |
| `tests/integration/test_rddf_cli_all_subcommands.bats` | 6 | All 36 `rddf` subcommands exposed via `--help`; basic commands work |
| `tests/integration/test_install_global.bats` | 6 | `install.sh --global` works: 27 symlinks, `rddf` in PATH, `_lib` Python importable |
| `tests/integration/test_external_project_smoke.bats` | 5 | Every SKILL.md has valid YAML frontmatter + name/description/license + semver version |
| `tests/_lib/test_full_workflow_fixture_*.bats` | 12 | Per-function unit tests of the E2E fixture helpers |

Total: **36 cases, ~20s runtime**.

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│ rdd-workflow-e2e (this repo, GitHub: chisuhua/rdd-workflow-e2e)       │
│ ┌─────────────────────────┐  ┌────────────────────────────────────┐  │
│ │ install_testbed.sh      │  │ tests/                              │  │
│ │ --clone / --symlink     │  │  ├─ test_helper.bash                │  │
│ │ --status / --uninstall  │  │  │  (load_lib + RDD_WORKFLOW_REPO)   │  │
│ └─────────────────────────┘  │  ├─ _lib/test_full_workflow_fixture │  │
│                              │  │  (10 invoke_* functions, real API) │  │
│                              │  └─ integration/                     │  │
│                              │     ├─ test_full_workflow_e2e.bats   │  │
│                              │     ├─ test_rddf_cli_all_subcommands │  │
│                              │     ├─ test_install_global.bats     │  │
│                              │     └─ test_external_project_smoke   │  │
│                              └────────────────────────────────────┘  │
└──────────────────────────────┬───────────────────────────────────────┘
                               │ install_testbed.sh
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│ ~/.agents/skills/rdd-workflow (installed)                              │
│   OR                                                                 │
│ /workspace/project/rdd-workflow (symlink in dev)                      │
│ ┌────────────────────────────────────────────────────────────────┐  │
│ │ _lib/  ←  Python modules (state_vector, builder_handoff, ...)  │  │
│ │ skills/  ←  27 sub-skills (rdd-arch, rdd-planner, ...)         │  │
│ │ install.sh  ←  bootstrap entry point                          │  │
│ │ rddf CLI wrapper  ←  ~/.local/bin/rddf → python3 -m _lib.cli  │  │
│ └────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────┘
```

### Key env vars

| Var | Default | Purpose |
|-----|---------|---------|
| `RDD_WORKFLOW_REPO` | `~/.agents/skills/rdd-workflow` | Where the test bed expects rdd-workflow to live |
| `BATS_TEST_TMPDIR` | (bats-managed) | Per-test scratch directory; fake project lives here |
| `PROJECT_ROOT` | `$RDD_WORKFLOW_REPO` | What `rddf` and Python shims read to resolve `_lib/` |

### Where each case exercises real code

Every `@test` in `tests/integration/test_full_workflow_e2e.bats` invokes **real production code**:

| Case | Calls |
|------|-------|
| 1 (arch handoff) | `python3 -m skills.rdd_arch.scripts.write_arch_handoff_env` |
| 2 (planner handoff) | `python3 -m _lib.planner_handoff` |
| 3 (builder handoff + archive) | `python3 -m _lib.builder_handoff` + `openspec archive` |
| 4 (lifecycle) | `openspec archive` + `sync_iteration_after_archive` |
| 5-7 (error gates) | `check_arch_done_gate`, `archive_gate_check` |

There is **zero** in-process mocking or self-contained simulator logic.

## Relationship to upstream `chisuhua/rdd-workflow`

| Repo | Role |
|------|------|
| [chisuhua/rdd-workflow](https://github.com/chisuhua/rdd-workflow) | Product (the CLI + skills + libraries) |
| [chisuhua/rdd-workflow-e2e](https://github.com/chisuhua/rdd-workflow-e2e) | **External test bed (this repo)** |

The product repo's `tests/` runs in-process; this test bed runs as an external consumer.
**Both** must pass for a release.

The product repo's `AGENTS.md` points at this repo for nightly-cron-based regression detection
(see `chisuhua/rdd-workflow` README §测试基础设施).

## Local development loop

When working on `chisuhua/rdd-workflow` and wanting to re-run the test bed against your changes:

```bash
# In chisuhua/rdd-workflow (your dev repo)
# ... make changes ...

# In chisuhua/rdd-workflow-e2e (this repo)
./install_testbed.sh --symlink     # use local checkout, not remote
RDD_WORKFLOW_REPO="$HOME/.agents/skills/rdd-workflow" bats tests/
```

The `--symlink` mode means edits to `chisuhua/rdd-workflow/_lib/...` are picked up
immediately without re-installing.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `❌ RDD_WORKFLOW_REPO not found` | rdd-workflow not installed | `./install_testbed.sh --clone` |
| `ModuleNotFoundError: No module named '_lib.builder_handoff'` | PYTHONPATH not injected | Set `RDD_WORKFLOW_REPO` or run `./install_testbed.sh --status` |
| `not a rdd-workflow project` from `rddf` | `cwd` lacks `.rddf/state/` | Run from `RDD_WORKFLOW_REPO` (or any rdd-workflow-installed repo) |
| Tests pass locally but fail in CI | Branch mismatch — CI runs `--clone` (master), not your branch | Open a PR — `pull_request` trigger runs against the PR branch |

## License

MIT (matches upstream `chisuhua/rdd-workflow`).