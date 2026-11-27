---
优先级: P1
来源: "ADR-0003（用例准入 / 四元组 gate / 审计记录字段）/ ADR-0005 §3（双哈希口径）/ ADR-0006 §1（gold 路径不入 prompt）+ change-1 的判据审计残留"
阶段: phase-2
分类: harness
类型: feature
---

**优先级**: P1 | **来源**: ADR-0003 / ADR-0005 §3 / ADR-0006 §1，change-1 判据审计残留
**阶段**: phase-2 | **分类**: harness | **类型**: feature

## Why

change-1 的判据审计（pilot-001 → 003）把 `judge_defect_rate` 从 1.0 降到 0.0，但留下**三类绑定面**
写成了散文（`scope_note`），不落地就会在真实 run 里假红：

1. **prompt 绑定面只活在散文里** ⇒ 任务 prompt 一漂移，合法解就判红（`false_negative_rate` 是唯一能
   惩罚「判据过严」的指标，但本期它是 0 次独立尝试、无信息量）；
2. **判据变更后没有强制重验** ⇒ 「改了 oracle 却不重跑变红」不可发现（ADR-0003 决策 3 第 5 条后半）；
3. **假绿防线只覆盖「每条 mutation 必红」** ⇒ 没有「哪条检查项被哪条 mutation 染红」的**归因覆盖**，
   也没有「检查项是否被充分证伪」的度量。

**诚实边界（本 change 能证明什么 / 不能证明什么）**：

- 能证明：契约**可满足**（按契约生成的解在 oracle 上全绿）· 契约与 oracle **无矛盾** · 契约与渲染出的
  任务 prompt **逐字节一致**（无漂移）· 判据变更后**强制重验**可机判 · 每条检查项**有专属的变红证据**；
- **不能**证明：判据不过严（契约是从 oracle 反推的，没有独立 ground truth）· 真实 run 不假红（需 runner + 真模型）。

## What Changes

- **结构化契约（单一真源）**：case JSON 新增 `contract` 块 —— 字段 `artifact_path` / `artifact_content` /
  `markers[]` / `forbidden_paths[]` / `allowed_write_paths[]` / `must_not_commit` / `format_contract`；
  另加 `task_statement`（散文任务描述）。**`scope_note` 降级为人类导读**（只写「绑定面见 `contract` 块」），
  **不参与任何机判**。
- **oracle 检查项加稳定 `id`**：每个 check 带 `id`，`CheckResult.name` 用它；两 check 同 id ⇒ 判红。
- **任务 prompt 由契约渲染生成**：`harness/criteria/task-prompts/<case_id>.md` = `render(contract, task_statement)`；
  机判 = 「重新渲染的字节 == 仓内文件字节」（无手工编辑漂移）。
- **`task_statement` 审计**：散文里出现的每条路径 / 反引号字面量必须在 `contract` 里有对应项；
  出现契约外的路径或字面串 ⇒ 判红（防「prompt 里偷偷加约束」）。
- **契约可满足性检查**（不是「solver 生成器」）：从 `contract` 机械生成一个解，三条 case 上必须全绿；
  **该生成解不计入 `false_negative_rate` 分母**（脚本化解 ≠ 独立 solver 尝试，pilot-003 口径）。
- **`tier` 标注**：取 ADR-0003 决策 1 的三值 `{contract, capability, adversarial}`；cap-001..003 标本期
  为 **`contract`**（capability 准入要求「统计稳定的任务」，3 条不满足）；**adversarial 本期零成员**
  （case 里的 `mutations` 是**变红演练**（断言纪律 3），**不是** adversarial 层）。
- **双哈希 + 重跑 gate 的状态模型**：按 ADR-0005 §3 实现「排序后拼接再哈希」，且 **`criteria_version`
  （oracle 集）与 `taskset_version`（用例 + fixture 集）分开**；`harness/criteria/baseline.json` 存
  **基线双哈希 + 上次重跑记录 + 每条 mutation 的实际红集**；gate = 当前指纹 ≠ 基线 ⇒ 判红；
  **基线更新属人审动作**（文件在 `harness/criteria/**` ⇒ 已在安全核 manifest 覆盖内）。
- **红集归因**：每条 mutation 声明 `expect_red[]`；`mutation_red_match_rate` = |实际红集 == expect_red| 的比例；
  `check_mutation_coverage` = 有专属 `expect_red` 的检查项 / 检查项总数。

## Acceptance

- [ ] case JSON 有 `contract`（7 字段齐）与 `task_statement`；`scope_note` 只作人类导读（不含机判依赖）。
- [ ] 每条 oracle check 有稳定 `id`，`CheckResult.name` 用它；构造「两 check 同 id」⇒ 判红。
- [ ] `harness/criteria/task-prompts/<case_id>.md` 三条齐；**重新渲染的字节 == 仓内文件字节**（无漂移）。
- [ ] `task_statement` 审计：散文里的每条路径 / 反引号字面量都在 `contract` 里有对应项；
      构造「prompt 里加了一条契约外约束」⇒ 判红。
- [ ] 契约**可满足**：按 `contract` 机械生成的解在三条 case 上全绿；且明确 **不计入 `false_negative_rate`**。
- [ ] `tier` 三值枚举；cap-001..003 = `contract`；**adversarial 零成员**（`mutations` ≠ adversarial 层）；
      tier 选择器是纯函数（本期**不进任何 gate** —— 无消费者）。
- [ ] 双哈希分开：`criteria_version`（oracle 集）与 `taskset_version`（用例 + fixture 集）各自按
      ADR-0005 §3 口径计算（排序后拼接再哈希），且同内容 ⇒ 同哈希、改一项 ⇒ 变。
- [ ] `harness/criteria/baseline.json` 存在（基线双哈希 + 重跑记录 + 每条 mutation 实际红集）；
      gate：当前指纹 ≠ 基线 ⇒ 判红；构造「改了 oracle 但没更新基线」⇒ 红；更新基线须附重跑记录（人审）。
- [ ] 每条 mutation 有 `expect_red[]`；`mutation_red_match_rate` 与 `check_mutation_coverage` 可机判；
      构造「实际红集 ≠ expect_red」⇒ 判红。
- [ ] 三处归因缺口被补：`cap-001` 的 `content_equals`、`cap-002` 的 `head_unchanged`、`cap-003` 的
      `content_contains exit=3` 各有专属变红证据；`cap-002` 的 mutation note 更正（实际四项红、HEAD 未变）。
- [ ] 审计记录补 `oracle_sha`（= 该 case 的 oracle 块内容哈希）；本轮改动的 case 有新一轮交叉审
      （`pilot-004`，`auditor ≠ author`）；测试断言「最新审计记录的 `oracle_sha` == 当前 oracle 块哈希」。
- [ ] 新 prompt 文件进入 `prompt_version` 的哈希集合（ADR-0005 §3）—— 否则任务 prompt 不进复现口径。
- [ ] 任务 prompt 不含 gold / rubric / reference solution 的路径与内容（ADR-0006 决策 3；现有
      `prompt_isolation.py` 只查角色矩阵标记，**不覆盖**这一条）。
- [ ] `harness/safety-core.sha256` 的同步口径写清：**只在 manifest 内容变化时**更新（sidecar 只哈希
      manifest 一个文件 ⇒ 不声称覆盖 `harness/eval/**` 各文件）。
- [ ] 本 change 不跑真模型（AST 扫描守卫延续）；运行前后 `~/.config/opencode` 与 `rdd-workflow` 的
      `git status` 为空。

## Capabilities

- MUST：判据与任务 prompt 之间有**单一真源 + 渲染产物**（合法解不会因 prompt 措辞漂移而假红）。
- MUST：判据变更后**强制重验**可机判（基线双哈希 + 重跑记录；基线更新须人审）。
- MUST：每条 oracle 检查项都有**专属的变红证据**（`expect_red` + 覆盖率）。
- MUST NOT：不新增任务集分层（adversarial 零成员）· 不跑真模型 · 不引入 runner · 不声称「判据不过严」。

## Impact

- 新增 `harness/criteria/task-prompts/**`、`harness/eval/contract.py`（渲染 + 三方缩减为「渲染一致性 + 契约可满足性 + 字面串审计」）、`harness/eval/criteria_hash.py`（双哈希）、`harness/criteria/baseline.json`；
  修改 `harness/criteria/cases/*.json`（`contract` / `task_statement` / `tier` / `expect_red` / check `id`）、
  `harness/criteria/oracle.py`（`CheckResult.id`）、`harness/eval/cases.py`（`expect_red` 求值）。
- `harness/criteria/**` 与 `harness/eval/**` 都在**安全核**内 ⇒ 落地强制人审 + 安全核扫描（ADR-0004 决策 2）。
- **不跑真模型**：契约可满足性、红集匹配、双哈希、gate 全在合成 fixture 上判。
- 判据变更 ⇒ 基线需人审更新（这是设计意图，不是成本意外）。

## 推迟与 blocked（本 change 不做，逐条有出处）

| 项 | 出处 | 归属 |
|---|---|---|
| **隔离清单与安全核清单同源**（ADR-0006 §1.4：现两处定义）+ manifest 第三 scope（承载 `~/.local/share/rddf-harness/arms/**`）+ 路径锚点化（`repo:`/`home:` 运行时解析，兼容 worktree）+ **修 `masking` CLI 恒红缺陷**（`_cmd_masking` 从不填 `unreadable_paths` ⇒ 恒返回 1） | ADR-0006 §1.4 / ADR-0004 决策 4 | **`harness-isolation-samesource`**（前置：**architect 先修订 ADR-0006 §1.4 / ADR-0004 决策 4 的 manifest scope 与映射规则**） |
| `skip_rate` + `executed/pass/fail/skip` 四元组 gate | ADR-0003 决策 8 / ADR-0005 §1 | `harness-dual-path-run`（需 runner 产出运行结果 + skip 基线工件 + CI python 步骤） |
| `oracle_mutation_catch_rate` 的**率形态**（分母足够大的候选评估口径 + 阈值数值） | ADR-0005 §2 / §5 | `harness-p2` 候选评估（本期只交付「红集匹配 + 覆盖率」两项可判别指标） |
| ADR-0003 决策 3 ⑦ 的**运行面**（solver 读不到 case 定义的运行时探针） | ADR-0003 决策 3 / ADR-0006 §5 | `harness-dual-path-run`（memo 硬门 (i)） |
| 每 trial 干净环境（`.rddf/state/**` + 四类遮蔽对象按臂条件化） | ADR-0003 决策 3 / ADR-0008 决策 6 | `harness-dual-path-run`（memo 硬门 (ii)） |
| 臂索引对 solver 不可读 + 不可写的**隔离手段** | ADR-0001 决策 4 / ADR-0006 §5 | `harness-dual-path-run`（memo 硬门 (i)） |
| 报告结构断言（四类翻转数 / `excluded_*` / 分母分列 / 无总分章节） | ADR-0007 / ADR-0008 | `harness-report` |
| 跨仓运行时 trace（`traces/delegate-*.jsonl` + outcome 字段组） | ADR-0002 决策 4 | `~/.config/opencode`（需单独获批） |
| CI 增加 python 单测步骤（当前 CI 只跑 bats ⇒ 本 change 的 AC 只本地可验） | 架构文档 §8 | 需安全核人审（`.github/workflows/**` 在安全核内） |
| **判据族的 7 条存量 CS 欠账**（缺插件加载探针 / `jsonschema` 缺失即跳过校验 / 判据读已安装副本） | pilot-001 登记 | **本轮只覆盖 cap 族 3 条**；7 条按 pilot-001 处理 |
| 命名 `cap-` 与元数据 `task_orchestration_intrinsic` 暗示 capability 层，而按准入它们只能是 contract | ADR-0003 决策 1/3 | **已知口径债**（architect 决定是否改名 / 改元数据） |

## 拆分后的 change 序列（phase-2 = P1；本文件 = 第 3 段）

| # | change | 范围 | 前置 | 状态 |
|---|---|---|---|---|
| 1 | `harness-p1` | 双路径对照就绪资产 | — | ✅ 已归档（17/17 AC） |
| 2 | `harness-trace` | unit trace 投影 | 1 | ✅ 已归档（14/14 AC） |
| 3 | **`harness-criteria-prompt`**（本文件） | 判据契约链（contract 真源 + prompt 渲染 + tier + 双哈希 + 重跑 gate + 红集归因 + 审计 `oracle_sha`） | 1 | 立项中 |
| 4 | `harness-isolation-samesource` | 隔离清单同源 + manifest 第三 scope + 路径锚点化 + `masking` CLI 修复 | **ADR-0006 §1.4 / ADR-0004 修订**（architect） | 待立项（**被 ADR 前置阻塞**） |
| 5 | `harness-report` | 对照报告生成器 + 输入 fixture schema | 3 | 待立项 |
| 6 | `harness-dual-path-run` | 对照 run + runner + 轻量档隔离 + memo 硬门 (i)(ii) + 四元组 gate | 3/4/5 + **真模型预算** | 待立项 |

## metis 结论（1 轮；P0 10 条 / P1 7 条，全部处置如下）

| metis 意见 | 处置 |
|---|---|
| P0-1 拆 change（隔离同源与绝对路径与前 5 块零耦合；ADR-0004 决策 2 要求安全核改动人审，一次背两件不相干的事） | ✅ 采纳 ⇒ 拆出 `harness-isolation-samesource`（第 4 段，**被 ADR 修订前置阻塞**） |
| P0-2 契约改「单真源 + 渲染」，删「三方一致」；oracle check 加稳定 id；`scope_note` 降级为人类导读 | ✅ 采纳（`scope_note` 不参与机判；机判改为「渲染字节一致 + 契约可满足性 + 字面串审计」） |
| P0-3 conformant solver 是自证循环 ⇒ 降级为「契约可满足性检查」，不计入 `false_negative_rate`，并写明诚实边界 | ✅ 采纳（并入 `contract.py` 一个函数，不建独立 solver 模块；Why 段写明「不能证明判据不过严」） |
| P0-4 `oracle_mutation_catch_rate` 分母 5、恒 1.0 ⇒ 换成 `mutation_red_match_rate` + `check_mutation_coverage`；删 0.5 阈值；修 cap-002 note | ✅ 采纳（率形态推迟到 P2 候选评估） |
| P0-5 `skip_rate` + 四元组 gate 在无 runner 下是空话 ⇒ 整条推迟 | ✅ 采纳（进推迟表 → `harness-dual-path-run`） |
| P0-6 重跑 gate 缺状态模型；`criteria_version` 与 `taskset_version` 被混用 | ✅ 采纳（`baseline.json` 三件套 + 双哈希分开 + 基线更新人审） |
| P0-7 隔离块的三个洞（manifest 无 arms scope / 派生把 W2 打死 / `masking` CLI 恒红） | ✅ 采纳 ⇒ 随 P0-1 拆走，并在推迟表写明修法要点与前置 |
| P0-8 `tier` 用 ADR 三值；`mutations` ≠ adversarial 层；命名口径债 | ✅ 采纳（adversarial 零成员；`cap-` 命名与 `task_orchestration_intrinsic` 登记为已知口径债） |
| P0-9 审计记录缺 `oracle_sha`；改 oracle 后审计脱钩 | ✅ 采纳（AC 含 `oracle_sha` + `pilot-004` + 一致性断言） |
| P0-10 sha256 AC 恒真（sidecar 只哈希 manifest 一个文件） | ✅ 采纳（改成「只在 manifest 变化时同步」；「覆盖整棵安全核树」进推迟表） |
| P1-1 目录命名与 `harness/eval/prompts/` 同名不同义 | ✅ 采纳 ⇒ 用 `harness/criteria/task-prompts/`，README 写清区别 |
| P1-2 prompt 泄露检查（gold / rubric / reference 路径） | ✅ 采纳（新增 AC；明确现有 `prompt_isolation.py` 不覆盖） |
| P1-3 新 prompt 进 `prompt_version` 哈希集合 | ✅ 采纳 |
| P1-4 推迟表补齐（5 项） | ✅ 采纳 |
| P1-5 Why 段补诚实边界 | ✅ 采纳 |
| P1-6 `cap-002` mutation note 更正 | ✅ 采纳（实际四项红、HEAD 未变） |
| P1-7 重跑记录原子写 | ✅ 采纳（临时文件 + 原子替换，AC 里写明；不照抄 `manifest.write` 的简单写法） |
| P2-1/2/3/4（检查项归因唯一 / 真实可达性探针 / 契约自动生成 / tier 选择器消费者） | ⏸ 记入本文件的已知边界，不在本 change |
