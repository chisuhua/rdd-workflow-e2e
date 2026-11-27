import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from harness import trace  # noqa: E402


def unit(incomplete=0, cost=1.0):
    return {"trace_incomplete": incomplete, "cost": cost}


class CompletenessTest(unittest.TestCase):
    def test_three_rates(self):
        units = [unit(0), unit(1), unit(0, cost=None)]
        report = trace.completeness(units, torn_lines=2)
        self.assertAlmostEqual(report["trace_incomplete_rate"], 1 / 3)
        self.assertEqual(report["torn_lines"], 2)
        self.assertAlmostEqual(report["cost_coverage"], 2 / 3)
        self.assertEqual(report["units"], 3)

    def test_warning_above_five_percent(self):
        report = trace.completeness([unit(1)] + [unit(0)] * 9, torn_lines=0)
        self.assertTrue(report["warn"])  # 10% > 5%

    def test_no_warning_at_exactly_five_percent(self):
        report = trace.completeness([unit(1)] + [unit(0)] * 19, torn_lines=0)
        self.assertFalse(report["warn"])  # 恰好 5%，阈值是「超过」

    def test_empty_units(self):
        report = trace.completeness([], torn_lines=0)
        self.assertEqual(report["units"], 0)
        self.assertEqual(report["trace_incomplete_rate"], 0.0)
        self.assertEqual(report["cost_coverage"], 0.0)
        self.assertFalse(report["warn"])

    def test_granularity_breakpoint_is_declared(self):
        self.assertEqual(trace.GRANULARITY, "unit")
        self.assertIn("不可拼接", trace.GRANULARITY_NOTE)
