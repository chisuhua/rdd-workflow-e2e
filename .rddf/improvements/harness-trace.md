---
优先级: P1
来源: "ADR-0002（trace 合同）/ ADR-0005（指标与口径）/ ADR-0006 §1（不可读与脱敏）+ harness-p1（change-1）"
阶段: phase-2
分类: harness
类型: feature
---

**优先级**: P1 | **来源**: ADR-0002 / ADR-0005 / ADR-0006 §1，harness-p1（change-1）后续
**阶段**: phase-2 | **分类**: harness | **类型**: feature

## Why

change-1（`harness-p1`，**已实施并归档**）交付了双路径对照的**静态资产与判据**：归属声明、安全核清单、
遮蔽探针、W0 prompt 副本、臂索引 writer、`kind=eval` manifest、机械 oracle + 3 条 cap 用例、判据审计
三轮。但这些判据目前只能对**合成 fixture**求值（验的是「判据本身对不对」），还不能对**真实产出**求值。

真实求值缺的第一块是 **unit 级 trace**：判据的**输入**。现在没有契约化的 trace 工件 ——
只有临时从 session DB 投影的做法，没有字段表、没有版本、没有完整性指标、没有脱敏保证。
ADR-0002 已经把 trace 合同写死（字段表 / `trace_version` / 演化规则 / 脱敏 / 完整性指标），
但**没有任何实现**；ADR-0005 §1 的「P1 起一行 = 一个 unit」也还停在纸面。

没有这一块，后面的任务集、报告生成器、对照 run 都无从落地（它们都要吃 unit trace）。

## What Changes

- **`harness/trace.py`：从 session DB 投影 unit trace**
  - 输出符合 **ADR-0002 决策 3 的字段表**，带 `trace_version = 1`（决策 9 的演化规则：字段只增不改语义）；
  - 落点路径**不是** ADR-0002 决策 4 的 `traces/delegate-<session>.jsonl`（那是**跨仓运行时**路径，
    本 change 不产出）⇒ 投影产物落 `~/.local/share/rddf-harness/traces/<run>/trace.jsonl`；
  - **跨仓 blocked 字段**（`outcome` / `host_outcome` / `changed_files` / `diff_ref` /
    `unverified_reason`）显式为 `null`，且该 unit 标 `trace_incomplete = 1`（不做假值填充）；
  - **`trace_incomplete` 的判定规则写死**：任一必填字段不可从 DB 导出 / 消息序列无法按决策 1 切分 /
    JSON 解析失败 / 未知 message type ⇒ 该 unit 记 `trace_incomplete`（规则在代码里且可单测）。
- **unit 切分与选择器**：`resume_of` 链（resume 两次 ⇒ 3 个 unit）；排序键写死（DB 无显式序 ⇒ 用
  `session_message` 的行 id + 时间戳的稳定序）；**单元选择器是纯函数**（`model_switches` 非空的 unit 被排除）。
- **脱敏**：默认配置下 trace 不含 prompt 原文；补测 **JWT / Basic / `.netrc`** 三类敏感串
  （ADR-0002 风险段明写要补）。
- **完整性指标与告警**：`trace_incomplete` 率 / `torn_lines` / `cost_coverage` 三项进**夜间指标报告**
  （`harness/run.py` 的那份，**不是**对照报告）；`trace_incomplete` 率 > 5% ⇒ 告警。
- **粒度断点**：报告标注 `granularity = unit`，并声明 **P0(session) 与 P1(unit) 趋势不可拼接**
  （ADR-0002 决策 1）；`metrics_version` 随之升版（改口径未升版 ⇒ CI 红）。
- **安全核**：`harness/trace.py` 进 `harness/safety-core.manifest`（按 `harness/metrics.py` 的**单文件**
  先例）+ `harness/safety-core.sha256` 同步（它承载 unit 推导口径 = 判据资产）。

## Acceptance

- [ ] 投影输出符合 ADR-0002 决策 3 的字段表且 `trace_version = 1`；落点路径 ≠ `traces/delegate-<session>.jsonl`。
- [ ] 跨仓 blocked 字段（`outcome` / `host_outcome` / `changed_files` / `diff_ref` / `unverified_reason`）
      显式为 `null` 且该 unit 标 `trace_incomplete = 1`。
- [ ] unit 切分与 `resume_of` 链可复算（resume 两次 ⇒ 3 个 unit）；排序键写死并可单测。
- [ ] 同一 DB 连续两次投影**逐字节一致**（幂等）。
- [ ] 单元选择器（纯函数）排除 `model_switches` 非空的 unit。
- [ ] 默认配置下 trace 不含 prompt 原文；脱敏补测覆盖 JWT / Basic / `.netrc`。
- [ ] 截断末行 ⇒ `torn_lines = 1`，不崩溃、不静默丢弃。
- [ ] `trace_incomplete` 的判定规则写死在实现里且可单测（必填字段不可导出 / 序列无法切分 / JSON 解析失败 /
      未知 message type 四类各一例）。
- [ ] 夜间**指标**报告含 `trace_incomplete` 率 / `torn_lines` / `cost_coverage` 三项；`trace_incomplete`
      率 > 5% ⇒ 出现告警。
- [ ] 报告标注 `granularity = unit` 且声明 P0(session) 与 P1(unit) 趋势**不可拼接**；`metrics_version` 升版。
- [ ] 投影值与**同一 DB 直算值逐字段相等**（替代 ADR-0002 决策 5 的 ±2% 抽样一致项 —— 投影自同一 DB
      ⇒ ±2% 只校验 unit 化逻辑，构成循环论证 ⇒ **显式不作 AC**，见「推迟清单」）。
- [ ] 空输入（0 unit / 无消息表 / 缺列）⇒ 空输出 + incomplete 口径，**不抛异常**（沿用 `harness/metrics.py`
      的兼容分支策略）。
- [ ] `harness/trace.py` 进 `harness/safety-core.manifest` + `harness/safety-core.sha256` 同步更新
      （落地走安全核人审与扫描，ADR-0004 决策 2）。
- [ ] 本 change 不跑真模型（AST 扫描守卫延续）；运行前后 `~/.config/opencode` 与 `rdd-workflow` 的
      `git status` 为空。

## Capabilities

- 能回答「一次真实会话的**每个 unit**（一轮）发生了什么、按契约字段可独立聚合吗」——
  这是 E 层判据的输入面（ADR-0002 的合同从纸面变成工件）。

## Impact

- 新增 `harness/trace.py`；扩展 `harness/run.py`（夜间报告的三项完整性指标 + 粒度断点标注）；
  `harness/manifest.py` 的 `metrics_version` 升版；`harness/safety-core.manifest` + `.sha256` 更新。
- **不跑真模型**：投影只读 session DB 的**离线快照**（与 P0 同源），不需要模型。
- **跨仓 blocked**：`traces/delegate-<session>.jsonl` 的存在性、outcome 字段组、delegate 写失败的告警计数
  三项**不在本 change**（ADR-0002 明写「本期不得默认开工」）⇒ 见「推迟与 blocked」。
- 口径变更 ⇒ `metrics_version` 升版 ⇒ P0 与 P1 的趋势**不可拼接**（既有基线需分段看）。

## 推迟与 blocked（本 change 不做，逐条有出处）

| 项 | 出处 | 归属 |
|---|---|---|
| `traces/delegate-<session>.jsonl` 存在且含全部必填字段 | ADR-0002 决策 4 | **跨仓**（`~/.config/opencode`，需单独获批） |
| outcome 字段组（`outcome` / `host_outcome` / `changed_files` 等）可读且语义正确 | ADR-0002 决策 4 | **跨仓**（同上） |
| delegate 收尾写失败 ⇒ 主流程仍返回成功 + 告警计数进报告 | ADR-0002 Verification | **跨仓**（同上） |
| 「同一 unit 的 trace 与 session DB 的 `agent` / `model` / `cost` 在 ±2% 内一致（抽样 50 个 unit）」 | ADR-0002 决策 5 | **不作 AC**：投影自同一 DB ⇒ 只校验 unit 化逻辑 ⇒ 循环论证；替代项 = 上面的「逐字段相等」 |
| `HARNESS_KEEP_PROMPTS=1` 的显式开启路径 | ADR-0002 决策 7 | 随脱敏一并落地（**本 change 内**，见 AC「脱敏补测」） |
| 隔离路径清单与安全核清单**同源**（ADR-0006 决策 1.4：当前两处定义 ⇒ 活违规） | ADR-0006 §1 Verification | **下一 change**（判据族与 prompt 契约） |
| 路径探针的路径基准统一为绝对路径（`harness/eval/masking.py` 现混用仓内相对路径与 `~`） | change-1 审计残留 | **下一 change**（改安全核资产 ⇒ 须人审 + sha256 同步） |

## 拆分后的 change 序列（phase-2 = P1）

| # | change | 范围 | 前置 | 状态 |
|---|---|---|---|---|
| 1 | `harness-p1` | 双路径对照**就绪资产**（归属声明 / 安全核清单 / 探针 / 副本 / 臂索引 / eval manifest / 3 条 cap 用例 / 判据审计） | — | ✅ 已归档（`openspec/changes/archive/2026-11-27-harness-p1/`，17/17 AC 通过） |
| 2 | **`harness-trace`**（本文件） | **unit trace 投影**（ADR-0002 合同落地） | change-1 | 立项中 |
| 3 | `harness-criteria-prompt` | 判据族与 **prompt 契约**（cap-001/002/003 的绑定面落成机器可查的契约）+ tier 标注 + 判据变更后自动重跑变红 + **隔离路径清单与安全核清单同源**（ADR-0006 决策 1.4 的活违规） | change-1 | 待立项 |
| 4 | `harness-report` | **对照报告生成器**（ADR-0008 的报告类 12 条：四类翻转数 / `excluded_*` 计数与占比 / 分母分列 / 流程层三类取值 / 安全不变量判红 / `taskset_size` 与 `cases` 对账 / `partial` 不含 Δ 字段 / 键集合层无总分）+ **输入 fixture schema** | change-3 | 待立项 |
| 5 | `harness-dual-path-run` | 对照 run（三臂）+ runner + **轻量档隔离与臂索引的作用范围扩展**（ADR-0006 §5 memo 硬门 (i)(ii)(iii) 的门控对象即本 change）+ 每 trial 前 `.rddf/state/**` 断言 | change-2/3/4 | 待立项 |

> ⚠ **本表已被后续拆分取代**：`harness-criteria-prompt` 立项时按 metis 的 P0 意见再拆出
> `harness-isolation-samesource`（隔离清单同源 + manifest 第三 scope + 路径锚点化 + `masking` CLI 修复，
> **前置是 architect 修订 ADR-0006 §1.4 / ADR-0004 决策 4**）⇒ **唯一真源改为
> `.rddf/improvements/harness-criteria-prompt.md` 的「拆分后的 change 序列」**（6 段）。本表保留作历史记录。


⚠ **change-4/5 依赖真模型与预算** ⇒ 单独立项、独立审批预算；本仓至今未批过任何真模型预算。

## metis 结论（1 轮；审查对象是本 change 的**母稿**「E 层主体」四子系统稿）

metis 的 P0 结论：**change-2 必须拆**（4 个子系统塞一个 change 会产出巨型 proposal，违反「每个 plan 独立产出
可工作的、可测试的软件」）。本文件即按该结论拆出的**第一块**；其 P0 意见逐条落点如下：

| metis P0 意见 | 本文件的处置 |
|---|---|
| 拆分 change（2a/2b/2c + runner） | ✅ 采纳 ⇒ 上面的 change 序列（metis 建议的边界 + 命名） |
| 「轻量档隔离」整条移交对照 run change（memo 硬门的门控对象是它） | ✅ 采纳 ⇒ **不在本 change**；移入 change-5（并记入「推迟与 blocked」） |
| 探针断言集**不重复验收**（change-1 AC-10 已覆盖） | ✅ 采纳 ⇒ 本 change 不含探针断言集的 AC |
| AC「真实 run 形态下三条 case 不假红」不可判（与「本期不跑真模型」冲突） | ✅ 采纳 ⇒ 该项属 change-3（prompt 契约 + conformant solver 的机械一致性），本 change 不含 |
| 「adversarial 单独成层」与 ADR-0003 决策 1 自相矛盾 | ✅ 采纳 ⇒ 本 change 不涉及任务集分层（归 change-3）；ADR-0003 的「adversarial 并入 contract」不在本 change 重开 |
| 补 ADR-0003 决策 3 的**准入 8 条落点表** | ✅ 采纳（但**不在本 change**：准入 8 条属任务集 ⇒ 归 change-3） |
| 补「推迟清单」与「跨仓 blocked」两节 | ✅ 采纳 ⇒ 见本文件「推迟与 blocked」（本 change 的跨仓 blocked = ADR-0002 决策 4 的三项） |
| 补 ADR-0002 决策 6 的三项完整性指标 + 决策 1 的粒度断点 + 决策 9 的 `trace_version` | ✅ 采纳 ⇒ 三项指标与告警、粒度断点标注 + `metrics_version` 升版、`trace_version = 1` 全部进入 AC |
| 投影语境的 `trace_incomplete` 判定规则必须写死（否则 AC 无输入） | ✅ 采纳 ⇒ AC 明确四类判定来源（必填字段不可导出 / 序列无法切分 / JSON 解析失败 / 未知 message type） |
| `harness/trace.py` 必须进安全核清单 | ✅ 采纳 ⇒ AC 明确（含 sha256 同步 + 人审） |

metis 的 P1/P2 中**与本 change 相关**的采纳项：ADR-0002 决策 5 的 ±2% 抽样一致项**显式声明不作 AC**
（投影自同一 DB ⇒ 循环论证）并给替代项（逐字段相等）；ADR-0002 决策 7 的脱敏补测（JWT / Basic / `.netrc`）；
ADR-0005 §5 的三项完整性指标中的两项（`skip_rate` 四元组、`oracle_mutation_catch_rate`）归 change-3；
「结论字段取值域统一」归 architect（ADR 侧，本 change 只消费词表）。

metis 的 P1/P2 中**移出本 change**的项：ADR-0006 决策 1.4 的同源违规（归 change-3）、路径探针的绝对路径基准
（归 change-3，改安全核资产须人审 + sha256 同步）、报告结构断言（归 change-4）、CI 增加 python 单测步骤
（`.github/workflows/**` 在安全核内 ⇒ 须人审；另：change-1 的 78 项单测当前**只在本地验证**，已记入架构文档 §8）。
