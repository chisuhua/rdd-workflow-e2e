---
优先级: P0
来源: "ADR-0001 / ADR-0002 / ADR-0005 + 架构 §2 分期"
阶段: phase-1
分类: harness
类型: feature
---

**优先级**: P0 | **来源**: ADR-0001/0002/0005，架构 §2（P0 只做 O 层）
**阶段**: phase-1 | **分类**: harness | **类型**: feature

## Why

多智能体行为（角色矩阵、委托、审查配对、权限门）目前没有统一观测视图：一次委托做了什么、错了没有、花了多少，散落在 session DB、NDJSON、`.rddf` 状态文件里。没有可复算的基线，任何「改进」都无法归因，也无法判断是否真的变好。

本项是整个 harness 的 P0：只回答「过去 N 周按 agent/项目的成功率、工具错误率、成本、Top 失败模式」，且**同一快照重跑必得同数**。它不修改被测仓、不调用模型。

## What Changes

新增 `harness/`（Python 标准库，无第三方依赖）：

| 文件 | 职责 |
|---|---|
| `harness/snapshot.py` | 用 SQLite `backup` API 对 `opencode.db` 做离线快照；`PRAGMA integrity_check`；输出 SHA256 |
| `harness/metrics.py` | 从快照只读计算指标（公式写死；根 session 粒度；子会话按 `parent_id` 归并） |
| `harness/manifest.py` | 写 `run-manifest.json`（`kind=metrics`） |
| `harness/run.py` | CLI：`snapshot → metrics → manifest → report` |
| `harness/tests/` | 合成库 fixture 的单元测试（unittest） |
| `harness/README.md` | 用法与口径说明 |

产物默认落 `~/.local/share/rddf-harness/`（不进 git）：`snapshots/<sha>.db`、`runs/<ts>/{report.md,metrics.json,run-manifest.json}`。

## Acceptance

- [ ] 快照：`integrity_check=ok`；快照文件可独立打开且不依赖 WAL。
- [ ] 指标：同一 `snapshot_sha256` 连续两次运行，所有数值一致。
- [ ] 成功率分母含 `unknown`（`idle_outcome` null），并同时输出剔除 unknown 的分口径值。
- [ ] 成本 `sum` 跳过 null，并输出 `cost_coverage`。
- [ ] 子会话 token/cost 归并到根 session，不重复计。
- [ ] 工具错误率 = 非空 `state.error` 的工具调用 / 工具调用总数。
- [ ] 报告含 Top 失败模式（`tool name + error` 聚类）与写目标分布。
- [ ] `run-manifest.json` 含 `kind/snapshot_sha256/metrics_version/metrics_sha/generated_at/tool_version/granularity`。
- [ ] 单元测试覆盖：分母口径、null 处理、父子归并、损坏/截断容错。
- [ ] 运行前后 `~/.config/opencode` 与 `rdd-workflow` 的 `git status` 为空。

## Capabilities

- `python3 -m harness.run snapshot`：生成快照 + SHA。
- `python3 -m harness.run metrics --snapshot <db>`：输出 metrics.json。
- `python3 -m harness.run report --snapshot <db>`：输出 report.md + manifest。
- `python3 -m unittest discover -s harness/tests`：单元测试。

## Impact

- 新增目录 `harness/`（约 5 个模块 + 测试）。
- 不改任何现有测试与代码路径。
- 不触碰被测仓；只读 `opencode.db`。
- 后续 phase-2 的 trace/评测、phase-3 的 RSI 都以本项产出的指标口径为基线。
