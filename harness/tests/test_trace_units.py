import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from harness import trace  # noqa: E402
from harness.tests.test_trace_fields import make_db  # noqa: E402


def msg(mtype, rid, payload=None):
    return {"row_id": rid, "type": mtype, "data": payload or {}}


class SplitUnitsTest(unittest.TestCase):
    def test_round0_covers_first_turn_up_to_first_idle(self):
        """ADR-0002 决策 1：round_index 从 0 开始；首个 idle 之前**不切分**出新 unit
        （预-idle 消息属于 round 0，round 0 由首个 idle 收尾）。"""
        units = trace.split_units([msg("user", 1), msg("assistant", 2), msg("idle", 3)])
        self.assertEqual([u["round_index"] for u in units], [0])
        self.assertEqual(units[0]["row_range"], (1, 3))

    def test_round_increments_at_user_after_idle(self):
        messages = [
            msg("user", 1), msg("assistant", 2), msg("idle", 3),   # round 0
            msg("user", 4), msg("assistant", 5), msg("idle", 6),   # round 1
            msg("user", 7), msg("assistant", 8),                    # round 2（尚无 idle）
        ]
        units = trace.split_units(messages)
        self.assertEqual([u["round_index"] for u in units], [0, 1, 2])
        self.assertEqual(units[0]["row_range"], (1, 3))
        self.assertEqual(units[1]["row_range"], (4, 6))
        self.assertEqual(units[2]["row_range"], (7, 8))

    def test_no_idle_yields_single_open_unit(self):
        """没有任何 idle ⇒ 只有一个未完（open-ended）的 round 0，而不是 0 个 unit。"""
        units = trace.split_units([msg("user", 1), msg("assistant", 2)])
        self.assertEqual(len(units), 1)
        self.assertEqual(units[0]["round_index"], 0)
        self.assertEqual(units[0]["row_range"], (1, 2))

    def test_resume_produces_new_unit_with_resume_of(self):
        first = trace.split_units([msg("user", 1), msg("idle", 2)])
        resumed = trace.split_units([msg("user", 3), msg("idle", 4)], resume_of="ses_1")
        self.assertEqual([u["round_index"] for u in first], [0])
        self.assertEqual(resumed[-1]["resume_of"], "ses_1")
        self.assertEqual(resumed[-1]["round_index"], 0)  # resume 从 0 重新计

    def test_projection_is_byte_identical_across_runs(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            db = Path(tmp) / "t.db"
            make_db(db, messages=[(1, "user", {}), (2, "idle", {})])
            a = Path(tmp) / "a.jsonl"
            b = Path(tmp) / "b.jsonl"
            trace.write_ndjson(trace.project(db), a)
            trace.write_ndjson(trace.project(db), b)
            self.assertEqual(a.read_bytes(), b.read_bytes())

    def test_ndjson_is_one_unit_per_line(self):
        import tempfile
        import json

        with tempfile.TemporaryDirectory() as tmp:
            db = Path(tmp) / "t.db"
            make_db(db, messages=[(1, "user", {}), (2, "idle", {}), (3, "user", {}), (4, "idle", {})])
            out = Path(tmp) / "t.jsonl"
            trace.write_ndjson(trace.project(db), out)
            lines = [ln for ln in out.read_text(encoding="utf-8").splitlines() if ln]
        self.assertEqual(len(lines), 2)
        for line in lines:
            self.assertEqual(json.loads(line)["trace_version"], 1)
