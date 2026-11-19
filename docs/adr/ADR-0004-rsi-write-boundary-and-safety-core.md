# ADR-0004: RSI 写入边界与安全核

| 字段 | 值 |
|---|---|
| Status | Proposed |
| Date | 2026-11-19 |
| Author | architect |
| 审稿报告 | `.rddf/reviews/harness-adr-review.md`（oracle + metis → critic；BLOCKER 已闭合） |
| 外部依据 | `docs/research/02-self-improvement-and-agent-evolution.md`（RSI 失败模式）、`docs/research/03-safety-permission-and-eval-integrity.md`（沙箱与隔离契约） |
| Parent | ADR-0001 |
| 关联 change | `backlog: harness-p2` |
| 分期 | **P2（挂起）**：capability 正式集 ≥ 30 条，且连续 4 周中至少 3 周有夜间报告被引用进 improvement notes 或 ADR context 后恢复 |
| AC 映射 | 暂缺（change 未立项） |

## 背景与问题

「让 agent 改进 agent」最大的风险不是能力不足，而是**判据自指**与**自我放行**：

- 本仓已发生过假绿：断言与模型叙述自命中；fixture 初始失败导致「确实失败」恒真。
- 若 RSI 能修改判据、权限或 gate，它可以把「不许做」改成「可以做」，且没有测试会发现。
- 本系统的行为主要由**规则文本**约束 ⇒ 改 prompt 在语义上可能等效于改权限（例如「你现在可以直接写 X」），路径扫描对此不可见。

## 决策

1. **RSI 只产出候选，不直接落盘**：`proposals/<id>.patch` + `<id>.md`（改什么、为什么、预期指标、回滚命令）。
2. **enforcement 在工具权限层**：RSI 进程的运行写集被限制为 `proposals/`；安全核扫描失败即拒绝合并并留痕，不依赖提案者自觉。
   - **白名单 ≠ 可写**：白名单只定义「允许生成哪类提案」；任何安全核路径的落地只能以 proposal 形式经人审合并。
3. **白名单（可自动提案，仍需人审合并）**：
   - prompt 的表述、示例、反例（人审须判定「是否构成等效权限/配对/gate 变更」）
   - 新增 fixture 与新增用例（只允许新增文件，不允许修改安全核清单内既有文件）
   - helper 脚本、文档
   - ADR 给定边界内的阈值参数
4. **安全核（hard-deny）**：清单化在 `harness/safety-core.manifest`（glob + 理由 + 版本）。**隔离路径（评分器 / rubric / criteria / eval 定义）与安全核共用这一份声明**——一份 manifest、两处引用，不允许两处定义（见 ADR-0006）。覆盖：
   - `~/.config/opencode/{opencode.jsonc, AGENTS.md, subagent-contract.json}`
   - `~/.config/opencode/prompts/**`、`lib/**`、`plugins/**`、`scripts/role-*.ts`
   - `rdd-workflow/skills/rdd-verifier/**`、gate 脚本、`.rddf/state` schema
   - `rdd-workflow-e2e/tests/**`、`KNOWN_FAILURES.txt`、`scripts/report_regression.sh`、`.github/workflows/**`
   - **判据自身**：`rdd-workflow-e2e/harness/metrics/**`（指标定义与行粒度，ADR-0005 声明其为安全核）、`harness/criteria/**`（oracle 定义）、`harness/eval/**`（评测定义与 rubric）、`harness/safety-core.manifest`、`harness/safety-core.sha256`
   - **判据的判据**：`docs/runtime-assertion-discipline.md`（ADR-0003 指定为唯一口径）、`docs/adr/**`
   - manifest 自身：哈希固定在 `harness/safety-core.sha256`（受版本控制），夜间与 CI 都校验该文件；改动它需人审 PR。
   - prompt 内机读块（`<!-- capability:` / `<!-- role-class-write-set:`）：任一非空改动 ⇒ 自动归为等效权限变更，逐行人审。
5. **合并前置条件**（缺一不可）：
   - **A/B 结论只作方向性**：capability 集规模 × N 的分辨率 **> 5pp 期间**（尚不能分辨 5pp 时），Δ 不得作为合并依据；数值与阈值以 ADR-0005 §4 为唯一真源；
   - contract 层 0 新增失败，skip 数不超过基线；
   - **判据审计已完成**（新增 case 100% 审计、`auditor ≠ author`）；
   - 安全核扫描通过（对清单每条 glob 造空改动 patch ⇒ 必须 deny）；
   - 人审通过（见第 7 条）；
   - **回滚三元组已记录**：patch + `criteria_version` + `taskset_version`，且至少演练一次 `revert` 后重跑 held-out。
6. **单变量原则**：一次提案只改一个变量；连续 3 轮无提升即停，交人。
7. **人审主体**：由非提案生成者执行（提案 agent 不得自审）；检查清单固定为三问「是否在白名单 / 是否构成等效权限变更 / A/B 是否成立」，每类 proposal 设定人工分钟数上限。
8. **禁止**：RSI 修改准入判据、mutation 判据、删除或跳过测试、放宽已知失败基线、修改自身 manifest。

## 选项对比

| 选项 | 结论 | 理由 |
|---|---|---|
| A. 通用 RSI 自主改并自动合并 | 否 | 判据自指 + 自我放行；事故不可检测 |
| B. 限域 RSI（白名单）+ 人审合并 | **选中** | 保留收益，保留否决点；可回滚 |
| C. 完全不做 RSI | 否 | 放弃数据与评测基础 |
| D. 只允许人改，不生成候选 | 否（**保留 revisit**） | 当前数据饥饿下人改运转正常；capability 集 ≥30 条后重估，若自动候选接受率低则回退到 D |

## 后果 / 代价

**正面**

- 安全核与改进面分离，事故半径可控。
- 候选 patch 可审计（说明 + A/B 证据 + 回滚点）。
- 单变量与原提案隔离降低归因难度。

**负面**

- 人审仍是瓶颈；数据饥饿时候选价值低。
- 白名单边界需持续维护。
- P2 挂起意味着短期没有自动改进能力。

**风险**

- 人审疲劳 ⇒ 安全核扫描自动化 + 每类分钟数上限。
- prompt 类提案的语义绕过 ⇒ 必须有「等效权限变更」判据与人工复核。
- 统计功效不足 ⇒ 明确区分「方向性」与「可合并」。

## Verification

- [ ] `safety-core.manifest` 每条 glob 均有一个「空改动 patch ⇒ deny」测试。
- [ ] RSI 进程尝试写清单外路径时，工具层拒绝并留痕（不是仅告警）。
- [ ] 任一 proposal 的 patch 触碰安全核时，合并流程自动终止。
- [ ] 每个合并的 proposal 都有 A/B 结果、回滚命令与一次真实 revert 演练记录。
- [ ] 提案生成者与审批者不同（记录在 proposal 元数据中）。
- [ ] 连续 3 轮无提升时流程自动停止（脚本模拟）。
- [ ] prompt 类提案包含「是否构成等效权限变更」的判定结果。
- [ ] 删除 P2 恢复条件中的任一项时，流程拒绝启动。
