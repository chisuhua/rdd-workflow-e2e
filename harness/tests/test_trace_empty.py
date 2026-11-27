import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from harness import trace  # noqa: E402


class EmptyInputTest(unittest.TestCase):
    def test_missing_tables_returns_empty(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = Path(tmp) / "empty.db"
            sqlite3.connect(db).close()
            self.assertEqual(trace.project(db), [])

    def test_session_without_messages_returns_empty(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = Path(tmp) / "t.db"
            conn = sqlite3.connect(db)
            conn.execute("CREATE TABLE session_v2 (id TEXT PRIMARY KEY, agent TEXT)")
            conn.execute("INSERT INTO session_v2 VALUES ('s', 'builder')")
            conn.execute("CREATE TABLE session_message (id INTEGER PRIMARY KEY, session_id TEXT, type TEXT, data TEXT)")
            conn.commit()
            conn.close()
            self.assertEqual(trace.project(db), [])

    def test_session_with_only_user_message_does_not_raise(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = Path(tmp) / "t.db"
            conn = sqlite3.connect(db)
            conn.execute("CREATE TABLE session_v2 (id TEXT PRIMARY KEY, agent TEXT)")
            conn.execute("INSERT INTO session_v2 VALUES ('s', 'builder')")
            conn.execute("CREATE TABLE session_message (id INTEGER PRIMARY KEY, session_id TEXT, type TEXT, data TEXT)")
            conn.execute("INSERT INTO session_message VALUES (1, 's', 'user', '{}')")
            conn.commit()
            conn.close()
            units = trace.project(db)
        self.assertIsInstance(units, list)
        self.assertEqual(len(units), 1)          # 未完的 round 0 也要有输出
        self.assertEqual(units[0]["round_index"], 0)

    def test_missing_columns_degrade_instead_of_crashing(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = Path(tmp) / "t.db"
            conn = sqlite3.connect(db)
            # 只有 id / agent：其余列缺失 ⇒ 降级 + 记 incomplete，而不是抛异常
            conn.execute("CREATE TABLE session_v2 (id TEXT PRIMARY KEY, agent TEXT)")
            conn.execute("INSERT INTO session_v2 VALUES ('s', 'builder')")
            conn.execute("CREATE TABLE session_message (id INTEGER PRIMARY KEY, session_id TEXT, type TEXT, data TEXT)")
            conn.execute("INSERT INTO session_message VALUES (1, 's', 'user', '{}')")
            conn.execute("INSERT INTO session_message VALUES (2, 's', 'idle', '{}')")
            conn.commit()
            conn.close()
            units = trace.project(db)
        self.assertEqual(units[0]["trace_incomplete"], 1)

    def test_manifest_lists_trace_module(self):
        root = Path(__file__).resolve().parents[2]
        text = (root / "harness" / "safety-core.manifest").read_text(encoding="utf-8")
        self.assertIn("repo:harness/trace.py", text)
