# Roadmap — rdd-workflow-e2e Harness

> 说明：planner 的写集是 `.rddf/roadmap/**`，故路线图落在此目录；根 `.rddf/roadmap.md` 由 rdd-* 工具生成，本文件是人工维护的版本。

## Phase Skeleton
| Phase | Theme | Status | 依据 |
|-------|-------|--------|------|
| phase-1 | Harness O 观测层（P0） | active | ADR-0001 / 0002 / 0005、架构 §2/§4 |
| phase-2 | E 评测层（P1） | planned | ADR-0003 / 0006、架构 §5 |
| phase-3 | R 限域改进（P2） | deferred | ADR-0004、架构 §6 |

## 依赖与门禁

```
phase-1 (O) ──> phase-2 (E) ──> phase-3 (R)
    │                │                │
    │                └─ 恢复条件：P0 指标暴露出现有字段回答不了的具体问题（须落成文件，≥3 个问题 + 所需字段）
    └─ 完成判据：同一快照重跑必得同数
                                     └─ 恢复条件：capability 正式集 ≥30 条 + 连续 4 周中 ≥3 周报告被引用
```

## 本期（phase-1）交付

| # | 交付 | 判据 |
|---|---|---|
| 1 | 离线快照（SQLite backup + SHA256） | `PRAGMA integrity_check=ok`；快照可独立打开 |
| 2 | 指标脚本（公式写死，根 session 粒度） | 同一快照两次运行数值一致；报告含分母定义 |
| 3 | run-manifest（`kind=metrics`） | 含 `snapshot_sha256` / `metrics_version` / `metrics_sha` / `granularity` |
| 4 | 报告（Markdown + JSON） | 成功率/成本/错误率/失败聚类可复算 |
| 5 | 单元测试（合成库 fixture） | 覆盖分母、null、子会话归并、截断 |

## phase-2（P1）范围预告

- trace 合同（ATIF/EvalSpec 子集）+ delegate outcome 持久化（**跨仓变更需单独获批**）
- contract / capability 分层 + oracle 准入 8 条 + 判据审计（试点 10 条）
- 评测隔离：语义层 + 轻量档；容器档按 ADR-0006 触发线

## phase-3（P2）范围预告

- proposals + A/B（仅方向性）+ 人审 + 回滚三元组
- 安全核 manifest 与工具层写集限制
- 不启动条件：capability <30 条 或 报告连续 4 周无人引用

## 不做（phase-1）

- 不修改 `~/.config/opencode` 与 `rdd-workflow`；
- 不调用模型、不跑 runtime 用例；
- 不建 capability/adversarial 集；
- 不做 RSI / proposals / A-B。

## 关联

- 架构：`docs/architecture/agent-harness-and-rsi.md`
- ADR：`docs/adr/ADR-0001`、`ADR-0002`、`ADR-0005`（phase-1）；`ADR-0003`、`ADR-0006`（phase-2）；`ADR-0004`（phase-3）
- 调研：`docs/research/05-adoption-map-to-our-adrs.md`、`07-downloadable-datasets-matrix.md`
- 改进草稿：`.rddf/improvements/harness-p0.md`、`harness-p1.md`、`harness-p2.md`
