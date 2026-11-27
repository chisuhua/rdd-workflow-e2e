import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from harness.eval import audit  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[2]
AUDIT_DIR = REPO_ROOT / "harness" / "eval" / "audits"
PILOT_FILES = sorted(AUDIT_DIR.glob("pilot-*.json"))


class AuditRecordTest(unittest.TestCase):
    def test_at_least_one_pilot_exists(self):
        self.assertTrue(PILOT_FILES, "至少要有一轮审计记录")

    def test_each_pilot_declares_its_shape(self):
        for path in PILOT_FILES:
            data = json.loads(path.read_text(encoding="utf-8"))
            self.assertTrue(data["pilot"], path.name)
            self.assertTrue(data["sampling_method"], path.name)
            self.assertTrue(data["auditor"], path.name)
            self.assertIn("defect_rate_threshold", data, path.name)

    def test_each_pilot_findings_are_well_formed(self):
        for path in PILOT_FILES:
            data = json.loads(path.read_text(encoding="utf-8"))
            self.assertTrue(data["findings"], path.name)
            allowed = {None, "过窄", "过宽", "可绕过", "依赖环境"}
            for finding in data["findings"]:
                self.assertIn(finding.get("defect"), allowed, f"{path.name}: {finding}")
                self.assertTrue(finding.get("oracle_id"), f"{path.name}: {finding}")
                self.assertTrue(finding.get("reason"), f"{path.name}: {finding}")

    def test_auditor_is_not_the_author(self):
        for path in PILOT_FILES:
            data = json.loads(path.read_text(encoding="utf-8"))
            self.assertTrue(data["auditor"], path.name)
            self.assertNotEqual(data["auditor"], data["author_of_cases"], path.name)

    def test_recorded_rates_match_the_recomputation(self):
        for path in PILOT_FILES:
            data = json.loads(path.read_text(encoding="utf-8"))
            report = audit.summarize(
                data["findings"],
                audited_total=len(data["findings"]),
                sampling_method=data["sampling_method"],
            )
            self.assertEqual(report.judge_defect_rate, data["judge_defect_rate"], path.name)
            self.assertEqual(report.audit_coverage, data["audit_coverage"], path.name)
            self.assertEqual(report.false_negative_rate, data["false_negative_rate"], path.name)

    def test_report_carries_the_three_rates_and_the_freeze_decision(self):
        for path in PILOT_FILES:
            data = json.loads(path.read_text(encoding="utf-8"))
            report = audit.summarize(
                data["findings"],
                audited_total=len(data["findings"]),
                sampling_method=data["sampling_method"],
            )
            text = (AUDIT_DIR / f"{data['pilot']}.md").read_text(encoding="utf-8")
            self.assertIn(f"judge_defect_rate: {report.judge_defect_rate}", text, path.name)
            self.assertIn(f"audit_coverage: {report.audit_coverage}", text, path.name)
            self.assertIn(f"false_negative_rate: {report.false_negative_rate}", text, path.name)
            self.assertIn("冻结", text, path.name)

    def test_freeze_decision_is_consistent_between_json_and_report(self):
        for path in PILOT_FILES:
            data = json.loads(path.read_text(encoding="utf-8"))
            report = audit.summarize(
                data["findings"],
                audited_total=len(data["findings"]),
                sampling_method=data["sampling_method"],
            )
            self.assertEqual(bool(data.get("freeze_expansion")), report.freeze_expansion, path.name)
            text = (AUDIT_DIR / f"{data['pilot']}.md").read_text(encoding="utf-8")
            self.assertIn("冻结" if report.freeze_expansion else "不冻结", text, path.name)

    def test_first_pilot_covered_ten_oracles(self):
        data = json.loads((AUDIT_DIR / "pilot-001.json").read_text(encoding="utf-8"))
        self.assertEqual(len(data["findings"]), 10)
        self.assertEqual(data["frame_size"], 10)
