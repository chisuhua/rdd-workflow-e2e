# harness-criteria-prompt

**优先级**: P1

## Why

change-1 的判据审计（pilot-001 → 003）把 `judge_defect_rate` 从 1.0 降到 0.0，但留下**三类绑定面**写成了散文
（`scope_note`），不落地就会在真实 run 里假红：

1. **prompt 绑定面只活在散文里** ⇒ 任务 prompt 一漂移，合法解就判红（`false_negative_rate` 是唯一能惩罚
   「判据过严」的指标，但本期它是 0 次独立尝试、无信息量）；
2. **判据变更后没有强制重验** ⇒ 「改了 oracle 却不重跑变红」不可发现（ADR-0003 决策 3 第 5 条后半）；
3. **假绿防线只覆盖「每条 mutation 必红」** ⇒ 没有「哪条检查项被哪条 mutation 染红」的**归因覆盖**，
   也没有「检查项是否被充分证伪」的度量。

**诚实边界（本 change 能证明什么 / 不能证明什么）**：

- 能证明：契约**可满足**（按契约生成的解在 oracle 上全绿）· 契约与 oracle **无矛盾** · 契约与渲染出的任务 prompt
  **逐字节一致**（无漂移）· 判据变更后**强制重验**可机判 · 每条检查项**有专属的变红证据**；
- **不能**证明：判据不过严（契约是从 oracle 反推的，没有独立 ground truth）· 真实 run 不假红（需 runner + 真模型）。

## What Changes

**In Scope**:

- **结构化契约（单一真源）**：case JSON 新增 `contract` 块 —— 字段 `artifact_path` / `artifact_content` /
  `markers[]` / `forbidden_paths[]` / `allowed_write_paths[]` / `must_not_commit` / `format_contract`；另加
  `task_statement`（散文任务描述）。**`scope_note` 降级为人类导读**（只写「绑定面见 `contract` 块」），
  **不参与任何机判**。
- **oracle 检查项加稳定 `id`**：每个 check 带 `id`，`CheckResult.name` 用它；两 check 同 id ⇒ 判红。
- **任务 prompt 由契约渲染生成**：`harness/criteria/task-prompts/<case_id>.md` = `render(contract, task_statement)`；
  机判 = 「重新渲染的字节 == 仓内文件字节」（无手工编辑漂移）。
- **`task_statement` 审计**：散文里出现的每条路径 / 反引号字面量必须在 `contract` 里有对应项；出现契约外的
  路径或字面串 ⇒ 判红（防「prompt 里偷偷加约束」）。
- **契约可满足性检查**（不是「solver 生成器」）：从 `contract` 机械生成一个解，三条 case 上必须全绿；
  **该生成解不计入 `false_negative_rate` 分母**（脚本化解 ≠ 独立 solver 尝试，pilot-003 口径）。
- **`tier` 标注**：取 ADR-0003 决策 1 的三值 `{contract, capability, adversarial}`；cap-001..003 本期为
  **`contract`**（capability 准入要求「统计稳定的任务」，3 条不满足）；**adversarial 本期零成员**
  （case 里的 `mutations` 是**变红演练**（断言纪律 3），**不是** adversarial 层）。
- **双哈希 + 重跑 gate 的状态模型**：按 ADR-0005 §3 实现「排序后拼接再哈希」，且 **`criteria_version`（oracle 集）
  与 `taskset_version`（用例 + fixture 集）分开**；`harness/criteria/baseline.json` 存**基线双哈希 + 上次重跑记录 +
  每条 mutation 的实际红集**；gate = 当前指纹 ≠ 基线 ⇒ 判红；**基线更新属人审动作**。
- **红集归因**：每条 mutation 声明 `expect_red[]`；`mutation_red_match_rate` = |实际红集 == expect_red| 的比例；
  `check_mutation_coverage` = 有专属 `expect_red` 的检查项 / 检查项总数。

**Out of Scope**:

- `skip_rate` + `executed/pass/fail/skip` 四元组 gate（无 runner ⇒ 无运行结果工件）；
- `oracle_mutation_catch_rate` 的**率形态**（分母仅 5、恒 1.0 ⇒ 无判别力）；
- 隔离清单同源 / manifest scope 落地 / 路径锚点化 / `masking` CLI 修复（第 4 段 `harness-isolation-samesource`）；
- 对照报告生成器（第 5 段 `harness-report`）；runner / 真模型 / 每 trial 干净环境 / 臂索引隔离手段（第 6 段）；
- 判据族 7 条存量 CS 欠账（按 pilot-001 登记处理，本轮只覆盖 cap 族 3 条）。

## Capabilities

- MUST：判据与任务 prompt 之间有**单一真源 + 渲染产物**（合法解不会因 prompt 措辞漂移而假红）。
- MUST：判据变更后**强制重验**可机判（基线双哈希 + 重跑记录；基线更新须人审）。
- MUST：每条 oracle 检查项都有**专属的变红证据**（`expect_red` + 覆盖率）。
- MUST NOT：不新增任务集分层（adversarial 零成员）· 不跑真模型 · 不引入 runner · 不声称「判据不过严」。

## Impact

- 新增 `harness/criteria/task-prompts/**`、`harness/eval/contract.py`（渲染 + 契约可满足性 + 字面串审计）、
  `harness/eval/criteria_hash.py`（双哈希）、`harness/criteria/baseline.json`；修改 `harness/criteria/cases/*.json`
  （`contract` / `task_statement` / `tier` / `expect_red` / check `id`）、`harness/criteria/oracle.py`
  （`CheckResult.id`）、`harness/eval/cases.py`（`expect_red` 求值）。
- `harness/criteria/**` 与 `harness/eval/**` 都在**安全核**内 ⇒ 落地强制人审 + 安全核扫描（ADR-0004 决策 2）。
- **不跑真模型**：契约可满足性、红集匹配、双哈希、gate 全在合成 fixture 上判。
- 判据变更 ⇒ 基线需人审更新（这是设计意图，不是成本意外）。

## Acceptance

- [ ] case JSON 有 `contract`（7 字段齐）与 `task_statement`；`scope_note` 只作人类导读（不含机判依赖）。
- [ ] 每条 oracle check 有稳定 `id`，`CheckResult.name` 用它；构造「两 check 同 id」⇒ 判红。
- [ ] `harness/criteria/task-prompts/<case_id>.md` 三条齐；**重新渲染的字节 == 仓内文件字节**（无漂移）。
- [ ] `task_statement` 审计：散文里的每条路径 / 反引号字面量都在 `contract` 里有对应项；构造「prompt 里加了一条
      契约外约束」⇒ 判红。
- [ ] 契约**可满足**：按 `contract` 机械生成的解在三条 case 上全绿；且明确 **不计入 `false_negative_rate`**。
- [ ] `tier` 三值枚举；cap-001..003 = `contract`；**adversarial 零成员**（`mutations` ≠ adversarial 层）；
      tier 选择器是纯函数（本期**不进任何 gate** —— 无消费者）。
- [ ] 双哈希分开：`criteria_version`（oracle 集）与 `taskset_version`（用例 + fixture 集）各自按 ADR-0005 §3 口径
      计算（排序后拼接再哈希），且同内容 ⇒ 同哈希、改一项 ⇒ 变。
- [ ] `harness/criteria/baseline.json` 存在（基线双哈希 + 重跑记录 + 每条 mutation 实际红集）；gate：当前指纹 ≠
      基线 ⇒ 判红；构造「改了 oracle 但没更新基线」⇒ 红；更新基线须附重跑记录（人审）。
- [ ] 每条 mutation 有 `expect_red[]`；`mutation_red_match_rate` 与 `check_mutation_coverage` 可机判；
      构造「实际红集 ≠ expect_red」⇒ 判红。
- [ ] 三处归因缺口被补：`cap-001` 的 `content_equals`、`cap-002` 的 `head_unchanged`、`cap-003` 的
      `content_contains exit=3` 各有专属变红证据；`cap-002` 的 mutation note 更正（实际四项红、HEAD 未变）。
- [ ] 审计记录补 `oracle_sha`（= 该 case 的 oracle 块内容哈希）；本轮改动的 case 有新一轮交叉审（`pilot-004`，
      `auditor ≠ author`）；测试断言「最新审计记录的 `oracle_sha` == 当前 oracle 块哈希」。
- [ ] 新 prompt 文件进入 `prompt_version` 的哈希集合（ADR-0005 §3）—— 否则任务 prompt 不进复现口径。
- [ ] 任务 prompt 不含 gold / rubric / reference solution 的路径与内容（ADR-0006 决策 3；现有
      `prompt_isolation.py` 只查角色矩阵标记，**不覆盖**这一条）。
- [ ] `harness/safety-core.sha256` 的同步口径写清：**只在 manifest 内容变化时**更新（sidecar 只哈希 manifest
      一个文件 ⇒ 不声称覆盖 `harness/eval/**` 各文件）。
- [ ] 本 change 不跑真模型（AST 扫描守卫延续）；运行前后 `~/.config/opencode` 与 `rdd-workflow` 的
      `git status` 为空。

## 推迟与 blocked（本 change 不做，逐条有出处）

| 项 | 出处 | 归属 |
|---|---|---|
| **隔离清单同源 + manifest 四 scope 落地**（`repo:` / `repo-writeonly:` / `external:` / `runtime:`）+ 路径锚点化（`repo:` 相对仓库根、`~` = runner 的 HOME 且解析时固化、外部仓 `env:` / `link:` 锚点）+ 探针断言集改派生 + **修 `masking` CLI 恒红缺陷** + 补 `harness/tests/**` 等清单条目 | ADR-0004 决策 4 / ADR-0006 §1.4（**ADR 修订已完成**：`9cc7c8e` / `20ea870` / `bd10565`） | **`harness-isolation-samesource`**（前置已满足；注意清单增补与 `parse_manifest` 白名单改动**必须同批**） |
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
