#!/usr/bin/env python3
"""Provenance survives the aggregation and warm paths, PROVED BY RUNNING THEM.

WHY THIS EXISTS, and it is a fair criticism landing rather than a new idea.

The #410 suite asserts that `filters.py` spreads `**pref.extra` first when it
rebuilds `extra` during aggregation. TNM reviewed that and said, correctly:

    "test_the_aggregation_step_carries_the_flag is a regex over source text and
     never calls PreferenceFilter. Across the 281-line file: PreferenceFilter 0,
     warm_from_payloads 0, add_or_aggregate 0, get_aggregated_preferences 0. It
     goes red if anyone reflows that dict onto one line while behaviour is
     perfect, and stays green through any aggregation defect that keeps the
     spread. Fine as a tripwire, but the middle is still uncovered by execution."

Both halves of that are true. A source-text assertion is sensitive to spelling
and blind to behaviour, which is the wrong way round for the one hop between a
parser that records provenance and a gate that reads it. The regex tripwire is
kept, because it catches a deliberate rewrite that this file would not, and
this file is added because it catches a behavioural break the regex cannot see.

TWO THINGS ARE MEASURED HERE, BY EXECUTION:

  1. AGGREGATION. A preference carrying category_inferred=True goes through the
     real PreferenceFilter and comes back out still carrying it.

  2. THE WARM PATH, which is the one that can defeat the egress gate.
     `warm_from_payloads` is the only place a ParsedPreference is built by
     something that is not a parser. A row stored before the field existed has
     no key; if that placeholder is written back, to_payload's
     setdefault(..., False) would stamp it DECLARED, which authorises egress.

     Today that cannot happen, and NOT by design: _make_dedup_key builds
     `source:signal_type:normalized` while warm_from_payloads builds
     `source:normalized`, so warmed entries are unreachable. The hole is closed
     by a key mismatch. Adding signal_type to the warm key is an obvious and
     correct fix somebody will eventually make, and it would silently re-open
     the hole. So the placeholder is stamped fail-closed at creation, and this
     test asserts that stamping rather than the accident.
"""

import importlib.util
import sys
import types
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SRC = REPO / "vendor" / "cm019_preferences" / "services" / "ingest" / "src"
ELIGIBILITY = (REPO / "vendor" / "cm019_preferences" / "services" / "enrich"
               / "src" / "eligibility.py")


def _load_ingest_package():
    """Load filters.py with its relative import satisfied.

    filters.py does `from .parsers.base import ParsedPreference`, so it cannot
    be loaded as a lone file. Build the minimum real package around it rather
    than copying ParsedPreference into this test, because a copied dataclass
    would not have the to_payload() behaviour that is the whole point.
    """
    pkg = types.ModuleType("_ost_ingest")
    pkg.__path__ = [str(SRC)]
    sys.modules["_ost_ingest"] = pkg

    parsers = types.ModuleType("_ost_ingest.parsers")
    parsers.__path__ = [str(SRC / "parsers")]
    sys.modules["_ost_ingest.parsers"] = parsers

    def _load(name, path):
        spec = importlib.util.spec_from_file_location(name, path)
        mod = importlib.util.module_from_spec(spec)
        sys.modules[name] = mod
        spec.loader.exec_module(mod)
        return mod

    base = _load("_ost_ingest.parsers.base", SRC / "parsers" / "base.py")
    filters = _load("_ost_ingest.filters", SRC / "filters.py")
    return base, filters


BASE, FILTERS = _load_ingest_package()


def _load_eligibility():
    spec = importlib.util.spec_from_file_location("_ost_elig", ELIGIBILITY)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["_ost_elig"] = mod
    spec.loader.exec_module(mod)
    return mod


ELIG = _load_eligibility()


def _pref(subject, inferred, source="csv"):
    return BASE.ParsedPreference(
        subject=subject,
        preference_type="Like",
        category="music",
        strength=0.6,
        source=source,
        extra={"category_inferred": inferred},
    )


class TestAggregationCarriesProvenance(unittest.TestCase):
    """Limb 1. The real filter, executed, not a regex over its source."""

    def test_inferred_flag_survives_a_real_aggregation_pass(self):
        f = FILTERS.PreferenceFilter(aggregate_frequency=True)
        p = _pref("Technology roundup", True)
        self.assertTrue(f.should_include(p), "fixture rejected before the test began")
        f.is_duplicate(p)

        out = f.get_aggregated_preferences()
        self.assertTrue(out, "aggregation returned nothing; the fixture never entered")
        self.assertIs(
            out[0].extra.get("category_inferred"), True,
            "aggregation DROPPED category_inferred. The egress gate reads this "
            "field; without it an inferred subject is treated as declared and "
            "goes to a third party.",
        )

    def test_declared_flag_also_survives(self):
        """The control. If aggregation forced True, limb 1 would be vacuous."""
        f = FILTERS.PreferenceFilter(aggregate_frequency=True)
        p = _pref("Dark Side of the Moon", False)
        f.is_duplicate(p)
        out = f.get_aggregated_preferences()
        self.assertTrue(out)
        self.assertIs(out[0].extra.get("category_inferred"), False)

    def test_the_aggregated_row_still_decides_correctly_at_the_gate(self):
        """End to end across the seam: filter output straight into is_eligible."""
        f = FILTERS.PreferenceFilter(aggregate_frequency=True)
        f.is_duplicate(_pref("Technology roundup", True))
        aggregated = f.get_aggregated_preferences()[0]
        payload = aggregated.to_payload("test-user")

        ok, why = ELIG.is_eligible(
            "musicbrainz",
            payload["subject"],
            category_inferred=payload["extra"].get("category_inferred"),
        )
        self.assertFalse(ok, "an inferred subject survived the whole pipeline eligible")
        self.assertIn("inferred", (why or "").lower())


class TestWarmedRowsCannotClaimDeclaredProvenance(unittest.TestCase):
    """Limb 2. The path that can defeat the gate if it ever becomes reachable."""

    STORED_PRE_FIELD = {
        "subject": "Technology roundup",
        "source": "csv",
        "category": "music",
        "preference_type": "Like",
        "strength": 0.6,
        "compartment_level": 2,
        # No `extra` at all: this is what a row stored before the provenance
        # field existed actually looks like on a customer's box.
    }

    def test_a_pre_field_row_warms_in_as_inferred_not_declared(self):
        f = FILTERS.PreferenceFilter(aggregate_frequency=True)
        loaded = f.warm_from_payloads([dict(self.STORED_PRE_FIELD)])
        self.assertEqual(loaded, 1, "the fixture did not warm; the test proved nothing")

        placeholders = [p for p, _ in f._aggregated.values()]
        self.assertEqual(len(placeholders), 1)
        self.assertIs(
            placeholders[0].extra.get("category_inferred"), True,
            "a row with UNRECORDED provenance warmed in without being marked "
            "inferred. If the warm dedup key is ever fixed to match "
            "_make_dedup_key, this row becomes the representative, gets written "
            "back with category_inferred=False, and every pre-existing "
            "preference on an upgraded box starts egressing again.",
        )

    def test_write_back_of_a_warmed_row_is_refused_at_the_gate(self):
        """The consequence, measured rather than reasoned about."""
        f = FILTERS.PreferenceFilter(aggregate_frequency=True)
        f.warm_from_payloads([dict(self.STORED_PRE_FIELD)])
        placeholder = [p for p, _ in f._aggregated.values()][0]

        payload = placeholder.to_payload("test-user")
        ok, why = ELIG.is_eligible(
            "musicbrainz",
            payload["subject"],
            category_inferred=payload["extra"].get("category_inferred"),
        )
        self.assertFalse(ok, "a warmed pre-field row was eligible for egress")
        self.assertIn("inferred", (why or "").lower())

    def test_a_row_that_recorded_declared_provenance_keeps_it(self):
        """The discriminating control: warming must not mark EVERYTHING inferred.

        Without this, limb 2 would pass on a placeholder that hardcoded True,
        and enrichment would go dark for every row on every box, which would be
        read as the gate working rather than as the product being broken.
        """
        stored = dict(self.STORED_PRE_FIELD)
        stored["extra"] = {"category_inferred": False}
        f = FILTERS.PreferenceFilter(aggregate_frequency=True)
        f.warm_from_payloads([stored])
        placeholder = [p for p, _ in f._aggregated.values()][0]
        self.assertIs(placeholder.extra.get("category_inferred"), False)


class TestTheKeyMismatchIsRecordedNotRelieduOn(unittest.TestCase):
    """The accident that currently closes the hole, pinned so it is visible.

    This does NOT assert the keys stay different. It asserts that IF they are
    different, the reason is the signal_type segment, so that whoever fixes the
    warm key finds this test and the comment above it rather than discovering
    the coupling from a customer's outbound traffic.
    """

    def test_the_two_key_builders_are_measured_not_assumed(self):
        src = (SRC / "filters.py").read_text(encoding="utf-8")
        self.assertIn('f"{pref.source}:{signal_type}:{normalized}"', src,
                      "_make_dedup_key changed shape; re-read the warm-path comment")
        self.assertIn('f"{source}:{normalized}"', src,
                      "the warm key changed shape; if it now matches "
                      "_make_dedup_key, warmed rows are REACHABLE and the "
                      "fail-closed stamp in warm_from_payloads is the only "
                      "thing preventing pre-field rows from egressing. Verify "
                      "that stamp is still there before relaxing anything.")


if __name__ == "__main__":
    unittest.main(verbosity=2)
