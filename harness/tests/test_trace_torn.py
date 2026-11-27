import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from harness import trace  # noqa: E402


class TornLinesTest(unittest.TestCase):
    def test_truncated_last_line_counts_one_torn(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "t.jsonl"
            p.write_text('{"unit_id":"a"}\n{"unit_id":"b"}\n{"unit_id":"c"', encoding="utf-8")
            self.assertEqual(trace.count_torn_lines(p), 1)

    def test_clean_file_has_zero_torn(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "t.jsonl"
            p.write_text('{"unit_id":"a"}\n{"unit_id":"b"}\n', encoding="utf-8")
            self.assertEqual(trace.count_torn_lines(p), 0)

    def test_empty_file_is_zero(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "t.jsonl"
            p.write_text("", encoding="utf-8")
            self.assertEqual(trace.count_torn_lines(p), 0)

    def test_unterminated_but_valid_last_line_is_not_torn(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "t.jsonl"
            p.write_text('{"unit_id":"a"}\n{"unit_id":"b"}', encoding="utf-8")
            self.assertEqual(trace.count_torn_lines(p), 0)
