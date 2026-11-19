# 借鉴方向与方案：调研 → 我们 ADR 的映射（含裁决建议）

| 字段 | 值 |
|---|---|
| 日期 | 2026-11-19 |
| 输入 | `01`~`04` 四类外部材料 + `06` 数据集调研 |
| 审查 | metis（gap 分析，材料）→ oracle（裁决建议，判定 APPROVE） |
| 状态 | **裁决已通过（2026-11-19）**：①接受（语义层+轻量档+容器档触发线）②接受（含 gate 改写）③接受（默认轻量）④接受（P1，试点提前）⑤接受（三元组）。§5 已按裁决落地 |

## 1. 采纳判据

| 判据 | 含义 |
|---|---|
| 证据强度 | 一手来源 + 可复现做法 > 论文自报 > 二手综述 |
| 相容性 | 不违反「判据外置」「安全核禁止自动改」「P0 不触碰宿主」 |
| 成本 | 相对当前规模（1 operator / 1,828 sessions）是否可承受 |
| 独立性 | 是否引入新依赖或口径断点 |
| **本地可验证前置** | 采纳前，本仓必须先能产出可机械判定的前置证据（否则只是名词） |

## 2. 采纳映射（去重后 18 条独立动作）

| # | 发现（来源） | 受影响 ADR | 处置 | 期 | 本地可验证前置 | 状态 |
|---|---|---|---|---|---|---|
| 1 | 写集/进程隔离才有效，「明令禁止」无效（DGM 删检测标记；AlphaEvolve EVOLVE-BLOCK） | ADR-0004 | 不可写集 = 安全核 ∪ {评分器, rubric, eval 定义, manifest}，与安全核**共用一份声明** | P1 | solver 存在 | 建议 |
| 2 | 评分器物理隔离（PaperBench 三容器 / verifiers isolated scoring / Inspect compose） | ADR-0006 | 采纳：**语义层**现在生效；**轻量档** P1；**容器档**触发后 | P1 | case 集存在 | 建议（依赖 ① 的强度档） |
| 3 | 判据缺陷可测（OpenAI 审计 59.4%；TB2.0 ~30%） | ADR-0005 | `judge_defect_rate` | P1 | 抽样框 + 审计者 + 作废规则 | 建议 |
| 4 | 作弊 attempt 必须计为失败（METR） | ADR-0005 | `cheating_attempt_rate`，识别到的作弊计失败 | P1 | 检测机制（人工/规则） | 建议 |
| 5 | reward hacking 横向泛化到安全行为（Anthropic 2025-11-23） | ADR-0004 | **降级**为「冻结提案 + 审计受影响判据 + 只回滚同批次」；不采用「全局回滚」（证据来自 RL 层，机制不同） | P2 | — | 降级采纳 |
| 6 | 沙袋可污染 A/B（ICLR'25） | ADR-0004 | A/B 外部执行；arm 标签只由 runner 持有；审阅者不见 arm | P1 | arm 机制存在 | 建议 |
| 7 | A/B + 回滚是文献空白区；工业契约可抄 | ADR-0004 / ADR-0005 | Δ 口径 + 不计入 Δ 的 grader + 成本熔断（`partial` 标记）+ 回滚三元组 | P1 | 候选 patch 可生成 | 建议（依赖 ③⑤ 的裁决） |
| 8 | 轨迹契约（ATIF / Inspect EvalSpec） | ADR-0002 | **借鉴字段命名**（不 vendor schema），加 `llm_call_count` / `schemaVersion` / join key | P1 | trace 落盘路径存在 | 建议 |
| 9 | 脱敏默认 + 显式开关 + 截断上限（Claude Code 60 KB） | ADR-0001 / ADR-0002 | P0 快照即按此处理（序列化器 allowlist） | **P0** | 序列化器存在 | 建议 |
| 10 | 指标分层 + 成本同表（CORE-Bench / BFCL / Claude Code OTel） | ADR-0005 | transcript / latency / state 三层 + `cost_coverage` | **P0** | 指标脚本存在 | 建议 |
| 11 | 不确定性用区间（METR 三层 bootstrap） | ADR-0005 | P0 只报点估计并显式写「无区间」；P1 给区间但 n<30 不作推断 | P1 | — | 部分采纳 |
| 12 | pass@k vs pass^k（τ-bench；Codex 无偏式） | ADR-0003 / ADR-0005 | capability 用 pass^k；引用 pass@k 须用无偏式 | P0/P1 | — | **已落地**（修 ADR-0005 口径冲突） |
| 13 | 每 trial 干净环境（曾观测到读上次 git 历史获益） | ADR-0003 | 准入条件 + 状态清单（HOME / session 目录 / git 历史 / TMPDIR） | P1 | — | 建议 |
| 14 | 每 task 一个 reference solution（CORE-Bench 42→95%） | ADR-0003 | 准入条件：**参考解须通过该 oracle**（不是"存在"） | P1 | — | 建议 |
| 15 | 20–50 个来自真实失败的 case 起步（Anthropic） | ADR-0003 | 收敛候选池规模；但「能否标出 20–50 条高精度失败」是未验证前置 | P1 | 失败标注精度 | 建议（前置待验） |
| 16 | grade outcome, not path；工具序列当 oracle 过脆 | ADR-0003 | 写入判定优先级 | P1 | — | 建议 |
| 17 | judge 必须被校准（JudgeEval / LLM-judge bias） | ADR-0003 | LLM judge 只作排序 + 校准集 + 一致率报告 | P1 | 校准集 | 建议 |
| 18 | 失败分类学（Agent-SafetyBench 10 类 / AgentBench 终止原因 / LangChain doom loop） | ADR-0005 | 作为失败模式聚类的枚举来源 | **P0** | — | 建议 |
| 19 | 「harness 覆盖率」是全行业未解问题（Fowler） | ADR-0005 | `oracle_mutation_catch_rate` / 恒真检查 / `skip_rate` 作覆盖率代理，并声明局限 | P1 | 变异算子集已定义 | 建议 |
| 20 | 固定模型只改 harness 有 +13.7（LangChain TB2.0） | 架构文档 | **仅作上界引用**（其 tools/middleware 恰在我方安全核内），不作为目标值 | — | — | 已改写 |
| 21 | 评测对象 = harness + 模型联合体（Anthropic 定义） | 架构文档 | 术语对齐 | — | — | 已落地 |
| 22 | 通用开放式 RSI（DGM / AFlow / ADAS） | ADR-0004 | **不采纳**：与安全核冲突；只借护栏与失败模式 | — | — | 不采纳 |
| 23 | RL 训练路线（Agent Lightning / RAGEN / AgentGym-RL / SWE-RL） | — | **不采纳**：层级不同（我们改 prompt/规则，不训权重）；只借「template collapse ⇒ 只看分数会漏」 | — | — | 不采纳 |
| 24 | OTel 作内部事实源 | ADR-0002 | **不采纳**（仍 Development、无 pin、不含 seed/prompt hash）⇒ 只作出口层 | — | — | 不采纳 |
| 25 | 容器依赖（gVisor / Firecracker / Inspect / Harbor / verifiers） | ADR-0006 | **条件接受**：默认轻量路径；容器档设触发线（见 §3 ③） | P1 | 依赖可用性探针 | 建议 |
| 26 | prompt registry（Langfuse version+label） | ADR-0004 | **本期不做**：先落「patch + 判据版本 + 任务集版本」；触发线：月合并 >5 或并存变体 >3 | P2 | — | 建议 |

## 3. 裁决建议（oracle 判定 APPROVE；metis 提供 gap 分析）

> metis 指出：5 个裁决点实际是 **3 个问题**——①+③ =「隔离门槛与实现强度」；②+④ =「收益承诺与可测性」；⑤ =「回滚点由哪些哈希定义」，且「三元组 vs registry」是伪二分（三元组是**内容**，registry 是**切换机制**）。
> oracle 的一处修正：①与③**不该捆死**——契约语义现在就很便宜（解锁 manifest 修补），强度才可推迟；捆在一起会让 ① 被 ③ 拖死。

### ① 新增 ADR-0006（评测隔离契约）——**接受，但拆成语义层与实现档**

- **推荐**：现在接受为 Proposed。**语义层立即生效**（不可读集定义、三段式 artifacts 契约、gold/rubric 不注入 agent prompt）；**实现分两档**——轻量档（工具层写集 + 文件权限位 + 独立评分进程 + 路径可达性测试）P1 落地；容器档（fresh grading container、network none 可证、双容器重跑同分）待 ③ 的触发线。
- **生效条件**：ADR-0006 验收判据**分档重写**（轻量档只承诺路径不可达与 artifacts 显式声明）；不可写集并入 ADR-0004 的**同一份** manifest（防清单漂移）。
- **明确不要做**：不要按原文整体接受（否则 P1 无 Docker 不可验收）；不要让 ADR-0006 单独重定义安全核。
- **补充（oracle）**：隔离缺口当前**就 RSI 攻击向量而言**不可利用；但 P1 一开始建 case，gold/rubric 经 prompt 注入是我们**自己流程**的近失风险 ⇒ **信息隐藏规则是 P1 级，容器机制才是 P2 级**。

### ② 接受「收益预期下调」——**接受，且要改写合并 gate 语义（不止写文档）**

- **推荐**：接受「个位数 pp」定位；同时把 ADR-0004「A/B 提升即合并」与 ADR-0005「≥10 条×N=3 即可合并」改写为：R 层合并依据 = **contract 0 回归 + skip 纪律 + 方向性 capability 信号 + 人审**。
- **生效条件（可判定）**：capability 集规模 × N 的分辨率 **> 5pp 期间**（尚不能分辨 5pp），任何 Δ 结论标注「方向性」；要分辨 5pp 需约 **1600 次/臂**（50 任务 × N≈32），作为 P2 后重估的数字锚点。
- **统计事实（metis 复核，oracle 复核通过）**：两比例检验（基线 0.5、α=.05、功效 80%）下 Δ=0.05 需 ~1600/臂、Δ=0.10 需 ~392/臂、Δ=0.20 需 ~98/臂；当前 10 任务×N=3=30/臂只能分辨 ~36pp，50×3=150/臂只能分辨 ~16pp；且 run 级样本在 task 内相关，**有效 n 更接近任务数**，上述仍是乐观上界。
- **明确不要做**：不要在 10×3 规模下保留「提升即合并」字面表述；不要把 +13.7 写成预期收益。
- **关键联动**：② 与 ④ 在数学上等价——判据缺陷率 10–30% ⇒ 10 条用例里 1–3 条坏判据即可造出 10–30pp 假 Δ ⇒ **当前设计下 Δ 不能作为合并依据**。

### ③ 容器依赖——**条件接受：默认轻量路径，容器档设明确触发线**

- **推荐**：P0/P1 首增量**不引入 Docker 硬依赖**。容器化触发线（任一满足即重审）：(a) E 层开始**真实执行 agent 代码**（而非查 DB）；(b) ADR-0004 P2 恢复、自动提案进入执行；(c) 出现 gold/rubric 经 prompt 注入的实测近失。
- **生效条件**：`install_testbed.sh` 与本机 cron 保持无容器可跑；ADR-0006 轻量档判据可在无 Docker 下全部勾选。
- **明确不要做**：不要「为将来准备好」提前给 CI 加 Docker（违反成本一等）；不要在内部 trace 契约（ADR-0002）冻结前选型 runner。
- **口径纠正（metis）**：「CI 无 Docker」按字面为假（GitHub 托管 runner 预装 Docker）；真正的问题是**operator 本机是否装 Docker** —— 该事实目前**无探针**，需在目标机复跑。

### ④ 判据缺陷审计——**P1，但试点提前，且先补估计量定义**

- **推荐**：P1 排期接受；**10 条试点在 capability 集开建前先做**，首批直接用现有 `tests/integration` 的 7 条 CS 用例（便宜，且 `runtime-assertion-discipline.md` 的反面教材正出自它们）。`judge_defect_rate` 先定义估计量（抽样率、双人背对背审、分歧裁决、缺陷确认协议）再进指标表；**审计样本对新增用例过采样**（闭合「提案者灌弱判据赌抽样漏检」）。
- **生效条件（可判定）**：试点 10 条缺陷率 > 10% ⇒ 冻结扩量、先修判据；此后每新增 20 条或每季度（先到为准）一轮审计；提案者不得审自己提交的用例。
- **明确不要做**：不要做成一次性事件（必须常态化）；不要报 `judge_defect_rate` 而不给分母与抽样方法。
- **追加（metis）**：审计与 RSI 共享人力会形成自指回路 ⇒ 缓解必须是**顺序 + 出处**：审计发生在 A/B **之前**并冻结 `oracle_sha`；新增 case 在首次进入 A/B 前 **100% 审计**（非抽样）；审计记录由 harness 写（作者无写权限）；审计人力是**固定预算行**，不与提案吞吐竞争；「审计覆盖率」本身作为报告字段。

### ⑤ 回滚语义——**本期三元组，registry 显式 defer**

- **推荐**：落 `patch + 判据版本 + 任务集版本`。ADR-0005 §3 的五元组**缺** `criteria_version`（oracle 定义集哈希）与 `taskset_version`（用例 + fixture 集哈希）——这是真正的工作量，很小。
- **生效条件**：合并时回滚点 = manifest 一行三元组；revert 演练必须**恢复三元组**并重跑 held-out 验证。
- **触发线**：月合并数 >5 或并存 prompt 变体 >3 时再评估 registry（届时照抄 Langfuse 式 version+label）。
- **明确不要做**：不要本期建 registry（无组件、无运维）；不要把「版本字段」与「切换服务」混为一谈。

## 4. 数据集调研如何改变裁决（见 `06-dataset-candidates.md`）

| 结论 | 影响 |
|---|---|
| **IFEval 式「规则 → 程序化判据」应上升为 P1 capability oracle 的主创作路径**（`instruction_id_list` + `kwargs` + 离线 checker，Apache-2.0） | 把 ADR-0003「机械 oracle 优先」从原则变成可执行流水线；我们 5–8 条自有规则可先行机械化 |
| **AutoIF 可作规则工厂，但必须走 proposal 通道**（生成 verifier + 单测 + 反例 ⇒ 人审 + 变红演练） | **不破坏判据外置**，前提是 authorship ≠ adjudication：verifier 评测时固定、哈希 pin、改进者运行期不可写；自动生成的**反例集直接充作 mutation 检查输入** |
| IH-Challenge（system>user>tool>third-party） | 权限门语义最贴近且程序化可判 ⇒ capability 用例的领域语言 |
| AgentDojo（utility + security 双指标，MIT，可离线） | 对抗层范式；与 `cheating_attempt_rate` 同构 |
| τ-bench/τ³-bench（policy 原文 + pass^k） | 「书面规则下行动」+ 配置稳定性度量 |
| JudgeBench / RewardBench / LLMBar | `judge_defect_rate` 的外部锚；LLMBar 提供了「judge 偏好看似合规的违规输出」的历史证据 |
| FLASK（12 skill rubric）/ DevAI（365 条层级需求 DAG） | 「三要素」拆子项 + 依赖传播 ⇒ 我们判据书写模板 |
| Agent-SafetyBench 10 种 failure mode | 失败分类学骨架，比从 1,828 条 session 归纳更快收敛 |
| 许可红线 | AgentHarm（有害内容，仅隔离评测禁再分发）、AgentNet（真人 PII）、CORE-Bench HF 镜像（非商用）、SWE-bench Pro/Multimodal（copyleft 传染）⇒ 写入 `docs/research/README.md` |

## 5. 返工清单

### 5.1 已落地（与裁决无关的缺陷修正）

| 位置 | 修正 | 依据 |
|---|---|---|
| ADR-0004 安全核清单 | 补 `harness/metrics/**`、`harness/criteria/**`、`harness/eval/**`、`harness/safety-core.*`、`docs/runtime-assertion-discipline.md`、`docs/adr/**` | ADR-0005 已声明指标定义属安全核；「判据的判据」此前不在清单内 |
| ADR-0005 §2 | 能力层 `pass@3` → **pass^k**（k 次全成功） | 与 `05 #12` 方向相反，属规格级冲突（指标定义属安全核 ⇒ 双真源） |
| ADR-0005 §1 | 新增「一致性」行，注明 pass@k 的无偏式 | Codex 论文附录 A |

### 5.2 已落地（2026-11-19，按裁决）

| # | 动作 | 落点 |
|---|---|---|
| a | 合并 gate 改为「contract 0 回归 + skip 纪律 + 判据审计 + 方向性 + 人审」 | ADR-0004 决策 5、ADR-0005 §4 |
| b | manifest 加 `criteria_version` / `taskset_version` | ADR-0005 §3 |
| c | 新增 ADR-0006（语义层 + 轻量档 + 容器档触发线 + 本环境 ECI 能力实测） | `docs/adr/ADR-0006-evaluation-isolation-contract.md` |
| d | 两条新指标补估计量定义；另加 `false_negative_rate`；`metrics_version` 变更门 | ADR-0005 §1/§4 |
| e | ADR-0003 准入 8 条（含 reference solution 通过、替代正确解、干净环境、case 不可达、审计记录）+ 审计常态化 | ADR-0003 决策 3/4 + Verification |
| f | 架构文档补 MDE 表、+13.7 上界、隔离能力实测 | `docs/architecture/agent-harness-and-rsi.md` §5.4 / §9 |
| g | 不可写集与安全核共用一份 manifest | ADR-0004 决策 4、ADR-0006 §1 |

### 5.3 现有 Verification 中会恒真或退化为现状描述的条目（需重写）

`ADR-0001`（git status 为空 → 需加「脚本确实处理 N>0」前提）、`ADR-0002`（±2% 一致在 trace 由 DB 派生时误差恒为 0；grep 抽样证明不了「不写」）、`ADR-0003`（held-out 写集检查在落地后成为 manifest 重述）、`ADR-0004`（「有记录」可被文本满足）、`ADR-0005`（同一 snapshot 两次运行一致在构造上恒真）、`ADR-0006 草案`（grep → 挂载表 / env allowlist / 路径探针 / egress 探针必须失败）。

## 6. 不采纳与待验证（附理由）

| 项 | 处置 | 理由 |
|---|---|---|
| 通用开放式 RSI | 不采纳 | 与安全核冲突；只借护栏与失败模式 |
| RL 训练路线 | 不采纳 | 层级不同；只借退化诊断（template collapse） |
| OTel 作内部事实源 | 不采纳 | Development、无 pin、不含 seed/prompt hash；只作出口层 |
| LLM judge 作主 gate | 不采纳 | 位置/长度/自增强偏差可量化、伪造引用即可骗过强模型；只作排序 + 校准集 |
| AutoIF 全自动生成并自动接纳判据 | 不采纳 | 生成者 ≈ 被评者 ⇒ 新自指回路；只走 proposal + 人审 + 变异门 |
| 直接采 τ-bench 任务集本体 | 不采纳 | 采范式（policy 原文 + pass^k + 状态 oracle），不采数据 |
| 立即上 gVisor/Firecracker | 待验证 | 见 ③ 的触发线 |
| 复用 Inspect/Harbor/verifiers | 待验证 | 排在 ADR-0002 契约冻结之后 |
| Langfuse 式 registry | 本期不做 | 见 ⑤ 的触发线 |
| SWE-* 任务集（BugsInPy/Defects4J/SWE-Pro/MM/PolyBench/Multi） | 不投入 | 与「配置/权限/规则」正交；仅在需要长程成本对照时取 SWE-bench Pro 的时长分布 |

## 7. 裁决结果（2026-11-19 已通过）

| 裁决点 | 结果 |
|---|---|
| ① ADR-0006 | **接受**：语义层现在生效；轻量档 P1 默认；容器档按触发线（已实测本环境可在容器内创建 ECI 沙箱） |
| ② 收益预期下调 | **接受**：并改写合并 gate（Δ 只作方向性）；MDE 分辨率表写入架构文档 |
| ③ 容器依赖 | **接受默认轻量路径**；容器档触发线：E 层真跑 agent 代码 / P2 恢复 / 注入近失 / 探针被绕过 |
| ④ 判据缺陷审计 | **接受**：P1，试点提前（首批 10 条含现有 CS 用例）；新增用例 100% 审计；`auditor ≠ author` |
| ⑤ 回滚语义 | **接受**：本期三元组（patch + `criteria_version` + `taskset_version`）；registry 触发线（月合并 >5 或并存变体 >3） |

**环境事实补充**：当前会话本身运行在 Aliyun ECI 实例内（`eci-uf65o2vzvkjp87qpefqj`）。已实测可在容器内创建新的 spot ECI 沙箱（`aliyun eci CreateContainerGroup` → Running ≈40s）、`ExecContainerCommand` 执行命令、`DeleteContainerGroup` 销毁；新实例 `/workspace` 为空、`/home/ubuntu` 仅默认 dotfiles ⇒ 容器档在本环境可达，无需 Docker daemon。脚本：`~/my-docker-env/aliyun_sandbox.sh`。

**重启/复用提示**：`aliyun` CLI 已安装到 `~/.local/bin/aliyun`（tar 包来自 `~/my-docker-env/`）；凭据从 `~/my-docker-env/my_eci.txt` 读取（**不要提交或外传**）。
