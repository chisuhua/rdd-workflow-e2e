"""任务集注册表：case id → 定义文件。

两类来源：
1. **正式 case**：`harness/criteria/cases/<id>.json`。
2. **外部引用**：既有 bats 用例（`tests/integration/**`）—— change-1 期间的过渡来源，
   供归属声明的「证据集」列引用（ADR-0007 决策 4：证据集 = 支撑该阶段判据的 case id）。

证据集里的 id 解析不到 ⇒ 判红（ADR-0007 Verification：「证据集列的 case id 均可解析到
任务集内的实际 case」）。空任务集不算矛盾：正式 case 为零时只暴露外部引用，
lint 据此决定「可解析」是否成立，而不是同时要求非空。
"""

from __future__ import annotations

import json
from pathlib import Path

#: 既有 bats 用例的外部引用 id → 文件路径（相对仓库根）。
#: 粒度是**用例族**（一个 id 指向一个 bats 文件）；cap 族落地后改为精确到单个 case。
LEGACY_CS_CASES: dict[str, str] = {
    "cs-e1": "tests/integration/test_independent_build_session.bats",
    "cs-e2": "tests/integration/test_independent_build_session.bats",
    "cs-e3": "tests/integration/test_role_gate_runtime.bats",
    "cs-e4": "tests/integration/test_commit_gate_runtime.bats",
    "cs-e5": "tests/integration/test_push_gate_runtime.bats",
    "cs-e6": "tests/integration/test_external_project_smoke.bats",
    "cs-rdd-1": "tests/integration/test_full_workflow_e2e.bats",
    "cs-rdd-2": "tests/integration/test_rddf_cli_all_subcommands.bats",
}


class UnknownCaseId(KeyError):
    """证据集里出现解析不到的 case id。"""


class Registry:
    def __init__(self, cases_dir: Path | None) -> None:
        self._cases_dir = cases_dir
        self._formal: dict[str, Path] = {}
        if cases_dir and cases_dir.is_dir():
            for path in sorted(cases_dir.glob("*.json")):
                self._formal[path.stem] = path

    def ids(self) -> list[str]:
        return sorted(set(self._formal) | set(LEGACY_CS_CASES))

    def kind(self, case_id: str) -> str:
        if case_id in self._formal:
            return "formal"
        if case_id in LEGACY_CS_CASES:
            return "external-reference"
        raise UnknownCaseId(case_id)

    def path(self, case_id: str) -> Path:
        if case_id in self._formal:
            return self._formal[case_id]
        if case_id in LEGACY_CS_CASES:
            return Path(LEGACY_CS_CASES[case_id])
        raise UnknownCaseId(case_id)

    def load(self, case_id: str) -> dict:
        if self.kind(case_id) != "formal":
            raise UnknownCaseId(f"{case_id} 不是正式 case，无法加载定义")
        return json.loads(self.path(case_id).read_text(encoding="utf-8"))
