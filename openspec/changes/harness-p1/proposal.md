# harness-p1

**优先级**: P1

## Why

P0 只能回答「发生了什么」，不能回答「给定任务下行为是否达标」。需要 E 层：可复现 fixture + 机械 oracle + 分层任务集，才能把「改进」变成可判定的实验。

双路径（ADR-0007 / ADR-0008）把这条需求变成「可归因」需求：两个载体（内置角色矩阵 = 治理基座；rdd skill = 叠加层）**同时生效**，要回答「哪个阶段由谁承担」，就必须先有 ① 显式归属声明 ② 臂遮蔽 ③ 臂索引（`session_id ↔ run_id ↔ arm` 唯一映射）④ 双层测量口径。缺任一项，对照 run 不可复现、失败不可归因 —— 结论只能靠推理，不能靠证据。

本期**不跑真模型**：只交付让对照「可开工、可审计」的静态资产与单元测试；runner 与预算另立。

## What Changes

**In Scope**:

- **change-1（本期，不跑真模型）** — 归属声明 `harness/path-config.yaml`：每行 `{阶段, 当前承担者, 证据强度, 移动门槛, 证据集}`；版本 = 内容哈希 `path_config_version`（ADR-0007 决策 4）
- **change-1** — 归属声明校验器：五列非空 lint + 阶段集合与主题文档 §2 对账 + 迁空 tripwire（叠加层阶段数 = 0 ⇒ 红；基座阶段数 = 0 ⇒ 不触发）（ADR-0007 Verification）
- **change-1** — `harness/safety-core.manifest` + sha256：安全核路径清单；**逐条核对 glob 与实际文件布局**（反例：`harness/metrics/**` 匹配不到单文件 `harness/metrics.py`）（ADR-0004 决策 4）
- **change-1** — ADR-0006 §5 判定 memo：威胁模型 diff 四项逐条结论 + 判定人（非实施者）+ 实现偏离假设时的复审条款；落 `.rddf/reviews/`（ADR-0006 §5）
- **change-1** — 遮蔽探针：`rdd-*` 成功调用 = 0 ∧ 列表不含 `rdd-*` ∧ 尝试调用返回 unknown-skill ∧ `rddf` 不在 PATH；与轻量档路径探针**共用同一框架**（一套实现，两种断言配置）（ADR-0008 决策 6）
- **change-1** — W0 通用 prompt 副本 + 变红演练：副本落 `harness/eval/**`；不含角色矩阵关键段（标记清单**版本化**）；构造「含关键段」的副本 ⇒ 必须判红（ADR-0008 决策 1）
- **change-1** — 臂索引 writer：五字段 `{session_id, run_id, arm, path_switches[], prompt_hash}`；落 runner 侧；单测用临时目录 + 环境变量覆盖，不写真目录（ADR-0008 决策 2；ADR-0001 决策 2）
- **change-1** — eval manifest 扩展：`kind=eval`，14 字段（含 `path_config_version` / `arms_index_sha256` / `budget_usd` / `cost_usd_actual`）；现状 `manifest.py` 只产 `kind=metrics`（ADR-0005 §3）
- **change-1** — cap 集首个 case 族：reference solution 通过 + 替代正确解通过 + 变红演练记录 + case 对 solver 不可达；准入按 ADR-0003 决策 3 的 8 条（ADR-0003 决策 3；主题文档 §6）
- **change-1** — 判据审计试点（10 条）：`auditor ≠ author`；1-operator 配置下写**局限声明**；缺陷率 > 10% 的冻结/解除机制有落点（ADR-0003 决策 4）
- **change-2（change-1 归档后）** — trace 投影：从 session DB 生成 unit trace（`(session_id, round_index)`）；`llm_call_count` 语义按 ADR-0002；`torn_lines` 容错；脱敏（ADR-0002）
- **change-2** — contract / adversarial 两档任务集：adversarial 先并入 contract 的 mutation 检查；capability ≥ 30 条后拆出；held-out < 50 条前手动切分（架构 §5.1 / §5.3）
- **change-2** — 轻量档隔离：工具层写集 + 评分目录权限位 + 独立评分进程 + 路径可达性探针（ADR-0006）

**Out of Scope**:

- delegate 运行时写 `traces/delegate-<session>.jsonl` 与 outcome 字段（`~/.config/opencode/lib/delegate-*.ts`）—— **跨仓变更，需单独获批**；ADR-0002 明写「本期不得默认开工」⇒ 对应 AC 标 `blocked`；unit 推导 / schema / `torn_lines` / 脱敏仍可验收
- runner（真模型 trial 执行 + 干净环境 + 预算熔断）—— **另立 change**；本期不造 ⇒ ADR-0008 的全部 run 级判据推迟（清单见「推迟清单」）
- 任何真模型调用与臂间 Δ 产出（`budget_usd` 字段先落结构，值为 0）
- 容器档评测（按 ADR-0006 §5 判定结论；若判「轻量档不足」则先做容器档重审）
- P2 的自动提案生成器（ADR-0007 的两条自动提案面判据属 P2）
- 生产侧归因（需 opencode 仓埋点，跨仓另议）

## Capabilities

- MUST：归属声明可版本化、可机判 —— `path_config_version`（内容哈希）进 eval manifest，且与文件内容相等。
- MUST：安全核路径清单可核 —— 每条 glob 有「与实际布局核对」的留痕 + `harness/safety-core.sha256` 校验。
- MUST：隔离档位判定可留证 —— ADR-0006 §5 判定 memo 落 `.rddf/reviews/`；未落盘 ⇒ 对照 run 不得开工。
- MUST：遮蔽状态可证 —— 探针覆盖四类遮蔽对象 + unknown-skill 尝试 + `rddf` 不在 PATH；未遮蔽环境判红。
- MUST：臂归属可回溯 —— 臂索引五字段 + `arms_index_sha256`；索引由 runner 独占，不进 trace / DB / solver 视野。
- MUST：判据可信度可量化 —— `judge_defect_rate` / `false_negative_rate` / 审计覆盖率进报告。
- MUST：评测版本可复现 —— `kind=eval` manifest 14 字段；回滚三元组（`patch` + `criteria_version` + `taskset_version`），归属修订追加 `path_config_version`。

## Impact

- 新增 `harness/path-config.yaml`、`harness/safety-core.manifest`、`harness/eval/**`；扩展 `harness/manifest.py`。
- 引入判据审计的持续人力成本（固定预算行）；1-operator 配置下审计独立性受限，须以局限声明替代（ADR-0003 决策 4 允许）。
- 跨仓依赖（delegate 持久化）**不在本仓 change 内**：需单独获批，否则只验收可投影部分。
- ADR-0006 §5 判定 memo 是**对照 run 的硬门**：memo 判「轻量档不足」时，change-2 的隔离工作量按容器档重审结论调整。
- 本期不消耗模型预算；`budget_usd` 字段先落 manifest 结构，值为 0。
- **ADR 状态**：ADR-0007 / ADR-0008 仍为 `Proposed`（双审已过、BLOCKER 已闭）。本 change 按其 Verification 立 AC，即作为其**裁决载体**：若裁决翻案，按变更项返工并更新本文件的 AC 出处。
- **安全核关系**：本 change 落在安全核路径内（`harness/path-config.yaml` / `harness/safety-core.manifest` / `harness/eval/**`）⇒ 按 ADR-0004 决策 2 **落地强制人审 + 安全核扫描**；白名单侧属「新增 fixture 与新增用例（只新增文件）」。

## Acceptance

> **本 change 的 AC = 下列 16 条（change-1）**。change-2 的 5 条与跨仓 blocked 的 2 条属于**后续 change**，列在文末「后续 change 的判据」节（刻意不使用 checkbox 形式，避免被计入本 change 的 AC 统计）。

### change-1（本 change）

- [ ] `harness/path-config.yaml` 存在；每行含五列；「证据强度」或「证据集」为空的行数 = 0（lint 命令可复跑）。
- [ ] 阶段集合与 `docs/architecture/dual-path-model.md` §2 的阶段表**相等**（机判，不是子集）。
- [ ] `path_config_version`（内容哈希）与 eval manifest 中的值相等。
- [ ] 迁空 tripwire 可执行：构造「叠加层阶段数 = 0」的声明 ⇒ 判红并要求第三档证据；构造「基座阶段数 = 0」⇒ **不触发**。
- [ ] 证据集过渡规则写死：change-1 期间允许引用既有 `tests/integration/**` 的 CS 用例；cap 族落地后改为必须解析到任务集注册表（空任务集时 lint 不得自相矛盾）。
- [ ] `harness/safety-core.manifest` 存在；每条 glob 有「与实际布局核对」的留痕（含 `harness/metrics.py` 单文件反例）；sha256 与文件一致。
- [ ] **ADR-0006 §5 判定 memo 已落 `.rddf/reviews/`**，含四项 checklist 结论 + 判定人（非实施者）+ 日期 + 偏离复审条款；**未落盘 ⇒ 对照 run 不得开工**（本条门住的是真模型 run，不是静态资产建设）。
- [ ] 遮蔽探针：禁用臂下 `rdd-*` 成功调用 = 0 ∧ 可用列表不含 `rdd-*` ∧ 尝试调用返回 unknown-skill ∧ `rddf` 不在 PATH；构造「未遮蔽」环境 ⇒ 判红（变红演练）。
- [ ] 探针断言方向**按臂条件化**（禁用臂断言不存在 / 启用臂断言存在），不写死方向。
- [ ] W0 prompt 副本：落 `harness/eval/**`；副本不含角色矩阵关键段（标记清单版本化，清单变更有记录）；构造「含 `【角色:` 片段」的副本 ⇒ 判红。
- [ ] 臂索引 writer 输出五字段；单测在临时目录运行，不写 `~/.local/share/rddf-harness/**`；`arms_index_sha256` 进 eval manifest。
- [ ] eval manifest 为 `kind=eval` 且 14 字段齐（缺字段 = 红）；与 `kind=metrics` 的字段集不混用。
- [ ] cap 集首族 case：reference solution 通过 ∧ 替代正确解通过 ∧ 一次变红演练记录 ∧ case 定义对 solver 不可达（路径探针）。
- [ ] 判据审计试点 10 条：`auditor ≠ author`；1-operator 局限声明在报告里；缺陷率 > 10% 时冻结扩量，冻结/解除的落点可查。
- [ ] 审计报告含 `judge_defect_rate` / `false_negative_rate` / 审计覆盖率，且 `judge_defect_rate` 的分母与抽样方法写明（ADR-0005 指标定义要求，缺则不得进安全核口径）。
- [ ] **本 change 不跑真模型**：CI 中无任何模型 API 调用 / 无 `cost_usd_actual` 非零记录（可机判）。

## 后续 change 的判据（不在本 change 验收）

> 以下条目属于 **change-2**（E 层主体）与**跨仓 blocked** 项，刻意不使用 `- [ ]` 形式 —— 本 change 的 AC 只有上面 16 条。拆出依据见 improvement 的「change 边界」节。

**change-2（change-1 归档后）**

- trace 可独立于 opencode DB 聚合；`±2%` 抽样误差**仅校验 unit 化逻辑**（投影自同一 DB ⇒ 不构成双写对账）。
- contract / adversarial 两档可独立运行；adversarial 并入 contract 的 mutation 检查，capability ≥ 30 条后才拆出。
- held-out 与 case 定义对 solver 不可达（路径探针）；< 50 条前手动切分。
- 轻量档判据全部可勾选 —— **条件**：ADR-0006 §5 memo 判定轻量档足够；若判定不足 ⇒ 本条改为「容器档重审结论已落盘」。
- 运行前后 `~/.config/opencode` 与 `rdd-workflow` 的 `git status` 为空。

**blocked（跨仓未获批则不验收）**

- `traces/delegate-<session>.jsonl` 存在且含全部必填字段 —— **blocked on** `~/.config/opencode` 变更获批。
- outcome 字段组（`outcome` / `host_outcome` / `changed_files` 等）可读且语义正确 —— 同上。

## 推迟清单（本 change 不验收）

| 条目 | 出处 | 理由 |
|---|---|---|
| 自动提案面 ⊆ 白名单类型；自动提案集 ∩ 实现类路径 = ∅ | ADR-0007 Verification | 判的是 **P2 的 RSI 提案生成器**；P2 挂起，P1 无生成器 |
| 两类改进提案的人审清单 diff 非空 | ADR-0007 Verification | 同上（提案流程属 P2） |
| 臂索引 ↔ trace 的 join 命中率 = 100% | ADR-0008 Verification | 需 runner 产出真 trial |
| `excluded_by_path_switch` / `excluded_overlay_induced` 计数与占比、对称剔除占比阈值 | ADR-0008 决策 4 | 需对照 run |
| 四类翻转数、拒收数、`same-score-different-behavior` 变红与正向对照 | ADR-0008 决策 4 | 需对照 run |
| 成本熔断、partial 补配、臂序随机化 | ADR-0008 决策 5 | 需真模型与预算 |
| 干净环境四类遮蔽对象的按臂条件化断言（两种臂序各跑一次） | ADR-0008 Verification | 需 runner 控制臂序 |
| W0 / W1 / W2 的 `prompt_hash` 互不相等（仅副本自身哈希与「不含关键段」在 change-1 验收） | ADR-0008 Verification | 需三臂真跑 |
| 报告结构断言（无总分章节、三臂单独成表、结论字段取值域、匿名臂名 / `--reveal` 留痕） | ADR-0007 决策 2 / ADR-0008 Verification | 需报告生成器 + 对照 run |
| `taskset_size` 与 `cases` 对账、分母分列与偏差声明 | ADR-0008 Verification | 需对照 run |

---

**产出说明**：本 proposal 由 rdd-builder P0 从 `.rddf/improvements/harness-p1.md` 生成；生成器把表格行平铺为 scope 条目，已按 improvement 的小节语义重排（In Scope = change-1 / change-2 交付物，Out of Scope = 外部依赖与本期不做项，推迟清单归入 Acceptance）。**内容以 improvement 为准**。

**spec delta**：本 change 在 `.openspec.yaml` 声明 `skip_specs: true` —— ① 生成器侧 delta 是 opt-in，improvement 未声明 `**delta**` ⇒ P0 不生成（`openspec/specs/` 下无主 spec，`modified` delta 无既有 Scenario 可保留，声明它只会产出退化产物）；② 本仓的规范真源是 ADR（ADR-0004 把 `docs/adr/**` 列为「判据的判据」），openspec spec 层在本仓尚无能力目录；③ `skip_specs` 只表示「无 spec 级行为变更」，**不表示**「无判据」—— 23 条 AC 全部来自 ADR Verification。`openspec validate harness-p1` ⇒ valid。
