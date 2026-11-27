"""遮蔽探针（ADR-0008 决策 6 + ADR-0006 §5 轻量档）。

被测对象是**环境状态**，不是模型输出。

两类断言：

**A. 叠加层可达面（方向按臂条件化）** —— ADR-0008 决策 6 的**四类遮蔽对象**：

| # | 遮蔽对象 | 禁用臂断言 |
|---|---|---|
| 1 | `~/.agents/skills/rdd-*`（per-skill 软链） | 不存在 |
| 2 | `~/.agents/skills/_lib`、`~/.agents/skills/rdd-workflow` | 不存在 |
| 3 | `~/.local/bin/rddf`（wrapper） | 不在 PATH |
| 4 | `PYTHONPATH` / `RDD_WORKFLOW_REPO` 注入 | 未注入 |

⇒ 禁用臂另加三项行为断言：`rdd-*` 成功调用数 = 0 ∧ 可用 skill 列表不含 `rdd-*` ∧
对 `rdd-*` 的尝试性调用返回 unknown-skill（**不是**「skill 工具调用数 = 0」——
工具仍在，猜测调用会产生 unknown-skill 错误）。
⇒ 启用臂断言四类对象**均存在**（臂序随机化时方向随臂翻转）。

**B. 路径可达性（与臂无关）** —— 判据类与运行数据类文件对 solver **不可读**，
且运行数据（臂索引）**不可写**：

- 不可读：`~/.local/share/rddf-harness/arms/**`、`harness/path-config.yaml`、
  `harness/criteria/**`、`harness/eval/audits/**`；
- 不可写：`~/.local/share/rddf-harness/arms/**`（臂索引不在安全核内 ⇒ 写方向必须单独断言，
  否则 solver 可自报/篡改 `arm` 字段）。

⚠ 探针是**检测器**，不是隔离器：它证明「遮蔽到位」，不阻止越读。
真正的隔离手段见 ADR-0006 §2 的轻量档机制清单（工具层写集 + 评分目录权限位 +
独立评分进程 + 路径可达性探针）—— 探针只覆盖其中最后一项。
"""

from __future__ import annotations

from dataclasses import dataclass, field

#: 禁用臂（叠加层必须被摘除）。
DISABLED_ARMS = frozenset({"W0", "W1"})

#: 判据类与运行数据类文件：solver **不可读**。
REQUIRED_UNREADABLE: tuple[str, ...] = (
    "~/.local/share/rddf-harness/arms/**",
    "harness/path-config.yaml",
    "harness/criteria/**",
    "harness/eval/audits/**",
)

#: 运行数据（臂索引）：solver **不可写**（否则可自报/篡改臂标签）。
REQUIRED_NOT_WRITABLE: tuple[str, ...] = (
    "~/.local/share/rddf-harness/arms/**",
)


@dataclass
class Environment:
    skill_names: tuple[str, ...]
    rdd_call_success_count: int
    unknown_skill_probe_result: str
    rddf_on_path: bool
    skill_links_present: bool = False
    overlay_lib_present: bool = False
    env_injected: bool = False
    unreadable_paths: tuple[str, ...] = ()
    writable_paths: tuple[str, ...] = ()


@dataclass
class Report:
    arm: str
    violations: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not self.violations


def _rdd_skills(env: Environment) -> list[str]:
    return [name for name in env.skill_names if name.startswith("rdd-")]


def _check_paths(env: Environment, report: Report) -> None:
    for path in REQUIRED_UNREADABLE:
        if path not in env.unreadable_paths:
            report.violations.append(f"路径对 solver 可读（应不可读）: {path}")
    for path in REQUIRED_NOT_WRITABLE:
        if path in env.writable_paths:
            report.violations.append(f"路径对 solver 可写（应不可写）: {path}")


def probe(env: Environment, *, arm: str) -> Report:
    report = Report(arm=arm)
    rdd_present = bool(_rdd_skills(env))
    if arm in DISABLED_ARMS:
        if env.rdd_call_success_count != 0:
            report.violations.append(
                f"rdd-* 成功调用数 = {env.rdd_call_success_count}（应为 0）"
            )
        if rdd_present:
            report.violations.append(f"可用 skill 列表仍含 rdd-*: {_rdd_skills(env)}")
        if env.unknown_skill_probe_result != "unknown-skill":
            report.violations.append(
                f"尝试调用 rdd-* 返回 {env.unknown_skill_probe_result!r}（应为 unknown-skill）"
            )
        if env.skill_links_present:
            report.violations.append("遮蔽对象 1 仍在: ~/.agents/skills/rdd-* 软链")
        if env.overlay_lib_present:
            report.violations.append("遮蔽对象 2 仍在: ~/.agents/skills/_lib 或 rdd-workflow")
        if env.rddf_on_path:
            report.violations.append("遮蔽对象 3 仍在: rddf 在 PATH")
        if env.env_injected:
            report.violations.append("遮蔽对象 4 仍在: PYTHONPATH / RDD_WORKFLOW_REPO 已注入")
    else:
        if not rdd_present:
            report.violations.append("启用臂却查不到任何 rdd-* skill")
        if env.rdd_call_success_count <= 0:
            report.violations.append("启用臂的 rdd-* 成功调用数为 0")
        if not env.skill_links_present:
            report.violations.append("启用臂缺遮蔽对象 1: ~/.agents/skills/rdd-* 软链")
        if not env.overlay_lib_present:
            report.violations.append("启用臂缺遮蔽对象 2: ~/.agents/skills/_lib / rdd-workflow")
        if env.rddf_on_path is not True:
            report.violations.append("启用臂的 PATH 上没有 rddf")
        if env.env_injected is not True:
            report.violations.append("启用臂未注入 PYTHONPATH / RDD_WORKFLOW_REPO")
    _check_paths(env, report)
    return report
