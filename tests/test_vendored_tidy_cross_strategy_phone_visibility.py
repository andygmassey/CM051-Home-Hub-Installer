"""CM051 walk #3 and #4, item E (v1.0.107): a duplicate pair's evidence must
name every shared identifier, not just the strategy that won the confidence
slot. Mirrors CM041 PR #188 and #189's own test suites against the copy that
actually ships (vendor/cm041).

Walk #3: consolidate_matches keeps only the HIGHEST-confidence match per
pair, so a pair that shares both an email and a phone is filed under
email_match (1.0 beats phone_match's 0.95 ceiling) -- measured on a cold
v1.0.107 install: 34 of 104 phone-matched pairs were "won" by a different
strategy this way, so the winning item's own evidence never mentioned the
phone. The pair WAS already merged/reviewed; nothing reading evidence for
"is this phone already surfaced" (the walk probe) could tell.

Walk #4: the walk #3 fix only folded in matches whose STRATEGY differed
from the winner's, so two people sharing TWO DIFFERENT phone numbers (two
phone_match entries for the same pair) still had one number dropped --
same strategy, different value, not caught by a strategy-name filter.

All identifiers/numbers here are synthetic (Rule 0): no real personal data.
"""
from __future__ import annotations

import pathlib
import sys
from typing import Dict

ROOT = pathlib.Path(__file__).resolve().parent.parent
VENDOR_CM041 = ROOT / "vendor" / "cm041"
if not VENDOR_CM041.is_dir():
    raise SystemExit(f"vendored cm041 missing: {VENDOR_CM041} (broken vendor layout)")
sys.path.insert(0, str(VENDOR_CM041))

from identity_resolver.batch_resolver import PersonRecord  # noqa: E402
from identity_resolver.tidy import ITEM_MERGE_DUPLICATE, TidyEngine  # noqa: E402

PWG = "https://schema.ostler.ai/ontology#"


def _make_person(short_id: str, name: str, *, phones=None, emails=None) -> PersonRecord:
    emails = emails or set()
    return PersonRecord(
        uri=f"{PWG}person_{short_id}",
        display_name=name,
        phones=phones or set(),
        emails=emails,
        email_domains={e.split("@")[-1] for e in emails if "@" in e},
        triple_count=10,
    )


def _persons(*records: PersonRecord) -> Dict[str, PersonRecord]:
    return {r.uri: r for r in records}


class _NoGraphEngine(TidyEngine):
    """TidyEngine that never touches a live graph - build_report is fed a dict."""


def test_a_pair_sharing_both_email_and_phone_mentions_both_in_one_item():
    # Jane/John share a surname (so fuzzy_name also fires on "doe"), but
    # neither the given names nor the full names match (so exact_name does
    # NOT fire) -- measured directly: phone_match registers at 0.6
    # (names_agree returns "unsure" for jane/john) and fuzzy_name at 0.7.
    # Both are correct: every strategy that matched this pair belongs in
    # the evidence, not just the highest-scoring one.
    persons = _persons(
        _make_person(
            "f1", "Jane Doe",
            emails={"tuser@example.test"}, phones={"+447700900140"},
        ),
        _make_person(
            "f2", "John Doe",
            emails={"tuser@example.test"}, phones={"+447700900140"},
        ),
    )
    engine = _NoGraphEngine()
    try:
        report = engine.build_report(persons=persons)
    finally:
        engine.close()

    dup_items = [it for it in report.items if it.item_type == ITEM_MERGE_DUPLICATE]
    assert len(dup_items) == 1, (
        "one pair sharing two identifiers must produce ONE item, not one per strategy"
    )
    it = dup_items[0]
    assert it.evidence["strategy"] == "email_match", (
        "email_match (1.0) must still win the confidence slot -- this fix "
        "must not change WHICH strategy is reported as primary"
    )
    assert "+447700900140" in it.evidence["details"], (
        "the shared phone must be named in the winning item's own evidence, "
        "even though a different strategy won the pair"
    )
    assert it.evidence.get("other_strategies") == ["fuzzy_name", "phone_match"]


def test_a_pair_sharing_only_one_identifier_lists_no_other_strategies():
    """CONTROL: the enrichment must not invent a second reason where there
    is only one. Names with zero similarity (measured directly: no
    exact_name, fuzzy_name or name_subset match) so nothing else fires."""
    persons = _persons(
        _make_person("f3", "Jane Doe", emails={"single@example.test"}),
        _make_person("f4", "Carl Stewart", emails={"single@example.test"}),
    )
    engine = _NoGraphEngine()
    try:
        report = engine.build_report(persons=persons)
    finally:
        engine.close()
    dup_items = [it for it in report.items if it.item_type == ITEM_MERGE_DUPLICATE]
    assert len(dup_items) == 1
    assert "other_strategies" not in dup_items[0].evidence


def test_a_pair_sharing_two_different_phone_numbers_mentions_both():
    """CM051 walk #4, item E. Two shared phone numbers between the same pair
    produce TWO phone_match DuplicateMatch objects for that one pair-key.
    consolidate_matches keeps only the highest-confidence one per pair -- a
    tie, since both are phone_match at the same confidence -- so the walk
    #3 fix (which only folded in OTHER STRATEGIES) still dropped the second
    number: same strategy, just a different value.
    """
    persons = _persons(
        _make_person("g1", "Jane Doe", phones={"+447700900151", "+447700900152"}),
        _make_person("g2", "John Doe", phones={"+447700900151", "+447700900152"}),
    )
    engine = _NoGraphEngine()
    try:
        report = engine.build_report(persons=persons)
    finally:
        engine.close()

    dup_items = [it for it in report.items if it.item_type == ITEM_MERGE_DUPLICATE]
    assert len(dup_items) == 1, (
        "one pair sharing two phone numbers must produce ONE item, not two"
    )
    details = dup_items[0].evidence["details"]
    assert "+447700900151" in details
    assert "+447700900152" in details
