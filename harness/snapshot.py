"""离线快照：SQLite backup API + 完整性检查 + SHA256。

WAL 下的裸文件拷贝会撕裂，必须用 SQLite 的 backup API（或 VACUUM INTO）。
"""

from __future__ import annotations

import hashlib
import os
import sqlite3
import tempfile
from pathlib import Path


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def create_snapshot(src: str | os.PathLike[str], dest_dir: str | os.PathLike[str]) -> tuple[Path, str]:
    """把 src 数据库备份为 dest_dir/<sha256>.db，返回 (path, sha256)。

    src 以只读打开；备份先写临时文件，完整性检查通过后再改名为内容哈希。
    """
    src_path = Path(src).expanduser()
    if not src_path.is_file():
        raise FileNotFoundError(f"source db not found: {src_path}")

    dest = Path(dest_dir).expanduser()
    dest.mkdir(parents=True, exist_ok=True)

    with tempfile.NamedTemporaryFile(prefix=".snapshot-", suffix=".db", dir=dest, delete=False) as tf:
        tmp_path = Path(tf.name)

    try:
        src_conn = sqlite3.connect(f"file:{src_path}?mode=ro", uri=True)
        dst_conn = sqlite3.connect(tmp_path)
        try:
            src_conn.backup(dst_conn)
        finally:
            dst_conn.close()
            src_conn.close()

        check_conn = sqlite3.connect(f"file:{tmp_path}?mode=ro", uri=True)
        try:
            row = check_conn.execute("PRAGMA integrity_check").fetchone()
        finally:
            check_conn.close()
        if not row or row[0] != "ok":
            raise RuntimeError(f"integrity_check failed: {row!r}")

        sha = _sha256(tmp_path)
        final_path = dest / f"{sha}.db"
        if final_path.exists():
            tmp_path.unlink()
        else:
            tmp_path.replace(final_path)
        return final_path, sha
    except Exception:
        tmp_path.unlink(missing_ok=True)
        raise
