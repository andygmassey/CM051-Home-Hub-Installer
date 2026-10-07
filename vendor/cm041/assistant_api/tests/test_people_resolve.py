"""Lane 8: GET /api/v1/people/resolve (handle -> display name).

The assistant reads iMessage and email by handle. Nothing on the Hub resolved a
handle to a person, so a promise or a reconnect nudge could only name a phone
number. This pins the smallest read that fixes that, on the identifier nodes
the owner-exclusion arm already reads. Synthetic people and reserved example
numbers only; no real data, no network.
"""
from __future__ import annotations

import importlib.util
import json
import socket
import sys
import threading
import time
import types
import typing
import unittest
import urllib.error
import urllib.request
from http.server import HTTPServer
from pathlib import Path
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
SERVER_FILE = HERE.parent / "ical-server.py"


def _install_ostler_security_stub() -> None:
    """Ported from the sibling test_people_list_endpoint.py's stub: this
    vendor tree's ical-server.py also hard-imports ostler_security.db_key,
    not just .database/.posture."""
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
    spec = importlib.util.spec_from_file_location("ical_server_resolve_vendored", SERVER_FILE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


server = _load_server_module()


def _free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class _ServerHarness:
    _OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def __init__(self) -> None:
        self.port = _free_port()
        self.httpd = HTTPServer(("127.0.0.1", self.port), server.Handler)
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        # The route logic is under test, not the service-token gate (which has
        # its own suite, test_service_auth). Same effect CM041's conftest gets
        # by injecting a real token; this tree has no such conftest.
        self._guard = patch.object(server.Handler, "_guard", lambda self, method, path: True)

    def __enter__(self) -> "_ServerHarness":
        self._guard.start()
        self.thread.start()
        for _ in range(50):
            try:
                with socket.create_connection(("127.0.0.1", self.port), 0.1):
                    break
            except OSError:
                time.sleep(0.02)
        return self

    def __exit__(self, *exc) -> None:
        self._guard.stop()
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join(timeout=2)

    def _do(self, req) -> tuple:
        try:
            with self._OPENER.open(req, timeout=5) as resp:
                return resp.status, json.loads(resp.read())
        except urllib.error.HTTPError as exc:
            raw = exc.read()
            try:
                return exc.code, json.loads(raw)
            except json.JSONDecodeError:
                return exc.code, {"_raw": raw.decode("utf-8", "replace")}

    def get(self, path: str) -> tuple:
        return self._do(urllib.request.Request(f"http://127.0.0.1:{self.port}{path}"))

    def post(self, path: str, payload) -> tuple:
        req = urllib.request.Request(
            f"http://127.0.0.1:{self.port}{path}",
            data=json.dumps(payload).encode(),
            method="POST",
            headers={"Content-Type": "application/json"},
        )
        return self._do(req)



P1 = "https://schema.ostler.ai/ontology#person_jane"
P2 = "https://schema.ostler.ai/ontology#person_tom"
P3 = "https://schema.ostler.ai/ontology#person_raw"


def _fake(phone_rows=(), email_rows=()):
    def fake(q):
        if 'identifierType "phone"' in q:
            return list(phone_rows)
        if 'identifierType "email"' in q:
            return list(email_rows)
        return []
    return fake


def _get(qs, fake):
    with patch.object(server, "_sparql_select", side_effect=fake):
        with _ServerHarness() as h:
            return h.get("/api/v1/people/resolve" + qs)


class TestPeopleResolve(unittest.TestCase):
    def test_resolves_phone_and_email_to_names(self):
        fake = _fake(
            phone_rows=[{"p": P1, "n": "Jane Doe", "value": "+44 7700 900001"}],
            email_rows=[{"p": P2, "n": "Tom Reid", "value": "Tom.Reid@Example.com"}],
        )
        status, body = _get("?handle=%2B447700900001&handle=tom.reid%40example.com", fake)
        self.assertEqual(status, 200)
        self.assertEqual(body["count"], 2)
        self.assertEqual(body["resolved"]["+447700900001"]["name"], "Jane Doe")
        self.assertEqual(body["resolved"]["+447700900001"]["slug"], "jane-doe")
        self.assertEqual(body["resolved"]["tom.reid@example.com"]["name"], "Tom Reid")

    def test_phone_match_tolerates_country_code_formatting(self):
        fake = _fake(phone_rows=[{"p": P1, "n": "Jane Doe", "value": "07700 900001"}])
        status, body = _get("?handle=%2B447700900001", fake)
        self.assertEqual(body["resolved"]["+447700900001"]["name"], "Jane Doe")

    def test_unknown_and_nameless_handles_are_omitted(self):
        fake = _fake(phone_rows=[
            {"p": P3, "n": "+44 7700 900003", "value": "+447700900003"},
            {"p": P1, "n": "Jane Doe", "value": "+447700900001"},
        ])
        status, body = _get("?handle=%2B447700900003&handle=%2B447700900099", fake)
        self.assertEqual(status, 200)
        self.assertEqual(body, {"resolved": {}, "count": 0})

    def test_short_codes_and_garbage_never_query_the_graph(self):
        calls = []
        def fake(q):
            calls.append(q)
            return []
        status, body = _get("?handle=86262&handle=AMZN", fake)
        self.assertEqual((status, body["count"]), (200, 0))
        self.assertEqual(calls, [])

    def test_requires_a_handle_and_caps_the_batch(self):
        status, _ = _get("", _fake())
        self.assertEqual(status, 400)
        many = "&".join(f"handle=%2B4477009{i:05d}" for i in range(51))
        status, _ = _get("?" + many, _fake())
        self.assertEqual(status, 400)
        status, _ = _get("?handle=" + "x" * 121, _fake())
        self.assertEqual(status, 400)

    def test_email_values_are_escaped_into_the_query(self):
        seen = []
        def fake(q):
            seen.append(q)
            return []
        _get("?handle=a%22b%40example.com", fake)
        self.assertTrue(any('a\\"b@example.com' in q for q in seen), seen)

    def test_oxigraph_failure_degrades(self):
        def boom(_q):
            raise RuntimeError("down")
        status, body = _get("?handle=%2B447700900001", boom)
        self.assertEqual(status, 503)
        self.assertTrue(body["degraded"])


if __name__ == "__main__":
    unittest.main()
