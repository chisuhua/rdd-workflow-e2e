# 分类 A：Harness 与评测工程

## A1. 定义与术语

| 来源 | 日期 | 定义 / 主张 | 链接 |
|---|---|---|---|
| Anthropic《Demystifying evals for AI agents》 | 2026-01-09 | **evaluation harness** = 端到端跑评测、记录每一步、判分、聚合的基础设施；**agent harness / scaffold** = 让模型能作为 agent 行动的系统；「当我们评测一个 agent，我们评测的是 **harness 与模型协同工作的结果**」 | https://www.anthropic.com/research/demystifying-evals-for-ai-agents |
| LangChain《Improving deep agents with harness engineering》 | 2026-02-17 | 「**Agent = Model + Harness**」；固定模型、只改 harness，Terminal-Bench 2.0 **52.8 → 66.5（+13.7）**，Top 30 → Top 5；三个旋钮 = system prompt / tools / middleware | https://www.langchain.com/blog/improving-deep-agents-with-harness-engineering |
| Thoughtworks / Martin Fowler | 2026-04-02 | Guides（前馈）/ Sensors（反馈）× Computational / Inferential；**keep quality left**；三类 regulation = maintainability / architecture fitness / **behaviour**；「harnessability / ambient affordances」 | https://martinfowler.com/articles/harness-engineering.html |
| OpenAI《harness engineering》 | 2026-02-11 | 「我们最难的挑战现在集中在设计环境、反馈回路和控制系统上」（**正文 403 抓取失败，仅二手引用**） | https://openai.com/index/harness-engineering/ |
| Addy Osmani（二手综述） | 2026-04-19 | 归因 Viv Trivedy 提出 harness engineering；**ratchet** 纪律：每条 `AGENTS.md` 约束都应能追溯到一次真实失败；只在约束冗余时删 | https://addyosmani.com/blog/agent-harness-engineering/ |

**术语冲突提示**：OpenTelemetry 官方博客里的 “agent harness” 指**插桩 harness**（instrumentation），与本文的 agent harness 不同义。

## A2. 厂商一手实践

| 来源 | 日期 | 可借鉴的具体做法 |
|---|---|---|
| Anthropic《Building effective agents》 | 2024-12-19 | workflows（预定义代码路径）vs agents（模型自主编排）的二分；**ACI 投入等同 HCI**；SWE-bench 上「花在优化工具上的时间比整体 prompt 还多」；把相对路径改**强制绝对路径**后模型使用 flawless |
| Anthropic《Writing tools for agents》 | 2025-09-11 | 工具是「确定性系统与非确定性 agent 之间的契约」；**先造评测任务再改工具**；**依赖 held-out 测试集避免对训练评测过拟合**；Claude Code 默认工具响应上限 **25,000 tokens**；`response_format: concise|detailed` 在 Slack 场景省约 **2/3 token**；命名空间前缀 vs 后缀对评测有非平凡影响 |
| Anthropic《Effective context engineering》 | 2025-09-29 | context 是「有限资源且边际收益递减」（attention budget / context rot）；system prompt 要在 right altitude；长任务三件套 compaction / structured note-taking / sub-agent |
| Anthropic《Effective harnesses for long-running agents》 | 2025-11-26 | 长任务 agent 的 **4 类失败模式**：①一次性做完留半成品 ②提前宣布完成 ③未充分测试即标通过 ④不知道怎么启动环境；对策含 initializer 写 `init.sh` + 进度文件 + 首个 commit；`feature_list.json` 用 **JSON 而非 Markdown**（模型更不容易误改）；对测试用强措辞「It is unacceptable to remove or edit tests」；代码 `anthropics/claude-quickstarts/autonomous-coding` |
| Anthropic《Harness design for long-running apps》 | 2026-03-24 | GAN 启发的 **planner / generator / evaluator** 三角色；主观质量拆成 4 条可评分标准并给 evaluator 做 few-shot 校准；**sprint contract**（写码前先谈成「done 的定义」）；成本对照 solo 20min/$9 vs full harness 6h/$200，V2 3h50m/$124.70（build 占绝大部分）；关键判断「**Claude 是糟糕的 QA agent……会说服自己那没什么大不了并批准工作**」 |
| Anthropic Claude Code plugin eval | v2.1.269+ | 把 skill/hook/agent 定义当**被测物**：默认 **3 runs × 2 arms（with/without plugin）**，输出 `WITH / W/OUT / Δ`；`--threshold` 决定 CI 退出码；**必须 pin `--model` 与 `--judge-model`**（避免把模型 rollout 误判为 plugin 回归）；`--max-cost-usd` 熔断；「**There are no custom-code graders**」；case 定义对被测 agent **不可读**；fresh home/cwd、不加载 `CLAUDE.md`；MCP mock + agent-mock 录制回放；结果 `aggregate-result.json`（`schemaVersion: 1`） |
| Anthropic Claude Code OTel | 持续更新 | metrics/events/(beta) traces 三路；span 层级 `claude_code.interaction → llm_request / tool → tool.blocked_on_user / tool.execution`；`llm_request` 带 `ttft_ms`、`first_content_ms`、`cache_read/creation_tokens`、`attempt`、`error_class`；**默认脱敏**（需 `OTEL_LOG_USER_PROMPTS` / `OTEL_LOG_TOOL_DETAILS` / `OTEL_LOG_TOOL_CONTENT` 显式开启，内容上限默认 **60 KB**）；**仓库内 `.claude/settings.json` 的 OTEL 变量被忽略**（防仓库改遥测目的地）；`OTEL_*` 不传给 Bash/hooks/MCP 子进程 |
| Anthropic Claude Code sandboxing | 持续更新 | OS 级、**只覆盖 shell**（Read/Edit/Write/WebFetch/hooks/MCP/LSP 在沙箱外）；默认可写 cwd + tmp、默认读全机（含 `~/.ssh`、`~/.aws/credentials`，需显式 deny）；网络默认无直连经代理；`failIfUnavailable` 默认 **false**（平台不支持就**不沙箱**运行）；存在 `dangerouslyDisableSandbox` 逃逸口 |
| OpenAI frontier-evals / PaperBench | 2025-04 起 | 三容器：rollout（ubuntu）→ reproduction（全新第二容器）→ grading（第三容器跑 judge）；榜单一律 **#runs=3 ± std**；每篇论文带 `rubric.json` / `blacklist.txt`（禁 agent 访问原论文代码库）/ `judge.addendum.md`；**JudgeEval** 专门评测 judge 准确率；Code-Dev 变体砍掉 reproduction，judge 成本降约 **85%** |
| GitHub Copilot coding agent | — | 环境 = cloud sandbox / GHA；每 session 最长 **59 分钟**；one branch at a time、one PR per task；ruleset/branch protection 可拦；「**logs do not replace your own review and testing**」 |

## A3. 评测基准与可借鉴机制

| 基准 | 链接 | 机制要点 | 对我们的可借鉴点 |
|---|---|---|---|
| SWE-agent (ACI) | arXiv 2405.15793 | 为 LM 设计专用命令集与反馈格式，编辑时自动 lint、禁止空编辑 | **harness 差异 ≈ 分数差异**；ACI 应版本化为一等公民 |
| Agentless | arXiv 2407.01489 | 固定三阶段 pipeline，不让 LLM 决定下一步 | **非 agent 基线必须纳入**，否则无法归因「模型强还是 scaffold 强」 |
| OpenHands | arXiv 2407.16741 | 统一 sandbox runtime + AgentHub + 内置 benchmark 复现 | 沙箱与 agent 解耦 |
| SWE-smith | arXiv 2504.21798 | 对任意 Python 仓自动注入 bug，50k 实例 / 128 仓 | **任务合成流水线**可复用为 capability 用例工厂 |
| SWE-rebench | arXiv 2505.20411 | 持续挖掘新 issue-PR 对，滚动更新以对抗污染 | 对抗「测试集进训练集」的运维式方案 |
| Terminal-Bench 2.0 | arXiv 2601.11868 / tbench.ai | 每任务唯一容器 + 人写解 + 完整测试；89 任务 | 「任务 = 环境镜像 + 测试」的最小可复现单元 |
| τ-bench / τ²-bench | arXiv 2406.12045 / 2506.07982 | 模拟用户 + 领域 API + policy；判**最终 DB 状态**；提出 `pass^k` | **状态型 oracle**（比对世界状态而非输出文本）+ 一致性指标 |
| AgentBench | arXiv 2308.03688 | 8 环境、Docker 隔离 worker、加权归一总分 | **失败原因分类学**（CLE/IF/IA/TLE）可直接进观测层 |
| GAIA | arXiv 2311.12983 | 450+ 题；dev 公开、**test 答案私有**；quasi-exact-match | **私有答案 + 公开 scorer** 的分离范式 |
| BFCL | gorilla blog | AST 匹配 + 真实执行双轨；报 cost & latency | 机械 oracle 双轨（结构 + 执行）+ 成本口径 |
| AgentBoard | arXiv 2401.13178 | subgoal 标注 → **progress rate** 过程指标 + panel | 过程级指标字段设计的现成模板 |
| mle-bench | arXiv 2410.07095 | Kaggle 竞赛按奖牌线机械判分 | 阈值型 oracle：绝对阈值 + 相对基线双口径 |
| CORE-Bench | arXiv 2409.11363 | 复现论文结果；**同表报 accuracy 与 $ cost** | 成本必须与准确率同表报告 |
| ScienceAgentBench | arXiv 2410.05080 | rubric + 执行双层判分 | rubric 与执行 oracle 的组合判据 |
| PaperBench | arXiv 2504.01848 | 三容器 + rubric 树叶子二值 + JudgeEval | **评分器物理隔离 + 判官自身被评测** |
| RE-Bench / HCAST | arXiv 2411.15114 / 2503.17354 | 7 个 R&D 环境；189 任务带人类时间校准 | 分数按参考解归一化；人类时间作为难度标尺 |
| SWE-Lancer | arXiv 2502.12115 | 1,400+ 真实外包任务、$1M 报酬；IC SWE + Manager 两类判分 | 经济价值加权；多判分变体并存 |
| Vending-Bench | arXiv 2502.15840 | 长程经营模拟，期末净资产；>20M tokens/run；**无公开代码** | 长程一致性与成本数量级参考 |

## A4. 统计与成本口径

| 事项 | 结论 | 来源 |
|---|---|---|
| pass@k | 无偏估计 `1 - C(n-c,k)/C(n,k)`；naive `1-(1-p)^k` **有偏** | Codex 论文附录 A（arXiv 2107.03374） |
| pass^k | k 次独立试验全成功的概率（一致性），与 pass@k 互补 | τ-bench；Anthropic 2026-01-09 亦强调 pass^k 更诚实 |
| 规模起步 | **20–50 个来自真实失败的 case** 足够起步 | Anthropic《Demystifying evals》 |
| 每 trial 隔离 | 每个 trial 必须从干净环境开始；曾观测到 Claude **通过读上一次 trial 的 git 历史**获得不公平优势 | 同上 |
| 判分对象 | 「grade what the agent produced, **not the path it took**」；工具调用序列完全一致当 oracle 被明确指为 brittle | 同上 |
| grader bug 代价 | CORE-Bench 因 grader bug / 歧义从 **42% → 95%** | 同上 |
| 分数可重算 | log 为唯一事实源，`recompute_metrics` / `inspect score` 可离线重算聚合分数 | Inspect AI（`inspect_ai/log/_log.py`） |
| 成本与时延 | Anthropic solo $9 vs harness $200；LangChain 全 xhigh 反而更低（53.9%，因超时）而 reasoning sandwich 66.5%；推理预算可烧 2× tokens/time | 见 A2 |
| 不确定性 | METR 三层 hierarchical bootstrap（task family / task / attempt）；RE-Bench run 抽样 bootstrap | arXiv 2503.14499 / 2411.15114 |
| 资源预算 | 「**resource budgets are part of the measurement specification**」 | Benchmarks as Software（arXiv 2611.08417） |

## A5. 对我们的直接含义

1. 我们把「同一快照重跑必得同数」当作 P0 成功判据 —— 与 METR 的 `runs.jsonl` + DVC 复算、Inspect 的 log-as-source-of-truth 是同一种思路，**有外部范式支撑**。
2. 我们的 P0 指标公式写死的要求，与 Anthropic「先写清楚评分对象」一致；但我们**缺一个 reference solution 机制**（每 task 一个参考解同时证明可解并校准 grader）。
3. 我们的 A/B N=3 与工业默认（plugin-eval 3 runs、PaperBench #runs=3）一致；但工业界还配了 **Δ 报告 + 成本熔断 + pin 模型**，我们 ADR-0004/0005 尚未把 Δ 与成本熔断写进判据。
4. 我们的「候选用例从真实失败里挖」与 Anthropic「20–50 个真实失败起步」一致；但**每 trial 干净环境**这条我们没写进 ADR-0003 的准入条件。
