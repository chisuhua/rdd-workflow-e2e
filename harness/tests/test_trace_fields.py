import json
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from harness import trace  # noqa: E402

REQUIRED = [
    # 标识
    "trace_version", "unit_id", "session_id", "parent_session_id", "round_index", "resume_of",
    # 项目
    "project",
    # 执行者
    "agent", "role_class", "model", "model_switches", "agent_switches",
    # 派发面
    "dispatch_face", "outcome_source",
    # 输入
    "prompt_hash", "prompt_files", "prompt_agents",
    # 轨迹
    "tool_calls",
    # 结果
    "outcome", "host_outcome", "blocked_reason", "changed_files", "diff_ref", "unverified_reason",
    # 成本
    "cost", "cost_coverage", "tokens", "duration_ms",
    # 完整性
    "trace_incomplete", "torn_lines",
    # 环境
    "opencode_sha", "product_sha", "prompt_version", "snapshot_sha", "time_created", "time_updated",
]

BLOCKED = ["outcome", "host_outcome", "changed_files", "diff_ref", "unverified_reason"]


def make_db(path, *, messages, session=("ses_1", None, "builder", '{"id":"m1"}', 0.5)):
    sid, parent, agent, model, cost = session
    conn = sqlite3.connect(path)
    conn.execute(
        "CREATE TABLE session_v2 (id TEXT PRIMARY KEY, parent_id TEXT, agent TEXT, model TEXT,"
        " cost REAL, tokens_input INTEGER, tokens_output INTEGER, time_created INTEGER,"
        " time_updated INTEGER, idle_outcome TEXT)"
    )
    conn.execute(
        "INSERT INTO session_v2 VALUES (?, ?, ?, ?, ?, 10, 20, 100, 200, 'idle')",
        (sid, parent, agent, model, cost),
    )
    conn.execute(
        "CREATE TABLE session_message (id INTEGER PRIMARY KEY, session_id TEXT, type TEXT, data TEXT)"
    )
    for rid, mtype, payload in messages:
        conn.execute(
            "INSERT INTO session_message (id, session_id, type, data) VALUES (?, ?, ?, ?)",
            (rid, sid, mtype, json.dumps(payload)),
        )
    conn.commit()
    conn.close()
    return path


class TraceFieldsTest(unittest.TestCase):
    def test_all_fields_present_and_versioned(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = make_db(Path(tmp) / "t.db",
                         messages=[(1, "user", {}), (2, "assistant", {}), (3, "idle", {})])
            units = trace.project(db)
        self.assertEqual(len(units), 1)
        unit = units[0]
        self.assertEqual(unit["trace_version"], 1)
        for field in REQUIRED:
            self.assertIn(field, unit, field)
        self.assertEqual(unit["unit_id"], "ses_1#0")
        self.assertIsInstance(unit["project"], dict)
        self.assertEqual(set(unit["project"]), {"name", "worktree", "state_root", "sha"})
        self.assertIsInstance(unit["tokens"], dict)
        self.assertEqual(set(unit["tokens"]),
                         {"input", "output", "reasoning", "cache_read", "cache_write"})

    def test_blocked_fields_are_null_and_mark_incomplete(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = make_db(Path(tmp) / "t.db", messages=[(1, "user", {}), (2, "idle", {})])
            units = trace.project(db)
        for field in BLOCKED:
            self.assertIsNone(units[0][field], field)
        self.assertEqual(units[0]["trace_incomplete"], 1)
        self.assertIn("outcome-blocked", units[0]["incomplete_reasons"])

    def test_tool_calls_are_extracted(self):
        payload = {"content": [{"type": "tool", "name": "edit",
                                "state": {"error": None, "input": {"path": "a.py"}}}]}
        with tempfile.TemporaryDirectory() as tmp:
            db = make_db(Path(tmp) / "t.db",
                         messages=[(1, "user", {}), (2, "assistant", payload), (3, "idle", {})])
            units = trace.project(db)
        self.assertEqual(units[0]["tool_calls"][0]["name"], "edit")
        self.assertEqual(units[0]["tool_calls"][0]["status"], "ok")
        self.assertEqual(units[0]["tool_calls"][0]["target"], "a.py")

    def test_switches_are_captured(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = make_db(Path(tmp) / "t.db", messages=[
                (1, "user", {}),
                (2, "model-switched", {"from": "m1", "to": "m2"}),
                (3, "idle", {}),
            ])
            units = trace.project(db)
        self.assertEqual(units[0]["model_switches"], [{"from": "m1", "to": "m2"}])

    def test_json_parse_error_marks_incomplete(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = Path(tmp) / "t.db"
            conn = sqlite3.connect(db)
            conn.execute("CREATE TABLE session_v2 (id TEXT PRIMARY KEY, agent TEXT)")
            conn.execute("INSERT INTO session_v2 VALUES ('s', 'builder')")
            conn.execute("CREATE TABLE session_message (id INTEGER PRIMARY KEY, session_id TEXT, type TEXT, data TEXT)")
            conn.execute("INSERT INTO session_message VALUES (1, 's', 'user', '{broken')")
            conn.execute("INSERT INTO session_message VALUES (2, 's', 'idle', '{}')")
            conn.commit()
            conn.close()
            units = trace.project(db)
        self.assertEqual(units[0]["trace_incomplete"], 1)
        self.assertIn("json-parse-error", units[0]["incomplete_reasons"])

    def test_unknown_message_type_marks_incomplete(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = make_db(Path(tmp) / "t.db",
                         messages=[(1, "user", {}), (2, "brand-new-type", {}), (3, "idle", {})])
            units = trace.project(db)
        self.assertIn("unknown-message-type", units[0]["incomplete_reasons"])
