# harness — O 层观测（P0）

只读 `opencode.db` 的离线快照，产出可复算指标。**不修改被测仓、不调用模型。**

## 用法

```bash
# 全流程：快照 → 指标 → manifest → 报告（默认 DB ~/.local/share/opencode/opencode.db）
python3 -m harness.run all

# 从已有快照重算（不重新快照；等价于同一快照重跑）
python3 -m harness.run report --snapshot ~/.local/share/rddf-harness/snapshots/<sha>.db

# 单独步骤
python3 -m harness.run snapshot --db <path> --out <dir>
python3 -m harness.run metrics  --snapshot <db>

# 单元测试（合成库 fixture，无外部依赖）
python3 -m unittest discover -s harness/tests -t .
```

产物（默认 `~/.local/share/rddf-harness/`，不进 git）：

```
snapshots/<sha256>.db          # SQLite backup + integrity_check
runs/<UTC-stamp>/
  metrics.json                 # 指标（排序键稳定）
  run-manifest.json            # kind=metrics / snapshot_sha256 / metrics_version / metrics_sha / granularity
  report.md                    # 人读报告
  determinism.json             # 同一快照两次计算是否一致
```

## 口径（ADR-0005 §1）

- 一行 = 一个**根 session**；子会话按 `parent_id` 归并到根。
- 成功率分母 = `succeeded + failed + interrupted + unknown`；`idle_outcome` 为 null 归 `unknown` 并计入分母。
- 成本 `sum` 跳过 null；`cost_coverage` = 有成本值的 session / 全部 session。
- 工具错误率 = `state.error` 非空的工具调用 / 工具调用总数；**必须与错误类别分布同读**：
  `permission.rejected`（该 agent 无权用该工具）是设计行为，单列 `permission_denied`，不计入
  `tool_execution_error_rate`（= 1 − (权限拒绝 + 中断 + 供应商故障) / 调用总数）。
- `unknown_rate` = `idle_outcome` 缺失的根会话占比（P0 实测 8.96%）⇒ 正确性信号有缺口。
- 时延 p50/p95 按根簇的 `min(time_created) → max(time_updated)`。
- 报告中同时给「按 agent（全部 session）」与「按根 session 的 agent」两张表：前者看执行者分布，后者是 P0 的率口径。

## 设计约束

- 快照必须用 SQLite `backup` API（WAL 下裸拷贝会撕裂）；先写临时文件，`integrity_check` 通过后再按内容哈希命名。
- 指标公式写死在代码里（`metrics_version`），改公式必须升版本（ADR-0005 `metrics_version` 变更门）。
- JSON 解析失败计入 `parse_errors`，不中断计算。
- 不读/不写 `~/.config/opencode` 与 `rdd-workflow`。

## 已知限制（P0 范围）

- 只做 **O 层**：不做评测、不调用模型、不跑 runtime 用例。
- 时延是 session 簇窗口，不是单次模型调用时延（P1 trace 再细化）。
- 子会话的「成功率」按自身 `idle_outcome` 统计，与根簇率是不同口径。
- `cost` 在订阅型 provider 下可能为 0，`cost_coverage` 只反映「字段非空」而非「真实计费」。

## unit trace 投影（P1 / ADR-0002 合同）

把 P0 的「session 粒度」升级为 **unit 粒度**（`(session_id, round_index)`，一行 NDJSON）。

```bash
# 从离线快照投影 unit trace（默认落 ~/.local/share/rddf-harness/runs/<ts>/trace.jsonl）
python3 -m harness.run trace --snapshot ~/.local/share/rddf-harness/snapshots/<sha>.db
```

**产出的三项完整性指标**（写 `trace-completeness.json`，同时打印）：

| 指标 | 含义 |
|---|---|
| `trace_incomplete_rate` | 不完整的 unit 占比；**> 5% 告警**（ADR-0002 决策 6，恰好 5% 不告警） |
| `torn_lines` | 截断末行的行数（末行非法 JSON **且** 文件不以换行结尾） |
| `cost_coverage` | 有 `cost` 值的 unit 占比 |

**行粒度断点（必读）**：本报告 `granularity = "unit"`；**P0（session）与 P1（unit）的趋势不可拼接**
（ADR-0002 决策 1 / ADR-0005 行粒度）⇒ `metrics_version` 已升 `p0-metrics-v3`，既有基线需分段看。

**完整性判定的四类来源**（写死在 `harness/trace.py`，可单测）：
`outcome-blocked`（跨仓运行时字段被我方置空）· `json-parse-error` · `unknown-message-type` ·
`no-messages` / `missing-<列名>`（关键 session 列缺失）。

⚠ **本 change 期间 `trace_incomplete` 率恒为 100%**：运行时的 `outcome` 字段组仍被跨仓阻塞
（`~/.config/opencode`，需单独获批）⇒ 「> 5% 告警」是**真实信号**（trace 尚不完整），**不是回归**。

**脱敏**：默认只落 `prompt_hash`（不落原文）；JWT / Basic auth / `.netrc` 会被替换为 `[REDACTED:<类>]`。
需要原文时显式 `HARNESS_KEEP_PROMPTS=1`（**只写本地**）。

**落点**：`runs/<ts>/trace.jsonl`。⚠ 这与 ADR-0002 决策 4 的 `traces/delegate-<session>.jsonl`
**不是同一个东西** —— 后者是跨仓运行时的产物，本仓不产出。

## 关联

- ADR-0001（数据面与归属）、ADR-0002（trace 合同，P1）、ADR-0005（指标口径）
- 架构：`docs/architecture/agent-harness-and-rsi.md` §4

---

# E 层就绪资产（change-1，双路径对照开工的前置）

本节是 **P1 的第一批交付物**（`openspec/changes/harness-p1`）。它们让双路径对照
（W0 / W1 / W2 三臂，ADR-0008）**可开工、可审计** —— 但**本期不跑真模型**：
只交付静态资产、判据与单元测试；runner 与真模型 run 另立。

## 用法

```bash
# 归属声明 lint（阶段集合对账 + 五列非空 + 证据集可解析）+ 迁空 tripwire
python3 -m harness.eval.cli path-config

# 遮蔽探针（环境状态 JSON；断言方向按臂条件化）
python3 -m harness.eval.cli masking --env /tmp/env.json --arm W0

# 臂索引追加（五字段；臂标签只存在于此）
python3 -m harness.eval.cli arms-index --path ~/.local/share/rddf-harness/arms/index.jsonl \
  --session-id ses_x --run-id run_x --arm W2 --prompt-hash <sha256>

# 产出 kind=eval manifest（14 字段）
python3 -m harness.eval.cli eval-manifest --out /tmp/run-manifest.json \
  --opencode-sha <sha> --product-sha <sha> --model-id <id> \
  --prompt-version <hash> --criteria-version <hash> --taskset-version <hash> \
  --snapshot-sha <sha>

# 判据审计汇总（三个率 + 冻结判定）
python3 -m harness.eval.cli audit --findings /tmp/findings.json \
  --audited-total 10 --sampling-method "试点 10 条全审"

# 单元测试（无外部依赖）
python3 -m unittest discover -s harness/tests -t .
```

**判红 ⇒ 退出码 1**；用法错 ⇒ 退出码 2。

## 资产清单与判据出处

| 资产 | 作用 | 判据出处 |
|---|---|---|
| `harness/path-config.yaml` | 期望归属声明（五列 + 证据集） | ADR-0007 决策 4 |
| `harness/eval/path_config.py` | 声明 lint、阶段集合对账、迁空 tripwire、`path_config_version` | ADR-0007 Verification |
| `harness/safety-core.manifest` + `.sha256` | 安全核路径清单（`repo:` / `external:` 两类 scope） | ADR-0004 决策 4 |
| `harness/eval/safety_core.py` | glob ↔ 实际布局核对（清单与布局不符 ⇒ 判红） | ADR-0004 决策 4（含 `harness/metrics/**` 匹配不到单文件的教训） |
| `harness/eval/masking.py` | 遮蔽探针（四项断言 + 按臂条件化） | ADR-0008 决策 6 |
| `harness/eval/prompts/w0-base.md` + `markers.yaml` | W0 通用 prompt 副本 + 角色矩阵关键段清单（版本化） | ADR-0008 决策 1 |
| `harness/eval/arms_index.py` | 臂索引 writer（五字段；标签只在此） | ADR-0008 决策 2；ADR-0001 决策 4 |
| `harness/manifest.py::build_eval` | `kind=eval` manifest（14 字段） | ADR-0005 §3 |
| `harness/criteria/cases/*.json` + `harness/criteria/oracle.py` | cap 集首族 case（机械 oracle + reference / alternative / mutation） | ADR-0003 决策 3；主题文档 §6 |
| `harness/eval/audit.py` | 判据审计三率 + 冻结扩量判定 | ADR-0005 指标定义；ADR-0003 决策 4 |

## 本期的硬门与不做项

- **硬门**：ADR-0006 §5 判定 memo 未落盘 ⇒ 双路径对照**不得开工**
  （memo：`.rddf/reviews/adr-0006-isolation-verdict.md`）。
- **不做**：runner、真模型调用、臂间 Δ、容器档、生产侧归因、delegate 跨仓持久化。
- **判据资产**：`harness/path-config.yaml`、`harness/safety-core.manifest`、
  `harness/eval/**`、`harness/criteria/**` 均在安全核内 ⇒ 落地强制人审 + 安全核扫描
  （ADR-0004 决策 2）。
