"""P13: a number-named person is the Contacts person who holds that number.

v1.0.117 walk box (counts only): 41 Person nodes named by a "+" number, all
provisional (WhatsApp 39, iMessage 2); 14 carry a phone identifier that sits
on another Person, and for all 14 that Person is a Contacts card, created
FIRST, and the only other holder. Root cause: ``pwg_ingest.ingest_whatsapp`` /
``ingest_imessage`` mint ``uuid5(handle)`` and never ask who already holds the
number, and the one twin sweep (``dedupe_merge.run``) runs at install only and
compares identifier STRINGS. See vendor/ostler_fda/phone_twins.py.

Real SPARQL end to end: the ingest and the sweep talk HTTP to a
pyoxigraph-backed fake Oxigraph. Fictional cast (Jane Smith, Tom Jones,
Sam Doe), reserved numbers (+44 7700 900xxx mobiles, 020 7946 0xxx landline).
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
import types
from pathlib import Path

import pytest

pytest.importorskip("pyoxigraph")

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "vendor" / "cm041"))
sys.path.insert(0, str(ROOT / "vendor"))
sys.path.insert(0, str(ROOT / "tests"))
os.environ.setdefault("OSTLER_PERSON_DELETION_LOG", os.path.join(tempfile.mkdtemp(), "r.jsonl"))

from _fake_oxigraph import FakeOxigraph  # noqa: E402

PWG = "https://schema.ostler.ai/ontology#"
JANE = PWG + "contact_jane_smith"
TOM = PWG + "contact_tom_jones"
JANE_MOBILE_E164 = "+44" + "7700900123"
JANE_MOBILE_NATIONAL = "07700 900123"     # how her card stores it
TOM_MOBILE = "+44 7700 900124"
TOM_US_CARD = "+1 202-555-0142"
TOM_US_E164 = "+1" + "2025550142"
LANDLINE_NATIONAL = "020 7946 0001"       # on BOTH family cards
LANDLINE_E164 = "+44" + "2079460001"
WHEN = "2026-10-20T09:30:00Z"


@pytest.fixture()
def world(tmp_path, monkeypatch):
    store = FakeOxigraph()
    monkeypatch.setenv("OSTLER_FORGET_TOMBSTONE_FILE", str(tmp_path / "forgotten.json"))
    monkeypatch.setenv("OSTLER_IDENTIFIER_QUALITY_STATE", str(tmp_path / "iq.json"))
    monkeypatch.setenv("DEFAULT_COUNTRY_CODE", "44")
    from ostler_fda import dedupe_merge, pwg_ingest
    monkeypatch.setattr(pwg_ingest, "OXIGRAPH_URL", store.url)
    monkeypatch.setattr(dedupe_merge, "OXIGRAPH_URL", store.url)
    fda = tmp_path / "fda"
    fda.mkdir()
    yield types.SimpleNamespace(store=store, fda=fda, ing=pwg_ingest, dm=dedupe_merge)
    store.close()


def _rows(w, sparql):
    with w.store.lock:
        return list(w.store.ds.query("PREFIX pwg: <%s>\n%s" % (PWG, sparql)))


def _persons(w):
    return {r["p"].value for r in _rows(w, "SELECT DISTINCT ?p WHERE { ?p a pwg:Person }")}


def _card(w, uri, name, uid, *phones):
    ids = " ".join(
        f'<{uri}> pwg:hasIdentifier <{uri}_p{i}> . <{uri}_p{i}> a pwg:PersonIdentifier ; '
        f'pwg:identifierType "phone" ; pwg:identifierValue "{v}" .'
        for i, v in enumerate(phones)
    )
    w.store.update(
        f'INSERT DATA {{ <{uri}> a pwg:Person ; pwg:displayName "{name}" . {ids} '
        f'<{uri}> pwg:hasIdentifier <{uri}_uid> . <{uri}_uid> a pwg:PersonIdentifier ; '
        f'pwg:identifierType "icloud_contact_uid" ; pwg:identifierValue "{uid}" }}')


def _whatsapp(w, *phones):
    (w.fda / "whatsapp_conversations.json").write_text(json.dumps([
        {"tier": "whatsapp_dm", "participants": [p.lstrip("+") + "@s.whatsapp.net"],
         "last_message": WHEN, "confidence": 1.0} for p in phones]))
    return w.ing.ingest_whatsapp(w.fda)


def _imessage(w, *handles):
    (w.fda / "imessage_conversations.json").write_text(json.dumps([
        {"participants": [h], "message_count": 3, "last_message": WHEN, "display_name": ""}
        for h in handles]))
    return w.ing.ingest_imessage(w.fda)


def _number_named(w):
    return {r["p"].value for r in _rows(
        w, 'SELECT ?p WHERE { ?p a pwg:Person ; pwg:displayName ?d . FILTER(REGEX(STR(?d), "^[+]?[0-9 ]+$")) }')}


# ── Prevention: the next message from a carded contact lands on the card ──

def test_whatsapp_from_a_carded_contact_lands_on_the_card_not_a_new_person(world):
    """WhatsApp writes a phone identifier only for a number phonenumbers
    validates (CM051 #2543), and the Ofcom drama range does not validate, so
    this one uses the NANP fictional 555-01xx range, stored on the card with
    spaces and dashes, never the E.164 string the handle carries."""
    w = world
    _card(w, TOM, "Tom Jones", "UID-TOM", TOM_US_CARD)
    stats = _whatsapp(w, TOM_US_E164)
    assert _persons(w) == {TOM}, "a number-named twin was minted for a carded contact"
    assert stats["people_linked_to_contact"] == 1, stats
    got = [r["v"].value for r in _rows(w, f"SELECT ?v WHERE {{ <{TOM}> pwg:lastContactWhatsApp ?v }}")]
    assert any(v.startswith(WHEN[:10]) for v in got), got


def test_imessage_from_a_carded_contact_lands_on_the_card_not_a_new_person(world):
    w = world
    _card(w, JANE, "Jane Smith", "UID-JANE", JANE_MOBILE_NATIONAL)
    stats = _imessage(w, JANE_MOBILE_E164)
    assert _persons(w) == {JANE}
    assert stats["people_linked_to_contact"] == 1, stats
    names = [r["n"].value for r in _rows(w, f"SELECT ?n WHERE {{ <{JANE}> pwg:displayName ?n }}")]
    assert names == ["Jane Smith"], names


def test_household_landline_on_two_cards_is_never_handed_to_either(world):
    """A shared detail alone is not identity: both family cards carry the
    landline, so a message from it must not be filed under either person."""
    w = world
    _card(w, JANE, "Jane Smith", "UID-JANE", JANE_MOBILE_NATIONAL, LANDLINE_NATIONAL)
    _card(w, TOM, "Tom Jones", "UID-TOM", TOM_MOBILE, LANDLINE_NATIONAL)
    stats = _imessage(w, LANDLINE_E164)
    assert stats["people_linked_to_contact"] == 0, stats
    assert len(_persons(w)) == 3, "the landline caller was folded into a family card"
    for card in (JANE, TOM):
        assert not _rows(w, f"SELECT ?v WHERE {{ <{card}> pwg:lastContactIMessage ?v }}"), card


def test_a_number_nobody_holds_still_makes_a_provisional_person(world):
    w = world
    _card(w, JANE, "Jane Smith", "UID-JANE", JANE_MOBILE_NATIONAL)
    _whatsapp(w, "+447700900999")
    assert len(_persons(w)) == 2


# ── Repair: twins already in the graph fold on the sweep ─────────────────

def _legacy_twin(w, phone):
    """The walk-box shape: the card exists, then a number-named node is
    minted for the same number (the pre-fix writer)."""
    uri = w.ing._person_uri(w.ing._person_id_from_identifier(phone))
    w.store.update(
        f'INSERT DATA {{ <{uri}> a pwg:Person ; pwg:displayName "{phone}" ; '
        f'pwg:displayNameProvisional "true"^^<http://www.w3.org/2001/XMLSchema#boolean> ; '
        f'pwg:source "whatsapp_fda" ; pwg:hasIdentifier <{uri}_id> . <{uri}_id> a pwg:PersonIdentifier ; '
        f'pwg:identifierType "phone" ; pwg:identifierValue "{phone}" }}')
    return uri


def test_the_sweep_folds_an_existing_number_named_twin_into_its_card(world):
    w = world
    _card(w, JANE, "Jane Smith", "UID-JANE", JANE_MOBILE_NATIONAL)
    twin = _legacy_twin(w, JANE_MOBILE_E164)
    stats = w.dm.run()
    assert stats["phone_twins_merged"] == 1, stats
    assert _persons(w) == {JANE}
    assert w.store.ask(f"ASK {{ <{twin}> pwg:mergedInto <{JANE}> }}")
    names = [r["n"].value for r in _rows(w, f"SELECT ?n WHERE {{ <{JANE}> pwg:displayName ?n }}")]
    assert names == ["Jane Smith"], names


def test_the_sweep_leaves_a_twin_of_a_household_landline_alone(world):
    w = world
    _card(w, JANE, "Jane Smith", "UID-JANE", LANDLINE_NATIONAL)
    _card(w, TOM, "Tom Jones", "UID-TOM", LANDLINE_NATIONAL)
    twin = _legacy_twin(w, LANDLINE_E164)
    stats = w.dm.run()
    assert stats["phone_twins_merged"] == 0 and stats["phone_twins_shared_refused"] == 1, stats
    assert twin in _persons(w) and JANE in _persons(w) and TOM in _persons(w)


def test_the_sweep_never_merges_two_named_cards_on_a_normalised_match(world):
    """Named-to-named stays the exact-string pass's business (RULE 1/2)."""
    w = world
    _card(w, JANE, "Jane Smith", "UID-JANE", JANE_MOBILE_NATIONAL)
    _card(w, TOM, "Tom Jones", "UID-TOM", JANE_MOBILE_E164)
    stats = w.dm.run()
    assert stats["phone_twins_merged"] == 0, stats
    assert {JANE, TOM} <= _persons(w)


def test_without_a_country_a_unique_trailing_match_still_folds(world, monkeypatch):
    w = world
    monkeypatch.delenv("DEFAULT_COUNTRY_CODE")
    monkeypatch.delenv("USER_PHONE", raising=False)
    _card(w, JANE, "Jane Smith", "UID-JANE", JANE_MOBILE_NATIONAL)
    _legacy_twin(w, JANE_MOBILE_E164)
    assert w.dm.run()["phone_twins_merged"] == 1
    assert _persons(w) == {JANE}


def test_a_named_person_without_a_card_is_never_folded_by_the_number_alone(world):
    """Household rule, the other direction: Tom Jones has a real name (from
    mail, say) and no Contacts card, and shares a number with Jane's card. A
    shared detail alone does not make them one person."""
    w = world
    _card(w, JANE, "Jane Smith", "UID-JANE", JANE_MOBILE_NATIONAL)
    w.store.update(
        f'INSERT DATA {{ <{TOM}> a pwg:Person ; pwg:displayName "Tom Jones" ; '
        f'pwg:hasIdentifier <{TOM}_p> . <{TOM}_p> a pwg:PersonIdentifier ; '
        f'pwg:identifierType "phone" ; pwg:identifierValue "{JANE_MOBILE_E164}" }}')
    stats = w.dm.run()
    assert stats["phone_twins_merged"] == 0, stats
    assert {JANE, TOM} <= _persons(w)


# ── Archie review of #3144 ───────────────────────────────────────────────

def test_the_fold_moves_the_twins_facts_both_ways_and_a_second_run_is_a_no_op(world):
    """A delete-instead-of-move fold passed the first nine tests. The twin's
    own facts (subject) and the facts pointing AT it (object) must land on
    the card, and a second sweep must leave the graph quad-for-quad as is."""
    w = world
    _card(w, JANE, "Jane Smith", "UID-JANE", JANE_MOBILE_NATIONAL)
    twin = _legacy_twin(w, JANE_MOBILE_E164)
    w.store.update(f'INSERT DATA {{ <{twin}> <{PWG}lastSeen> "{WHEN}" . '
                   f'<urn:msg:1> <{PWG}sentBy> <{twin}> . }}')
    s1 = w.dm.run()
    assert s1["phone_twins_merged"] == 1, s1
    assert w.store.ask(f'ASK {{ <{JANE}> <{PWG}lastSeen> "{WHEN}" }}'), "outbound fact lost"
    assert w.store.ask(f'ASK {{ <urn:msg:1> <{PWG}sentBy> <{JANE}> }}'), "inbound fact lost"
    with w.store.lock:
        before = sorted(str(q) for q in w.store.ds.quads_for_pattern(None, None, None, None))
    s2 = w.dm.run()
    assert s2["phone_twins_merged"] == 0 and s2["merged"] == 0, s2
    with w.store.lock:
        after = sorted(str(q) for q in w.store.ds.quads_for_pattern(None, None, None, None))
    assert before == after, "a second run changed the graph"


def test_with_the_country_known_a_foreign_number_never_matches_on_its_last_8_digits(world):
    """Owner's country is +44. A +852 handle whose last 8 digits equal a UK
    card's is a different number: no cross-country trailing-digit guess."""
    w = world
    _card(w, JANE, "Jane Smith", "UID-JANE", JANE_MOBILE_NATIONAL)   # ...00900123
    twin = _legacy_twin(w, "+852" + "00900123")
    stats = w.dm.run()
    assert stats["phone_twins_merged"] == 0, stats
    assert twin in _persons(w)


def test_a_carded_person_named_by_a_number_is_never_folded(world):
    """A Contacts card is a person in its own right even when its only name
    is a number; it is never the twin."""
    w = world
    _card(w, JANE, "Jane Smith", "UID-JANE", JANE_MOBILE_NATIONAL)
    _card(w, TOM, JANE_MOBILE_E164, "UID-NUMBER-CARD", JANE_MOBILE_E164)
    stats = w.dm.run()
    assert stats["phone_twins_merged"] == 0, stats
    assert {JANE, TOM} <= _persons(w)


def test_the_sweep_reports_the_country_it_matched_with(world, monkeypatch):
    w = world
    s = w.dm.run()
    assert s["phone_twins_country_code"] == 44 and s["phone_twins_match"] == "e164", s
    monkeypatch.delenv("DEFAULT_COUNTRY_CODE")
    monkeypatch.delenv("USER_PHONE", raising=False)
    s = w.dm.run()
    assert s["phone_twins_country_code"] is None and s["phone_twins_match"] == "trailing8", s
