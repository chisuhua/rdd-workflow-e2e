# ADR-0004: RSI 写入边界与安全核

| 字段 | 值 |
|---|---|
| Status | Proposed |
| Date | 2026-11-19 |
| Author | architect |
| 审稿报告 | `.rddf/reviews/harness-adr-review.md`（oracle + metis → critic；BLOCKER 已闭合）；**本次 scope 修订**：`.rddf/reviews/adr-manifest-scope-amendment-review.md` |
| 外部依据 | `docs/research/02-self-improvement-and-agent-evolution.md`（RSI 失败模式）、`docs/research/03-safety-permission-and-eval-integrity.md`（沙箱与隔离契约） |
| Parent | ADR-0001 |
| 关联 change | `backlog: harness-p2`（RSI 提案面）；`backlog: harness-isolation-samesource`（manifest 三 scope 的落地 + 清单增补） |
| 分期 | **P2（挂起）**：capability 正式集 ≥ 30 条（**按任务计，不按臂计**，ADR-0003 决策 6），且连续 4 周中至少 3 周有夜间报告被引用进 improvement notes 或 ADR context 后恢复 |
| AC 映射 | 暂缺（change 未立项） |
| 本次修订 | **2026-11-28**：决策 4 增补**三 scope**（`repo:` / `external:` / `runtime:`），`runtime:` **不进** hard-deny 语义（`arms/` 由「清单例外」收敛为 scope 成员）；映射规则与路径解析见 ADR-0006 §1.4；覆盖列表增补「清单与探针自身的测试」。**两档强度、触发线清单、安全核判定机制不变；Status 不变**。**2026-11-27**：白名单**澄清**一项（rdd skill 文档**表述**纳入，**不新增其他可提案面**）+ 确立**边界单一真源**（「生成面」= 决策 3 白名单穷举；「落地面」= 决策 2 的「经人审 + 安全核扫描」；**实现类路径禁入**）+ 安全核**新增三条 glob**（`rdd-workflow/skills/{rdd-planner,rdd-builder,rdd-quick}/**`、`rdd-workflow/**/_lib/**`、`harness/path-config.yaml`）。**既有语义「生成允许 / 落地强制人审」未变**；P2 恢复条件、合并 gate、安全核的判定机制均不变（指向 ADR-0007 / ADR-0008） |

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
   - prompt 的表述、示例、反例（人审须判定「是否构成等效权限/配对/gate 变更」）—— **表述类**；**可自动生成提案，落地强制人审**（决策 2）
   - **rdd skill 文档（`rdd-workflow/skills/**`）的表述** —— 2026-11-27 澄清项：现文「prompt 的表述」是否覆盖 skill 文档有二义，现**显式纳入**（**仅限「表述」**；**不含** `owns` / `not_owns` 与实现机械）；**不新增任何其他可提案面**（白名单条目集合的 diff 可验）。**表述类**；**可自动生成提案，落地强制人审**（决策 2）。两类载体的人审清单**分列**（清单条目见 ADR-0007 决策 5），且两类提案**不得合并为同一条**
   - ⚠ **边界单一真源（2026-11-27 定，供全仓引用）**：**「生成面」= 本决策 3 的白名单（穷举）**；**「落地面」= 决策 2 的规则**（安全核路径只能以 proposal 形式**经人审**合并 + 安全核扫描）。⇒ 白名单**未**显式列出的变更类型，**即使落在安全核路径内，也不得自动生成提案**；白名单**已**列出的**表述类**变更（prompt 表述 / skill 文档表述）**可以自动生成提案，但落地一律强制人审**（决策 2 —— 本次修订**未**改变这个既有语义）。⇒ 另设一条**实现类禁入**：安全核中的**实现类**路径（`_lib/**`、`harness/{metrics,criteria,eval}/**`、skill 目录下的非 `SKILL.md` 实现文件、`owns` / `not_owns` 所在的实现文件）**既不可自动生成、也不可自动落地**。ADR-0007 决策 5 的表只是**风险分类与人审清单**，**不构成新的提案面**。
   - 新增 fixture 与新增用例（只允许新增文件，不允许修改安全核清单内既有文件）
   - helper 脚本、文档
   - ADR 给定边界内的阈值参数
4. **安全核（hard-deny）**：清单化在 `harness/safety-core.manifest`（**scope + glob + 理由 + 版本**）。**隔离路径（评分器 / rubric / criteria / eval 定义）与安全核共用这一份声明**——一份 manifest、两处引用，不允许两处定义（见 ADR-0006）。

   **三个 scope（2026-11-28 增补）**：

   | scope | 语义 | 进安全核 hard-deny？ | 对 solver |
   |---|---|---|---|
   | `repo:` | 本仓的**判据资产** | ✅ 是 | 不可读 + 不可写 |
   | **`repo-writeonly:`**（2026-11-28 新增） | 本仓的**非判据**文件（回归套件 / 工具脚本 / CI 配置 / 已知失败基线） | ✅ 是 | **可读** + 不可写 |
   | `external:` | **跨仓载体**（opencode / rdd-workflow） | ✅ 是（由跨仓 gate 校） | **不主动遮蔽；实际可读性按臂配置**（ADR-0008 决策 6）+ 不可写 |
   | **`runtime:`** | **运行数据 / 隔离路径**（如 `~/.local/share/rddf-harness/arms/**`） | ❌ **否** —— 不是判据资产 | 不可读 + 不可写（ADR-0001 决策 4 的写者唯一性） |

   ⇒ **`arms/` 归 `runtime:`**：它是同一份 manifest 的**另一个 scope**，**不**是安全核条目 —— 与 2026-11-27 的「臂索引**不进安全核条目**」排除**一致**（该排除由此收敛为 **scope 划分**，不再是清单例外）。
   ⇒ **`runtime:` 成员 = ADR-0001 决策 2 的运行数据目录全集**（`snapshots/` `traces/` `runs/` `arms/` `proposals/` —— `arms/` 即其成员之一）；本 ADR 只举 `arms/**` 为例。⚠ `harness/path-config.yaml` 是**判据资产** ⇒ 归 `repo:`（ADR-0007 决策 4），**不属 `runtime:`**。⚠ `proposals/` 的「只读区」指**人审侧**读权限，**不是** solver 可读性 —— 按本表它对 solver **不可读 + 不可写**。
   ⇒ **`runtime:` 条目只登记、不做 `audit()` 布局核对**（同 `external:`）：`harness/eval/safety_core.py::audit()` 只对 `repo:` 做 glob 核对；否则「没有 `~/.local/share/rddf-harness/` 的机器」会误判红。⚠ 但 **`external:` 仍须有「空改动 patch ⇒ deny」测试**（工具层，ADR-0004 决策 2）——「校验」在这里是两个层面，别混。
   ⇒ 隔离声明的**映射规则与路径解析**见 ADR-0006 §1.4（本 ADR 只定清单格式与归属，不重复映射口径）。
   ⚠ **落地状态**：`harness/safety-core.manifest` 目前仍只有 `repo:` / `external:` 两类条目，**尚未**登记 `runtime:` 条目、**尚未**把非判据文件重归类为 `repo-writeonly:`、也**尚未**加入本决策新增的「清单与探针自身的测试」⇒ 该增补**与代码改动必须同批落地**（清单先加 `runtime:` 行会让 `harness/eval/safety_core.py::parse_manifest` 的 scope 白名单 `{repo, external}` 抛 `ValueError`，`harness/tests/test_safety_core_manifest.py` 会红），由 `harness-isolation-samesource` 承接（连带 `harness/safety-core.sha256` 同步，人审）。

   覆盖：
   - `~/.config/opencode/{opencode.jsonc, AGENTS.md, subagent-contract.json}`
   - `~/.config/opencode/prompts/**`、`lib/**`、`plugins/**`、`scripts/role-*.ts`
   - `rdd-workflow/skills/rdd-verifier/**`、gate 脚本、`.rddf/state` schema
   - **`rdd-workflow/skills/{rdd-planner,rdd-builder,rdd-quick}/**`**（2026-11-27 新增：叠加层的**工件归属与阶段契约**载体；改其 `owns` / `not_owns` ≈ 改 single writer 声明 ⇒ 归为等效权限风险）
   - **`rdd-workflow/**/_lib/**`**（2026-11-27 新增：**顶层 `_lib/**` 与 `skills/_lib/**` 都要覆盖** —— 后者含 `cross_repo_gate.py` / `state.sh` / `state_reader.py` / `cleanup_plan_handoff.py` / `orchestrator_entry.sh` / `post_flow_wrap.sh` 等**运行时 gate / handoff 机械**，且上游 `install.sh:155-165` 正是从 `skills/_lib/` 拷进已安装 `_lib` ⇒ 只列顶层会留下「白名单里 `rdd-workflow/skills/**` 的表述」可被解读为允许对 `skills/_lib` 自动提案的**缺口**）。改 handoff / gate 的实现机械与改 `owns` 同为等效工件归属变更 ⇒ 必须同列硬拒。
   - `tests/**`、`KNOWN_FAILURES.txt`、`scripts/report_regression.sh`、`.github/workflows/**`（**路径基准 = 仓库根**，与 §1.4 的 `repo:` 口径一致）
   - **判据自身**：`harness/metrics/**`（指标定义与行粒度，ADR-0005 声明其为安全核）、`harness/trace.py`（unit 推导口径与 trace 字段表，ADR-0002 决策 1/3 —— 2026-11-28 补登，与单文件 `metrics.py` 同列）、`harness/criteria/**`（oracle 定义）、`harness/eval/**`（评测定义与 rubric）、`harness/safety-core.manifest`、`harness/safety-core.sha256`
   - **期望归属声明**：`harness/path-config.yaml`（2026-11-27 新增：阶段归属声明 = 判据资产，ADR-0007 决策 4）
   - ⚠ **臂索引 `arms/` 不进安全核（hard-deny）条目，但作为 `runtime:` 条目登记在同一份 manifest**：它是 runner 产出的运行数据，不是判据资产 ⇒ 写者唯一性见 ADR-0001 决策 4；对 solver 的不可读 / 不可写由 ADR-0006 §1.4 的 `runtime:` 派生规则给出
   - ⚠ **清单落地时必须核对 glob 与实际布局**（2026-11-27 发现）：现文的 `harness/metrics/**` 在当前布局下**匹配不到** `harness/metrics.py`（指标定义是**单文件**，`harness/` 下为 `manifest.py` / `metrics.py` / `run.py` / `snapshot.py`）⇒ 落地 `safety-core.manifest` 时必须逐条核对，否则安全核会**漏掉指标定义文件**（与 ADR-0005「指标定义属安全核」相悖）。
   - **判据的判据**：`docs/runtime-assertion-discipline.md`（ADR-0003 指定为唯一口径）、`docs/adr/**`
   - **清单与探针自身的测试**（2026-11-28 增补）：`harness/tests/**`（安全核清单核对的回归测试 + 遮蔽探针断言的回归测试）、`harness/manifest.py`（eval manifest 构造器）—— **改它们 = 改判据的判据**。⚠ 本条是**清单内容的增补要求**，由 `harness-isolation-samesource` 落地（连带 `harness/safety-core.sha256` 同步，人审）
   - manifest 自身：哈希固定在 `harness/safety-core.sha256`（受版本控制），夜间与 CI 都校验该文件；改动它需人审 PR。
   - prompt 内机读块（`<!-- capability:` / `<!-- role-class-write-set:`）：任一非空改动 ⇒ 自动归为等效权限变更，逐行人审。⚠「**自动**归为」指**人审流程内的自动分类**，**不是**「自动生成提案」。
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

- [ ] `safety-core.manifest` 中 **`repo:` / `external:`** 每条 glob 均有一个「空改动 patch ⇒ deny」测试（`runtime:` 条目**不在此列** —— 它们是运行数据，只登记不校验；见下条）。
- [ ] 每条条目带合法 scope（`repo` / `repo-writeonly` / `external` / `runtime`）；`runtime:` 条目**不进入** hard-deny 语义（构造「runtime 条目被当作安全核」的样例 ⇒ 判红）。
- [ ] **`repo:` 与 `repo-writeonly:` 的归类可对账**：构造「判据资产被标成 `repo-writeonly:`」与「非判据文件被标成 `repo:`」两种样例 ⇒ 均判红（归类靠**理由字段 + 本 ADR 的覆盖列表**双向核对）。
- [ ] RSI 进程尝试写清单外路径时，工具层拒绝并留痕（不是仅告警）。
- [ ] 任一 proposal 的 patch 触碰安全核时，合并流程自动终止。
- [ ] 每个合并的 proposal 都有 A/B 结果、回滚命令与一次真实 revert 演练记录。
- [ ] 提案生成者与审批者不同（记录在 proposal 元数据中）。
- [ ] 连续 3 轮无提升时流程自动停止（脚本模拟）。
- [ ] prompt 类提案包含「是否构成等效权限变更」的判定结果。
- [ ] 删除 P2 恢复条件中的任一项时，流程拒绝启动。
