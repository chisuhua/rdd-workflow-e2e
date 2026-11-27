# ADR-0005: 度量、CI gate 与版本 pin

| 字段 | 值 |
|---|---|
| Status | Proposed |
| Date | 2026-11-19 |
| Author | architect |
| 审稿报告 | `.rddf/reviews/harness-adr-review.md`（oracle + metis → critic；BLOCKER 已闭合） |
| 外部依据 | `docs/research/01-harness-and-eval-engineering.md`（统计与成本口径）、`docs/research/03-safety-permission-and-eval-integrity.md`（判据缺陷与作弊） |
| 后审补写 | 2026-11-20：P0 实测回写「未知率 / 错误类别分布 / 执行失败率」三条指标（未经 critic 复审，理由与证据见 `docs/research/08-p0-findings-and-writeback.md`） |
| Parent | ADR-0001 |
| 关联 change | `backlog: harness-p0`（指标定义与 manifest）；`backlog: harness-p1`（gate 与夜间） |
| AC 映射 | 暂缺（change 未立项） |
| 本次修订 | 2026-11-27：`kind=eval` manifest 增 `manifest_version`、`path_config_version`、`arms_index_sha256`、`budget_usd`、`cost_usd_actual`（共 14 字段）+ 字段演进规则 + `prompt_version` 多臂并集口径 + 归属修订的四元组回滚集。**指标定义、分母口径、gate 语义一律不变**（指向 ADR-0007 / ADR-0008） |

## 背景与问题

指标全部进 CI 会带来成本与 flaky；都不进 CI 又无法阻止回归。同时，评测结论必须可复现，而当前 `install_testbed.sh` 使用 `git clone --depth 1`（无 SHA），「夜间」也没有明确的执行位置（GitHub Actions 无模型凭据、无 `~/.local/share`）。

P0 的成功判据是「指标可复算」，因此本 ADR 的第一要务不是 gate，而是**把指标公式写死**。

## 决策

### 1. 指标定义（P0 即生效）

**行粒度（唯一口径）**

- **P0：一行 = 一个根 session**（子会话按 `parent_id` 归并到根）；成功率、时延、成本均按 session 计。
- **P1 起：一行 = 一个 unit**（定义见 ADR-0002）。切换时报告必须标注 `granularity=session|unit`，且 P0 与 P1 的趋势**不可拼接**。
- **P0 的 resume 归属**：同一 session 的所有轮次合并计一个结果，不按轮次拆分；`resume_attempts` 单列。实测 `resume_attempts>0` 的 session 仅 1 个，影响可忽略，但必须在报告中声明。

| 指标 | 公式 / 边界 |
|---|---|
| 成功率 | `succeeded / (succeeded + failed + interrupted + unknown)`；`idle_outcome=null` 归 `unknown`，**计入分母**；同时输出「剔除 unknown」的分口径值。P0 按 session 行计 |
| 工具错误率 | `count(tool calls with non-empty state.error) / count(tool calls)` |
| 成本 | `sum(cost)` **跳过 null 值**（不按 0 计），单列 `cost_coverage = non_null / total` |
| token | 子会话按 `parent_id` 归并到根会话后求和，避免重复计 |
| 时延 | `time_updated - time_created`；P0 按 session，P1 按 unit；报 p50/p95 |
| 委托深度 | 从根会话到叶子的 `parent_id` 链长度 |
| 失败模式 | 按 `tool name + error code` 聚类，保留原始字符串样例与计数 |
| 一致性 | capability 层主用 **pass^k**（k 次独立试验全成功）；引用 pass@k 时必须用无偏式 `1 - C(n-c,k)/C(n,k)`，不得用有偏的 `1-(1-p)^k` |
| 判据缺陷率 | `judge_defect_rate` = 审计确认有缺陷的 oracle 数 / 被审计的 oracle 数。**估计量定义**：抽样框 = 全部正式用例（新增用例 100% 审计，存量按季度抽样）；缺陷分类 = {过窄, 过宽, 可绕过, 依赖环境}；双人背对背审、分歧裁决；发现缺陷 ⇒ 该用例作废并重审，不得沿用旧结论。分母与抽样方法必须进报告，否则该指标不得进安全核口径。**阈值（唯一真源）**：试点 10 条缺陷率 > 10% ⇒ 冻结扩量、先修判据。**1-operator 配置**：RSI 为 author 时人作 auditor；人自撰用例时用独立 AI 会话交叉审并留痕、报告声明其局限 |
| 未知率 | `unknown_rate` = `idle_outcome` 缺失的根会话 / 根会话总数。**P0 实测 8.96%（75/837）** ⇒ 正确性信号有缺口，须与成功率同读 |
| 错误类别分布 | `error_classes` = 按 `state.error` 的 `type` 分类计数（`permission.rejected` / `tool.execution` / `tool.input-json` / `aborted` / `provider.*` / 未分类） |
| 执行失败率 | `tool_execution_error_rate` = `1 − (permission.rejected + aborted + provider.*) / 工具调用总数`。**原始 `error_rate` 必须与类别分布同读**：权限拒绝是设计行为（该 agent 无权用该工具），单列 `permission_denied`，不计入执行失败。P0 实测：原始错误率 2.22%，其中 `permission.rejected` 占 47%（1,488/3,157）⇒ 原始错误率会严重高估真实失败 |
| 假阴性率 | `false_negative_rate` = 合法解被判失败的次数 / 合法解尝试次数（用 reference solution 与替代正确解构造）。这是唯一能惩罚「判据过严」的指标 |
| 作弊率 | `cheating_attempt_rate` = 识别到的作弊 attempt 数 / 总 attempt 数；**识别到的作弊一律计为失败**（METR 口径）。检测机制须写明（人工抽检 / 规则拒绝 / 判据审计发现），三者可并列 |
| skip 率 | `skipped / total cases`；gate 读四元组 `executed/pass/fail/skip` |
| 恒真检查 | fixture 初始必须绿；初始红即判该用例无效 |
| oracle 变异命中率 | 改坏受约束要素后必须红；命中率低于阈值即告警（原名「假绿率」，拆为上述三项） |

指标定义与行粒度都属于安全核：只能人改，且每次修改升 `metrics_version`。

### 2. 分层 gate

| 层 | 指标 | 是否 gate | 运行时机 |
|---|---|---|---|
| 确定性 | contract 通过、新增失败=0、skip 不超基线、schema、脱敏、安全核扫描 | **是** | PR |
| 能力 | 目标类 **pass^k**（k 次独立试验**全成功**，衡量一致性）、工具错误率、HANDOFF 率 | 否（趋势） | 夜间本机 cron |
| 成本 | cost / tokens / p95 latency / cost_coverage | 否（预算告警） | 夜间本机 cron |
| P2 合并阻断 | `oracle_mutation_catch_rate` 低于阈值 | 是（仅阻断 proposal 合并） | 候选评估 |
| 判据质量 | 判据审计完成率（新增用例 100%）、`judge_defect_rate` 未超阈值 | 是（阻断 capability 集扩量与 RSI 合并） | 每轮新增用例 |

能力指标不阻塞普通合并，只用于 proposal 的 A/B 与人审参考。

### 3. 版本集与 run manifest

每次运行写 `runs/run-manifest.json`，用 `kind` 区分两个工件：

| kind | 必填字段 |
|---|---|
| `metrics`（P0） | `kind`, `snapshot_sha256`, `metrics_version`, `metrics_sha`, `generated_at`, `tool_version`, `granularity` |
| `eval`（P1+） | `kind`, `manifest_version`, `opencode_sha`, `product_sha`, `model_id`, `prompt_version`, `criteria_version`, `taskset_version`, `snapshot_sha`, `granularity`（10 个版本/规格字段；旧称「五元组」是本表的子集），**2026-11-27 增补** `path_config_version`（期望归属声明的内容哈希，ADR-0007 决策 4）、`arms_index_sha256`（本次 run 所用臂索引的内容哈希，ADR-0008 决策 2）、`budget_usd`（本次 run 的预算上限）、`cost_usd_actual`（本次 run 的实际消耗）⇒ 共 **14** 字段 |

- `criteria_version`：oracle 定义集的内容哈希（排序后拼接再哈希）。
- `taskset_version`：用例 + fixture 集的内容哈希。
- **回滚三元组** = `patch` + `criteria_version` + `taskset_version`；缺任一 ⇒ 复现脚本拒绝运行。**归属声明的修订另需 `path_config_version`**（改 `harness/path-config.yaml` 本身必须可回滚）⇒ 归属修订的回滚集为**四元组**（ADR-0007 决策 3）。

`snapshot_sha` 与 `snapshot_sha256` 同义（统一取 SHA256）。

- `snapshot_sha`：离线快照内容的 SHA256（与 ADR-0001 的「数据版本」对齐）。
- `prompt_version`：相关 prompt 文件集合的哈希（路径排序后拼接再哈希），不使用单一语义版本号。**多臂 run 口径**：它是**本次 run 涉及的全部臂的 prompt 集合的并集哈希**（各臂 prompt 不同：W0 用评测面副本、W1/W2 用治理面矩阵）⇒ **逐臂的实际 prompt 哈希记在臂索引的 `prompt_hash` 字段**（ADR-0008 决策 2），可与 `arms_index_sha256` 对账。
- `model_id`：记录 session 级 `model_switches`；A/B 只比较无切换的 unit。
- 评测安装必须 pin：`install_testbed.sh --ref <sha>`；CI 与 manifest 使用同一 SHA。
- **manifest 字段演进**：字段**只增不改语义**（沿用 ADR-0002 决策 9 的 trace 演进规则）；**新增字段不算破坏性变更**，破坏性变更须升 **`manifest_version`**（该字段本身在 manifest 内 ⇒ 升版有落点；`manifest_version` 初始值 `1`）。
- `path_config_version`：期望归属声明 `harness/path-config.yaml` 的**内容哈希**（沿用 `prompt_version` 的内容哈希模式，不使用语义版本号；ADR-0007 决策 4）。
- `arms_index_sha256`：本次 run 所用**臂索引文件**的内容哈希；**不含臂标签本身**（臂标签只存在于 runner 侧索引内，见 ADR-0008 决策 2）。

### 4. 统计与预算

- **合并 gate**：A/B **不作为合并依据**。capability 集规模 × N 的分辨率 ≤ 5pp 之前，Δ 只标「方向性」；要分辨 5pp 需约 **1600 次/臂**（如 50 任务 × N≈32），作为 P2 后重估的数字锚点。R 层合并依据 = contract 0 回归 + skip 纪律 + 判据审计完成 + 方向性信号 + 人审。
- PR 不调用模型；夜间 capability 有固定预算上限；候选全量评测手动触发。
- 「夜间」= 本机 cron（不是 GitHub Actions），时区固定为 UTC。
- `metrics_version` 变更门：改指标公式未升版本 ⇒ CI 红。

### 5. 假绿监控

拆为三项独立指标：`skip_rate`、`恒真检查`、`oracle_mutation_catch_rate`；另有 `judge_defect_rate` 与**判据审计覆盖率**。任一低于阈值即告警；`oracle_mutation_catch_rate` 低于阈值或 `judge_defect_rate` 超阈值时阻断 RSI 合并（P2）与 capability 扩量。

## 选项对比

| 选项 | 结论 | 理由 |
|---|---|---|
| A. 单次通过/失败作为 gate | 否 | 模型随机性导致 flaky |
| B. 分层 gate + 趋势 | **选中** | 确定性部分可靠拦截；能力部分保留观察 |
| C. 全部指标硬 gate | 否 | 成本高、不稳定、会迫使绕过 |
| D. 不做 CI，只人工看报告 | 否 | 回归会在无人察觉时发生 |
| E. 用语义版本号做 prompt_version | 否 | 易漂移、不可复算；用内容哈希 |

## 后果 / 代价

**正面**

- P0 指标可复算：同一快照重跑必得同数。
- CI 保持快速、无模型依赖。
- 版本集（eval: **14** 字段，含两个内容哈希 + 预算记账 + manifest 版本号）使任何结论可复现；pin 落到装置层而不是文档承诺。

**负面**

- 能力退化不会立即阻止合并，只能靠夜间报告发现。
- mutation 抽样增加运行成本。
- 指标定义变更是安全核变更，流程较重。

**风险**

- 趋势无人看 ⇒ 夜间报告固定「Top 3 退化」摘要。
- 组合回归次数随两仓更新频率增长 ⇒ 定时 nightly，不做任一仓更新即触发。
- 快照轮换导致旧结论不可复现 ⇒ 保留聚合值 + 结论必须带 `snapshot_sha`。

## Verification

- [ ] 同一 `snapshot_sha` 连续运行两次，所有指标数值一致。
- [ ] 报告包含分母定义；手工按公式复算 3 个指标与报告一致。
- [ ] `idle_outcome=null` 的记录出现在 `unknown` 且计入分母（构造样例）。
- [ ] 子会话 token 不被重复计入（构造父子会话样例）。
- [ ] PR 中的 CI 不调用模型（检查 workflow 与脚本）。
- [ ] 评测安装使用 `--ref <sha>`，manifest 的 `product_sha` 与该 SHA 相等。
- [ ] 构造「全 skip」运行，gate 判红。
- [ ] 构造 fixture 初始红的用例，恒真检查判其无效。
- [ ] mutation 命中率低于阈值时产生告警与阻断信号。
- [ ] 夜间报告包含「较上一窗口的 Top 3 退化」。
- [ ] 删除 manifest 中的 `snapshot_sha` 后，复现脚本拒绝运行。
