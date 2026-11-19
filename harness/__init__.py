"""rdd-harness — O 层观测（P0）。

只读 opencode session DB，产出可复算的指标报告。
纪律：不修改被测仓、不调用模型、指标公式写死。
"""

__all__ = ["snapshot", "metrics", "manifest", "run"]

TOOL_VERSION = "harness-p0-v2"
METRICS_VERSION = "p0-metrics-v2"
