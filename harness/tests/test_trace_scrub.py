import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from harness import trace  # noqa: E402

JWT = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.abcdefghijklmnop"
BASE = "Basic dXNlcjpwYXNzd29yZA=="
NETRC = "machine example.com login alice password s3cret"


class ScrubTest(unittest.TestCase):
    def test_jwt_is_redacted(self):
        out = trace.scrub(f"authorization: bearer {JWT}")
        self.assertNotIn(JWT, out)
        self.assertIn("[REDACTED:jwt]", out)

    def test_basic_auth_is_redacted(self):
        out = trace.scrub(f"header {BASE}")
        self.assertNotIn("dXNlcjpwYXNzd29yZA==", out)
        self.assertIn("[REDACTED:basic]", out)

    def test_netrc_is_redacted(self):
        out = trace.scrub(NETRC)
        self.assertNotIn("s3cret", out)
        self.assertIn("[REDACTED:netrc]", out)

    def test_plain_text_untouched(self):
        self.assertEqual(trace.scrub("hello world"), "hello world")

    def test_prompt_not_kept_by_default(self):
        unit = trace.scrub_unit({"prompt": "secret text", "tool_calls": []}, keep_prompts=False)
        self.assertNotIn("prompt", unit)
        self.assertEqual(unit["tool_calls"], [])

    def test_prompt_kept_when_explicitly_enabled(self):
        unit = trace.scrub_unit({"prompt": "hello"}, keep_prompts=True)
        self.assertEqual(unit["prompt"], "hello")

    def test_env_var_controls_default(self):
        import os

        old = os.environ.get("HARNESS_KEEP_PROMPTS")
        try:
            os.environ["HARNESS_KEEP_PROMPTS"] = "1"
            self.assertTrue(trace.keep_prompts())
            self.assertEqual(trace.scrub_unit({"prompt": "x"})["prompt"], "x")
            os.environ.pop("HARNESS_KEEP_PROMPTS")
            self.assertFalse(trace.keep_prompts())
            self.assertNotIn("prompt", trace.scrub_unit({"prompt": "x"}))
        finally:
            if old is None:
                os.environ.pop("HARNESS_KEEP_PROMPTS", None)
            else:
                os.environ["HARNESS_KEEP_PROMPTS"] = old
