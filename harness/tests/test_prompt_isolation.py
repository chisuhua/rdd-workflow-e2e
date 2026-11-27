import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from harness.eval import prompt_isolation  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[2]
PROMPTS = REPO_ROOT / "harness" / "eval" / "prompts"


class PromptIsolationTest(unittest.TestCase):
    def test_repo_copy_has_no_role_matrix_markers(self):
        report = prompt_isolation.check(PROMPTS / "w0-base.md", PROMPTS / "markers.yaml")
        self.assertTrue(report.ok, report.found_markers)

    def test_copy_with_marker_is_red(self):
        with tempfile.TemporaryDirectory() as tmp:
            bad = Path(tmp) / "bad.md"
            bad.write_text("【角色: builder | source: user】", encoding="utf-8")
            report = prompt_isolation.check(bad, PROMPTS / "markers.yaml")
            self.assertFalse(report.ok)
            self.assertTrue(report.found_markers)

    def test_markers_manifest_has_version(self):
        report = prompt_isolation.check(PROMPTS / "w0-base.md", PROMPTS / "markers.yaml")
        self.assertTrue(report.version)
        self.assertEqual(len(report.sha256), 64)

    def test_missing_copy_is_red(self):
        report = prompt_isolation.check(PROMPTS / "does-not-exist.md", PROMPTS / "markers.yaml")
        self.assertFalse(report.ok)
