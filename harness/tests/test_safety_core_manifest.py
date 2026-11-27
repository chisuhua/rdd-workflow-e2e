import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from harness.eval import safety_core  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[2]
MANIFEST = REPO_ROOT / "harness" / "safety-core.manifest"


class SafetyCoreManifestTest(unittest.TestCase):
    def test_every_repo_entry_matches_something_on_disk(self):
        report = safety_core.audit(REPO_ROOT, MANIFEST)
        unmatched = [e.glob for e in report.entries if e.scope == "repo" and not e.matched_paths]
        self.assertEqual(unmatched, [])

    def test_metrics_single_file_is_covered(self):
        report = safety_core.audit(REPO_ROOT, MANIFEST)
        covered = {
            str(p.relative_to(REPO_ROOT))
            for e in report.entries
            for p in e.matched_paths
        }
        self.assertIn("harness/metrics.py", covered)

    def test_sha256_sidecar_matches(self):
        report = safety_core.audit(REPO_ROOT, MANIFEST)
        self.assertEqual(report.manifest_sha256, report.recorded_sha256)

    def test_manifest_parses_with_reason(self):
        entries = safety_core.parse_manifest("# c\nrepo:harness/metrics.py  单文件\n")
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0].glob, "harness/metrics.py")
        self.assertEqual(entries[0].reason, "单文件")
        self.assertEqual(entries[0].scope, "repo")

    def test_manifest_rejects_line_without_reason(self):
        with self.assertRaises(ValueError):
            safety_core.parse_manifest("repo:harness/metrics.py\n")

    def test_external_entries_are_recorded_but_not_matched(self):
        report = safety_core.audit(REPO_ROOT, MANIFEST)
        external = [e for e in report.entries if e.scope == "external"]
        self.assertTrue(external, "清单必须登记跨仓载体")
        for entry in external:
            self.assertEqual(entry.matched_paths, [])
