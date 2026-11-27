import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from harness.eval import cases  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[2]
CASES_DIR = REPO_ROOT / "harness" / "criteria" / "cases"


class CasesTest(unittest.TestCase):
    def test_all_cases_declare_intrinsic_flag_and_oracle(self):
        ids = cases.case_ids(CASES_DIR)
        self.assertTrue(ids, "至少要有一个正式 case")
        for case_id in ids:
            case = cases.load(CASES_DIR / f"{case_id}.json")
            self.assertIn("task_orchestration_intrinsic", case, case_id)
            self.assertIn("oracle", case, case_id)
            self.assertNotIn("模型说做完了", str(case["oracle"]), case_id)

    def test_case_structure_is_valid(self):
        for case_id in cases.case_ids(CASES_DIR):
            case = cases.load(CASES_DIR / f"{case_id}.json")
            self.assertEqual(cases.validate_case(case), [], case_id)

    def test_case_carries_its_own_fixture(self):
        """fixture 必须在 case 定义里（pilot-001 的最小修复方向）。"""
        for case_id in cases.case_ids(CASES_DIR):
            case = cases.load(CASES_DIR / f"{case_id}.json")
            self.assertTrue(cases.fixture_files(case), case_id)

    def test_reference_solution_passes(self):
        for case_id in cases.case_ids(CASES_DIR):
            case = cases.load(CASES_DIR / f"{case_id}.json")
            with cases.scratch_workspace(cases.fixture_files(case)) as (workspace, head):
                cases.apply_actions(workspace, case["reference_solution"]["actions"])
                outcome = cases.evaluate(case, workspace, baseline_head=head)
            self.assertTrue(outcome.passed, f"{case_id}: {outcome.detail}")

    def test_alternative_solution_passes(self):
        for case_id in cases.case_ids(CASES_DIR):
            case = cases.load(CASES_DIR / f"{case_id}.json")
            with cases.scratch_workspace(cases.fixture_files(case)) as (workspace, head):
                cases.apply_actions(workspace, case["alternative_solution"]["actions"])
                outcome = cases.evaluate(case, workspace, baseline_head=head)
            self.assertTrue(outcome.passed, f"{case_id}: {outcome.detail}")

    def test_every_mutation_turns_oracle_red(self):
        for case_id in cases.case_ids(CASES_DIR):
            case = cases.load(CASES_DIR / f"{case_id}.json")
            mutations = cases.case_mutations(case)
            self.assertTrue(mutations, case_id)
            for index, mutation in enumerate(mutations, start=1):
                with cases.scratch_workspace(cases.fixture_files(case)) as (workspace, head):
                    cases.apply_actions(workspace, mutation["actions"])
                    outcome = cases.evaluate(case, workspace, baseline_head=head)
                self.assertFalse(outcome.passed, f"{case_id} 的第 {index} 条变异没有变红")

    def test_oracle_is_not_vacuous_without_any_action(self):
        """判别力检查：不做任何动作时 oracle 必须**红**。

        否则「什么都不做」就是合法解 ⇒ 判据恒真（ADR-0005 的恒真检查；本 case 模型下
        「fixture 初始」= 解动作执行前的状态，reference 解之后才应绿）。
        """
        for case_id in cases.case_ids(CASES_DIR):
            case = cases.load(CASES_DIR / f"{case_id}.json")
            with cases.scratch_workspace(cases.fixture_files(case)) as (workspace, head):
                outcome = cases.evaluate(case, workspace, baseline_head=head)
            self.assertFalse(outcome.passed, f"{case_id}: 不做任何动作竟然判绿 ⇒ 判据恒真")

    def test_case_definition_is_unreachable_from_solver_workspace(self):
        with cases.scratch_workspace() as (workspace, _head):
            for case_id in cases.case_ids(CASES_DIR):
                cases.assert_unreachable(CASES_DIR / f"{case_id}.json", [workspace])
