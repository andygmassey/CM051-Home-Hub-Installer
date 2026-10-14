"""DMG #27 item 4: an identical full name is a "Same person?" SUGGESTION, never
an automatic merge (Archie ruling: merging two different people is data loss).

The walk: one real contact split across three nodes, identical full name,
different employer cards, no shared phone or email. A suggestion is offered
when the full names are identical AND (the employers overlap OR every record is
a card in the owner's own Contacts) AND no identifier conflicts. Everything
else stays apart. Executes the shipped batch_resolver detection end to end
(detect(), with only the graph read replaced). Cast names only.
"""
from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "vendor" / "cm041"))
os.environ.setdefault("OSTLER_PERSON_DELETION_LOG", os.path.join(tempfile.mkdtemp(), "r.jsonl"))

from identity_resolver import batch_resolver as br  # noqa: E402

N = [0]


def rec(name, org="", cards=(), phones=(), emails=()):
    N[0] += 1
    p = br.PersonRecord(uri=f"https://example.invalid/person_{N[0]:04d}", display_name=name,
                        organization=org)
    if org:
        p.organizations.add(org)
    p.contact_card_uids.update(cards)
    p.phones.update(phones)
    for e in emails:
        p.emails.add(e)
        p.email_domains.add(e.split("@", 1)[1])
    return p


def detect(records):
    persons = {p.uri: p for p in records}
    r = br.BatchResolver.__new__(br.BatchResolver)
    r.oxigraph_url, r.config = "http://unused.invalid", dict(br.DEFAULT_CONFIG)
    r._client = None
    orig = br._fetch_all_persons
    br._fetch_all_persons = lambda url, client, config: persons
    try:
        report = r.detect()
    finally:
        br._fetch_all_persons = orig
    return report


def _pairs(items, strategy=None):
    out = set()
    for m in items:
        a, b = (m.keep_uri, m.discard_uri) if hasattr(m, "keep_uri") else (m.uri_a, m.uri_b)
        if strategy is None or getattr(m, "strategy", None) == strategy:
            out.add(frozenset((a, b)))
    return out


def test_split_contact_across_three_employer_cards_is_suggested_not_merged():
    recs = [rec("Sam Smith", "Acme Ltd", cards=["CARD-1"]),
            rec("Sam Smith", "Globex", cards=["CARD-2"]),
            rec("Sam Smith", "Initech", cards=["CARD-3"])]
    report = detect(recs)
    assert report.auto_merges == []
    sugg = _pairs(report.needs_review, "same_name_suggest")
    assert len(sugg) == 3
    assert all("Same person?" in m.details for m in report.needs_review)


def test_two_cards_with_overlapping_employers_are_suggested():
    recs = [rec("Jane Doe", "Acme Ltd", cards=["CARD-A"]),
            rec("Jane Doe", "ACME", cards=["CARD-B"])]
    report = detect(recs)
    assert report.auto_merges == []
    assert _pairs(report.needs_review, "same_name_suggest") == {frozenset(p.uri for p in recs)}


def test_a_common_name_at_different_employers_stays_apart():
    # Not cards from the owner's Contacts: e.g. two people met through work.
    recs = [rec("John Smith", "Acme Ltd"), rec("John Smith", "Globex")]
    report = detect(recs)
    assert report.auto_merges == []
    assert report.needs_review == []


def test_conflicting_phones_stay_apart_even_as_cards_at_one_employer():
    recs = [rec("Bob Jones", "Acme", cards=["CARD-X"], phones=["+1555" + "0100001"]),
            rec("Bob Jones", "Acme", cards=["CARD-Y"], phones=["+1555" + "0100002"])]
    report = detect(recs)
    assert report.auto_merges == []
    assert report.needs_review == []


def test_mixed_sources_at_different_employers_stay_apart():
    # One card, one non-card node: not "all cards from the owner's Contacts".
    recs = [rec("Alex Brown", "Acme", cards=["CARD-Z"]), rec("Alex Brown", "Globex")]
    report = detect(recs)
    assert report.auto_merges == []
    assert report.needs_review == []


def test_suggestion_confidence_sits_between_review_and_auto():
    c = br.DEFAULT_CONFIG
    assert c["review_threshold"] <= c["same_name_suggest_confidence"] < c["auto_merge_threshold"]
