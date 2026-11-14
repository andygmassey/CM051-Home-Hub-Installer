"""Two people who fold to one slug must never be confused by a slug lookup.

``_wiki_slug`` folds accents, so "Jane\u0301 Doe" and "Jane Doe" are
both ``zoe-quillfeather`` while being two people. Forget, enrichment, the
timeline and the suppression writer used to take the FIRST match, so forgetting
one could erase the other (irreversibly).

The contract under test:
  * a slug that resolves to more than one person is a 409, counted before any
    mutation, and the store is left exactly as it was (read back from Oxigraph);
  * forget accepts an optional ``person_uri`` and erases only that person;
  * a single match behaves as before (control).

HOW IT RUNS. The real ``api_people_forget`` and friends run against a real
pyoxigraph Store behind a socket (``_fake_oxigraph.py``). The live-route tests
POST to the real HTTP Handler. Synthetic names only; ``example.invalid`` emails.
"""
from __future__ import annotations

import importlib.util
import json
import socket
import sys
import threading
import types
import urllib.error
import urllib.request
from http.server import HTTPServer
from pathlib import Path

import pytest

pytest.importorskip("pyoxigraph")

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
sys.path.insert(0, str(REPO / "tests"))
sys.path.insert(0, str(HERE))
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

from _fake_oxigraph import FakeOxigraph  # noqa: E402
from _fake_qdrant import FakeQdrant  # noqa: E402

ZOE_ACCENT = "Jane\u0301 Doe"
ZOE_PLAIN = "Jane Doe"
JANE = "John Smith"
SLUG_SHARED = "jane-doe"
SLUG_JANE = "john-smith"
URI_ACCENT = "https://schema.ostler.ai/ontology#person_syn0000000a"
URI_PLAIN = "https://schema.ostler.ai/ontology#person_syn0000000b"
URI_JANE = "https://schema.ostler.ai/ontology#person_syn0000000c"
PWG_TYPE = "https://schema.ostler.ai/ontology#SuggestionSuppression"


# test_people_list_endpoint loads the vendored ical-server WITH the
# ostler_security stub the CI box needs (HR015 is private). Reuse that load.
from test_people_list_endpoint import (  # noqa: E402
    _TEST_SERVICE_TOKEN,
    server as _vendored_server,
)


def _load_server():
    return _vendored_server


@pytest.fixture()
def world(tmp_path, monkeypatch):
    store = FakeOxigraph()
    monkeypatch.setenv("OSTLER_FORGET_TOMBSTONE_FILE", str(tmp_path / "forgotten.json"))
    monkeypatch.setenv("OSTLER_QUEUE_DIR", str(tmp_path / "queue"))
    monkeypatch.setenv("OXIGRAPH_URL", store.url)
    server = _load_server()
    monkeypatch.setattr(server, "OXIGRAPH_URL", store.url)
    qdrant = FakeQdrant(status=200)  # the forget purges BOTH stores or says so
    monkeypatch.setattr(server, "QDRANT_URL", qdrant.url)
    monkeypatch.setattr(server, "_RECOMPILE_QUEUE_DIR", tmp_path / "queue")
    for uri, name in ((URI_ACCENT, ZOE_ACCENT), (URI_PLAIN, ZOE_PLAIN), (URI_JANE, JANE)):
        store.update(
            f'INSERT DATA {{ <{uri}> a pwg:Person ; pwg:displayName "{name}" . }}')
    w = types.SimpleNamespace(store=store, server=server, tmp=tmp_path)
    yield w
    qdrant.close()
    store.close()


def _names(w):
    return sorted(w.store.person_names())


def _uris(w):
    rows = w.server._sparql_select(
        "PREFIX pwg: <https://schema.ostler.ai/ontology#>\n"
        "SELECT ?person WHERE { ?person a pwg:Person . }")
    return sorted(r["person"] for r in rows)


def _suppression_triples(w):
    rows = w.server._sparql_select(
        f"SELECT ?s WHERE {{ ?s a <{PWG_TYPE}> . }}")
    return len(rows)


def _no_audit(w):
    return not (w.tmp / "queue" / "forget_audit.log").exists()


# ── forget by slug: the refusal ─────────────────────────────────────────────

def test_forget_by_shared_slug_refuses_and_erases_nobody(world):
    body, status = world.server.api_people_forget(SLUG_SHARED)
    assert status == 409, (status, body)
    assert body["error"] == "more than one person matches"
    assert body["match_count"] == 2
    assert body["forgotten"] is False
    # Read back from the store, not from the handler's return value.
    assert sorted(world.store.person_names()) == sorted([ZOE_ACCENT, ZOE_PLAIN, JANE])
    assert len(_uris(world)) == 3
    assert _no_audit(world), "a 409 must not write the forget audit"
    assert not (world.tmp / "forgotten.json").exists(), "a 409 must not write a tombstone"


# ── forget by URI: the way out ──────────────────────────────────────────────

def test_forget_by_uri_erases_only_that_person(world):
    body, status = world.server.api_people_forget(SLUG_SHARED, person_uri=URI_ACCENT)
    assert status == 200, (status, body)
    assert body["forgotten"] is True
    names = sorted(world.store.person_names())
    assert ZOE_ACCENT not in names, "the named person must be gone"
    assert ZOE_PLAIN in names and JANE in names, "the twin and the bystander must survive"
    assert URI_PLAIN in _uris(world) and URI_JANE in _uris(world)


def test_forget_by_unknown_uri_is_404_and_writes_nothing(world):
    unknown = "https://schema.ostler.ai/ontology#person_syn0000000z"
    body, status = world.server.api_people_forget(SLUG_SHARED, person_uri=unknown)
    assert status == 404, (status, body)
    assert len(_uris(world)) == 3
    assert _no_audit(world)


def test_forget_with_non_string_uri_is_400(world):
    body, status = world.server.api_people_forget(SLUG_SHARED, person_uri=12345)
    assert status == 400
    assert len(_uris(world)) == 3


# ── control: a single match is unchanged ────────────────────────────────────

def test_control_single_match_forgets_as_before(world):
    body, status = world.server.api_people_forget(SLUG_JANE)
    assert status == 200, (status, body)
    assert body["forgotten"] is True
    assert JANE not in world.store.person_names()
    assert len(_uris(world)) == 2


# ── the same guard on the other slug-keyed readers and writers ──────────────

def test_enrichment_by_shared_slug_is_409(world):
    body, status = world.server.person_enrichment(SLUG_SHARED)
    assert status == 409, (status, body)
    assert body["match_count"] == 2
    assert "person" not in body


def test_timeline_by_shared_slug_is_409(world):
    body, status = world.server.person_timeline(SLUG_SHARED)
    assert status == 409, (status, body)
    assert body["match_count"] == 2


def test_suppression_by_shared_slug_is_409_and_writes_nothing(world):
    body, status = world.server.api_people_suppress_suggestions(
        SLUG_SHARED, {"suppressed": True, "reason": "deceased"})
    assert status == 409, (status, body)
    assert _suppression_triples(world) == 0, "a 409 must not write a suppression record"


def test_suppression_control_single_match_writes_one_record(world):
    body, status = world.server.api_people_suppress_suggestions(
        SLUG_JANE, {"suppressed": True, "reason": "user_request"})
    assert status == 200, (status, body)
    assert _suppression_triples(world) == 1


# ── the mutant: without the count guard the wrong person is erased ──────────

def test_mutant_without_count_guard_erases_the_wrong_person(world, monkeypatch):
    """Proves the harness can see the defect. Replace the counting helper with
    the old first-match behaviour: the forget then erases one of the twins
    (the first the store lists), and the 409 guard is what prevents it."""
    srv = world.server

    def first_match_only(slug):
        hits = [r for r in srv._merge_aware_name_rows()
                if srv._wiki_slug(r.get("name", "")) == slug]
        best = srv._rank_name_rows(hits)[0]
        return best["person"], best.get("name", "")

    monkeypatch.setattr(world.server, "_resolve_person_by_slug", first_match_only)
    body, status = world.server.api_people_forget(SLUG_SHARED)
    assert status == 200, "mutant should forget without refusing"
    remaining = sorted(world.store.person_names())
    erased = [n for n in (ZOE_ACCENT, ZOE_PLAIN) if n not in remaining]
    assert len(erased) == 1, f"mutant must erase exactly one of the twins, erased {len(erased)}"


# ── live HTTP route: the body carries person_uri ────────────────────────────

_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def _free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def _post(port, path, payload=None, raw=None):
    data = raw if raw is not None else (json.dumps(payload).encode() if payload is not None else b"")
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data, method="POST",
                                 headers={"Content-Type": "application/json",
                                          "Authorization": "Bearer " + _TEST_SERVICE_TOKEN})
    try:
        with _OPENER.open(req, timeout=10) as resp:
            return resp.status, json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read() or b"{}")


@pytest.fixture()
def live(world):
    port = _free_port()
    httpd = HTTPServer(("127.0.0.1", port), world.server.Handler)
    t = threading.Thread(target=httpd.serve_forever, daemon=True)
    t.start()
    yield port
    httpd.shutdown()
    httpd.server_close()


def test_route_shared_slug_without_uri_is_409_over_http(world, live):
    status, body = _post(live, f"/api/v1/people/{SLUG_SHARED}/forget")
    assert status == 409, (status, body)
    assert len(_uris(world)) == 3


def test_route_person_uri_in_body_forgets_exactly_that_person(world, live):
    status, body = _post(live, f"/api/v1/people/{SLUG_SHARED}/forget",
                         {"person_uri": URI_PLAIN})
    assert status == 200, (status, body)
    assert body["forgotten"] is True
    assert ZOE_PLAIN not in world.store.person_names()
    assert ZOE_ACCENT in world.store.person_names() and JANE in world.store.person_names()


def test_route_empty_body_still_works_for_single_match(world, live):
    status, body = _post(live, f"/api/v1/people/{SLUG_JANE}/forget")
    assert status == 200 and body["forgotten"] is True


def test_route_non_object_body_is_400(world, live):
    status, body = _post(live, f"/api/v1/people/{SLUG_JANE}/forget", raw=b"[1,2]")
    assert status == 400
    assert JANE in world.store.person_names()
