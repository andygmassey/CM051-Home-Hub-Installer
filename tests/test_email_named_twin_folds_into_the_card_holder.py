"""An address-only Person folds into the ONE card holding that address.

v1.0.120 walk (Mini16, read-only, shapes only): the People list showed a row
named by an email address while a human-named row held the same address.

  node A  human name tier, 1 Contacts card uid, 3 email identifiers, 1 phone
  node B  named by the email address, displayName provisional, the address as
          a bare ``pwg:email`` literal, ZERO ``pwg:hasIdentifier``

B is the email ingest's shape (vendor/cm021 ``_build_upsert``). Every identity
path keys on hasIdentifier (``dedupe_merge.find_collisions``,
``IdentityResolver.find_by_identifier``), so B was invisible to all of them
and could never merge: an under-merge, one human on two People rows. 33 such
nodes on that box shared their address with a live identifier-holding node.

Real writer, real sweep, real SPARQL engine: B is written by the shipped
``_build_upsert`` and the fold is ``dedupe_merge.run()`` over HTTP to a
pyoxigraph-backed fake Oxigraph. Synthetic cast, example.com addresses.
"""
from __future__ import annotations

import importlib.util
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
JANE = PWG + "person_card_jane"
JOHN = PWG + "person_card_john"
JANE_MAIL = "jane.stewart@example.com"
FAMILY_MAIL = "the.stewarts@example.com"


def _load_cm021():
    """The shipped email writer, with its parser-only imports stubbed (the
    same stubs tests/test_email_only_people_get_a_provisional_name.py uses)."""
    saved = {k: sys.modules.get(k) for k in
             ("src", "src.filters", "src.parsers", "src.parsers.fast_mbox_parser")}
    src = types.ModuleType("src"); src.__path__ = []
    flt = types.ModuleType("src.filters"); flt.EmailFilter = object
    par = types.ModuleType("src.parsers"); par.__path__ = []
    fmp = types.ModuleType("src.parsers.fast_mbox_parser")
    fmp.FastEmail = object; fmp.FastMboxParser = object
    sys.modules.update({"src": src, "src.filters": flt, "src.parsers": par,
                        "src.parsers.fast_mbox_parser": fmp})
    try:
        spec = importlib.util.spec_from_file_location(
            "cm021_cli_email_twin", ROOT / "vendor" / "cm021" / "src" / "cli.py")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    finally:
        for k, v in saved.items():
            if v is None:
                sys.modules.pop(k, None)
            else:
                sys.modules[k] = v


CLI = _load_cm021()


QDRANT = "http://qdrant.invalid:6333"   # never dialled: the client is in-memory
DIM = 4


def _pid(uri):
    import uuid
    return str(uuid.uuid5(uuid.NAMESPACE_URL, uri))


@pytest.fixture()
def world(tmp_path, monkeypatch):
    qdrant_client = pytest.importorskip("qdrant_client")
    from qdrant_client import models
    store = FakeOxigraph()
    mem = qdrant_client.QdrantClient(":memory:")
    mem.create_collection("people", vectors_config=models.VectorParams(
        size=DIM, distance=models.Distance.COSINE))
    monkeypatch.setattr(qdrant_client, "QdrantClient", lambda *a, **k: mem)
    monkeypatch.setenv("OSTLER_FORGET_TOMBSTONE_FILE", str(tmp_path / "forgotten.json"))
    monkeypatch.setenv("OSTLER_PERSON_DELETION_LOG", str(tmp_path / "del.jsonl"))
    monkeypatch.setenv("DEFAULT_COUNTRY_CODE", "44")
    jdir = tmp_path / "bk" / "merge_journal"
    monkeypatch.setenv("OSTLER_MERGE_JOURNAL_DIR", str(jdir))
    monkeypatch.setenv("QDRANT_URL", QDRANT)
    from ostler_fda import dedupe_merge
    monkeypatch.setattr(dedupe_merge, "OXIGRAPH_URL", store.url)
    yield types.SimpleNamespace(store=store, dm=dedupe_merge, mem=mem, jdir=jdir, tmp=tmp_path)
    store.close()


def _vector(w, uri):
    from qdrant_client import models
    w.mem.upsert("people", points=[models.PointStruct(
        id=_pid(uri), vector=[1.0, 0.0, 0.0, 0.0], payload={"person_uri": uri})])


def _vectors(w):
    pts, _ = w.mem.scroll("people", limit=100, with_payload=True)
    return sorted(p.payload["person_uri"] for p in pts)


def _journal(w):
    import json
    p = w.jdir / "merge_journal.jsonl"
    return [json.loads(x) for x in p.read_text().splitlines()] if p.exists() else []


def _rows(w, q):
    with w.store.lock:
        return list(w.store.ds.query("PREFIX pwg: <%s>\n%s" % (PWG, q)))


def _live(w):
    return sorted(r["p"].value for r in _rows(
        w, "SELECT DISTINCT ?p WHERE { ?p a pwg:Person . "
           "FILTER NOT EXISTS { ?p pwg:mergedInto ?t } }"))


def _names(w, uri):
    return sorted(r["n"].value for r in _rows(w, f"SELECT ?n WHERE {{ <{uri}> pwg:displayName ?n }}"))


def _card(w, uri, name, uid, *emails):
    ids = [("icloud_contact_uid", uid)] + [("email", e) for e in emails]
    body = " ".join(
        f'<{uri}> pwg:hasIdentifier <{uri}_i{i}> . <{uri}_i{i}> a pwg:PersonIdentifier ; '
        f'pwg:identifierType "{t}" ; pwg:identifierValue "{v}" .'
        for i, (t, v) in enumerate(ids))
    w.store.update(f'INSERT DATA {{ <{uri}> a pwg:Person ; pwg:displayName "{name}" . {body} }}')


def _email_ingest(w, address, from_name=""):
    """One email-ingest write, exactly as cm021 does it on a tick."""
    iri = CLI._live_person_iri(w.store.url, CLI._safe_person_iri(address))
    w.store.ds.update(CLI._build_upsert(iri, address, from_name, "2026-10-20T09:30:00Z"))
    return CLI._safe_person_iri(address)


# ── GREEN ──────────────────────────────────────────────────────────────────

def test_email_named_row_folds_into_the_human_named_card(world):
    _card(world, JANE, "Jane Stewart", "SYNTHETIC-CARD-UID-0001", JANE_MAIL)
    twin = _email_ingest(world, JANE_MAIL)
    assert _names(world, twin) == [JANE_MAIL], "precondition: an email-named row"
    assert len(_live(world)) == 2, "precondition: one human, two rows"
    stats = world.dm.run()
    assert len(_live(world)) == 1, ("live rows after the sweep", len(_live(world)))
    assert _live(world) == [JANE]
    assert stats.get("email_twins_merged") == 1, stats
    assert _names(world, JANE) == ["Jane Stewart"], "the human name must win"
    # The next email tick follows the tombstone; it never re-creates the row.
    _email_ingest(world, JANE_MAIL)
    assert _live(world) == [JANE]
    assert _names(world, JANE) == ["Jane Stewart"]
    assert world.dm.run().get("email_twins_merged") == 0, "a second sweep is a no-op"


def test_same_full_name_from_the_header_folds_too(world):
    _card(world, JANE, "Jane Stewart", "SYNTHETIC-CARD-UID-0001", JANE_MAIL)
    _email_ingest(world, JANE_MAIL, "Jane Stewart")
    assert len(_live(world)) == 2
    stats = world.dm.run()
    assert len(_live(world)) == 1, ("live rows after the sweep", len(_live(world)))
    assert stats.get("email_twins_merged") == 1, stats


# ── NEGATIVE ───────────────────────────────────────────────────────────────

def test_a_different_human_name_on_the_address_stays_apart(world):
    _card(world, JANE, "Jane Stewart", "SYNTHETIC-CARD-UID-0001", JANE_MAIL)
    _email_ingest(world, JANE_MAIL, "Tom Jones")
    stats = world.dm.run()
    assert len(_live(world)) == 2
    assert stats.get("email_twins_merged") == 0 and stats.get("email_twins_name_differs") == 1, stats


def test_a_shared_family_address_joins_nobody(world):
    _card(world, JANE, "Jane Stewart", "SYNTHETIC-CARD-UID-0001", FAMILY_MAIL)
    _card(world, JOHN, "John Stewart", "SYNTHETIC-CARD-UID-0002", FAMILY_MAIL)
    _email_ingest(world, FAMILY_MAIL)
    stats = world.dm.run()
    assert len(_live(world)) == 3
    assert stats.get("email_twins_merged") == 0, stats
    assert stats.get("email_twins_shared_refused") == 1, stats


def test_two_different_people_who_share_nothing_stay_two(world):
    _card(world, JANE, "Jane Stewart", "SYNTHETIC-CARD-UID-0001", JANE_MAIL)
    _email_ingest(world, "tom.jones@example.com", "Tom Jones")
    stats = world.dm.run()
    assert len(_live(world)) == 2
    assert stats.get("email_twins_merged") == 0, stats


# ── CONDITION 2: the fold is a merge like every other ──────────────────────

def test_the_fold_is_journalled_tombstoned_drops_the_vector_and_undo_restores_it(world):
    """A mergedInto tombstone, a journal row with a snapshot, the loser's people
    vector deleted, and the journal's undo puts the twin and its vector back."""
    import httpx
    from identity_resolver import merge_journal
    _card(world, JANE, "Jane Stewart", "SYNTHETIC-CARD-UID-0001", JANE_MAIL)
    twin = _email_ingest(world, JANE_MAIL)
    _vector(world, JANE)
    _vector(world, twin)
    assert _vectors(world) == sorted([JANE, twin])

    stats = world.dm.run()
    assert stats.get("email_twins_merged") == 1, stats
    assert world.store.ask(f"ASK {{ <{twin}> pwg:mergedInto <{JANE}> }}"), "no mergedInto tombstone"
    rows = [e for e in _journal(world) if e.get("kind") == "merge"]
    assert len(rows) == 1, rows
    assert rows[0]["keep"] == JANE and rows[0]["discard"] == twin
    assert rows[0]["strategy"] == "email_twin"
    assert (world.jdir / rows[0]["snapshot"]).exists()
    assert JANE_MAIL not in (world.jdir / "merge_journal.jsonl").read_text()
    assert _vectors(world) == [JANE], "the folded twin kept a searchable vector"

    with httpx.Client(trust_env=False) as client:
        res = merge_journal.undo_merge(world.store.url, client, str(world.jdir),
                                       rows[0]["id"], qdrant_url=QDRANT)
    assert res.get("qdrant_restored") is True, res
    assert sorted(_live(world)) == sorted([JANE, twin])
    assert _names(world, twin) == [JANE_MAIL]
    assert _names(world, JANE) == ["Jane Stewart"]
    assert _vectors(world) == sorted([JANE, twin])


def test_no_journal_no_fold(world, monkeypatch):
    """Fail closed: with no merge journal there is no fold at all."""
    monkeypatch.setenv("OSTLER_MERGE_JOURNAL_DIR", "")
    _card(world, JANE, "Jane Stewart", "SYNTHETIC-CARD-UID-0001", JANE_MAIL)
    _email_ingest(world, JANE_MAIL)
    stats = world.dm.run()
    assert stats.get("email_twins_merged") == 0 and stats.get("email_twins_unjournalled") == 1, stats
    assert len(_live(world)) == 2


def test_a_vector_the_fold_could_not_delete_is_swept_by_the_repair(world, monkeypatch, capsys):
    """If the vector delete fails, the tombstone is what #3235's upgrade repair
    keys on: repair_merge_consistency removes the folded twin's vector."""
    from identity_resolver import merge_journal
    from identity_resolver import repair_merge_consistency as rmc
    _card(world, JANE, "Jane Stewart", "SYNTHETIC-CARD-UID-0001", JANE_MAIL)
    twin = _email_ingest(world, JANE_MAIL)
    _vector(world, JANE)
    _vector(world, twin)

    def _boom(*a, **k):
        raise RuntimeError("qdrant went away")
    monkeypatch.setattr(merge_journal, "delete_person_points", _boom)
    stats = world.dm.run()
    assert stats.get("email_twins_merged") == 1 and stats.get("email_twins_vector_unreconciled") == 1, stats
    assert twin in _vectors(world)
    rc = rmc.repair(world.store.url, QDRANT, "people", apply=True,
                    backup_dir=str(world.tmp / "rbk"))
    assert rc == rmc.EXIT_OK, capsys.readouterr().out
    assert _vectors(world) == [JANE]
