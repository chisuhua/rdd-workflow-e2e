import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from harness.eval import mini_yaml  # noqa: E402


class MiniYamlTest(unittest.TestCase):
    def test_parses_block_sequence_of_mappings(self):
        text = (
            "# comment\n"
            "- 阶段: arch\n"
            "  当前承担者: 叠加层\n"
            "  证据集: cs-e1, cs-e2\n"
            "- 阶段: plan\n"
            "  当前承担者: 叠加层\n"
            "  证据集: cs-rdd-1\n"
        )
        rows = mini_yaml.parse_records(text)
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]["阶段"], "arch")
        self.assertEqual(rows[0]["证据集"], ["cs-e1", "cs-e2"])
        self.assertEqual(rows[1]["阶段"], "plan")

    def test_rejects_unknown_construct(self):
        text = "- 阶段: arch\n  当前承担者: [a, b]\n"
        with self.assertRaises(mini_yaml.MiniYamlError):
            mini_yaml.parse_records(text)

    def test_rejects_scalar_containing_colon(self):
        text = "- 阶段: arch\n  当前承担者: a: b\n"
        with self.assertRaises(mini_yaml.MiniYamlError):
            mini_yaml.parse_records(text)

    def test_rejects_line_outside_record(self):
        text = "阶段: arch\n"
        with self.assertRaises(mini_yaml.MiniYamlError):
            mini_yaml.parse_records(text)

    def test_quoted_scalar_may_contain_colon_and_comma(self):
        text = '- marker: "【角色:"\n- marker: "a, b"\n'
        rows = mini_yaml.parse_records(text)
        self.assertEqual(rows[0]["marker"], "【角色:")
        self.assertEqual(rows[1]["marker"], "a, b")

    def test_rejects_unterminated_quote(self):
        with self.assertRaises(mini_yaml.MiniYamlError):
            mini_yaml.parse_records('- marker: "abc\n')
