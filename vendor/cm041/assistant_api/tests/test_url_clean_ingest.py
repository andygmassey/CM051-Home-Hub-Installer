"""The extension's POST (api_safari_ingest, Save to Knowledge) strips
tracking params before the url is stored or keyed. Synthetic URLs only.
Red on origin/main: the handler stores the url as posted."""
from __future__ import annotations

import importlib.util
import sys
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
# Reuse the sibling test's loader (ostler_security stub + real server module).
_spec = importlib.util.spec_from_file_location("tbe_for_url_clean", HERE / "test_browsing_enrich.py")
_tbe = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_tbe)
server = _tbe.server

TRACKED = "https://www.example.com/story?utm_source=nl&fbclid=ABC&id=42"
CLEAN = "https://www.example.com/story?id=42"
YT = "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=30s"
TS = "2026-10-01T10:00:00Z"


def _drive(monkeypatch, url, fn_name="api_safari_ingest"):
    stored = []
    monkeypatch.setattr(server, "_subscription_paused", lambda *_a, **_k: None)
    monkeypatch.setattr(server, "_embed_text", lambda doc: [0.1, 0.2, 0.3])
    monkeypatch.setattr(server, "_safari_qdrant_ensure_collection", lambda *_a, **_k: None)
    monkeypatch.setattr(server, "_safari_qdrant_upsert",
                        lambda pid, vec, payload: stored.append((pid, payload)) or True)
    class Q:
        def enqueue(self, item): pass
    monkeypatch.setattr(server, "_enrich_queue", lambda: Q())
    monkeypatch.setattr(server, "_safari_write_state", lambda *_a, **_k: None)
    body = {"url": url, "title": "t", "timestamp": TS, "text": "body text", "note": "n"}
    result = getattr(server, fn_name)(body)
    return result, stored


def _pid(url):
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"browsing|safari_history|{url}|{TS}"))


def test_visit_post_strips_and_keys_on_clean_url(monkeypatch):
    _res, stored = _drive(monkeypatch, TRACKED)
    assert len(stored) == 1
    pid, payload = stored[0]
    assert payload["url"] == CLEAN
    assert pid == _pid(CLEAN) and pid != _pid(TRACKED)


def test_visit_post_control_functional_params_survive(monkeypatch):
    _res, stored = _drive(monkeypatch, YT)
    assert stored[0][1]["url"] == YT


def test_save_to_knowledge_strips_and_keys_on_clean_url(monkeypatch):
    bn = server._bn()
    monkeypatch.setattr(bn, "qdrant_get_payload", lambda *_a, **_k: None)
    _res, stored = _drive(monkeypatch, TRACKED, fn_name="api_safari_save")
    assert len(stored) == 1, _res
    pid, payload = stored[0]
    assert payload["url"] == CLEAN
    assert pid == _pid(CLEAN)


def test_url_clean_copy_is_the_shipped_one():
    here = (HERE.parent / "url_clean.py").read_bytes()
    fda = (HERE.parent.parent.parent / "ostler_fda" / "url_clean.py").read_bytes()
    assert here == fda
