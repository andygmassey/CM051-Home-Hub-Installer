"""End-to-end proof for the exact-identifier merge tier (v1.0.107 #30).

Real BatchResolver (detect -> execute -> converge) against an in-memory SPARQL
store (rdflib behind an httpx MockTransport). SYNTHETIC DATA ONLY: invented
names, Ofcom drama-range / reserved numbers, example.com addresses.

The measured miss (Mini16, 2026-10-15, counts only): of 70 same-name pairs
that share an exact email or phone, 66 were refused by RULE 2 because the two
nodes carry DIFFERENT icloud_contact_uid values (two Contacts cards for one
person, e.g. an iCloud card and an Exchange card), 4 were spilled to review.
The shared exact identifier was found every time; the card-uid veto then
discarded it. These tests pin that and the safety rails around the fix.
"""
from __future__ import annotations

import json
import os
import sys
import types

import httpx
import pytest
from rdflib import Graph

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "vendor", "cm041"))

from identity_resolver import batch_resolver as br  # noqa: E402

PWG = br.PWG
MOBILE_A = "+447400123456"      # valid UK mobile (type MOBILE)
MOBILE_B = "+447400123457"
LANDLINE = "+442079460123"      # Ofcom drama range, valid FIXED_LINE


class FakeStore:
    """rdflib Graph served as /query and /update through httpx.MockTransport."""

    def __init__(self) -> None:
        self.g = Graph()

    def handler(self, request: httpx.Request) -> httpx.Response:
        body = request.content.decode()
        if request.url.path.endswith("/query"):
            res = self.g.query(body)
            return httpx.Response(
                200, content=res.serialize(format="json"),
                headers={"content-type": "application/sparql-results+json"},
            )
        if request.url.path.endswith("/update"):
            self.g.update(body)
            return httpx.Response(204)
        return httpx.Response(404)

    def client(self) -> httpx.Client:
        return httpx.Client(transport=httpx.MockTransport(self.handler))

    # -- seeding -----------------------------------------------------------
    def person(self, slug, name, *, phones=(), emails=(), linkedin=(),
               uids=(), given="", family="", extra_triples=0) -> str:
        uri = f"{PWG}person_{slug}"
        t = [f"<{uri}> a <{PWG}Person>", f'<{uri}> <{PWG}displayName> "{name}"']
        if given:
            t.append(f'<{uri}> <{PWG}givenName> "{given}"')
        if family:
            t.append(f'<{uri}> <{PWG}familyName> "{family}"')
        for i in range(extra_triples):
            t.append(f'<{uri}> <{PWG}notes> "n{slug}{i}"')
        ids = ([("phone", v) for v in phones] + [("email", v) for v in emails]
               + [("linkedin_url", v) for v in linkedin]
               + [("icloud_contact_uid", v) for v in uids])
        for n, (typ, val) in enumerate(ids):
            iu = f"{PWG}id_{slug}_{n}"
            t += [f"<{uri}> <{PWG}hasIdentifier> <{iu}>",
                  f"<{iu}> a <{PWG}PersonIdentifier>",
                  f'<{iu}> <{PWG}identifierType> "{typ}"',
                  f'<{iu}> <{PWG}identifierValue> "{val}"']
        self.g.update("INSERT DATA { " + " . ".join(t) + " . }")
        return uri

    def live(self) -> set[str]:
        q = (f"SELECT ?p WHERE {{ ?p a <{PWG}Person> . "
             f"FILTER NOT EXISTS {{ ?p <{PWG}mergedInto> ?m }} }}")
        return {str(r[0]) for r in self.g.query(q)}


def make(store: FakeStore, tmp_path) -> br.BatchResolver:
    r = br.BatchResolver(oxigraph_url="http://store.invalid",
                         config={"default_country_code": None,
                                 "corrections_dir": str(tmp_path / "corr")})
    r._client = store.client()
    # Qdrant is outside this fixture; the graph merge is what is under test.
    r.reconcile_qdrant = lambda **k: None  # type: ignore[assignment]
    return r


@pytest.fixture(autouse=True)
def _no_qdrant(monkeypatch):
    monkeypatch.setattr(br, "_merge_qdrant", lambda *a, **k: True)
    monkeypatch.setattr(br, "_set_qdrant_display_name", lambda *a, **k: None)
    monkeypatch.setattr(br, "record_person_removal", lambda *a, **k: None)


def converge(store, tmp_path):
    r = make(store, tmp_path)
    r.converge(backup_dir=str(tmp_path / "bk"))
    return r


# --------------------------------------------------------------------------
# The reproduced miss. RED on the old code: RULE 2 refuses two same-name nodes
# that share an exact mobile number because their card uids differ.
# --------------------------------------------------------------------------
def test_same_name_shared_mobile_two_cards_merge(tmp_path):
    s = FakeStore()
    s.person("a1", "Casey Morgan", phones=[MOBILE_A], uids=["uid-icloud-1"])
    s.person("a2", "Casey Morgan", phones=[MOBILE_A], uids=["uid-exch-9"])
    converge(s, tmp_path)
    assert len(s.live()) == 1


def test_same_name_shared_email_two_cards_merge(tmp_path):
    s = FakeStore()
    s.person("b1", "Robin Ellis", emails=["robin@example.com"], uids=["u1"])
    s.person("b2", "Robin Ellis", emails=["robin@example.com"], uids=["u2"])
    converge(s, tmp_path)
    assert len(s.live()) == 1


def test_same_linkedin_url_variants_merge_ignoring_card_uids(tmp_path):
    s = FakeStore()
    s.person("c1", "Dana Whitfield", linkedin=["https://www.linkedin.com/in/dana-w/"],
             uids=["u1"])
    s.person("c2", "Dana Whitfield", linkedin=["http://linkedin.com/in/dana-w"],
             uids=["u2"])
    converge(s, tmp_path)
    assert len(s.live()) == 1


# --------------------------------------------------------------------------
# Vetoes and guards. Each must keep the pair apart.
# --------------------------------------------------------------------------
def test_different_linkedin_urls_veto_even_with_shared_email(tmp_path):
    s = FakeStore()
    s.person("d1", "Sam Hartley", emails=["sam@example.com"],
             linkedin=["https://www.linkedin.com/in/sam-hartley-one"], uids=["u1"])
    s.person("d2", "Sam Hartley", emails=["sam@example.com"],
             linkedin=["https://www.linkedin.com/in/sam-hartley-two"], uids=["u2"])
    converge(s, tmp_path)
    assert len(s.live()) == 2


def test_different_mobiles_both_sides_veto_shared_email(tmp_path):
    s = FakeStore()
    s.person("e1", "Lee Fenwick", emails=["lee@example.com"], phones=[MOBILE_A], uids=["u1"])
    s.person("e2", "Lee Fenwick", emails=["lee@example.com"], phones=[MOBILE_B], uids=["u2"])
    converge(s, tmp_path)
    assert len(s.live()) == 2


def test_different_names_sharing_family_email_do_not_merge(tmp_path):
    s = FakeStore()
    s.person("f1", "Jamie Rivera", emails=["rivera.family@example.com"], uids=["u1"])
    s.person("f2", "Robin Rivera", emails=["rivera.family@example.com"], uids=["u2"])
    converge(s, tmp_path)
    assert len(s.live()) == 2


def test_company_switchboard_held_by_three_names_is_not_a_key(tmp_path):
    """Guard: an identifier held by 3+ distinct names never merges anyone,
    including a same-name pair among them."""
    s = FakeStore()
    s.person("g1", "Alex Stone", phones=[LANDLINE], uids=["u1"])
    s.person("g2", "Alex Stone", phones=[LANDLINE], uids=["u2"])
    s.person("g3", "Pat Quinn", phones=[LANDLINE], uids=["u3"])
    s.person("g4", "Kim Doyle", phones=[LANDLINE], uids=["u4"])
    converge(s, tmp_path)
    assert len(s.live()) == 4


def test_shared_landline_two_same_name_is_not_enough_across_cards(tmp_path):
    """A household landline can carry a father and a son of the same name.
    A fixed line is not strong enough to override two different Contacts
    cards; the pair goes to review, not to a merge."""
    s = FakeStore()
    s.person("h1", "Chris Dalton", phones=[LANDLINE], uids=["u1"])
    s.person("h2", "Chris Dalton", phones=[LANDLINE], uids=["u2"])
    converge(s, tmp_path)
    assert len(s.live()) == 2


def test_different_whatsapp_lid_still_refuses(tmp_path):
    s = FakeStore()
    a = s.person("i1", "Noor Salem", phones=[MOBILE_A])
    b = s.person("i2", "Noor Salem", phones=[MOBILE_A])
    for u, lid in ((a, "lid-1"), (b, "lid-2")):
        s.g.update(
            f'INSERT DATA {{ <{u}> <{PWG}hasIdentifier> <{u}_lid> . '
            f'<{u}_lid> <{PWG}identifierType> "whatsapp_lid" ; '
            f'<{PWG}identifierValue> "{lid}" }}')
    converge(s, tmp_path)
    assert len(s.live()) == 2


def test_different_human_names_never_merge_on_shared_mobile(tmp_path):
    s = FakeStore()
    s.person("j1", "Casey Morgan", phones=[MOBILE_A], uids=["u1"])
    s.person("j2", "Jordan Pike", phones=[MOBILE_A], uids=["u2"])
    converge(s, tmp_path)
    assert len(s.live()) == 2


def test_single_token_name_is_not_a_merge_basis(tmp_path):
    s = FakeStore()
    s.person("k1", "Mum", phones=[MOBILE_A], uids=["u1"])
    s.person("k2", "Mum", phones=[MOBILE_A], uids=["u2"])
    converge(s, tmp_path)
    assert len(s.live()) == 2
