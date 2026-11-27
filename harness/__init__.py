"""rdd-harness — O 层观测（P0）。

只读 opencode session DB，产出可复算的指标报告。
纪律：不修改被测仓、不调用模型、指标公式写死。
"""

__all__ = ["snapshot", "metrics", "manifest", "run"]

TOOL_VERSION = "harness-p0-v2"
# v3（2026-11-27）：行粒度断点（P0 按 session / P1 起按 unit ⇒ 趋势不可拼接）+ 夜间报告增
# trace 三项完整性指标（trace_incomplete 率 / torn_lines / cost_coverage，ADR-0002 决策 6）。
METRICS_VERSION = "p0-metrics-v3"
