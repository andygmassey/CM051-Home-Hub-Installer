"""Lane 11 route matrix over a real HTTPServer.

For each route a client now depends on:

  POST /api/v1/people/{slug}/forget          (CM031 ForgetPersonService)
  POST /api/v1/speakers/identify             (CM042 SpeakersIdentifyService)
  POST /api/v1/speakers/correct
  POST /api/v1/conversation/upload-part

this pins: a valid service token is served, a missing or wrong token is 401,
the wrong method is 405, an over-limit body is 413, and a path-traversal id is
rejected. Fixture data is synthetic.
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
TOKEN = "lane11-synthetic-service-token"


def _stub_security() -> None:
    import sqlite3
    if "ostler_security" in sys.modules:
        return
    try:
        import ostler_security  # noqa: F401
        return
    except Exception:
        pass
    pkg = types.ModuleType("ostler_security")
    pkg.__path__ = []
    sys.modules["ostler_security"] = pkg
    db = types.ModuleType("ostler_security.database")
    db.get_db_connection = lambda path, _k, *a, **kw: sqlite3.connect(path)
    sys.modules["ostler_security.database"] = db
    posture = types.ModuleType("ostler_security.posture")
    posture.record_posture = lambda *a, **kw: None
    sys.modules["ostler_security.posture"] = posture
    # The vendored (CM051) server also hard-imports ostler_security.db_key.
    db_key = types.ModuleType("ostler_security.db_key")
    db_key.resolve_db_key = lambda *a, **kw: types.SimpleNamespace(
        key=None, source=None, reason="no_key", detail=None)
    sys.modules["ostler_security.db_key"] = db_key


_stub_security()
_spec = importlib.util.spec_from_file_location("ical_server_lane11", SERVER_FILE)
server = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(server)
_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def _free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class _Server:
    def __enter__(self):
        self.port = _free_port()
        self.httpd = HTTPServer(("127.0.0.1", self.port), server.Handler)
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        for _ in range(50):
            try:
                socket.create_connection(("127.0.0.1", self.port), 0.1).close()
                break
            except OSError:
                time.sleep(0.02)
        return self

    def __exit__(self, *exc):
        self.httpd.shutdown()
        self.httpd.server_close()

    def call(self, method, path, token=TOKEN, body=None, raw=None, ctype="application/json"):
        data = raw if raw is not None else (None if body is None else json.dumps(body).encode())
        if data is None and method == "POST":
            data = b""
        req = urllib.request.Request(f"http://127.0.0.1:{self.port}{path}", method=method, data=data)
        if token:
            req.add_header("Authorization", f"Bearer {token}")
        if method == "POST":
            req.add_header("Content-Type", ctype)
        try:
            with _OPENER.open(req, timeout=10) as r:
                return r.status, json.loads(r.read() or b"{}")
        except urllib.error.HTTPError as exc:
            raw_body = exc.read()
            try:
                return exc.code, json.loads(raw_body or b"{}")
            except ValueError:
                return exc.code, {}


    def oversize_status(self, path, claimed):
        """Status for a POST that CLAIMS `claimed` body bytes. Raw socket: the
        server answers 413 from the header alone and closes, which urllib
        would report as a broken pipe instead of a status."""
        with socket.create_connection(("127.0.0.1", self.port), 5) as sock:
            sock.sendall(
                (f"POST {path} HTTP/1.1\r\nHost: 127.0.0.1:{self.port}\r\n"
                 f"Authorization: Bearer {TOKEN}\r\nContent-Type: application/json\r\n"
                 f"Content-Length: {claimed}\r\nConnection: close\r\n\r\n{{}}").encode())
            return int(sock.recv(64).split()[1])


class Lane11Routes(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        env = {
            "OSTLER_SERVICE_TOKEN": TOKEN,
            "OSTLER_TEST_AUTOAUTH": "",
            "OSTLER_SPEAKER_CORRECTIONS": os.path.join(self.tmp.name, "corr.json"),
            "OSTLER_UPLOAD_SPOOL_DIR": os.path.join(self.tmp.name, "spool"),
        }
        p = patch.dict(os.environ, env)
        p.start()
        self.addCleanup(p.stop)
        for target, value in (
            ("_speaker_directory_rows", lambda: [{"name": "Jane Doe"}]),
            ("_speaker_operator_names", lambda: ["Sam Smith"]),
        ):
            q = patch.object(server, target, value)
            q.start()
            self.addCleanup(q.stop)
        fake = patch.object(server, "api_conversation_process",
                            lambda payload: ({"job_id": payload["metadata"]["meeting_id"],
                                              "status": "accepted",
                                              "state_url": "/api/v1/conversation/status/"
                                              + payload["metadata"]["meeting_id"]}, 202))
        fake.start()
        self.addCleanup(fake.stop)
        forget = patch.object(server, "api_people_forget",
                              lambda slug: ({"forgotten": True, "wiki_recompile_queued": True,
                                             "stores_purged": ["oxigraph", "qdrant"]}, 200)
                              if server._SLUG_PATTERN.match(slug or "") else ({"error": "bad slug"}, 400))
        forget.start()
        self.addCleanup(forget.stop)

    VALID = {
        "/api/v1/people/jane-doe/forget": None,
        "/api/v1/speakers/identify": {"transcript": "Remote: hello\nUser: hi\n",
                                      "attendees": ["Jane Doe", "Sam Smith"],
                                      "timestamp": "2026-01-01T00:00:00Z", "duration": 60,
                                      "source": "test"},
        "/api/v1/speakers/correct": {"corrections": [{"label": "Remote", "display_name": "Jane Doe"}]},
        "/api/v1/conversation/upload-part": {"meeting_id": "m-1", "part_index": 0, "part_total": 1,
                                             "transcript": "User: hi\n"},
    }

    def test_valid_credential_is_served(self):
        with _Server() as s:
            for path, body in self.VALID.items():
                status, data = s.call("POST", path, body=body)
                self.assertIn(status, (200, 202), (path, status, data))

    def test_missing_and_wrong_credential_is_401(self):
        with _Server() as s:
            for path, body in self.VALID.items():
                self.assertEqual(s.call("POST", path, token=None, body=body)[0], 401, path)
                self.assertEqual(s.call("POST", path, token="wrong", body=body)[0], 401, path)

    def test_wrong_method_is_405(self):
        with _Server() as s:
            for path in self.VALID:
                status, _ = s.call("GET", path)
                self.assertEqual(status, 405, path)

    def test_over_limit_body_is_413(self):
        with _Server() as s:
            for path in self.VALID:
                self.assertEqual(s.oversize_status(path, server.MAX_POST_BYTES + 1), 413, path)

    def test_path_traversal_is_rejected(self):
        with _Server() as s:
            for bad in ("..%2f..%2fetc", "../x", "a%2Fb", "Jane", ".."):
                status, _ = s.call("POST", f"/api/v1/people/{bad}/forget")
                self.assertEqual(status, 400, bad)
            status, _ = s.call("POST", "/api/v1/people/a/b/forget")
            self.assertEqual(status, 400)
            for bad_id in ("../etc", "a/b", "..", "x" * 129, "a b"):
                status, _ = s.call("POST", "/api/v1/conversation/upload-part",
                                   body={"meeting_id": bad_id, "part_index": 0, "part_total": 1,
                                         "transcript": "x"})
                self.assertEqual(status, 400, bad_id)
            status, _ = s.call("POST", "/api/v1/speakers/correct",
                               body={"meeting_id": "../x",
                                     "corrections": [{"label": "R", "display_name": "J"}]})
            self.assertEqual(status, 400)
        self.assertFalse(Path(self.tmp.name, "etc").exists())

    def test_identify_names_the_remote_speaker_end_to_end(self):
        with _Server() as s:
            status, data = s.call("POST", "/api/v1/speakers/identify", body=self.VALID["/api/v1/speakers/identify"])
            self.assertEqual(status, 200)
            by = {x["label"]: x for x in data["speakers"]}
            self.assertEqual(by["Remote"]["display_name"], "Jane Doe")
            self.assertEqual(by["Remote"]["person_id"], "jane-doe")
            self.assertEqual(by["User"]["display_name"], "Sam Smith")

    def test_correction_names_a_later_transcript(self):
        three = {"transcript": "Remote: hello\n", "attendees": ["Jane Doe", "Alex Ross", "Sam Smith"]}
        with _Server() as s:
            _, before = s.call("POST", "/api/v1/speakers/identify", body=three)
            self.assertIsNone(before["speakers"][0]["display_name"])
            s.call("POST", "/api/v1/speakers/correct",
                   body={"attendees": three["attendees"],
                         "corrections": [{"label": "Remote", "display_name": "Alex Ross"}]})
            _, after = s.call("POST", "/api/v1/speakers/identify", body=three)
            self.assertEqual(after["speakers"][0]["display_name"], "Alex Ross")

    def test_chunked_upload_reassembles_and_processes_once(self):
        with _Server() as s:
            sent = []
            for i, text in ((2, "C\n"), (0, "A\n"), (1, "B\n")):
                sent.append(s.call("POST", "/api/v1/conversation/upload-part",
                                   body={"meeting_id": "m-2", "part_index": i, "part_total": 3,
                                         "transcript": text, "metadata": {"type": "call"}}))
            self.assertEqual([c for c, _ in sent], [200, 200, 202])
            self.assertEqual(sent[-1][1]["parts"], 3)


if __name__ == "__main__":
    unittest.main()
