# Agent Harness 与限域 RSI 架构

| 字段 | 值 |
|---|---|
| Status | Proposed |
| Date | 2026-11-19 |
| Author | architect |
| 审稿报告 | `.rddf/reviews/harness-adr-review.md`（oracle + metis → critic；BLOCKER 已闭合） |
| Scope | `~/.config/opencode`（治理面）× `rdd-workflow`（产品面）× `rdd-workflow-e2e`（评测面） |
| 关联 ADR | ADR-0001 ~ ADR-0008 |
| 关联调研 | `docs/research/README.md`（harness / 评测 / RSI / 安全 四类） |
| 关联 change | `backlog: harness-p0` |
| 本次修订 | 2026-11-27：引入「**双路径**」被测维度（内置基座 + 可选 rdd skill 叠加层，**两者不互斥**）⇒ 新增主题文档 [`dual-path-model.md`](./dual-path-model.md) 与 ADR-0007 / ADR-0008。**P2 挂起条件与既有 gate 一律不变** |

> 命名说明：本文用 **O/E/R（观测 / 评测 / 改进）** 指代 harness 三层，**不复用** `docs/known-gaps-and-ownership.md` 里的 L1/L2/L3（那三个字母指测试层：单元 / 运行时 / 跨阶段 E2E）。

## 1. 问题

多智能体行为（角色矩阵、委托、审查配对）主要靠规则文本约束，缺少两类能力：

1. **可观测**：一次委托做了什么、错了没有、花了多少，散落在 session DB、NDJSON、`.rddf` 状态文件里，没有统一视图。
2. **可改进**：失败模式无法系统归因，规则与 prompt 的修改靠人工直觉，没有回归保护。
3. **两个载体混为一谈**（2026-11-27 修订新增）：实际有**两个载体**参与 planner / builder —— `~/.config/opencode` 的**内置角色矩阵**（治理面基座：权限边界 / 审查配对 / 越权处理 / 非交互停机兜底）与 `rdd-workflow` 的 **rdd skill 层**（产品面阶段合同：工件归属 / 状态机 / gate / 归档）。⚠ 二者**不互斥**（skill 层的 agent 仍在读内置角色矩阵）⇒ 真问题是「**哪个阶段由谁承担**」，不是「选哪条流程」。当前 O 层按 opencode 的 `agent` 切片，看不见流程归属；E 层任务集也没有「同一任务两种配置」的配对结构 ⇒ **两个载体都拿不到持续改进所需的证据**。模型与归属见 [`dual-path-model.md`](./dual-path-model.md)，决策见 ADR-0007 / ADR-0008。

## 2. 分期（本期只做 O 层）

| 期 | 内容 | 立项条件 |
|---|---|---|
| **P0（本期）** | **O 层观测**：离线快照 + 指标脚本 + 可复算报告 | 立即 |
| P1（下期） | E 层评测：trace 合同、delegate outcome 持久化、capability 集；**+ 双路径对照**（capability 的首个 case 族：同一任务**多臂**配对 —— W1↔W2 主比较 + W0 参照；臂标签只由 runner 持有） | P0 指标暴露出现有字段回答不了的具体问题 |
| P2（挂起） | R 层限域 RSI：proposals、A/B、回滚 | capability 正式集 ≥ 30 条，且连续 4 周中至少 3 周有夜间报告被引用进 improvement notes 或 ADR context（可 grep） |

P0 的成功判据：**过去 5 周按 agent/项目的成功率、工具错误率、成本、Top 失败模式**，且同一份快照重跑必得同数。
该判据只依赖 session DB + 一个离线快照 + 写死的指标公式，不依赖 trace 合同、不依赖宿主改动、不调用模型。

## 3. 范围

| 组成 | 归属 | 在本架构中的角色 |
|---|---|---|
| `~/.config/opencode` | 治理面 | 被观测、被评测、被改进；**安全核**所在 |
| `rdd-workflow` | 产品面 | 被观测、被评测、被改进；提供 `rddf` / gate / handoff |
| `rdd-workflow-e2e` | 评测面 | 承载 harness 代码、指标脚本、任务集、报告 |
| `oh-my-openagent` | 外部 | **只消费**其 usage ledger，不重复生产指标 |

## 4. O 层（观测，本期）

### 4.1 数据源（实测规模，2026-11-19）

| 源 | 规模 | 用途 |
|---|---|---|
| `opencode.db` | 1,854 sessions / ~129k messages / 137k tool parts | 主力语料：任务、轨迹、成本、结果（口径见 `docs/research/08-p0-findings-and-writeback.md`） |
| `storage/session_diff` | 521 个文件 | 文件级改动事实（需先核对空文件比例） |
| e2e 运行时 NDJSON | 70 个 json + meta | 契约断言证据 |
| `.rddf` 留痕 | events 20 / event-log 1 / bypass 2 / trace 523 | 门禁与绕过事件（量小，只作补充） |
| `subagent-contract.log` | 277 行 | 契约违规率 |

### 4.2 采集方式

1. **离线快照**：对 `opencode.db` 做文件级拷贝 + SHA256，所有批量查询在快照上执行；live 库只做 `sqlite3 -readonly` 抽样复核。
2. **公式即规格**：指标公式写死在 `harness/metrics.py` 代码里，每条指标带 `metric_id`、分子/分母、边界处理；代码即定义。
3. **manifest**：每次运行写 `runs/run-manifest.json`，P0 使用 `kind=metrics` 子集 `{snapshot_sha256, metrics_version, metrics_sha, generated_at, tool_version, granularity}`；字段定义见 ADR-0005 §3。

### 4.3 指标定义（摘要）

**P0 行粒度 = 根 session**（子会话按 `parent_id` 归并）；P1 起改为 unit，报告标注断点，趋势不拼接。

| 指标 | 定义 |
|---|---|
| 成功率 | `succeeded / (succeeded + failed + interrupted + unknown)`；`null` 归 `unknown`，**计入分母**；同时给分口径值 |
| 工具错误率 | `tool calls with non-empty state.error / total tool calls` |
| 成本 | `sum(cost)` 跳过 null；单列 `cost_coverage` |
| 去重 | 子会话按 `parent_id` 归并到根会话统计 token；P0 不按轮次拆分 |
| FAIL 模式 | 按 `tool name + error code` 聚类，保留原始字符串样例 |

完整公式见 ADR-0005「指标定义」章。

### 4.4 指标分层

| 层 | 指标 | 来源 | 用途 |
|---|---|---|---|
| 直接可算 | 成功率、成本、token、时延、工具错误率、写目标分布、委托深度 | session DB | 趋势与归因 |
| 需补落盘（P1） | 委托 outcome、critic verdict、verifier verdict | delegate 收尾 / 判定输出 | 正确性信号 |
| 需补落盘（P1） | **按臂（arm）切片**：各臂的**任务层**产物达成率 + 逐任务翻转数（流程层合规指标分列，不合成） | runner 侧臂索引 + 任务层 oracle | 双路径对照（**只适用于 runner 执行的新评测，不回溯历史会话** —— 历史会话无臂标签；ADR-0008） |
| 暂不可得 | 假绿率、长期 CI 趋势 | mutation 运行 / GitHub API | 后续补齐 |

## 5. E 层（评测，P1）

### 5.1 三层任务集

| 层 | 判定方式 | 运行时机 | 例 |
|---|---|---|---|
| contract | 确定性：文件事实 / 退出码 / 结构化字段 | 每 PR | 角色写门、commit gate、schema |
| capability | 机械 oracle + 多次采样 | 夜间（本机 cron，非 Actions） | 委托 scope 判断、HANDOFF 交回 |
| adversarial | 变异任务 / 边界输入 | 候选 patch 评估 | 指标优化行为、越权尝试 |

初期 adversarial **并入 contract 的 mutation 检查**，不单独成层；capability 集 ≥ 30 条后再拆出。

### 5.2 用例准入

1. 可复现 fixture（不依赖生产仓库状态）；
2. 机械 oracle（禁止「模型说做完了」）；
3. 一次变红演练记录。

生产会话只产出**候选**，不直接转正。判定优先级：文件事实 > 结构化字段 > 退出码 > 模型文本；模型文本只允许断言 prompt 明确规定的短语。

### 5.3 held-out

capability 集 < 50 条前**手动切分**，不做滚动窗口；之后改为按时间窗冻结，冻结集不回灌候选池。

### 5.4 评测隔离（ADR-0006）

「判据外置」叠加**环境与信息边界**，分三档：

| 档 | 机制 | 适用 |
|---|---|---|
| 语义层（现在） | 不可读集、三段式 artifacts、gold/rubric 不注入 prompt、与安全核共用一份 manifest | 立即 |
| 轻量档（P1 默认） | 工具层写集 + 权限位 + 独立评分进程 + 路径可达性探针 | P1 |
| 容器档（触发后） | solver 容器（空工作区 / 无 NAS / 无凭据）+ fresh grading 容器 + `network:none` | §ADR-0006 触发线 |

**本环境的容器档能力已实测**（2026-11-19）：当前容器本身是 ECI 实例，可在容器内用 `aliyun eci CreateContainerGroup` 创建 spot 沙箱（无 NAS / 无 EIP），`eci ExecContainerCommand` 执行命令，`DeleteContainerGroup` 销毁；新实例 `/workspace` 为空、`/home/ubuntu` 仅默认 dotfiles ⇒ 判据与历史天然不可达。脚本：`~/my-docker-env/aliyun_sandbox.sh`。无需 Docker daemon（当前是 containerd 管理的 ECI）。

**注意**：隔离 ≠ 确定性。隔离保证 agent 读不到评分器；确定性保证同一 artifacts 重跑同分（需要固定 seed/模型/参数与非 LLM 评分器）。两者判据不可混写。

## 6. R 层（改进，P2，挂起）

### 6.1 流程

```
失败统计 → 选 1 个失败类 → 1 个候选 patch → A/B（同任务集，各 N 次）
        → 安全核扫描 → 人审 → 合并 + 回滚点
```

### 6.2 允许自动提案的层（白名单）

- prompt 的表述、示例、反例（**但需人审判定「是否构成等效权限/配对/gate 变更」**）
- 新增 fixture 与新增用例（**只允许新增文件，不允许修改清单内既有文件**）
- helper 脚本、文档
- ADR 给定边界内的阈值参数

### 6.3 安全核（不可自动改，清单化）

> 白名单 ≠ 可写：RSI 进程的写集在工具层被限制为 `proposals/`；任何安全核路径的落地只能以 proposal 形式经人审合并。

安全核是 **`harness/safety-core.manifest`**（glob + 每项理由 + 版本），不是抽象名词。

> **唯一真源**：安全核清单**只在该 manifest 里定义**，本节不复述 glob（ADR-0006 决策 1.4：「一份 manifest、两处引用，不允许两处定义」）。清单覆盖的类别为：治理面配置与 prompt（含 `<!-- capability:` / `<!-- role-class-write-set:` 机读块）、治理面机制面（`lib/**` / `plugins/**`）、被测仓的判据与门禁资产（`rdd-workflow` 的 gate 脚本与 `.rddf/state` schema）、本仓的判据资产（指标定义、oracle 定义、评测定义与 rubric、期望归属声明）、本仓的回归面（`tests/**`、`KNOWN_FAILURES.txt`、CI 工作流）、以及 manifest 自身（哈希固定在 `harness/safety-core.sha256`，夜间/CI 校验，改动需人审 PR）。
>
> ⚠ 2026-11-27 增补（ADR-0004）：`rdd-workflow/skills/{rdd-planner,rdd-builder,rdd-quick}/**`（叠加层的工件归属与阶段契约载体）与 `harness/path-config.yaml`（期望归属声明）进 manifest。**臂索引 `arms/` 不进安全核** —— 它是 runner 产出的运行数据（写者唯一性见 ADR-0001 决策 4，对 solver 不可读见 ADR-0006 §1）。

**enforcement**：RSI 进程的写集在工具权限层限制为 `proposals/`；安全核扫描失败即拒绝合并并留痕，不依赖提案者自觉。

## 7. 关键约束

1. **判据外置**：被改进对象不决定自己是否通过。
2. **single writer（按工件 + 按进程实例）**：同一工件只有一个写入者；同一时刻同一 trace 文件只有一个进程写。
3. **版本可复现**：每次评测记录版本集 `{opencode_sha, product_sha, model_id, prompt_version, criteria_version, taskset_version, snapshot_sha, granularity}`（旧称「五元组」是其子集）。
4. **成本一等**：PR 不跑模型；能力评测夜间本机执行。
5. **可回滚**：任何合并都带 revert 点，且至少演练一次。

## 8. 已知缺口

| 缺口 | 影响 | 处置 |
|---|---|---|
| `idle_outcome` 语义粗 | 不能当正确性奖励 | P0 只报分口径值；正确性留给 P1 的 verdict/AC 字段 |
| verdict 未结构化 | 无法回归 | P1 落字段；P0 从 `.ac-verdict-*.json` 聚合 |
| `.rddf` 留痕使用率低 | 数据饥饿 | 不依赖 feedback 作主数据源 |
| 假绿无自动化 | RSI 会磨平判据 | P1 起纳入 mutation 抽样；P0 只测 `skip_rate` 与恒真检查 |
| 跨仓治理变更 | 旧拍板「只记录不动 opencode 仓」 | P1 的 delegate 持久化需用户批准并记录；P0 不触碰宿主 |
| **无臂（arm）维度** | O 层只能按 opencode `agent` 切片，看不出流程归属 ⇒ 双流程不可对照 | P1 引入 runner 侧臂索引（ADR-0008）；**臂标签不进 trace / DB / solver 视野** |
| **双流程「可比落点」未定义** | 对照只能比感觉 | 已定义：**双层测量** —— 任务层（最终工作区状态 + 测试通过，各臂同分母）与流程层（各自合规，不跨臂比），见 [`dual-path-model.md`](./dual-path-model.md) §3 |
| **内置路径无机械 oracle** | 内置臂若只断模型措辞 ⇒ 违反断言纪律 | 复用 rdd 臂已有的产物判据；内置特有面（开场报告 / 越权 / 停机）只作各自断言，**不跨流程比** |
| **编排增量不可分解** | 只能说「叠加层有没有方向性影响」，**说不出「编排本身值多少」**（缺基线臂） | 引入 **W0 无阶段编排参照臂**（ADR-0008 决策 1）：W0 只作参照、**不进入归属决策**；P1 以参照试点进入 |
| **CI 不跑 python 单测**（2026-11-27 实测） | `.github/workflows/test.yml` 只跑 `bats tests/integration/ tests/_lib/` ⇒ `harness/tests/` 的单测（含 change-1 的 78 项）**只在本地验证** ⇒ 「本 change 不跑真模型」的 AST 守卫、改口径未升 `metrics_version` ⇒ CI 红 等门在 CI 里**落不了地** | 处置：① 在验收报告里显式标注「取证方式 = 本地实跑」；② CI 增加一步 `python3 -m unittest discover -s harness/tests -t .`（⚠ `.github/workflows/**` 在安全核内 ⇒ 改动须人审 + 安全核扫描） |
| **隔离路径清单与安全核清单两处定义**（2026-11-27 实测） | ADR-0006 决策 1.4 要求二者**同源**（不允许两处定义）；现状：安全核清单在 `harness/safety-core.manifest`，隔离路径清单在 `harness/eval/masking.py` 的常量 ⇒ 两份会漂移 | 处置：下一 change（判据族与 prompt 契约）里把隔离路径清单改为**从 manifest 派生**（diff 为空可机判）；本 change 已在验收报告登记为欠账 |
| **ADR-0007 与 ADR-0008 的结论字段取值域字面不一致**（2026-11-27 实测） | ADR-0007 写 `{归属声明修订, 判据修订, 列入观察, 无结论}`，ADR-0008 写 `{阶段归属修订, 判据修订, 列入观察, 无结论}` ⇒ 报告生成器必须二选一（否则实现者自造第三种） | 处置：统一到 **ADR-0007 的词表**（`归属声明修订` 命名的是**被改动的工件** `harness/path-config.yaml` ⇒ 与 ADR-0007 决策 3 第二行的四元组回滚集一一对应），ADR-0008 决策 8 与 Verification 同步对齐 |

## 9. 术语对照与外部依据

| 外部术语 | 来源 | 与本文的对应 |
|---|---|---|
| evaluation harness | Anthropic《Demystifying evals for AI agents》2026-01-09 | O + E 层（跑评测、记录每步、判分、聚合） |
| agent harness / scaffold | 同上 | E 层中被测的「提示 + 工具 + 环境」整体 |
| harness engineering | LangChain（Viv Trivedy）2026-02；Thoughtworks/Fowler 2026-04 | R 层的做法与本文 O/E/R 三层的总称 |
| Guides / Sensors × Computational / Inferential | Fowler 2026-04 | 对应我们的「规则文本约束」（Guides）与「指标反馈」（Sensors） |
| 2 臂 A/B + Δ + 成本熔断 | Claude Code plugin eval v2.1.269+（3 runs × 2 arms，`--max-cost-usd` 熔断） | ADR-0008 的对照形态（臂只由 runner 持有） |
| 状态型 oracle | τ-bench / τ²-bench（判**最终状态**而非输出文本） | 双路径**任务层**判据的形态（`dual-path-model.md` §3） |

**外部依据**：固定模型、只改 harness，公开实验为 Terminal-Bench 2.0 **52.8 → 66.5（+13.7）**，Top 30 → Top 5（LangChain，2026-02）。评测对象是 **harness 与模型协同工作的结果**（Anthropic 定义）——本文的「改进 harness 而非模型」主张由此有独立支撑。

⚠ **+13.7 只作上界引用，不是目标值**：该实验改动了 system prompt / tools / middleware，其中 tools 与 middleware 正落在我们的**安全核**内（`lib/**`、`plugins/**`）⇒ 我们能采纳的改动面更窄。

**收益预期（诚实边界）**：文献显示「开放式」与「可审计」存在张力——允许奇怪改动的系统收益最高（DGM 在 SWE-bench 上 20.0%→50.0%），而写集越受限，收益越接近**提示词微调量级**（GEPA / PromptWizard 的个位数百分点）。本架构的限域版本应按**后者**设定目标。

**分辨率现实（可算的事实）**：两比例检验（基线 0.5、α=.05、功效 80%）下，Δ=0.05 需约 1600 次/臂、Δ=0.10 需约 392、Δ=0.20 需约 98；而「10 任务 × N=3」= 30 次/臂只能分辨约 36pp、「50 × 3」= 150 次/臂只能分辨约 16pp，且 run 级样本在 task 内相关（有效 n 更接近任务数）⇒ **上述均为乐观上界**。⇒ 在 capability 集规模 × N 能分辨 5pp 之前，任何 Δ 结论只能标「方向性」，不能作为合并依据。

## 10. 已知未解问题

| 问题 | 现状 | 出处 |
|---|---|---|
| harness 覆盖率与质量如何度量 | 类似 code coverage / mutation testing 的评测方法尚不存在；我们以 `oracle_mutation_catch_rate` / 恒真检查 / `skip_rate` 作为**代理**，并声明其局限 | Fowler 2026-04 |
| 跨 agent 的轨迹可移植与探索 | 没有标准化的方式比较不同 agent 类型与工作负载的 benchmark 结果与轨迹 | AgentDojo（arXiv 2406.13352） |
| 判据缺陷的常态化度量 | 公开审计显示抽样缺陷率可达 59.4%（SWE-bench Verified）、约 30%（TB2.0）⇒ 需要常态化抽审 | OpenAI 2026-02-23；Benchmarks as Software 2026-11 |

## 11. 非目标

- 不做通用开放式 RSI（自主改判据/权限）。
- 不把 harness 数据提交进 git。
- 不替代现有 e2e 套件；harness 消费其证据，不重复实现断言。
- 不评价模型好坏，只评价「在给定任务上的行为结果」。
- **不做两条流程的排名式竞赛**：对照的产出是**阶段归属边界**（哪一阶段由哪条流程承担），不是一个总分或一张排行榜（ADR-0007）。
- P0 不修改 `~/.config/opencode` 与 `rdd-workflow` 的任何运行时文件。

## 12. 关联决策

| ADR | 决策 |
|---|---|
| ADR-0001 | 数据面归属与 single writer |
| ADR-0002 | 统一 trace 与 outcome 合同 |
| ADR-0003 | 评测集分层与 oracle 准入 |
| ADR-0004 | RSI 写入边界与安全核 |
| ADR-0005 | 度量、gate 与版本 pin |
| ADR-0006（Proposed，已裁决） | 评测隔离契约（评分器不可达）：语义层 + 轻量档 P1 + 容器档触发线 |
| ADR-0007 | 双流程的层属与改进面归属（内置 = 治理基座 / rdd-\* = 产品面阶段合同；不是同层竞品；阶段归属边界而非排名） |
| ADR-0008 | 双路径对照的测量契约（**三级臂集合** W0 无阶段编排 / W1 内置编排 / W2 内置编排 + rdd skill；臂只由 runner 持有且不进 solver 视野；盲化 + 外部执行；**双层测量**（任务层 + 流程层）；逐任务配对；成本熔断） |

## 13. 与既有文档的关系

- `docs/known-gaps-and-ownership.md`：定义测试层 L1/L2/L3 与跨仓缺口归属；本文不复用其字母。
- `docs/architecture/dual-path-model.md`：双流程被测模型（层属、**双层测量**、臂的数据流、首批判据来源）；本文只给总纲与指针。
- `docs/runtime-assertion-discipline.md`：断言纪律的唯一真源；ADR-0003 只引用，不复制。
- `docs/research/**`：外部调研材料与借鉴映射（只作材料，不作判据）。
- 本目录 `docs/adr/`：决策文档，按 ADR-0001 → ADR-0008 顺序阅读。
