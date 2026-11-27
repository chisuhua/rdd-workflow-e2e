import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from harness.eval import path_config  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[2]


class PathConfigTest(unittest.TestCase):
    def test_repo_declaration_passes_lint(self):
        result = path_config.check(REPO_ROOT / "harness" / "path-config.yaml")
        self.assertEqual(result.errors, [], result.errors)
        self.assertEqual(tuple(result.stages), path_config.EXPECTED_STAGES)

    def test_missing_evidence_strength_is_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "path-config.yaml"
            p.write_text(
                "- 阶段: arch\n  当前承担者: 叠加层\n  移动门槛: 判据层\n  证据集: cs-e1\n",
                encoding="utf-8",
            )
            result = path_config.check(p)
            self.assertTrue(any("证据强度" in e for e in result.errors), result.errors)

    def test_version_is_content_sha256(self):
        path = REPO_ROOT / "harness" / "path-config.yaml"
        self.assertEqual(path_config.version(path), path_config.sha256_file(path))
        self.assertEqual(len(path_config.version(path)), 64)

    def test_tripwire_fires_when_overlay_bears_no_stage(self):
        rows = [
            {
                "阶段": s,
                "当前承担者": "基座",
                "证据强度": "方向性",
                "移动门槛": "判据层",
                "证据集": ["cs-e1"],
            }
            for s in path_config.EXPECTED_STAGES
        ]
        verdict = path_config.tripwire(rows)
        self.assertTrue(verdict.triggered, verdict.reason)
        self.assertIn("退役", verdict.reason)

    def test_tripwire_does_not_fire_when_base_bears_no_stage(self):
        rows = [
            {
                "阶段": s,
                "当前承担者": "叠加层",
                "证据强度": "方向性",
                "移动门槛": "判据层",
                "证据集": ["cs-e1"],
            }
            for s in path_config.EXPECTED_STAGES
        ]
        verdict = path_config.tripwire(rows)
        self.assertFalse(verdict.triggered, verdict.reason)
