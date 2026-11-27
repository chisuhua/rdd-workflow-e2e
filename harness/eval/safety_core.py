"""安全核清单（ADR-0004 决策 4）的读取与「glob ↔ 实际布局」核对。

为什么必须有这一步：清单里的 glob 若与仓库实际布局不一致，安全核会**漏掉**它本该
覆盖的文件。已发现的真实缺陷：ADR-0004 原文写 `harness/metrics/**`，而指标定义是
单文件 `harness/metrics.py` ⇒ 该 glob 匹配不到 ⇒ 核对不通过即判红。

清单条目有两种 scope：
- `repo:<glob>` —— 本仓资产：glob 必须匹配到 ≥1 个真实文件，否则判红。
- `external:<glob>` —— 跨仓载体（`~/.config/opencode/**`、`rdd-workflow/**`）：
  只登记不校验（本仓没有那些文件，校验由跨仓 gate 负责）。
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass, field
from pathlib import Path

SKIP_DIRS = {
    ".git", "__pycache__", ".rddf", ".tmp-cg", ".tmp-ibs", ".tmp-l2",
    ".tmp-oig", ".tmp-oig-fixtures", ".tmp-pg", ".tmp-pt1", ".tmp-rt", ".tmp-sc",
}


@dataclass
class Entry:
    scope: str
    glob: str
    reason: str
    matched_paths: list[Path] = field(default_factory=list)


@dataclass
class Report:
    entries: list[Entry] = field(default_factory=list)
    manifest_sha256: str = ""
    recorded_sha256: str = ""


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def parse_manifest(text: str) -> list[Entry]:
    entries: list[Entry] = []
    for lineno, raw in enumerate(text.splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split(None, 1)
        if len(parts) != 2:
            raise ValueError(f"第 {lineno} 行格式非法（需要 <scope>:<glob> <理由>）: {raw!r}")
        target = parts[0]
        scope, _, glob = target.partition(":")
        if scope not in {"repo", "external"} or not glob:
            raise ValueError(f"第 {lineno} 行 scope 非法: {target!r}")
        entries.append(Entry(scope=scope, glob=glob, reason=parts[1].strip()))
    return entries


def _skip(path: Path, root: Path) -> bool:
    """按**相对 root 的路径**判定是否跳过。

    判定必须相对 root：worktree 会落在 `.rddf/wt/<name>/` 下，用绝对路径的 parts 判定
    会把整个仓库都当成「跳过目录」⇒ 所有 glob 都匹配不到（真实踩过的坑）。
    """
    try:
        parts = path.relative_to(root).parts
    except ValueError:
        return True
    return any(part in SKIP_DIRS for part in parts)


def _match(root: Path, pattern: str) -> list[Path]:
    """把 glob 匹配到真实路径。

    `**` 语义：`x/**` 展开为「该目录下任意深度」；`dir/**/name` 展开为「该目录下任意深度
    的 name」；其余按 fnmatch 逐文件比对。
    """
    if pattern.endswith("/**"):
        base = root / pattern[:-3]
        if not base.exists():
            return []
        return [p for p in base.rglob("*") if p.is_file() and not _skip(p, root)]
    if "**/" in pattern:
        head, _, tail = pattern.partition("**/")
        base = root / head
        if not base.exists():
            return []
        return [p for p in base.rglob(tail) if p.is_file() and not _skip(p, root)]
    candidate = root / pattern
    if candidate.is_file():
        return [candidate]
    if candidate.is_dir():
        return [p for p in candidate.rglob("*") if p.is_file() and not _skip(p, root)]
    return [p for p in root.rglob(pattern) if p.is_file() and not _skip(p, root)]


def audit(root: Path, manifest_path: Path) -> Report:
    report = Report()
    report.manifest_sha256 = sha256_file(manifest_path)
    sidecar = manifest_path.with_name(manifest_path.stem + ".sha256")
    if sidecar.is_file():
        report.recorded_sha256 = sidecar.read_text(encoding="utf-8").split()[0].strip()
    for entry in parse_manifest(manifest_path.read_text(encoding="utf-8")):
        if entry.scope == "repo":
            entry.matched_paths = _match(root, entry.glob)
        report.entries.append(entry)
    return report
