"""W0 prompt 副本的角色矩阵隔离检测（ADR-0008 决策 1）。

断言对象是**副本文件自身的内容**（文件事实），不是模型输出。
治理面 `build.md` 的标记格式若变更，本清单必须同步升版本 —— 否则断言静默失效
（清单带 `version` 字段；变更时改版本号，报告里带出该版本）。
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass, field
from pathlib import Path

from . import mini_yaml


@dataclass
class Report:
    path: Path
    found_markers: list[str] = field(default_factory=list)
    version: str = ""
    sha256: str = ""

    @property
    def ok(self) -> bool:
        return not self.found_markers


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _markers(markers_path: Path) -> tuple[list[str], str]:
    rows = mini_yaml.parse_records(markers_path.read_text(encoding="utf-8"))
    version = ""
    markers: list[str] = []
    for row in rows:
        value = row.get("version")
        if isinstance(value, str):
            version = value
        marker = row.get("marker")
        if isinstance(marker, str):
            markers.append(marker)
    return markers, version


def check(copy_path: Path, markers_path: Path) -> Report:
    report = Report(path=copy_path)
    if not copy_path.is_file():
        report.found_markers.append(f"副本不存在: {copy_path}")
        return report
    markers, version = _markers(markers_path)
    report.version = version
    report.sha256 = sha256_file(copy_path)
    text = copy_path.read_text(encoding="utf-8")
    report.found_markers = [m for m in markers if m and m in text]
    return report
