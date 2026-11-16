"""A service-sender row the people indexer leaves out must be DECLARED, not silent.

Synthetic members only (reserved example.com addresses, invented names).
Red on the v1.0.132 tag: ingest_people_to_qdrant returns no exclusion count.
"""
import sys

import pytest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "vendor"))

import ostler_fda.pwg_ingest as pw  # noqa: E402


def _person(uri, name, emails, phones=None):
    return {"uri": uri, "display_name": name, "contact_type": "person",
            "organization": "", "job_title": "", "given_name": "", "family_name": "",
            "phones": phones or [], "emails": emails, "icloud_uid": "",
            "created_at": "", "last_contact": ""}


def _run(monkeypatch, people):
    monkeypatch.setattr(pw, "_load_people_from_oxigraph", lambda: people)
    monkeypatch.setattr(pw, "_qdrant_scroll_points", lambda c, limit=1000: [])
    monkeypatch.setattr(pw, "_ollama_embed_batch", lambda texts: [[0.1, 0.2] for _ in texts])
    monkeypatch.setattr(pw, "_qdrant_ensure_collection", lambda *a, **k: None)
    monkeypatch.setattr(pw, "_qdrant_upsert_points", lambda c, pts: len(pts))
    monkeypatch.setattr(pw, "_qdrant_delete_points", lambda c, ids: 0)
    monkeypatch.setattr(pw, "_people_index_record", lambda *a, **k: None)
    monkeypatch.setattr(pw, "_people_index_finish", lambda *a, **k: None)
    return pw.ingest_people_to_qdrant()


def test_service_sender_exclusion_is_declared(monkeypatch):
    people = [
        _person("urn:synthetic:person:1", "Synthetic Alpha", ["alpha@example.com"]),
        _person("urn:synthetic:person:2", "Synthetic Bravo", ["noreply@example.com"]),
    ]
    result = _run(monkeypatch, people)
    assert result["total"] == 1
    assert result.get("excluded") == 1, result
    assert result.get("by_reason") == {"service mailbox": 1}, result


@pytest.mark.xfail(strict=True, reason="134: keep a sender on a contact card OR a verified outbound signal (BACKLOG row, 134 rule)")
def test_first_last_address_with_a_card_is_kept(monkeypatch):
    # A personal first.last address that the sender rule flags, but the person
    # has a contact card, must be KEPT (card-or-conversation keeps the person).
    carded = _person("urn:synthetic:person:3", "Synthetic Carol",
                     ["carol.synthetic@wish.example.com"])
    carded["icloud_uid"] = "synthetic-card-uid-3"
    result = _run(monkeypatch, [carded])
    assert result["total"] == 1, result


def test_first_last_address_with_no_card_and_no_conversation_is_excluded(monkeypatch):
    # Control: same shape, no card and no last-contact evidence, stays excluded.
    bare = _person("urn:synthetic:person:4", "Synthetic Dan",
                   ["dan.synthetic@wish.example.com"])
    result = _run(monkeypatch, [bare])
    assert result["total"] == 0, result


def test_notification_sender_that_emailed_the_owner_stays_excluded(monkeypatch):
    # Guard for the 134 rule: a last-contact channel alone is NOT a conversation,
    # so a notification sender that emailed the owner stays excluded on 133.
    notifier = _person("urn:synthetic:person:5", "Synthetic Notifier",
                       ["noreply@example.com"])
    notifier["last_contact"] = "2026-11-01"
    result = _run(monkeypatch, [notifier])
    assert result["total"] == 0, result


def test_declared_exclusion_is_persisted_to_the_state_file(monkeypatch, tmp_path):
    # RED before the product writes the exclusion to the people-index state:
    # the probes need the excluded URIs and reasons on disk, not just in a return.
    state = tmp_path / "people-index.json"
    monkeypatch.setattr(pw, "_people_index_state_path", lambda: state)
    monkeypatch.setattr(pw, "_load_people_from_oxigraph", lambda: [
        _person("urn:synthetic:person:1", "Synthetic Alpha", ["alpha@example.com"]),
        _person("urn:synthetic:person:2", "Synthetic Bravo", ["noreply@example.com"]),
    ])
    monkeypatch.setattr(pw, "_qdrant_scroll_points", lambda c, limit=1000: [])
    monkeypatch.setattr(pw, "_ollama_embed_batch", lambda texts: [[0.1, 0.2] for _ in texts])
    monkeypatch.setattr(pw, "_qdrant_ensure_collection", lambda *a, **k: None)
    monkeypatch.setattr(pw, "_qdrant_upsert_points", lambda c, pts: len(pts))
    monkeypatch.setattr(pw, "_qdrant_delete_points", lambda c, ids: 0)
    pw.ingest_people_to_qdrant()
    import json
    rec = json.loads(state.read_text(encoding="utf-8"))
    assert rec.get("excluded") == 1, rec
    assert rec.get("by_reason") == {"service mailbox": 1}, rec
    assert rec.get("excluded_uris") == ["urn:synthetic:person:2"], rec
