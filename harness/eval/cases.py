"""case 定义（判据）的加载、oracle 求值与解动作执行。

**边界**：本模块做的是 **oracle 层面的验证**（判据本身是否正确），不是跑 agent。
- reference / alternative solution = 脚本化的动作序列，用来验证「正确解 ⇒ oracle 绿」；
- mutation = 破坏受约束要素的动作序列，用来验证「判据会变红」（变红演练）。

真正的 solver 试跑属 change-2 / runner 层（本期不跑真模型）。

**fixture 收在 case 定义里**（pilot-001 审计的最小修复方向）：fixture 写在测试文件里会
让「case 定义」与「验证它的环境」分家 —— fixture 漂移会连带假红。
"""

from __future__ import annotations

import json
import subprocess
import tempfile
from contextlib import contextmanager
from dataclasses import dataclass, field
from pathlib import Path

from harness.criteria import oracle

CASE_DIR = Path(__file__).resolve().parents[1] / "criteria" / "cases"


@dataclass
class Outcome:
    passed: bool
    checks: list[oracle.CheckResult] = field(default_factory=list)

    @property
    def detail(self) -> str:
        return "; ".join(
            f"{c.name}: {'PASS' if c.passed else 'FAIL'} {c.detail}".strip() for c in self.checks
        )


def load(path: Path) -> dict:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def case_ids(cases_dir: Path | None = None) -> list[str]:
    base = cases_dir or CASE_DIR
    return sorted(p.stem for p in base.glob("*.json"))


def validate_case(case: dict) -> list[str]:
    """结构自检：缺字段 ⇒ 列出错误（不抛异常，便于批量报告）。"""
    errors: list[str] = []
    for field_name in ("id", "title", "task_orchestration_intrinsic", "oracle"):
        if field_name not in case:
            errors.append(f"缺字段: {field_name}")
    spec = case.get("oracle") or {}
    # `exit_nonzero` **禁用**：它要求 oracle 自己跑一条命令 —— 若该命令与被测行为无关，
    # 判据就是恒真（pilot-001 判定 cap-003「可绕过」的根因）。退出码只能由**解动作**产生
    # （`run` + `record`），再由文件事实检查读它。
    if spec.get("kind") != "file_facts":
        errors.append(f"oracle.kind 只允许 file_facts: {spec.get('kind')!r}")
    if spec.get("kind") == "file_facts" and not spec.get("checks"):
        errors.append("file_facts 至少要有一条检查")
    for section in ("reference_solution", "alternative_solution"):
        if section not in case:
            errors.append(f"缺段: {section}")
        elif "actions" not in case[section]:
            errors.append(f"{section} 缺 actions")
    if not case_mutations(case):
        errors.append("至少要有一条变红演练（mutation / mutations）")
    for index, mutation in enumerate(case_mutations(case), start=1):
        if "actions" not in mutation:
            errors.append(f"第 {index} 条 mutation 缺 actions")
    return errors


def case_mutations(case: dict) -> list[dict]:
    """变红演练列表：`mutations`（新）或单条 `mutation`（旧形态，兼容）。"""
    if isinstance(case.get("mutations"), list):
        return list(case["mutations"])
    if isinstance(case.get("mutation"), dict):
        return [case["mutation"]]
    return []


def fixture_files(case: dict) -> dict[str, str]:
    """case 自带的初始文件（初始工作区内容）。"""
    return dict(case.get("fixture") or {})


def apply_actions(workspace: Path, actions: list[dict]) -> None:
    for action in actions:
        kind = action.get("type")
        if kind == "write":
            target = workspace / action["path"]
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(action.get("content", ""), encoding="utf-8")
        elif kind == "delete":
            target = workspace / action["path"]
            if target.exists():
                target.unlink()
        elif kind == "run":
            proc = subprocess.run(
                action["command"], cwd=str(workspace), capture_output=True, text=True, check=False
            )
            record = action.get("record")
            if record:
                # 把退出码**记录**下来 —— 「失败被记为失败」的载体，
                # 而不是让 oracle 去跑一个与被测行为无关的硬编码命令。
                target = workspace / record
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(f"exit={proc.returncode}\n{proc.stdout}", encoding="utf-8")
        else:
            raise ValueError(f"不支持的动作类型: {kind!r}")


def evaluate(case: dict, workspace: Path, *, baseline_head: str | None = None) -> Outcome:
    spec = case["oracle"]
    if spec["kind"] != "file_facts":
        raise ValueError(f"不支持的 oracle 类型: {spec['kind']!r}")
    checks = oracle.file_facts(workspace, spec["checks"], baseline_head=baseline_head)
    return Outcome(passed=all(c.passed for c in checks), checks=checks)


@contextmanager
def scratch_workspace(files: dict[str, str] | None = None):
    """临时 git 工作区（含一次初始提交）⇒ 有基线 HEAD 可比。"""
    with tempfile.TemporaryDirectory() as tmp:
        workspace = Path(tmp)
        for rel, content in (files or {}).items():
            target = workspace / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content, encoding="utf-8")
        subprocess.run(["git", "init", "-q"], cwd=str(workspace), check=True)
        subprocess.run(["git", "config", "user.email", "harness@example.invalid"], cwd=str(workspace), check=True)
        subprocess.run(["git", "config", "user.name", "harness"], cwd=str(workspace), check=True)
        subprocess.run(["git", "add", "-A"], cwd=str(workspace), check=True)
        # `--allow-empty`：空 fixture 也要有基线 HEAD（否则「HEAD 未变」无从比较）
        subprocess.run(
            ["git", "commit", "-q", "--allow-empty", "-m", "baseline"],
            cwd=str(workspace), check=True,
        )
        head = subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=str(workspace), capture_output=True, text=True, check=True
        ).stdout.strip()
        yield workspace, head


def assert_unreachable(case_path: Path, solver_roots: list[Path]) -> None:
    """case 定义对 solver 不可达（ADR-0003 决策 3 的准入项）。

    判据是**路径事实**：case 定义文件不得落在任何 solver 工作区之内。
    """
    resolved = case_path.resolve()
    for root in solver_roots:
        try:
            resolved.relative_to(Path(root).resolve())
        except ValueError:
            continue
        raise AssertionError(f"case 定义对 solver 可达: {resolved} 落在 {root} 内")
