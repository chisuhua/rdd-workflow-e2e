import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from harness import manifest as manifest_mod  # noqa: E402

EVAL_FIELDS = {
    "kind", "manifest_version", "opencode_sha", "product_sha", "model_id",
    "prompt_version", "criteria_version", "taskset_version", "snapshot_sha",
    "granularity", "path_config_version", "arms_index_sha256", "budget_usd",
    "cost_usd_actual", "generated_at",
}


def _kwargs() -> dict:
    return dict(
        opencode_sha="a" * 40,
        product_sha="b" * 40,
        model_id="test-model",
        prompt_version="c" * 64,
        criteria_version="d" * 64,
        taskset_version="e" * 64,
        snapshot_sha="f" * 64,
        path_config_version="1" * 64,
        arms_index_sha256="2" * 64,
        budget_usd=0.0,
        cost_usd_actual=0.0,
    )


class EvalManifestTest(unittest.TestCase):
    def test_eval_manifest_has_all_14_fields(self):
        m = manifest_mod.build_eval(**_kwargs())
        self.assertEqual(set(m), EVAL_FIELDS)
        self.assertEqual(len(EVAL_FIELDS), 15)  # 14 字段 + generated_at
        self.assertEqual(m["kind"], "eval")
        self.assertEqual(m["granularity"], "unit")
        self.assertEqual(m["manifest_version"], 1)

    def test_metrics_and_eval_field_sets_do_not_mix(self):
        with tempfile.TemporaryDirectory() as tmp:
            metrics_file = Path(tmp) / "m.json"
            metrics_file.write_text("{}", encoding="utf-8")
            metrics_manifest = manifest_mod.build(snapshot_sha256="0" * 64, metrics_path=metrics_file)
        eval_manifest = manifest_mod.build_eval(**_kwargs())
        shared = set(metrics_manifest) & set(eval_manifest)
        # 只允许三个共用名：kind（工件类型）、generated_at（生成时间）、granularity（行粒度键）
        self.assertEqual(shared, {"kind", "generated_at", "granularity"})
        # 语义不得混用：行粒度不同（session vs unit）
        self.assertEqual(metrics_manifest["granularity"], "session")
        self.assertEqual(eval_manifest["granularity"], "unit")

    def test_metrics_manifest_keeps_its_own_field_set(self):
        with tempfile.TemporaryDirectory() as tmp:
            metrics_file = Path(tmp) / "m.json"
            metrics_file.write_text("{}", encoding="utf-8")
            m = manifest_mod.build(snapshot_sha256="0" * 64, metrics_path=metrics_file)
        self.assertEqual(
            set(m),
            {"kind", "snapshot_sha256", "metrics_version", "metrics_sha",
             "generated_at", "tool_version", "granularity"},
        )

    def test_path_config_version_matches_the_declaration_file(self):
        """AC：path_config_version（内容哈希）= eval manifest 中的值。"""
        from harness.eval import path_config

        decl = Path(__file__).resolve().parents[1] / "path-config.yaml"
        m = manifest_mod.build_eval(**{**_kwargs(), "path_config_version": path_config.version(decl)})
        self.assertEqual(m["path_config_version"], path_config.version(decl))
        self.assertEqual(len(m["path_config_version"]), 64)

    def test_arms_index_sha256_is_carried_into_the_manifest(self):
        """AC：臂索引的内容哈希进 eval manifest（不含臂标签本身）。"""
        from harness.eval import arms_index, path_config

        with tempfile.TemporaryDirectory() as tmp:
            index = Path(tmp) / "arms" / "index.jsonl"
            arms_index.Index(index).append(
                session_id="s", run_id="r", arm="W2", path_switches=[], prompt_hash="a" * 64
            )
            m = manifest_mod.build_eval(
                **{**_kwargs(), "arms_index_sha256": path_config.sha256_file(index)}
            )
        self.assertEqual(len(m["arms_index_sha256"]), 64)
