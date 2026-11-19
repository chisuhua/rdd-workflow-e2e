# P0 实测发现与口径回写（2026-11-20）

| 字段 | 值 |
|---|---|
| 数据 | `opencode.db` 快照 SHA256 `c4f1e85c0848aa3620b6fc072e1fde20a251142bcd146bf093b394277915c42d`（1.3 GB，1,854 sessions） |
| 窗口 | 2026-10-12 → 2026-11-19 |
| 产出 | `~/.local/share/rddf-harness/runs/<UTC>/{report.md, metrics.json, run-manifest.json, determinism.json}` |
| 复算 | 同一快照两次计算 `deterministic: true` |

## 1. 关键数字

| 指标 | 值 |
|---|---|
| session 总数 / 根 / 子 | 1,854 / 837 / 1,017（孤儿 0） |
| 成功率（含 unknown） | **0.8232** |
| 成功率（剔除 unknown） | 0.9042 |
| unknown 率 | **75 / 837 = 8.96%** |
| 工具调用 / 错误 / 原始错误率 | 142,349 / 3,157 / **2.22%** |
| 错误类别 | `permission.rejected` 1,488（47%）· `tool.execution` 1,035 · `unknown` 468 · `aborted` 127 · `tool.input-json` 35 · `provider.*` 4 |
| 执行失败率（去权限拒绝/中断/供应商故障） | **1.08%**（1,538 / 142,349） |
| 总成本 / 每根 session 平均 | 319.18 / 0.381（cost_coverage = 1.0） |
| 时延 p50 / p95 | 44.3 s / ≈16.4 h |
| 委托深度 | 深度 1：126 根；深度 2：3 根 |
| 消息类型 | assistant 120,413 · user 4,449 · model-switched 1,024 · agent-switched 592 · idle 4,427 · compaction 393 · location-switched 9 |

## 2. 三个发现

### 发现 1 —— 原始错误率严重高估真实失败（回写 ADR-0005）

Top 失败模式第一是 `shell: {"type":"permission.rejected","message":"Permission denied: shell"}`，**1,345 次**；`permission.rejected` 合计 1,488，占全部错误 **47%**。这些是「该 agent 无权用该工具」的设计行为（explore / oracle / general 等无 shell 权限），不是失败。

⇒ 回写三条指标口径：
- `error_classes`：按 `state.error` 的 `type` 分类计数；
- `permission_denied`：单列，不计入执行失败；
- `tool_execution_error_rate` = `1 − (permission.rejected + aborted + provider.*) / 调用总数`（保守口径：未分类与 unknown 计入执行失败）。

### 发现 2 —— `idle_outcome` 缺失率 8.96%（正确性信号有缺口）

75/837 根会话 `idle_outcome` 为 null（归 unknown 并计入成功率分母）。successed+failed+interrupted 的和与根会话数差 75。

⇒ 回写 `unknown_rate` 指标；并确认 P1 的 **delegate outcome 持久化是刚需**（ADR-0002），不是可选项。

### 发现 3 —— 会话内存在模型/agent 切换，P1 的 unit 切分确有必要

`model-switched` 1,024 条、`agent-switched` 592 条、`compaction` 393 条消息；时延 p95 ≈ 16.4 h 明显异常（簇窗口被长跑会话拉长）。

⇒ P1 的 unit 切分规则（ADR-0002 决策 1：`idle` 后的 `user` 消息递增 `round_index`）有实测支撑；时延需细化到调用级。

## 3. 回写清单（本次改动）

| 位置 | 改动 |
|---|---|
| ADR-0005 §1 指标表 | 新增 `unknown_rate` / `error_classes` / `tool_execution_error_rate` 三行（含 P0 实测值） |
| ADR-0005 元数据 | 增加「后审补写」行，标注**未经 critic 复审** |
| `harness/metrics.py` | 计算上述三指标；`METRICS_VERSION` 升 `p0-metrics-v2`、`TOOL_VERSION` 升 `harness-p0-v2` |
| `harness/run.py` | 总览表增加三行；口径段写明「原始错误率必须与类别分布同读」 |
| `harness/README.md` | 口径同步 |
| `harness/tests/test_metrics.py` | 增加 `unknown_rate` / `tool_execution_error_rate` 断言 |

**口径变更必须升 `metrics_version`**（ADR-0005 的 `metrics_version` 变更门）：本次由 `p0-metrics-v1` 升 `p0-metrics-v2`，旧 manifest 与新 manifest 的指标集不可直接比较。

## 4. 复核状态

- 本次回写发生在 critic 第 4 轮之后，**未经新一轮 critic 评审**（评审预算已用满 4 轮）。
- 变更性质：**口径补充**（新增三个只读指标 + 一个派生率），不改动既有指标的定义与分母口径；`success_rate` / `cost` / `tool error_rate` 的算法未变。
- 若需独立背书，需用户批准第 5 轮（只验这三条新增指标与版本升级）。

## 5. 顺带发现（与 P0 无关，但值得记录）

- 默认 e2e 套件有 **8 个失败**，全部源于上游 rdd-workflow 提交 `d7a7b2d0`（退役 guide skill）移除了 `rddf_session_hook_poll_events`；在 pristine HEAD 树上可复现 ⇒ 已基线化到 `tests/KNOWN_FAILURES.txt`（附证据），回归报告现为「已知失败 8 / 新增失败 0」。
- 本仓 `.gitignore` 原先忽略整个 `.rddf/`，导致 planner 的 `roadmap/` 与 `improvements/` 无法入库；已改为「忽略 `.rddf/*` 但放行 `roadmap/`、`improvements/`、`config/`」。
