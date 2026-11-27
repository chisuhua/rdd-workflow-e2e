"""unit trace 投影（ADR-0002 合同）。

一行 = 一个 unit `(session_id, round_index)`（NDJSON）。

## unit 推导规则（ADR-0002 决策 1，**写死**）

- `round_index` 从 **0** 开始；
- **round 0 = 首个 `idle` 之前的那一轮**（预-idle 的消息不被单独切分成新 unit，由首个 `idle` 收尾）；
- 此后在**每次「`idle` 之后的 `user` 消息」处递增**（每个 user-after-idle 开一个新 round）；
- 没有 `idle` 时只有一个**未完（open-ended）** 的 round 0；
- resume 产生新 unit，并通过 `resume_of` 关联（round_index 从 0 重新计）。

## 落点

`~/.local/share/rddf-harness/traces/<run>/trace.jsonl`。
**不是** ADR-0002 决策 4 的 `traces/delegate-<session>.jsonl` —— 那是**跨仓运行时**路径，本 change 不产出。

## 完整性

`trace_incomplete = 1` 的判定（写死、可单测）：
- 「跨仓运行时字段被我方置空」⇒ 恒记 `outcome-blocked`（`outcome` / `host_outcome` / `changed_files` /
  `diff_ref` / `unverified_reason` 显式 `null`，**不做假值填充**）；
- 消息 JSON 解析失败 ⇒ `json-parse-error`；
- 出现未知 message type ⇒ `unknown-message-type`；
- 该 session 无任何消息 ⇒ `no-messages`；
- 关键 session 列缺失（`model` / `time_created` / `time_updated`）⇒ `missing-<列名>`。

⚠ 本 change 期间运行时的 outcome 字段组仍被跨仓阻塞 ⇒ **真实投影的 `trace_incomplete` 率恒为 100%**，
「> 5% 告警」是**真实信号**（trace 尚不完整），不是回归。

口径纪律：本模块是**判据资产**（unit 推导口径决定 E 层一切指标）⇒ 已登记进安全核清单
（`harness/safety-core.manifest`）。
"""

from __future__ import annotations

import json
import os
import re
import sqlite3
from pathlib import Path

TRACE_VERSION = 1

#: 行粒度断点（ADR-0002 决策 1 / ADR-0005 行粒度）。
GRANULARITY = "unit"
GRANULARITY_NOTE = (
    "P0 按 session 计、P1 起按 unit 计 ⇒ 两段趋势**不可拼接**（ADR-0002 决策 1 / ADR-0005 行粒度）"
)

#: `trace_incomplete` 率告警阈值（ADR-0002 决策 6：超过 5% 即告警；「恰好 5%」不告警）。
TRACE_INCOMPLETE_WARN_THRESHOLD = 0.05

#: 跨仓阻塞字段：本 change 恒为 null（不做假值填充）。
BLOCKED_FIELDS = (
    "outcome", "host_outcome", "blocked_reason", "changed_files", "diff_ref", "unverified_reason",
)

#: 已知 message type（未知类型 ⇒ 记 `unknown-message-type`）。
KNOWN_MESSAGE_TYPES = frozenset({
    "user", "assistant", "idle", "system", "error",
    "model-switched", "agent-switched",
})

_SENSITIVE_PATTERNS = (
    ("jwt", re.compile(r"eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}")),
    ("basic", re.compile(r"Basic\s+[A-Za-z0-9+/=]{8,}")),
    ("netrc", re.compile(r"machine\s+\S+\s+login\s+\S+\s+password\s+\S+")),
)


# ── unit 切分 ──────────────────────────────────────────────────────────────

def split_units(messages: list[dict], *, resume_of: str | None = None) -> list[dict]:
    """把消息序列切成 unit 区间。

    `messages` 必须已按**稳定序**排好（调用方用 `session_message` 的行 id 升序）；
    切分只依赖 `row_id` 与 `type`（纯函数，无 IO）。
    """
    units: list[dict] = []
    current: dict | None = None
    seen_idle = False

    def _open(row_id: int) -> dict:
        return {
            "round_index": len(units),
            "row_range": (row_id, row_id),
            "resume_of": resume_of,
        }

    for message in messages:
        mtype = message.get("type")
        row_id = message["row_id"]
        if mtype == "idle":
            seen_idle = True
            if current is not None:
                current["row_range"] = (current["row_range"][0], row_id)
                units.append(current)
                current = None
            continue
        if mtype == "user" and seen_idle:
            if current is not None:
                units.append(current)
            current = _open(row_id)
            continue
        if current is None:
            current = _open(row_id)
        else:
            current["row_range"] = (current["row_range"][0], row_id)
    if current is not None:
        units.append(current)
    return units


# ── 读取（沿用 harness/metrics.py 的兼容策略）──────────────────────────────

def _columns(conn: sqlite3.Connection, table: str) -> set[str]:
    try:
        return {row[1] for row in conn.execute(f'PRAGMA table_info("{table}")')}
    except sqlite3.Error:
        return set()


def _message_sequences(conn: sqlite3.Connection) -> dict[str, list[dict]]:
    """按 session 分组、**按行 id 升序**（排序键写死）的消息序列。"""
    out: dict[str, list[dict]] = {}
    try:
        rows = conn.execute(
            "SELECT id, session_id, type, data FROM session_message ORDER BY id ASC"
        ).fetchall()
    except sqlite3.Error:
        return out
    for row_id, sid, mtype, raw in rows:
        try:
            data = json.loads(raw) if raw else {}
        except Exception:
            data = {"__parse_error__": True}
        out.setdefault(sid, []).append({"row_id": row_id, "type": mtype, "data": data})
    return out


def _tool_calls(window: list[dict]) -> list[dict]:
    calls: list[dict] = []
    for message in window:
        content = (message.get("data") or {}).get("content")
        if not isinstance(content, list):
            continue
        for part in content:
            if not isinstance(part, dict) or part.get("type") != "tool":
                continue
            state = part.get("state") or {}
            error = state.get("error")
            calls.append({
                "name": part.get("name") or "(unknown)",
                "status": "error" if error else "ok",
                "error": (error or {}).get("type") if isinstance(error, dict) else None,
                "target": (state.get("input") or {}).get("path"),
            })
    return calls


def _switches(window: list[dict], mtype: str) -> list[dict]:
    return [m["data"] for m in window if m.get("type") == mtype]


def _incomplete_reasons(messages: list[dict], session: dict) -> list[str]:
    reasons = ["outcome-blocked"]
    if not messages:
        reasons.append("no-messages")
    if any((m.get("data") or {}).get("__parse_error__") for m in messages):
        reasons.append("json-parse-error")
    if any(m.get("type") not in KNOWN_MESSAGE_TYPES for m in messages):
        reasons.append("unknown-message-type")
    for field in ("model", "time_created", "time_updated"):
        if session.get(field) is None:
            reasons.append(f"missing-{field}")
    return reasons


def _model(value) -> dict:
    if isinstance(value, dict):
        return value
    if isinstance(value, str):
        try:
            parsed = json.loads(value)
            return parsed if isinstance(parsed, dict) else {"id": value}
        except Exception:
            return {"id": value}
    return {}


def _duration_ms(start, end) -> int | None:
    if start is None or end is None:
        return None
    return int(end) - int(start)


def project(db_path, *, session_ids: list[str] | None = None) -> list[dict]:
    """从 session DB（只读）投影 unit trace；空输入返回 `[]`，不抛异常。"""
    conn = sqlite3.connect(f"file:{Path(db_path).expanduser()}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    try:
        if not _columns(conn, "session_v2"):
            return []
        sequences = _message_sequences(conn)
        units: list[dict] = []
        for row in conn.execute("SELECT * FROM session_v2").fetchall():
            sid = row["id"]
            if session_ids is not None and sid not in session_ids:
                continue
            session = {key: row[key] for key in row.keys()}
            messages = sequences.get(sid, [])
            if not messages:
                continue
            for unit in split_units(messages):
                low, high = unit["row_range"]
                window = [m for m in messages if low <= m["row_id"] <= high]
                reasons = _incomplete_reasons(window, session)
                cost = session.get("cost")
                units.append({
                    "trace_version": TRACE_VERSION,
                    "unit_id": f"{sid}#{unit['round_index']}",
                    "session_id": sid,
                    "parent_session_id": session.get("parent_id"),
                    "round_index": unit["round_index"],
                    "resume_of": unit.get("resume_of"),
                    "project": {"name": None, "worktree": None, "state_root": None, "sha": None},
                    "agent": session.get("agent"),
                    "role_class": None,
                    "model": _model(session.get("model")),
                    "model_switches": _switches(window, "model-switched"),
                    "agent_switches": _switches(window, "agent-switched"),
                    "dispatch_face": "sync",
                    "outcome_source": "derived",
                    "prompt_hash": None,
                    "prompt_files": [],
                    "prompt_agents": [],
                    "tool_calls": _tool_calls(window),
                    **{field: None for field in BLOCKED_FIELDS},
                    "cost": cost,
                    "cost_coverage": 1 if cost is not None else 0,
                    "tokens": {
                        "input": session.get("tokens_input"),
                        "output": session.get("tokens_output"),
                        "reasoning": session.get("tokens_reasoning"),
                        "cache_read": session.get("tokens_cache_read"),
                        "cache_write": session.get("tokens_cache_write"),
                    },
                    "duration_ms": _duration_ms(session.get("time_created"), session.get("time_updated")),
                    "trace_incomplete": 1 if reasons else 0,
                    "incomplete_reasons": reasons,
                    "torn_lines": 0,
                    "opencode_sha": None,
                    "product_sha": None,
                    "prompt_version": None,
                    "snapshot_sha": None,
                    "time_created": session.get("time_created"),
                    "time_updated": session.get("time_updated"),
                })
        return units
    finally:
        conn.close()


# ── 写出 / 选择器 ─────────────────────────────────────────────────────────

def write_ndjson(units: list[dict], path) -> Path:
    """一行一个 unit；键排序固定 ⇒ 同一输入逐字节一致（幂等）。"""
    out = Path(path)
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "w", encoding="utf-8") as handle:
        for unit in units:
            handle.write(
                json.dumps(unit, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n"
            )
    return out


def selectable(unit: dict) -> bool:
    """unit 是否可进 A/B 配对：`model_switches` 非空 ⇒ 排除（纯函数，不改入参）。"""
    return not unit.get("model_switches")


# ── 脱敏 ──────────────────────────────────────────────────────────────────

def scrub(text: str) -> str:
    """字段级脱敏（ADR-0002 决策 7）：JWT / Basic auth / `.netrc`。"""
    for label, pattern in _SENSITIVE_PATTERNS:
        text = pattern.sub(f"[REDACTED:{label}]", text)
    return text


def keep_prompts() -> bool:
    """`HARNESS_KEEP_PROMPTS=1` 才保留 prompt 原文（且只写本地）。"""
    return os.environ.get("HARNESS_KEEP_PROMPTS") == "1"


def scrub_unit(unit: dict, *, keep_prompts: bool | None = None) -> dict:
    """默认不落 prompt 原文（只留 `prompt_hash`）；显式开启才保留。"""
    keep = scrub_keep_default() if keep_prompts is None else keep_prompts
    out = dict(unit)
    if not keep:
        out.pop("prompt", None)
    return out


def scrub_keep_default() -> bool:
    return keep_prompts()


# ── 完整性 ────────────────────────────────────────────────────────────────

def count_torn_lines(path) -> int:
    """截断末行计数：末行不是合法 JSON **且** 文件不以换行结尾 ⇒ 1（不崩溃、不静默丢弃）。"""
    text = Path(path).read_text(encoding="utf-8")
    if not text or text.endswith("\n"):
        return 0
    last = text.rsplit("\n", 1)[-1]
    try:
        json.loads(last)
        return 0
    except Exception:
        return 1


def completeness(units: list[dict], *, torn_lines: int = 0) -> dict:
    """三项完整性指标（ADR-0002 决策 6）：`trace_incomplete` 率 / `torn_lines` / `cost_coverage`。"""
    total = len(units)
    incomplete = sum(1 for unit in units if unit.get("trace_incomplete"))
    with_cost = sum(1 for unit in units if unit.get("cost") is not None)
    rate = incomplete / total if total else 0.0
    return {
        "granularity": GRANULARITY,
        "units": total,
        "trace_incomplete_rate": rate,
        "torn_lines": int(torn_lines),
        "cost_coverage": with_cost / total if total else 0.0,
        "warn": rate > TRACE_INCOMPLETE_WARN_THRESHOLD,
    }
