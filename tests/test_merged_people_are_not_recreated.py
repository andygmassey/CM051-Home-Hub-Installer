"""A merged person is never re-created by the next ingest (DMG #27, shape sweep S2).

Walk box: 145 merged-away nodes were typed pwg:Person again (138 from
WhatsApp, 6 from iMessage), each a duplicate person, plus 144 duplicate Qdrant
people points. Every ostler_fda writer mints ``uuid5(identifier)``, so the
next tick computed the merged-away URI, asked ``_person_exists`` (`<uri> a ?t`),
got nothing back from dedupe_merge's UNTYPED tombstone, and minted the person
again. The same check answered False on any store error.

Real SPARQL end to end: the ingest talks HTTP to a pyoxigraph-backed fake
Oxigraph, the merges are the shipped ones (``dedupe_merge.run`` and
``IdentityResolver.merge_persons``). Cast names, reserved phone numbers.
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
PHONE = "+44" + "7700900456"
JID = PHONE[1:] + "@s.whatsapp.net"
# Sorts before every uuid5 "person_" URI, so dedupe_merge keeps it.
SURVIVOR = PWG + "aaa_contact_jane_doe"
FIRST = "2026-10-01T10:00:00Z"
LATER = "2026-10-12T09:30:00Z"


@pytest.fixture()
def world(tmp_path, monkeypatch):
    store = FakeOxigraph()
    monkeypatch.setenv("OSTLER_FORGET_TOMBSTONE_FILE", str(tmp_path / "forgotten.json"))
    monkeypatch.setenv("OSTLER_IDENTIFIER_QUALITY_STATE", str(tmp_path / "iq.json"))
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


def _n_persons(w):
    return len(_rows(w, "SELECT DISTINCT ?p WHERE { ?p a pwg:Person }"))


def _is_person(w, uri):
    return w.store.ask(f"ASK {{ <{uri}> a pwg:Person }}")


def _imessage(w, when):
    (w.fda / "imessage_conversations.json").write_text(json.dumps([
        {"participants": [PHONE], "message_count": 3, "last_message": when, "display_name": ""}]))
    return w.ing.ingest_imessage(w.fda)


def _whatsapp(w, when):
    (w.fda / "whatsapp_conversations.json").write_text(json.dumps([
        {"tier": "whatsapp_dm", "participants": [JID], "last_message": when, "confidence": 1.0}]))
    return w.ing.ingest_whatsapp(w.fda)


def _add_survivor(w):
    w.store.update(
        f'INSERT DATA {{ <{SURVIVOR}> a pwg:Person ; pwg:displayName "Jane Doe" ; '
        f'pwg:hasIdentifier <{SURVIVOR}_id> . <{SURVIVOR}_id> a pwg:PersonIdentifier ; '
        f'pwg:identifierType "phone" ; pwg:identifierValue "{PHONE}" }}')


def _minted_uri(w, handle=PHONE):
    return w.ing._person_uri(w.ing._person_id_from_identifier(handle))


@pytest.mark.parametrize("source", ["imessage", "whatsapp"])
def test_dedupe_merged_person_is_not_recreated_and_the_contact_lands_on_the_survivor(world, source):
    w = world
    ingest, pred = ((_imessage, "lastContactIMessage") if source == "imessage"
                    else (_whatsapp, "lastContactWhatsApp"))
    ingest(w, FIRST)
    _add_survivor(w)
    assert _n_persons(w) == 2, "harness: the ingest minted nothing to merge"
    minted = _minted_uri(w, PHONE if source == "imessage" else JID)
    if source == "imessage":
        stats = w.dm.run()  # the shipped sweep, keyed on the shared phone
        assert stats["merged"] == 1, stats
    else:
        # The WhatsApp node keys on its JID, which the sweep does not compare;
        # fold it with the sweep's own merge step, the untyped-tombstone writer.
        w.dm._merge_pair(SURVIVOR, minted)
    retired = [u for u in (minted,) if w.store.ask(f"ASK {{ <{u}> pwg:mergedInto ?x }}")]
    assert retired, "harness: dedupe_merge did not tombstone the minted node"
    assert _n_persons(w) == 1

    ingest(w, LATER)  # the next hourly tick, from the retired identifier

    assert _n_persons(w) == 1, "the merged person was re-created"
    assert not _is_person(w, retired[0])
    got = [r["v"].value for r in _rows(w, f"SELECT ?v WHERE {{ <{SURVIVOR}> pwg:{pred} ?v }}")]
    assert any(v.startswith(LATER[:10]) for v in got), f"the new contact did not land on the survivor: {got}"


def test_resolver_retired_person_gets_no_new_facts_the_survivor_does(world):
    from identity_resolver.resolver import IdentityResolver
    w = world
    _imessage(w, FIRST)
    _add_survivor(w)
    dupe = _minted_uri(w)
    r = IdentityResolver(oxigraph_url=w.store.url)
    r._sync_qdrant_display_name = lambda *a, **k: None
    r.merge_persons(SURVIVOR, dupe)
    assert w.store.ask(f"ASK {{ <{dupe}> a pwg:RetiredPerson ; pwg:mergedInto <{SURVIVOR}> }}")

    _imessage(w, LATER)

    assert _n_persons(w) == 1
    assert not _is_person(w, dupe)
    assert not _rows(w, f"SELECT ?v WHERE {{ <{dupe}> pwg:lastContactIMessage ?v . FILTER(STR(?v) >= \"{LATER[:10]}\") }}"), \
        "the new contact landed on the retired node"
    got = [r["v"].value for r in _rows(w, f"SELECT ?v WHERE {{ <{SURVIVOR}> pwg:lastContactIMessage ?v }}")]
    assert any(v.startswith(LATER[:10]) for v in got), got


def test_a_store_error_creates_nobody(world, monkeypatch):
    w = world
    calls = {"n": 0}
    real = w.ing._sparql_query

    def flaky(sparql):
        calls["n"] += 1
        raise RuntimeError("store refused the connection")
    monkeypatch.setattr(w.ing, "_sparql_query", flaky)
    res = _imessage(w, FIRST)
    monkeypatch.setattr(w.ing, "_sparql_query", real)
    assert calls["n"] >= 1
    assert _n_persons(w) == 0, "a store error minted a person"
    assert res.get("people_lookup_failed") == 1


def test_people_index_skips_a_merged_node_still_typed_person(world):
    w = world
    _imessage(w, FIRST)
    _add_survivor(w)
    dupe = _minted_uri(w)
    # The walk-box state: merged, and re-typed Person by an older ingest.
    w.store.update(f"INSERT DATA {{ <{dupe}> pwg:mergedInto <{SURVIVOR}> }}")
    assert _is_person(w, dupe)
    uris = {p["uri"] for p in w.ing._load_people_from_oxigraph()}
    assert SURVIVOR in uris and dupe not in uris
    current = w.ing._current_person_uris()
    assert SURVIVOR in current and dupe not in current


def test_email_ingest_upserts_onto_the_survivor(world, monkeypatch):
    w = world
    # cm021 posts with httpx's default (environment) proxy handling, as it
    # does on a Hub. The fake store is on loopback: keep any developer proxy
    # out of the way.
    for k in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"):
        monkeypatch.delenv(k, raising=False)
    monkeypatch.setenv("NO_PROXY", "127.0.0.1,localhost")
    sys.path.insert(0, str(ROOT / "vendor" / "cm021"))
    from src import cli
    addr = "jane.doe" + "@" + "example.invalid"
    minted = cli._safe_person_iri(addr)
    w.store.update(f'INSERT DATA {{ <{SURVIVOR}> a pwg:Person ; pwg:displayName "Jane Doe" . '
                   f'<{minted}> a pwg:RetiredPerson ; pwg:mergedInto <{SURVIVOR}> }}')
    assert cli._live_person_iri(w.store.url, minted) == SURVIVOR
    assert cli._live_person_iri(w.store.url, SURVIVOR) == SURVIVOR
