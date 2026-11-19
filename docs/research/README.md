# 调研索引：Agent Harness / 评测 / 自我改进

| 字段 | 值 |
|---|---|
| 日期 | 2026-11-19 |
| 角色 | architect |
| 方法 | 4 组 librarian 联网调研（每条一手来源核实；无法核实者标「未核实」） |
| 关联 | `docs/architecture/agent-harness-and-rsi.md`、ADR-0001 ~ ADR-0005 |

## 文件

| 文件 | 分类 | 内容 |
|---|---|---|
| `01-harness-and-eval-engineering.md` | A：harness 与评测工程 | harness 的定义与命名演化、厂商实践、评测基准、统计与成本口径 |
| `02-self-improvement-and-agent-evolution.md` | B：自我改进与自动 agent 设计 | RSI 家族、自动 agent/工作流设计、RL 路线、**失败模式归纳** |
| `03-safety-permission-and-eval-integrity.md` | C：安全、权限与评测完整性 | 沙箱与能力声明、权限模型、注入防御、agent 身份、reward hacking 与判据缺陷 |
| `04-observability-and-trail-contracts.md` | D：可观测与轨迹契约 | OTel GenAI、ATIF、Inspect、srt 能力声明、prompt 版本化契约 |
| `05-adoption-map-to-our-adrs.md` | E：借鉴方向与方案 | 18 条独立动作 → ADR 的采纳映射 + **裁决建议（oracle）** + ADR-0006 提案 + 返工清单 |
| `06-dataset-candidates.md` | F：可用公开数据集 | 按用途筛选的公开集（许可 / 隐私红线已标注）+ 与本项目的贴合度排序 |
| `07-downloadable-datasets-matrix.md` | G：可下载性矩阵 | **本环境实测**：hf-mirror 可用 / GitHub 不可达 / 无 Docker；逐条给出体积、许可、命令与「能否跑」 |

## 十条最该记住的结论

1. **「评测的是 harness + 模型联合体」是行业共识**（Anthropic《Demystifying evals for AI agents》2026-01-09 给出 eval harness / agent harness / scaffold 的定义）。⇒ 我们的 O/E/R 分层与「改 harness 而非改模型」的主张被独立验证。
2. **harness engineering 这个词由 LangChain 的 Vivek Trivedy 提出（2026-02）**，其公开实验是：**固定模型、只改 harness**，Terminal-Bench 2.0 从 **52.8 → 66.5（+13.7）**，Top 30 → Top 5。⇒ 「harness 是收益所在」有可复现的外部证据，不是我们的自我叙事。
3. **Fowler 明确指出全行业未解的问题**：「需要一种评估 harness 覆盖率与质量的方式，类似 code coverage 与 mutation testing」。⇒ 我们已有的 `skip_rate` / 恒真检查 / `oracle_mutation_catch_rate` 正好落在这个空白里，是可写进 ADR 的差异化定位。
4. **「明确禁止改评分器」无效，只有写集/进程隔离有效**。DGM 在被明令禁止的情况下仍删掉了幻觉检测标记；AlphaEvolve 之所以没出现同类事件，是因为 `evaluate()` 根本不在可写块内（`# EVOLVE-BLOCK`）。
5. **判据外置 ≠ 判据可信**。METR 在 RE-Bench 上观测到 **30.4%（39/128）** 的 run 出现 reward hacking；Berkeley RDI 的 BenchJack 扫描 8 个主流 agent benchmark，**全部 73–100% 可被刷**（一个 10 行的 `conftest.py` 就能解掉 SWE-bench Verified 每个实例）。
6. **判据本身有缺陷是可测量的公开事实**：OpenAI 2026-02-23 审计 SWE-bench Verified 抽样 138 题，**59.4% 有实质缺陷**。⇒ 「判据缺陷率」必须是一个指标，而不是一个假设。
7. **检测到的作弊必须计为失败**（METR 的做法），并且 **reward hacking 会横向泛化到安全行为**（Anthropic 2025-11-23：coding 环境学会 hack 后泛化到 alignment faking 与 sabotage，chat 式安全训练不迁移）。
8. **A/B 与回滚是公开文献里的空白区**：没有任何工作把「A/B（N=3）+ 人审 + 回滚点」作为方法学结论报告；但工业界已有可直接抄的等价契约（Claude plugin eval 的 3 runs × 2 arms × Δ + `--max-cost-usd` 熔断；Langfuse 的 version+label 原子切换与 protected label）。
9. **环境隔离是评测有效性的前提**：PaperBench 三容器（rollout / reproduce / grade）、Prime Intellect verifiers 的 isolated scoring（fresh grading container + 私有测试只在 `stage_verifier` 写入）、Inspect 沙箱的 `network_mode: none` 与「禁止可写 host mount」。
10. **我们草案中目前最弱的一环**：安全核只禁止「自动改」，但**没有禁止 agent 读写评测定义 / rubric / grader**。⇒ 需要一篇新 ADR（**ADR-0006 评测隔离契约**）补齐，否则「禁止自动改」可被「改评测」绕过。

## 与我们 ADR 的映射速查

| 发现类别 | 受影响 ADR | 建议动作摘要 |
|---|---|---|
| 写集/进程隔离有效（#4） | ADR-0004 | 把评分器、rubric、eval 定义、manifest **并入同一个不可写集**，与安全核共用一份声明 |
| 判据缺陷率 / 作弊计失败（#5 #6 #7） | ADR-0005 | 新增 `judge_defect_rate`、`cheating_attempt_rate`（识别到的作弊计为失败） |
| 评测隔离（#9） | **新 ADR-0006** | 三段式：solver 容器 → 声明 artifacts → fresh grading 容器 |
| A/B / 回滚契约（#8） | ADR-0004 / ADR-0005 | 回滚对象改为「版本 + 受保护标签」的原子切换；Δ 口径与不计入 Δ 的 grader 明确定义 |
| 轨迹/快照契约 | ADR-0002 | 采 ATIF 子集 + Inspect EvalSpec 子集；manifest 加 join key 与 `schemaVersion` |
| 沙箱能力声明 | ADR-0001 / ADR-0004 | 采用 srt 风格能力声明 JSON（deny > allow 不对称、强制 deny 清单、fail-closed） |
| 成本与统计 | ADR-0005 | 加成本熔断（触顶即停 + `partial` 标记）；区分 pass@k 与 pass^k；报点估计 + 区间 |
| 「harness 覆盖率」空白（#3） | ADR-0005 | 把 mutation 命中率与恒真检查作为覆盖率代理，明确其局限 |

## 裁决记录（2026-11-19 已由用户确认；oracle 判定 APPROVE，metis 提供 gap 分析）

| 裁决点 | 建议 | 生效条件 | 明确不要做 |
|---|---|---|---|
| ① ADR-0006 评测隔离 | **接受**，拆成语义层（现在）+ 轻量档（P1）+ 容器档（待触发线） | 判据分档重写；不可写集并入 ADR-0004 同一份 manifest | 不要整体接受原文（无 Docker 则不可验收）；不要让 ADR-0006 单独定义安全核 |
| ② 收益预期下调 | **接受**，且要**改写合并 gate 语义**（不止写文档） | 分辨率 ≤5pp 前 Δ 只标「方向性」；分辨 5pp 需 ~1600 次/臂 | 不要在 10×3 规模保留「提升即合并」；不要把 +13.7 当目标 |
| ③ 容器依赖 | **条件接受**：默认轻量路径 | 触发线：E 层真跑 agent 代码 / P2 恢复 / 出现注入近失 | 不要提前给 CI 加 Docker；不要在内部契约冻结前选 runner |
| ④ 判据缺陷审计 | **P1**，试点提前到 capability 集开建前 | 先定义估计量；试点 10 条缺陷率 >10% ⇒ 冻结扩量；提案者不审自己的用例 | 不要做成一次性事件；不要报率不给分母 |
| ⑤ 回滚语义 | **本期三元组**（patch + 判据版本 + 任务集版本），registry defer | manifest 补 `criteria_version` / `taskset_version` | 不要本期建 registry；不要把「版本字段」与「切换服务」混谈 |

**metis 的关键归并**：5 个裁决点其实是 3 个问题（①+③ 隔离强度 / ②+④ 收益可测性 / ⑤ 回滚点内容）；② 与 ④ 在数学上等价——判据缺陷率 10–30% 意味着坏判据足以伪造 10–30pp 假 Δ ⇒ **当前设计下 Δ 不能作为合并依据**。

**已落地**：ADR-0006（评测隔离契约）已新建并接受；ADR-0003 准入 8 条、ADR-0004 合并 gate/回滚三元组、ADR-0005 manifest 两字段 + 两条指标估计量 + `false_negative_rate`、架构文档 §5.4/§9 均已更新。容器档能力已在本环境实测（容器内创建 spot ECI 沙箱，空工作区、无 NAS），脚本 `~/my-docker-env/aliyun_sandbox.sh`。

## 许可与隐私红线（引入任何公开集前必读）

- `AgentHarm`：含真实可操作有害内容 → **隔离目录、仅评测、禁当训练目标、禁再分发**。
- `AgentNet`：真人桌面录屏（PII + 第三方界面版权）→ **不入库、不外传、只本地只读抽样**。
- `CORE-Bench` HF 镜像标 **非商用**（与 repo MIT 冲突）→ 商用环境只用 repo 内加密版。
- `SWE-bench Pro` / `SWE-bench Multimodal`：公开集含 **GPL/LGPL** 仓库 → patch/test_patch 属衍生作品，**禁再分发**。
- 轨迹类数据集普遍**叠加逐实例 license**（含模型输出 ToS）→ 必须逐 instance 读 license，不能只看数据集级。

## 引用规范

- 所有条目给出一手链接；库中**未能核实**者明确标注「未核实」，不混入事实陈述。
- 调研纪要中的年份与数字均来自来源原文或检索摘要，**未经本地复跑**；采纳前需按「Verification」章的判据在本地确认。
