# ADR-0002: 统一 trace 与 outcome 合同

| 字段 | 值 |
|---|---|
| Status | Proposed |
| Date | 2026-11-19 |
| Author | architect |
| 审稿报告 | `.rddf/reviews/harness-adr-review.md`（oracle + metis → critic；BLOCKER 已闭合） |
| Parent | ADR-0001 |
| 关联 change | `backlog: harness-p1` |
| 分期 | **P1**（P0 只做 session DB 指标，不实施本 ADR） |
| AC 映射 | 暂缺（change 未立项） |

## 背景与问题

观测数据分散且语义不一致：

- session DB：有 agent / model / cost / tool 调用 / `idle_outcome`，但**没有交付正确性**；
- delegate 层：`lib/delegate-core.ts` 已定义 `outcome` / `host_outcome` / `blocked_reason` / `last_assistant_text` / `changed_files`，但**没有持久化**；
- `.rddf/state/ledger.jsonl`：实测只有 role lease 事件（全系统 4 行），**不是委托数据面**；
- e2e NDJSON：字段接近契约，但只覆盖测试跑批；
- 一次 session 可被 resume、可中途 fallback 模型、可跨目录（`session_move`）——「一条 trace = 一个 session」不足以定义分析单元。

## 决策

1. **分析单元**：`unit_id = (session_id, round_index)`，一个 unit 一行 NDJSON。
   - **P0 不实施本 ADR**：P0 的率按**根 session** 计（见 ADR-0005「行粒度」）；P1 切换到 unit 时报告标注断点，趋势不拼接。
   - **unit 的推导规则**（P1）：`round_index` 从 **0** 开始；在每次「`idle` 之后的 `user` 消息」处递增；首个 `idle` 之前不产生独立 unit；resume 产生新 unit 并通过 `resume_of` 关联。
   - 实测 `session_message.type` 已包含 `model-switched`（992 条）与 `agent-switched`（592 条），可直接填充 `model_switches` / `agent_switches`，不需要额外埋点。
2. **定义 `trace_version: 1`**，一个 unit 一行 NDJSON。
3. **必填字段**：

| 组 | 字段 |
|---|---|
| 标识 | `trace_version`, `unit_id`, `session_id`, `parent_session_id`, `round_index`, `resume_of` |
| 项目 | `project{name, worktree, state_root, sha}`（worktree 与 stateRoot 分开记录） |
| 执行者 | `agent`, `role_class`, `model{provider, id, variant}`, `model_switches[]`, `agent_switches[]` |
| 派发面 | `dispatch_face(sync|async)`, `outcome_source(host|derived|ac_verdict)` |
| 输入 | `prompt_hash`, `prompt_files[]`, `prompt_agents[]` |
| 轨迹 | `tool_calls[{name, status, error, target}]` |
| 结果 | `outcome`, `host_outcome`, `blocked_reason`, `changed_files[]`, `diff_ref`, `unverified_reason` |
| 成本 | `cost`（可为 null）, `cost_coverage`, `tokens{input, output, reasoning, cache_read, cache_write}`, `duration_ms` |
| 完整性 | `trace_incomplete`, `torn_lines` |
| 环境 | `opencode_sha`, `product_sha`, `prompt_version`, `snapshot_sha`, `time_created`, `time_updated` |

4. **outcome 持久化**：由 delegate 收尾写独立 NDJSON（`traces/delegate-<session>.jsonl`），**不写入 `ledger.jsonl`**。该改动属于 `~/.config/opencode` 运行时变更，**必须作为独立的跨仓治理变更获批后实施**；本期不得默认开工。
5. **交叉校验**：trace 上线后，首月必须与 P0 的 session DB 指标并行计算，允许误差阈值内（成功率、成本、tool 错误率各 ±2%），否则以 SQL 基线为准并标记 `trace_incomplete`。
6. **完整性指标**：`trace_incomplete` 率、`torn_lines` 数、`cost_coverage` 三项列入夜间报告；`trace_incomplete` 率超过 5% 即告警。
7. **脱敏**：默认只落 `prompt_hash`；`last_assistant_text`、`blocked_reason`、`tool_calls.target`（含 shell 命令）按字段级规则脱敏；需要原文时显式开启 `HARNESS_KEEP_PROMPTS=1`，只写本地。
8. **保留期**：raw trace 90 天；聚合指标永久；`proposals/` 保留到合并或拒绝后 180 天。需要跨 90 天复现的结论，必须同时保留当时的 `snapshot_sha` 与聚合值。
9. **版本演进**：字段只增不改语义；破坏性变更升 `trace_version`，旧版本继续可读。

## 选项对比

| 选项 | 结论 | 理由 |
|---|---|---|
| A. 复用 `ledger.jsonl` 存委托结果 | 否（但否定理由不绝对） | 现只有 4 行 lease 事件，加 `type` 可隔离；选独立文件是因为与 e2e NDJSON 消费方式一致、便于版本化 |
| B. 独立 NDJSON trace 数据面 | **选中** | 追加写、易聚合、可版本化 |
| C. 只依赖 opencode DB | 否 | schema 不受本仓控制；无 `outcome` 语义；难以注入 `product_sha` |
| D. 每仓各自定义格式 | 否 | 会产生多套口径 |
| E. 按 session 而非 unit 聚合 | 否 | resume / 多轮会把不同结论混在一起，分母不可复算 |

## 后果 / 代价

**正面**

- 分析单元明确，率可复算、可与 DB 对齐。
- outcome 落盘后，交回率与 verdict 从文本抽取变为字段读取。
- 完整性指标让「指标空洞」可见。

**负面**

- 需要修改宿主运行时（跨仓），且失败只告警 ⇒ 必须有交叉校验与完整性阈值。
- `trace_version` 演进需要读取端兼容。
- 90 天保留期限制长期复现。

**风险**

- **信任根**：trace 由被观测进程自己写，被测 agent 可以少写、改字段或让 append 失败。缓解：SQL 基线交叉校验 + `trace_incomplete` 指标 + 审计日志独立落点。
- resume / 多槽位 / 中途 fallback 会让单变量比较失效。缓解：unit 级切分 + `model_switches` 记录；A/B 只比较 model_switches 为空的 unit。
- 半行 JSON：读取端容忍截断并计 `torn_lines`，不静默丢样本。
- 脱敏漏项：`redactAndTruncate` 目前只覆盖部分 token 前缀；需补 JWT / Basic / `.netrc` 形态单测。

## Verification

- [ ] 任意一次委托结束后，`traces/delegate-<session>.jsonl` 存在且含上表全部必填字段。
- [ ] 同一 unit 的 trace 与 session DB 的 `agent` / `model` / `cost` 在 ±2% 内一致（抽样 50 个 unit）。
- [ ] resume 两次的 session 产生 3 个 unit，且 `resume_of` 链正确。
- [ ] 多模型 session 的 `model_switches` 非空，A/B 选择器能排除该 unit。
- [ ] 默认配置下 trace 中不含 prompt 原文（grep 抽样）。
- [ ] 删除 opencode DB 后，已有 trace 仍可独立聚合。
- [ ] 截断最后一行后，读取端输出 `torn_lines=1` 而不是崩溃或静默丢弃。
- [ ] `trace_incomplete` 率 >5% 时夜间报告出现告警。
- [ ] delegate 收尾写失败时，主流程仍返回成功，且告警计数进入报告。
- [ ] 跨仓变更获批记录存在于 ADR 或 change 中，且 P0 未触碰宿主。
