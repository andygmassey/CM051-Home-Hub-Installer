"""An already-installed box with the v1.0.120 pile heals, and stays healed.

THE BOX SHAPE (v1.0.120 walk, Mini16, read-only, shapes only): one person,
8 live Person nodes, all with the same full name, birthday, 3 emails and 2
mobiles; 2 Contacts card uids between them. One node held BOTH uids, 3 held
the first only, 4 the second only.

THE ASK (Archie, #3240 review): seed that shape, run the converge an upgrade
runs; the result is ONE node, every fold journalled and undoable. Then two
more contact resyncs: still one node, and no new node minted.

Real components end to end: the shipped batch resolver's converge, the
shipped contact syncer write path and identity resolver, the shared merge
journal and its undo, over HTTP to a pyoxigraph-backed Oxigraph, with
qdrant-client's in-memory engine standing in for the Qdrant server.
Synthetic data only (approved cast, example.com, reserved mobiles).
"""
from __future__ import annotations

import json
import sys
import types
from pathlib import Path

import pytest

pytest.importorskip("pyoxigraph")
qdrant_client = pytest.importorskip("qdrant_client")
from qdrant_client import models  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
VENDOR = ROOT / "vendor" / "cm041"
for _n in [n for n in sys.modules if n.split(".")[0] in ("contact_syncer", "identity_resolver")]:
    del sys.modules[_n]
while str(ROOT) in sys.path:
    sys.path.remove(str(ROOT))
sys.path.insert(0, str(VENDOR))
sys.path.insert(0, str(ROOT / "tests"))

from _fake_oxigraph import FakeOxigraph  # noqa: E402

PWG = "https://schema.ostler.ai/ontology#"
QDRANT = "http://qdrant.invalid:6333"   # never dialled: the client is in-memory
U1 = "SYNTHETIC-CARD-UID-0001"
U2 = "SYNTHETIC-CARD-UID-0002"
NAME = "Jane Stewart"
EMAILS = ("jane.stewart@example.com", "jstewart@example.com", "jane@example.com")
MOBILES = ("+447700900123", "+447700900124")
BIRTHDAY = "1980-11-02"
# The box's pile: one node with both cards, 3 with card 1, 4 with card 2.
PILE = [("both0000000", [U1, U2])] + [("one%08d" % i, [U1]) for i in range(3)] \
    + [("two%08d" % i, [U2]) for i in range(4)]


@pytest.fixture()
def world(tmp_path, monkeypatch):
    store = FakeOxigraph()
    mem = qdrant_client.QdrantClient(":memory:")
    mem.create_collection("people", vectors_config=models.VectorParams(
        size=4, distance=models.Distance.COSINE))
    monkeypatch.setattr(qdrant_client, "QdrantClient", lambda *a, **k: mem)
    bk = tmp_path / "bk"
    monkeypatch.setenv("OSTLER_MERGE_JOURNAL_DIR", str(bk / "merge_journal"))
    monkeypatch.setenv("QDRANT_URL", QDRANT)
    monkeypatch.setenv("OXIGRAPH_URL", store.url)
    monkeypatch.setenv("WIKI_CORRECTIONS_DIR", str(tmp_path / "corr"))
    monkeypatch.setenv("OSTLER_FORGET_TOMBSTONE_FILE", str(tmp_path / "tomb.json"))
    monkeypatch.setenv("OSTLER_PERSON_DELETION_LOG", str(tmp_path / "del.jsonl"))
    from identity_resolver import batch_resolver as br
    from contact_syncer import config as cfg
    monkeypatch.setattr(cfg, "OXIGRAPH_URL", store.url)
    monkeypatch.setattr(cfg, "QDRANT_URL", QDRANT)
    monkeypatch.setattr(cfg, "USER_ID", "")
    monkeypatch.setattr(cfg, "DEFAULT_PRIVACY_LEVEL", "L2")
    monkeypatch.setattr(cfg, "DEFAULT_COUNTRY_CODE", 44)
    yield types.SimpleNamespace(store=store, mem=mem, bk=bk, br=br, cfg=cfg,
                                corr=tmp_path / "corr")
    store.close()


def _seed(w):
    for short, uids in PILE:
        uri = f"{PWG}person_{short}"
        t = [f"<{uri}> a pwg:Person", f'<{uri}> pwg:displayName "{NAME}"',
             f'<{uri}> pwg:givenName "Jane"', f'<{uri}> pwg:familyName "Stewart"',
             f'<{uri}> pwg:contactType "person"',
             f'<{uri}> pwg:birthday "{BIRTHDAY}"^^xsd:date']
        ids = [("icloud_contact_uid", u) for u in uids] + \
            [("email", e) for e in EMAILS] + [("phone", p) for p in MOBILES]
        for i, (typ, val) in enumerate(ids):
            idn = f"{PWG}id_{short}_{i}"
            t += [f"<{uri}> pwg:hasIdentifier <{idn}>", f"<{idn}> a pwg:PersonIdentifier",
                  f'<{idn}> pwg:identifierType "{typ}"', f'<{idn}> pwg:identifierValue "{val}"']
        w.store.update("INSERT DATA { " + " .\n".join(t) + " . }")
        w.mem.upsert("people", points=[models.PointStruct(
            id=_pid(uri), vector=[1.0, 0.0, 0.0, 0.0], payload={"person_uri": uri})])


def _pid(uri):
    import uuid
    return str(uuid.uuid5(uuid.NAMESPACE_URL, uri))


def _q(w, sparql):
    with w.store.lock:
        return list(w.store.ds.query("PREFIX pwg: <%s> %s" % (PWG, sparql)))


def _live(w):
    return sorted(r["p"].value for r in _q(
        w, "SELECT DISTINCT ?p WHERE { ?p a pwg:Person . "
           "FILTER NOT EXISTS { ?p pwg:mergedInto ?t } }"))


def _every_person_uri(w):
    """Every person URI the graph has ever typed or tombstoned: a mint adds one."""
    return sorted({r["p"].value for r in _q(
        w, "SELECT DISTINCT ?p WHERE { { ?p a pwg:Person } UNION { ?p pwg:mergedInto ?t } }")})


def _dump(w):
    with w.store.lock:
        return sorted(str(q) for q in w.store.ds.quads_for_pattern(None, None, None, None))


def _uids(w, uri):
    return sorted({r["v"].value for r in _q(
        w, "SELECT ?v WHERE { <%s> pwg:hasIdentifier ?i . "
           '?i pwg:identifierType "icloud_contact_uid" ; pwg:identifierValue ?v }' % uri)})


def _converge(w):
    r = w.br.BatchResolver(oxigraph_url=w.store.url, qdrant_url=QDRANT,
                           config={"default_country_code": 44,
                                   "corrections_dir": str(w.corr)})
    r.converge(backup_dir=str(w.bk))
    return r


def _resync(w, uid):
    """One contact-resync of ONE card through the real write path."""
    from contact_syncer.syncer import ContactSyncer
    from identity_resolver.resolver import IdentityResolver
    s = ContactSyncer.__new__(ContactSyncer)
    s.cfg = w.cfg
    s.resolver = IdentityResolver(oxigraph_url=w.store.url, default_country_code=44)
    s._persist_photo = lambda *a, **k: None
    s._resolve_and_write_person({
        "fn": NAME, "given_name": "Jane", "family_name": "Stewart", "uid": uid,
        "phones": [{"value": p} for p in MOBILES], "emails": [{"value": e} for e in EMAILS],
        "org": "", "title": "", "notes": "", "birthday": BIRTHDAY}, "person")


def _merges(w):
    p = w.bk / "merge_journal" / "merge_journal.jsonl"
    rows = [json.loads(x) for x in p.read_text().splitlines()] if p.exists() else []
    return [r for r in rows if r.get("kind") == "merge"]


def test_the_box_pile_converges_to_one_journalled_and_stays_one(world):
    _seed(world)
    seeded = _dump(world)
    seeded_uris = _every_person_uri(world)
    assert len(_live(world)) == 8 and len(seeded_uris) == 8

    # 1. The converge an upgrade runs.
    r = _converge(world)
    live = _live(world)
    assert len(live) == 1, ("live after converge", len(live))
    assert _uids(world, live[0]) == [U1, U2]
    merges = _merges(world)
    assert len(merges) == 7, ("journalled folds", len(merges))
    assert all((world.bk / "merge_journal" / m["snapshot"]).exists() for m in merges)

    # 2. Two more hourly resyncs of both cards: still one, nothing minted.
    for _ in range(2):
        _resync(world, U1)
        _resync(world, U2)
    live = _live(world)
    assert len(live) == 1, ("live after 2 resyncs", len(live))
    assert _every_person_uri(world) == seeded_uris, "a resync minted a new person node"

    # 3. Every fold is undoable: undo them newest first and the seeded graph
    #    comes back exactly.
    for m in reversed(_merges(world)):
        r.undo_merge(m["id"], backup_dir=str(world.bk))
    assert len(_live(world)) == 8
    assert _dump(world) == seeded


def test_control_two_different_people_are_left_apart(world):
    """Negative control: the converge does not fold two people who share
    nothing, so the 1 above is the pile's doing, not a converge that folds all."""
    _seed(world)
    uri = f"{PWG}person_tomjones0000"
    world.store.update(
        f'INSERT DATA {{ <{uri}> a pwg:Person ; pwg:displayName "Tom Jones" ; '
        f'pwg:hasIdentifier <{uri}_i0> . <{uri}_i0> a pwg:PersonIdentifier ; '
        f'pwg:identifierType "email" ; pwg:identifierValue "tom.jones@example.com" . }}')
    _converge(world)
    _resync(world, U1)
    assert len(_live(world)) == 2
