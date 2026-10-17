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

qdrant_client = pytest.importorskip("qdrant_client")
from rdflib import Graph

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "vendor", "cm041"))

from identity_resolver import batch_resolver as br  # noqa: E402

_REAL_MERGE_QDRANT = br._merge_qdrant   # captured before the autouse stub
PWG = br.PWG
MOBILE_A = "+44" + "7400123456"      # valid UK mobile (type MOBILE)
MOBILE_B = "+44" + "7400123457"
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
    # An in-memory Qdrant stands in for the server: "no snapshot, no merge"
    # means every merge needs a reachable store.
    from qdrant_client import QdrantClient, models
    mem = QdrantClient(":memory:")
    mem.create_collection("people", vectors_config=models.VectorParams(
        size=4, distance=models.Distance.COSINE))
    monkeypatch.setattr(qdrant_client, "QdrantClient", lambda *a, **k: mem)
    monkeypatch.setattr(br, "_merge_qdrant", lambda *a, **k: True)
    monkeypatch.setattr(br, "_set_qdrant_display_name", lambda *a, **k: None)
    monkeypatch.setattr(br, "record_person_removal", lambda *a, **k: None)
    return mem


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
    s.person("a1", "John Smith", phones=[MOBILE_A], uids=["uid-icloud-1"])
    s.person("a2", "John Smith", phones=[MOBILE_A], uids=["uid-exch-9"])
    converge(s, tmp_path)
    assert len(s.live()) == 1


def test_same_name_shared_email_two_cards_merge(tmp_path):
    s = FakeStore()
    s.person("b1", "Jane Doe", emails=["robin@example.com"], uids=["u1"])
    s.person("b2", "Jane Doe", emails=["robin@example.com"], uids=["u2"])
    converge(s, tmp_path)
    assert len(s.live()) == 1


def test_same_linkedin_url_variants_merge_ignoring_card_uids(tmp_path):
    s = FakeStore()
    s.person("c1", "Mary Jones", linkedin=["https://www.linkedin.com/in/dana-w/"],
             uids=["u1"])
    s.person("c2", "Mary Jones", linkedin=["http://linkedin.com/in/dana-w"],
             uids=["u2"])
    converge(s, tmp_path)
    assert len(s.live()) == 1


# --------------------------------------------------------------------------
# Vetoes and guards. Each must keep the pair apart.
# --------------------------------------------------------------------------
def test_different_linkedin_urls_veto_even_with_shared_email(tmp_path):
    s = FakeStore()
    s.person("d1", "Sam Li", emails=["sam@example.com"],
             linkedin=["https://www.linkedin.com/in/sam-hartley-one"], uids=["u1"])
    s.person("d2", "Sam Li", emails=["sam@example.com"],
             linkedin=["https://www.linkedin.com/in/sam-hartley-two"], uids=["u2"])
    converge(s, tmp_path)
    assert len(s.live()) == 2


def test_different_mobiles_both_sides_veto_shared_email(tmp_path):
    s = FakeStore()
    s.person("e1", "Thomas Patel", emails=["lee@example.com"], phones=[MOBILE_A], uids=["u1"])
    s.person("e2", "Thomas Patel", emails=["lee@example.com"], phones=[MOBILE_B], uids=["u2"])
    converge(s, tmp_path)
    assert len(s.live()) == 2


def test_different_names_sharing_family_email_do_not_merge(tmp_path):
    s = FakeStore()
    s.person("f1", "Liz Brown", emails=["rivera.family@example.com"], uids=["u1"])
    s.person("f2", "Ana Brown", emails=["rivera.family@example.com"], uids=["u2"])
    converge(s, tmp_path)
    assert len(s.live()) == 2


def test_company_switchboard_held_by_three_names_is_not_a_key(tmp_path):
    """Guard: an identifier held by 3+ distinct names never merges anyone,
    including a same-name pair among them."""
    s = FakeStore()
    s.person("g1", "Alex Stewart", phones=[LANDLINE], uids=["u1"])
    s.person("g2", "Alex Stewart", phones=[LANDLINE], uids=["u2"])
    s.person("g3", "Raj Wang", phones=[LANDLINE], uids=["u3"])
    s.person("g4", "Ben Ross", phones=[LANDLINE], uids=["u4"])
    converge(s, tmp_path)
    assert len(s.live()) == 4


def test_shared_landline_two_same_name_is_not_enough_across_cards(tmp_path):
    """A household landline can carry a father and a son of the same name.
    A fixed line is not strong enough to override two different Contacts
    cards; the pair goes to review, not to a merge."""
    s = FakeStore()
    s.person("h1", "Carl Coe", phones=[LANDLINE], uids=["u1"])
    s.person("h2", "Carl Coe", phones=[LANDLINE], uids=["u2"])
    converge(s, tmp_path)
    assert len(s.live()) == 2


def test_different_whatsapp_lid_still_refuses(tmp_path):
    s = FakeStore()
    a = s.person("i1", "Min Zhang", phones=[MOBILE_A])
    b = s.person("i2", "Min Zhang", phones=[MOBILE_A])
    for u, lid in ((a, "lid-1"), (b, "lid-2")):
        s.g.update(
            f'INSERT DATA {{ <{u}> <{PWG}hasIdentifier> <{u}_lid> . '
            f'<{u}_lid> <{PWG}identifierType> "whatsapp_lid" ; '
            f'<{PWG}identifierValue> "{lid}" }}')
    converge(s, tmp_path)
    assert len(s.live()) == 2


def test_different_human_names_never_merge_on_shared_mobile(tmp_path):
    s = FakeStore()
    s.person("j1", "John Smith", phones=[MOBILE_A], uids=["u1"])
    s.person("j2", "Tom Andersen", phones=[MOBILE_A], uids=["u2"])
    converge(s, tmp_path)
    assert len(s.live()) == 2


def test_single_token_name_is_not_a_merge_basis(tmp_path):
    s = FakeStore()
    s.person("k1", "Mum", phones=[MOBILE_A], uids=["u1"])
    s.person("k2", "Mum", phones=[MOBILE_A], uids=["u2"])
    converge(s, tmp_path)
    assert len(s.live()) == 2


# --------------------------------------------------------------------------
# Guard without any card uid in play: a switchboard held by 3 names must not
# merge the name-variant pair that shares it (the variant pair is joined by
# the phone alone, so only the guard holds it; RED on the old code).
# --------------------------------------------------------------------------
def test_switchboard_guard_holds_without_card_uids(tmp_path):
    s = FakeStore()
    s.person("l1", "Alex Stewart", phones=[LANDLINE])
    s.person("l2", "Alexander Stewart", phones=[LANDLINE])
    s.person("l3", "Raj Wang", phones=[LANDLINE])
    s.person("l4", "Ben Ross", phones=[LANDLINE])
    converge(s, tmp_path)
    assert len(s.live()) == 4


def test_two_names_on_one_number_is_still_a_key(tmp_path):
    """Control for the guard: 2 distinct names is below the 3+ threshold."""
    s = FakeStore()
    s.person("m1", "Alex Stewart", phones=[MOBILE_A], uids=["u1"])
    s.person("m2", "Alex Stewart", phones=[MOBILE_A], uids=["u2"])
    s.person("m3", "Raj Wang", phones=[MOBILE_A], uids=["u3"])
    converge(s, tmp_path)
    live = s.live()
    assert len(live) == 2           # the Alex pair merged, Pat untouched


def test_converge_stops_at_the_fixpoint_when_everything_is_refused(tmp_path):
    s = FakeStore()
    s.person("n1", "Sam Li", emails=["s@example.com"],
             linkedin=["https://www.linkedin.com/in/sam-a"], uids=["u1"])
    s.person("n2", "Sam Li", emails=["s@example.com"],
             linkedin=["https://www.linkedin.com/in/sam-b"], uids=["u2"])
    r = make(s, tmp_path)
    rounds = r.converge(backup_dir=str(tmp_path / "bk"))
    assert len(rounds) == 1


# --------------------------------------------------------------------------
# Safety: backup before merge, one journal entry per merge, undo restores.
# --------------------------------------------------------------------------
def _dump(store: FakeStore) -> set[tuple[str, str, str]]:
    return {(str(s), str(p), repr(o)) for s, p, o in store.g}


def test_merge_is_journalled_and_undo_restores_the_pre_merge_graph(tmp_path):
    s = FakeStore()
    s.person("p1", "John Smith", phones=[MOBILE_A], emails=["c@example.com"],
             uids=["uid-1"], given="John", family="Smith", extra_triples=3)
    s.person("p2", "John Smith", phones=[MOBILE_A], uids=["uid-2"],
             extra_triples=1)
    s.g.update(
        f'INSERT DATA {{ <{PWG}fact_1> <{PWG}aboutPerson> <{PWG}person_p2> . '
        f'<{PWG}meeting_1> <{PWG}meetingAttendee> <{PWG}person_p2> }}')
    before = _dump(s)

    r = make(s, tmp_path)
    r.converge(backup_dir=str(tmp_path / "bk"))
    assert len(s.live()) == 1
    assert _dump(s) != before

    jdir = tmp_path / "bk" / "merge_journal"
    entries = [json.loads(x) for x in (jdir / "merge_journal.jsonl").read_text().splitlines()]
    merges = [e for e in entries if e["kind"] == "merge"]
    assert len(merges) == 1                                   # one per merge
    assert merges[0]["override"].startswith("exact_identifier:")
    assert (jdir / merges[0]["snapshot"]).exists()            # backup exists
    assert oct((jdir / merges[0]["snapshot"]).stat().st_mode & 0o777) == "0o600"
    assert "c@example.com" not in (jdir / "merge_journal.jsonl").read_text()

    res = r.undo_merge(merges[0]["id"], backup_dir=str(tmp_path / "bk"))
    assert res["qdrant_restored"] is True
    assert _dump(s) == before                                 # exact restore
    assert len(s.live()) == 2


def test_undo_pins_the_pair_so_converge_does_not_remerge(tmp_path):
    pytest.importorskip("yaml")
    s = FakeStore()
    s.person("q1", "John Smith", phones=[MOBILE_A], uids=["u1"])
    s.person("q2", "John Smith", phones=[MOBILE_A], uids=["u2"])
    r = make(s, tmp_path)
    r.converge(backup_dir=str(tmp_path / "bk"))
    mid = [e for e in merge_entries(tmp_path) if e["kind"] == "merge"][0]["id"]
    r.undo_merge(mid, backup_dir=str(tmp_path / "bk"))
    assert len(s.live()) == 2
    make(s, tmp_path).converge(backup_dir=str(tmp_path / "bk"))
    assert len(s.live()) == 2                                  # stays apart


def merge_entries(tmp_path):
    p = tmp_path / "bk" / "merge_journal" / "merge_journal.jsonl"
    return [json.loads(x) for x in p.read_text().splitlines()]


def test_undo_twice_and_unknown_id_are_refused(tmp_path):
    from identity_resolver.merge_journal import UndoError
    s = FakeStore()
    s.person("r1", "John Smith", phones=[MOBILE_A], uids=["u1"])
    s.person("r2", "John Smith", phones=[MOBILE_A], uids=["u2"])
    r = make(s, tmp_path)
    r.converge(backup_dir=str(tmp_path / "bk"))
    mid = merge_entries(tmp_path)[0]["id"]
    r.undo_merge(mid, backup_dir=str(tmp_path / "bk"))
    with pytest.raises(UndoError):
        r.undo_merge(mid, backup_dir=str(tmp_path / "bk"))
    with pytest.raises(UndoError):
        r.undo_merge("no-such-id", backup_dir=str(tmp_path / "bk"))


def test_no_snapshot_no_merge(tmp_path, monkeypatch):
    s = FakeStore()
    s.person("t1", "John Smith", phones=[MOBILE_A], uids=["u1"])
    s.person("t2", "John Smith", phones=[MOBILE_A], uids=["u2"])

    def boom(*a, **k):
        raise OSError("disk full")
    monkeypatch.setattr(br.merge_journal, "record_merge", boom)
    converge(s, tmp_path)
    assert len(s.live()) == 2


# --------------------------------------------------------------------------
# Policy unit tests (pure functions), including a mutation control.
# --------------------------------------------------------------------------
def _rec(name, phones=(), emails=(), li=()):
    return br.PersonRecord(uri=name, display_name=name,
                           phones=set(phones), emails=set(emails),
                           linkedin_urls=set(li))


def test_policy_overrides_only_the_card_uid_conflict():
    from identity_resolver import exact_identifier as ex
    a = _rec("John Smith", phones=[MOBILE_A])
    b = _rec("John Smith", phones=[MOBILE_A])
    h = ex.build_holder_index({"a": a, "b": b}, br._normalise_linkedin_url)
    f = lambda c: ex.card_uid_override(a, b, c, h, br._normalise_linkedin_url)
    assert f({"icloud_contact_uid"})[0] is True
    assert f({"icloud_contact_uid", "linkedin_url"})[0] is False
    assert f({"whatsapp_lid"})[0] is False
    assert f({"unreadable"})[0] is False
    assert f(set())[0] is False


def test_policy_mutation_control_guard_threshold():
    """Break the guard (threshold 99) and the switchboard test's premise
    disappears: proves the 3+ rule is what holds the line, not luck."""
    from identity_resolver import exact_identifier as ex
    a, b = _rec("Alex Stewart", phones=[LANDLINE]), _rec("Alex Stewart", phones=[LANDLINE])
    c, d = _rec("Raj Wang", phones=[LANDLINE]), _rec("Ben Ross", phones=[LANDLINE])
    p = {"a": a, "b": b, "c": c, "d": d}
    h = ex.build_holder_index(p, br._normalise_linkedin_url)
    assert ex.is_guarded(("phone", LANDLINE), h) is True
    old = ex.GUARD_MIN_DISTINCT_NAMES
    try:
        ex.GUARD_MIN_DISTINCT_NAMES = 99
        assert ex.is_guarded(("phone", LANDLINE), h) is False
    finally:
        ex.GUARD_MIN_DISTINCT_NAMES = old


# --------------------------------------------------------------------------
# Undo is complete across BOTH stores: graph and Qdrant people points.
# Real _merge_qdrant and the real reconcile sweep run against an in-memory
# Qdrant; the point ids are the production ones, uuid5(NAMESPACE_URL, uri).
# --------------------------------------------------------------------------
def test_undo_restores_graph_and_qdrant_points_and_pins_distinct(tmp_path, monkeypatch, _no_qdrant):
    qc = pytest.importorskip("qdrant_client")
    pytest.importorskip("yaml")
    import uuid
    from qdrant_client import QdrantClient, models

    mem = _no_qdrant
    monkeypatch.setattr(br, "_merge_qdrant", _REAL_MERGE_QDRANT)

    s = FakeStore()
    ka = s.person("v1", "John Smith", phones=[MOBILE_A], uids=["uid-1"], extra_triples=3)
    kb = s.person("v2", "John Smith", phones=[MOBILE_A], emails=["c@example.com"],
                  uids=["uid-2"])
    pid = lambda u: str(uuid.uuid5(uuid.NAMESPACE_URL, u))
    mem.upsert("people", [
        models.PointStruct(id=pid(ka), vector=[1, 0, 0, 0], payload={
            "person_uri": ka, "display_name": "John Smith",
            "phones": [MOBILE_A], "emails": []}),
        models.PointStruct(id=pid(kb), vector=[0, 1, 0, 0], payload={
            "person_uri": kb, "display_name": "John Smith",
            "phones": [MOBILE_A], "emails": ["c@example.com"],
            "organization": "Acme Corp"}),
        models.PointStruct(id=str(uuid.uuid4()), vector=[0, 0, 1, 0], payload={
            "person_uri": f"{PWG}person_other", "display_name": "Unrelated Person"}),
    ])

    def qdump():
        recs, _ = mem.scroll("people", limit=100, with_payload=True, with_vectors=True)
        return {str(r.id): (json.dumps(r.payload, sort_keys=True),
                            [round(x, 6) for x in r.vector]) for r in recs}

    q_before, g_before = qdump(), _dump(s)
    r = make(s, tmp_path)
    r.reconcile_qdrant = types.MethodType(br.BatchResolver.reconcile_qdrant, r)
    r.converge(backup_dir=str(tmp_path / "bk"))

    assert len(s.live()) == 1
    assert qdump() != q_before                      # the merge really changed Qdrant
    assert len(qdump()) == len(q_before) - 1        # discard point deleted

    entry = [e for e in merge_entries(tmp_path) if e["kind"] == "merge"][0]
    assert entry["qdrant_status"] == "ok" and entry["qdrant_points"] == 2

    # A stray point for the pair that was not in the snapshot (e.g. written by
    # a sync after the merge) must be gone after the undo.
    mem.upsert("people", [models.PointStruct(
        id=str(uuid.uuid4()), vector=[0, 0, 0, 1], payload={"person_uri": ka})])
    assert len(qdump()) == len(q_before)

    res = r.undo_merge(entry["id"], backup_dir=str(tmp_path / "bk"))
    assert res["qdrant_restored"] is True and res["pinned_distinct"] is True
    assert qdump() == q_before                      # ids, payloads, vectors
    assert _dump(s) == g_before                     # graph too

    make(s, tmp_path).converge(backup_dir=str(tmp_path / "bk"))
    assert len(s.live()) == 2                       # pinned distinct: not re-merged
    assert qdump() == q_before


def test_undo_refuses_before_touching_the_graph_if_qdrant_restore_fails(tmp_path, monkeypatch, _no_qdrant):
    qc = pytest.importorskip("qdrant_client")
    pytest.importorskip("yaml")
    from qdrant_client import QdrantClient, models
    from identity_resolver.merge_journal import UndoError
    import uuid

    mem = _no_qdrant
    monkeypatch.setattr(br, "_merge_qdrant", _REAL_MERGE_QDRANT)
    s = FakeStore()
    ka = s.person("w1", "John Smith", phones=[MOBILE_A], uids=["u1"])
    kb = s.person("w2", "John Smith", phones=[MOBILE_A], uids=["u2"])
    for u in (ka, kb):
        mem.upsert("people", [models.PointStruct(
            id=str(uuid.uuid5(uuid.NAMESPACE_URL, u)), vector=[1, 0, 0, 0],
            payload={"person_uri": u})])
    r = make(s, tmp_path)
    r.converge(backup_dir=str(tmp_path / "bk"))
    merged_graph = _dump(s)
    mid = [e for e in merge_entries(tmp_path) if e["kind"] == "merge"][0]["id"]

    def down(*a, **k):
        raise ConnectionError("qdrant down")
    monkeypatch.setattr(qc, "QdrantClient", down)
    with pytest.raises(UndoError):
        r.undo_merge(mid, backup_dir=str(tmp_path / "bk"))
    assert _dump(s) == merged_graph                 # graph untouched, retry is safe


# --------------------------------------------------------------------------
# No snapshot, no merge: Qdrant down means the pair is skipped (recorded as
# qdrant_unavailable), the graph is untouched, nothing is pinned, and the next
# converge with Qdrant back merges it.
# --------------------------------------------------------------------------
def test_qdrant_down_skips_the_merge_and_the_next_converge_retries(tmp_path, monkeypatch):
    s = FakeStore()
    s.person("x1", "John Smith", phones=[MOBILE_A], uids=["u1"])
    s.person("x2", "John Smith", phones=[MOBILE_A], uids=["u2"])
    before = _dump(s)
    working = qdrant_client.QdrantClient

    def down(*a, **k):
        raise ConnectionError("qdrant down")
    monkeypatch.setattr(qdrant_client, "QdrantClient", down)
    r = converge(s, tmp_path)
    assert _dump(s) == before                       # graph unchanged
    assert len(s.live()) == 2
    entries = merge_entries(tmp_path)
    assert [e["kind"] for e in entries] == ["skip"]
    assert entries[0]["reason"] == "qdrant_unavailable"
    assert not list((tmp_path / "bk" / "merge_journal" / "merge_snapshots").glob("*"))
    assert not (tmp_path / "corr" / "duplicates.yaml").exists()   # no pin
    assert getattr(r, "_qdrant_skipped", 0) == 1

    monkeypatch.setattr(qdrant_client, "QdrantClient", working)
    converge(s, tmp_path)
    assert len(s.live()) == 1                       # retried and merged
    kinds = [e["kind"] for e in merge_entries(tmp_path)]
    assert kinds == ["skip", "merge"]
