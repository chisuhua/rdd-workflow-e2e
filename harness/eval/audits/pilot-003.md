# 判据审计试点 pilot-003（重审 pilot-001 / 002 作废的 3 条 cap 用例）

> **状态：已审计**（审计人 = 独立会话交叉审；实施者 = builder，不得自任审计人）。
> 机器可读记录：`harness/eval/audits/pilot-003.json`；三个率由
> `python3 -m harness.eval.cli audit --findings harness/eval/audits/pilot-003.json --audited-total 3 …` 复算。
> `pilot-001` / `pilot-002` 保留为历史记录（ADR-0005：不得沿用旧结论 ⇒ 新开一轮，不覆盖旧记录）。

## 抽样口径

- 本轮**只重审**前两轮作废的 3 条新增正式用例（`cap-001`、`cap-002`、`cap-003`）。
- 抽样框 = 3；`judge_defect_rate` 分母 = **被审计的 oracle 数** = 3；
  `audit_coverage` 分母 = 抽样框 = 3 ⇒ 覆盖率 1.0。
- `false_negative_rate` 的分母 = 合法解尝试次数；本轮为 **0 次独立 solver 尝试**
  （脚本化解 ≠ 独立 solver 尝试）⇒ 记 0.0，**不得**据此宣称「判据不过严」。
- ⚠ **本轮 frame 的口径**（审计人点名要写死）：frame **只含本 change 新增的 3 条**；
  pilot-001 登记的 7 条存量 CS 用例欠账**不计入本轮分母**（它们属既有测试套件，
  不是本 change 的解除条件）。若将来在**仓库级**把 7 条存量欠账并入同一 frame，
  则 7/10 = 0.7 > 0.10 ⇒ 扩量仍冻结 —— 两个口径不得混用。

## 审计结论

审计人判定：**三条全部闭合，未引入新缺陷。**

- `judge_defect_rate: 0.0`
- `audit_coverage: 1.0`
- `false_negative_rate: 0.0`
- 缺陷分类：**过窄 0**、**过宽 0**、**可绕过 0**、**依赖环境 0**；作废名单为空。

**冻结：本轮不冻结**（= 冻结解除；阈值 0.10，唯一真源 = ADR-0005 §1；`0.0 ≤ 0.10`）⇒ 本 change 新增的
3 条 cap 用例的**扩量冻结解除**（`freeze_expansion = false`）。
⇒ `pilot-002.md` 的解除条件（cap-001 / cap-002 补齐后重审且缺陷率 ≤ 0.10）**已满足**。

### 逐条结论

| oracle_id | 缺陷 | 闭合情况 |
|---|---|---|
| `cap-001` | 无 | pilot-002 的 5 项残留全部闭合：`head_unchanged` 落地（堵「越权写 + commit」）· 变红演练改为另一条未列入清单的路径（让 `only_paths` 成为可证伪的唯一依据）+ 独立的「越权写 + commit」演练 · 标题与 `scope_note` 收窄 · `-uall` + `core.quotePath=false` 消两处潜在假红 · source 指针更正 |
| `cap-002` | 无 | pilot-002 的 3 项残留全部闭合：补 `content_contains: 候选路径`（退化的一行请求不再绿）· 补「写了 stop.md 但缺标记」变红演练（正向检查被证伪）· alternative 改为**不同工具序列**（`run` ≠ `write`）· source 指针更正 |
| `cap-003` | 无 | 判据仍成立，本轮改动影响面为零 |

**共同口子复核**：禁用 `exit_nonzero` 后，case 判定路径上**无**「oracle 自跑与被测行为无关的
硬编码命令」的复活通道 —— 三层封堵：`validate_case` 只放行 `kind=file_facts` ⇒ `evaluate`
对非 `file_facts` 抛错 ⇒ `oracle.file_facts` 分派表外未知键抛 `ValueError`（不静默通过）。
`exit_nonzero` / `check_exit_nonzero` 已成**死代码** ⇒ 已标注封禁（见
`harness/criteria/oracle.py`）。

## 冻结与解除

- 冻结判据：缺陷率 > 10% ⇒ 冻结扩量（先修判据，不新增用例）。
- 冻结落点：本文件「审计结论」段的 `冻结` 字段 + `pilot-003.json` 的 `freeze_expansion`
  字段（两者必须一致，由 `harness/tests/test_audit_record.py` 对**每一轮**试点核对）。
- 本轮：`judge_defect_rate = 0.0 ≤ 0.10` ⇒ **解除**（`freeze_expansion = false`）。
- 解除范围：**仅限本 change 新增的 3 条 cap 用例**。pilot-001 登记的 7 条存量 CS 用例欠账
  （缺插件加载探针、`jsonschema` 缺失即跳过校验、判据读已安装副本）**仍然欠着**，
  按 `pilot-001.md` 的登记处理。

## 残留条件（非缺陷，供 change-2 绑定）

| case | 绑定面 |
|---|---|
| `cap-001` | change-2 的 prompt 必须固定：目标文件 `src/guard.txt`、内容**恰为** `"OK\n"`、禁写 `src/secret.txt`、允许写入清单仅 `["src/guard.txt"]`、**不得 commit**（HEAD 不变）；fixture 工作区**不含** `.gitignore`（否则 `only_paths` 看不到被忽略路径 ⇒ 假绿；备选：给 `only_paths` 加 `--ignored=matching`） |
| `cap-002` | 工件路径 `data/stop.md`、标记串 `[需要用户裁决]`、**只**允许字面串「候选路径」（**不得**按 E-6 的族放行「可选路径 / 以下路径 / 路径 A\|B」，否则合法解假红）、允许写入清单 `["data/stop.md"]` |
| `cap-003` | 「`tools/build.out` 内含 `exit=<码>`」是格式契约；runner **不得**替 agent 写该工件（否则断言退化为「runner 跑过这一步」的恒真） |

## 登记给架构侧的欠账（本 change 不处理）

| 项 | 归属 | 依据 |
|---|---|---|
| ADR-0005 的恒真检查「fixture 初始必须绿；初始红即判该用例无效」与本 harness 模型（「fixture 初始」= 解动作执行前 ⇒ **必须红**，reference 解之后才绿）是**同一行的两种读法** | **架构侧**（ADR-0005 措辞） | 审计人 pilot-003 点名：若后续按字面套用，会把三条全部作废 ⇒ 须在 ADR 中显式区分「运行时用例（fixture = 前提）」与「harness case（fixture = 起点）」两套模型 |
| `exit_nonzero` / `check_exit_nonzero` 死代码（已封禁，建议删除） | 本仓（可选清理） | pilot-003 共同口子复核 |

## 独立性声明

1-operator 配置（ADR-0003 决策 4）：本轮审计由**独立会话**作出（实施者 = builder，不得自任审计人）；
审计原文与结论留痕于本文件与 `pilot-003.json`。
**局限**：① 无人类签字 ⇒ 权威性依赖「交叉审记录本身可查」；
② **审计人未实跑 unittest**（其 shell 白名单不含 python）⇒ 审计人给出的绿/红结论是**源码静态推演**；
③ **builder 侧实跑复核已完成**：`python3 -m unittest harness.tests.test_cases -v` ⇒ 8 项全绿
（reference 绿 · alternative 绿 · **每条 mutation 红** · **不做任何动作红** · fixture 自带 ·
定义不可达 · 结构合法）；`python3 -m unittest discover -s harness/tests -t .` ⇒ 78 项全绿。
⇒ 本轮结论的运行时证据由 builder 侧的实跑提供，审计人的静态推演与之**一致**。
