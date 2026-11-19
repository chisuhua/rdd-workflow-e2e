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
