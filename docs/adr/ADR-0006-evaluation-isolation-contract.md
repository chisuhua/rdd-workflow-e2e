# ADR-0006: 评测隔离契约（评分器不可达）

| 字段 | 值 |
|---|---|
| Status | Proposed |
| Date | 2026-11-19 |
| Author | architect |
| Parent | ADR-0004（不可写集声明）、ADR-0002（trace 合同） |
| 关联 change | `backlog: harness-p1` |
| 分期 | **语义层现在生效**；**轻量档** P1；**容器档** 待触发线（见 §5） |
| 裁决记录 | 用户 2026-11-19 接受（默认轻量路径） |
| 本次修订 | 2026-11-27：不可读集**增补**臂索引与期望归属声明（引用 ADR-0001 / ADR-0007 / ADR-0008，不复制条款）+ §5 补判定（双路径对照**已踩触发线 (a)** ⇒ P1 开工前须判定轻量档是否足够）。**两档强度、触发线清单、语义层条款本身不变** |
| 外部依据 | `docs/research/03-safety-permission-and-eval-integrity.md`、`docs/research/04-observability-and-trail-contracts.md` |
| 审稿报告 | `.rddf/reviews/harness-adr-review.md`（第 3 轮，用户批准） |

## 背景与问题

安全核禁止「自动改」，但没有禁止 **agent 读写评分器 / rubric / eval 定义 / manifest**。公开证据显示：

- METR 在 RE-Bench 上观测到 **30.4%（39/128）** 的 run 出现 reward hacking；单任务 100%；
- BenchJack 扫描 8 个主流 agent benchmark，**全部 73–100% 可被刷**（10 行 `conftest.py` 即可解掉 SWE-bench Verified 每个实例）；
- OpenAI 2026-02 审计 SWE-bench Verified 抽样 138 题，**59.4% 有实质缺陷**。

⇒ 「判据外置」必须叠加**环境与信息边界**，否则只是文件放错了地方。

同时必须区分两件不同的事：

- **隔离（完整性）**：agent 读不到 grader / rubric / 私有测试；
- **确定性（可复现性）**：同一 artifacts 重跑得到相同分数。

这两件事的判据不可混写（一个完全隔离但用 LLM judge 的评分器必然不满足「重跑同分」）。

## 决策

### 1. 语义层（现在生效，与实现无关）

1. **不可读集**：评分器、rubric、eval 定义、criteria/、manifest 的**内容**对被测 agent 不可达。
   - **2026-11-27 增补（引用，不复制条款）**：双路径对照的**臂索引**（`arms/`，运行数据）与**期望归属声明**（`harness/path-config.yaml`，判据资产）同样对被测 agent 不可达 —— 前者按 ADR-0001 决策 4 由 runner 独占写、后者按 ADR-0007 决策 4 进安全核；**臂标签本身不可见，但「臂可被 skill 列表反推」是已知局限**（ADR-0008 决策 1 的诚实边界），本 ADR 不假装它是完全盲化。
2. **三段式执行**：solver（agent）→ 收集**显式声明的 artifacts** → grader（评分器）。
3. **私有数据不注入**：gold / rubric 路径 / 参考解存 `TaskData` 扩展字段，**不进入 agent 的 prompt、环境变量、挂载**。
4. **不可写集与安全核同源**：隔离相关路径与 ADR-0004 的安全核清单**共用一份 manifest**（`harness/safety-core.manifest`），不允许两处定义。
5. **判据不得自证**：被测 agent 不得参与判据生成、判据审批或判据执行。

### 2. 两档实现

| 档 | 机制 | 保证 | 不保证 |
|---|---|---|---|
| **轻量档（P1 默认）** | 工具层写集限制 + 评分目录权限位（独立用户 / `chmod`）+ 独立评分进程 + **路径可达性探针** | agent 进程无法打开评分器 / rubric / criteria 路径；评分输入只含声明的 artifacts | 不保证内核级隔离；不保证跨 trial 的宿主级状态清理 |
| **容器档（触发后）** | solver 容器（空工作区 / 无 NAS / **凭据探针必须失败**）+ fresh grading 容器 + `network: none` 可证 + 只读挂载 | 文件系统级隔离 + 网络隔离 + 双容器重跑同分 | 成本与启动时延（spot 约 30–60s 调度 + 拉镜像） |

### 3. 本环境的隔离能力（已实测，2026-11-19）

当前运行环境本身是 ECI 实例（`eci-uf65o2vzvkjp87qpefqj`）。**已在容器内验证可在创建新 ECI 作为评测沙箱**：

| 事实 | 证据 |
|---|---|
| 容器内 egress 到 `eci.cn-shanghai.aliyuncs.com` 可达 | HTTP 400（空请求到达 API） |
| 凭据可用（RAM 用户 `power-application-user`，账号与本实例 `owner-account-id` 一致） | `sts GetCallerIdentity` |
| 可在容器内创建新 ECI（spot、无 NAS、无 EIP） | `eci CreateContainerGroup` → `eci-uf65zwyqr4vidoei5ysi` → Running（约 40s） |
| 可在容器内执行命令 | `eci ExecContainerCommand`（**注意 API 名是 `ExecContainerCommand`，不是 `ExecContainer`**） |
| **新实例工作区干净** | `/workspace` 为空、`/home/ubuntu` 仅默认 dotfiles ⇒ 判据 / rubric / 历史会话天然不可达 |
| **新实例无可用的云凭据** | 沙箱内实测：`ram/security-credentials/` 返回 **404**、无 `~/.aliyun`、无 `aliyun` CLI ⇒ 无法调用云 API 创建兄弟实例 |
| 执行身份非 root | `id -u` = 1000 |
| 可销毁 | `eci DeleteContainerGroup` |

⚠ **`--mount-nas` 会破坏凭据边界**：挂载 `/home/ubuntu` 后，凭据文件（`my_eci.txt`）回到 solver 可达路径。容器档**必须**使用默认（不挂 NAS）或只读挂载不含凭据的目录。

脚本：`~/my-docker-env/aliyun_sandbox.sh`（`start` / `exec` / `stop` / `list`；默认不挂 NAS、不给 EIP、spot 优先）。

⇒ **容器档在本环境是可达的**，不需要 Docker daemon（当前为 Kubernetes/containerd 管理的 ECI，无 `/var/run/docker.sock`）。

### 4. 契约条款（与档位无关）

1. 每条用例声明 **artifacts 清单**（含 `source` / `exclude` / `required`）；未声明的文件不得进入评分输入。
2. 每条用例声明 **oracle**（机械判据），并声明 **reference solution**（通过该 oracle 的合法解）。
3. **双向平衡**：既含「应当触发」的用例，也含「不应触发」的用例，防过度触发。
4. **判据审计**：oracle 由**非作者**人审；新增用例在首次进入 A/B 前 **100% 审计**（非抽样）；审计记录含 `{case_id, oracle_sha, auditor, author, defects[], verdict, date}`，由 harness 写入（作者无写权限）。1-operator 配置下：RSI 为 author 时人作 auditor；人自撰用例时用独立 AI 会话交叉审并留痕，报告须声明「AI 交叉审」及其局限。
5. **审计覆盖率是报告字段**：防止「提案越多、单位审计强度越低」。
6. **每 trial 干净环境**：显式断言无跨 run 共享状态（含 `HOME`、opencode session 目录、git 历史、`TMPDIR`、工作区）。**清单以 ADR-0003 决策 3 为唯一真源**（该条已扩入 `.rddf/state/**` 与**叠加层四类遮蔽对象**；遮蔽对象的逐项定义见 ADR-0008 决策 6）—— 本 ADR 不另立清单。
7. **评分器确定性**：非 LLM 评分器须同输入同输出；LLM 评分器须固定模型与参数，并报告与人工的一致率（判官自身被评测）。

### 5. 容器档触发线（任一满足即重审）

1. E 层开始**真实执行 agent 代码**（而非查 DB / 读文本）；
2. ADR-0004 的 P2 恢复、自动提案进入执行；
3. 出现 **gold / rubric 经 prompt 注入**的实测近失 —— **认定程序**：harness 审计在 trace 中记录到一次「注入内容进入 solver 的 prompt 输入」的证据（trace 字段 + artifact 快照），由非提案者的审计者写入报告；口头怀疑不构成触发。
4. 轻量档路径可达性探针出现一次绕过。

**2026-11-27 补判定（触发线 a）**：双路径对照（ADR-0008）各臂都**真跑模型做真任务** ⇒ **已满足触发线 (a)**（「E 层开始真实执行 agent 代码」）。⇒ **P1 开工前必须先完成一次判定**（本判定未完成前，双路径对照**不得开工**）。

**判定 checklist（逐条给结论，不得整体通过）**：

1. **威胁模型 diff**：相对既有 real-runtime 用例（`tests/integration/**` 的 `E2E_REAL_RUNTIME=1` 族），双路径对照**新增**的暴露面 = {① 叠加层**遮蔽完整性**（漏一处 ⇒ 禁用臂仍在跑叠加层机制）② **臂索引 / 期望归属声明**对 solver 的不可读性 ③ **预算与 partial run 的记账**（可复现性）④ **W0 臂的通用 prompt 副本**是否把 case 定义 / 判据泄露给 solver}；
2. 每一项给出「轻量档（工具层写集 + 评分目录权限位 + 独立评分进程 + 路径可达性探针）**是否足够**」的判定与依据；
3. **判定 memo 落 `.rddf/reviews/`**，含：结论、逐条 checklist 结果、日期、判定人；memo 未落盘 ⇒ 该门视为**未通过**（不可证伪的门等于没有门）。

### 6. 与其他 ADR 的关系

- 本 ADR **不重新定义安全核**：不可写集与安全核共用 ADR-0004 的 manifest。
- 轨迹字段沿用 ADR-0002（ATIF / EvalSpec 子集）；隔离相关字段（`sandbox` 规格、artifacts 清单）进 run manifest。
- 判据审计常态化与合并 gate 语义见 ADR-0003 / ADR-0004 / ADR-0005。

## 选项对比

| 选项 | 结论 | 理由 |
|---|---|---|
| A. 只靠安全核（禁止自动改），不做隔离 | 否 | 单层不足：路径禁改挡不住「读」与「注入」；BenchJack 证明可刷 |
| B. 轻量档（权限位 + 独立进程 + 探针） | **选中（P1 默认）** | 成本低、覆盖当前威胁模型（合作型模型 + 自有流程近失）、无容器依赖 |
| C. 容器档（fresh grading container） | **保留（触发后）** | 文件系统级隔离最强；本环境已验证可达，但成本与启动时延不适合每 trial |
| D. 一步到位全容器化 | 否 | 每 trial 启动 30–60s + 计费；与「成本一等」冲突 |
| E. 复用 Inspect / Harbor / verifiers 现成 runner | 待验证 | 排在 ADR-0002 契约冻结之后；避免内部契约让渡给上游 API |

## 后果 / 代价

**正面**

- 「安全核禁止自动改」不再可被「改评测」绕过。
- 隔离强度可分级，代价与威胁模型对齐。
- 本环境已具备容器档能力，未来升级无需换基础设施。

**负面**

- 轻量档依赖路径可达性探针的准确性；探针本身要纳入测试。
- 容器档每 trial 成本与时延高（spot 计费 + 调度）。
- 判据审计是**持续人力**，不是一次性事件。

**风险**

- 探针被绕过 ⇒ 触发线 4；必须有独立探针实现。
- 审计人力与提案吞吐竞争 ⇒ 审计是固定预算行（ADR-0004 人审条款）。
- 「隔离」与「确定性」混淆 ⇒ 本 ADR 明确分列判据。

## Verification

**语义层（现在可验）**

- [ ] 安全核 manifest 中含 `harness/criteria/**`、`harness/eval/**`、评分器路径，且与隔离清单同源（diff 为空）。
- [ ] gold / rubric 路径不出现在任何 case 的 prompt、环境变量、挂载表中（路径探针，不用 grep）。
- [ ] 被测 agent 的运行写集不含 criteria / eval 路径。

**轻量档（P1）**

- [ ] 路径可达性探针：solver 进程尝试 open 评分器 / rubric 路径 ⇒ 返回不可达（探针实现独立于 solver）。
- [ ] 评分进程输入目录只含声明的 artifacts（目录清单 diff）。
- [ ] 每 trial 前断言干净环境：`HOME`、opencode session 目录、git 历史、`TMPDIR`、工作区均为本 trial 新建。
- [ ] 替代正确解（不同工具序列）必须通过同一 oracle。
- [ ] 新增用例在首次进入 A/B 前有 100% 审计记录，且 `auditor ≠ author`。

**容器档（触发后）**

- [ ] solver 容器文件系统内不存在 criteria / rubric 路径（挂载表 + 路径探针）。
- [ ] solver 容器内 `ram/security-credentials/` 探针失败、无 `~/.aliyun`、无云 CLI（凭据探针；`--mount-nas` 运行时必须重跑本项）。
- [ ] egress 探针在 solver 容器内必须失败。
- [ ] 同一 artifacts 在两个 fresh grading 容器中重跑 ⇒ 分数相同。
- [ ] artifacts 目录在评分结束后只读。
- [ ] 评分容器内私有测试文件不出现在 solver 容器。

**每档通用**

- [ ] 判据审计覆盖率出现在报告字段中。
- [ ] 报告中的 `sandbox` 规格与实际一致（可对账）。
