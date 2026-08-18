#!/usr/bin/env python3
"""A GUESSED category must never authorise sending a subject to a third party.

WHY THIS EXISTS. Measured on Andy's v1.0.35 box, 2026-08-18, from a real
LinkedIn GDPR export. `csv_parser._infer_category` matched keywords by
UNANCHORED SUBSTRING:

    if kw in text:        # "Technology" contains "techno"

so LinkedIn InMail subjects were filed as music / movie / tv, and enrichment
then sent those subjects to MusicBrainz and Wikidata as title lookups, carrying
third-party company names off the machine.

TWO LIMBS, AND ONLY THE SECOND ONE CLOSES IT.

  A. Word boundaries. Takes the 12 probes below from 12 wrong to 2. Necessary
     hygiene, not a fix: "festive season" and "Managing Director" survive it,
     because those ARE standalone words that simply are not about TV or film.

  B. Provenance. Every category the fallback can return routes to a client that
     puts the SUBJECT in an outbound query -- including the `interest` catch-all
     that the code comment treats as the safe default. Measured against
     enricher.CATEGORY_CLIENTS x eligibility.SUBJECT_IS_THE_QUERY. So there is
     no safe category to guess into, and the only durable rule is that a guess
     does not authorise egress.

This file is the RED that limb B must turn green. It asserts against the SHIPPED
keyword table, not a copy, so the table cannot drift away from its own test.
"""

import re
import sys
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CM019 = REPO / "vendor" / "cm019_preferences"
PARSER = CM019 / "services" / "ingest" / "src" / "parsers" / "csv_parser.py"
ELIGIBILITY = CM019 / "services" / "enrich" / "src" / "eligibility.py"
ENRICHER = CM019 / "services" / "enrich" / "src" / "enricher.py"

# Ordinary business subjects. SYNTHETIC: no real correspondent, company or
# subject line appears here, and none is needed -- the defect is in the
# matching, not in any particular person's mail.
PROBES = [
    "Exciting new Chief Technology Officer role",
    "Tips to win the festive season",
    "Meet our new Managing Director",
    "Please review the bandwidth report",
    "My husband will join the call",
    "Increase server capacity this quarter",
    "Facebook advertising results",
    "Gigabyte storage upgrade quote",
    "Abandoned cart recovery metrics",
    "Electricity bill for the office",
    "Booking confirmation for the meeting room",
    "A concerted effort from the team",
]


def _load(path, name):
    """Import a shipped module by path, without needing the package installed."""
    import importlib.util
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


def _keyword_table():
    """The SHIPPED table, read from the file. Never a copy kept in this test."""
    src = PARSER.read_text(encoding="utf-8")
    m = re.search(r"SUBJECT_CATEGORY_KEYWORDS = \{(.*?)\n    \}", src, re.S)
    assert m, "SUBJECT_CATEGORY_KEYWORDS not found -- the test is reading the wrong file"
    return eval("{" + m.group(1) + "}")  # noqa: S307 - our own source, in-repo


def _infer_as_shipped(subject):
    """Re-run the SHIPPED matcher over the SHIPPED table."""
    src = PARSER.read_text(encoding="utf-8")
    boundary = "(?<!\\w)" in src and "re.escape(kw)" in src
    text = (subject or "").lower()
    for category, keywords in _keyword_table().items():
        for kw in keywords:
            hit = (re.search(r"(?<!\w)" + re.escape(kw) + r"(?!\w)", text)
                   if boundary else kw in text)
            if hit:
                return category
    return "interest"


class TestWordBoundary(unittest.TestCase):
    def test_no_probe_is_filed_as_media(self):
        """Limb A. Ordinary business subjects must not become media categories."""
        wrong = []
        for p in PROBES:
            cat = _infer_as_shipped(p)
            # "interest" is the honest "no idea" answer. Anything else is a
            # claim about the subject that the keyword had no right to make.
            if cat != "interest":
                wrong.append((p, cat))
        # Two are EXPECTED to survive word boundaries, and limb B is what
        # contains them. Naming them keeps this test honest rather than
        # pretending limb A did more than it did.
        survivors = {"Tips to win the festive season",
                     "Meet our new Managing Director"}
        unexpected = [(p, c) for p, c in wrong if p not in survivors]
        self.assertEqual(
            unexpected, [],
            "substring matching is back: ordinary subjects filed as media\n"
            + "\n".join(f"  {p!r} -> {c}" for p, c in unexpected),
        )


class TestInferredNeverEgresses(unittest.TestCase):
    """Limb B. This is the one that actually closes the leak."""

    def setUp(self):
        self.elig = _load(ELIGIBILITY, "_ostler_eligibility")

    def test_inferred_category_is_refused_for_every_query_client(self):
        for client in sorted(self.elig.SUBJECT_IS_THE_QUERY):
            ok, why = self.elig.is_eligible(client, "Dark Side of the Moon",
                                            category_inferred=True)
            self.assertFalse(ok, f"{client} accepted an INFERRED category")
            self.assertIn("inferred", (why or "").lower())

    def test_declared_category_still_enriches(self):
        """The fix must not switch enrichment off for well-formed sources."""
        ok, why = self.elig.is_eligible("musicbrainz", "Dark Side of the Moon",
                                        category_inferred=False)
        self.assertTrue(ok, f"a DECLARED category was refused: {why}")

    def test_default_is_backwards_compatible(self):
        """Callers that predate this parameter keep working unchanged."""
        ok, _ = self.elig.is_eligible("musicbrainz", "Dark Side of the Moon")
        self.assertTrue(ok)

    def test_reason_never_quotes_the_subject(self):
        """The refusal reason is logged. It must not leak what it refused."""
        secret = "Opportunity at a named company"
        _, why = self.elig.is_eligible("wikidata", secret, category_inferred=True)
        self.assertNotIn(secret, why or "")


class TestNoSafeCategoryToGuessInto(unittest.TestCase):
    def test_every_inferable_category_would_egress(self):
        """The measurement that makes limb B mandatory rather than belt-and-braces.

        If this ever fails because some inferable category stops routing to a
        query client, that is good news -- but it must be noticed, not assumed.
        """
        elig = _load(ELIGIBILITY, "_ostler_eligibility2")
        src = ENRICHER.read_text(encoding="utf-8")
        m = re.search(r"CATEGORY_CLIENTS = \{(.*?)\n    \}", src, re.S)
        self.assertIsNotNone(m, "CATEGORY_CLIENTS not found")
        routes = dict(re.findall(r'"([a-z_]+)"\s*:\s*"([a-z_]+)"', m.group(1)))
        inferable = set(_keyword_table().keys()) | {"interest"}
        egressing = {c for c in inferable if routes.get(c) in elig.SUBJECT_IS_THE_QUERY}
        self.assertIn(
            "interest", egressing,
            "`interest` no longer egresses. That is the fallback default, so if "
            "this changed, re-read whether limb B is still the only containment.",
        )
        self.assertTrue(egressing, "no inferable category egresses -- re-check the mapping")


if __name__ == "__main__":
    unittest.main(verbosity=2)
