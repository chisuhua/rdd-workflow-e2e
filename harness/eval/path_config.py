"""期望归属声明（ADR-0007 决策 4）的读取与机判。

声明 = 数据文件（`harness/path-config.yaml`），校验器 = 判据。二者分离：
声明可被人改（它进安全核），校验逻辑写死在本模块。

阶段集合的权威来源是本模块的 `EXPECTED_STAGES`：它对应 rdd-workflow 的四个阶段执行型
职责（arch / plan / build / verify —— 产出 openspec 工件与 handoff 的阶段）。
ADR-0007 决策 3 明确：基座的权限 / 配对 / 停机类约束**不计为阶段**，
所以「基座承担 0 个阶段」是正常态，不触发迁空 tripwire。
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass, field
from pathlib import Path

from . import mini_yaml
from . import taskset

#: 阶段集合（顺序即声明顺序；与声明文件必须完全一致，不接受子集）。
EXPECTED_STAGES: tuple[str, ...] = ("arch", "plan", "build", "verify")

#: 承担者词表。
BEARERS: frozenset[str] = frozenset({"基座", "叠加层"})

#: 证据强度词表（ADR-0007 决策 3 的三档）。
EVIDENCE_LEVELS: frozenset[str] = frozenset({"方向性", "判据层", "完整A/B"})

#: 移动门槛词表。
THRESHOLDS: frozenset[str] = frozenset({"方向性", "判据层", "完整A/B"})

REQUIRED_FIELDS: tuple[str, ...] = ("阶段", "当前承担者", "证据强度", "移动门槛", "证据集")


@dataclass
class Result:
    path: Path
    rows: list[dict] = field(default_factory=list)
    stages: list[str] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not self.errors


@dataclass
class TripwireVerdict:
    triggered: bool
    reason: str
    overlay_stage_count: int
    base_stage_count: int


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def version(path: Path) -> str:
    """`path_config_version` = 内容哈希（ADR-0005 §3 的内容哈希模式）。"""
    return sha256_file(path)


def check(path: Path, cases_dir: Path | None = None) -> Result:
    result = Result(path=path)
    if not path.is_file():
        result.errors.append(f"声明文件不存在: {path}")
        return result
    try:
        rows = mini_yaml.parse_records(path.read_text(encoding="utf-8"))
    except mini_yaml.MiniYamlError as exc:
        result.errors.append(f"声明文件解析失败: {exc}")
        return result
    result.rows = rows
    if not rows:
        result.errors.append("声明文件为空：至少要有 arch / plan / build / verify 四行")
        return result
    registry = taskset.Registry(cases_dir=cases_dir)
    seen: set[str] = set()
    for index, row in enumerate(rows, start=1):
        for required in REQUIRED_FIELDS:
            value = row.get(required)
            if value is None or (isinstance(value, str) and not value.strip()):
                result.errors.append(f"第 {index} 行缺少或留空字段「{required}」")
        stage = row.get("阶段")
        if not isinstance(stage, str) or not stage.strip():
            continue
        if stage in seen:
            result.errors.append(f"阶段重复: {stage}")
        seen.add(stage)
        bearer = row.get("当前承担者")
        if isinstance(bearer, str) and bearer not in BEARERS:
            result.errors.append(f"第 {index} 行当前承担者取值非法: {bearer!r}")
        strength = row.get("证据强度")
        if isinstance(strength, str) and strength not in EVIDENCE_LEVELS:
            result.errors.append(f"第 {index} 行证据强度取值非法: {strength!r}")
        threshold = row.get("移动门槛")
        if isinstance(threshold, str) and threshold not in THRESHOLDS:
            result.errors.append(f"第 {index} 行移动门槛取值非法: {threshold!r}")
        evidence = row.get("证据集")
        if isinstance(evidence, str):
            evidence = [evidence]
        if not isinstance(evidence, list) or not evidence:
            result.errors.append(f"第 {index} 行证据集为空")
            continue
        for case_id in evidence:
            try:
                registry.path(case_id)
            except taskset.UnknownCaseId:
                result.errors.append(f"第 {index} 行证据集引用了解析不到的 case: {case_id}")
    result.stages = [r.get("阶段") for r in rows if isinstance(r.get("阶段"), str)]
    if tuple(result.stages) != EXPECTED_STAGES:
        result.errors.append(
            f"阶段集合与权威来源不一致: 声明={result.stages} 期望={list(EXPECTED_STAGES)}"
        )
    return result


def tripwire(rows: list[dict]) -> TripwireVerdict:
    """迁空 tripwire（ADR-0007 决策 3）。

    叠加层承担的阶段数降为 0 ⇒ 该次迁移视同「退役」提案，须走第三档证据要求。
    基座承担的阶段数为 0 **不触发**：基座的权限 / 配对 / 停机类约束不计为阶段
    （ADR-0007 决策 3 的阶段定义），否则门槛永久触发、形同虚设。
    """
    overlay = sum(1 for r in rows if r.get("当前承担者") == "叠加层")
    base = sum(1 for r in rows if r.get("当前承担者") == "基座")
    if overlay == 0:
        return TripwireVerdict(
            triggered=True,
            reason="叠加层承担的阶段数 = 0 ⇒ 视同退役提案，须满足 ADR-0007 决策 3 第三行证据要求",
            overlay_stage_count=overlay,
            base_stage_count=base,
        )
    return TripwireVerdict(
        triggered=False,
        reason=f"叠加层承担 {overlay} 个阶段（基座 {base} 个）⇒ 未触发迁空门槛",
        overlay_stage_count=overlay,
        base_stage_count=base,
    )
