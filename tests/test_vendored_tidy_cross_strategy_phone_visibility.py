"""CM051 walk #3, item E (v1.0.107): a duplicate pair's evidence must name
every shared identifier, not just the strategy that won the confidence slot.
Mirrors CM041 PR #188's own test suite against the copy that actually ships
(vendor/cm041).

consolidate_matches keeps only the HIGHEST-confidence match per pair, so a
pair that shares both an email and a phone is filed under email_match
(1.0 beats phone_match's 0.95 ceiling) -- measured on a cold v1.0.107
install: 34 of 104 phone-matched pairs were "won" by a different strategy
this way, so the winning item's own evidence never mentioned the phone.
The pair WAS already merged/reviewed; nothing reading evidence for "is this
phone already surfaced" (the walk probe) could tell.

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
    # Different given names so exact_name does NOT also fire; fuzzy_name
    # fires naturally (Mike/Michael are similar), which is correct -- every
    # strategy that matched this pair belongs in the evidence.
    persons = _persons(
        _make_person(
            "f1", "Mike User",
            emails={"tuser@example.test"}, phones={"+447700900140"},
        ),
        _make_person(
            "f2", "Michael User",
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
    is only one. Unrelated names so nothing else (exact_name, fuzzy_name,
    name_subset) also fires."""
    persons = _persons(
        _make_person("f3", "Mike User", emails={"single@example.test"}),
        _make_person("f4", "Priya Patel", emails={"single@example.test"}),
    )
    engine = _NoGraphEngine()
    try:
        report = engine.build_report(persons=persons)
    finally:
        engine.close()
    dup_items = [it for it in report.items if it.item_type == ITEM_MERGE_DUPLICATE]
    assert len(dup_items) == 1
    assert "other_strategies" not in dup_items[0].evidence
