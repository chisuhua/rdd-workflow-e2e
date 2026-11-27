import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from harness.eval import masking  # noqa: E402


def _masked_env(**overrides) -> masking.Environment:
    base = dict(
        skill_names=(),
        rdd_call_success_count=0,
        unknown_skill_probe_result="unknown-skill",
        rddf_on_path=False,
        skill_links_present=False,
        overlay_lib_present=False,
        env_injected=False,
        unreadable_paths=masking.REQUIRED_UNREADABLE,
        writable_paths=(),
    )
    base.update(overrides)
    return masking.Environment(**base)


def _unmasked_env(**overrides) -> masking.Environment:
    base = dict(
        skill_names=("rdd-builder",),
        rdd_call_success_count=2,
        unknown_skill_probe_result="ok",
        rddf_on_path=True,
        skill_links_present=True,
        overlay_lib_present=True,
        env_injected=True,
        unreadable_paths=(),
        writable_paths=masking.REQUIRED_NOT_WRITABLE,
    )
    base.update(overrides)
    return masking.Environment(**base)


class MaskingTest(unittest.TestCase):
    def test_disabled_arm_requires_all_conditions(self):
        report = masking.probe(_masked_env(), arm="W0")
        self.assertTrue(report.ok, report.violations)
        self.assertEqual(report.violations, [])

    def test_unmasked_environment_is_red(self):
        report = masking.probe(_unmasked_env(), arm="W0")
        self.assertFalse(report.ok)
        # 四类遮蔽对象 + 三项行为断言 + 路径可达性 ⇒ 违规数 >= 7
        self.assertGreaterEqual(len(report.violations), 7)

    def test_enabled_arm_asserts_presence(self):
        report = masking.probe(
            _unmasked_env(
                unreadable_paths=masking.REQUIRED_UNREADABLE,
                writable_paths=(),
            ),
            arm="W2",
        )
        self.assertTrue(report.ok, report.violations)

    def test_assertion_direction_follows_the_arm(self):
        """臂序随机化时探针不能写死方向 —— 同一环境在两个臂上给相反结论。"""
        env = _unmasked_env(unreadable_paths=masking.REQUIRED_UNREADABLE, writable_paths=())
        self.assertTrue(masking.probe(env, arm="W2").ok)
        self.assertFalse(masking.probe(env, arm="W0").ok)

    def test_fifth_assertion_env_injection_is_checked(self):
        """ADR-0008 Verification 的第五项：PYTHONPATH / RDD_WORKFLOW_REPO 未注入。"""
        report = masking.probe(_masked_env(env_injected=True), arm="W0")
        self.assertFalse(report.ok)
        self.assertTrue(any("PYTHONPATH" in v for v in report.violations), report.violations)

    def test_arms_index_must_be_unreadable(self):
        report = masking.probe(
            _masked_env(unreadable_paths=tuple(p for p in masking.REQUIRED_UNREADABLE
                                               if "arms" not in p)),
            arm="W0",
        )
        self.assertFalse(report.ok)
        self.assertTrue(any("arms" in v for v in report.violations), report.violations)

    def test_arms_index_must_not_be_writable(self):
        report = masking.probe(
            _masked_env(writable_paths=masking.REQUIRED_NOT_WRITABLE), arm="W0"
        )
        self.assertFalse(report.ok)
        self.assertTrue(any("可写" in v for v in report.violations), report.violations)
