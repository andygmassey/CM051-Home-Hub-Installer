"""Walk #15: POST /api/v1/memory/assert must ANSWER while the local model is busy.

people_seed_and_retrieval PASSED early in walk #15, then got NO HTTP response
from ical-server :8090 POST /api/v1/memory/assert in the manifest phase. The
server did not restart (same pid) and its .err carried 3 BrokenPipeError in
wfile.write: the handler finished AFTER the client (curl --max-time 15) had
gone. The probe recorded CANNOT-RUN.

MEASURED before the fix, against this vendored server over a real SPARQL
engine with 8,074 synthetic people and 300,000 named-graph quads: the handler
takes 0.01 to 0.03s, and concurrent /api/v1/people, /people/stale and
/api/v1/contacts/diff do not slow it (the server is a ThreadingHTTPServer).
Its latency is the identity search's: an Ollama embed then a Qdrant search,
each with a 30s socket timeout and no overall deadline. With the embed held
for 20s the handler answered in 20.0s, past the probe's 15s.

This drives the REAL vendored ical-server as a subprocess. Only its three
upstreams are stand-ins: an embed endpoint whose delay we set, an empty
Qdrant, and a SPARQL endpoint that knows one fixture name and records every
UPDATE. Synthetic names only.
"""
from __future__ import annotations

import json
import os
import pathlib
import re
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

ROOT = pathlib.Path(__file__).resolve().parent.parent
SERVER = ROOT / "vendor/cm041/assistant_api/ical-server.py"
PROBE = ROOT / "scripts/box_walk_probes/probes/people_seed_and_retrieval.sh"
TOKEN = "fixture-service-token"
KNOWN_NAME = "Alexandra Patel"
KNOWN_URI = "urn:ostler:person:fixture-alexandra"
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


class Upstreams(BaseHTTPRequestHandler):
    embed_delay = 0.0
    updates: list = []

    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except BrokenPipeError:
            pass

    def do_GET(self):
        self._send(200, b"{}")

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        if self.path.startswith("/api/embed"):
            time.sleep(Upstreams.embed_delay)
            return self._send(200, json.dumps({"embeddings": [[0.0] * 768]}).encode())
        if self.path.startswith("/collections/"):
            return self._send(200, b'{"result": []}')
        if self.path.startswith("/update"):
            Upstreams.updates.append(body)
            return self._send(204, b"")
        if self.path.startswith("/query"):
            rows = []
            if ('"%s"' % KNOWN_NAME) in body and "SELECT ?person" in body:
                rows = [{"person": {"type": "uri", "value": KNOWN_URI}}]
            vars_ = re.findall(r"SELECT\s+(?:DISTINCT\s+)?([^{]*?)\s+WHERE", body, re.S)
            names = [v[1:] for v in (vars_[0].split() if vars_ else []) if v.startswith("?")]
            out = {"head": {"vars": names}, "results": {"bindings": rows}}
            return self._send(200, json.dumps(out).encode(), "application/sparql-results+json")
        self._send(404, b"{}")


def _free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@pytest.fixture(scope="module")
def hub():
    if not SERVER.is_file():
        pytest.fail(f"vendored ical-server.py missing: {SERVER}")
    up = ThreadingHTTPServer(("127.0.0.1", 0), Upstreams)
    threading.Thread(target=up.serve_forever, daemon=True).start()
    up_url = f"http://127.0.0.1:{up.server_address[1]}"
    port = _free_port()
    home = tempfile.mkdtemp(prefix="assert-budget-")
    env = {k: v for k, v in os.environ.items() if "proxy" not in k.lower()}
    env.update({
        "OSTLER_API_PORT": str(port), "OXIGRAPH_URL": up_url, "QDRANT_URL": up_url,
        "EMBED_OLLAMA_URL": up_url, "OSTLER_SERVICE_TOKEN": TOKEN, "USER_ID": "fixtureowner",
        "USER_NAME": "Sam Smith", "HOME": home, "NO_PROXY": "*", "PYTHONDONTWRITEBYTECODE": "1",
        "WIKI_BASE_URL": "http://wiki.example",
        "OSTLER_ASSERT_SEARCH_BUDGET_S": "1",
        "PYTHONPATH": os.pathsep.join([str(ROOT / "vendor/cm041"), str(ROOT / "vendor")]),
    })
    proc = subprocess.Popen([sys.executable, str(SERVER)], env=env, cwd=str(SERVER.parent),
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    url = f"http://127.0.0.1:{port}"
    for _ in range(150):
        if proc.poll() is not None:
            pytest.fail("ical-server exited: " + proc.stderr.read().decode()[-800:])
        try:
            OPENER.open(url + "/health", timeout=1).read()
            break
        except Exception:
            time.sleep(0.1)
    else:
        pytest.fail("ical-server did not come up")
    yield url
    proc.terminate()
    try:
        proc.wait(5)
    except Exception:
        proc.kill()
    up.shutdown()


def _assert(url, subject, client_timeout=10):
    body = json.dumps({"subject": subject, "fact_text": "likes green tea",
                       "asserted_via": "test"}).encode()
    req = urllib.request.Request(url + "/api/v1/memory/assert", data=body, method="POST",
                                 headers={"Authorization": "Bearer " + TOKEN,
                                          "Content-Type": "application/json"})
    t = time.monotonic()
    try:
        with OPENER.open(req, timeout=client_timeout) as r:
            code, data = r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        code, data = e.code, json.loads(e.read() or b"{}")
    return code, data, time.monotonic() - t


def test_control_a_responsive_model_mints_the_new_person(hub):
    Upstreams.embed_delay, Upstreams.updates[:] = 0.0, []
    code, data, dt = _assert(hub, "Catherine Stewart")
    assert code == 200 and data.get("status") == "created_person", (code, data)
    assert Upstreams.updates, "a stored fact must have issued a SPARQL UPDATE"
    assert dt < 2, dt


def test_a_busy_model_gets_a_prompt_retryable_503_and_nothing_is_written(hub):
    # Embed held for 4s, past the 1s budget set for this test but well inside
    # the old 30s socket timeout: before the fix this waited the full 4s and
    # then minted a person no duplicate check had looked at.
    Upstreams.embed_delay, Upstreams.updates[:] = 4.0, []
    code, data, dt = _assert(hub, "Philip Coe")
    assert dt < 2.5, f"answered after {dt:.2f}s; the budget is 1s"
    assert code == 503, (code, data)
    assert str(data.get("reason", "")).startswith("identity_resolution_timeout"), data
    assert data.get("retry_after_seconds"), data
    assert not Upstreams.updates, f"nothing may be written: {Upstreams.updates}"


def test_a_busy_model_still_attaches_to_an_exact_name_already_in_the_graph(hub):
    Upstreams.embed_delay, Upstreams.updates[:] = 4.0, []
    code, data, dt = _assert(hub, KNOWN_NAME)
    assert dt < 2.5, f"answered after {dt:.2f}s; the budget is 1s"
    assert code == 200 and data.get("status") == "stored", (code, data)
    assert any(KNOWN_URI in u for u in Upstreams.updates), Upstreams.updates


def test_the_default_budget_leaves_the_walk_probe_room_to_hear_the_answer():
    src = SERVER.read_text()
    m = re.search(r'OSTLER_ASSERT_SEARCH_BUDGET_S", "([0-9.]+)"', src)
    assert m, "no default budget found in the vendored server"
    p = re.search(r'^HTTP_TIMEOUT="\$\{OSTLER_PROBE_HTTP_TIMEOUT:-([0-9]+)\}"', PROBE.read_text(), re.M)
    assert p, "could not read the probe's HTTP_TIMEOUT default"
    budget, probe = float(m.group(1)), float(p.group(1))
    # The rest of the handler is SPARQL at ~10ms; 5s of margin is generous.
    assert budget + 5 <= probe, f"budget {budget}s + 5s margin exceeds the probe's {probe}s"
