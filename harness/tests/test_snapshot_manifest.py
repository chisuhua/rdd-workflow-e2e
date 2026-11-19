import json
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from harness import manifest as manifest_mod  # noqa: E402
from harness.snapshot import create_snapshot  # noqa: E402


class SnapshotTest(unittest.TestCase):
    def test_snapshot_integrity_and_sha(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "src.db"
            conn = sqlite3.connect(src)
            conn.execute("CREATE TABLE t (x INTEGER)")
            conn.executemany("INSERT INTO t VALUES (?)", [(i,) for i in range(100)])
            conn.commit()
            conn.close()

            path, sha = create_snapshot(src, Path(tmp) / "snap")
            self.assertTrue(path.exists())
            self.assertEqual(path.name, f"{sha}.db")

            ro = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
            try:
                self.assertEqual(ro.execute("PRAGMA integrity_check").fetchone()[0], "ok")
                self.assertEqual(ro.execute("SELECT count(*) FROM t").fetchone()[0], 100)
            finally:
                ro.close()


class ManifestTest(unittest.TestCase):
    def test_required_fields(self):
        with tempfile.TemporaryDirectory() as tmp:
            metrics = Path(tmp) / "metrics.json"
            metrics.write_text(json.dumps({"a": 1}), encoding="utf-8")
            m = manifest_mod.build(snapshot_sha256="deadbeef", metrics_path=metrics, generated_at="2026-11-20T00:00:00Z")
            for key in (
                "kind",
                "snapshot_sha256",
                "metrics_version",
                "metrics_sha",
                "generated_at",
                "tool_version",
                "granularity",
            ):
                self.assertIn(key, m)
            self.assertEqual(m["kind"], "metrics")
            self.assertEqual(m["granularity"], "session")
            out = manifest_mod.write(Path(tmp) / "run-manifest.json", m)
            self.assertEqual(json.loads(out.read_text())["snapshot_sha256"], "deadbeef")


if __name__ == "__main__":
    unittest.main()
