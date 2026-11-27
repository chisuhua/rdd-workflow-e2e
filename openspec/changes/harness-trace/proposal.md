# harness-trace

**优先级**: P1

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

**In Scope**:

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

**Out of Scope**:

- **跨仓运行时 trace**：`traces/delegate-<session>.jsonl`、outcome 字段组、delegate 写失败告警 ——
  三项都在 `~/.config/opencode`，需单独获批（ADR-0002 决策 4 明写「本期不得默认开工」）；
- **runner / 真模型 run / 臂间 Δ**：属 `harness-dual-path-run`（需预算）；
- **任务集扩充与 prompt 契约**：属 `harness-criteria-prompt`；
- **对照报告生成器**：属 `harness-report`；
- **隔离档位（轻量档四项机制）**：属 `harness-dual-path-run`（ADR-0006 §5 memo 硬门的门控对象是它）。

## Capabilities

- MUST：能回答「一次真实会话的**每个 unit**（一轮）发生了什么」—— 按 ADR-0002 的契约字段可独立聚合，
  不依赖 opencode DB 在线。
- MUST：trace 的**完整性可量化** —— `trace_incomplete` 率 / `torn_lines` / `cost_coverage` 三项进夜间指标报告。
- MUST：**缺数据不伪造** —— 跨仓 blocked 字段显式 `null` 且标 `trace_incomplete`，不做假值填充。
- MUST NOT：不产出跨仓运行时 trace（`traces/delegate-*.jsonl`）；不跑真模型。

## Impact

- 新增 `harness/trace.py`；扩展 `harness/run.py`（夜间报告的三项完整性指标 + 粒度断点标注）；
  `harness/manifest.py` 的 `metrics_version` 升版；`harness/safety-core.manifest` + `.sha256` 更新。
- **不跑真模型**：投影只读 session DB 的**离线快照**（与 P0 同源），不需要模型。
- **跨仓 blocked**：`traces/delegate-<session>.jsonl` 的存在性、outcome 字段组、delegate 写失败的告警计数
  三项**不在本 change**（ADR-0002 明写「本期不得默认开工」）⇒ 见「推迟与 blocked」。
- 口径变更 ⇒ `metrics_version` 升版 ⇒ P0 与 P1 的趋势**不可拼接**（既有基线需分段看）。
- **安全核**：`harness/trace.py` / `harness/safety-core.manifest` 在安全核内 ⇒ 落地强制人审 + 安全核扫描。

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
      ⇒ ±2% 只校验 unit 化逻辑，构成循环论证 ⇒ **显式不作 AC**，见「推迟与 blocked」）。
- [ ] 空输入（0 unit / 无消息表 / 缺列）⇒ 空输出 + incomplete 口径，**不抛异常**（沿用 `harness/metrics.py`
      的兼容分支策略）。
- [ ] `harness/trace.py` 进 `harness/safety-core.manifest` + `harness/safety-core.sha256` 同步更新
      （落地走安全核人审与扫描，ADR-0004 决策 2）。
- [ ] 本 change 不跑真模型（AST 扫描守卫延续）；运行前后 `~/.config/opencode` 与 `rdd-workflow` 的
      `git status` 为空。

## 推迟与 blocked（本 change 不做，逐条有出处）

| 项 | 出处 | 归属 |
|---|---|---|
| `traces/delegate-<session>.jsonl` 存在且含全部必填字段 | ADR-0002 决策 4 | **跨仓**（`~/.config/opencode`，需单独获批） |
| outcome 字段组（`outcome` / `host_outcome` / `changed_files` 等）可读且语义正确 | ADR-0002 决策 4 | **跨仓**（同上） |
| delegate 收尾写失败 ⇒ 主流程仍返回成功 + 告警计数进报告 | ADR-0002 Verification | **跨仓**（同上） |
| 「同一 unit 的 trace 与 session DB 的 `agent` / `model` / `cost` 在 ±2% 内一致（抽样 50 个 unit）」 | ADR-0002 决策 5 | **不作 AC**：投影自同一 DB ⇒ 只校验 unit 化逻辑 ⇒ 循环论证；替代项 = AC「投影值与 DB 直算值逐字段相等」 |
| `HARNESS_KEEP_PROMPTS=1` 的显式开启路径 | ADR-0002 决策 7 | 随脱敏一并落地（**本 change 内**，见 AC「脱敏补测」） |
| 隔离路径清单与安全核清单**同源**（ADR-0006 决策 1.4：当前两处定义 ⇒ 活违规） | ADR-0006 §1 Verification | **`harness-criteria-prompt`** |
| 路径探针的路径基准统一为绝对路径（`harness/eval/masking.py` 现混用仓内相对路径与 `~`） | change-1 审计残留 | **`harness-criteria-prompt`**（改安全核资产 ⇒ 须人审 + sha256 同步） |
| 每 trial 前 `.rddf/state/**` 存在性断言 + 四类遮蔽对象按臂条件化 | ADR-0008 决策 6 / ADR-0006 §5 | **`harness-dual-path-run`**（memo 硬门 (ii)） |
| 臂索引对 solver 不可读 + 不可写的**隔离手段** | ADR-0001 决策 4 / ADR-0006 §5 | **`harness-dual-path-run`**（memo 硬门 (i)） |
| join 命中率 100% / 四类翻转数 / 成本熔断 / 报告结构断言 | ADR-0008 Verification | **`harness-report`** + 对照 run |
