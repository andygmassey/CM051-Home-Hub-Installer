"""Follow-Up Detector (Lane 8): /api/v1/commitments extension.

The Hub's commitments wing only knew todos pulled from meetings. The
assistant's message detector now writes promises it finds in iMessage,
WhatsApp and email into the SAME wing. This pins:

  * the read side keeps its old shape and gains id/person/channel/origin/
    confidence, additively;
  * low-confidence detector rows are hidden by default (and counted), and a
    meeting todo with no confidence is never hidden;
  * POST /api/v1/commitments/detected validates everything before writing,
    upserts by id, never resurrects a dismissed item, and never touches a
    node it did not mint;
  * POST /api/v1/commitments/<id>/status changes only detector nodes.

Synthetic people only (Jane Doe, John Smith); no real data, no network.
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
    spec = importlib.util.spec_from_file_location("ical_server_commitments_vendored", SERVER_FILE)
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


ID_A = "a" * 16
ID_B = "b" * 16
ID_C = "c" * 16
PREFIX = "urn:ostler:todo/detected/"


def _item(**over):
    base = {
        "id": ID_A,
        "what": "send Jane Doe the deck",
        "owner": "user",
        "person": "Jane Doe",
        "channel": "imessage",
        "promised_at": "2026-10-01T09:30:00Z",
        "due": "2026-10-02",
        "confidence": 0.9,
        "source_ref": "im:1234",
    }
    base.update(over)
    return base


def _is_commitments_query(q: str) -> bool:
    return "urn:ostler:OutstandingTodo" in q


class TestReadSideIsAdditive(unittest.TestCase):
    ROWS = [
        # A CM048 meeting todo: no person/channel/confidence/origin at all.
        {"todo": "urn:ostler:todo/1", "action": "Review the proposal",
         "owner": "other", "deadline": "2026-10-05", "status": "open",
         "source": "2026-09-30", "createdAt": "2026-09-30T09:00:00"},
        # A confident detector row.
        {"todo": PREFIX + ID_A, "action": "send Jane Doe the deck",
         "owner": "user", "deadline": "2026-10-02", "status": "open",
         "source": "2026-10-01T09:30:00Z", "createdAt": "2026-10-01T09:31:00Z",
         "person": "Jane Doe", "channel": "imessage", "confidence": "0.9000",
         "origin": "message_detector"},
        # A low-confidence detector row.
        {"todo": PREFIX + ID_B, "action": "maybe reply to John Smith",
         "owner": "user", "deadline": "", "status": "open",
         "source": "2026-10-01T10:00:00Z", "createdAt": "2026-10-01T10:01:00Z",
         "person": "John Smith", "channel": "email", "confidence": "0.3000",
         "origin": "message_detector"},
    ]

    def _get(self, qs=""):
        with patch.object(server, "_sparql_select",
                          side_effect=lambda q: self.ROWS if _is_commitments_query(q) else []):
            with _ServerHarness() as h:
                return h.get("/api/v1/commitments" + qs)

    def test_meeting_todo_keeps_its_old_fields_and_is_never_hidden(self):
        status, body = self._get()
        self.assertEqual(status, 200)
        meeting = [c for c in body["commitments"] if c["action"] == "Review the proposal"][0]
        for key in ("action", "owner", "due", "status", "source"):
            self.assertIn(key, meeting)
        self.assertIsNone(meeting["confidence"])
        self.assertEqual(meeting["person"], "")
        self.assertEqual(meeting["origin"], "")

    def test_low_confidence_hidden_by_default_and_counted(self):
        status, body = self._get()
        actions = [c["action"] for c in body["commitments"]]
        self.assertNotIn("maybe reply to John Smith", actions)
        self.assertIn("send Jane Doe the deck", actions)
        self.assertEqual(body["hidden_low_confidence"], 1)
        self.assertEqual(body["count"], 2)

    def test_min_confidence_zero_shows_everything(self):
        status, body = self._get("?min_confidence=0")
        self.assertEqual(body["count"], 3)
        self.assertEqual(body["hidden_low_confidence"], 0)

    def test_detector_row_carries_new_fields(self):
        status, body = self._get()
        row = [c for c in body["commitments"] if c["id"] == PREFIX + ID_A][0]
        self.assertEqual(row["person"], "Jane Doe")
        self.assertEqual(row["channel"], "imessage")
        self.assertEqual(row["origin"], "message_detector")
        self.assertAlmostEqual(row["confidence"], 0.9)

    def test_bad_min_confidence_is_400(self):
        status, body = self._get("?min_confidence=banana")
        self.assertEqual(status, 400)


class TestDetectedWrite(unittest.TestCase):
    def _post(self, payload, existing=None, update=None):
        existing = existing or []
        updates = [] if update is None else update

        def fake_select(q):
            return existing if "VALUES ?todo" in q else []

        with patch.object(server, "_sparql_select", side_effect=fake_select), \
                patch.object(server, "_sparql_update", side_effect=updates.append):
            with _ServerHarness() as h:
                return h.post("/api/v1/commitments/detected", payload), updates

    def test_writes_same_node_type_and_predicates_as_meeting_todos(self):
        (status, body), updates = self._post({"items": [_item()]})
        self.assertEqual(status, 200)
        self.assertEqual(body, {"written": 1, "skipped_dismissed": 0})
        sparql = updates[0]
        for needle in (
            "a <urn:ostler:OutstandingTodo>", "<urn:ostler:todoText>",
            "<urn:ostler:owner> \"user\"", "<urn:ostler:status> \"open\"",
            "<urn:ostler:deadline> \"2026-10-02\"",
            "<urn:ostler:person> \"Jane Doe\"", "<urn:ostler:channel> \"imessage\"",
            "<urn:ostler:confidence> \"0.9000\"",
            "<urn:ostler:origin> \"message_detector\"",
            "<urn:ostler:privacyLevel> \"L2\"",
        ):
            self.assertIn(needle, sparql)
        self.assertIn(f"<{PREFIX}{ID_A}>", sparql)
        # Upsert: the old triples go first, in the same request.
        self.assertTrue(sparql.startswith(f"DELETE WHERE {{ <{PREFIX}{ID_A}>"))
        # One prologue-free request (a repeated PREFIX after ';' is a parse error).
        self.assertNotIn("PREFIX", sparql)

    def test_no_message_text_beyond_what_is_stored(self):
        (status, _), updates = self._post({"items": [_item()]})
        self.assertNotIn("body", updates[0].lower().replace("somebody", ""))

    def test_dismissed_item_is_not_resurrected(self):
        existing = [{"todo": PREFIX + ID_A, "status": "dismissed"}]
        (status, body), updates = self._post(
            {"items": [_item(), _item(id=ID_B, what="call John Smith back")]},
            existing=existing,
        )
        self.assertEqual(status, 200)
        self.assertEqual(body, {"written": 1, "skipped_dismissed": 1})
        joined = "\n".join(updates)
        self.assertNotIn(PREFIX + ID_A, joined)
        self.assertIn(PREFIX + ID_B, joined)

    def test_one_bad_item_rejects_the_whole_batch_and_writes_nothing(self):
        (status, body), updates = self._post(
            {"items": [_item(), _item(id=ID_B, owner="nobody")]}
        )
        self.assertEqual(status, 400)
        self.assertIn("items[1]", body["error"])
        self.assertEqual(updates, [])

    def test_validation_rejects_bad_shapes(self):
        bad = [
            _item(id="not-hex"),
            _item(what=""),
            _item(what="x" * 281),
            _item(what="line\x00break"),
            _item(channel="telegram"),
            _item(confidence=1.5),
            _item(confidence="high"),
            _item(confidence=True),
            _item(promised_at="yesterday"),
            _item(due="soon"),
            _item(status="maybe"),
            _item(source_ref="has space"),
        ]
        for item in bad:
            with self.subTest(item=item):
                (status, _), updates = self._post({"items": [item]})
                self.assertEqual(status, 400)
                self.assertEqual(updates, [])

    def test_sparql_injection_in_text_is_escaped(self):
        evil = 'x" . } ; DROP ALL ; INSERT DATA { <a> <b> "c'
        (status, _), updates = self._post({"items": [_item(what=evil)]})
        self.assertEqual(status, 200)
        # The quote is escaped, so the payload stays inside one literal.
        self.assertIn('\\" . } ; DROP ALL', updates[0])
        self.assertNotIn('x" . }', updates[0])

    def test_caps_and_body_shape(self):
        (status, _), _u = self._post({"items": [_item(id=("%016x" % i)) for i in range(101)]})
        self.assertEqual(status, 400)
        (status, _), _u = self._post([1, 2])
        self.assertEqual(status, 400)
        (status, body), updates = self._post({"items": []})
        self.assertEqual((status, body["written"]), (200, 0))
        self.assertEqual(updates, [])

    def test_oxigraph_failure_degrades_without_5xx_crash(self):
        def boom(_q):
            raise RuntimeError("down")
        with patch.object(server, "_sparql_select", side_effect=boom):
            with _ServerHarness() as h:
                status, body = h.post("/api/v1/commitments/detected", {"items": [_item()]})
        self.assertEqual(status, 503)
        self.assertTrue(body["degraded"])


class TestStatusRoute(unittest.TestCase):
    def _post(self, todo_id, payload, found=True):
        updates = []
        with patch.object(server, "_sparql_select",
                          side_effect=lambda q: [{"status": "open"}] if found else []), \
                patch.object(server, "_sparql_update", side_effect=updates.append):
            with _ServerHarness() as h:
                return h.post(f"/api/v1/commitments/{todo_id}/status", payload), updates

    def test_sets_status_on_detector_node_only(self):
        (status, body), updates = self._post(ID_A, {"status": "done"})
        self.assertEqual(status, 200)
        self.assertEqual(body, {"id": ID_A, "status": "done"})
        self.assertIn(f"<{PREFIX}{ID_A}>", updates[0])
        self.assertIn('"done"', updates[0])

    def test_non_hex_id_cannot_reach_a_meeting_todo(self):
        # A CM048 todo is addressed by its full IRI; that must not parse here.
        (status, _), updates = self._post("urn:ostler:todo/1", {"status": "done"})
        self.assertEqual(status, 400)
        self.assertEqual(updates, [])

    def test_unknown_status_and_missing_node(self):
        (status, _), updates = self._post(ID_A, {"status": "obliterated"})
        self.assertEqual(status, 400)
        (status, _), updates = self._post(ID_C, {"status": "done"}, found=False)
        self.assertEqual(status, 404)
        self.assertEqual(updates, [])

    def test_dismiss_then_stays_dismissed_end_to_end(self):
        (status, _), updates = self._post(ID_A, {"status": "dismissed"})
        self.assertEqual(status, 200)
        self.assertIn('"dismissed"', updates[0])


class TestNewQueriesSurviveTheVendoredGraphScoper(unittest.TestCase):
    """CM051 reaches CM048's named graph through ``_graph_scoped`` (a rewriter
    on every SELECT), NOT through CM041's per-reader ``read_across_graphs``.
    Every SELECT these routes add must come out of it unions-in-scope; a query
    the rewriter cannot locate a WHERE group in is returned UNCHANGED and would
    silently read the default graph only. Executed against the real rewriter
    with a fixed graph list rather than assumed."""

    GRAPHS = ["urn:ostler:user/primary"]

    def _scoped(self, q):
        return server._graph_scoped_select(q, self.GRAPHS)

    def _seen_queries(self, fn):
        seen = []
        def fake(q):
            seen.append(q)
            return []
        with patch.object(server, "_sparql_select", side_effect=fake):
            fn()
        return seen

    def test_commitments_select_is_rewritten_to_span_the_named_graph(self):
        qs = self._seen_queries(lambda: server.commitments_list())
        self.assertTrue(qs)
        out = self._scoped(qs[0])
        self.assertNotEqual(out, qs[0])
        self.assertIn("GRAPH ?", out)
        self.assertIn("urn:ostler:person", out)  # the new OPTIONAL survives inside both arms
        self.assertEqual(out.count("<urn:ostler:confidence> ?confidence"), 2)

    def test_status_lookup_and_resolve_selects_are_rewritten(self):
        qs = self._seen_queries(lambda: server.api_commitments_detected({"items": [{
            "id": "a" * 16, "what": "send the deck", "owner": "user", "channel": "imessage",
            "promised_at": "2026-10-01", "confidence": 0.9}]}))
        lookup = [q for q in qs if "VALUES ?todo" in q][0]
        self.assertNotEqual(self._scoped(lookup), lookup)
        qs = self._seen_queries(lambda: server.people_resolve(["+447700900001", "jane@example.com"]))
        self.assertEqual(len(qs), 2)
        for q in qs:
            out = self._scoped(q)
            self.assertNotEqual(out, q)
            self.assertEqual(out.count("pwg:identifierValue ?value"), 2)


if __name__ == "__main__":
    unittest.main()
