import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from harness import trace  # noqa: E402


class SelectableTest(unittest.TestCase):
    def test_model_switched_unit_is_excluded(self):
        self.assertFalse(trace.selectable({"model_switches": [{"from": "m1", "to": "m2"}]}))
        self.assertTrue(trace.selectable({"model_switches": []}))

    def test_selection_is_pure(self):
        unit = {"model_switches": []}
        trace.selectable(unit)
        self.assertEqual(unit, {"model_switches": []})

    def test_missing_key_is_selectable(self):
        self.assertTrue(trace.selectable({}))
