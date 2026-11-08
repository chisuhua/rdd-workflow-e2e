# 跨仓缺口归属表（只记录，不改 opencode 仓）

| 字段 | 值 |
|---|---|
| 日期 | 2026-11-06 |
| 范围 | front+delegate 自动化测试体系落地时，**opencode 仓**（`~/.config/opencode`）尚未覆盖的 7 项缺口 + 探针期间实测新发现 2 项（第 8、9 条） |
| 用户拍板 | 跨仓缺口**只在本仓记录，不动 opencode 仓** |
| 配套文档 | [real-runtime-prereqs.md](./real-runtime-prereqs.md)（L2 落地的前置探针结论 + L2 实跑结果） |

## 术语约定

| 层 | 位置 | 依赖真实 opencode 运行时？ | session id 来源 |
|---|---|---|---|
| **L1 单元层** | `~/.config/opencode` 的 `bun test tests/`（63 项） | ❌ 假 ctx | 假字符串 |
| **L2 运行时层** | 真实 `opencode run --agent front`（本轮落地用例集：`tests/integration/test_front_delegate_runtime.bats`，**14 条**，默认全 skip；2026-11-08 由 8 条扩到 14 条） | ✅ | **真实 id**（探针 P1 结论 + L2 实跑证实） |
| **L3 跨阶段 E2E 层** | 本仓 bats 套件（`tests/integration/` + `tests/_lib/`，48 例 + 8 条 L2） | ❌ 但真 subprocess / 真文件契约 | 假字符串（`OWNER_A` / `OWNER_B` / `OWNER_CRASH` / `pane-A-<ts>-<rand>`） |

「本仓 L3 是否间接覆盖」一列问的是：**本仓已有的 48 例 bats 里，有没有哪一条在事实上覆盖了这条缺口**（哪怕不是为它写的）。

---

## 缺口清单

### 1. AC12 —— 并发写盘无丢失更新

| 项 | 内容 |
|---|---|
| **归属仓** | opencode 仓（`~/.config/opencode/lib/delegate-core.ts` → `registerSession` + `withLock` 的 `mkdir` 协作锁） |
| **当前判定** | **PARTIAL**（验收报告 AC12：pair-v2 与 role.json 分区均已写入，但「并发无丢失更新」未实测） |
| **复现命令** | 并发发起两次 delegate，指向同一工程根 → 读该工程 `.rddf/state/pair.json`，检查两个 session 条目**都**存在；再读 `role.json` 的 `sessions` 分区，同判 |
| **本仓 L3 是否间接覆盖** | **否**。本仓 `test_stage_guide_cross_process_e2e.bats` 的「AC-1: two processes concurrently append_event — no row loss or duplication」覆盖的是 **rdd-workflow 侧 `events.jsonl` 的 fcntl 并发写**，与 opencode 侧 `.role.lock` 的 `mkdir` 协作锁是**两套不同的锁实现**，语义相近但代码不相交 → 只能当**参照模式**，不能算覆盖 |
| **备注** | 锁实现已存在（`withLock`：协作锁 + 30s 陈旧锁清理），缺的是**造并发的验证**。L2 用例「L2-4」扩展为并发场景即可覆盖，但需两次真实委托（模型额度） |

### 2. AC14 —— 开场报状态

| 项 | 内容 |
|---|---|
| **归属仓** | opencode 仓（`~/.config/opencode/prompts/front.md` 的开场报行为；`skill: deny` 由 front 权限块结构性保证） |
| **当前判定** | **NOT-TESTED**（验收报告 AC14：front.md 已写该行为，但未做「冷启动首轮即报状态」的专项实测） |
| **复现命令** | `opencode run --agent front --session <new-id> "<任务>"` → 看**首轮**回复是否含状态摘要 + 新鲜度标注（验收报告 AC13 已验证过摘要与新鲜度标注，缺的是「冷启动首轮」这一条件） |
| **本仓 L3 是否间接覆盖** | **否**。这是**模型行为**（front 读状态后自己组织语言），bats 无法在无模型条件下断言。本仓 L3 全部用固定文本驱动脚本 |
| **备注** | L2 用例「L2-1」可顺带覆盖（首轮回复结构），但属模型输出断言，**稳定性差**，不宜进 CI |

### 3. AC15 —— grants 预批端到端

| 项 | 内容 |
|---|---|
| **归属仓** | opencode 仓（delegate 工具的 `grants` 入参 + `question` 工具的代答链路） |
| **当前判定** | **NOT-TESTED**（验收报告 AC15：grants 通道本身 ✅，「front 先问用户 → 同意 → grants 进 permissions」的端到端未实测） |
| **复现命令** | `opencode run --agent front --session <new-id> "<需要问权限的任务>"` → 观察 front 是否发 `question` → 用户同意 → grants 是否进入工程 session 的 permissions（`session.get().permissions`） |
| **本仓 L3 是否间接覆盖** | **否**。需要真实模型的 `question` 交互与权限服务代答；本仓 L3 全程离线 |
| **备注** | 与缺口 2 同属「模型 + 宿主交互」类，L2 覆盖需要交互式 harness（`opencode run` 单次调用无法回答 question），本轮 L2 骨架未预留该用例 |

### 4. AC17 —— `failed` / `interrupted` 返回结构

| 项 | 内容 |
|---|---|
| **归属仓** | opencode 仓（`delegate-core.ts` 的 `outcome` 判定与 summary 结构） |
| **当前判定** | **NOT-TESTED**（验收报告 AC17：仅验证了 `succeeded` / `busy` / `unknown` 路径） |
| **复现命令** | 委托一个**必定失败**的任务（如：要求在只读目录里写文件）→ 读 delegate 返回的 summary，看 `outcome` 是否为 `failed`、`blocked_reason` / `blocked_action` / `blocked_all` 是否被填充；`interrupted` 需在工程 session 运行中人为打断 |
| **本仓 L3 是否间接覆盖** | **否**。`outcome` 取自宿主 `session.get().outcome`，是真实宿主字段；本仓 L3 没有真实 session |
| **备注** | `failed` 路径可在 L2 内低成本覆盖（委托一个会被权限层拒绝的任务即可）；`interrupted` 需要打断能力，L2 暂不覆盖 |

### 5. `unknown` 语义（宿主时间线）

| 项 | 内容 |
|---|---|
| **归属仓** | opencode 仓（`delegate-core.ts` 的 `newActivity` 判定：最后消息 id 变了 或 消息数变了） |
| **当前判定** | **NOT-TESTED**（front-delegate-testing.md 覆盖矩阵第 13 行：「宿主时间线行为，⚠ 未实测」） |
| **复现命令** | 委托一个**不产生新消息**的工程 session（极难构造）→ 看 summary 的 `outcome` 是否为 `unknown`、`new_activity` 是否为 false |
| **本仓 L3 是否间接覆盖** | **否**。`unknown` 的判定输入（消息 id / 消息数变化）完全是宿主时间线，本仓 L3 无从构造 |
| **备注** | 这是 7 项里**最难**在自动化中稳定构造的一条。建议保留为人工验收项，不进 L2 |

### 6. scope 只约束 edit 类目 → shell 写越界检测不到

| 项 | 内容 |
|---|---|
| **归属仓** | opencode 仓（`delegate-core.ts` 的 `outOfScopeFiles` 只比对**工程仓的 `git status`**；scope → 权限规则只生成 `edit` 类目） |
| **当前判定** | **known gap**（验收报告 §三 已知缺口 1：实测工程 session 在工程目录外写了临时文件，而 `out_of_scope_files` 为空） |
| **复现命令** | 委托 scope=`["a.txt"]`，任务要求「在工程目录**之外**创建 b.txt」→ 读 delegate summary：`out_of_scope_files` 仍为 `[]`（漏报） |
| **本仓 L3 是否间接覆盖** | **否**。越界检测代码在 opencode 仓，本仓 L3 不含该插件源码，也不驱动真实 delegate |
| **备注** | 结构性缺口，不是 bug：scope 目前表达的是「edit 工具的允许前缀」，不是「进程级写边界」。L2 用例「L2-5」的断言口径**必须显式排除 shell 路径**，否则会写出永远失败的用例 |

### 7. pair 过期清理未实现

| 项 | 内容 |
|---|---|
| **归属仓** | opencode 仓（`delegate-core.ts`：`remove` 默认 false + 无淘汰策略 → `pair.json` 的 `pairs` 持续累积） |
| **当前判定** | **known gap / 未实现**（验收报告 §三 已知缺口 5：ADR D2 把清理责任挂在 pair 的 `last_used_at` 过期策略上，该策略未落地） |
| **复现命令** | 连续委托 N 次（不传 `remove`）→ 读工程 `.rddf/state/pair.json`，`pairs` 条目数只增不减；`last_used_at` 有值但无任何进程消费它 |
| **本仓 L3 是否间接覆盖** | **否（但存在同构的先例可参照）**。rdd-workflow 侧有同类问题的另一套解法：`rddf sessions gc`（`~/.agents/skills/_lib/cli/sessions_cmd.py`）做「deterministic gc：只把陈旧的 active session 转成 orphaned」，且 `sessions.json` 里带 `last_heartbeat` / `ended_at`。**两套登记表的生命周期策略不同源** → opencode 侧的 pair.json 没有等价物 |
| **备注** | 建议 opencode 仓侧对齐 rdd-workflow 的 `gc` 思路（基于 `last_used_at` 的确定性淘汰），而不是加时间窗随机清理 |

---

## 本轮新发现（第 8 条，探针期间实测）

### 8. front 的 delegate 调用参数形状不合规 → `acceptance` 必须是 string

| 项 | 内容 |
|---|---|
| **归属仓** | opencode 仓（delegate 工具的 input schema + `prompts/front.md` 的 brief 表；**不是**本仓的代码问题） |
| **当前判定** | **实测复现**（本轮探针期间，front session 对**本仓**发起真实 delegate 时命中） |
| **复现命令** | `opencode session export <front-session-id> \| python3 -c "…"` → 取 `content[].type=='tool' and name=='delegate'` 的 part，看 `state.error.message` 与 `state.input.acceptance` 的类型 |
| **原始证据** | 工具 part 记录的 `state.error`：`{"type":"tool.execution","message":"Invalid arguments for tool \"delegate\":\n- acceptance: Expected string"}`；同一次调用的 `state.input.acceptance` 是**字符串数组**（3 条验收标准），而工具 schema 声明 `acceptance: { type: "string" }` |
| **本仓 L3 是否间接覆盖** | **否**。L1（`bun test`）只断言 core 里声明的 schema 形状，**不断言模型是否会遵守它**；L3 无模型 |
| **影响** | 「模型不按 schema 填参」是 L2 必须正面覆盖的失败模式。L2 用例「L2-3 / L2-4」的断言必须能区分「委托被参数校验拒绝」与「委托执行了但结果不符」——两者在 summary 里的表现完全不同（前者没有 `session_id`，后者有） |

### 9. 上一轮 5 处权限拦截的归属判定 —— 4 处是宿主策略的正确行为，1 处暴露了 shell 守卫的「零节点跳过」

| 项 | 内容 |
|---|---|
| **归属仓** | opencode 仓（shell 工具的权限匹配器 / `external_directory` 判定）。**其中 4 处的拦截本身是正确行为，不需要改产品**；只有最后一条是真缺口 |
| **当前判定** | **NOT-A-BUG（4 处）+ 已知缺口（1 处）** |
| **原始证据** | 上一轮 delegate 返回里的 `blocked_all`（5 条，顺序 = 发生顺序）：`external_directory` ×3 + `shell` ×2。逐条还原（具体命令 / 判定来源 / 对 L2 的影响 / 是否需追加 grant）见 [real-runtime-prereqs.md §9](./real-runtime-prereqs.md) |
| **复现命令** | 在**被委托的工程 session**里跑这三条（本轮已实测复现，结果一致）：<br>`rm -f <repo>/.tmp-l2/.nonexistent` → `Permission denied: shell`（Build agent 的 `rm -f *` 是 **ask**，非交互 session 无人应答 → 直接拒）<br>`cd /tmp/x && pwd` → `Permission denied: external_directory`（shell 的 chdir 目标在 project root 外）<br>`read /workspace/main/<另一个仓>/…` → `Permission denied: external_directory`（read 工具的 external 检查） |
| **本仓 L3 是否间接覆盖** | **否**。权限匹配在宿主侧，本仓 L3 全程离线、也不持有真实 session |
| **影响** | ① **L2 的 8 条用例不需要追加任何 grant** —— 5 处拦截都不在关键路径上；<br>② 但 L2 的写法有两条纪律：清理动作必须**放进脚本**（脚本内部的命令不过 shell 工具的权限匹配），路径必须用**字面量绝对路径**（`$HOME` 未展开会绕过 external 检查） |
| **唯一真缺口** | **`$HOME` 未展开能绕过 shell 的 `external_directory` 检查**：上一轮 `dd if=$HOME/.opencode/bin/opencode bs=1 skip=… count=…` 被**放行**，而同一 session 里 `read /workspace/main/rdd-workflow/…` 被拒 → 匹配器在「零节点」时跳过了检查（验收报告 §三 已知缺口 6「shell 守卫非完备边界」的具体样本）。**归属 opencode 仓**；本轮已通过用户 grant `external_directory:/home/ubuntu/.opencode/**` 把该路径显式放行，**不再依赖绕过写法** |

---

## 不是 opencode 仓缺口、但本轮实测踩到并已在本仓消化的 4 个坑

这 4 条**归属本仓的 L2 harness**（探针脚本 + 测试骨架），不进上面的跨仓表；
列在这里是为了让下一轮建用例时不要重蹈。

| # | 坑 | 现象 | 本仓处置 |
|---|---|---|---|
| 1 | fixture 携带 `.rddf/state/` | 复制工作树时把 `pair.json` 一起带走 → front 读到里面的 session id → 当 `resume_session` 传给 delegate → 去续接一个**正在运行的** session → 返回 `busy` → front 无限重试（实测 10 分钟不收敛） | 探针脚本与 L2 用例都改成**只删登记文件**：`rm -f "$dest/.rddf/state/pair.json" "$dest/.rddf/state/role.json"`（保留 `.rddf/state/` 的其余内容）；prompt 里显式写「若返回 busy 就直接汇报，不要重复尝试」 |
| 2 | fixture 放在仓库内 | front 把**仓库根**当成 `project_dir`（7/7 次调用都是），并读到仓库自己的 `pair.json` | fixture 改放**仓库外**的 `/workspace/main/…`（sticky 可写、front 读得到、不脏 git status） |
| 3 | 断言口径没区分失败形态 | 「参数校验被拒」「busy」「执行了但结果不符」在 stdout 里长得不一样（前者无 `session_id`） | L2 断言优先级定为：文件系统事实 > stdout `tool_use` 事件 > 自然语言；每条用例独立超时（建议 300s） |
| 4 | 并发跑探针互相清工作目录 | 后一轮探针的清理删掉了前一轮还在跑的 fixture 与 stdout | 探针只清理**自己造出来且带 `.probe-owner` 标记**的子目录，`PROBE_ROOT` 仅在清空后 `rmdir`；仍建议同机不并发跑两轮 |

> 副产品：坑 1 的复现过程**顺带把 `busy` 语义（AC11）在真实运行时复现了一遍**
> ——`outcome="busy"` + `still_running=true` + 明确拒绝排队，与验收报告 AC11 结论一致；
> `resume_session` 走 `pair.json` 登记表的续接路径也被真实走通。

---

## 处置原则

1. **只记录，不改 opencode 仓**（用户拍板）。本表是 opencode 仓排期的输入，不是本仓的待办。
2. 每条给出**可复现命令**，让 opencode 仓侧能直接接手验证。
3. 「本仓 L3 是否间接覆盖」一列只认**事实覆盖**（同一段代码路径被真实执行过），不认「语义相近」。
4. 本仓的 L2 用例集（`tests/integration/test_front_delegate_runtime.bats`）里，凡最终形态会受本表影响的用例，都已在其注释中写明受影响的缺口编号与口径要求。

## 相关文档

| 文档 | 内容 |
|---|---|
| [real-runtime-prereqs.md](./real-runtime-prereqs.md) | L2 落地的前置探针（P1–P5）结论与证据 |
| `~/.config/opencode/docs/front-delegate-testing.md` | 上游的测试分层与覆盖矩阵（§4） |
| `~/.config/opencode/.rddf/reviews/front-agent-redesign-acceptance.md` | 验收报告（AC1–AC17 逐条判定、§三 已知缺口、§四 运维事实、§五 复现命令） |
| `~/.config/opencode/.rddf/reviews/front-agent-redesign-p0-probes.md` | Stage 0 前置探针报告（5 项计划外发现） |
