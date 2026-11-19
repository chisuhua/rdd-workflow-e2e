"""P0 指标：从离线快照只读计算。

口径（ADR-0005 §1）：一行 = 一个**根 session**；子会话按 parent_id 归并到根。
所有率、成本、token、时延均按根 session 计；`idle_outcome` 为 null 归 unknown 并计入分母。
"""

from __future__ import annotations

import json
import os
import sqlite3
import statistics
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

from . import METRICS_VERSION

TOOL_WRITE_NAMES = {"edit", "write", "multiedit", "patch"}


def _iso(ms: int | None) -> str | None:
    if not ms:
        return None
    return datetime.fromtimestamp(ms / 1000, tz=timezone.utc).isoformat()


def _columns(conn: sqlite3.Connection, table: str) -> set[str]:
    return {row[1] for row in conn.execute(f'PRAGMA table_info("{table}")')}


def _pick(cols: set[str], *names: str) -> str | None:
    for n in names:
        if n in cols:
            return n
    return None


def _normalize_error(err: Any) -> str:
    text = err if isinstance(err, str) else json.dumps(err, ensure_ascii=False, sort_keys=True)
    text = " ".join(text.split())
    return text[:120]


def _percentile(values: list[int], q: float) -> int | None:
    if not values:
        return None
    s = sorted(values)
    # nearest-rank
    idx = max(0, min(len(s) - 1, int(round((len(s) - 1) * q))))
    return s[idx]


def _slug_target(path: str) -> str:
    """把绝对路径折叠成顶层目录，便于聚合（保留最多 4 段）。"""
    if not path:
        return "(empty)"
    parts = [p for p in path.split(os.sep) if p]
    if len(parts) <= 4:
        return "/".join(parts)
    return "/".join(parts[:4]) + "/…"


def compute(db_path: str | os.PathLike[str]) -> dict[str, Any]:
    conn = sqlite3.connect(f"file:{Path(db_path).expanduser()}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    try:
        sess_cols = _columns(conn, "session_v2")
        if not sess_cols:
            raise RuntimeError("session_v2 表不存在（不是 opencode DB？）")
        col_id = "id"
        col_parent = _pick(sess_cols, "parent_id")
        col_agent = _pick(sess_cols, "agent")
        col_model = _pick(sess_cols, "model")
        col_cost = _pick(sess_cols, "cost")
        col_tin = _pick(sess_cols, "tokens_input")
        col_tout = _pick(sess_cols, "tokens_output")
        col_treason = _pick(sess_cols, "tokens_reasoning")
        col_tcache_r = _pick(sess_cols, "tokens_cache_read")
        col_tcache_w = _pick(sess_cols, "tokens_cache_write")
        col_tc = _pick(sess_cols, "time_created")
        col_tu = _pick(sess_cols, "time_updated")
        col_outcome = _pick(sess_cols, "idle_outcome")

        def sel(name: str | None) -> str:
            return f'"{name}"' if name else "NULL"

        rows = conn.execute(
            "SELECT "
            f'{sel(col_id)} AS id, {sel(col_parent)} AS parent_id, {sel(col_agent)} AS agent, '
            f'{sel(col_model)} AS model, {sel(col_cost)} AS cost, '
            f'{sel(col_tin)} AS tokens_input, {sel(col_tout)} AS tokens_output, '
            f'{sel(col_treason)} AS tokens_reasoning, {sel(col_tcache_r)} AS tokens_cache_read, '
            f'{sel(col_tcache_w)} AS tokens_cache_write, '
            f'{sel(col_tc)} AS time_created, {sel(col_tu)} AS time_updated, '
            f'{sel(col_outcome)} AS idle_outcome '
            "FROM session_v2"
        ).fetchall()

        sessions: dict[str, dict[str, Any]] = {}
        for r in rows:
            sid = r["id"]
            model = r["model"]
            if isinstance(model, str):
                try:
                    model = json.loads(model)
                except Exception:
                    model = {"id": model}
            sessions[sid] = {
                "id": sid,
                "parent_id": r["parent_id"] or None,
                "agent": r["agent"] or "(none)",
                "model": model or {},
                "cost": r["cost"],
                "tokens_input": r["tokens_input"] or 0,
                "tokens_output": r["tokens_output"] or 0,
                "tokens_reasoning": r["tokens_reasoning"] or 0,
                "tokens_cache_read": r["tokens_cache_read"] or 0,
                "tokens_cache_write": r["tokens_cache_write"] or 0,
                "time_created": r["time_created"],
                "time_updated": r["time_updated"],
                "outcome": r["idle_outcome"] or "unknown",
            }

        # 根/子会话簇：BFS（防环）
        children: dict[str, list[str]] = defaultdict(list)
        roots: list[str] = []
        for sid, s in sessions.items():
            pid = s["parent_id"]
            if pid and pid in sessions and pid != sid:
                children[pid].append(sid)
            else:
                roots.append(sid)

        cluster_of: dict[str, str] = {}
        depth_of: dict[str, int] = {}
        for root in roots:
            queue = [(root, 0)]
            while queue:
                sid, depth = queue.pop(0)
                if sid in cluster_of:
                    continue
                cluster_of[sid] = root
                depth_of[sid] = depth
                for child in children.get(sid, []):
                    if child not in cluster_of:
                        queue.append((child, depth + 1))

        # 孤儿（父不在表中）自成根
        roots = sorted(set(cluster_of.values()))
        orphan = [sid for sid in sessions if sid not in cluster_of]
        for sid in orphan:
            cluster_of[sid] = sid
            depth_of[sid] = 0
            roots.append(sid)

        # 每个簇的聚合
        clusters: dict[str, dict[str, Any]] = {
            r: {
                "agent": sessions[r]["agent"],
                "model": sessions[r]["model"],
                "outcome": sessions[r]["outcome"],
                "cost": 0.0,
                "cost_sessions": 0,
                "members": 0,
                "tokens_input": 0,
                "tokens_output": 0,
                "tokens_reasoning": 0,
                "tokens_cache_read": 0,
                "tokens_cache_write": 0,
                "start": None,
                "end": None,
                "max_depth": 0,
            }
            for r in roots
        }
        for sid, s in sessions.items():
            c = clusters[cluster_of[sid]]
            c["members"] += 1
            if s["cost"] is not None:
                c["cost"] += float(s["cost"])
                c["cost_sessions"] += 1
            for k in (
                "tokens_input",
                "tokens_output",
                "tokens_reasoning",
                "tokens_cache_read",
                "tokens_cache_write",
            ):
                c[k] += s[k]
            if s["time_created"]:
                c["start"] = s["time_created"] if c["start"] is None else min(c["start"], s["time_created"])
            if s["time_updated"]:
                c["end"] = s["time_updated"] if c["end"] is None else max(c["end"], s["time_updated"])
            c["max_depth"] = max(c["max_depth"], depth_of[sid])

        # 消息与工具调用
        msg_cols = _columns(conn, "session_message")
        has_msgs = bool(msg_cols)
        tool_calls = 0
        tool_errors = 0
        tool_counter: Counter[str] = Counter()
        tool_error_counter: Counter[str] = Counter()
        error_classes: Counter[str] = Counter()
        write_targets: Counter[str] = Counter()
        failure_modes: Counter[str] = Counter()
        type_counter: Counter[str] = Counter()
        parse_errors = 0

        if has_msgs:
            cur = conn.execute("SELECT session_id, type, data FROM session_message")
            for sid, mtype, raw in cur:
                if mtype:
                    type_counter[mtype] += 1
                if not raw or sid not in cluster_of:
                    continue
                try:
                    payload = json.loads(raw)
                except Exception:
                    parse_errors += 1
                    continue
                content = payload.get("content")
                if not isinstance(content, list):
                    continue
                for part in content:
                    if not isinstance(part, dict) or part.get("type") != "tool":
                        continue
                    name = part.get("name") or "(unknown)"
                    tool_calls += 1
                    tool_counter[name] += 1
                    state = part.get("state") or {}
                    err = state.get("error")
                    if err:
                        tool_errors += 1
                        tool_error_counter[name] += 1
                        if isinstance(err, dict):
                            error_classes[str(err.get("type") or "object")] += 1
                        else:
                            error_classes["string"] += 1
                        failure_modes[f"{name}: {_normalize_error(err)}"] += 1
                    if name in TOOL_WRITE_NAMES:
                        inp = state.get("input") or {}
                        target = inp.get("filePath") or inp.get("path") or ""
                        if target:
                            write_targets[_slug_target(str(target))] += 1

        # 汇总
        outcomes = Counter(c["outcome"] for c in clusters.values())
        denom = sum(outcomes.values())
        success = outcomes.get("succeeded", 0)
        non_unknown = denom - outcomes.get("unknown", 0)
        total_cost = sum(c["cost"] for c in clusters.values())
        cost_sessions = sum(c["cost_sessions"] for c in clusters.values())
        total_sessions = sum(c["members"] for c in clusters.values())

        durations = [
            int(c["end"] - c["start"])
            for c in clusters.values()
            if c["start"] and c["end"] and c["end"] >= c["start"]
        ]

        by_agent: dict[str, dict[str, Any]] = {}
        for s in sessions.values():
            a = by_agent.setdefault(
                s["agent"],
                {"sessions": 0, "succeeded": 0, "failed": 0, "interrupted": 0, "unknown": 0, "cost": 0.0},
            )
            a["sessions"] += 1
            if s["cost"] is not None:
                a["cost"] += float(s["cost"])
            if s["outcome"] in a:
                a[s["outcome"]] += 1
        for a in by_agent.values():
            d = a["sessions"]
            a["success_rate"] = round(a["succeeded"] / d, 4) if d else None

        root_by_agent: dict[str, dict[str, Any]] = {}
        for c in clusters.values():
            a = root_by_agent.setdefault(
                c["agent"],
                {"roots": 0, "succeeded": 0, "failed": 0, "interrupted": 0, "unknown": 0, "cost": 0.0},
            )
            a["roots"] += 1
            a["cost"] += c["cost"]
            if c["outcome"] in a:
                a[c["outcome"]] += 1
        for a in root_by_agent.values():
            d = a["roots"]
            a["success_rate_root"] = round(a["succeeded"] / d, 4) if d else None

        def top(counter: Counter[str], n: int = 20) -> list[dict[str, Any]]:
            return [
                {"key": k, "count": v}
                for k, v in sorted(counter.items(), key=lambda kv: (-kv[1], kv[0]))[:n]
            ]

        window = {
            "start": _iso(min((s["time_created"] for s in sessions.values() if s["time_created"]), default=None)),
            "end": _iso(max((s["time_updated"] for s in sessions.values() if s["time_updated"]), default=None)),
        }

        return {
            "schema": "harness-metrics-v1",
            "metrics_version": METRICS_VERSION,
            "granularity": "session",
            "window": window,
            "sessions": {
                "total": len(sessions),
                "roots": len(clusters),
                "children": len(sessions) - len(clusters),
                "orphans": len(orphan),
            },
            "outcomes": dict(sorted(outcomes.items())),
            "unknown_rate": round(outcomes.get("unknown", 0) / denom, 4) if denom else None,
            "success_rate": {
                "denominator": denom,
                "value": round(success / denom, 4) if denom else None,
                "value_excluding_unknown": round(success / non_unknown, 4) if non_unknown else None,
                "unknown": outcomes.get("unknown", 0),
            },
            "by_agent": dict(sorted(by_agent.items())),
            "root_by_agent": dict(sorted(root_by_agent.items())),
            "cost": {
                "total": round(total_cost, 6),
                "mean_per_root": round(total_cost / len(clusters), 6) if clusters else None,
                "coverage": round(cost_sessions / total_sessions, 4) if total_sessions else None,
            },
            "tokens": {
                "input": sum(c["tokens_input"] for c in clusters.values()),
                "output": sum(c["tokens_output"] for c in clusters.values()),
                "reasoning": sum(c["tokens_reasoning"] for c in clusters.values()),
                "cache_read": sum(c["tokens_cache_read"] for c in clusters.values()),
                "cache_write": sum(c["tokens_cache_write"] for c in clusters.values()),
            },
            "duration_ms": {
                "p50": _percentile(durations, 0.50),
                "p95": _percentile(durations, 0.95),
                "n": len(durations),
            },
            "delegation_depth": dict(sorted(Counter(c["max_depth"] for c in clusters.values()).items())),
            "tools": {
                "calls": tool_calls,
                "errors": tool_errors,
                "error_rate": round(tool_errors / tool_calls, 4) if tool_calls else None,
                "top": top(tool_counter),
                "top_error_tools": top(tool_error_counter),
            },
            "error_classes": dict(sorted(error_classes.items())),
            # 执行失败率 = 1 − (权限拒绝 + 中断 + 供应商故障) / 调用总数
            # 保守口径：未分类错误（string）与 unknown 计入执行失败
            "tool_execution_error_rate": (
                round(
                    (
                        tool_errors
                        - error_classes.get("permission.rejected", 0)
                        - error_classes.get("aborted", 0)
                        - sum(v for k, v in error_classes.items() if k.startswith("provider."))
                    )
                    / tool_calls,
                    4,
                )
                if tool_calls
                else None
            ),
            "permission_denied": error_classes.get("permission.rejected", 0),
            "write_targets": {"count": sum(write_targets.values()), "top": top(write_targets)},
            "failure_modes": top(failure_modes),
            "message_types": dict(sorted(type_counter.items())),
            "parse_errors": parse_errors,
        }
    finally:
        conn.close()
