"""A person erased by /api/v1/people/<slug>/forget stays erased when the
ostler_fda Full Disk Access ingests next run (Lane 18).

ostler_fda mints every person as ``uuid5(lowercased identifier)``, so the SAME
URI comes back on every tick: iMessage, WhatsApp, calendar attendees, Photos
face labels and Apple Mail correspondents. Forget deletes the triples and,
before the tombstone, nothing else, so the next tick re-created the person.

Method, as in test_forget_tombstone_every_syncer.py: the real forget handler
(vendor/cm041 ical-server) and each ingest's real entry point over a
pyoxigraph-backed HTTP fake of Oxigraph. The person is first minted BY
ostler_fda itself (iMessage), then forgotten, then every ingest runs again
with a source that still lists them. test_control_* lifts the tombstone and
shows each ingest recreating them, so the harness can see a recreation.

All identifiers SYNTHETIC / reserved (Ofcom drama range, example.invalid).
"""
from __future__ import annotations

import importlib.util
import json
import sys
import types
from pathlib import Path

import pytest

pytest.importorskip("pyoxigraph")

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "vendor" / "cm041"))
sys.path.insert(0, str(ROOT / "vendor"))
sys.path.insert(0, str(ROOT / "tests"))


def _stub_security() -> None:
    import sqlite3
    try:
        import ostler_security  # noqa: F401
        return
    except Exception:
        pass
    pkg = types.ModuleType("ostler_security")
    pkg.__path__ = []
    sys.modules["ostler_security"] = pkg
    db = types.ModuleType("ostler_security.database")
    db.get_db_connection = lambda path, _k, *a, **kw: sqlite3.connect(path)
    sys.modules["ostler_security.database"] = db
    posture = types.ModuleType("ostler_security.posture")
    posture.record_posture = lambda *a, **kw: None
    sys.modules["ostler_security.posture"] = posture
    db_key = types.ModuleType("ostler_security.db_key")
    db_key.resolve_db_key = lambda *a, **kw: types.SimpleNamespace(
        key=None, source=None, reason="no_key", detail=None)
    sys.modules["ostler_security.db_key"] = db_key


_stub_security()

from _fake_oxigraph import FakeOxigraph  # noqa: E402

PHONE = "+447700900123"
JID = "447700900123@s.whatsapp.net"
EMAIL = "elizabeth.stewart@example.invalid"
FACE = "Elizabeth Stewart"


@pytest.fixture()
def world(tmp_path, monkeypatch):
    store = FakeOxigraph()
    monkeypatch.setenv("OSTLER_FORGET_TOMBSTONE_FILE", str(tmp_path / "forgotten.json"))
    from ostler_fda import pwg_ingest

    monkeypatch.setattr(pwg_ingest, "OXIGRAPH_URL", store.url)
    spec = importlib.util.spec_from_file_location(
        "ical_server_fda", ROOT / "vendor" / "cm041" / "assistant_api" / "ical-server.py")
    server = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(server)
    monkeypatch.setattr(server, "OXIGRAPH_URL", store.url)
    monkeypatch.setattr(server, "QDRANT_URL", "http://127.0.0.1:9")
    monkeypatch.setattr(server, "_RECOMPILE_QUEUE_DIR", tmp_path / "queue")
    fda = tmp_path / "fda"
    fda.mkdir()
    yield types.SimpleNamespace(store=store, fda=fda, ing=pwg_ingest, server=server,
                                tomb=tmp_path / "forgotten.json")
    store.close()


def _write_sources(w):
    (w.fda / "imessage_conversations.json").write_text(json.dumps([
        {"participants": [PHONE], "message_count": 3, "last_message": "2026-10-01T10:00:00Z",
         "display_name": ""}]))
    (w.fda / "whatsapp_conversations.json").write_text(json.dumps([
        {"tier": "whatsapp_dm", "participants": [JID], "last_message": "2026-10-01T10:00:00Z",
         "confidence": 1.0}]))
    (w.fda / "calendar_events.json").write_text(json.dumps([
        {"uid": "e1", "title": "Synthetic sync", "start": "2026-10-01T10:00:00Z",
         "end": "2026-10-01T11:00:00Z", "attendees": [EMAIL]}]))
    (w.fda / "photos_people.json").write_text(json.dumps([
        {"name": FACE, "photo_count": 4, "first_seen": "2025-01-01T00:00:00Z",
         "last_seen": "2025-02-01T00:00:00Z"}]))
    (w.fda / "apple_mail_contacts.json").write_text(json.dumps({EMAIL: 7}))


def _mint_and_forget(w):
    _write_sources(w)
    # Minted BY ostler_fda: the iMessage handle creates the node.
    w.ing.ingest_imessage(w.fda)
    assert w.store.person_count() == 1, "ostler_fda minted nothing, the harness proves nothing"
    # Then the graph learns the rest of the same human, as a Contacts sync and
    # the resolver's merge do: a real name and an email identifier.
    w.store.update(
        'DELETE { ?p pwg:displayName ?o } INSERT { ?p pwg:displayName "%s" } '
        'WHERE { ?p a pwg:Person ; pwg:displayName ?o }' % FACE)
    w.store.update(
        'INSERT { ?p pwg:hasIdentifier <urn:synthetic:id-email> . '
        '<urn:synthetic:id-email> a pwg:PersonIdentifier ; pwg:identifierType "email" ; '
        'pwg:identifierValue "%s" } WHERE { ?p a pwg:Person }' % EMAIL)
    body, status = w.server.api_people_forget(w.server._wiki_slug(FACE))
    assert status == 200 and body["forgotten"] is True, (status, body)
    assert w.store.person_count() == 0, "forget left the person in the graph"


INGESTS = {
    "ingest_imessage": lambda w: w.ing.ingest_imessage(w.fda),
    "ingest_whatsapp": lambda w: w.ing.ingest_whatsapp(w.fda),
    "ingest_calendar": lambda w: w.ing.ingest_calendar(w.fda),
    "ingest_photos_people": lambda w: w.ing.ingest_photos_people(w.fda),
    "ingest_mail_contacts": lambda w: w.ing.ingest_mail_contacts(w.fda),
}


@pytest.mark.parametrize("name", list(INGESTS))
def test_a_forgotten_person_stays_absent_after_the_ingest(world, name):
    _mint_and_forget(world)
    INGESTS[name](world)
    assert world.store.person_names() == [], (
        f"{name} recreated a forgotten person: {world.store.person_names()}"
    )


@pytest.mark.parametrize("name", list(INGESTS))
def test_control_without_the_tombstone_the_same_ingest_recreates_them(world, name):
    _mint_and_forget(world)
    world.tomb.unlink(missing_ok=True)
    INGESTS[name](world)
    assert world.store.person_count() >= 1, (
        f"{name}: with no tombstone nothing was recreated, so this ingest's creation "
        "path is not exercised and the test above proves nothing"
    )
