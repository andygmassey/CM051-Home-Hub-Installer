"""L3 withheld server-side on the people-graph readers an assistant model reads.

Endpoints under test (real HTTP, real ical-server handlers):

  - GET /api/v1/decisions            decisions_list
  - GET /api/v1/topics               topics_list
  - GET /api/v1/topics/<slug>/mentions  topic_mentions
  - GET /api/v1/commitments          commitments_list
  - GET /api/v1/preferences          api_preferences  (pwg_preferences, pwg_overview)

Doctrine (pwg_privacy.provenance_verdict): an item's level is the STRICTEST of
its provenance. Any L3 source hides it. Any source without a parseable level is
unknown provenance and is hidden AND counted in the response's ``withheld``.

Each endpoint has the same pair: an L3-sourced item must be ABSENT and an
L2-sourced item must be PRESENT. Against main the L3 items are served, so the
absent-assertions are red there. Synthetic placeholders only.
"""
from __future__ import annotations

import importlib.util
import json
import os
import socket
import sys
import tempfile
import threading
import time
import types
import unittest
import urllib.error
import urllib.request
from http.server import HTTPServer
from pathlib import Path
from unittest.mock import patch


HERE = Path(__file__).resolve().parent
SERVER_FILE = HERE.parent / "ical-server.py"


def _install_ostler_security_stub() -> None:
    try:
        import ostler_security  # noqa: F401
        return
    except Exception:
        pass
    import sqlite3 as _sqlite

    pkg = types.ModuleType("ostler_security")
    pkg.__path__ = []
    sys.modules["ostler_security"] = pkg
    database = types.ModuleType("ostler_security.database")
    database.get_db_connection = lambda path, _key, *a, **k: _sqlite.connect(path)
    sys.modules["ostler_security.database"] = database
    posture = types.ModuleType("ostler_security.posture")
    posture.record_posture = lambda *a, **k: None
    sys.modules["ostler_security.posture"] = posture


_install_ostler_security_stub()


def _load_server_module():
    spec = importlib.util.spec_from_file_location("ical_server_l3", SERVER_FILE)
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


_TEST_SERVICE_TOKEN = "synthetic-moat-test-token"
os.environ["OSTLER_SERVICE_TOKEN"] = _TEST_SERVICE_TOKEN


class _ServerHarness:
    def __init__(self) -> None:
        self.port = _free_port()
        self.httpd = HTTPServer(("127.0.0.1", self.port), server.Handler)
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)

    def __enter__(self) -> "_ServerHarness":
        self.thread.start()
        for _ in range(50):
            try:
                with socket.create_connection(("127.0.0.1", self.port), 0.1):
                    break
            except OSError:
                time.sleep(0.02)
        return self

    def __exit__(self, *exc) -> None:
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join(timeout=2)

    _OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def get(self, path: str, destination: str | None = None) -> tuple[int, dict]:
        # The server is token-gated (fail closed) and reads the destination from
        # the X-Ostler-Destination header only; a query string is ignored by design.
        url = f"http://127.0.0.1:{self.port}{path}"
        headers = {"Authorization": f"Bearer {_TEST_SERVICE_TOKEN}"}
        if destination is not None:
            headers["X-Ostler-Destination"] = destination
        req = urllib.request.Request(url, headers=headers)
        try:
            with self._OPENER.open(req, timeout=5) as resp:
                return resp.status, json.loads(resp.read())
        except urllib.error.HTTPError as exc:
            return exc.code, json.loads(exc.read() or b"{}")


def _boom(_query):
    raise OSError("oxigraph unreachable")


# ---------------------------------------------------------------------------
# Decisions
# ---------------------------------------------------------------------------

class TestDecisionsL3(unittest.TestCase):
    """Provenance = source meeting + every attendee. Keyed by decision URI."""

    DECISIONS = [
        {"d": "urn:ostler:decision/l2", "summary": "Ship the L2 plan",
         "date": "2026-06-10T00:00:00", "source": "urn:ostler:meeting/l2",
         "status": "active"},
        {"d": "urn:ostler:decision/l3", "summary": "Secret L3 plan",
         "date": "2026-06-11T00:00:00", "source": "urn:ostler:meeting/l3",
         "status": "active"},
        {"d": "urn:ostler:decision/unk", "summary": "Untagged meeting plan",
         "date": "2026-06-12T00:00:00", "source": "urn:ostler:meeting/unk",
         "status": "active"},
        {"d": "urn:ostler:decision/att", "summary": "L2 meeting, L3 attendee",
         "date": "2026-06-13T00:00:00", "source": "urn:ostler:meeting/l2",
         "status": "active"},
        {"d": "urn:ostler:decision/nosrc", "summary": "No source meeting",
         "date": "2026-06-14T00:00:00", "source": "",
         "status": "active"},
        {"d": "urn:ostler:decision/bad", "summary": "Unreadable meeting level",
         "date": "2026-06-15T00:00:00", "source": "urn:ostler:meeting/bad",
         "status": "active"},
    ]

    # Rows the provenance query returns, per decision: (m, mpriv, name, ppriv).
    PROVENANCE = {
        "urn:ostler:decision/l2": [
            {"m": "urn:ostler:meeting/l2", "mpriv": "L2",
             "p": "urn:ostler:person/a", "name": "Synthetic Person A", "ppriv": "L2"}],
        "urn:ostler:decision/l3": [
            {"m": "urn:ostler:meeting/l3", "mpriv": "L3",
             "p": "urn:ostler:person/a", "name": "Synthetic Person A", "ppriv": "L2"}],
        "urn:ostler:decision/unk": [
            {"m": "urn:ostler:meeting/unk", "mpriv": None,
             "p": "urn:ostler:person/a", "name": "Synthetic Person A", "ppriv": "L2"}],
        "urn:ostler:decision/att": [
            {"m": "urn:ostler:meeting/l2", "mpriv": "L2",
             "p": "urn:ostler:person/b", "name": "Synthetic Person B", "ppriv": "L3"}],
        "urn:ostler:decision/nosrc": [
            {"m": None, "mpriv": None, "p": "urn:ostler:person/a", "name": "Synthetic Person A",
             "ppriv": "L2"}],
        "urn:ostler:decision/bad": [
            {"m": "urn:ostler:meeting/bad", "mpriv": "bogus",
             "p": "urn:ostler:person/a", "name": "Synthetic Person A", "ppriv": "L2"}],
    }

    def _fake(self, provenance=None):
        provenance = self.PROVENANCE if provenance is None else provenance

        def fake(q):
            if "a pwg:Decision" in q and "decisionSummary" in q:
                return self.DECISIONS
            if "pwg:decisionSource" in q and "pwg:decisionAbout" in q:
                for uri in self.PROVENANCE:
                    if f"<{uri}>" in q:
                        return provenance.get(uri, [])
            return []
        return fake

    def test_l2_sourced_present_l3_sourced_absent(self) -> None:
        with patch.object(server, "_sparql_select", side_effect=self._fake()):
            with _ServerHarness() as h:
                status, body = h.get("/api/v1/decisions")
        self.assertEqual(status, 200)
        summaries = [d["summary"] for d in body["decisions"]]
        self.assertIn("Ship the L2 plan", summaries)          # L2 present
        self.assertNotIn("Secret L3 plan", summaries)         # L3 absent
        self.assertNotIn("L2 meeting, L3 attendee", summaries)  # L3 attendee hides
        self.assertNotIn("Unreadable meeting level", summaries)  # unreadable absent
        # Legacy: no readable level anywhere -> served and counted, not withheld.
        self.assertIn("Untagged meeting plan", summaries)
        self.assertIn("No source meeting", summaries)

    def test_withheld_is_counted_not_silent(self) -> None:
        with patch.object(server, "_sparql_select", side_effect=self._fake()):
            with _ServerHarness() as h:
                _, body = h.get("/api/v1/decisions")
        self.assertEqual(body["withheld"], {"l3": 2, "unknown": 1})
        # The meeting-less and unlevelled decisions carry a readable L2
        # attendee, so they are ok, not legacy: legacy stays 0 here.
        self.assertEqual(body["legacy_untagged"], 0)
        self.assertEqual(body["count"], 3)

    def test_failed_provenance_query_fails_closed(self) -> None:
        def fake(q):
            if "a pwg:Decision" in q and "decisionSummary" in q:
                return [self.DECISIONS[0]]
            raise OSError("provenance lookup failed")
        with patch.object(server, "_sparql_select", side_effect=fake):
            with _ServerHarness() as h:
                _, body = h.get("/api/v1/decisions")
        self.assertEqual(body["decisions"], [])
        self.assertEqual(body["withheld"]["unknown"], 1)


# ---------------------------------------------------------------------------
# Topics (list and per-topic mentions)
# ---------------------------------------------------------------------------

def _is_topics_list(q: str) -> bool:
    return "?topic a pwg:ConversationTopic .\n" in q


def _is_topic_mentions(q: str) -> bool:
    return 'pwg:topicSlug "' in q


class TestTopicsL3(unittest.TestCase):
    # One row per mention: topic, slug, label, mention, weight, mention level,
    # conversation, conversation level.
    MENTIONS = [
        {"topic": "pwg:topic_apple-mail", "slug": "apple-mail", "label": "Apple Mail",
         "m": "pwg:tm_1", "w": "3", "mpriv": "L2", "conv": "pwg:batch_1", "cpriv": "L2"},
        {"topic": "pwg:topic_launch", "slug": "launch", "label": "Launch planning",
         "m": "pwg:tm_2", "w": "4", "mpriv": "L2", "conv": "pwg:batch_2", "cpriv": "L2"},
        {"topic": "pwg:topic_launch", "slug": "launch", "label": "Launch planning",
         "m": "pwg:tm_3", "w": "9", "mpriv": "L2", "conv": "pwg:batch_3", "cpriv": "L3"},
        {"topic": "pwg:topic_secret", "slug": "secret-deal", "label": "Secret deal",
         "m": "pwg:tm_4", "w": "7", "mpriv": "L3", "conv": "pwg:batch_4", "cpriv": "L2"},
        {"topic": "pwg:topic_unk", "slug": "untagged-topic", "label": "Untagged topic",
         "m": "pwg:tm_5", "w": "2", "mpriv": "L2", "conv": "pwg:batch_5", "cpriv": None},
    ]

    def _fake_list(self):
        def fake(q):
            return self.MENTIONS if _is_topics_list(q) else []
        return fake

    def test_list_l2_present_l3_topic_and_mention_absent(self) -> None:
        with patch.object(server, "_sparql_select", side_effect=self._fake_list()):
            with _ServerHarness() as h:
                status, body = h.get("/api/v1/topics")
        self.assertEqual(status, 200)
        slugs = [t["slug"] for t in body["topics"]]
        self.assertIn("apple-mail", slugs)                 # L2 present
        self.assertNotIn("secret-deal", slugs)             # L3 mention only: absent
        self.assertIn("untagged-topic", slugs)             # own L2, conv level absent: served
        self.assertNotIn("Secret deal", json.dumps(body))  # its label not disclosed

    def test_list_weight_excludes_withheld_mentions(self) -> None:
        with patch.object(server, "_sparql_select", side_effect=self._fake_list()):
            with _ServerHarness() as h:
                _, body = h.get("/api/v1/topics")
        launch = next(t for t in body["topics"] if t["slug"] == "launch")
        # The L3-conversation mention (weight 9) must not inflate the count.
        self.assertEqual(launch["weight"], 4)
        self.assertEqual(launch["mentions"], 1)
        self.assertEqual(body["withheld"], {"l3": 2, "unknown": 0})

    def test_mentions_l2_present_l3_absent(self) -> None:
        rows = [
            {"label": "Launch planning", "conversation": "pwg:batch_2", "weight": "4",
             "channel": "pwg:channel_imessage", "sender": "Synthetic Person A",
             "date": "2026-05-01", "mpriv": "L2", "cpriv": "L2"},
            {"label": "Launch planning", "conversation": "pwg:batch_3", "weight": "9",
             "channel": "pwg:channel_imessage", "sender": "Synthetic Person B",
             "date": "2026-06-10", "mpriv": "L2", "cpriv": "L3"},
        ]

        def fake(q):
            return rows if _is_topic_mentions(q) else []

        with patch.object(server, "_sparql_select", side_effect=fake):
            with _ServerHarness() as h:
                status, body = h.get("/api/v1/topics/launch/mentions")
        self.assertEqual(status, 200)
        convs = [m["conversation"] for m in body["mentions"]]
        self.assertEqual(convs, ["pwg:batch_2"])           # L2 present, L3 absent
        self.assertEqual(body["withheld"], {"l3": 1, "unknown": 0})


# ---------------------------------------------------------------------------
# Commitments
# ---------------------------------------------------------------------------

class TestCommitmentsL3(unittest.TestCase):
    ROWS = [
        {"todo": "urn:ostler:todo/l2", "action": "Send the L2 deck", "owner": "user",
         "deadline": "2026-06-20", "status": "open", "source": "2026-06-10",
         "createdAt": "2026-06-10T09:00:00", "plevel": "L2"},
        {"todo": "urn:ostler:todo/l3", "action": "Confidential L3 action", "owner": "user",
         "deadline": "2026-06-21", "status": "open", "source": "2026-06-10",
         "createdAt": "2026-06-10T09:00:00", "plevel": "L3"},
        {"todo": "urn:ostler:todo/unk", "action": "Untagged action", "owner": "user",
         "deadline": "2026-06-22", "status": "open", "source": "2026-06-10",
         "createdAt": "2026-06-10T09:00:00"},
    ]

    def _fake(self):
        def fake(q):
            return self.ROWS if "urn:ostler:OutstandingTodo" in q else []
        return fake

    def test_l2_present_l3_and_untagged_absent_and_counted(self) -> None:
        with patch.object(server, "_sparql_select", side_effect=self._fake()):
            with _ServerHarness() as h:
                status, body = h.get("/api/v1/commitments", destination="owner_own_brief")
        self.assertEqual(status, 200)
        actions = [c["action"] for c in body["commitments"]]
        # owner_own_brief: L2 served; L3 withheld (counted l3); untagged is
        # canonical L3 now (counted unknown, not served).
        self.assertEqual(actions, ["Send the L2 deck"])
        self.assertNotIn("Confidential L3 action", json.dumps(body))
        self.assertNotIn("Untagged action", json.dumps(body))
        self.assertEqual(body["withheld"], {"l3": 1, "unknown": 1})
        self.assertEqual(body["legacy_untagged"], 0)


# ---------------------------------------------------------------------------
# Preferences (pwg_preferences tool and the pwg_overview counts)
# ---------------------------------------------------------------------------

class TestPreferencesL3(unittest.TestCase):
    def _artefact(self, tmp: Path) -> Path:
        art = {
            "schema_version": "0.1",
            "generated_at": "2026-06-20T00:00:00+00:00",
            "interests": [
                {"id": "int_l2", "subject": "subject-l2", "domain": "Music",
                 "polarity": "like", "score": 0.9, "confidence": 0.8,
                 "privacy_level": "L2", "sources": ["you"], "evidence": ["x"]},
                {"id": "int_l3", "subject": "subject-l3", "domain": "Health",
                 "polarity": "like", "score": 0.95, "confidence": 0.8,
                 "privacy_level": "L3", "sources": ["you"], "evidence": ["x"]},
                {"id": "int_unk", "subject": "subject-untagged", "domain": "Film",
                 "polarity": "like", "score": 0.85, "confidence": 0.8,
                 "sources": ["you"], "evidence": ["x"]},
            ],
        }
        path = tmp / "interest_profile.json"
        path.write_text(json.dumps(art), encoding="utf-8")
        return path

    def test_l2_present_l3_and_untagged_absent_and_counted(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            art = self._artefact(Path(d))
            with patch.object(server, "INTEREST_PROFILE_PATH", str(art)):
                with _ServerHarness() as h:
                    status, body = h.get("/api/v1/preferences")
        self.assertEqual(status, 200)
        subjects = [i["subject"] for i in body["interests"]]
        self.assertEqual(subjects, ["subject-l2", "subject-untagged"])
        self.assertNotIn("subject-l3", json.dumps(body))
        self.assertEqual(body["withheld"], {"l3": 1, "unknown": 0})
        self.assertEqual(body["legacy_untagged"], 1)


if __name__ == "__main__":
    unittest.main()
