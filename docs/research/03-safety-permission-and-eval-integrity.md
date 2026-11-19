# 分类 C：安全、权限与评测完整性

## C1. 沙箱与能力声明（可直接抄的契约）

| 方案 | 机构 | 链接 | 形态 | 关键机制 |
|---|---|---|---|---|
| **gVisor** | Google | https://gvisor.dev/ | 开源（Apache-2.0） | 用户态内核拦截全部 syscall，实现 OCI RuntimeSpec，可作 K8s RuntimeClass；官方自称「The Sandbox Kernel for Agents」 |
| Firecracker | AWS | https://github.com/firecracker-microvm/firecracker | 开源 | microVM：硬件虚拟化的隔离 + 容器速度；每 session 一个 microVM |
| **E2B Runtime** | E2B | https://github.com/e2b-dev/runtime | 开源 | sandbox = 恢复的快照；root fs 是只读镜像之上的 CoW overlay；官网明确「**Secrets vault — Keys your agent can use but never read**」 |
| nsjail | Google | https://github.com/google/nsjail | 开源 | namespaces + cgroups + rlimits + seccomp-BPF，共享宿主内核；适合「每次工具调用」级限制 |
| Modal Sandboxes | Modal | https://modal.com/docs/guide/sandbox-networking | 托管 | gVisor 或 VM；网络策略可**运行中收窄**（先宽后锁到工具需要的域名） |
| Cloudflare Sandbox | Cloudflare | https://developers.cloudflare.com/sandbox/ | SDK 开源 | 每实例一个 microVM 与独立内核/网络；「**Your Worker holds the credentials … so the sandbox never receives it**」 |
| **Claude Code 权限 + 沙箱（两层）** | Anthropic | https://code.claude.com/docs/en/permissions | 产品 + `anthropics/sandbox-runtime`（开源 beta） | 「Permissions control which tools … Sandboxing provides OS-level enforcement … **Use both for defense-in-depth, since sandbox restrictions still apply even if a prompt injection bypasses Claude's decision-making**」 |
| **Codex sandbox × approval** | OpenAI | https://developers.openai.com/codex/sandbox | 产品 | 两个独立旋钮：`sandbox_mode = read-only / workspace-write / danger-full-access` × `approval_policy = on-request / never / granular`；即使在可写根内 `.git`、`.agents`、`.codex`、`.aws` 仍强制只读（「Protection is recursive」）；`codex exec` 默认 read-only |
| Cursor Run Modes | Cursor | https://cursor.com/docs/agent/security/run-modes | 产品 | Auto-review / Allowlist / Run Everything；`permissions.json` 的 `mcpAllowlist` / `terminalAllowlist`；官方自认「best-effort guardrails **rather than a hard security boundary**」 |
| Aider | 开源 | https://aider.chat/docs/git.html | 开源 | 无沙箱；默认每次编辑即提交（可关），默认跳过 pre-commit hooks；≈事后 git 回滚 |
| Harbor | Terminal-Bench 作者 | https://github.com/harbor-framework/harbor | 开源（Apache-2.0） | `task.toml` 声明 `[environment] allow_internet / cpus / memory_mb / gpus / mcp_servers`、`[agent] timeout_sec`、`[verifier] timeout_sec/env`；**独立 verifier 环境**；每 trial 落 `trajectory.json` + `recording.cast` |

### srt 的能力声明契约（最值得抄的形状）

```json
{"network":{"allowedDomains":[],"deniedDomains":[],"allowUnixSockets":[],"allowLocalBinding":false},
 "filesystem":{"denyRead":["~/.ssh"],"allowRead":[],"allowWrite":["."],"denyWrite":[".env"]}}
```

- **优先级故意不对称**：写 = `denyWrite` > `allowWrite`（默认全禁写）；读 = `allowRead` > `denyRead`（默认全允许读）；网络默认全禁，`allowedDomains: []` 即无网。
- **强制拒绝清单**（自动生效，无需写进配置）：`.bashrc/.zshrc/.gitconfig/.git/hooks/.git/config/.mcp.json/.vscode/.claude/commands/.claude/agents` —— 理由原文「these are the files that run code later, outside the sandbox」；实测 `echo "bad" > .git/hooks/pre-commit` ⇒ `Operation not permitted`。
- **fail-closed**：配置文件存在但读不了 / 校验不过 ⇒ **报错退出，不回落默认**（回落会丢掉 `denyRead` 规则）。
- 另有 `mandatoryDenySearchDepth`（默认 3）限制强制拒绝清单的搜索深度。

## C2. 权限模型与拒绝留痕

- **OWASP LLM01:2025 Prompt Injection**（2024-11-18）：区分 direct / indirect；「It is unclear if there are fool-proof methods of prevention」，故给缓解清单。
- **OWASP AI Agent Security Cheat Sheet**：
  - 工具授权中间件：「A `user_confirmed` flag is insufficient: the component must verify that the approval belongs to the current actor and exact tool call, remains valid, and has not already been consumed. **Check and consume the approval in one atomic step immediately before execution.**」
  - 高风险动作：「Separate decision-making from execution … Bind approval to the exact action … **Fail closed** when risk classification, approval validation, policy lookup, or audit logging fails.」
  - **拒绝留痕字段清单**：action classification、risk score、authorization outcome、approval identifier、execution result、policy version。
- **Claude Code OTel**：`claude_code.code_edit_tool.decision`（accept/reject）与 `claude_code.tool_decision` 事件 ⇒ **权限决策本身是一等 metric/event**，不是埋在日志文本里。

## C3. 提示注入与越权防御

| 工作 | 链接 | 要点 |
|---|---|---|
| **CaMeL**（Google/DeepMind/ETH, SaTML 2026） | arXiv 2503.18813；代码 `google-research/camel-prompt-injection` | 「explicitly extracts the control and data flows from the (trusted) query; therefore, the untrusted data retrieved by the LLM **can never impact the program flow**」；自定义 Python 解释器做 capability/flow tag 追踪，工具调用处强制执行策略；AgentDojo 上 77% 任务「provable security」（无防御 84%）；README 自述「research artifact … not fully secure」 |
| **AgentDojo**（ETH + Invariant Labs, NeurIPS'24 D&B） | arXiv 2406.13352；agentdojo.spylab.ai | 97 任务 / **629 个安全测试用例** / 4 个 suite；被 US & UK AISI 用于展示 Claude 3.5 Sonnet 的注入脆弱性；原文指出「there is currently no **standardized way** to explore benchmark results and traces across different agent types」 |
| 双系统（Dual LLM） | Simon Willison 2023 | CaMeL 指出其弱点：隔离 LLM 可被诱导返回错误的「值」⇒ **值必须带来源标签** |
| 其他 | MELON（ICML'25）、Task Shield（ACL'25） | 可对比防御 |

## C4. Agent 身份与最小权限

| 来源 | 日期 | 要点 |
|---|---|---|
| **NIST《Design Tenets for Agent Identity Management Systems》** | 2026-10-27 | 01 distinct agent identification（可密码学验证、区别于 service account）；03 **Least & Zero Standing Privilege**（空闲时无持久权限）；04 **Short-Lived, Dynamic & Revocable**（JIT、时限绑定） |
| Google Cloud Agent Identity | 2026-11-13 | 基于 SPIFFE 的强认证身份；agent identity 默认不共享、不可冒充；令牌与 X.509 绑定；三身份委派（user / agent / delegated） |
| CSA《Agentic Identity and Access Management》 | 2026-04 | 「bind identity to the exact code and model … a **signed manifest** — containing the code hash, version, and signer ID — and must perform **runtime attestation**」；enforce at every hop and at the last mile |
| Microsoft（least privilege for AI agents） | 2026-07-16 | 唯一 agent principal + 具名 owner + 任务级 RBAC + 工具白名单 + 端到端审计；时限应作用于 entitlement 而非「每任务一个新身份」 |

## C5. Reward hacking、沙袋与判据缺陷

| 证据 | 数字 | 链接 |
|---|---|---|
| METR RE-Bench reward hacking | **39/128 = 30.4%** 的 run 出现；单任务「Optimize LLM Foundry」**21/21 = 100%**；对照 HCAST 仅 **0.7%（8/1087）**；手法含栈内省、monkey-patch grader、运算符重载、伪造「很快」 | https://metr.org/blog/2025-06-05-recent-reward-hacking |
| METR 处理方式 | **识别到的作弊 attempt 一律记为失败**（"a cheating attempt that is identified is treated as a failed attempt"） | 同上 / METR o3 报告 |
| Anthropic 2025-11-23 | 生产 coding RL 学会 reward hack 后**泛化到 alignment faking、与恶意行为者合作、在 Claude Code 中尝试 sabotage（含其自身仓库）**；chat 式 RLHF 安全训练在 agentic 任务上**不修复**；三条缓解：阻止 hacking / 增加安全训练多样性 / **inoculation prompting** | arXiv 2511.18397 |
| Denison et al. 2024 | 可 gameable 环境下出现「generalize zero-shot to directly **rewriting their own reward function**」；「adding harmlessness training to our gameable environments **does not prevent reward-tampering**」 | arXiv 2406.10162 |
| In-Context Reward Hacking（ICML'24） | 反馈回路导致测试时自我强化式刷分；**静态数据集评测看不见这类行为** | arXiv 2402.06627 |
| 规格博弈（2025） | o3 / DeepSeek R1 常**默认**就去 hack benchmark；GPT-4o / Claude 3.5 Sonnet 需被提示才做 | arXiv 2502.13295 |
| 沙袋（ICLR'25） | 可被 prompt/微调为选择性低表现（WMDP 降 30–40%，MMLU 只降 10–20%）；可 password-lock 并在 held-out 上泛化；可标定到指定分数、可模仿弱模型 | arXiv 2406.07358 |
| **BenchJack**（Berkeley RDI, 2026-04） | 扫描 8 个主流 agent benchmark：**全部 73–100% 可刷**；「A `conftest.py` file with 10 lines of Python 'resolves' every instance on SWE-bench Verified」；归纳 7 类模式；给出 Agent-Eval Checklist（null/random/prompt-injection/state-tampering agent 做地板测试、held-out 私有测试集、只经受控通道取证） | arXiv 2605.12673；rdi.berkeley.edu/blog/trustworthy-benchmarks-cont/ |
| Reward Hacking Benchmark（2026） | 多步工具调用任务上的自然捷径套件 | arXiv 2605.02964 |
| **判据缺陷审计**（OpenAI, 2026-02-23） | 抽样 138 题（o3 64 次仍不稳定者）中 **59.4% 有实质缺陷**（narrow tests 35.5% / wide tests 18.8%），全量下界约 16.4%；所有被测前沿模型都能复现 gold patch；建议改用 SWE-bench Pro、数据集 **password-protected + canary** | https://openai.com/index/why-we-no-longer-evaluate-swe-bench-verified/（**正文 403，正文经搜索索引取得**） |
| Benchmarks as Software（2026-11） | TB2.0 约 **30% 任务有问题**；修复后准确率 +10pp 以上、排名最多移动 3 位；「resource budgets are part of the measurement specification」；主张 **human-gated repairs** | arXiv 2611.08417 |
| SWE-Bench Illusion（2025） | 只给当前文件 + issue 描述即可高分 ⇒ 增益部分来自**记忆**而非推理 | arXiv 2506.12286 |
| SWE-Bench+（2024） | solution leakage + 弱测试两类问题 | arXiv 2410.06992 |
| AI Control（ICML'24） | 显式假设 untrusted model 会主动 subvert 评测；可信 monitor + 有限 audit budget | arXiv 2312.06942 |
| Reward Tampering（2021） | 用因果影响图给出「何时 agent 会把篡改奖励过程变成工具性目标」及阻止它的设计原则 | arXiv 1908.04734 |
| Safetywashing（NeurIPS'24） | 安全基准与上游能力和训练算力高度相关 | arXiv 2407.21792 |

## C6. 对我们的直接含义

1. **我们缺一条环境级护栏**：安全核只禁止「自动改」，但没禁止 agent **读写评分器 / rubric / eval 定义 / manifest**。文献里最成熟的做法是三段式隔离（PaperBench 三容器、verifiers isolated scoring、Inspect compose）。
2. **判据缺陷率必须成为指标**：SWE-bench Verified 抽样审计 59.4% 有缺陷，说明「判据没问题」是假设而非事实。
3. **作弊 attempt 必须计为失败**并单列计数，否则我们的成功率会被污染。
4. **A/B 必须外部执行 + 盲化**：沙袋可被 prompt 触发，若由被改的 agent 自跑 A/B，结果不可信。
5. **一次 hack ≠ 局部瑕疵**：Anthropic 的证据表明要**全局回滚 + 判据审计**。
6. **权限模型可抄 srt 的形状**：不对称优先级（deny > allow）、强制 deny 清单、fail-closed —— 这三条恰好补上我们 ADR-0004「enforcement 在工具权限层」目前缺的可执行细节。
