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
BASE = CM019 / "services" / "ingest" / "src" / "parsers" / "base.py"
FILTERS = CM019 / "services" / "ingest" / "src" / "filters.py"

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

    def test_unrecorded_provenance_is_refused(self):
        """THE ONE TNM FOUND IN REVIEW, and it inverts what this test used to say.

        An earlier version of this file asserted the opposite -- that omitting
        the parameter kept the old behaviour -- under the heading "callers that
        predate this parameter keep working unchanged". That is precisely the
        false all-clear: a preference stored before the field existed came back
        as "not inferred", which reads identically to "the source declared it".

        It matters because the recurring enrichment agent feeds on the corpus
        that ALREADY EXISTS on the box, and on an upgraded install every row in
        that corpus predates the field. The gate would have reported clean
        having protected nothing.

        Unknown provenance now refuses, and the reason says WHY it refused
        rather than borrowing the "inferred" wording, because the operator
        reading the log needs to tell "we guessed" from "we never recorded".
        """
        ok, why = self.elig.is_eligible("musicbrainz", "Dark Side of the Moon")
        self.assertFalse(ok, "an omitted provenance was treated as declared")
        self.assertIn("unrecorded", (why or "").lower())

        ok_explicit, _ = self.elig.is_eligible("musicbrainz", "Dark Side of the Moon",
                                               category_inferred=None)
        self.assertFalse(ok_explicit, "an explicit None was treated as declared")

    def test_the_three_states_are_distinguishable(self):
        """False enriches, True refuses, None refuses. Three states, not two."""
        verdicts = {
            state: self.elig.is_eligible("musicbrainz", "Dark Side of the Moon",
                                         category_inferred=state)[0]
            for state in (False, True, None)
        }
        self.assertEqual(verdicts, {False: True, True: False, None: False})

    def test_the_reader_does_not_flatten_absence_to_false(self):
        """`bool()` around the read would undo all of this in one character.

        The three-state gate only works if absence reaches it as None. Wrapping
        the payload read in `bool()` collapses None to False, which is the
        "source declared it" branch, and every pre-existing row starts
        egressing again while every test above still passes -- because they all
        call `is_eligible` directly and never go through this line.
        """
        src = ENRICHER.read_text(encoding="utf-8")
        m = re.search(r"category_inferred=(.+?),\n", src)
        self.assertIsNotNone(m, "the is_eligible call site moved -- re-read this test")
        arg = m.group(1)
        self.assertNotIn(
            "bool(", arg,
            "the enricher coerces the provenance read with bool(), so a row "
            f"stored before the field existed arrives as False, not None: {arg}",
        )

    def test_reason_never_quotes_the_subject(self):
        """The refusal reason is logged. It must not leak what it refused."""
        secret = "Opportunity at a named company"
        _, why = self.elig.is_eligible("wikidata", secret, category_inferred=True)
        self.assertNotIn(secret, why or "")


class TestEveryWrittenRowStatesItsProvenance(unittest.TestCase):
    """The writer half of the contract the reader above depends on.

    Refusing unknown provenance is only safe if rows written from now on are
    never unknown. There are 23 parsers and exactly one of them (csv_parser)
    has any opinion about inferred categories, so the guarantee cannot live in
    the parsers -- it lives in ParsedPreference.to_payload(), which every row
    passes through on its way to Qdrant.

    Without this, the reader's refusal would take enrichment dark for all 22
    other sources, and the first anyone would know is a customer asking why
    nothing enriches.
    """

    def setUp(self):
        self.base = _load(BASE, "_ostler_parsers_base")

    def test_payload_always_states_provenance(self):
        p = self.base.ParsedPreference(subject="Dark Side of the Moon",
                                       source="spotify", category="music")
        payload = p.to_payload("test-user")
        self.assertIn("extra", payload,
                      "a parser that sets no extra produced a payload with no provenance")
        self.assertIn("category_inferred", payload["extra"])
        self.assertIs(payload["extra"]["category_inferred"], False)

    def test_an_explicit_inferred_flag_is_not_overwritten(self):
        """setdefault, not assignment. csv_parser's True must survive."""
        p = self.base.ParsedPreference(subject="Technology roundup", source="csv",
                                       category="music",
                                       extra={"category_inferred": True})
        self.assertIs(p.to_payload("test-user")["extra"]["category_inferred"], True)

    def test_other_extra_keys_are_preserved(self):
        p = self.base.ParsedPreference(subject="x", source="csv",
                                       extra={"frequency": 3})
        extra = p.to_payload("test-user")["extra"]
        self.assertEqual(extra["frequency"], 3)
        self.assertIs(extra["category_inferred"], False)

    def test_the_aggregation_step_carries_the_flag(self):
        """The middle hop, which was the joint I could not vouch for.

        `filters.py` rebuilds `extra` during frequency aggregation. It spreads
        `**pref.extra` FIRST and then adds its own keys, so the flag survives.
        That ordering is the whole contract, and it is one edit away from being
        silently reversed, so it is asserted against the shipped source rather
        than trusted.
        """
        src = FILTERS.read_text(encoding="utf-8")
        m = re.search(r"extra=\{\s*\n\s*\*\*pref\.extra\s*,", src)
        self.assertIsNotNone(
            m,
            "filters.py no longer spreads **pref.extra first when rebuilding "
            "extra during aggregation. If that dict is now composed without the "
            "spread, category_inferred is dropped between the parser and Qdrant "
            "and the egress gate silently stops seeing inferred rows.",
        )


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
