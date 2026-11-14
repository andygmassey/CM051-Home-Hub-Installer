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

from _fake_oxigraph import FakeOxigraph  # noqa: E402
from _fake_qdrant import FakeQdrant  # noqa: E402
from test_people_list_endpoint import (  # noqa: E402  (loads the vendored server WITH the stub)
    _TEST_SERVICE_TOKEN,
    server as _vendored_server,
)

ACCENT = "Jane\u0301 Doe"        # folds to jane-doe
PLAIN = "Jane Doe"               # the other spelling: a second identity
SAME_A = "Ben Ross"              # two UNLINKED nodes with an identical name
SAME_B = "Ben Ross"
FRAG = "Sam Brown"                # a fragment merged into the survivor
SURV = "Sam Brown"
JOHN = "John Smith"
SLUG_JANE = "jane-doe"
SLUG_PAT = "ben-ross"
SLUG_SAM = "sam-brown"
SLUG_JOHN = "john-smith"
URI_ACCENT = "https://schema.ostler.ai/ontology#person_syn0000000a"
URI_PLAIN = "https://schema.ostler.ai/ontology#person_syn0000000b"
URI_JOHN = "https://schema.ostler.ai/ontology#person_syn0000000c"
URI_SAME_A = "https://schema.ostler.ai/ontology#person_syn0000000d"
URI_SAME_B = "https://schema.ostler.ai/ontology#person_syn0000000e"
URI_FRAG = "https://schema.ostler.ai/ontology#person_syn0000000f"
URI_SURV = "https://schema.ostler.ai/ontology#person_syn00000010"
PWG_TYPE = "https://schema.ostler.ai/ontology#SuggestionSuppression"


def _load_server():
    return _vendored_server


@pytest.fixture()
def world(tmp_path, monkeypatch):
    store = FakeOxigraph()
    monkeypatch.setenv("OSTLER_FORGET_TOMBSTONE_FILE", str(tmp_path / "forgotten.json"))
    monkeypatch.setenv("OXIGRAPH_URL", store.url)
    server = _load_server()
    monkeypatch.setattr(server, "OXIGRAPH_URL", store.url)
    qdrant = FakeQdrant(status=200)  # the forget purges BOTH stores or says so
    monkeypatch.setattr(server, "QDRANT_URL", qdrant.url)
    monkeypatch.setattr(server, "_RECOMPILE_QUEUE_DIR", tmp_path / "queue")
    people = [(URI_ACCENT, ACCENT), (URI_PLAIN, PLAIN), (URI_JOHN, JOHN),
              (URI_SAME_A, SAME_A), (URI_SAME_B, SAME_B),
              (URI_FRAG, FRAG), (URI_SURV, SURV)]
    for uri, name in people:
        store.update(f'INSERT DATA {{ <{uri}> a pwg:Person ; pwg:displayName "{name}" . }}')
    # The identity link the resolver writes (pwg:mergedInto): FRAG is one identity with SURV.
    store.update(f'INSERT DATA {{ <{URI_FRAG}> pwg:mergedInto <{URI_SURV}> . }}')
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
    return len(w.server._sparql_select(f"SELECT ?s WHERE {{ ?s a <{PWG_TYPE}> . }}"))


def _no_audit(w):
    return not (w.tmp / "queue" / "forget_audit.log").exists()


ALL_NAMES = sorted([ACCENT, PLAIN, JOHN, SAME_A, SAME_B, FRAG, SURV])


# ── two UNLINKED nodes with an IDENTICAL name are two people ─────────────────

def test_identical_name_unlinked_forget_by_slug_is_409_and_both_survive(world):
    body, status = world.server.api_people_forget(SLUG_PAT)
    assert status == 409, (status, body)
    assert body["error"] == "more than one person matches"
    assert body["forgotten"] is False
    assert {URI_SAME_A, URI_SAME_B} <= set(_uris(world))
    assert world.store.person_names().count(SAME_A) == 2, "both nodes must survive"
    assert _no_audit(world)
    assert not (world.tmp / "forgotten.json").exists()


def test_identical_name_unlinked_forget_by_uri_removes_only_that_one(world):
    body, status = world.server.api_people_forget(SLUG_PAT, person_uri=URI_SAME_A)
    assert status == 200 and body["forgotten"] is True, (status, body)
    uris = _uris(world)
    assert URI_SAME_A not in uris and URI_SAME_B in uris


def test_identical_name_unlinked_enrichment_and_timeline_are_409(world):
    body, status = world.server.person_enrichment(SLUG_PAT)
    assert status == 409 and body["match_count"] == 2, (status, body)
    body, status = world.server.person_timeline(SLUG_PAT)
    assert status == 409 and body["match_count"] == 2, (status, body)


def test_identical_name_unlinked_suppression_is_409_and_writes_nothing(world):
    body, status = world.server.api_people_suppress_suggestions(
        SLUG_PAT, {"suppressed": True, "reason": "deceased"})
    assert status == 409, (status, body)
    assert _suppression_triples(world) == 0


# ── nodes the resolver has LINKED are one identity ──────────────────────────

def test_linked_pair_forget_by_slug_erases_every_linked_node(world):
    body, status = world.server.api_people_forget(SLUG_SAM)
    assert status == 200, (status, body)
    assert body["forgotten"] is True
    assert URI_FRAG not in _uris(world) and URI_SURV not in _uris(world)
    assert "Sam Brown" not in world.store.person_names()


def test_linked_pair_forget_by_uri_removes_only_that_node(world):
    body, status = world.server.api_people_forget(SLUG_SAM, person_uri=URI_FRAG)
    assert status == 200 and body["forgotten"] is True, (status, body)
    assert URI_FRAG not in _uris(world)
    assert URI_SURV in _uris(world), "URI-keyed forget must not take the linked survivor"


def test_linked_pair_enrichment_resolves_to_one_person(world):
    body, status = world.server.person_enrichment(SLUG_SAM)
    assert status == 200, (status, body)


# ── forget by slug with two DIFFERENT spellings: unchanged ───────────────────

def test_different_spellings_forget_by_slug_is_409_and_nobody_erased(world):
    body, status = world.server.api_people_forget(SLUG_JANE)
    assert status == 409, (status, body)
    assert _names(world) == ALL_NAMES


def test_different_spellings_forget_by_uri_removes_only_that_one(world):
    body, status = world.server.api_people_forget(SLUG_JANE, person_uri=URI_ACCENT)
    assert status == 200 and body["forgotten"] is True, (status, body)
    assert ACCENT not in world.store.person_names() and PLAIN in world.store.person_names()


def test_unknown_uri_is_404_and_writes_nothing(world):
    unknown = "https://schema.ostler.ai/ontology#person_syn0000ffff"
    body, status = world.server.api_people_forget(SLUG_PAT, person_uri=unknown)
    assert status == 404, (status, body)
    assert _names(world) == ALL_NAMES
    assert _no_audit(world)


def test_non_string_uri_is_400(world):
    body, status = world.server.api_people_forget(SLUG_PAT, person_uri=12345)
    assert status == 400
    assert _names(world) == ALL_NAMES


# ── control: a single match is unchanged ────────────────────────────────────

def test_control_single_match_forgets_as_before(world):
    body, status = world.server.api_people_forget(SLUG_JOHN)
    assert status == 200 and body["forgotten"] is True, (status, body)
    assert JOHN not in world.store.person_names()


def test_suppression_control_single_match_writes_one_record(world):
    body, status = world.server.api_people_suppress_suggestions(
        SLUG_JOHN, {"suppressed": True, "reason": "user_request"})
    assert status == 200, (status, body)
    assert _suppression_triples(world) == 1


# ── the mutant: without the identity guard the wrong person is erased ───────

def test_mutant_without_identity_guard_erases_one_of_an_identical_pair(world, monkeypatch):
    """Proves the harness sees the defect: resolve by first match (no identity
    count), and the identical-name forget erases ONE of the two people."""
    srv = world.server

    def first_hit_only(slug):
        hits = [r for r in srv._merge_aware_name_rows()
                if srv._wiki_slug(r.get("name", "")) == slug]
        best = srv._rank_name_rows(hits)[0]
        return best["person"], best.get("name", "")

    monkeypatch.setattr(srv, "_resolve_person_by_slug", first_hit_only)
    body, status = srv.api_people_forget(SLUG_PAT)
    assert status == 200, "mutant should forget without refusing"
    remaining = _uris(world)
    erased = [u for u in (URI_SAME_A, URI_SAME_B) if u not in remaining]
    assert len(erased) == 1, f"mutant must erase exactly one of the pair, erased {len(erased)}"


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


def test_route_identical_name_without_uri_is_409_over_http(world, live):
    status, body = _post(live, f"/api/v1/people/{SLUG_PAT}/forget")
    assert status == 409, (status, body)
    assert {URI_SAME_A, URI_SAME_B} <= set(_uris(world))


def test_route_person_uri_in_body_forgets_exactly_that_person(world, live):
    status, body = _post(live, f"/api/v1/people/{SLUG_PAT}/forget", {"person_uri": URI_SAME_B})
    assert status == 200 and body["forgotten"] is True, (status, body)
    uris = _uris(world)
    assert URI_SAME_B not in uris and URI_SAME_A in uris


def test_route_empty_body_still_works_for_single_match(world, live):
    status, body = _post(live, f"/api/v1/people/{SLUG_JOHN}/forget")
    assert status == 200 and body["forgotten"] is True


def test_route_non_object_body_is_400(world, live):
    status, body = _post(live, f"/api/v1/people/{SLUG_JOHN}/forget", raw=b"[1,2]")
    assert status == 400
    assert JOHN in world.store.person_names()
