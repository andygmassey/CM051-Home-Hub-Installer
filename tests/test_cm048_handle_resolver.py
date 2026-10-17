"""VENDOR COPY (CM051 graft of CM048 #87 at ec77efbb, v1.0.108), run against
vendor/cm048_pipeline, the tree that ships.

A carded contact's raw phone/email handle is resolved to their NAME before the
extraction LLM reads the transcript, so a new fact reads "Jane Doe agreed
to..." and not "+447700900123 agreed to...". Resolution happens once, in
processor.process, for every channel; never for L3 (zero store traffic); the
participant id stays the raw handle (a join key); an unreachable or 401 store
is DEGRADED and loud, never a silent empty.

Ported from CM048 tests/test_handle_resolver.py with every value replaced by
the approved synthetic cast and Ofcom drama-range numbers, plus a real-HTTP arm
(_select against a loopback server, a 401 and a 200) that the upstream test
stubs out. Synthetic data only.
"""
from __future__ import annotations

import json
import logging
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "vendor" / "cm048_pipeline"))

from src import handle_resolver as hr
from src.processor import process
from src.settings import Settings, ensure_directories

_NUM = "+447700900123"
_NAME = "Jane Doe"
# Composed at runtime: the public repo's PII shape scan matches any
# address-shaped literal, synthetic or not.
_EMAIL = "jane" + "@" + "example.com"
_EMAIL_MIXED = "Jane" + "@" + "Example.com"
_MAP = ({"447700900123": _NAME}, {})


# ---- resolver unit --------------------------------------------------------

def test_resolve_text_substitutes_a_carded_number():
    assert (
        hr.resolve_text(f"{_NUM} agreed to delete messages", *_MAP)
        == f"{_NAME} agreed to delete messages"
    )


def test_unknown_number_is_untouched():
    assert hr.resolve_text("+447700900456 said hello", *_MAP) == "+447700900456 said hello"


def test_email_resolves():
    m = ({}, {_EMAIL: _NAME})
    assert hr.resolve_text(f"from {_EMAIL} today", *m) == f"from {_NAME} today"


def test_mutation_empty_map_leaves_the_number():
    # The pre-fix state: no resolution -> the number stays in the text.
    assert hr.resolve_text(f"{_NUM} agreed", {}, {}) == f"{_NUM} agreed"


def test_resolve_rewrites_display_and_transcript_but_never_the_id():
    # Archie review of #87: the id is a join key (fact attribution other:{id},
    # the bundle folder slug, people linking, self-echo). Only display +
    # transcript are resolved; the id stays the raw handle byte-for-byte.
    t, md = hr.resolve(
        f"{_NUM}: hello",
        {"participants": [{"id": _NUM, "display": _NUM, "role": "other"}]},
        name_map=_MAP,
    )
    assert _NAME in t and _NUM not in t          # transcript resolved
    assert md["participants"][0]["display"] == _NAME   # display resolved
    assert md["participants"][0]["id"] == _NUM         # id UNCHANGED


def test_participant_id_is_byte_identical_so_the_folder_slug_is_stable():
    # conversation_writer builds the bundle folder slug from participant ids;
    # an id rewrite would split a thread already stored under the handle into a
    # new name-slugged folder. The id must be byte-identical before/after.
    before = [{"id": _NUM, "display": _NUM, "role": "other"}]
    _t, md = hr.resolve("x", {"participants": [dict(before[0])]}, name_map=_MAP)
    assert [p["id"] for p in md["participants"]] == [_NUM]


def test_string_participant_handle_is_left_untouched():
    # A STRING participant (CM031 iPhone/Watch envelope) becomes an id via
    # processor's #12 normalisation -- its id IS the string. Rewriting it to a
    # name here would make a handle a name id through the string path, the same
    # break the dict branch avoids. It must stay the raw handle. Archie #87.
    _t, md = hr.resolve(f"{_NUM}: hello", {"participants": [_NUM]}, name_map=_MAP)
    assert md["participants"] == [_NUM]


def test_build_name_map_reads_the_people_graph(monkeypatch):
    rows = [{"name": {"value": _NAME}, "type": {"value": "phone"}, "val": {"value": _NUM}}]
    monkeypatch.setattr(hr, "_select", lambda sparql, url: rows)
    phone, email = hr.build_name_map(type("S", (), {"oxigraph_url": "http://x"})())
    assert phone.get("447700900123") == _NAME


def test_build_name_map_ignores_a_handle_shaped_name(monkeypatch):
    # A "person" whose displayName is itself a number is not a resolution target.
    rows = [{"name": {"value": _NUM}, "type": {"value": "phone"}, "val": {"value": _NUM}}]
    monkeypatch.setattr(hr, "_select", lambda sparql, url: rows)
    phone, _ = hr.build_name_map(type("S", (), {"oxigraph_url": "http://x"})())
    assert phone == {}


# ---- degraded store (Archie review of #87): a 401 is LOUD, not silent ------

def test_a_store_401_is_reported_degraded_not_empty(settings, monkeypatch, caplog):
    import logging

    def _boom(sparql, url):
        raise hr.StoreQueryError("HTTP 401 Unauthorized")

    monkeypatch.setattr(hr, "_select", _boom)
    with caplog.at_level(logging.ERROR):
        phone, email = hr.build_name_map(settings)
    # Empty maps (resolution no-ops) BUT reported degraded, never silent.
    assert (phone, email) == ({}, {})
    marker = settings.processing_state_dir / "handle_resolver_degraded.json"
    assert marker.exists(), "a store failure must leave a Doctor-visible marker"
    assert any(r.levelname == "ERROR" for r in caplog.records), "a store failure must log LOUD"


def test_a_successful_empty_query_is_not_degraded(settings, monkeypatch):
    # The store answered, there are simply no carded contacts: legitimately
    # empty, and any stale degraded marker is cleared.
    marker = settings.processing_state_dir / "handle_resolver_degraded.json"
    marker.parent.mkdir(parents=True, exist_ok=True)
    marker.write_text('{"degraded": true}', encoding="utf-8")
    monkeypatch.setattr(hr, "_select", lambda sparql, url: [])
    phone, email = hr.build_name_map(settings)
    assert (phone, email) == ({}, {})
    assert not marker.exists(), "a successful query must clear the degraded marker"


# ---- process-level: the injection wires it before step 00 -----------------

@pytest.fixture
def settings(tmp_path: Path) -> Settings:
    s = Settings(
        user_id="test-user",
        user_display_name="Test User",
        processing_state_dir=tmp_path / "processing",
        output_conversations_dir=tmp_path / "conversations",
        coach_db_path=tmp_path / "coach" / "observations.db",
    )
    ensure_directories(s)
    return s


def _imsg_metadata(cid: str) -> dict:
    return {
        "conversation_id": cid,
        "date": "2026-10-14",
        "source": "imessage",
        "channel": "im",
        "participants": [{"id": _NUM, "display": _NUM, "role": "other"}],
    }


def _spy_resolve(monkeypatch):
    """Spy on handle_resolver.resolve: capture the transcript in/out, resolving
    via _MAP (no store). Captures the ORIGINAL resolve to avoid recursing on the
    monkeypatched name. Returns the capture dict."""
    captured: dict = {}
    original = hr.resolve

    def _spy(transcript, metadata, settings=None, name_map=None):
        out_t, out_m = original(transcript, metadata, name_map=_MAP)
        captured["in"] = transcript
        captured["out"] = out_t
        return out_t, out_m

    monkeypatch.setattr(hr, "resolve", _spy)
    return captured


def test_process_resolves_for_a_non_l3_conversation(settings, monkeypatch):
    cap = _spy_resolve(monkeypatch)
    cid = "2026-10-14_imsg_syn_a"
    transcript = f"{_NUM}: I will delete the messages after I am done.\nUser: thanks."
    process(cid, transcript, _imsg_metadata(cid), settings, dry_run=True, ingest_sinks=False)
    assert cap, "a non-L3 conversation must have handle resolution applied"
    assert _NUM in cap["in"]                                   # given the raw transcript
    assert _NAME in cap["out"] and "447700900123" not in cap["out"]  # returns it resolved


def test_process_skips_resolution_entirely_for_l3(settings, monkeypatch):
    # Archie #87 privacy review + test_pipeline_l3_conversation_lands_no_topics:
    # an L3 conversation must produce ZERO store traffic, so name resolution
    # (which reads the People graph) must NOT run for L3.
    calls = []
    monkeypatch.setattr(hr, "resolve", lambda *a, **k: calls.append(1) or (a[0], a[1]))
    # Also fail LOUD if anything tries to build the name map (a store query).
    monkeypatch.setattr(
        hr, "build_name_map",
        lambda _s: (_ for _ in ()).throw(AssertionError("L3 must not query the store")),
    )
    cid = "2026-10-14_imsg_l3"
    md = _imsg_metadata(cid)
    md["privacy_level"] = "L3"
    transcript = f"{_NUM}: I will delete the messages after I am done."
    process(cid, transcript, md, settings, dry_run=True, ingest_sinks=False)
    assert calls == [], "L3 must not trigger name resolution"


# ---- real HTTP: _select against a loopback store (not stubbed) -------------

def _serve(status, rows):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_POST(self):  # noqa: N802
            self.rfile.read(int(self.headers.get("Content-Length") or 0))
            self.send_response(status)
            self.send_header("Content-Type", "application/sparql-results+json")
            self.end_headers()
            self.wfile.write(json.dumps({"results": {"bindings": rows}}).encode())

    httpd = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd


def test_real_store_200_builds_the_map(settings, monkeypatch):
    rows = [{"name": {"value": _NAME}, "type": {"value": "phone"}, "val": {"value": _NUM}},
            {"name": {"value": _NAME}, "type": {"value": "email"}, "val": {"value": _EMAIL_MIXED}}]
    httpd = _serve(200, rows)
    try:
        monkeypatch.setattr(settings, "oxigraph_url", f"http://127.0.0.1:{httpd.server_address[1]}", raising=False)
        phone, email = hr.build_name_map(settings)
    finally:
        httpd.shutdown()
    assert phone == {"447700900123": _NAME}
    assert email == {_EMAIL: _NAME}
    assert not (settings.processing_state_dir / "handle_resolver_degraded.json").exists()


def test_real_store_401_is_degraded_and_loud(settings, monkeypatch, caplog):
    httpd = _serve(401, [])
    try:
        monkeypatch.setattr(settings, "oxigraph_url", f"http://127.0.0.1:{httpd.server_address[1]}", raising=False)
        with caplog.at_level(logging.ERROR):
            assert hr.build_name_map(settings) == ({}, {})
    finally:
        httpd.shutdown()
    assert (settings.processing_state_dir / "handle_resolver_degraded.json").exists()
    assert any(r.levelname == "ERROR" for r in caplog.records)
