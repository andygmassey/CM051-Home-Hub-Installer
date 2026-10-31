"""Slow-request log line for ical-server.py (v1.0.121 batch-2).

Why: on the v1.0.121 trial walk the assistant's pwg_people tool hit its 15s
HTTP timeout to ical-server on 5 of 10 chat openings, and the access log is
suppressed, so WHY the server was slow was NOT INSTRUMENTED. A request slower
than the threshold now writes ONE line (route template, duration, in-flight
count at start and end, qdrant/oxigraph/embed split). Fast requests write
nothing, and no query string, body or identifier is ever logged.

The tests drive the REAL Handler over a real socket (ThreadingHTTPServer, as
in production). The only fake is urllib.request.urlopen, which sleeps to
stand in for a slow store. Synthetic fixtures only.
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import re
import socket
import sys
import threading
import time
import types
import typing
import unittest
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
SERVER_FILE = HERE.parent / "ical-server.py"


def _install_ostler_security_stub() -> None:
    if "ostler_security" in sys.modules:
        return
    pkg = types.ModuleType("ostler_security")
    pkg.__path__ = []
    sys.modules["ostler_security"] = pkg
    db_mod = types.ModuleType("ostler_security.database")
    db_mod.get_db_connection = lambda *a, **k: (_ for _ in ()).throw(
        RuntimeError("stub: tests must not touch the DB"))
    sys.modules["ostler_security.database"] = db_mod
    posture_mod = types.ModuleType("ostler_security.posture")
    posture_mod.record_posture = lambda *a, **k: None
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
_TOKEN = "test-only-slow-request-token"
os.environ["OSTLER_SERVICE_TOKEN"] = _TOKEN


def _load():
    spec = importlib.util.spec_from_file_location("ical_server_slowlog", SERVER_FILE)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


server = _load()

# Synthetic and recognisable: if this string ever shows in the captured
# output the redaction has failed.
_SECRET_QUERY = "zzsyntheticquerymarker"
_ROUTE = "/api/v1/people/search"
_NO_PROXY = urllib.request.build_opener(urllib.request.ProxyHandler({}))


_SLUG = "zzslugmarker"  # single-word lowercase: the shape a real slug can take

# (path with a slug in it, expected template) for every routed dynamic shape.
_DYNAMIC_EXPECTED = (
    ("/api/v1/people/%s/enrichment", "/api/v1/people/{slug}/enrichment"),
    ("/api/v1/people/%s/forget", "/api/v1/people/{slug}/forget"),
    ("/api/v1/people/%s/minor", "/api/v1/people/{slug}/minor"),
    ("/api/v1/people/%s/minor-suggestion/dismiss",
     "/api/v1/people/{slug}/minor-suggestion/dismiss"),
    ("/api/v1/people/%s/suppress-suggestions",
     "/api/v1/people/{slug}/suppress-suggestions"),
    ("/api/v1/person/%s/timeline", "/api/v1/person/{slug}/timeline"),
    ("/api/v1/topics/%s/mentions", "/api/v1/topics/{topic}/mentions"),
    ("/api/v1/conversation/%s/speakers", "/api/v1/conversation/{id}/speakers"),
    ("/api/v1/conversation/status/%s", "/api/v1/conversation/status/{id}"),
    ("/api/v1/memory/assert/pending/%s", "/api/v1/memory/assert/pending/{id}"),
    ("/api/v1/memory/correct/%s", "/api/v1/memory/correct/{id}"),
)


def _template_problems(templates):
    """Resolve each dynamic example through ``templates`` only."""
    problems = []
    for tpl_path, want in _DYNAMIC_EXPECTED:
        path = tpl_path % _SLUG
        got = None
        for rx, tpl in templates:
            m = rx.match(path)
            if m:
                got = m.expand(tpl)
                break
        if got != want:
            problems.append((path, got, want))
    return problems


def _paths_from_source():
    """Every path shape the Handler serves, read from ical-server.py itself:
    each "/..." literal, each startswith prefix with a slug appended, and each
    prefix x endswith suffix combination around a slug."""
    src = SERVER_FILE.read_text(encoding="utf-8")
    body = src[src.index("class Handler("):]
    lits = set(re.findall(r'"(/(?:api/|health|email|calendar|people)[A-Za-z0-9_/\-]*)"', body))
    starts = set(re.findall(r'startswith\("(/[^"]*)"\)', body))
    ends = set(re.findall(r'endswith\("(/[^"]*)"\)', body))
    paths = set(lits)
    for p in lits | starts:
        paths.add(p + _SLUG)
        paths.add(p.rstrip("/") + "/" + _SLUG)
        paths.add(p.rstrip("/") + "/" + _SLUG + "/x")
    for p in starts:
        for e in ends:
            paths.add(p.rstrip("/") + "/" + _SLUG + e)
    return sorted(paths)


class _Resp:
    def __init__(self, payload):
        self._b = json.dumps(payload).encode()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def read(self):
        return self._b


def _fake_urlopen(embed_s=0.0, qdrant_s=0.0):
    """Stands in for the stores: sleeps per store, answers an empty result."""
    def fake(req, *a, **k):
        url = str(getattr(req, "full_url", req))
        if url.startswith(server.EMBED_OLLAMA_URL.rstrip("/")):
            time.sleep(embed_s)
            return _Resp({"embeddings": [[0.1, 0.2, 0.3]]})
        if url.startswith(server.QDRANT_URL.rstrip("/")):
            time.sleep(qdrant_s)
            return _Resp({"result": []})
        raise AssertionError("unexpected outbound call in test: " + url)
    return fake


class _Harness:
    def __enter__(self):
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        self.port = s.getsockname()[1]
        s.close()
        self.httpd = ThreadingHTTPServer(("127.0.0.1", self.port), server.Handler)
        self.httpd.daemon_threads = True
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()
        for _ in range(50):
            try:
                with socket.create_connection(("127.0.0.1", self.port), 0.1):
                    break
            except OSError:
                time.sleep(0.02)
        return self

    def __exit__(self, *exc):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join(timeout=2)

    def get(self, path):
        req = urllib.request.Request(
            "http://127.0.0.1:%d%s" % (self.port, path),
            headers={"Authorization": "Bearer " + _TOKEN})
        with _NO_PROXY.open(req, timeout=10) as r:
            return r.status, json.loads(r.read())


def _slow_lines(text):
    return [l for l in text.splitlines() if l.startswith("[slow-request]")]


def _field(line, name):
    return re.search(r"\b%s=(\S+)" % name, line).group(1)


class SlowRequestLog(unittest.TestCase):
    def setUp(self):
        self._env = patch.dict(os.environ, {"OSTLER_ICAL_SLOW_REQUEST_S": "0.2"})
        self._env.start()
        self._usage = patch.object(server, "_record_embed_usage", lambda *a, **k: None)
        self._usage.start()

    def tearDown(self):
        self._usage.stop()
        self._env.stop()

    def _run(self, fake, paths, threads=1):
        buf = io.StringIO()
        results = []

        def one(p):
            results.append(h.get(p))

        with patch.object(urllib.request, "urlopen", fake), _Harness() as h:
            with contextlib.redirect_stdout(buf):
                ts = [threading.Thread(target=one, args=(p,)) for p in paths]
                for t in ts:
                    t.start()
                for t in ts:
                    t.join(timeout=20)
        self.assertEqual(len(results), len(paths))
        return buf.getvalue()

    def test_forced_slow_store_emits_exactly_one_line_with_split(self):
        out = self._run(_fake_urlopen(embed_s=0.1, qdrant_s=0.5),
                        [_ROUTE + "?q=" + _SECRET_QUERY + "&limit=5"])
        lines = _slow_lines(out)
        print("SAMPLE:", lines[0] if lines else "<none>")
        self.assertEqual(len(lines), 1, out)
        ln = lines[0]
        self.assertEqual(_field(ln, "route"), _ROUTE)
        self.assertGreater(float(_field(ln, "duration_s")), 0.2)
        self.assertEqual(_field(ln, "inflight_start"), "1")
        self.assertEqual(_field(ln, "inflight_end"), "1")
        self.assertGreaterEqual(float(_field(ln, "qdrant_s")), 0.5)
        self.assertGreaterEqual(float(_field(ln, "embed_s")), 0.1)
        self.assertEqual(float(_field(ln, "oxigraph_s")), 0.0)
        self.assertEqual(_field(ln, "status"), "200")

    def test_fast_request_logs_nothing(self):
        out = self._run(_fake_urlopen(), [_ROUTE + "?q=" + _SECRET_QUERY])
        self.assertEqual(_slow_lines(out), [], out)
        self.assertEqual(out.strip(), "", "a fast request must write nothing")

    def test_query_string_and_identifiers_are_never_logged(self):
        out = self._run(_fake_urlopen(qdrant_s=0.4),
                        [_ROUTE + "?q=" + _SECRET_QUERY + "&limit=5"])
        self.assertEqual(len(_slow_lines(out)), 1, out)
        for leak in (_SECRET_QUERY, "q=", "limit=5", "?"):
            self.assertNotIn(leak, out)

    def test_dynamic_route_slug_is_templated(self):
        slug = "synthetic-person-slug"
        self.assertEqual(server._route_template("/api/v1/people/%s/enrichment" % slug),
                         "/api/v1/people/{slug}/enrichment")
        self.assertEqual(server._route_template("/api/v1/people/%s/forget" % slug),
                         "/api/v1/people/{slug}/forget")
        self.assertNotIn("42", server._route_template("/api/v1/thing/42"))

    def test_every_slug_bearing_route_has_its_template(self):
        self.assertEqual(_template_problems(server._ROUTE_TEMPLATES), [])

    def test_no_route_the_handler_serves_can_log_a_single_word_slug(self):
        """Enumerated FROM THE SOURCE, not from a list kept in this test."""
        paths = _paths_from_source()
        self.assertGreater(len(paths), 100, "enumeration looks broken: %d" % len(paths))
        leaks = [p for p in paths if _SLUG in server._route_template(p)]
        self.assertEqual(leaks, [])
        # control: the enumeration does reach the minors routes
        self.assertIn("/api/v1/people/%s/minor" % _SLUG, paths)
        self.assertIn("/api/v1/people/%s/suppress-suggestions" % _SLUG, paths)
        self.assertIn("/api/v1/people/%s/minor-suggestion/dismiss" % _SLUG, paths)

    def test_mutant_dropping_one_template_is_caught(self):
        for i, (rx, tpl) in enumerate(server._ROUTE_TEMPLATES):
            mutated = server._ROUTE_TEMPLATES[:i] + server._ROUTE_TEMPLATES[i + 1:]
            self.assertNotEqual(_template_problems(mutated), [],
                                "dropping template %d (%s) went unnoticed" % (i, tpl))

    def test_mutant_per_segment_fallback_is_caught(self):
        """The pre-fix fallback printed any lowercase word. It must leak here."""
        def old(path):
            segs = [x for x in path.split("/") if x]
            return "/" + "/".join(
                x if re.match(r"^[a-z_]{1,32}$", x) or x == "v1" else "{id}" for x in segs)
        self.assertIn(_SLUG, old("/api/v1/people/%s/minor" % _SLUG))

    def test_concurrent_requests_show_inflight_above_one(self):
        out = self._run(_fake_urlopen(qdrant_s=0.6),
                        [_ROUTE + "?q=a%d" % i for i in range(4)], threads=4)
        lines = _slow_lines(out)
        self.assertEqual(len(lines), 4, out)
        ends = [int(_field(l, "inflight_end")) for l in lines]
        self.assertGreater(max(ends), 1, lines)
        self.assertEqual(server._inflight_count, 0, "counter must return to zero")

    def test_invalid_threshold_env_falls_back_to_default(self):
        with patch.dict(os.environ, {"OSTLER_ICAL_SLOW_REQUEST_S": "not-a-number"}):
            self.assertEqual(server._slow_request_threshold_s(), 2.0)


if __name__ == "__main__":
    unittest.main()
