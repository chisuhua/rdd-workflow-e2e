import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from harness.eval import audit  # noqa: E402


class AuditTest(unittest.TestCase):
    def test_defect_rate_and_coverage(self):
        findings = [
            {"oracle_id": "cap-001", "defect": "过窄"},
            {"oracle_id": "cap-002", "defect": None},
            {"oracle_id": "cap-003", "defect": None},
            {"oracle_id": "cap-004", "defect": None},
        ]
        report = audit.summarize(findings, audited_total=4, sampling_method="全部正式用例 100% 审计")
        # 分母口径（ADR-0005）：judge_defect_rate 的分母 = 被审计的 oracle 数
        self.assertEqual(report.judge_defect_rate, 0.25)
        self.assertEqual(report.audit_coverage, 1.0)
        self.assertEqual(report.sampling_method, "全部正式用例 100% 审计")

    def test_freeze_when_defect_rate_above_ten_percent(self):
        findings = [{"oracle_id": f"cap-{i:03d}", "defect": "过宽"} for i in range(10)]
        findings[0]["defect"] = None
        findings[1]["defect"] = None
        report = audit.summarize(findings, audited_total=10, sampling_method="试点 10 条全审")
        self.assertEqual(report.judge_defect_rate, 0.8)
        self.assertTrue(report.freeze_expansion)

    def test_no_freeze_at_exactly_ten_percent(self):
        findings = [{"oracle_id": f"cap-{i:03d}", "defect": None} for i in range(10)]
        findings[0]["defect"] = "过窄"
        report = audit.summarize(findings, audited_total=10, sampling_method="试点 10 条全审")
        self.assertEqual(report.judge_defect_rate, 0.1)
        self.assertFalse(report.freeze_expansion)

    def test_false_negative_rate_counts_legit_failures(self):
        report = audit.summarize(
            findings=[], audited_total=10, sampling_method="抽样",
            legit_attempts=10, legit_failures=1,
        )
        self.assertEqual(report.false_negative_rate, 0.1)

    def test_sampling_method_is_always_carried(self):
        report = audit.summarize(findings=[], audited_total=0, sampling_method="尚未审计")
        self.assertEqual(report.sampling_method, "尚未审计")
        self.assertEqual(report.judge_defect_rate, 0.0)
        self.assertEqual(report.audit_coverage, 0.0)
