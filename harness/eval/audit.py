"""判据审计报告（ADR-0005 指标定义：judge_defect_rate / false_negative_rate / 覆盖率）。

三个率的定义与阈值（唯一真源 = ADR-0005 §1 指标表）：
- `judge_defect_rate` = 审计确认有缺陷的 oracle 数 / 被审计的 oracle 数；
  **分母与抽样方法必须进报告**，否则该指标不得进安全核口径。
- 试点 10 条缺陷率 > 10% ⇒ **冻结扩量**（先修判据）。
- `false_negative_rate` = 合法解被判失败的次数 / 合法解尝试次数（唯一能惩罚「判据过严」的指标）。

审计者独立性（ADR-0003 决策 4）：1-operator 配置下由**独立会话交叉审**，报告须声明其局限；
发现缺陷的用例作废并重审，不得沿用旧结论。
"""

from __future__ import annotations

from dataclasses import dataclass

#: 冻结扩量的阈值（唯一真源：ADR-0005 指标表 —— 试点 10 条缺陷率 > 10%）。
FREEZE_THRESHOLD = 0.10


@dataclass
class Report:
    judge_defect_rate: float
    audit_coverage: float
    false_negative_rate: float
    sampling_method: str
    freeze_expansion: bool


def summarize(
    findings: list[dict],
    *,
    audited_total: int,
    sampling_method: str,
    legit_attempts: int = 0,
    legit_failures: int = 0,
) -> Report:
    defects = sum(1 for f in findings if f.get("defect"))
    # 分母口径（ADR-0005 指标表）：
    # - judge_defect_rate 的分母 = **被审计的 oracle 数**（= findings 条数）
    # - 审计覆盖率 = 被审计数 / 正式用例总数（= audited_total）
    judge_defect_rate = defects / len(findings) if findings else 0.0
    audit_coverage = len(findings) / audited_total if audited_total else 0.0
    false_negative_rate = legit_failures / legit_attempts if legit_attempts else 0.0
    return Report(
        judge_defect_rate=judge_defect_rate,
        audit_coverage=audit_coverage,
        false_negative_rate=false_negative_rate,
        sampling_method=sampling_method,
        freeze_expansion=judge_defect_rate > FREEZE_THRESHOLD,
    )
