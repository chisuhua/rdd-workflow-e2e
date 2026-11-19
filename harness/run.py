"""CLI：snapshot → metrics → manifest → report。

用法：
    python3 -m harness.run all                  # 默认读 ~/.local/share/opencode/opencode.db
    python3 -m harness.run all --db /path/to/opencode.db --out /path/to/out
    python3 -m harness.run snapshot --db ... --out ...
    python3 -m harness.run metrics --snapshot <db> --out <run-dir>
"""

from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path

from . import METRICS_VERSION, TOOL_VERSION
from .metrics import compute
from .snapshot import create_snapshot
from . import manifest as manifest_mod

DEFAULT_DB = "~/.local/share/opencode/opencode.db"
DEFAULT_OUT = "~/.local/share/rddf-harness"


def _run_dir(out: Path) -> Path:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    run = out / "runs" / stamp
    run.mkdir(parents=True, exist_ok=True)
    return run


def _md_table(headers: list[str], rows: list[list[str]]) -> str:
    lines = ["| " + " | ".join(headers) + " |", "|" + "|".join(["---"] * len(headers)) + "|"]
    for r in rows:
        lines.append("| " + " | ".join(str(x) for x in r) + " |")
    return "\n".join(lines)


def render_report(metrics: dict, manifest: dict) -> str:
    sr = metrics["success_rate"]
    cost = metrics["cost"]
    tools = metrics["tools"]
    out: list[str] = []
    out.append("# Harness P0 指标报告\n")
    out.append(f"- 生成时间：{manifest['generated_at']}")
    out.append(f"- 快照 SHA256：`{manifest['snapshot_sha256']}`")
    out.append(f"- 指标版本：`{metrics['metrics_version']}` / 粒度：`{metrics['granularity']}`")
    out.append(f"- 数据窗口：{metrics['window']['start']} → {metrics['window']['end']}\n")

    out.append("## 口径（可复算前提）\n")
    out.append("- 一行 = 一个根 session；子会话按 `parent_id` 归并到根。")
    out.append("- 成功率分母 = succeeded + failed + interrupted + unknown（`idle_outcome` 为 null 归 unknown）。")
    out.append("- 成本 `sum` 跳过 null，`cost_coverage` = 有成本值的 session / 全部 session。")
    out.append("- 工具错误率 = `state.error` 非空的工具调用 / 工具调用总数；**原始错误率必须与错误类别分布同读**——")
    out.append("  `permission.rejected` 是设计行为（该 agent 无权用该工具），单列，不计入执行失败率。\n")

    out.append("## 总览\n")
    s = metrics["sessions"]
    out.append(_md_table(
        ["项", "值"],
        [
            ["session 总数", s["total"]],
            ["根 session", s["roots"]],
            ["子 session", s["children"]],
            ["孤儿 session（父缺失）", s["orphans"]],
            ["成功率（含 unknown）", sr["value"]],
            ["成功率（剔除 unknown）", sr["value_excluding_unknown"]],
            ["成功率分母", sr["denominator"]],
            ["总成本", cost["total"]],
            ["每根 session 平均成本", cost["mean_per_root"]],
            ["成本覆盖率", cost["coverage"]],
            ["时延 p50 / p95 (ms)", f"{metrics['duration_ms']['p50']} / {metrics['duration_ms']['p95']}"],
            ["工具调用 / 错误 / 原始错误率", f"{tools['calls']} / {tools['errors']} / {tools['error_rate']}"],
            ["执行失败率（去权限拒绝/中断/供应商故障）", metrics.get("tool_execution_error_rate")],
            ["权限拒绝次数（单列，不计入执行失败率）", metrics.get("permission_denied")],
            ["unknown 率（idle_outcome 缺失）", metrics.get("unknown_rate")],
        ],
    ))
    out.append("")

    out.append("## 按 agent（全部 session，含子会话）\n")
    out.append("> `cost` 为该 agent **自身 session** 的成本；簇总成本见下一张表。\n")
    rows = []
    for agent, a in metrics["by_agent"].items():
        rows.append([agent, a["sessions"], a["succeeded"], a["failed"], a["interrupted"], a["unknown"], a["success_rate"], round(a["cost"], 4)])
    out.append(_md_table(["agent", "sessions", "succeeded", "failed", "interrupted", "unknown", "session_success_rate", "cost"], rows))
    out.append("")

    out.append("## 按根 session 的 agent（P0 率口径）\n")
    rows = []
    for agent, a in metrics["root_by_agent"].items():
        rows.append([agent, a["roots"], a["succeeded"], a["failed"], a["interrupted"], a["unknown"], a["success_rate_root"], round(a["cost"], 4)])
    out.append(_md_table(["agent", "roots", "succeeded", "failed", "interrupted", "unknown", "root_success_rate", "cost"], rows))
    out.append("")

    out.append("## 结果分布\n")
    out.append(_md_table(["outcome", "count"], [[k, v] for k, v in metrics["outcomes"].items()]))
    out.append("")

    out.append("## 工具调用 Top 10\n")
    out.append(_md_table(["tool", "calls"], [[t["key"], t["count"]] for t in tools["top"][:10]]))
    out.append("")

    out.append("## 工具错误 Top 10\n")
    out.append(_md_table(["tool", "errors"], [[t["key"], t["count"]] for t in tools["top_error_tools"][:10]]))
    out.append("")

    out.append("## 错误类别\n")
    out.append(_md_table(["class", "count"], [[k, v] for k, v in metrics.get("error_classes", {}).items()]))
    out.append("")

    out.append("## 失败模式 Top 20\n")
    out.append(_md_table(["failure", "count"], [[f["key"], f["count"]] for f in metrics["failure_modes"][:20]]))
    out.append("")

    out.append("## 写目标 Top 10\n")
    out.append(_md_table(["target", "writes"], [[w["key"], w["count"]] for w in metrics["write_targets"]["top"][:10]]))
    out.append("")

    out.append("## 委托深度\n")
    out.append(_md_table(["depth", "root_sessions"], [[k, v] for k, v in metrics["delegation_depth"].items()]))
    out.append("")

    out.append("## 其他\n")
    out.append(f"- 消息类型计数：`{json.dumps(metrics['message_types'], ensure_ascii=False)}`")
    out.append(f"- JSON 解析失败：{metrics['parse_errors']}")
    out.append(f"- tool_version：`{manifest['tool_version']}` / metrics_version：`{METRICS_VERSION}`")
    out.append("")
    return "\n".join(out)


def _emit(snap_path: Path, sha: str, out: Path) -> int:
    run = _run_dir(out)
    metrics = compute(snap_path)
    metrics_path = run / "metrics.json"
    metrics_path.write_text(json.dumps(metrics, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    manifest = manifest_mod.build(snapshot_sha256=sha, metrics_path=metrics_path)
    manifest_mod.write(run / "run-manifest.json", manifest)

    report = render_report(metrics, manifest)
    (run / "report.md").write_text(report, encoding="utf-8")

    # 再算一次，证明同一快照同数（P0 验收判据）
    again = compute(snap_path)
    deterministic = json.dumps(metrics, sort_keys=True) == json.dumps(again, sort_keys=True)
    (run / "determinism.json").write_text(
        json.dumps({"deterministic": deterministic, "snapshot_sha256": sha}, indent=2) + "\n",
        encoding="utf-8",
    )

    print(f"▶ run dir: {run}")
    print(f"▶ deterministic: {deterministic}")
    print(f"▶ report: {run / 'report.md'}")
    return 0 if deterministic else 1


def cmd_snapshot(args) -> int:
    out = Path(args.out).expanduser()
    path, sha = create_snapshot(args.db, out / "snapshots")
    print(f"{path}\n{sha}")
    return 0


def cmd_metrics(args) -> int:
    metrics = compute(args.snapshot)
    run = _run_dir(Path(args.out).expanduser()) if args.run_dir is None else Path(args.run_dir)
    metrics_path = run / "metrics.json"
    metrics_path.write_text(json.dumps(metrics, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(metrics_path)
    return 0


def cmd_report(args) -> int:
    snap = Path(args.snapshot).expanduser()
    if not snap.is_file():
        raise FileNotFoundError(f"snapshot not found: {snap}")
    stem = snap.stem
    sha = stem if len(stem) == 64 else __import__("hashlib").sha256(snap.read_bytes()).hexdigest()
    return _emit(snap, sha, Path(args.out).expanduser())


def cmd_all(args) -> int:
    out = Path(args.out).expanduser()
    snap_path, sha = create_snapshot(args.db, out / "snapshots")
    print(f"▶ snapshot: {snap_path}")
    return _emit(snap_path, sha, out)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="harness.run")
    p.add_argument("--version", action="version", version=TOOL_VERSION)
    sub = p.add_subparsers(dest="cmd", required=True)

    ps = sub.add_parser("snapshot")
    ps.add_argument("--db", default=DEFAULT_DB)
    ps.add_argument("--out", default=DEFAULT_OUT)
    ps.set_defaults(func=cmd_snapshot)

    pm = sub.add_parser("metrics")
    pm.add_argument("--snapshot", required=True)
    pm.add_argument("--out", default=DEFAULT_OUT)
    pm.add_argument("--run-dir", default=None)
    pm.set_defaults(func=cmd_metrics)

    pr = sub.add_parser("report")
    pr.add_argument("--snapshot", required=True)
    pr.add_argument("--out", default=DEFAULT_OUT)
    pr.set_defaults(func=cmd_report)

    pa = sub.add_parser("all")
    pa.add_argument("--db", default=DEFAULT_DB)
    pa.add_argument("--out", default=DEFAULT_OUT)
    pa.set_defaults(func=cmd_all)

    args = p.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
