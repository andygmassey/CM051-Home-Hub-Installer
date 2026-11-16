"""A service-sender row the people indexer leaves out must be DECLARED, not silent.

Synthetic members only (reserved example.com addresses, invented names).
Red on the v1.0.132 tag: ingest_people_to_qdrant returns no exclusion count.
"""
import sys
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
