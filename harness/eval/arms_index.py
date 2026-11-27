"""臂索引：`session_id ↔ run_id ↔ arm` 的唯一映射（ADR-0008 决策 2）。

五条规则（缺一即违约）：
1. 只有**五**字段；多写字段即违约。
2. 臂标签**只**存在于本文件 —— 不进 trace、不进 session DB、不进 solver 可见环境。
3. 目录由调用方给（runner 侧持有）；单测用临时目录覆盖，**不写**
   `~/.local/share/rddf-harness/`。
4. 每行一个 JSON 对象（JSONL），追加写。
5. `prompt_hash` 是该 trial 实际使用的 prompt 集合哈希（逐臂），与 manifest 的
   `prompt_version`（并集哈希）可对账。
"""

from __future__ import annotations

import json
from pathlib import Path

FIELDS = ("session_id", "run_id", "arm", "path_switches", "prompt_hash")


class Index:
    def __init__(self, path: Path) -> None:
        self.path = Path(path)

    def append(
        self,
        *,
        session_id: str,
        run_id: str,
        arm: str,
        path_switches: list[str],
        prompt_hash: str,
    ) -> dict:
        row = {
            "session_id": session_id,
            "run_id": run_id,
            "arm": arm,
            "path_switches": list(path_switches),
            "prompt_hash": prompt_hash,
        }
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with open(self.path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(row, ensure_ascii=False) + "\n")
        return row

    def rows(self) -> list[dict]:
        if not self.path.is_file():
            return []
        return [
            json.loads(line)
            for line in self.path.read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]
