"""memory/assert while the local model is busy: answer in time, lose nothing.

Walk #15: people_seed_and_retrieval got NO HTTP response from POST
/api/v1/memory/assert inside its 15s curl; ical-server logged BrokenPipeError
in wfile.write (it answered after the client left). Measured on this vendored
server with 8,074 synthetic people: the handler is 0.01-0.03s and its latency
is the Ollama embed behind the identity search (held 20s -> 20.0s).

Contract, driven against the REAL vendored server as a subprocess over a REAL
SPARQL engine (pyoxigraph). Only the embed and Qdrant edges are stand-ins:
  * a responsive model mints and stores as before (control);
  * an embed held past the budget gets 202 accepted_pending within the budget,
    and a row is in the spool; nothing is in the graph yet;
  * once the model answers, the resolver attaches the fact EXACTLY ONCE, and a
    second pass is a no-op;
  * a restart with a pending row still lands it exactly once, and a row that
    was written but not closed (death between the write and the close) is
    closed without a second write;
  * the level recorded on the row is the level written;
  * an exact name already in the graph is stored even while the model is busy;
  * the shipped default budget leaves the walk probe room to hear the answer.
Synthetic names only.
"""
from __future__ import annotations

import json
import os
import pathlib
import re
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

import pyoxigraph as ox  # a missing engine is a red collection error, never a skip

ROOT = pathlib.Path(__file__).resolve().parent.parent
SERVER = ROOT / "vendor/cm041/assistant_api/ical-server.py"
PROBE = ROOT / "scripts/box_walk_probes/probes/people_seed_and_retrieval.sh"
TOKEN = "fixture-service-token"
NS = "https://schema.ostler.ai/ontology#"
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))
STORE = ox.Store()


def _sparql_json(results):
    names = [v.value for v in results.variables]
    rows = []
    for sol in results:
        row = {}
        for n in names:
            t = sol[n]
            if t is not None:
                kind = "uri" if isinstance(t, ox.NamedNode) else "literal"
                row[n] = {"type": kind, "value": t.value}
        rows.append(row)
    return {"head": {"vars": names}, "results": {"bindings": rows}}


class Edges(BaseHTTPRequestHandler):
    """Oxigraph (/query, /update over STORE), Ollama /api/embed (delay set per
    test) and an empty Qdrant."""
    embed_delay = 0.0

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
            time.sleep(Edges.embed_delay)
            return self._send(200, json.dumps({"embeddings": [[0.0] * 768]}).encode())
        if self.path.startswith("/collections/"):
            return self._send(200, b'{"result": []}')
        try:
            if self.path.startswith("/query"):
                res = STORE.query(body, use_default_graph_as_union=False)
                return self._send(200, json.dumps(_sparql_json(res)).encode(),
                                  "application/sparql-results+json")
            if self.path.startswith("/update"):
                STORE.update(body)
                return self._send(204, b"")
        except Exception as exc:
            return self._send(400, str(exc).encode(), "text/plain")
        self._send(404, b"{}")


def _free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


EDGES = ThreadingHTTPServer(("127.0.0.1", 0), Edges)
threading.Thread(target=EDGES.serve_forever, daemon=True).start()
EDGE_URL = f"http://127.0.0.1:{EDGES.server_address[1]}"
WORK = pathlib.Path(tempfile.mkdtemp(prefix="assert-spool-"))
SPOOL = WORK / "assert_spool.db"


class Server:
    def __init__(self):
        self.port = _free_port()
        env = {k: v for k, v in os.environ.items() if "proxy" not in k.lower()}
        env.pop("OSTLER_DB_KEY", None)
        env.update({
            "OSTLER_API_PORT": str(self.port), "OXIGRAPH_URL": EDGE_URL,
            "QDRANT_URL": EDGE_URL, "EMBED_OLLAMA_URL": EDGE_URL,
            "OSTLER_SERVICE_TOKEN": TOKEN, "USER_ID": "fixtureowner",
            "USER_NAME": "Sam Smith", "HOME": str(WORK), "PWG_HOME": str(WORK / "pwg"),
            "NO_PROXY": "*", "PYTHONDONTWRITEBYTECODE": "1",
            "WIKI_BASE_URL": "http://wiki.example",
            "OSTLER_ASSERT_SEARCH_BUDGET_S": "1",
            "OSTLER_ASSERT_SPOOL_RESOLVE_BUDGET_S": "1",
            # The automatic resolver never fires in this test; passes are
            # driven through the status route, so each one is observable.
            "OSTLER_ASSERT_SPOOL_FIRST_SWEEP_S": "3600",
            "ASSERT_SPOOL_DB": str(SPOOL),
            "PYTHONPATH": os.pathsep.join([str(ROOT / "vendor/cm041"), str(ROOT / "vendor")]),
        })
        self.proc = subprocess.Popen([sys.executable, str(SERVER)], env=env,
                                     cwd=str(SERVER.parent),
                                     stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        self.url = f"http://127.0.0.1:{self.port}"
        for _ in range(150):
            if self.proc.poll() is not None:
                pytest.fail("ical-server exited: " + self.proc.stderr.read().decode()[-800:])
            try:
                OPENER.open(self.url + "/health", timeout=1).read()
                return
            except Exception:
                time.sleep(0.1)
        pytest.fail("ical-server did not come up")

    def stop(self):
        self.proc.kill()
        self.proc.wait(5)

    def call(self, method, path, payload=None, timeout=10):
        data = json.dumps(payload).encode() if payload is not None else None
        req = urllib.request.Request(self.url + path, data=data, method=method,
                                     headers={"Authorization": "Bearer " + TOKEN,
                                              "Content-Type": "application/json"})
        t = time.monotonic()
        try:
            with OPENER.open(req, timeout=timeout) as r:
                code, body = r.status, json.loads(r.read() or b"{}")
        except urllib.error.HTTPError as e:
            code, body = e.code, json.loads(e.read() or b"{}")
        return code, body, time.monotonic() - t

    def assert_fact(self, subject, fact):
        return self.call("POST", "/api/v1/memory/assert",
                         {"subject": subject, "fact_text": fact, "asserted_via": "test"})

    def resolve(self, spool_id, wait=15):
        """Kick resolver passes via the status route until the row closes."""
        deadline = time.monotonic() + wait
        while True:
            code, body, _ = self.call("GET", f"/api/v1/memory/assert/pending/{spool_id}")
            if body.get("state") != "pending" or time.monotonic() > deadline:
                return code, body
            time.sleep(0.3)


def _count(q):
    return len(list(STORE.query(q)))


def facts_with_text(text):
    return _count(f'SELECT ?f WHERE {{ ?f a <{NS}PersonFact> ; <{NS}factText> "{text}" }}')


def people_named(name):
    return _count(f'SELECT ?p WHERE {{ ?p a <{NS}Person> ; <{NS}displayName> "{name}" }}')


def spool_rows(where="1=1"):
    if not SPOOL.exists():
        return []
    c = sqlite3.connect(str(SPOOL))
    try:
        return c.execute(f"SELECT spool_id, state, privacy_level FROM assert_spool WHERE {where}").fetchall()
    finally:
        c.close()


@pytest.fixture(scope="module")
def hub():
    s = Server()
    yield s
    s.stop()


def test_control_a_responsive_model_mints_and_stores(hub):
    Edges.embed_delay = 0.0
    code, body, dt = hub.assert_fact("Catherine Stewart", "likes green tea")
    assert code == 200 and body["status"] == "created_person", (code, body)
    assert facts_with_text("likes green tea") == 1 and people_named("Catherine Stewart") == 1
    assert dt < 2, dt


def test_busy_model_spools_then_lands_exactly_once(hub):
    Edges.embed_delay = 4.0
    code, body, dt = hub.assert_fact("Philip Coe", "plays the cello")
    assert dt < 2.5, f"answered after {dt:.2f}s; the budget is 1s"
    assert code == 202 and body["status"] == "accepted_pending", (code, body)
    sid = body["spool_id"]
    assert [r[1] for r in spool_rows(f"spool_id = '{sid}'")] == ["pending"]
    assert facts_with_text("plays the cello") == 0, "nothing in the graph before resolving"

    # Still busy: a pass leaves it pending, writes nothing.
    code, st = hub.resolve(sid, wait=2)
    assert st["state"] == "pending", st
    assert facts_with_text("plays the cello") == 0

    Edges.embed_delay = 0.0
    code, st = hub.resolve(sid)
    assert st["state"] == "done" and st["person_uri"], st
    assert facts_with_text("plays the cello") == 1
    assert people_named("Philip Coe") == 1

    # A second pass is a no-op.
    hub.call("GET", f"/api/v1/memory/assert/pending/{sid}")
    time.sleep(1.0)
    assert facts_with_text("plays the cello") == 1 and people_named("Philip Coe") == 1


def test_restart_with_a_pending_row_lands_it_exactly_once(hub):
    Edges.embed_delay = 4.0
    code, body, _ = hub.assert_fact("Raj Brown", "runs on Sundays")
    assert code == 202, (code, body)
    sid = body["spool_id"]
    hub.stop()
    Edges.embed_delay = 0.0
    fresh = Server()
    try:
        code, st = fresh.resolve(sid)
        assert st["state"] == "done", st
        assert facts_with_text("runs on Sundays") == 1 and people_named("Raj Brown") == 1
        # Death between the write and the close: reopen the row by hand. The
        # next pass must find the fact already there and only close the row.
        c = sqlite3.connect(str(SPOOL))
        c.execute("UPDATE assert_spool SET state='pending', subject='Raj Brown', "
                  "fact_text='runs on Sundays' WHERE spool_id=?", (sid,))
        c.commit(); c.close()
        code, st = fresh.resolve(sid)
        assert st["state"] == "done", st
        assert facts_with_text("runs on Sundays") == 1 and people_named("Raj Brown") == 1
    finally:
        hub.__dict__.update(fresh.__dict__)


def test_the_recorded_level_is_the_level_written(hub):
    Edges.embed_delay = 4.0
    code, body, _ = hub.assert_fact("Tom Patel", "keeps bees")
    assert code == 202, (code, body)
    sid = body["spool_id"]
    assert spool_rows(f"spool_id = '{sid}'")[0][2] == "L1"
    # A row recorded at L3 must be written at L3, never at the default.
    c = sqlite3.connect(str(SPOOL))
    c.execute("UPDATE assert_spool SET privacy_level='L3' WHERE spool_id=?", (sid,))
    c.commit(); c.close()
    Edges.embed_delay = 0.0
    code, st = hub.resolve(sid)
    assert st["state"] == "done", st
    levels = [r["l"].value for r in STORE.query(
        f'SELECT ?l WHERE {{ ?f <{NS}factText> "keeps bees" ; <{NS}privacyLevel> ?l }}')]
    assert levels == ["L3"], levels


def test_busy_model_still_stores_against_an_exact_name_already_in_the_graph(hub):
    STORE.update(f'INSERT DATA {{ <{NS}person_fixturealex> a <{NS}Person> ; '
                 f'<{NS}displayName> "Alexandra Patel" . }}')
    Edges.embed_delay = 4.0
    code, body, dt = hub.assert_fact("Alexandra Patel", "speaks Portuguese")
    assert dt < 2.5, dt
    assert code == 200 and body["status"] == "stored", (code, body)
    assert body["person_uri"] == f"{NS}person_fixturealex"


def test_the_default_budget_leaves_the_walk_probe_room_to_hear_the_answer():
    src = SERVER.read_text()
    m = re.search(r'OSTLER_ASSERT_SEARCH_BUDGET_S", "([0-9.]+)"', src)
    assert m, "no default budget found in the vendored server"
    p = re.search(r'^HTTP_TIMEOUT="\$\{OSTLER_PROBE_HTTP_TIMEOUT:-([0-9]+)\}"', PROBE.read_text(), re.M)
    assert p, "could not read the probe's HTTP_TIMEOUT default"
    budget, probe = float(m.group(1)), float(p.group(1))
    assert budget + 5 <= probe, f"budget {budget}s + 5s margin exceeds the probe's {probe}s"
