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

## Test suite breakdown (42 cases, ~20s)| File | Cases | What it validates |
|------|------:|-------------------|
| `tests/integration/test_full_workflow_e2e.bats` | 7 | Full arch→planner→builder→archive workflow with real handoff contracts (ADR-0016 v3 schema, planner-handoff-v1, builder-handoff-v1, iteration schema) |
| `tests/integration/test_rddf_cli_all_subcommands.bats` | 6 | All 36 `rddf` subcommands exposed via `--help`; basic commands work |
| `tests/integration/test_install_global.bats` | 6 | `install.sh --global` works: 27 symlinks, `rddf` in PATH, `_lib` Python importable |
| `tests/integration/test_external_project_smoke.bats` | 5 | Every SKILL.md has valid YAML frontmatter + name/description/license + semver version |
| `tests/integration/test_stage_guide_cross_process_e2e.bats` | 6 | Cross-process (real subprocess.Popen + fcntl contention) for feat-guide-orchestrator-session-event-bus: fcntl concurrent writes, last_seen_offset polling, crash recovery, H7 singleton, archive-triggered reset, guide_entry persistence |
| `tests/integration/test_guide_polling_loop_e2e.bats` | 3 | Closed polling loop for add-guide-polling-loop-implementation (v4.1): AC-G1 guide reads window-B events, AC-G2 last_seen_offset monotonic advance, AC-G3 archive-triggered offset reset + re-read |
| `tests/_lib/test_full_workflow_fixture_*.bats` | 12 | Per-function unit tests of the E2E fixture helpers |
| `tests/integration/test_front_delegate_runtime.bats` | 26 | **真实运行时**（`E2E_REAL_RUNTIME=1` 才跑）：front agent 驱动的委托面契约 —— 工具门控 / 真委托 / pair+role 登记 / scope 越界 / busy / 续接 / 知识 session / ledger / 权限加固 / 异步派发（dispatch·sessions·suspend·cancel）|
| `tests/integration/test_subagent_contract_runtime.bats` | 11 | **真实运行时**（同上门控）：subagent 输入契约门 —— L3 注入 / L1 warn-vs-enforce / L2 兜底检出 / 合规放行 / 豁免三路径（任务陈述区关键词、尾部关键词不算、跨对象不继承）/ 续接轮 / 逐 agent 覆盖 / off / 审计 CLI |

Total: **45 in-process cases, ~25s runtime** (was 42, +3 from add-guide-polling-loop-implementation).

**Plus 37 real-runtime cases** (`test_front_delegate_runtime.bats` 26 + `test_subagent_contract_runtime.bats` 11) that are **skipped by default** because they need a real model + real host (`opencode run`), not available in CI:

```bash
E2E_REAL_RUNTIME=1 TMPDIR="$PWD/.tmp-sc" bats tests/integration/test_subagent_contract_runtime.bats
E2E_REAL_RUNTIME=1 TMPDIR="$PWD/.tmp-l2" bats tests/integration/test_front_delegate_runtime.bats
```

### subagent 输入契约运行时测试（`test_subagent_contract_runtime.bats`）

被测对象是 **`~/.config/opencode`**（用户配置仓）里的 subagent 输入契约门，不是 rdd-workflow 的 Python 侧：
`plugins/subagent-contract.ts`（L3 注入 / L1 硬门 / L2 检出）、`lib/subagent-contract-core.ts`（规则真源与豁免语义）、
`scripts/audit-subagent-prompts.ts`（审计 CLI）。默认从 `$HOME/.config/opencode` 读，可用 `SC_SRC=<path>` 覆盖。

隔离方式是 **hermetic HOME**：`HOME` 指到 `.tmp-sc/home` ⇒ 契约配置、契约日志、会话 DB 全部隔离；配置目录用
**符号链接农场**指向真实安装态（只有 `subagent-contract.json` 是真文件）⇒ 测的是真实插件，但任何配置写入都落在临时副本里。
凭据 `auth.json` / `account.json` 用链接带过来（否则 provider 401）。

断言只取**结构性事实**：契约日志（`gate`/`level`/`mode`/`exempted`/`violations`）、NDJSON 里 `subagent` 工具调用的
`status`（completed / error）与错误文案、隔离 DB 里子会话是否被创建 —— 不断言模型措辞。

⚠️ 每个用例都会真实调用模型（父会话 build + 可能的子会话 critic）。父模型默认**按候选顺序自动挑一个当前有额度的**
（`commandcode → opencode-go → minimax-cn`，可用 `SC_PARENT_MODEL=...` 指定、`SC_PARENT_MODEL_CANDIDATES=...` 改候选），
额度全满时整文件 skip；默认 `SC_CASE_TIMEOUT=180s`，provider 报 rate-limit 或父会话超时且无任何工具调用时**单例 skip**；
`opencode run --standalone` 会留下 `serve` / `pty` 守护进程，setup/teardown 会按 `OPENCODE_DB` 前缀精确清理。

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
│                              │     ├─ test_subagent_contract_runtime│  │
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