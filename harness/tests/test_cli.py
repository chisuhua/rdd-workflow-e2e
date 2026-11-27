import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

REPO_ROOT = Path(__file__).resolve().parents[2]
CLI = [sys.executable, "-m", "harness.eval.cli"]


class CliTest(unittest.TestCase):
    def _run(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            CLI + list(args), cwd=str(REPO_ROOT), capture_output=True, text=True, check=False
        )

    def test_path_config_command_passes(self):
        proc = self._run("path-config")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("归属声明校验通过", proc.stdout)

    def test_masking_command_reds_on_unmasked_env(self):
        with tempfile.TemporaryDirectory() as tmp:
            env_file = Path(tmp) / "env.json"
            env_file.write_text(
                json.dumps({
                    "skill_names": ["rdd-builder"],
                    "rdd_call_success_count": 3,
                    "unknown_skill_probe_result": "ok",
                    "rddf_on_path": True,
                }),
                encoding="utf-8",
            )
            proc = self._run("masking", "--env", str(env_file), "--arm", "W0")
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertIn("✗", proc.stdout)

    def test_arms_index_command_writes_five_fields(self):
        with tempfile.TemporaryDirectory() as tmp:
            index = Path(tmp) / "arms" / "index.jsonl"
            proc = self._run(
                "arms-index", "--path", str(index),
                "--session-id", "s1", "--run-id", "r1", "--arm", "W2",
                "--prompt-hash", "a" * 64,
            )
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            row = json.loads(index.read_text(encoding="utf-8").strip())
        self.assertEqual(
            set(row), {"session_id", "run_id", "arm", "path_switches", "prompt_hash"}
        )

    def test_eval_manifest_command_writes_14_fields(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "manifest.json"
            proc = self._run(
                "eval-manifest", "--out", str(out),
                "--opencode-sha", "a" * 40, "--product-sha", "b" * 40,
                "--model-id", "m", "--prompt-version", "c" * 64,
                "--criteria-version", "d" * 64, "--taskset-version", "e" * 64,
                "--snapshot-sha", "f" * 64,
            )
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            manifest = json.loads(out.read_text(encoding="utf-8"))
        self.assertEqual(manifest["kind"], "eval")
        self.assertEqual(len(manifest["path_config_version"]), 64)
        self.assertEqual(manifest["budget_usd"], 0.0)
