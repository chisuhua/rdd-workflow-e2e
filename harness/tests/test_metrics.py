import json
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from harness.metrics import compute  # noqa: E402


def _mk_db(path: Path) -> None:
    conn = sqlite3.connect(path)
    conn.executescript(
        """
        CREATE TABLE session_v2 (
            id TEXT PRIMARY KEY, parent_id TEXT, agent TEXT, model TEXT,
            cost REAL, tokens_input INTEGER, tokens_output INTEGER,
            tokens_reasoning INTEGER, tokens_cache_read INTEGER,
            tokens_cache_write INTEGER, time_created INTEGER,
            time_updated INTEGER, idle_outcome TEXT
        );
        CREATE TABLE session_message (
            session_id TEXT, type TEXT, data TEXT
        );
        """
    )
    sessions = [
        ("r1", None, "build", '{"id":"m1"}', 1.0, 10, 5, 0, 0, 0, 1000, 2000, "succeeded"),
        ("c1", "r1", "critic", '{"id":"m2"}', 0.5, 20, 7, 0, 0, 0, 1200, 1800, "succeeded"),
        ("r2", None, "oracle", '{"id":"m3"}', None, 1, 1, 0, 0, 0, 3000, 3500, None),
        ("r3", None, "metis", '{"id":"m4"}', 0.25, 2, 2, 0, 0, 0, 4000, 5000, "failed"),
    ]
    conn.executemany("INSERT INTO session_v2 VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)", sessions)

    def assistant(tools):
        return json.dumps({"content": tools})

    edit_tool = {
        "type": "tool",
        "name": "edit",
        "state": {"status": "completed", "input": {"filePath": "/repo/src/a.py"}},
    }
    shell_err = {
        "type": "tool",
        "name": "shell",
        "state": {"status": "error", "error": "boom: command failed", "input": {"command": "x"}},
    }
    read_err = {
        "type": "tool",
        "name": "read",
        "state": {"status": "error", "error": "read fail", "input": {"path": "/repo/src/b.py"}},
    }
    conn.execute("INSERT INTO session_message VALUES (?,?,?)", ("r1", "assistant", assistant([{"type": "text", "text": "hi"}, edit_tool, shell_err])))
    conn.execute("INSERT INTO session_message VALUES (?,?,?)", ("c1", "assistant", assistant([read_err])))
    conn.execute("INSERT INTO session_message VALUES (?,?,?)", ("r2", "user", '{"text":"do it","files":[],"agents":[]}'))
    conn.execute("INSERT INTO session_message VALUES (?,?,?)", ("r3", "assistant", "{not json"))
    conn.commit()
    conn.close()


class MetricsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db = Path(self.tmp.name) / "fixture.db"
        _mk_db(self.db)

    def tearDown(self):
        self.tmp.cleanup()

    def test_session_clusters(self):
        m = compute(self.db)
        self.assertEqual(m["sessions"], {"total": 4, "roots": 3, "children": 1, "orphans": 0})
        self.assertEqual(m["granularity"], "session")

    def test_success_rate_includes_unknown(self):
        m = compute(self.db)
        sr = m["success_rate"]
        self.assertEqual(sr["denominator"], 3)
        self.assertEqual(sr["unknown"], 1)
        self.assertAlmostEqual(sr["value"], 1 / 3, places=4)
        self.assertAlmostEqual(sr["value_excluding_unknown"], 1 / 2, places=4)
        self.assertAlmostEqual(m["unknown_rate"], 1 / 3, places=4)

    def test_cost_aggregation_and_coverage(self):
        m = compute(self.db)
        self.assertAlmostEqual(m["cost"]["total"], 1.75, places=6)
        # 3 个 session 有 cost（r1/c1/r3），共 4 个
        self.assertAlmostEqual(m["cost"]["coverage"], 0.75, places=4)

    def test_child_tokens_folded_into_root(self):
        m = compute(self.db)
        self.assertEqual(m["tokens"]["input"], 33)  # 10+20+1+2
        self.assertEqual(m["tokens"]["output"], 15)  # 5+7+1+2

    def test_tool_error_rate_and_targets(self):
        m = compute(self.db)
        self.assertEqual(m["tools"]["calls"], 3)
        self.assertEqual(m["tools"]["errors"], 2)
        self.assertAlmostEqual(m["tools"]["error_rate"], 2 / 3, places=4)
        self.assertEqual(m["error_classes"], {"string": 2})
        # 保守口径：未分类错误计入执行失败（2/3），权限拒绝不计入
        self.assertAlmostEqual(m["tool_execution_error_rate"], 2 / 3, places=4)
        self.assertEqual(m["permission_denied"], 0)
        self.assertEqual(m["write_targets"]["count"], 1)
        self.assertEqual(m["write_targets"]["top"][0]["key"], "repo/src/a.py")

    def test_corrupt_json_counted_not_crash(self):
        m = compute(self.db)
        self.assertEqual(m["parse_errors"], 1)

    def test_deterministic(self):
        a = json.dumps(compute(self.db), sort_keys=True)
        b = json.dumps(compute(self.db), sort_keys=True)
        self.assertEqual(a, b)

    def test_by_agent(self):
        m = compute(self.db)
        self.assertEqual(m["by_agent"]["build"]["sessions"], 1)
        self.assertEqual(m["by_agent"]["build"]["succeeded"], 1)
        self.assertEqual(m["by_agent"]["metis"]["failed"], 1)
        # 子会话按自己的 agent 计入 by_agent，但不计入 root_by_agent
        self.assertEqual(m["by_agent"]["critic"]["sessions"], 1)
        self.assertNotIn("critic", m["root_by_agent"])
        self.assertEqual(m["root_by_agent"]["build"]["roots"], 1)


if __name__ == "__main__":
    unittest.main()
