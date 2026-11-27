"""run-manifest（kind=metrics）：让一次运行可复算。

字段定义见 ADR-0005 §3。
"""

from __future__ import annotations

import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from . import METRICS_VERSION, TOOL_VERSION


def _sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def build(
    *,
    snapshot_sha256: str,
    metrics_path: str | Path,
    generated_at: str | None = None,
) -> dict[str, Any]:
    metrics_file = Path(metrics_path)
    return {
        "kind": "metrics",
        "snapshot_sha256": snapshot_sha256,
        "metrics_version": METRICS_VERSION,
        "metrics_sha": _sha256_file(metrics_file),
        "generated_at": generated_at or datetime.now(timezone.utc).isoformat(),
        "tool_version": TOOL_VERSION,
        "granularity": "session",
    }


def write(path: str | Path, manifest: dict[str, Any]) -> Path:
    out = Path(path)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return out


def build_eval(
    *,
    opencode_sha: str,
    product_sha: str,
    model_id: str,
    prompt_version: str,
    criteria_version: str,
    taskset_version: str,
    snapshot_sha: str,
    path_config_version: str,
    arms_index_sha256: str,
    budget_usd: float,
    cost_usd_actual: float,
    generated_at: str | None = None,
) -> dict[str, Any]:
    """`kind=eval` manifest（ADR-0005 §3 的 14 字段）。

    - `prompt_version` 是**本次 run 涉及的全部臂的 prompt 集合的并集哈希**；逐臂的实际
      prompt 哈希记在臂索引的 `prompt_hash` 字段（ADR-0008 决策 2）。
    - `path_config_version` = 期望归属声明的内容哈希（ADR-0007 决策 4）。
    - `arms_index_sha256` = 本次 run 所用臂索引文件的内容哈希（不含臂标签本身）。
    - `budget_usd` / `cost_usd_actual` 在不跑真模型的 change-1 期间为 0。
    """
    return {
        "kind": "eval",
        "manifest_version": 1,
        "opencode_sha": opencode_sha,
        "product_sha": product_sha,
        "model_id": model_id,
        "prompt_version": prompt_version,
        "criteria_version": criteria_version,
        "taskset_version": taskset_version,
        "snapshot_sha": snapshot_sha,
        "granularity": "unit",
        "path_config_version": path_config_version,
        "arms_index_sha256": arms_index_sha256,
        "budget_usd": budget_usd,
        "cost_usd_actual": cost_usd_actual,
        "generated_at": generated_at or datetime.now(timezone.utc).isoformat(),
    }
