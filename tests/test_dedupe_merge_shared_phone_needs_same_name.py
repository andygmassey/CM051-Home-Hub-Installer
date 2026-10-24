"""P16: two NAMED people who share a phone are one person only if their names
match too. A household landline on two family cards is a shared detail, not
an identity.

The exact-string pass in vendor/ostler_fda/dedupe_merge.py (RULE 1) merged
every Person sharing a phone string, whatever their names, so the two cards
that list the family landline became one person. Same rule as the P13
number-named twin fold: same name plus a shared detail merges; a shared
detail alone never does.

Real SPARQL: dedupe_merge talks HTTP to a pyoxigraph-backed fake Oxigraph.
Fictional cast (Jane Smith, Tom Jones), reserved numbers (Ofcom 020 7946 0xxx
landline, 07700 900xxx mobiles).
"""
from __future__ import annotations

import os
import sys
import tempfile
import types
from pathlib import Path

import pytest

pytest.importorskip("pyoxigraph")

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "vendor"))
sys.path.insert(0, str(ROOT / "tests"))
os.environ.setdefault("OSTLER_PERSON_DELETION_LOG", os.path.join(tempfile.mkdtemp(), "r.jsonl"))

from _fake_oxigraph import FakeOxigraph  # noqa: E402

PWG = "https://schema.ostler.ai/ontology#"
JANE = PWG + "contact_jane_smith"
TOM = PWG + "contact_tom_jones"
JANE_MAIL = PWG + "person_mail_jane_smith"
STRANGER = PWG + "person_number_only"
LANDLINE = "+44" + "2079460001"
JANE_MOBILE = "+44" + "7700900123"


@pytest.fixture()
def world(monkeypatch):
    store = FakeOxigraph()
    from ostler_fda import dedupe_merge
    monkeypatch.setattr(dedupe_merge, "OXIGRAPH_URL", store.url)
    yield types.SimpleNamespace(store=store, dm=dedupe_merge)
    store.close()


def _person(w, uri, name, *phones):
    ids = " ".join(
        f'<{uri}> pwg:hasIdentifier <{uri}_p{i}> . <{uri}_p{i}> a pwg:PersonIdentifier ; '
        f'pwg:identifierType "phone" ; pwg:identifierValue "{v}" .'
        for i, v in enumerate(phones))
    w.store.update(f'INSERT DATA {{ <{uri}> a pwg:Person ; pwg:displayName "{name}" . {ids} }}')


def _alive(w, uri):
    return w.store.ask(f"ASK {{ <{uri}> a pwg:Person }}")


def test_a_household_landline_on_two_family_cards_never_merges_them(world):
    w = world
    _person(w, JANE, "Jane Smith", LANDLINE)
    _person(w, TOM, "Tom Jones", LANDLINE)
    stats = w.dm.run()
    assert stats["merged"] == 0, stats
    assert stats["refused_shared_phone"] == 1, stats
    assert _alive(w, JANE) and _alive(w, TOM)


def test_same_name_plus_a_shared_phone_still_merges(world):
    """Control: the household rule must not blind RULE 1."""
    w = world
    _person(w, JANE, "Jane Smith", JANE_MOBILE)
    _person(w, JANE_MAIL, "jane  SMITH", JANE_MOBILE)
    stats = w.dm.run()
    assert stats["merged"] == 1, stats
    assert _alive(w, min(JANE, JANE_MAIL)) and not _alive(w, max(JANE, JANE_MAIL))


def test_a_number_named_node_on_a_household_landline_joins_nobody(world):
    w = world
    _person(w, JANE, "Jane Smith", LANDLINE)
    _person(w, TOM, "Tom Jones", LANDLINE)
    _person(w, STRANGER, LANDLINE, LANDLINE)
    stats = w.dm.run()
    assert stats["merged"] == 0, stats
    assert _alive(w, JANE) and _alive(w, TOM) and _alive(w, STRANGER)


def test_a_number_named_node_with_one_named_holder_still_merges(world):
    """Control: the ordinary twin (one named holder) is still RULE 1."""
    w = world
    _person(w, JANE, "Jane Smith", JANE_MOBILE)
    _person(w, STRANGER, JANE_MOBILE, JANE_MOBILE)
    stats = w.dm.run()
    assert stats["merged"] == 1, stats


def test_same_named_pair_on_a_landline_merges_while_the_other_name_stays(world):
    w = world
    _person(w, JANE, "Jane Smith", LANDLINE)
    _person(w, JANE_MAIL, "Jane Smith", LANDLINE)
    _person(w, TOM, "Tom Jones", LANDLINE)
    stats = w.dm.run()
    assert stats["merged"] == 1 and stats["refused_shared_phone"] == 1, stats
    assert _alive(w, TOM)
    assert _alive(w, min(JANE, JANE_MAIL)) and not _alive(w, max(JANE, JANE_MAIL))


def test_a_kinship_label_is_not_a_name_so_it_never_splits_a_household(world):
    """"Mum" says how somebody refers to Jane, not who she is (CM051 #2556):
    it is not a different name, so the shared number still joins them."""
    w = world
    _person(w, JANE, "Jane Smith", JANE_MOBILE)
    _person(w, JANE_MAIL, "Mum", JANE_MOBILE)
    stats = w.dm.run()
    assert stats["merged"] == 1 and stats["refused_shared_phone"] == 0, stats


# ── P16b: kinship words on a shared number ───────────────────────────────

MUM = PWG + "person_kin_mum"
DAD = PWG + "person_kin_dad"


def _card(w, uri, name, uid, *phones):
    _person(w, uri, name, *phones)
    w.store.update(
        f'INSERT DATA {{ <{uri}> pwg:hasIdentifier <{uri}_uid> . <{uri}_uid> a pwg:PersonIdentifier ; '
        f'pwg:identifierType "icloud_contact_uid" ; pwg:identifierValue "{uid}" }}')


def test_two_different_kinship_words_on_one_landline_never_merge(world):
    """"Mum" and "Dad" on the household landline are two people."""
    w = world
    _person(w, MUM, "Mum", LANDLINE)
    _person(w, DAD, "Dad", LANDLINE)
    stats = w.dm.run()
    assert stats["merged"] == 0, stats
    assert stats["refused_kinship_phone"] == 1, stats
    assert _alive(w, MUM) and _alive(w, DAD)


def test_a_kinship_word_never_swallows_a_separate_contacts_card(world):
    """"Mum" on the landline and Tom Jones, already his own card, on the same
    landline: Tom must not be folded into Mum (nor Mum into Tom)."""
    w = world
    _person(w, MUM, "Mum", LANDLINE)
    _card(w, TOM, "Tom Jones", "UID-TOM", LANDLINE)
    stats = w.dm.run()
    assert stats["merged"] == 0, stats
    assert stats["refused_kinship_phone"] == 1, stats
    assert _alive(w, MUM) and _alive(w, TOM)


def test_control_the_same_kinship_word_twice_still_merges(world):
    w = world
    _person(w, MUM, "Mum", LANDLINE)
    _person(w, DAD, "mum", LANDLINE)
    stats = w.dm.run()
    assert stats["merged"] == 1 and stats["refused_kinship_phone"] == 0, stats


def test_control_a_kinship_word_and_an_uncarded_name_still_merge(world):
    """The CM051 #2556 case: "Mum" is how the owner refers to Jane, and Jane
    has no separate card, so the shared mobile still joins them."""
    w = world
    _person(w, MUM, "Mum", JANE_MOBILE)
    _person(w, JANE, "Jane Smith", JANE_MOBILE)
    stats = w.dm.run()
    assert stats["merged"] == 1 and stats["refused_kinship_phone"] == 0, stats


def test_an_unreadable_card_lookup_for_the_kinship_check_fails_closed(world, monkeypatch):
    """ONLY the kinship check's card read fails (the later RULE 2 read is
    fine). "Mum" plus an uncarded Jane Smith would normally merge (the #2556
    case), but with the card keys unknown the kinship holder joins nobody
    this run: a missed merge is retried next sweep, a wrong one is not."""
    w = world
    _person(w, MUM, "Mum", JANE_MOBILE)
    _person(w, JANE, "Jane Smith", JANE_MOBILE)
    real = w.dm.canonical_keys_of
    calls = {"n": 0}

    def first_read_fails(persons):
        calls["n"] += 1
        if calls["n"] == 1:
            raise RuntimeError("store unreachable for the kinship card read")
        return real(persons)

    monkeypatch.setattr(w.dm, "canonical_keys_of", first_read_fails)
    stats = w.dm.run()
    assert calls["n"] >= 2, "harness: the RULE 2 read did not happen after the kinship read"
    assert stats["refused_unreadable"] is False, stats
    assert stats["merged"] == 0, stats
    assert stats["refused_kinship_phone"] == 1, stats
    assert _alive(w, MUM) and _alive(w, JANE)
