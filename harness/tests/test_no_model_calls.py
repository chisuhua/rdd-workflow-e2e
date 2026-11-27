import ast
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

#: 任何模型客户端 / 网络客户端都不得出现在 harness 里（本期不跑真模型）。
FORBIDDEN = {
    "openai", "anthropic", "litellm", "httpx", "requests", "aiohttp",
    "google", "cohere", "ollama",
}


class NoModelCallsTest(unittest.TestCase):
    def test_harness_sources_do_not_import_model_clients(self):
        offenders = []
        for path in sorted((REPO_ROOT / "harness").rglob("*.py")):
            tree = ast.parse(path.read_text(encoding="utf-8"))
            for node in ast.walk(tree):
                if isinstance(node, ast.Import):
                    for alias in node.names:
                        if alias.name.split(".")[0] in FORBIDDEN:
                            offenders.append(f"{path}: import {alias.name}")
                elif isinstance(node, ast.ImportFrom) and node.module:
                    if node.module.split(".")[0] in FORBIDDEN:
                        offenders.append(f"{path}: from {node.module}")
        self.assertEqual(offenders, [])

    def test_harness_sources_do_not_call_model_endpoints(self):
        offenders = []
        for path in sorted((REPO_ROOT / "harness").rglob("*.py")):
            if path.name == Path(__file__).name:
                continue  # 扫描器自身含 needle 字面量
            text = path.read_text(encoding="utf-8")
            for needle in ("api.openai.com", "api.anthropic.com", "/v1/chat/completions"):
                if needle in text:
                    offenders.append(f"{path}: {needle}")
        self.assertEqual(offenders, [])

    def test_eval_manifest_budget_is_zero_by_default(self):
        from harness import manifest as manifest_mod

        m = manifest_mod.build_eval(
            opencode_sha="a", product_sha="b", model_id="none",
            prompt_version="c", criteria_version="d", taskset_version="e",
            snapshot_sha="f", path_config_version="1", arms_index_sha256="2",
            budget_usd=0.0, cost_usd_actual=0.0,
        )
        self.assertEqual(m["cost_usd_actual"], 0.0)
        self.assertEqual(m["budget_usd"], 0.0)
