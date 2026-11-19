# 分类 F：可用公开数据集（面向本项目的可落地性筛选）

| 字段 | 值 |
|---|---|
| 日期 | 2026-11-19 |
| 方法 | librarian 联网核实（HF 数据集卡 / 官方仓库 / 论文原文）；未核实者标注 |
| 下载可行性 | 已由 `07-downloadable-datasets-matrix.md` 在**本环境实测**复核（hf-mirror 可用、GitHub 不可达、无 Docker） |
| 结论 | **没有任何公开数据集能直接当我们的 capability oracle** —— 公开集全是「单 agent 对任务」或「单轮文本对指令」。可直接复用的是**判据机制与失败分类学**，不是数据本身 |

## F0. 用途分层与优先级

| 层 | 投入 | 内容 |
|---|---|---|
| **P0（< 2 人日，立刻产出指标）** | 低 | IFEval checker 结构、τ-bench policy 形态、AgentDojo 双指标、JudgeBench/RewardBench 作 judge 误判锚 |
| **P1（2–4 周）** | 中 | AutoIF 规则工厂、IH-Challenge 权限门语义、Agent-SafetyBench 失败分类学、FLASK/DevAI 判据模板 |
| **P2（1–2 月，仅作对照）** | 高 | 轨迹类数据集（失败挖掘方法论）、成本标尺（HCAST/METR/CORE-Bench）、SWE-smith 式注入工厂 |
| **P3（不建议投入）** | — | BugsInPy / Defects4J / Codeflaws / SWE-bench Multimodal / Multi-SWE-bench / SWE-PolyBench —— 与「配置/权限/规则」正交 |

## F1. 可机械判定的「指令/规则遵循」——我们的 capability oracle 基座

| 数据集 | 机构/年份 | 规模 | 许可 | 离线 | 对我们的用法 | 限制 |
|---|---|---|---|---|---|---|
| **IFEval** | Google DeepMind, 2023 | 541 prompts（train），~25 类可验证指令 | **Apache-2.0** | 完全离线（jsonl 207KB + 纯 Python checker） | **最可直接复用**：`instruction_id_list` + `kwargs` 即「规则 → 程序化判据」的现成范式；先机械化我们已能判的 5–8 条规则 | 判的是**单轮文本对象**，不含会话级角色约束；checker 有边界 bug（key 2785 与 kwargs 不一致；strict/loose 两套口径须固定） |
| **IH-Challenge** | OpenAI, 2026 | RL 训练集，多层级指令冲突 | **Apache-2.0**，非 gated | 合成，可离线 | **权限门语义最贴近且可程序化判定**：system > user > tool > third-party 优先级 + 过度拒答轴 | 训练集非评测集，需自建 held-out |
| **AutoIF** | Qwen/Alibaba, ICLR'25 Spotlight | 方法 + 代码，可扩到万级 | 代码许可未核实 | 可离线生成 | **规则工厂**：规则 → LLM 生成 verifier 代码 + 单测 → 交叉执行 + 回译 NLI 过滤 | 生成物必须走 proposal 通道（见 §F6） |
| FollowBench | HKUST-GZ + 华为, ACL'24 | 820 条指令 / HF 1.85k 行 | **Apache-2.0** | 评测需 GPT-4 judge | 5 类约束 × 1–5 级递增 ⇒ 天然的「规则逐条加码」阶梯 | 开放题靠模型判，非纯机械 |
| ComplexBench | 清华, NeurIPS'24 D&B | 1,150 条，每条 4–19 个约束 | 数据 **CC BY 4.0**，代码 MIT | 可离线 | 「多约束组合 + 依赖聚合」最接近我们的组合式规则 | 评分依赖 LLM + 规则混合 |
| InFoBench | 2024, Findings ACL | 500 指令 / 2,250 分解问题 | 许可未核实 | 可离线 | **DRFR（分解需求满足率）** ⇒ 可移植为我们的 rule oracle 模板 | — |
| Conifer | 2024 | 35,613 条 / 13,606 段多轮 | 论文 CC BY 4.0；HF 许可未核实 | 可离线 | **不是评测集而是训练集**；价值在 process feedback 结构（难指令→失败→判词→正确答）⇒ 判据缺陷样本来源 | 模型 ToS 约束（GPT-4 生成） |

## F2. agent 策略/规则遵循与交互式任务

| 数据集 | 机构/年份 | 规模 | 许可 | 离线 | 用法 | 限制 |
|---|---|---|---|---|---|---|
| **AgentDojo** | ETH + Invariant Labs, 2024 | 97 任务 / **629 安全用例** / 4 suites | **MIT** | 完全离线（`pip install agentdojo`） | **权限门对抗层范式**：`utility` + `security` 双指标；挑 20–30 条改写成我们的越权场景（成本最低、语义最近） | 注入 payload 很少（4 域分别 6/5/7/9 条），易被针对 |
| **τ-bench / τ³-bench** | Sierra, 2024 / 2025–26 | τ-bench: retail 115 + airline 50；τ³: 5 域 × 6 语言 × 50 冻结任务 | **MIT** | text 可离线（user 为 LLM 模拟 ⇒ 非确定性）；**voice 需付费 API** | **policy 原文 + 工具 + DB 终态 + pass^k** ⇒ 与「书面规则下行动」同构；policy wiki 原文即我们的角色权限表模板 | 单 agent、客服域；τ 1.0.1 与 2.0 不可比 |
| Agent-SafetyBench | 清华, 2024/AAAI-W'26 | 349 环境 / 2,000 用例 / 8 风险类 / **10 种 failure mode** | 许可未核实 | 可离线 | **10 种 failure mode = 现成失败分类学**，可映射到越权/委托错配/审查缺失/门禁绕过 | 环境自建，接入成本中等 |
| AgentHarm | UK AISI/ETH, 2024 | 110 恶意任务（增强 440）/ 11 危害类 / 含 benign 对照 | MIT + 附加条款 | 可离线 | 「该拒绝时是否拒绝」⇒ 越权三要素的拒绝侧 | **红线**：含真实可操作有害内容 ⇒ 仅隔离评测、禁当训练目标、禁再分发 |
| ToolEmu | Toronto, ICLR'24 Spotlight | 36 toolkits / 311 tools / 144 cases | 许可未核实 | 工具由 LM 模拟 ⇒ 不可完全确定性复现 | 高风险工具上的 agent 行为 + 自动风险评审 ⇒ 审查配对的外部参照 | emulator 自身 31% 误报 |
| R-Judge | EMNLP Findings 2024 | 多轮交互 + 人工安全标注 | 许可未核实 | 可离线 | **判官层**：判「交互记录是否有风险」⇒ 权限违规判定器 baseline | — |

## F3. 真实 / 合成 agent 轨迹

| 数据集 | 机构/年份 | 规模 | 许可 | 形态 | 对我们的用法 |
|---|---|---|---|---|---|
| **nebius/SWE-agent-trajectories** | Nebius | **80,036 条**（13,389 成功 / 66,647 失败） | CC BY 4.0 + 逐仓库 + Llama 3.1 输出条款 | 完整 trajectory JSON（system prompt / exit_status / eval_logs） | **失败挖掘方法论 + 失败率基线** |
| nebius/SWE-rebench-openhands-trajectories | Nebius | 67,074 条 | CC BY 4.0 + 逐仓库 | messages + tool_calls + `resolved` + 自写测试正确性 | 同上 |
| nvidia/Nemotron-SWE-v1 | NVIDIA | 59k 轨迹 | CC BY 4.0（部分 BSD-3） | 可回放 | 失败分类学对照 |
| **nvidia/Nemotron-Agentic-v1** | NVIDIA | 合成多轮 tool-use（user/agent/tool 三角色 + judge 过滤） | 许可未核实 | **多角色**轨迹 | **与我们「角色矩阵」最贴近的轨迹形态** |
| AgentNet / OpenCUA | xlang-ai, NeurIPS'25 Spotlight | **22,625 条**（均 18.6 步） | MIT（**仅覆盖代码，不覆盖画面**） | 真实桌面录屏 | ⚠ **真人 PII + 第三方界面版权**：不入库、不外传、只本地只读抽样 |
| AgentTrek | xlang-ai, ICLR'25 Spotlight | 23,430 教程 → 10,398 成功轨迹 | 许可未核实 | GUI 动作 + 截图 | 离线需自建回放 |
| AgentBank | EMNLP'24 Findings | 50,000+ 轨迹 / 16 任务 / 5 技能维度 | 许可未核实 | 交互记录 | 失败分类学对照 |
| SWE-Gym | 2024/ICML'25 | 2,438 可执行 + 64,689 raw | **Apache-2.0** | 轨迹 + 可执行环境 | 任务工厂（但域不匹配） |
| AgentGym / AgentTraj-L | 复旦, ACL'25 | 14 环境 / ~1.4 万轨迹 | 许可未核实 | ReAct 统一格式 | 格式对照 |
| R2E-Gym | 2025 | 8,135 可执行环境 / 3,321 成功轨迹 | 许可未核实 | 轨迹 + 环境 | 同上 |

> 结论：轨迹类**只用于方法论与失败率基线**，不要直接当我们的 case 源（域不匹配）——我们自有的 1,828 条真实 session 更贴题。

## F4. 合成任务工厂

| 数据集 | 规模 | 许可 | 自动化 | 对我们的关系 |
|---|---|---|---|---|
| **SWE-smith** | 50k+ 实例 / 128 仓库 | **MIT** | 程序化 + LM 注入 bug → 自动生成 F2P 测试 | **注入式任务工厂范式可迁移到「配置缺陷注入」**（故意放宽权限、删审查步骤、错配委托） |
| SWE-Gym | 2,438 可执行 / 64,689 raw | Apache-2.0 | 真实 PR 反向抽取 | 真实 issue 工厂 |
| SWE-bench Pro | 642（HARD-51）/ 11 仓 / Go·Py·JS·TS | harness MIT；公开集**强 copyleft GPL** | 人工 + 盲实现校验 | **长程（小时级）⇒ 成本/时长标尺价值 > 任务价值** |
| SWE-bench Multimodal | 619 / 480 test，JS·TS | 逐仓库（含 **GPL-2.0 / LGPL-2.1**） | 真实 PR + 图像 | 与配置主题无关 |
| SWE-PolyBench | 2,110，4 语言 | **MIT** | 真实 PR + `task_category` 标注 | 唯一带任务类别的工厂 |
| SWE-bench-Live | 1,565+ / 164 仓，每月 +50 | 未核实 | RepoLaunch 全自动 | **抗污染：持续新增** |
| SWE-rebench | 27,878 行（V2 号称 12 万+ 多语言） | CC BY 4.0 + 逐仓库 | 全自动挖掘 + 去污染 | 自动化流水线最完整 |
| Multi-SWE-bench | 1,632 / 7 语言 | 代码 Apache-2.0；数据 CC0 + 逐仓库 | 真实 PR | 多语言覆盖 |
| BugsInPy / Defects4J / Codeflaws | 493 / 438+ / 3,902 | 混合未核实 | 人工筛选 | 纯代码缺陷 ⇒ 与配置主题正交 |

## F5. 判官可靠性与判据缺陷

| 数据集 | 规模 | 许可 | 用法 |
|---|---|---|---|
| **JudgeBench** | **620 对**（GPT-4o 350 + Claude-3.5 270），**客观标签** | 许可未核实 | **`judge_defect_rate` 的直接对标**：有 ground-truth 优劣标签可算 judge 误判率（注意：任务是知识/推理/代码，不含规则遵循判定） |
| **RewardBench** | ~3k 偏好对；chat/safety/reasoning/reasoning-hard | 子集 permissive | 判官/奖励模型校准；跨域偏移对照 |
| **FLASK** | 4 能力 / **12 细粒度 skill** rubric | 论文 CC BY 4.0 | **rubric 模板**：把「拒绝/解释/引导」拆成 3 个可判子项 ⇒ 直接解决我们三要素判据的颗粒度问题 |
| **DevAI / Agent-as-a-Judge** | 55 任务 / **365 条层级需求（DAG 依赖）** | **MIT** | **层级需求 DAG 判分** = 我们「审查配对」的判分模型；agent-judge 与人类一致性显著高于 LLM-judge |
| **LLMBar** | 对抗性 instruction-following 偏好对 + CaseStudy | 未核实 | **判据缺陷的历史证据**：judge 系统性偏好「看似好」的违规输出 ⇒ 正是 `judge_defect_rate` 要复现的现象 |

## F6. 成本/时长/难度标尺

| 数据集 | 规模 | 许可 | 用法 |
|---|---|---|---|
| HCAST / METR public-tasks | 任务套件 170 个（含 97 来自 HCAST），人类耗时 ~1 分钟–30 小时 | public-tasks **MIT**；hcast-public **已 deprecated**（许可未核实） | 唯一公开 `human_minutes` 标尺 ⇒ 给我们的 case 标「人类等价时长」 |
| METR eval-analysis-public | 逐任务 `human_minutes` + 运行结果（TH1.1 228 任务） | 未核实（DVC 管线） | **P0「同一快照同数」之外的长程对照** |
| CORE-Bench | 270 任务 / 90 论文 / 3 学科 | 代码 **MIT**；数据集仓库内 **GPG 加密**；HF 镜像 **CC BY-NC-SA 4.0（非商用）** | 唯一**逐任务公开美元成本**（$0.64 / $1.20 / $2.96 ±）⇒ 预算建模 |
| AgentBoard | 9 任务 / 1,013 环境 | 未核实 | **progress rate（部分完成度）** ⇒ 比 pass/fail 更适合「配置部分生效」；含 turn 级成本 |

## F7. 许可与隐私红线（写入本仓前的硬约束）

| 数据集 | 红线 | 处置 |
|---|---|---|
| **AgentHarm** | MIT + 附加条款，含真实可操作有害内容 | 只放隔离目录、只做评测、**禁当训练目标、禁再分发** |
| **AgentNet / OpenCUA** | 真人桌面录屏 ⇒ PII + 第三方界面版权；MIT 只覆盖代码 | **不入库、不外传、只本地只读抽样** |
| **CORE-Bench（HF 镜像）** | 标 **CC BY-NC-SA 4.0**，与 repo 的 MIT 声明冲突 | 商用环境只用 repo 内 GPG 加密版；冲突未澄清前不进 CI |
| **SWE-bench Pro / SWE-bench Multimodal** | 公开集含 **GPL / LGPL** 仓库 ⇒ patch/test_patch 属衍生作品 | **禁止再分发**；只本机跑、只保留指标 |
| SWE-rebench / Multi-SWE-bench / nebius·nvidia 轨迹 | 数据集级 license 之上**叠加逐实例 license** | 必须逐 instance 读 `license` 字段，不能只看数据集级 |
| Conifer / AutoIF / nebius·nvidia 轨迹 | 模型输出受上游 ToS 约束（GPT-4 / Qwen / Llama） | 不得声称「纯 CC BY」 |
| 真实用户数据 | 本清单中**只有 AgentNet 是真人操作**；τ-bench 的 user 是 LLM 模拟，HCAST 的 human baseline 是工时标注 | 隐私风险集中在 AgentNet 一项 |

## F8. 与我们主题最贴近的（贴近度排序）

1. **IH-Challenge** — 指令优先级 = 权限门的形式化；唯一同时满足「可机械判定」+「权限语义」的公开集
2. **AgentDojo** — 权限/越权 + 双指标 + MIT + 可离线
3. **τ-bench / τ³-bench** — 书面 policy 下的行动 + pass^k 稳定性
4. **Agent-SafetyBench** — 失败分类学（10 类）
5. **R-Judge / ToolEmu** — 「agent 行为是否越界」的判官评测
6. **Nemotron-Agentic-v1** — 唯一 user/agent/tool 三角色的轨迹形态
7. **AgentHarm** — 拒绝侧（仅评测、需隔离）

## F9. 「规则 → 程序化判据」路线的自指风险（须写进 ADR-0004）

AutoIF 式自动生成 verifier 不会破坏「判据外置」，前提是满足三条：

1. **authorship ≠ adjudication**：verifier 在评测时固定、哈希 pin、改进者运行期不可写；
2. 准入需**人审 + 变红演练**；
3. **被测 agent 不得自审自**（case 定义对 agent 不可读；提案与审批分离）。

自动生成的**反例集直接充作 mutation 检查输入** —— 被自己的反例击败的 verifier 即拒。

真正的红线不是「谁写的」，而是：**被测 agent 不得写判据**、**RSI 不得自动批准生成的判据**。
