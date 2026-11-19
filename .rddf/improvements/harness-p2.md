---
优先级: P2
来源: "ADR-0004 + 架构 §6"
阶段: phase-3
分类: harness
类型: feature
---

**优先级**: P2 | **来源**: ADR-0004，架构 §6
**阶段**: phase-3（挂起） | **分类**: harness | **类型**: feature

## Why

在 E 层稳定、判据可信之后，才允许「生成候选改进」。更早启动会退化为优化不可信的指标。

## What Changes

- `proposals/<id>.patch` + `<id>.md`（改什么/为什么/预期指标/回滚命令）。
- 安全核 manifest + 工具层写集限制（RSI 只能写 `proposals/`）。
- A/B：外部执行；arm 标签只由 runner 持有；**Δ 只作方向性**（分辨率 >5pp 期间）。
- 合并前置：contract 0 回归 + skip 纪律 + 判据审计完成 + 人审 + 回滚三元组。
- 一次作弊 ⇒ 冻结提案 + 审计受影响判据 + 只回滚同批次。

## Acceptance

- [ ] 安全核每条 glob 有「空改动 patch ⇒ deny」测试。
- [ ] RSI 写清单外路径被工具层拒绝并留痕。
- [ ] 合并带 A/B 两臂、Δ、每任务翻转数、排除的 grader。
- [ ] revert 后文件 blob hash 等于合并前，且重跑 held-out。
- [ ] 提案者 ≠ 审批者（provenance 由 harness 写入）。

## Capabilities

- 能生成候选改进并给出可复现的方向性证据。

## Impact

- 人审是瓶颈；预期收益为个位数百分点（见架构 §9 收益边界）。
- 恢复条件：capability 正式集 ≥30 条 且 连续 4 周中 ≥3 周报告被引用。
