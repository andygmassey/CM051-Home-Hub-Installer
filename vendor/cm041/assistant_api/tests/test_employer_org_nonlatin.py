"""Non-Latin employer names must not collapse onto each other.

Before the fix ``_norm_org`` was ASCII-only, so every CJK, Cyrillic or Arabic
employer normalised to "". Two different employers then compared equal and
the employer conflict in ``_select_current_employer`` never fired.

Synthetic org names only. The RED arms are the ones that fail on the old
ASCII-only normaliser.
"""
from __future__ import annotations

import unittest
from unittest.mock import patch

import sys as _sys
from pathlib import Path as _Path
_sys.path.insert(0, str(_Path(__file__).resolve().parent))
from test_people_list_endpoint import server  # noqa: E402  (ical-server with the ostler_security stub)

OPERATOR_URI = "https://schema.ostler.ai/ontology#user_testuser"

SYNTH_JA_A = "合成商事株式会社"
SYNTH_JA_B = "架空商会有限会社"
SYNTH_RU_A = "Синтез Холдинг"
SYNTH_RU_B = "Пример Групп"
SYNTH_AR_A = "شركة تركيبية"
SYNTH_AR_B = "مؤسسة وهمية"


def _open_rows(orgs):
    return [
        {
            "fact": "https://schema.ostler.ai/ontology#fact_%d" % i,
            "org": org,
            "startDate": "2023-01",
            "factText": "… to present",
        }
        for i, org in enumerate(orgs)
    ]


def _select(orgs):
    rows = _open_rows(orgs)

    def _fake(sparql):
        if 'pwg:factType "career_position"' in sparql:
            return list(rows)
        return []

    with patch.object(server, "USER_URI", OPERATOR_URI), \
            patch.object(server, "_sparql_select", side_effect=_fake), \
            patch.object(server, "_hygiene_verdicts", return_value={}), \
            patch.object(server, "_operator_email_domains", return_value=set()):
        return server._select_current_employer()


class NormOrgKeepsNonLatin(unittest.TestCase):
    # RED on the old ASCII-only normaliser: each assert below returned "".
    def test_cjk_org_has_a_key(self):
        self.assertTrue(server._norm_org(SYNTH_JA_A))

    def test_distinct_cjk_orgs_have_distinct_keys(self):
        self.assertNotEqual(server._norm_org(SYNTH_JA_A), server._norm_org(SYNTH_JA_B))

    def test_distinct_cyrillic_orgs_have_distinct_keys(self):
        self.assertNotEqual(server._norm_org(SYNTH_RU_A), server._norm_org(SYNTH_RU_B))

    def test_distinct_arabic_orgs_have_distinct_keys(self):
        self.assertNotEqual(server._norm_org(SYNTH_AR_A), server._norm_org(SYNTH_AR_B))

    def test_orgs_differ_is_true_for_distinct_cjk(self):
        self.assertTrue(server._orgs_differ(SYNTH_JA_A, SYNTH_JA_B))

    # Controls: must hold on the old code too.
    def test_control_latin_punctuation_still_ignored(self):
        self.assertEqual(server._norm_org("Acme Ltd."), "acmeltd")

    # RED on the old code (fullwidth letters were dropped to "").
    def test_fullwidth_folds_to_ascii(self):
        self.assertEqual(server._norm_org("ＡＣＭＥ"), server._norm_org("acme"))

    def test_control_same_org_different_case_still_equal(self):
        self.assertFalse(server._orgs_differ("Acme Ltd.", "ACME LTD"))


class EmptyKeyIsNeverAMatch(unittest.TestCase):
    def test_empty_key_is_unknown_not_equal_to_other_unknown(self):
        # Symbols-only strings have no letters: unknown, so they differ.
        self.assertTrue(server._orgs_differ("---", "***"))

    def test_empty_key_equal_only_to_identical_raw(self):
        self.assertFalse(server._orgs_differ("---", "---"))


class EmployerConflictFiresForNonLatin(unittest.TestCase):
    # RED on the old code: both orgs keyed "" so no conflict was raised.
    def test_two_cjk_open_ended_orgs_conflict(self):
        emp = _select([SYNTH_JA_A, SYNTH_JA_B])
        self.assertTrue(emp["found"])
        self.assertTrue(emp["conflict"])
        self.assertTrue(emp["conflicting_employers"])

    def test_two_cyrillic_open_ended_orgs_conflict(self):
        emp = _select([SYNTH_RU_A, SYNTH_RU_B])
        self.assertTrue(emp["conflict"])

    def test_two_arabic_open_ended_orgs_conflict(self):
        emp = _select([SYNTH_AR_A, SYNTH_AR_B])
        self.assertTrue(emp["conflict"])

    # Control: the same CJK org listed twice is not a conflict.
    def test_control_same_cjk_org_twice_is_not_a_conflict(self):
        emp = _select([SYNTH_JA_A, SYNTH_JA_A])
        self.assertFalse(emp["conflict"])


if __name__ == "__main__":
    unittest.main()
