---
优先级: P1
来源: "ADR-0003 / ADR-0006 + 架构 §5"
阶段: phase-2
分类: harness
类型: feature
---

**优先级**: P1 | **来源**: ADR-0003/0006，架构 §5
**阶段**: phase-2 | **分类**: harness | **类型**: feature

## Why

P0 只能回答「发生了什么」，不能回答「给定任务下行为是否达标」。需要 E 层：可复现 fixture + 机械 oracle + 分层任务集，才能把「改进」变成可判定的实验。

## What Changes

- **trace 合同**（ATIF/EvalSpec 子集）：unit = `(session_id, round_index)`；`llm_call_count` 语义；`criteria_version`/`taskset_version` 入 manifest。
- **delegate outcome 持久化**：改 `~/.config/opencode/lib/delegate-*.ts`（**跨仓变更，需单独获批**）。
- **任务集三档**：contract（CI）/ capability（夜间本机 cron）/ adversarial（初期并入 contract 的 mutation 检查）。
- **oracle 准入 8 条**：reference solution 通过、替代正确解通过、干净环境、case 不可达、审计记录、变更后重跑变红等。
- **判据审计**：试点 10 条（首批用现有 CS 用例）；新增用例 100% 审计；`judge_defect_rate` / `false_negative_rate` 入报告。
- **评测隔离**：语义层 + 轻量档（路径探针 + 权限位 + 独立评分进程）；容器档仅按触发线。

## Acceptance

- [ ] trace 可独立于 opencode DB 聚合；与 DB 抽样误差 ≤2%。
- [ ] 每条正式用例有 reference solution 且通过 oracle；替代正确解也通过。
- [ ] held-out 与 case 定义对 solver 不可达（路径探针）。
- [ ] 判据审计记录齐全（`auditor ≠ author`），试点缺陷率 >10% 时冻结扩量。
- [ ] 报告含 `judge_defect_rate` / `false_negative_rate` / 审计覆盖率。
- [ ] 容器档未启动时，轻量档判据全部可勾选。

## Capabilities

- 能回答「目标类 pass^k 在改动前后是否变化（仅方向性）」。

## Impact

- 引入判据审计的持续人力成本（固定预算行）。
- 跨仓变更（delegate 持久化）需用户批准并作废旧拍板。
