# ADR-0003: 评测集分层与 oracle 准入

| 字段 | 值 |
|---|---|
| Status | Proposed |
| Date | 2026-11-19 |
| Author | architect |
| 审稿报告 | `.rddf/reviews/harness-adr-review.md`（oracle + metis → critic；BLOCKER 已闭合） |
| Parent | ADR-0001 |
| 关联 change | `backlog: harness-p1` |
| 分期 | **P1**（P0 只做观测指标，不建评测集） |
| AC 映射 | 暂缺（change 未立项） |

## 背景与问题

现有 e2e 几乎全是**契约测试**，能防回归，但不能回答「agent 在这类任务上变好还是变坏」。session DB 有 12,632 条用户输入和 137k 次工具调用，但没有 ground truth、依赖当时仓库状态，且关键 verdict 未结构化。

若把「会话成功」当 oracle，RSI 会学会「快速结束」而不是「正确交付」。

## 决策

1. **三层任务集**：

| 层 | 判定 | 运行时机 | 准入 |
|---|---|---|---|
| contract | 确定性（文件事实 / 退出码 / 结构化字段） | 每 PR | 可复现 fixture + 机械 oracle |
| capability | 机械 oracle + 多次采样 | 夜间（本机 cron） | 同上 + 统计稳定的任务 |
| adversarial | 变异 / 边界输入 | 候选 patch | 明确的安全属性 |

初期 adversarial **并入 contract 的 mutation 检查**，不单独成层；capability 正式集 ≥ 30 条后再拆出。

**双路径配对子集**（2026-11-27 增补，指向 ADR-0008）：capability 层内设「同一任务多臂」的配对子集（W0 无阶段编排 / W1 内置编排 / W2 内置编排 + rdd skill；**主比较 = W1↔W2**，W0 仅作参照、不进主比较）。case 元数据须含 `task_orchestration_intrinsic`（ADR-0008 决策 1 约束 2；声明须附理由，并进本 ADR 决策 3 的**审计记录** + 决策 4 的 100% 审计要求）。⚠ 配对子集**不改变**本 ADR 决策 7 的统计口径 —— Δ 仍只标「方向性」，阈值以 ADR-0005 §4 为唯一真源；「正式集 ≥ 30 条」按**任务**计，不按臂计（见决策 6）。

2. **断言纪律引用既有真源**：`docs/runtime-assertion-discipline.md` 的三条（事实非措辞 / 可证伪 / 变红演练）为唯一口径，本 ADR 不复制。补充一条：模型文本只允许断言 prompt 明确规定的短语（契约检查）。
3. **转正规则**：生产会话只产出候选。任何用例转正必须同时满足：
   - 在隔离 fixture 中可重放；
   - 有机械 oracle（禁止「模型说做完了」）；
   - **有 reference solution 且它通过该 oracle**（不是「存在」）；
   - **替代正确解（不同工具序列）也必须通过**（防 oracle 过窄）；
   - 有一次变红演练记录；**case 或其 oracle 每次变更后必须重跑变红**；
   - **每 trial 干净环境**（显式断言无跨 run 共享状态：`HOME`、opencode session 目录、git 历史、`TMPDIR`、工作区；**2026-11-27 增补**：`.rddf/state/**` 与**叠加层的全部可达面**（四类对象：rdd-* per-skill 软链 / `_lib` 与 `rdd-workflow` 软链 / `~/.local/bin/rddf` wrapper / `PYTHONPATH` 与 `RDD_WORKFLOW_REPO` 注入 —— 清单以 ADR-0008 决策 6 的表为准）—— 否则上一 trial 的阶段状态与「skill 是否真的被遮蔽」会泄漏进下一 trial）；
   - **case 定义对被测 solver 不可达**（路径探针，不用 grep）；
   - 有 oracle 审计记录 `{case_id, oracle_sha, auditor, author, defects[], verdict, date}`，且 `auditor ≠ author`。
4. **判据审计常态化**：新增用例在首次进入 A/B 前 **100% 审计**（非抽样，防止「提案者灌弱判据赌抽样漏检」）；此后每新增 20 条或每季度（先到为准）一轮；缺陷率阈值以 ADR-0005 §1 为唯一真源。审计覆盖率作为报告字段。审计是**固定预算行**，不与提案吞吐竞争。
   - **1-operator 配置**：RSI agent 作为 author 时，由人作 auditor；人自撰用例时，用**独立 AI 会话**做交叉审并留痕，且报告须声明「AI 交叉审」及其局限（不得冒充双人背对背）。
5. **候选挖掘分层**：种子（去重后的用户输入）→ 轨迹（工具调用 + 错误 + 写目标 + diff）→ 弱标签（`idle_outcome`、tool error、后续 git 撤销）→ 人工确认 oracle 与 fixture。
6. **held-out**：capability 集 < 50 条前手动切分；之后按时间窗冻结，冻结集不回灌候选池，耗尽即扩充新窗口。**「capability 正式集 ≥ 30 条」按任务计，不按臂计**（配对子集中各臂不双倍计数），否则 ADR-0004 的 P2 恢复门槛被稀释。
7. **统计效力**：capability 集规模 × N 的**分辨率 > 5pp 期间**（尚不能分辨 5pp），Δ 只标「方向性」，不构成合并依据；数值与阈值以 ADR-0005 §4 为唯一真源。配对设计（逐任务翻转）虽更敏感，**不因此放宽**本条口径，其分辨率锚点须另行标注来源。
8. **skip 纪律**：评测 gate 必须读取 `executed / pass / fail / skip` 四元组；`skip` 总数超过基线即判红，不允许「全 skip 但 0 新增失败」通过。

## 选项对比

| 选项 | 结论 | 理由 |
|---|---|---|
| A. 全量模型打分作为 gate | 否 | 噪声大、可被优化（reward hacking） |
| B. 机械 oracle 优先，模型只做排序 | **选中** | 可回归、可解释 |
| C. 全部人工标注 | 否（不绝对） | 首年只需约 50 条确认用例，与 B 的差距比表面小；选 B 是因为可扩展 |
| D. 直接复用生产会话当用例 | 否 | 不可复现、无 ground truth、含敏感信息 |
| E. 三层同时建 | 否 | adversarial 初期并入 contract 即可，避免空壳层 |

## 后果 / 代价

**正面**

- 能力评测与契约回归分离，互不拖累。
- 明确禁止「模型自评」作为 gate。
- skip 纪律封住「全 skip 也绿」的现有漏洞。

**负面**

- 转正速度慢（每条需要 fixture + oracle）。
- capability 集达到统计效力前，A/B 只能给方向。
- held-out 手动切分需要维护。

**风险**

- oracle 写得太窄 ⇒ 过拟合；held-out 与对抗层是对冲。
- fixture 依赖生产快照 ⇒ 重放失败；必须最小化 fixture。

## Verification

- [ ] 每条正式用例有 `oracle` 说明与一次变红记录。
- [ ] 每条正式用例有 **reference solution**，且它**通过**该 oracle。
- [ ] 至少一条**替代正确解**（不同工具序列）通过同一 oracle。
- [ ] `contract` 层在无模型、无网络的 CI 中可全部执行。
- [ ] 评测 gate 输出四元组；构造一个「全 skip」运行，gate 必须判红。
- [ ] held-out 目录不在任何自动化写集内（按写目标检查，而非 grep 脚本）。
- [ ] 对 5 条用例删除其受约束要素后，必须变红（人工抽检，记录在报告里）；case 或 oracle 变更后自动重跑变红。
- [ ] 每 trial 干净环境：run2 看不到 run1 的 `HOME`、session 目录、git 历史、`TMPDIR`、工作区（路径探针）。
- [ ] case 定义对 solver 不可达（路径探针，非 grep）。
- [ ] 新增用例在首次进入 A/B 前有 100% 审计记录，`auditor ≠ author`。
- [ ] 试点 10 条审计缺陷率 >10% 时 capability 扩量被冻结。
- [ ] 目标类 <10 条时，A/B 报告标记为「方向性」且不进入合并依据。
- [ ] 任一用例的判定路径中，不存在「读取模型自然语言结论」作为唯一 oracle。
- [ ] `judge_defect_rate` 与 `false_negative_rate` 出现在报告中，且带分母与抽样方法。
