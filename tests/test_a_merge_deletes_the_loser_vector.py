"""A merged-away person has no searchable vector, and undo puts it back (v1.0.121).

MEASURED on the v1.0.120 box (read-only, counts only): the ``people`` vector
collection held 12004 points; 87 of their person URIs were not a live Person.
86 were the SOURCE of a ``mergedInto`` triple whose chain (1 to 7 hops) ends
at a live Person; 1 was in the graph in no position at all. None of the 86 was
in the batch converge's merge journal (670 journalled merges, 0 left a point):
every one came from the INGEST-TIME merge, ``IdentityResolver.merge_persons``,
which was graph-only. So a people search for a merged-away name returned a URI
the graph had retired.

Real components end to end: the shipped resolver, batch resolver, merge
journal and upgrade repair, talking HTTP to a pyoxigraph-backed Oxigraph, and
qdrant-client's own in-memory engine standing in for the Qdrant server (real
upsert, delete, scroll and vector search). Synthetic data only.
"""
from __future__ import annotations

import hashlib
import json
import math
import os
import sys
import uuid
from pathlib import Path

import pytest

pytest.importorskip("pyoxigraph")
qdrant_client = pytest.importorskip("qdrant_client")
from qdrant_client import models  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "vendor" / "cm041"))
sys.path.insert(0, str(ROOT / "tests"))

from _fake_oxigraph import FakeOxigraph  # noqa: E402
from identity_resolver import batch_resolver as br  # noqa: E402
from identity_resolver import merge_journal  # noqa: E402
from identity_resolver import repair_merge_consistency as rmc  # noqa: E402
from identity_resolver.models import PersonIdentity  # noqa: E402
from identity_resolver.resolver import IdentityResolver  # noqa: E402

PWG = "https://schema.ostler.ai/ontology#"
DIM = 64
# Another test file rebinds these module globals without restoring them;
# capture the shipped ones at import so this file runs in any order.
_SHIPPED = [(m, n, getattr(m, n)) for m, n in (
    (br, "_sparql_query"), (br, "_sparql_update"),
    (rmc, "_sparql_query"), (rmc, "_sparql_update"),
    (rmc, "_set_qdrant_display_name"))]
PHONE = "+44" + "7700900123"
EMAIL = "jane.doe@example.com"


def embed(text: str) -> list:
    """Deterministic character-trigram embedding: similar names, near vectors."""
    v = [0.0] * DIM
    t = f"  {text.lower()}  "
    for i in range(len(t) - 2):
        h = int(hashlib.sha256(t[i:i + 3].encode()).hexdigest(), 16)
        v[h % DIM] += 1.0
    n = math.sqrt(sum(x * x for x in v)) or 1.0
    return [x / n for x in v]


def pid(uri: str) -> str:
    return str(uuid.uuid5(uuid.NAMESPACE_URL, uri))


@pytest.fixture()
def world(tmp_path, monkeypatch):
    for mod, name, fn in _SHIPPED:
        monkeypatch.setattr(mod, name, fn)
    store = FakeOxigraph()
    mem = qdrant_client.QdrantClient(":memory:")
    mem.create_collection("people", vectors_config=models.VectorParams(
        size=DIM, distance=models.Distance.COSINE))
    monkeypatch.setattr(qdrant_client, "QdrantClient", lambda *a, **k: mem)
    monkeypatch.setenv("OSTLER_PERSON_DELETION_LOG", str(tmp_path / "del.jsonl"))
    monkeypatch.setenv("OSTLER_FORGET_TOMBSTONE_FILE", str(tmp_path / "forgotten.json"))
    # The production defaults, pointed at this test: the resolver reads both
    # from the environment, as the syncers construct it with neither.
    monkeypatch.setenv("QDRANT_URL", "http://qdrant.invalid:6333")
    monkeypatch.setenv("OSTLER_MERGE_JOURNAL_DIR", str(tmp_path / "journal"))
    yield store, mem, tmp_path
    store.close()


def person(store, mem, slug, name, *, phones=(), emails=(), point=True):
    uri = f"{PWG}person_{slug}"
    t = [f"<{uri}> a pwg:Person", f'<{uri}> pwg:displayName "{name}"']
    for n, (typ, val) in enumerate([("phone", p) for p in phones]
                                   + [("email", e) for e in emails]):
        iu = f"{PWG}id_{slug}_{n}"
        t += [f"<{uri}> pwg:hasIdentifier <{iu}>",
              f'<{iu}> pwg:identifierType "{typ}"',
              f'<{iu}> pwg:identifierValue "{val}"']
    store.update("INSERT DATA { " + " . ".join(t) + " . }")
    if point:
        upsert(mem, uri, name)
    return uri


def upsert(mem, uri, name, point_id=None, source="icloud_contacts"):
    mem.upsert("people", wait=True, points=[models.PointStruct(
        id=point_id or pid(uri), vector=embed(name),
        payload={"person_uri": uri, "display_name": name, "source": source})])


def search(mem, name, k=5):
    res = mem.query_points("people", query=embed(name), limit=k, with_payload=True)
    return [p.payload["person_uri"] for p in res.points]


def point_uris(mem):
    pts, _ = mem.scroll("people", limit=10000, with_payload=True)
    return sorted(p.payload["person_uri"] for p in pts)


def resolver(store, tmp_path):
    return IdentityResolver(oxigraph_url=store.url)


def seed_pair(store, mem):
    a = person(store, mem, "a", "Jane Doe", phones=[PHONE])
    b = person(store, mem, "b", "Jane Doe", emails=[EMAIL])
    person(store, mem, "c", "John Smith", phones=["+44" + "7700900999"])
    return a, b


def ingest_collapse(store, mem, tmp_path, seeded=None):
    """Two nodes for one person (one holds the phone, one the email); an
    incoming record carrying both makes resolve() collapse them, which is the
    ingest-time merge path (merge_on_resolve)."""
    a, b = seeded or seed_pair(store, mem)
    r = resolver(store, tmp_path)
    m = r.resolve(PersonIdentity(display_name="Jane Doe", phones=[PHONE], emails=[EMAIL]))
    assert m.match_type == "exact_identifier_merged", m
    keep = m.person_uri
    lose = b if keep == a else a
    assert store.ask(f"ASK {{ <{lose}> pwg:mergedInto <{keep}> }}")
    return r, keep, lose


# ---------------------------------------------------------------------------
# 1. A merge deletes the loser's point. RED at main: merge_persons was
#    graph-only and the point survived.
# ---------------------------------------------------------------------------
def test_ingest_time_merge_deletes_the_loser_point(world):
    store, mem, tmp = world
    r, keep, lose = ingest_collapse(store, mem, tmp)
    assert lose not in point_uris(mem)
    assert keep in point_uris(mem)
    assert getattr(r, "merge_stats", None) == {"skipped_no_snapshot": 0, "vector_unreconciled": 0}


# ---------------------------------------------------------------------------
# 2. Undo restores it. The journal holds the pre-merge vectors; undo puts both
#    nodes and both points back, and search finds both again.
# ---------------------------------------------------------------------------
def test_undo_of_an_ingest_time_merge_restores_the_loser_and_search_finds_both(world):
    store, mem, tmp = world
    seeded = seed_pair(store, mem)
    before = {u: mem.retrieve("people", ids=[pid(u)], with_payload=True)[0]
              for u in seeded}
    r, keep, lose = ingest_collapse(store, mem, tmp, seeded)
    rows = merge_journal.read_journal(str(tmp / "journal"))
    merges = [e for e in rows if e["kind"] == "merge"]
    assert len(merges) == 1
    assert merges[0]["keep"] == keep and merges[0]["discard"] == lose
    assert merges[0]["qdrant_status"] == "ok" and merges[0]["qdrant_points"] == 2
    assert merges[0]["strategy"] == "ingest_exact_identifier"

    res = merge_journal.undo_merge(
        store.url, r._client, str(tmp / "journal"), merges[0]["id"],
        qdrant_url="http://qdrant.invalid:6333")
    assert res["qdrant_restored"] is True
    assert store.ask(f"ASK {{ <{lose}> a pwg:Person }}")
    assert not store.ask(f"ASK {{ <{lose}> pwg:mergedInto ?k }}")
    for u, p in before.items():
        got = mem.retrieve("people", ids=[pid(u)], with_payload=True, with_vectors=True)
        assert len(got) == 1 and got[0].payload == p.payload
    hits = search(mem, "Jane Doe", k=3)
    assert keep in hits[:2] and lose in hits[:2]


# ---------------------------------------------------------------------------
# 3. Search: a vector search for the merged-away person's name returns the
#    winner's uri and never the loser's. RED at main.
# ---------------------------------------------------------------------------
def test_search_for_a_merged_away_name_returns_the_winner_never_the_loser(world):
    store, mem, tmp = world
    _, keep, lose = ingest_collapse(store, mem, tmp)
    hits = search(mem, "Jane Doe")
    assert lose not in hits
    assert hits[0] == keep


# The batch path already deleted the uuid5 point. A point a writer keyed some
# other way (WhatsApp's uuid4) but carrying the loser's person_uri survived it.
def test_batch_merge_also_deletes_a_loser_point_keyed_by_another_id(world):
    store, mem, tmp = world
    keep = person(store, mem, "k", "Jane Doe")
    lose = person(store, mem, "l", "Jane Doe")
    upsert(mem, lose, "Jane Doe", point_id=str(uuid.uuid4()), source="whatsapp_bridge")
    assert point_uris(mem).count(lose) == 2
    assert br._merge_qdrant("http://qdrant.invalid:6333", "people", keep, lose) is True
    assert lose not in point_uris(mem)
    assert search(mem, "Jane Doe")[0] == keep


# No snapshot, no merge: the ingest-time path behaves like the batch path.
def test_qdrant_down_skips_the_ingest_time_merge(world, monkeypatch):
    store, mem, tmp = world
    a = person(store, mem, "a", "Jane Doe", phones=[PHONE])
    b = person(store, mem, "b", "Jane Doe", emails=[EMAIL])

    def down(*a, **k):
        raise ConnectionError("qdrant down")
    monkeypatch.setattr(qdrant_client, "QdrantClient", down)
    r = resolver(store, tmp)
    r.resolve(PersonIdentity(display_name="Jane Doe", phones=[PHONE], emails=[EMAIL]))
    assert not store.ask(f"ASK {{ <{a}> pwg:mergedInto ?k }}")
    assert not store.ask(f"ASK {{ <{b}> pwg:mergedInto ?k }}")
    assert getattr(r, "merge_stats", {}).get("skipped_no_snapshot") == 1
    skips = [e for e in merge_journal.read_journal(str(tmp / "journal")) if e["kind"] == "skip"]
    assert skips and skips[0]["reason"] == "qdrant_unavailable"


# ---------------------------------------------------------------------------
# 4. The upgrade repair, on a seeded copy shaped like the v1.0.120 box: 86
#    merged-away points whose chains (1 to 7 hops) end at a live Person, and 1
#    point whose uri is in the graph in no position. Plus two controls the box
#    did not have: a chain that dangles and a chain that loops.
# ---------------------------------------------------------------------------
BOX_HOPS = [1] * 22 + [3] * 20 + [4] * 14 + [2] * 14 + [1] * 8 + [5] * 4 + [7] * 2 + [6] + [2]


def seed_box(store, mem):
    losers = []
    for i, hops in enumerate(BOX_HOPS):
        final = person(store, mem, f"w{i}", f"Winner {i}")
        chain = [f"{PWG}person_r{i}_{h}" for h in range(hops)]
        nxt = final
        for h, u in enumerate(reversed(chain)):
            store.update(f"INSERT DATA {{ <{u}> a pwg:RetiredPerson ; pwg:mergedInto <{nxt}> ; "
                         f'pwg:displayName "Winner {i}" }}')
            nxt = u
        upsert(mem, chain[0], f"Winner {i}")   # the first loser kept its point
        losers.append(chain[0])
    orphan = f"{PWG}person_orphan"
    upsert(mem, orphan, "orphan-point", source="fda_people_index")
    dangling = f"{PWG}person_dangling"
    store.update(f"INSERT DATA {{ <{dangling}> a pwg:RetiredPerson ; "
                 f"pwg:mergedInto <{PWG}person_never_existed> }}")
    upsert(mem, dangling, "dangling-point")
    loop_a, loop_b = f"{PWG}person_loop_a", f"{PWG}person_loop_b"
    store.update(f"INSERT DATA {{ <{loop_a}> a pwg:RetiredPerson ; pwg:mergedInto <{loop_b}> . "
                 f"<{loop_b}> a pwg:RetiredPerson ; pwg:mergedInto <{loop_a}> }}")
    upsert(mem, loop_a, "loop-point")
    return losers, orphan, dangling, loop_a


def test_upgrade_repair_on_a_box_shaped_copy(world, capsys):
    store, mem, tmp = world
    losers, orphan, dangling, loop_a = seed_box(store, mem)
    assert len(losers) == 86
    n_before = len(point_uris(mem))

    # Read-only first, as on the box.
    dry = br.sweep_qdrant_orphans_of_merged_people(
        "http://qdrant.invalid:6333", "people", store.url, apply=False,
        backup_dir=str(tmp / "bk"))
    assert len(point_uris(mem)) == n_before
    assert dry.orphans == 86
    assert getattr(dry, "candidates", None) == 86 + 3
    assert getattr(dry, "true_orphan_uris", None) == [orphan]
    assert sorted(getattr(dry, "unresolved_merge_uris", [])) == sorted([dangling, loop_a])

    rc = rmc.repair(store.url, "http://qdrant.invalid:6333", "people",
                    apply=True, backup_dir=str(tmp / "bk"))
    out = capsys.readouterr().out
    assert rc == rmc.EXIT_OK, out
    after = point_uris(mem)
    assert not set(losers) & set(after)
    assert orphan in after and dangling in after and loop_a in after
    assert len(after) == n_before - 86
    assert "deleted by this run   : 86" in out
    assert "true orphans          : 1" in out
    assert "dangling merge chain  : 2" in out
    # Journalled: every deleted point is in the backup, readable, restorable.
    backups = list((tmp / "bk").glob("qdrant_orphan_sweep_backup_*.jsonl"))
    assert len(backups) == 1
    rows = [json.loads(x) for x in backups[0].read_text().splitlines() if x.strip()]
    assert sorted(r["payload"]["person_uri"] for r in rows) == sorted(losers)
    assert all(len(r["vector"]) == DIM for r in rows)
    # Search for a merged-away name now returns the winner.
    assert search(mem, "Winner 5")[0] == f"{PWG}person_w5"

    # Idempotent: a second run finds and deletes nothing.
    rc = rmc.repair(store.url, "http://qdrant.invalid:6333", "people",
                    apply=True, backup_dir=str(tmp / "bk2"))
    out = capsys.readouterr().out
    assert rc == rmc.EXIT_OK, out
    assert "deleted by this run   : 0" in out
    assert point_uris(mem) == after
