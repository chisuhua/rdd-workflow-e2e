import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from harness.eval import arms_index  # noqa: E402


class ArmsIndexTest(unittest.TestCase):
    def test_row_has_five_fields(self):
        with tempfile.TemporaryDirectory() as tmp:
            idx = arms_index.Index(Path(tmp) / "arms" / "index.jsonl")
            idx.append(
                session_id="ses_1", run_id="run_1", arm="W2",
                path_switches=[], prompt_hash="a" * 64,
            )
            row = json.loads(idx.path.read_text(encoding="utf-8").strip())
            self.assertEqual(
                set(row), {"session_id", "run_id", "arm", "path_switches", "prompt_hash"}
            )
            self.assertEqual(row["arm"], "W2")

    def test_arm_label_is_only_in_the_index(self):
        with tempfile.TemporaryDirectory() as tmp:
            idx = arms_index.Index(Path(tmp) / "arms" / "index.jsonl")
            idx.append(session_id="s", run_id="r", arm="W1", path_switches=[], prompt_hash="h")
            text = idx.path.read_text(encoding="utf-8")
            self.assertIn('"arm"', text)
            self.assertNotIn("trace", text)
            self.assertNotIn("session_db", text)

    def test_path_switches_are_preserved(self):
        with tempfile.TemporaryDirectory() as tmp:
            idx = arms_index.Index(Path(tmp) / "arms" / "index.jsonl")
            idx.append(
                session_id="s", run_id="r", arm="W1",
                path_switches=["prompts/build.md"], prompt_hash="h",
            )
            self.assertEqual(idx.rows()[0]["path_switches"], ["prompts/build.md"])

    def test_append_creates_parent_dir(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "nested" / "deeper" / "index.jsonl"
            arms_index.Index(path).append(
                session_id="s", run_id="r", arm="W0", path_switches=[], prompt_hash="h"
            )
            self.assertTrue(path.is_file())
