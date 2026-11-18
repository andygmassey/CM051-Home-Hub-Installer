"""An L0 interest is withheld by the preference readers (CM041 #278, 134
red-team CM041-02). Pure-function test on the verdict: no store, no server.

The existing preference fixtures all carry L1, so an L0 case was never
exercised and the flag was encoded rather than the property. These do not
depend on the flag: the same L0 value on either key must be withheld, and an
explicit L1 or L2 must still be served.
"""
from __future__ import annotations

import importlib.util
import pathlib
import sys
import types
import unittest

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SERVER = REPO_ROOT / "assistant_api" / "ical-server.py"
sys.path.append(str(REPO_ROOT / "assistant_api"))
sys.path.append(str(REPO_ROOT))

try:
    import ostler_security  # noqa: F401
except Exception:
    import sqlite3
    pkg = types.ModuleType("ostler_security")
    pkg.__path__ = []
    sys.modules["ostler_security"] = pkg
    db = types.ModuleType("ostler_security.database")
    db.get_db_connection = lambda p, _k, *a, **k: sqlite3.connect(p)
    sys.modules["ostler_security.database"] = db
    po = types.ModuleType("ostler_security.posture")
    po.record_posture = lambda *a, **k: None
    sys.modules["ostler_security.posture"] = po

_spec = importlib.util.spec_from_file_location("ical_interest_l0_134", SERVER)
ICAL = importlib.util.module_from_spec(_spec)
# The server edits sys.path and can shadow the test package name ("tests") with its
# own assistant_api/tests: restore both so the rest of the suite imports as before.
_saved_path = list(sys.path)
_saved_mods = {k for k in sys.modules if k == "tests" or k.startswith("tests.")}
_spec.loader.exec_module(ICAL)
sys.path[:] = _saved_path
for _k in [k for k in sys.modules if (k == "tests" or k.startswith("tests.")) and k not in _saved_mods]:
    del sys.modules[_k]


class InterestL0IsWithheld(unittest.TestCase):

    def test_l0_on_the_compiler_key_is_withheld(self):
        self.assertEqual(ICAL._interest_privacy_verdict({"privacy": "L0"}), "l0")

    def test_l0_on_the_legacy_key_is_withheld(self):
        self.assertEqual(ICAL._interest_privacy_verdict({"privacy_level": "L0"}), "l0")

    def test_control_l1_and_l2_are_served(self):
        self.assertEqual(ICAL._interest_privacy_verdict({"privacy": "L1"}), "ok")
        self.assertEqual(ICAL._interest_privacy_verdict({"privacy": "L2"}), "ok")

    def test_l3_still_wins_over_l0(self):
        self.assertEqual(
            ICAL._interest_privacy_verdict({"privacy": "L0", "privacy_level": "L3"}), "l3")


if __name__ == "__main__":
    unittest.main()
