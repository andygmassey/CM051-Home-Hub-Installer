"""By-URI person timeline: two people who fold to one wiki slug.

Synthetic fixture only: two people named alike, so they share the slug
``pat-example``. The by-URI route must return the exact person the caller named, with that
person's own meetings, and must never run slug resolution.

Red on origin/main: the route and function do not exist there.
"""
from __future__ import annotations

import importlib.util
import json
import os
import socket
import sys
import threading
import types
import typing
import unittest
import urllib.request
from urllib.parse import quote
from http.server import HTTPServer
from pathlib import Path
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
SERVER_FILE = HERE.parent / "ical-server.py"

PERSON_A = "https://schema.ostler.ai/ontology#person_aaaaaaaaaaaa"
PERSON_B = "https://schema.ostler.ai/ontology#person_bbbbbbbbbbbb"
NAME_A = "Pat Example"
NAME_B = "pat example"  # folds to the same wiki slug as NAME_A


def _install_ostler_security_stub() -> None:
    """Stub ostler_security so the vendored ical-server.py imports without
    the full HR015 dependency. The vendor ical-server also imports
    ostler_security.db_key.resolve_db_key, so that module is stubbed too."""
    if "ostler_security" in sys.modules:
        return
    pkg = types.ModuleType("ostler_security")
    pkg.__path__ = []
    sys.modules["ostler_security"] = pkg

    db_mod = types.ModuleType("ostler_security.database")

    def _stub_get_db_connection(*args, **kwargs):
        raise RuntimeError("stub: tests must not touch the DB")

    db_mod.get_db_connection = _stub_get_db_connection
    sys.modules["ostler_security.database"] = db_mod

    posture_mod = types.ModuleType("ostler_security.posture")
    posture_mod.record_posture = lambda *args, **kwargs: None
    sys.modules["ostler_security.posture"] = posture_mod

    db_key_mod = types.ModuleType("ostler_security.db_key")
    db_key_mod.SOURCE_ENV = "OSTLER_DB_KEY"
    db_key_mod.SOURCE_KEY_FILE = "OSTLER_DB_KEY_FILE"
    db_key_mod.REASON_NO_KEY = "no_key"

    class _DbKey(typing.NamedTuple):
        key: typing.Optional[str]
        source: typing.Optional[str]
        reason: typing.Optional[str]
        detail: typing.Optional[str]

    db_key_mod.DbKey = _DbKey
    db_key_mod.resolve_db_key = lambda: _DbKey(None, None, "no_key", None)
    sys.modules["ostler_security.db_key"] = db_key_mod


_install_ostler_security_stub()


def _load_server_module():
    spec = importlib.util.spec_from_file_location("ical_server", SERVER_FILE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


server = _load_server_module()


class _Store:
    """Fake Oxigraph: answers the queries the timeline path issues."""

    def __init__(self) -> None:
        self.queries: list[str] = []

    def __call__(self, query: str, *a, **k):
        self.queries.append(query)
        if "SELECT ?person ?name" in query:
            # Slug-resolution candidate scan: both people, one slug.
            return [{"person": PERSON_A, "name": NAME_A},
                    {"person": PERSON_B, "name": NAME_B}]
        if "SELECT ?name WHERE" in query:
            for uri, name in ((PERSON_A, NAME_A), (PERSON_B, NAME_B)):
                if f"<{uri}>" in query:
                    return [{"name": name}]
            return []
        if "pwg:Meeting" in query and f"<{PERSON_B}>" in query:
            return [{"m": "urn:ostler:meeting:b1", "summary": "Budget review B",
                     "date": "2026-10-02T09:00:00Z", "location": "", "mpriv": "L1"}]
        if "pwg:Meeting" in query and f"<{PERSON_A}>" in query:
            return [{"m": "urn:ostler:meeting:a1", "summary": "Kickoff A",
                     "date": "2026-09-01T09:00:00Z", "location": "", "mpriv": "L1"}]
        return []


class PersonTimelineByUri(unittest.TestCase):
    def setUp(self) -> None:
        self.store = _Store()
        patcher = patch.object(server, "_sparql_select", side_effect=self.store)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_by_uri_returns_the_named_person_not_the_slug_winner(self):
        body, status = server.person_timeline_by_uri(PERSON_B)
        self.assertEqual(status, 200, body)
        self.assertEqual(body["person"]["person_uri"], PERSON_B)
        summaries = [e.get("summary") for e in body["events"]]
        self.assertIn("Budget review B", summaries)
        self.assertNotIn("Kickoff A", summaries)

    def test_by_uri_never_runs_slug_resolution(self):
        server.person_timeline_by_uri(PERSON_B)
        self.assertFalse(
            any("SELECT ?person ?name" in q for q in self.store.queries),
            "by-URI route must not scan candidates for a slug",
        )

    def test_malformed_uri_is_refused_before_any_query(self):
        body, status = server.person_timeline_by_uri("x> } DROP ALL ;")
        self.assertEqual(status, 400)
        self.assertEqual(self.store.queries, [])

    def test_unknown_uri_is_404(self):
        body, status = server.person_timeline_by_uri(
            "https://schema.ostler.ai/ontology#person_cccccccccccc")
        self.assertEqual(status, 404)

    def test_http_route_serves_the_by_uri_timeline(self):
        httpd = HTTPServer(("127.0.0.1", 0), server.Handler)
        t = threading.Thread(target=httpd.serve_forever, daemon=True)
        t.start()
        self.addCleanup(httpd.shutdown)
        port = httpd.server_address[1]
        # '#' must be percent-encoded or it starts a fragment and truncates the URI.
        url = f"http://127.0.0.1:{port}/api/v1/people/timeline?uri={quote(PERSON_B, safe='')}"
        # Person data needs the service token (the guard fails closed
        # without it). Bypass any local proxy: it answers for every host.
        os.environ["OSTLER_SERVICE_TOKEN"] = "test-token"
        token = server._expected_service_token()
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(req, timeout=5) as resp:
            self.assertEqual(resp.status, 200)
            data = json.loads(resp.read().decode())
        self.assertEqual(data["person"]["person_uri"], PERSON_B)


if __name__ == "__main__":
    unittest.main()
