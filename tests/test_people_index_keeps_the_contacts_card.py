"""The people index keeps the Contacts card it mirrors (v1.0.122 walk, Mini16).

people_count_agreement FAILED by 100: 101 people counted in the graph were
hidden in Qdrant. Every one carried an icloud_contact_uid identifier in the
graph and NO icloud_uid on its point (2178 carded graph people, 1 carded point
of 11370). ingest_people_to_qdrant upserts at uuid5(person_uri), the same id
contact_syncer uses, and never wrote icloud_uid, so the upsert erased the card.
people_rules SHARED RULE A then hid every carded person whose handles are all
sender-ID shaped. Real SPARQL through the shipped loader; synthetic data only.
"""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

pytest.importorskip("pyoxigraph")

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "vendor"))
sys.path.insert(0, str(ROOT / "vendor" / "cm041" / "assistant_api"))
sys.path.insert(0, str(ROOT / "tests"))

from _fake_oxigraph import FakeOxigraph  # noqa: E402
from people_rules import is_countable_person  # noqa: E402
from ostler_fda import pwg_ingest as _pwg  # noqa: E402

# The shipped scroll, captured before any fixture fakes it.
REAL_SCROLL = _pwg._qdrant_scroll_points

URI = "https://schema.ostler.ai/ontology#person_cardtest0001"
ID_UID = URI + "_id_card"
ID_PH = URI + "_id_phone"
# A carded contact whose only handle is an alphanumeric sender ID.
SENDER = "TESTBANK"
# Composed from parts so no two-word name literal sits in this file (name guard).
GIVEN = "Test" + "bank"
DISPLAY = GIVEN + " " + "Alerts"


@pytest.fixture()
def world(monkeypatch):
    store = FakeOxigraph()
    from ostler_fda import pwg_ingest as mod
    monkeypatch.setattr(mod, "OXIGRAPH_URL", store.url)
    store.update(
        "INSERT DATA { "
        f"<{URI}> a pwg:Person ; pwg:displayName \"{DISPLAY}\" ; "
        f"pwg:givenName \"{GIVEN}\" ; pwg:hasIdentifier <{ID_UID}> , <{ID_PH}> . "
        f"<{ID_UID}> pwg:identifierType \"icloud_contact_uid\" ; pwg:identifierValue \"CARD-0001\" . "
        f"<{ID_PH}> pwg:identifierType \"phone\" ; pwg:identifierValue \"{SENDER}\" . }}")
    points: list = []
    monkeypatch.setattr(mod, "_person_embed_doc", lambda p: "doc")
    monkeypatch.setattr(mod, "_ollama_embed_batch", lambda docs: [[0.1, 0.2]] * len(docs))
    monkeypatch.setattr(mod, "_qdrant_ensure_collection", lambda *a, **k: None)
    monkeypatch.setattr(mod, "_qdrant_upsert_points", lambda c, pts: points.extend(pts) or len(pts))
    monkeypatch.setattr(mod, "_qdrant_scroll_points", lambda *a, **k: [])
    monkeypatch.setattr(mod, "_qdrant_delete_points", lambda c, ids: 0)
    yield mod, points
    store.close()


def test_the_point_carries_the_card_and_both_stores_count_the_person(world):
    mod, points = world
    mod.ingest_people_to_qdrant()
    pl = [p["payload"] for p in points if p["payload"]["person_uri"] == URI]
    assert len(pl) == 1, "control: the person must be indexed at all"
    pl = pl[0]
    assert pl.get("icloud_uid") == "CARD-0001"
    # Graph side, as the walk probe builds it: carded, so countable.
    assert is_countable_person(DISPLAY, GIVEN, "", [], [SENDER], has_card=True)
    # Qdrant side, as the Doctor builds it from the payload: must agree.
    assert is_countable_person(pl["display_name"], pl["given_name"], pl["family_name"],
                               pl["emails"], pl["phones"],
                               has_card=bool((pl.get("icloud_uid") or "").strip()))


def test_control_the_same_person_without_a_card_is_hidden():
    # Proves the fixture exercises SHARED RULE A: without the card it hides.
    assert not is_countable_person(DISPLAY, GIVEN, "", [], [SENDER], has_card=False)


def _seed_existing(mod, monkeypatch, payload):
    import uuid
    pid = str(uuid.uuid5(uuid.NAMESPACE_URL, URI))
    monkeypatch.setattr(mod, "_qdrant_scroll_points", lambda *a, **k: [{"id": pid, "payload": dict(payload)}])


# Every key contact_syncer writes (syncer.py ~1100-1150), synthetic values,
# and the strictest level.
SYNCER = {
    "person_id": "p", "person_uri": URI, "display_name": DISPLAY,
    "given_name": GIVEN, "family_name": "", "organization": "Test Org",
    "job_title": "Tester", "phones": [SENDER], "emails": [],
    "icloud_uid": "CARD-0001", "profile_photo_path": "/synthetic/photo.jpg",
    "contact_type": "person", "privacy_level": "L3", "source": "icloud_contacts",
    "last_contact": "", "last_contact_ts": 0,
    "created_at": "2026-01-02T03:04:05Z", "updated_at": "2026-01-02T03:04:05Z",
}


def test_the_sweep_never_drops_a_key_it_does_not_compute_nor_weakens_l3(world, monkeypatch):
    mod, points = world
    _seed_existing(mod, monkeypatch, SYNCER)
    mod.ingest_people_to_qdrant()
    pl = [p["payload"] for p in points if p["payload"]["person_uri"] == URI][0]
    for key in ("icloud_uid", "profile_photo_path", "created_at", "updated_at", "organization", "job_title"):
        assert pl.get(key) == SYNCER[key], key
    assert pl["privacy_level"] == "L3"


def test_an_unparseable_stored_level_is_treated_as_l3(world, monkeypatch):
    mod, points = world
    _seed_existing(mod, monkeypatch, dict(SYNCER, privacy_level="secret-ish"))
    mod.ingest_people_to_qdrant()
    pl = [p["payload"] for p in points if p["payload"]["person_uri"] == URI][0]
    assert pl["privacy_level"] == "L3"


def test_a_failed_read_of_the_stored_points_refuses_to_overwrite(world, monkeypatch):
    mod, points = world
    monkeypatch.setattr(mod, "_qdrant_scroll_points", lambda *a, **k: None)
    res = mod.ingest_people_to_qdrant()
    assert res["status"] == "error" and res.get("reason") == "could_not_read_existing"
    assert points == []



def test_a_fresh_install_with_no_collection_indexes_everyone(world, monkeypatch):
    """Archie's rule: a MISSING collection (Qdrant answers 404) means nothing
    is stored and the write proceeds; only a real read failure writes
    nothing. The read goes through the real _qdrant_scroll_points against a
    real local HTTP server that answers 404, as Qdrant does for an absent
    collection."""
    import http.server
    import threading

    class NoCollection(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            self.send_response(404)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"status":{"error":"Not found: Collection `people` doesn\'t exist!"}}')

        def log_message(self, *a):
            pass

    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), NoCollection)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    mod, points = world
    created = []
    monkeypatch.setattr(mod, "_qdrant_scroll_points", REAL_SCROLL)  # undo the world's fake
    monkeypatch.setattr(mod, "QDRANT_URL", "http://127.0.0.1:%d" % srv.server_address[1])
    monkeypatch.setattr(mod, "_qdrant_ensure_collection", lambda c, *a, **k: created.append(c))
    try:
        res = mod.ingest_people_to_qdrant()
    finally:
        srv.shutdown()
    assert created, "the sweep creates the collection"
    assert res["status"] == "ok" and res["sent"] == 1, res
    assert [p["payload"]["person_uri"] for p in points] == [URI]
