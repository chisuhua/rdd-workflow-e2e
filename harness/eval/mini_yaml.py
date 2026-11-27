"""受限 YAML 子集解析器（fail-closed）。

只支持本仓声明文件用到的形态：注释行 + 顶层 block sequence of mappings，
标量为纯文本，逗号分隔的列表写成 `a, b`。

为什么不引第三方 YAML 库：harness 的既有纪律是「Python 标准库，无第三方依赖」
（`harness/README.md`）；而 `PyYAML` 未列入任何依赖声明（仓里没有 requirements.txt），
引入它会让 CI 的可复现性依赖环境状态。

为什么 fail-closed：声明文件（`harness/path-config.yaml`）是**判据资产**（ADR-0007 决策 4）。
「猜着解析」会把声明读成另一种含义，而读错声明 = 判据失真 ⇒ 遇到不认识的构造直接报错。
"""

from __future__ import annotations


class MiniYamlError(ValueError):
    """输入不属于受支持的子集。"""


def _scalar(raw: str) -> object:
    text = raw.strip()
    if not text:
        raise MiniYamlError("空标量不支持")
    if text[0] in "\"'":
        quote = text[0]
        end = text.find(quote, 1)
        if end == -1:
            raise MiniYamlError(f"引号未闭合: {text!r}")
        if text[end + 1:].strip():
            raise MiniYamlError(f"引号后有多余内容: {text!r}")
        # 引号标量按**字面量**处理：允许其中出现 ':' 与 ','（标记清单需要）。
        return text[1:end]
    if text[0] in "[{":
        raise MiniYamlError(f"不支持的标量形式: {text!r}")
    if ":" in text:
        raise MiniYamlError(f"标量含冒号，拒绝猜测: {text!r}")
    if "," in text:
        return [part.strip() for part in text.split(",") if part.strip()]
    return text


def parse_records(text: str) -> list[dict[str, object]]:
    """解析顶层 block sequence of mappings。

    支持的形态：
    - `#` 开头的注释行、空行 —— 跳过；
    - `- key: value` —— 新记录的第一对键值；
    - `  key: value` —— 同一记录的后续键值（缩进两格）。

    标量：裸文本（可含逗号 ⇒ 视为列表）或**引号包裹的字面量**（可含 ':' 与 ','）。
    """
    records: list[dict[str, object]] = []
    current: dict[str, object] | None = None
    for lineno, raw in enumerate(text.splitlines(), start=1):
        line = raw.rstrip()
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if line.startswith("- "):
            current = {}
            records.append(current)
            line = "  " + line[2:]
        elif line.startswith("  ") and current is not None:
            pass
        else:
            raise MiniYamlError(f"第 {lineno} 行不是受支持的形态: {line!r}")
        if ":" not in line:
            raise MiniYamlError(f"第 {lineno} 行缺少 ':'")
        key, _, value = line.partition(":")
        key = key.strip()
        if not key:
            raise MiniYamlError(f"第 {lineno} 行键为空")
        current[key] = _scalar(value)
    return records
