# harness — O 层观测（P0）

只读 `opencode.db` 的离线快照，产出可复算指标。**不修改被测仓、不调用模型。**

## 用法

```bash
# 全流程：快照 → 指标 → manifest → 报告（默认 DB ~/.local/share/opencode/opencode.db）
python3 -m harness.run all

# 从已有快照重算（不重新快照；等价于同一快照重跑）
python3 -m harness.run report --snapshot ~/.local/share/rddf-harness/snapshots/<sha>.db

# 单独步骤
python3 -m harness.run snapshot --db <path> --out <dir>
python3 -m harness.run metrics  --snapshot <db>

# 单元测试（合成库 fixture，无外部依赖）
python3 -m unittest discover -s harness/tests -t .
```

产物（默认 `~/.local/share/rddf-harness/`，不进 git）：

```
snapshots/<sha256>.db          # SQLite backup + integrity_check
runs/<UTC-stamp>/
  metrics.json                 # 指标（排序键稳定）
  run-manifest.json            # kind=metrics / snapshot_sha256 / metrics_version / metrics_sha / granularity
  report.md                    # 人读报告
  determinism.json             # 同一快照两次计算是否一致
```

## 口径（ADR-0005 §1）

- 一行 = 一个**根 session**；子会话按 `parent_id` 归并到根。
- 成功率分母 = `succeeded + failed + interrupted + unknown`；`idle_outcome` 为 null 归 `unknown` 并计入分母。
- 成本 `sum` 跳过 null；`cost_coverage` = 有成本值的 session / 全部 session。
- 工具错误率 = `state.error` 非空的工具调用 / 工具调用总数；**必须与错误类别分布同读**：
  `permission.rejected`（该 agent 无权用该工具）是设计行为，单列 `permission_denied`，不计入
  `tool_execution_error_rate`（= 1 − (权限拒绝 + 中断 + 供应商故障) / 调用总数）。
- `unknown_rate` = `idle_outcome` 缺失的根会话占比（P0 实测 8.96%）⇒ 正确性信号有缺口。
- 时延 p50/p95 按根簇的 `min(time_created) → max(time_updated)`。
- 报告中同时给「按 agent（全部 session）」与「按根 session 的 agent」两张表：前者看执行者分布，后者是 P0 的率口径。

## 设计约束

- 快照必须用 SQLite `backup` API（WAL 下裸拷贝会撕裂）；先写临时文件，`integrity_check` 通过后再按内容哈希命名。
- 指标公式写死在代码里（`metrics_version`），改公式必须升版本（ADR-0005 `metrics_version` 变更门）。
- JSON 解析失败计入 `parse_errors`，不中断计算。
- 不读/不写 `~/.config/opencode` 与 `rdd-workflow`。

## 已知限制（P0 范围）

- 只做 **O 层**：不做评测、不调用模型、不跑 runtime 用例。
- 时延是 session 簇窗口，不是单次模型调用时延（P1 trace 再细化）。
- 子会话的「成功率」按自身 `idle_outcome` 统计，与根簇率是不同口径。
- `cost` 在订阅型 provider 下可能为 0，`cost_coverage` 只反映「字段非空」而非「真实计费」。

## 关联

- ADR-0001（数据面与归属）、ADR-0002（trace 合同，P1）、ADR-0005（指标口径）
- 架构：`docs/architecture/agent-harness-and-rsi.md` §4
