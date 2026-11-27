"""rdd-harness E 层就绪资产（change-1）。

本子包只提供**静态资产与判据**：归属声明、安全核清单核对、遮蔽探针、W0 prompt 副本
隔离检测、臂索引 writer、判据审计汇总。

纪律（与 P0 同源）：
- **不调用模型**：本子包没有任何模型客户端依赖（`harness/tests/test_no_model_calls.py`
  用 AST 扫描守卫这一点）。
- **不写用户目录**：产物目录一律由调用方传入；单测用临时目录。
- **fail-closed**：解析失败、断言不成立 ⇒ 报错/判红，不猜测、不降级。
"""

__all__ = [
    "arms_index",
    "audit",
    "cases",
    "masking",
    "mini_yaml",
    "path_config",
    "prompt_isolation",
    "safety_core",
    "taskset",
]
