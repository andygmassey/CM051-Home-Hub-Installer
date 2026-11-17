"""Unit states of pwg_privacy.provenance_verdict (Archie, 133).

The item's OWN level is read first, then its linked sources; most-restrictive
wins. States: L3 and UNREADABLE withhold; ABSENT (no level, no readable source)
is legacy and is served and counted; a readable L0-L2 serves. ABSENT and
UNREADABLE stay distinct. Pure function, synthetic values only.
"""
from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path

_PATH = Path(__file__).resolve().parent.parent.parent / "pwg_privacy.py"
_spec = importlib.util.spec_from_file_location("pwg_privacy_states", _PATH)
pp = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(pp)


class TestProvenanceVerdictStates(unittest.TestCase):
    def test_own_l3_withholds(self):
        self.assertEqual("l3", pp.provenance_verdict("L3"))

    def test_own_unreadable_withholds(self):
        self.assertEqual("unknown", pp.provenance_verdict("public"))

    def test_linked_source_l3_withholds_even_when_own_is_l2(self):
        self.assertEqual("l3", pp.provenance_verdict("L2", ["L3"]))

    def test_linked_source_unreadable_withholds(self):
        self.assertEqual("unknown", pp.provenance_verdict(None, ["bogus"]))

    def test_absent_everywhere_is_legacy_and_served(self):
        self.assertEqual("legacy_untagged", pp.provenance_verdict(None))
        self.assertEqual("legacy_untagged", pp.provenance_verdict(None, [None]))

    def test_own_readable_level_serves(self):
        self.assertEqual("ok", pp.provenance_verdict("L2"))
        self.assertEqual("ok", pp.provenance_verdict("l1"))

    def test_absent_source_level_does_not_withhold_a_readable_own(self):
        self.assertEqual("ok", pp.provenance_verdict("L2", [None]))

    def test_absent_and_unreadable_are_distinct(self):
        self.assertNotEqual(pp.provenance_verdict(None), pp.provenance_verdict("junk"))


if __name__ == "__main__":
    unittest.main()
