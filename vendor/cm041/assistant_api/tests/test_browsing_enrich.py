"""Lane 6: page summaries for ordinary browsing, and Save to Knowledge.

Everything here drives the REAL code: the real ``Handler`` (so the real
service-token guard answers 401), the real ``api_safari_ingest`` /
``api_safari_save`` / ``api_browsing_search``, the real summary worker and
the real Qdrant and Ollama HTTP clients. Only the far end is fake: one
loopback server plays Qdrant (collections, points, payload, scroll, search)
and Ollama (/api/embed, /api/generate). No external network, and every page
here is fictional.

What is pinned (the brief's test list):
  A1 a visit with text yields a stored summary, tags and entities
  A2 a skip-listed page keeps its visit and captures no text
  A3 no credentials -> 401 on ingest, save and search
  A4 the raw text is gone after summarising (spool, store, state file)
  A5 the worker yields to chat (lease), is rate limited, and is bounded
  B  a saved page lands in the Knowledge collection in the importers'
     shape with the user's tags preserved, linked to the visit
  C  the extension contract matches the real handler
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
import typing
import unittest
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
SERVER_FILE = HERE.parent / "ical-server.py"
CONTRACT = json.loads((HERE / "fixtures" / "hub_contract.json").read_text())
TOKEN = "unit-test-service-token-lane6"

SENTINEL = "ZEPHYRQUILL-7731"  # unique marker planted in fictional page text


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
    os.environ.setdefault("USER_ID", "testuser")
    spec = importlib.util.spec_from_file_location("ical_server_lane6", SERVER_FILE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


server = _load_server_module()
bn = server._bn()


def _free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class FakeBackend:
    """One loopback server that speaks the slice of Qdrant and Ollama the
    Hub uses. State lives on the instance so tests can inspect it."""

    def __init__(self):
        self.collections = {}   # name -> {id: {"vector": [...], "payload": {...}}}
        self.generate_prompts = []
        self.generate_models = []
        self.installed_models = None  # None = every model is installed
        self.generate_reply = None  # callable(prompt) -> str
        outer = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _send(self, code, obj):
                raw = json.dumps(obj).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            def _body(self):
                n = int(self.headers.get("Content-Length") or 0)
                return json.loads(self.rfile.read(n)) if n else {}

            def do_GET(self):
                p = self.path.split("?")[0]
                parts = p.strip("/").split("/")
                if parts[0] == "collections" and len(parts) == 2:
                    return self._send(200 if parts[1] in outer.collections else 404, {})
                if parts[0] == "collections" and len(parts) == 4 and parts[2] == "points":
                    pt = outer.collections.get(parts[1], {}).get(parts[3])
                    if pt is None:
                        return self._send(404, {})
                    return self._send(200, {"result": {"id": parts[3], "payload": pt["payload"]}})
                self._send(404, {})

            def do_PUT(self):
                p = self.path.split("?")[0]
                parts = p.strip("/").split("/")
                body = self._body()
                if parts[0] == "collections" and len(parts) == 2:
                    outer.collections.setdefault(parts[1], {})
                    return self._send(200, {"result": True})
                if parts[-1] == "points":
                    col = outer.collections.setdefault(parts[1], {})
                    for pt in body["points"]:
                        col[pt["id"]] = {"vector": pt["vector"], "payload": dict(pt["payload"])}
                    return self._send(200, {"result": {"status": "completed"}})
                if parts[-1] == "vectors":
                    col = outer.collections.get(parts[1], {})
                    for pt in body["points"]:
                        if pt["id"] in col:
                            col[pt["id"]]["vector"] = pt["vector"]
                    return self._send(200, {"result": {"status": "completed"}})
                self._send(404, {})

            def do_POST(self):
                p = self.path.split("?")[0]
                parts = p.strip("/").split("/")
                body = self._body()
                if p == "/api/embed":
                    return self._send(200, {"embeddings": [[0.1, 0.2, 0.3, 0.4]]})
                if p == "/api/generate":
                    outer.generate_models.append(body.get("model"))
                    if (outer.installed_models is not None
                            and body.get("model") not in outer.installed_models):
                        return self._send(404, {"error": f"model '{body.get('model')}' not found"})
                    outer.generate_prompts.append(body.get("prompt", ""))
                    reply = outer.generate_reply(body.get("prompt", "")) if outer.generate_reply else ""
                    return self._send(200, {"response": reply})
                if parts[0] == "collections" and parts[-1] == "payload":
                    col = outer.collections.get(parts[1], {})
                    for pid in body["points"]:
                        if pid in col:
                            col[pid]["payload"].update(body["payload"])
                    return self._send(200, {"result": {"status": "completed"}})
                if parts[0] == "collections" and parts[-1] == "scroll":
                    col = outer.collections.get(parts[1], {})
                    pts = [{"id": k, "payload": v["payload"]} for k, v in col.items()]
                    return self._send(200, {"result": {"points": pts, "next_page_offset": None}})
                if parts[0] == "collections" and parts[-1] == "search":
                    col = outer.collections.get(parts[1], {})
                    pts = [{"id": k, "score": 0.5, "payload": v["payload"]} for k, v in col.items()]
                    return self._send(200, {"result": pts})
                self._send(404, {})

        self.port = _free_port()
        self.httpd = ThreadingHTTPServer(("127.0.0.1", self.port), H)
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)

    def start(self):
        self.thread.start()

    def stop(self):
        self.httpd.shutdown()
        self.httpd.server_close()

    @property
    def url(self):
        return f"http://127.0.0.1:{self.port}"

    def all_payload_json(self):
        return json.dumps({c: [v["payload"] for v in pts.values()]
                           for c, pts in self.collections.items()})


class _Hub:
    """The real Handler on a free port, wired to a FakeBackend."""

    def __init__(self):
        self.port = _free_port()
        self.httpd = HTTPServer(("127.0.0.1", self.port), server.Handler)
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def start(self):
        self.thread.start()
        for _ in range(50):
            try:
                with socket.create_connection(("127.0.0.1", self.port), 0.1):
                    return
            except OSError:
                time.sleep(0.02)

    def stop(self):
        self.httpd.shutdown()
        self.httpd.server_close()

    def request(self, method, path, body=None, token=TOKEN):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(f"http://127.0.0.1:{self.port}{path}", method=method, data=data)
        if data is not None:
            req.add_header("Content-Type", "application/json")
        if token:
            req.add_header("Authorization", f"Bearer {token}")
        try:
            with self.opener.open(req, timeout=10) as r:
                return r.status, json.loads(r.read() or b"{}")
        except urllib.error.HTTPError as exc:
            raw = exc.read()
            try:
                return exc.code, json.loads(raw or b"{}")
            except Exception:
                return exc.code, {"_raw": raw.decode("utf-8", "replace")}


GOOD_VISIT_REPLY = json.dumps({
    "summary": "A fictional field guide to harbour cities and their ferry timetables.",
    "tags": ["Travel", "harbours", "ferries", "travel"],
    "entities": ["Harbourmaster Quill", "Port of Examplia"],
})
GOOD_KNOWLEDGE_REPLY = json.dumps({
    "summary": "An invented essay on slow bread. It explains starter care and long cold proofs.",
    "key_points": ["Feed the starter daily", "Cold proof overnight", "Score before baking"],
    "tags": ["baking", "sourdough", "food"],
    "entities": ["Bakery of Examplia"],
})


class Lane6Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.backend = FakeBackend()
        self.backend.start()
        self.addCleanup(self.backend.stop)
        self.hub = _Hub()
        self.hub.start()
        self.addCleanup(self.hub.stop)
        env = {
            "OSTLER_SERVICE_TOKEN": TOKEN,
            "OSTLER_TEST_AUTOAUTH": "",
            "AI_MODEL": "gemma4:e2b",
            "OSTLER_BROWSING_MODEL": "",
            "OSTLER_ENV_FILE": os.path.join(self.tmp, "absent.env"),
            "NO_PROXY": "127.0.0.1,localhost",
            "no_proxy": "127.0.0.1,localhost",
        }
        p = patch.dict(os.environ, env)
        p.start()
        self.addCleanup(p.stop)
        for target, name, value in (
            (server, "QDRANT_URL", self.backend.url),
            (server, "EMBED_OLLAMA_URL", self.backend.url),
            (bn, "OLLAMA_URL", self.backend.url),
            (server, "_BROWSING_STATE_PATH", os.path.join(self.tmp, "state.json")),
            (bn, "USER_SKIPLIST_PATH", os.path.join(self.tmp, "skip.txt")),
            (bn, "USER_ACTIVE_LEASE", os.path.join(self.tmp, "lease")),
        ):
            q = patch.object(target, name, value)
            q.start()
            self.addCleanup(q.stop)
        self.spool = os.path.join(self.tmp, "spool")
        self.sleeps = []
        self.active_polls = 0
        self.queue = bn.EnrichQueue(
            self.spool, server._enrich_summarise, server._enrich_store,
            min_interval_s=0, sleep=self.sleeps.append,
            is_user_active=lambda: False,
        )  # not started: tests call run_once() themselves
        # Rule 0.8 gate open by default (no licence state on a test box);
        # TestD closes it explicitly.
        q = patch.object(server, "_subscription_paused", lambda surface: None)
        q.start()
        self.addCleanup(q.stop)
        q = patch.object(server, "_enrich_queue", lambda: self.queue)
        q.start()
        self.addCleanup(q.stop)
        self.backend.generate_reply = lambda prompt: (
            GOOD_KNOWLEDGE_REPLY if "Knowledge entry" in prompt else GOOD_VISIT_REPLY)

    def visit(self, url="https://harbour.example.invalid/guide/ferries", text=None, ts="2026-10-01T10:00:00Z", **extra):
        body = {"url": url, "title": "Harbour cities field guide", "timestamp": ts, "device": "Chrome"}
        if text is not None:
            body["text"] = text
        body.update(extra)
        return self.hub.request("POST", "/api/safari/ingest", body)

    def visits(self):
        return self.backend.collections.get("safari_history", {})

    def spool_files(self):
        return list(Path(self.spool).glob("*.json")) if Path(self.spool).exists() else []


PAGE_TEXT = (f"Harbour cities rely on ferries. {SENTINEL} Harbourmaster Quill keeps the timetable "
             "for the Port of Examplia. " * 30)


class TestA_PageSummaries(Lane6Base):
    def test_a1_visit_with_text_stores_summary_tags_entities(self):
        status, body = self.visit(text=PAGE_TEXT, dwell_ms=21000)
        self.assertEqual(status, 200, body)
        self.assertEqual(body["summary_status"], "queued")
        pid = body["id"]
        self.assertEqual(self.visits()[pid]["payload"]["summary_status"], "pending")
        self.assertTrue(self.queue.run_once())
        stored = self.visits()[pid]["payload"]
        self.assertEqual(stored["summary_status"], "done")
        self.assertIn("harbour cities", stored["summary"].lower())
        self.assertEqual(stored["tags"], ["travel", "harbours", "ferries"])  # lowercased, deduped
        self.assertIn("Harbourmaster Quill", stored["entities"])
        self.assertEqual(stored["dwell_ms"], 21000)
        # the model really saw the page text
        self.assertTrue(any(SENTINEL in p for p in self.backend.generate_prompts))

    def test_a2_skip_listed_page_keeps_visit_but_captures_no_text(self):
        for url in (
            "https://intranet.example.invalid/wiki/page",
            "https://shop.example.invalid/checkout/step1",
            "https://news.example.invalid/search?q=ferries",
            "http://localhost:3000/app",
            "http://192.168.1.20/admin",
            "https://example.invalid/account/settings",
        ):
            status, body = self.visit(url=url, text=PAGE_TEXT, ts=f"2026-10-01T10:00:0{len(url) % 10}Z")
            self.assertEqual(status, 200, url)
            self.assertEqual(body["summary_status"], "skipped_text", url)
            self.assertEqual(body["stored"], 1)
        self.assertEqual(self.spool_files(), [])
        self.assertEqual(self.backend.generate_prompts, [])
        self.assertNotIn(SENTINEL, self.backend.all_payload_json())

    def test_a2b_user_editable_skiplist(self):
        Path(bn.USER_SKIPLIST_PATH).write_text("# mine\nharbour.example\n")
        status, body = self.visit(text=PAGE_TEXT)
        self.assertEqual(body["summary_status"], "skipped_text")
        self.assertEqual(self.spool_files(), [])

    def test_a2c_skip_reason_table(self):
        for url, want in (
            ("https://harbour.example.invalid/guide", ""),
            ("https://news.example.invalid/articles/ferries", ""),
            ("https://www.mybank.example.invalid/home", "sensitive_host"),
            ("https://example.invalid/login", "path_login"),
            ("https://example.invalid/sign-in/now", "path_sign-in"),
            ("https://example.invalid/?q=x", "search_results"),
            ("https://10.1.2.3/x", "private_ip"),
            ("https://172.20.0.4/x", "private_ip"),
            ("https://wiki.corp.example.invalid/x", "intranet"),
            ("ftp://example.invalid/x", "non_web_scheme"),
        ):
            self.assertEqual(bn.text_skip_reason(url, user_extra=[]), want, url)

    def test_a3_no_credentials_is_401(self):
        for method, path, body in (
            ("POST", "/api/safari/ingest", {"url": "https://harbour.example.invalid/a", "text": "x"}),
            ("POST", "/api/safari/save", {"url": "https://harbour.example.invalid/a", "text": "x"}),
            ("GET", "/api/v1/browsing/search?q=ferries", None),
        ):
            status, _ = self.hub.request(method, path, body, token=None)
            self.assertEqual(status, 401, path)
            status, _ = self.hub.request(method, path, body, token="wrong-token")
            self.assertEqual(status, 401, path)
        self.assertEqual(self.visits(), {})
        self.assertEqual(self.spool_files(), [])

    def test_a4_raw_text_is_gone_after_summarising(self):
        status, body = self.visit(text=PAGE_TEXT)
        pid = body["id"]
        # while queued the text exists only in the 0600 spool file
        files = self.spool_files()
        self.assertEqual(len(files), 1)
        self.assertEqual(files[0].stat().st_mode & 0o777, 0o600)
        self.assertNotIn(SENTINEL, self.backend.all_payload_json())
        self.queue.run_once()
        self.assertEqual(self.spool_files(), [])
        blob = self.backend.all_payload_json() + Path(server._BROWSING_STATE_PATH).read_text()
        self.assertNotIn(SENTINEL, blob)
        self.assertNotIn("html", self.visits()[pid]["payload"].get("summary", ""))
        # ... and a failed summary also drops the text and says so honestly
        self.backend.generate_reply = lambda p: "not json at all"
        status, body = self.visit(url="https://harbour.example.invalid/two", text=PAGE_TEXT,
                                  ts="2026-10-02T10:00:00Z")
        for _ in range(bn.MAX_ATTEMPTS):
            self.queue.run_once()
        self.assertEqual(self.spool_files(), [])
        self.assertEqual(self.visits()[body["id"]]["payload"]["summary_status"], "failed")
        self.assertNotIn(SENTINEL, self.backend.all_payload_json())

    def test_a4b_repost_never_erases_a_summary(self):
        status, body = self.visit(text=PAGE_TEXT)
        self.queue.run_once()
        status, again = self.visit()  # the extension's retry of the text-less visit
        self.assertEqual(again["id"], body["id"])
        self.assertEqual(self.visits()[body["id"]]["payload"]["summary_status"], "done")
        status, third = self.visit(text=PAGE_TEXT)  # second send after it is already done
        self.assertEqual(third["summary_status"], "unsummarised")
        self.assertEqual(self.spool_files(), [])

    def test_a5_worker_yields_to_chat_and_is_rate_limited_and_bounded(self):
        order = []
        q = bn.EnrichQueue(
            self.spool, lambda job: order.append(("summarise", job["id"])) or {"summary": "s", "tags": [], "entities": []},
            lambda job, res: order.append(("store", job["id"])) or True,
            min_interval_s=5, sleep=self.sleeps.append,
            is_user_active=lambda: self._chat_active(order), max_queue=2,
        )
        # chat is "active" for the first 4 lease polls
        self.active_polls = 4
        self.assertTrue(q.enqueue({"id": "v1", "kind": "visit", "text": "a"}))
        self.assertTrue(q.enqueue({"id": "v2", "kind": "visit", "text": "b"}))
        self.assertFalse(q.enqueue({"id": "v3", "kind": "visit", "text": "c"}), "queue is bounded")
        # an explicit save outranks browsing but still obeys the lease
        self.assertTrue(q.enqueue({"id": "k1", "kind": "knowledge", "text": "d"}))
        q.run_once()
        self.assertEqual(q.yielded, 4, "waited out four active lease polls before any model call")
        first_call = next(i for i, o in enumerate(order) if o[0] == "summarise")
        self.assertEqual(order[first_call], ("summarise", "k1"), "knowledge before older browsing")
        self.assertEqual([o for o in order[:first_call] if o[0] != "lease_busy"], [],
                         "no model call until the chat lease cleared")
        self.assertEqual(sum(1 for o in order[:first_call] if o[0] == "lease_busy"), 4)
        q.run_once()
        self.assertEqual([o[1] for o in order if o[0] == "summarise"], ["k1", "v2"],
                         "a full queue sheds its OLDEST browsing job for a user save, never the save")
        # rate limit: the worker slept to keep MIN interval between model calls
        self.assertTrue(any(s > 0 for s in self.sleeps if s != 0.5))

    def _chat_active(self, order):
        if self.active_polls > 0:
            self.active_polls -= 1
            order.append(("lease_busy", True))
            return True
        return False

    def test_a5b_lease_file_contract(self):
        lease = Path(bn.USER_ACTIVE_LEASE)
        lease.write_text(str(int(time.time() * 1000) + 60_000))
        self.assertTrue(bn.user_active())
        lease.write_text(str(int(time.time() * 1000) - 1))
        self.assertFalse(bn.user_active())
        lease.write_text("garbage")
        self.assertFalse(bn.user_active())
        lease.unlink()
        self.assertFalse(bn.user_active())

    def test_a6_history_import_shaped_entries_read_as_unsummarised(self):
        # shape written by the History.db / Chrome history importers: no page text, no status
        self.backend.collections["safari_history"] = {"old-1": {"vector": [0] * 4, "payload": {
            "url": "https://recipes.example.invalid/bread", "title": "Slow breads and sourdough",
            "domain": "recipes.example.invalid", "visit_date": "2026-09-01", "source": "safari_history"}}}
        status, body = self.hub.request("GET", "/api/v1/browsing/search?q=bread")
        self.assertEqual(status, 200)
        self.assertEqual(body["results"][0]["summary_status"], "unsummarised")
        self.assertEqual(body["results"][0]["summary"], "")

    def test_a7_search_returns_summary_and_tags(self):
        status, body = self.visit(text=PAGE_TEXT)
        self.queue.run_once()
        status, res = self.hub.request("GET", "/api/v1/browsing/search?q=ferry+timetables&limit=5")
        self.assertEqual(status, 200)
        hit = res["results"][0]
        self.assertEqual(hit["url"], "https://harbour.example.invalid/guide/ferries")
        self.assertEqual(hit["summary_status"], "done")
        self.assertIn("harbour", hit["summary"].lower())
        self.assertIn("ferries", hit["tags"])
        self.assertIn("Port of Examplia", hit["entities"])
        status, none = self.hub.request("GET", "/api/v1/browsing/search?q=zzzznothing")
        self.assertEqual(none["count"], 1 if none["results"] else 0)  # vector fallback may return the single fake entry


class TestD_SummaryModelIsTheInstalledOne(Lane6Base):
    """Measured 2026-10-07 on macmini16-walk: the job env has no AI_MODEL, the
    old default qwen3.5:9b was not pulled, so every summary failed silently."""

    def _no_env_model(self):
        p = patch.dict(os.environ, {"AI_MODEL": "", "OSTLER_BROWSING_MODEL": ""})
        p.start()
        self.addCleanup(p.stop)

    def _write_env_file(self, text):
        path = os.path.join(self.tmp, "ostler.env")
        Path(path).write_text(text)
        p = patch.dict(os.environ, {"OSTLER_ENV_FILE": path})
        p.start()
        self.addCleanup(p.stop)

    def test_d1_model_read_from_installer_env_file_when_job_env_has_none(self):
        self._no_env_model()
        self._write_env_file("USER_FIRST_NAME=Sam\nAI_MODEL=gemma4:e2b\nOTHER=1\n")
        self.backend.installed_models = {"gemma4:e2b"}
        status, body = self.visit(text=PAGE_TEXT, dwell_ms=21000)
        self.assertEqual(status, 200, body)
        self.assertTrue(self.queue.run_once())
        stored = self.visits()[body["id"]]["payload"]
        self.assertEqual(stored["summary_status"], "done")
        self.assertEqual(stored["summary_model"], "gemma4:e2b")
        self.assertEqual(self.backend.generate_models, ["gemma4:e2b"])

    def test_d2_no_model_anywhere_is_failed_loudly_never_a_guess(self):
        self._no_env_model()  # env file is absent too
        self.assertIsNone(bn.summary_model())
        status, body = self.visit(text=PAGE_TEXT, dwell_ms=21000)
        self.assertEqual(status, 200, body)
        with patch("sys.stderr") as err:
            self.assertTrue(self.queue.run_once())
        self.assertIn("no summary model configured",
                      "".join(str(c.args[0]) for c in err.write.call_args_list))
        stored = self.visits()[body["id"]]["payload"]
        self.assertEqual(stored["summary_status"], "failed")
        self.assertEqual(stored["summary_error"], "no_model_configured")
        self.assertEqual(self.backend.generate_models, [])  # nothing was asked of Ollama
        self.assertEqual(self.spool_files(), [])  # not retried, text gone

    def test_d3_model_not_pulled_is_failed_with_reason_and_not_retried(self):
        self.backend.installed_models = {"gemma4:e2b", "nomic-embed-text:latest"}
        with patch.dict(os.environ, {"AI_MODEL": "qwen3.5:9b"}):
            status, body = self.visit(text=PAGE_TEXT, dwell_ms=21000)
            with patch("sys.stderr") as err:
                self.assertTrue(self.queue.run_once())
        self.assertIn("not installed", "".join(str(c.args[0]) for c in err.write.call_args_list))
        stored = self.visits()[body["id"]]["payload"]
        self.assertEqual(stored["summary_status"], "failed")
        self.assertEqual(stored["summary_error"], "model_not_installed")
        self.assertEqual(self.backend.generate_models, ["qwen3.5:9b"])  # one call, no retries
        self.assertEqual(self.spool_files(), [])

    def test_d4_saved_page_with_missing_model_is_visibly_failed(self):
        self._no_env_model()
        status, body = self.hub.request("POST", "/api/safari/save", {
            "url": "https://harbour.example.invalid/guide/ferries", "title": "Ferries",
            "text": PAGE_TEXT, "timestamp": "2026-10-01T10:00:00Z", "device": "Chrome",
            "tags": ["travel"], "note": "keep"})
        self.assertEqual(status, 202, body)
        self.assertTrue(self.queue.run_once())
        items = list(self.backend.collections[bn.KNOWLEDGE_COLLECTION].values())
        self.assertEqual(len(items), 1)
        pl = items[0]["payload"]
        self.assertEqual(pl["summary_status"], "failed")
        self.assertEqual(pl["summary_error"], "no_model_configured")
        self.assertEqual(pl["user_tags"], ["travel"])  # the user's own save is kept
        self.assertEqual(pl["user_note"], "keep")

    def test_d5_override_beats_env_and_env_beats_file(self):
        self._write_env_file("AI_MODEL=from-file\n")
        with patch.dict(os.environ, {"AI_MODEL": "from-env", "OSTLER_BROWSING_MODEL": ""}):
            self.assertEqual(bn.summary_model(), "from-env")
        with patch.dict(os.environ, {"AI_MODEL": "", "OSTLER_BROWSING_MODEL": ""}):
            self.assertEqual(bn.summary_model(), "from-file")
        with patch.dict(os.environ, {"OSTLER_BROWSING_MODEL": "override"}):
            self.assertEqual(bn.summary_model(), "override")


class TestB_SaveToKnowledge(Lane6Base):
    # Keys cm024 QdrantStore.upsert writes (vendor/cm024_knowledge/.../storage/qdrant_store.py
    # ~L240) plus the keys CM044 knowledge_pages._assemble_note reads.
    IMPORTER_KEYS = {"note_id", "evernote_guid", "chunk_index", "title", "content", "tags",
                     "compartment_level", "importance_score", "source_url", "created",
                     "updated", "content_hash"}
    WIKI_READER_KEYS = {"rel_path", "notebook", "source", "author"}

    def save(self, **over):
        body = {"url": "https://bakery.example.invalid/essays/slow-bread", "title": "Slow bread, an essay",
                "text": PAGE_TEXT, "timestamp": "2026-10-03T09:00:00Z", "device": "macOS",
                "tags": ["Research", "bread club"], "note": "Try this for the weekend bake."}
        body.update(over)
        return self.hub.request("POST", "/api/safari/save", body)

    def test_b1_save_becomes_a_knowledge_item_with_user_tags_and_visit_link(self):
        status, body = self.save()
        self.assertEqual(status, 202, body)
        self.assertEqual(body["status"], "queued")
        self.queue.run_once()
        notes = self.backend.collections[bn.KNOWLEDGE_COLLECTION]
        self.assertEqual(len(notes), 1)
        note = next(iter(notes.values()))["payload"]
        self.assertTrue(self.IMPORTER_KEYS <= set(note), self.IMPORTER_KEYS - set(note))
        self.assertTrue(self.WIKI_READER_KEYS <= set(note))
        self.assertEqual(note["source"], "web_clip")
        self.assertEqual(note["source_url"], "https://bakery.example.invalid/essays/slow-bread")
        self.assertEqual(note["tags"][:2], ["Research", "bread club"])  # user tags first, case kept
        self.assertIn("sourdough", note["tags"])
        self.assertIn("## Summary", note["content"])
        self.assertIn("Cold proof overnight", note["content"])
        self.assertIn("Try this for the weekend bake.", note["content"])
        self.assertEqual(note["user_note"], "Try this for the weekend bake.")
        self.assertEqual(note["compartment_level"], 2)  # strictest level the importers index
        self.assertEqual(note["visit_id"], body["visit_id"])
        visit = self.visits()[body["visit_id"]]["payload"]
        self.assertTrue(visit["saved_to_knowledge"])
        self.assertEqual(visit["knowledge_id"], note["note_id"])
        # raw page text is not kept anywhere
        self.assertNotIn(SENTINEL, self.backend.all_payload_json())
        self.assertEqual(self.spool_files(), [])

    def test_b2_summary_failure_still_saves_the_users_item(self):
        self.backend.generate_reply = lambda p: "garbage"
        status, body = self.save()
        for _ in range(bn.MAX_ATTEMPTS):
            self.queue.run_once()
        note = next(iter(self.backend.collections[bn.KNOWLEDGE_COLLECTION].values()))["payload"]
        self.assertFalse(note["summarised"])
        self.assertEqual(note["tags"], ["Research", "bread club"])
        self.assertIn("Try this for the weekend bake.", note["content"])

    def test_b3_sensitive_domain_is_refused_even_on_explicit_save(self):
        status, body = self.save(url="https://www.mybank.example.invalid/statement")
        self.assertEqual(status, 200)
        self.assertEqual(body["skipped_sensitive"], 1)
        self.assertEqual(self.spool_files(), [])
        self.assertNotIn(bn.KNOWLEDGE_COLLECTION, self.backend.collections)

    def test_b4_text_cap_and_validation(self):
        status, body = self.save(text="x" * (bn.KNOWLEDGE_TEXT_CAP_CHARS + 5000))
        self.assertEqual(status, 202)
        job = json.loads(self.spool_files()[0].read_text())
        self.assertEqual(len(job["text"]), bn.KNOWLEDGE_TEXT_CAP_CHARS)
        self.assertEqual(self.save(url="")[0], 400)
        self.assertEqual(self.save(text="", note="")[0], 400)
        tags = [f"t{i}" for i in range(50)]
        self.save(tags=tags, timestamp="2026-10-04T09:00:00Z")
        jobs = [json.loads(p.read_text()) for p in self.spool_files()]
        self.assertTrue(all(len(j["user_tags"]) <= bn.MAX_TAGS_USER for j in jobs))


class TestD_VendoredSubscriptionGate(Lane6Base):
    """CM051-only: browser capture pauses without Ostler Pro (Rule 0.8), and
    Save to Knowledge is browser capture, so it pauses too, writing nothing."""

    def test_d1_save_pauses_like_ingest_when_the_gate_says_paused(self):
        paused = ({"error": "paused"}, 402)
        with patch.object(server, "_subscription_paused", lambda surface: paused):
            status, body = self.hub.request("POST", "/api/safari/save", {
                "url": "https://bakery.example.invalid/x", "text": "hello", "tags": ["a"]})
            self.assertEqual(status, 402)
            status, body = self.hub.request("POST", "/api/safari/ingest", {
                "url": "https://bakery.example.invalid/x", "text": "hello"})
            self.assertEqual(status, 402)
        self.assertEqual(self.spool_files(), [])
        self.assertEqual(self.visits(), {})


class TestC_ExtensionContract(Lane6Base):
    def test_c1_contract_payload_is_accepted_by_the_real_handler(self):
        ing = CONTRACT["ingest"]
        body = {k: {"url": "https://harbour.example.invalid/contract", "title": "Contract page",
                    "timestamp": "2026-10-05T10:00:00Z", "device": "iOS"}[k] for k in ing["required"]}
        for k in ing["new_optional"]:
            body[k] = {"text": PAGE_TEXT[:ing["text_cap_chars"]], "dwell_ms": 30000}[k]
        for k in ing["legacy_optional"]:
            body[k] = "<p>legacy html is accepted and never stored</p>"
        status, res = self.hub.request("POST", "/api/safari/ingest", body)
        self.assertEqual(status, 200, res)
        self.assertEqual(res["summary_status"], "queued")
        self.queue.run_once()
        stored = self.visits()[res["id"]]["payload"]
        self.assertEqual(stored["summary_status"], "done")
        self.assertEqual(stored["device"], "iOS")
        self.assertEqual(stored["html_len"], len(body["html"]))
        self.assertNotIn("legacy html", self.backend.all_payload_json())
        self.assertEqual(set(res), {"ok", "stored", "id", "summary_status"})

    def test_c2_contract_save_payload_is_accepted(self):
        sv = CONTRACT["save"]
        body = {k: {"url": "https://bakery.example.invalid/contract", "title": "Saved", "text": PAGE_TEXT,
                    "timestamp": "2026-10-05T11:00:00Z", "device": "Chrome"}[k] for k in sv["required"]}
        body["tags"] = ["a", "b"]
        body["note"] = "n"
        self.assertEqual(set(sv["optional"]), {"tags", "note"})
        status, res = self.hub.request("POST", "/api/safari/save", body)
        self.assertEqual(status, 202, res)
        self.assertEqual(sv["path"], "/api/safari/save")

    def test_c3_contract_numbers_and_lists_match_the_hub(self):
        self.assertEqual(CONTRACT["ingest"]["text_cap_chars"], bn.TEXT_CAP_CHARS)
        self.assertEqual(CONTRACT["save"]["text_cap_chars"], bn.KNOWLEDGE_TEXT_CAP_CHARS)
        d = CONTRACT["default_text_skiplist"]
        for key in ("host_substrings", "path_patterns", "query_params",
                    "hosts_exact_or_suffix", "host_patterns", "private_ip_prefixes"):
            self.assertEqual(d[key], bn.DEFAULT_TEXT_SKIPLIST[key], key)

    def test_c4_over_cap_text_is_clamped_not_rejected(self):
        status, res = self.visit(text="y" * (bn.TEXT_CAP_CHARS * 3))
        self.assertEqual(status, 200)
        job = json.loads(self.spool_files()[0].read_text())
        self.assertEqual(len(job["text"]), bn.TEXT_CAP_CHARS)


if __name__ == "__main__":
    unittest.main()
