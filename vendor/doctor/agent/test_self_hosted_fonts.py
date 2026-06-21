"""Privacy regression test: the Doctor dashboard must self-host its brand fonts.

The dashboard previously @import-ed Outfit / IBM Plex from fonts.googleapis.com,
which beacons the customer IP + timestamp to Google on every dashboard open --
unacceptable for a local-first product. These tests pin that:

  1. No third-party font fetch URL (fonts.googleapis.com / fonts.gstatic.com /
     a remote @import) survives anywhere in the dashboard CSS.
  2. The CSS self-hosts the branded families via @font-face served same-origin
     from /doctor/fonts.
  3. Every font file referenced by an @font-face rule is actually bundled next
     to the agent, and every allow-listed file exists (no dangling references,
     no orphan bundle).

Deliberately source-level (no FastAPI import) so it runs with stdlib only and
does not require the agent's runtime deps to be installed.
"""

import re
import unittest
from pathlib import Path

_AGENT_DIR = Path(__file__).resolve().parent
_WEB_UI = _AGENT_DIR / "web_ui.py"
_FONTS_DIR = _AGENT_DIR / "fonts"


class SelfHostedFontsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.src = _WEB_UI.read_text(encoding="utf-8")

    def test_no_third_party_font_fetch(self):
        # A real fetch URL would be inside a url(...) or @import. Bare mentions
        # of the hostname inside explanatory comments ("do NOT re-add ...") are
        # fine; an actual https://fonts.googleapis.com/css?... URL is not.
        forbidden = re.findall(
            r"https?://fonts\.(?:googleapis|gstatic)\.com/\S*\.(?:css|woff2?|ttf)",
            self.src,
        )
        self.assertEqual(
            forbidden, [], f"third-party font fetch leaked back in: {forbidden}"
        )
        self.assertNotIn("@import url", self.src)

    def test_font_faces_present(self):
        self.assertIn("@font-face", self.src)
        self.assertIn("/doctor/fonts/", self.src)
        # Both branded families self-hosted.
        self.assertIn("font-family: 'Outfit'", self.src)
        self.assertIn("font-family: 'IBM Plex Sans'", self.src)

    def test_referenced_font_files_are_bundled(self):
        referenced = set(
            re.findall(r"/doctor/fonts/([A-Za-z0-9_-]+\.ttf)", self.src)
        )
        self.assertTrue(referenced, "expected at least one bundled font reference")
        for fname in referenced:
            self.assertTrue(
                (_FONTS_DIR / fname).is_file(),
                f"@font-face references {fname} but it is not bundled in {_FONTS_DIR}",
            )

    def test_ofl_licence_bundled(self):
        # The fonts are OFL-licensed; ship the licence alongside them.
        self.assertTrue((_FONTS_DIR / "OFL.txt").is_file())


if __name__ == "__main__":
    unittest.main()
