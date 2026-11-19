# ADR-0001: Harness 数据面归属与 single writer

| 字段 | 值 |
|---|---|
| Status | Proposed |
| Date | 2026-11-19 |
| Author | architect |
| 审稿报告 | `.rddf/reviews/harness-adr-review.md`（oracle + metis → critic；BLOCKER 已闭合） |
| Parent | — |
| 关联 change | `backlog: harness-p0` |
| AC 映射 | 暂缺（change 未立项） |

## 背景与问题

harness 需要同时处理三类东西：**代码**（抽取、任务集、runner）、**运行数据**（trace、报告、候选 patch）、**判定**（oracle 结果）。系统里已有四个仓：

- `~/.config/opencode`：治理面，含 agent 规则与权限；
- `rdd-workflow`：产品面，含 gate / handoff；
- `rdd-workflow-e2e`：评测面，已有 143 条外部用例；
- `oh-my-openagent`：已有 usage ledger（skills/memory/reservation）。

若不先定归属，会出现两个后果：① 被测对象获得修改判据的能力；② 同一指标出现两套口径。

## 决策

1. **代码归 `rdd-workflow-e2e`**，新增 `harness/` 目录（schema、抽取脚本、任务集、runner、报告生成）。
2. **运行数据归本地状态目录** `~/.local/share/rddf-harness/`（不进 git、不跨机同步）：
   - `snapshots/`：`opencode.db` 的离线快照 + SHA256
   - `traces/`：归一化 trace（NDJSON，P1 起）
   - `runs/`：一次评测的 manifest + 结果
   - `proposals/`：候选 patch（只读区，人审后合并；P2 起）
3. **报告归 `rdd-workflow-e2e/.rddf/reviews/`**（与既有验收报告同落点）。
4. **single writer 划分（按工件 + 按进程实例）**：

| 工件 | 唯一写入者 |
|---|---|
| `harness/**` schema / 脚本 | e2e 仓（builder 经 change 实施） |
| `snapshots/` | 快照脚本（运行期间独占，文件名含 SHA） |
| `traces/` `runs/` `proposals/` | 单个 harness 进程（同文件不允许双写） |
| 评测报告 | verifier 角色 |
| ADR / 架构文档 | architect |
| 被测仓的规则与实现 | 各自仓的角色流程 |

5. **P0 不修改任何被测仓**：本期只读取 session DB 并生成快照；`~/.config/opencode` 的 delegate 持久化钩子属 P1，需作为跨仓治理变更单独获批（旧拍板见 `docs/known-gaps-and-ownership.md`）。
6. **`oh-my-openagent` 的 usage ledger 只消费不复制**：harness 读取其聚合值，不另建同义指标。

## 选项对比

| 选项 | 结论 | 理由 |
|---|---|---|
| A. 代码与数据全放 e2e 仓 | 否 | 数据进 git：体积、隐私、每次评测产生 diff 噪声 |
| B. 代码 e2e 仓 + 数据本地状态目录 | **选中** | 代码可评审、数据可丢弃；与现有 `KNOWN_FAILURES` / 报告落点一致 |
| C. 全放 `rdd-workflow` 产品仓 | 否 | 被测对象同时持有判据，违反「判据外置」 |
| D. 放 `~/.config/opencode` 治理面 | 否 | 治理面写权限过大，且 harness 跨仓使用不应绑定用户配置 |

## 后果 / 代价

**正面**

- 判据与实现分离；被测仓无法修改 harness。
- 数据不进 git，评测不会污染工作区。
- 复用 e2e 仓已有的回归基线与报告机制。

**负面**

- 跨仓读取需要额外的只读权限约定。
- 本地数据需要清理策略（否则无限增长）。
- `harness/` 与既有 `tests/` 边界需要文档化，避免职责重叠。

**风险**

- 本地数据目录在 CI 中不可用 ⇒ CI 只能跑 contract 层，能力评测必须本地/夜间执行。
- 若将来需要共享 trace，必须走脱敏导出，而不是直接同步目录。

## Verification

- [ ] `harness/` 目录存在且不含运行数据（无 `snapshots/`、`traces/`、`runs/`）。
- [ ] 快照脚本 dry-run 能列出将清理的文件数与保留期边界；实际删除前要求确认。
- [ ] 任一 trace / snapshot 文件的写者唯一（按文件名 SHA 与进程锁检查，无第二进程写入同一路径）。
- [ ] 评测报告只出现在 `.rddf/reviews/`，不出现在 `harness/`。
- [ ] `oh-my-openagent` ledger 只被读取，未被 harness 改写。
- [ ] 一次评测的 `runs/run-manifest.json`（`kind=eval`）可还原：`opencode_sha`、`product_sha`、`model_id`、`prompt_version`、`snapshot_sha`；P0 的 `kind=metrics` 子集见 ADR-0005 §3。
- [ ] P0 运行前后，`~/.config/opencode` 与 `rdd-workflow` 的 `git status` 为空。
