import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from harness.eval import taskset  # noqa: E402


class TasksetTest(unittest.TestCase):
    def test_registers_formal_cases_and_legacy_references(self):
        with tempfile.TemporaryDirectory() as tmp:
            cases_dir = Path(tmp) / "cases"
            cases_dir.mkdir()
            (cases_dir / "cap-001.json").write_text(
                json.dumps({"id": "cap-001", "oracle": "file_facts"}), encoding="utf-8"
            )
            reg = taskset.Registry(cases_dir=cases_dir)
            self.assertIn("cap-001", reg.ids())
            self.assertIn("cs-e1", reg.ids())
            self.assertEqual(reg.path("cap-001"), cases_dir / "cap-001.json")
            self.assertEqual(reg.kind("cs-e1"), "external-reference")

    def test_unknown_id_raises(self):
        reg = taskset.Registry(cases_dir=None)
        with self.assertRaises(taskset.UnknownCaseId):
            reg.path("no-such-case")

    def test_legacy_reference_files_exist_in_repo(self):
        reg = taskset.Registry(cases_dir=None)
        repo_root = Path(__file__).resolve().parents[2]
        for case_id in reg.ids():
            target = repo_root / reg.path(case_id)
            self.assertTrue(target.is_file(), f"{case_id} -> {target} 不存在")
