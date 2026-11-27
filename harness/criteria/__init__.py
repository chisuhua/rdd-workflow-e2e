"""判据集（capability 集）的包入口。

判据定义在 `harness/criteria/cases/*.json`；机械 oracle 在 `harness/criteria/oracle.py`。
判据是**安全核资产**（ADR-0004 决策 4）⇒ 只能人改。
"""

__all__ = ["oracle"]
