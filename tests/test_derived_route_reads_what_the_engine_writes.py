#!/usr/bin/env python3
"""The hub route reads exactly what the derive engine writes (producer -> route).

Two vendored halves of one feature, from two repos, that have never met:

  writer  vendor/cm019_preferences/.../derive_runner.py (CM019 engine + writer)
  reader  vendor/cm041/assistant_api/derived_preferences.py (CM041 #215, the
          builder behind GET /api/v1/preferences/derived, which the oa
          pwg_derived_preferences tool calls)

Each repo tests its half against a fixture. Nothing tested that the reader's
SPARQL matches the writer's triples. This runs the REAL writer into pyoxigraph,
then the REAL reader through an unscoped flat-bindings SELECT (the shape of
ical-server's _sparql_select_unscoped), and checks the response against the
shared contract example.

  arm 1  a written graph is served healthy: degraded=false, the derived labels
         come back, every item has exactly the contract's keys, and "because"
         resolves to the literal items' matchedTitle.
  arm 2  RED CONTROL: a run that derived nothing is served degraded with a
         reason, never a healthy-looking empty list.
  arm 3  the route is wired: ical-server.py routes the path to
         api_preferences_derived, and hub_contract.yaml declares it.
  arm 4  OVER HTTP: the REAL vendored ical-server, started as a subprocess with
         its Oxigraph pointed at a loopback stub that answers SPARQL from the
         graph the writer wrote. GET /api/v1/preferences/derived with the
         service token serves the derived label; without it, the route is not
         open (it sits behind the same lockdown as /api/v1/preferences).

Synthetic data only. Exit: 0 pass, 1 fail, 2 cannot-run.
"""

from __future__ import annotations

import importlib.util
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CM019 = REPO / "vendor" / "cm019_preferences"
SRC = CM019 / "services" / "enrich" / "src"
AAPI = REPO / "vendor" / "cm041" / "assistant_api"
CONTRACT = AAPI / "contract" / "derived_preferences_response.example.json"

for p in (SRC / "derive_runner.py", AAPI / "derived_preferences.py", CONTRACT):
    if not p.is_file():
        print(f"CANNOT-RUN: {p.relative_to(REPO)} is missing")
        sys.exit(2)
try:
    import pyoxigraph  # noqa: F401
    import pyshacl  # noqa: F401
    import yaml  # noqa: F401
except ImportError as exc:
    print(f"CANNOT-RUN: {exc}. pip install pyoxigraph rdflib pyshacl pyyaml")
    sys.exit(2)

sys.path.insert(0, str(CM019 / "services" / "common"))
sys.path.insert(0, str(SRC))
import derive_runner  # noqa: E402
from derive.model import DERIVED_GRAPH, ENRICH_NS, RDFS_NS  # noqa: E402
from derive.shacl import PyShaclValidator  # noqa: E402
from pyoxigraph import RdfFormat, Store  # noqa: E402

_spec = importlib.util.spec_from_file_location("derived_preferences", AAPI / "derived_preferences.py")
dp = importlib.util.module_from_spec(_spec)
sys.modules["derived_preferences"] = dp
_spec.loader.exec_module(dp)

NOW = datetime(2026, 10, 17, tzinfo=timezone.utc)
GENRE = "synthetic-genre-beta"
FAILS = []


def check(cond, msg):
    print(("  ok   " if cond else "  FAIL ") + msg)
    if not cond:
        FAILS.append(msg)


def nested(store, q):
    res = store.query(q)
    return [{v.value: {"value": s[v].value} for v in res.variables if s[v] is not None} for s in res]


def flat(store, q):
    """ical-server _sparql_select_unscoped shape: [{var: value}]."""
    return [{k: v["value"] for k, v in row.items()} for row in nested(store, q)]


class GraphStore:
    def __init__(self, s):
        self.s = s

    def update(self, u):
        self.s.update(u)

    def _select(self, q):
        return nested(self.s, q)

    def count_default_graph_triples(self):
        return int(self._select("SELECT (COUNT(*) AS ?c) WHERE { ?s ?p ?o }")[0]["c"]["value"])

    def count_graph_triples(self, g):
        return int(self._select("SELECT (COUNT(*) AS ?c) WHERE { GRAPH <%s> { ?s ?p ?o } }" % g)[0]["c"]["value"])

    def graph_triples_turtle(self, g):
        return ""


class Gateway:
    def __init__(self, s, points):
        self.s, self.points = s, points

    def sparql(self, q):
        return nested(self.s, q)

    def scroll(self, cats, fields):
        return [p for p in self.points if p["payload"]["category"] in cats]


class Mirror:
    def replace_all(self, points):
        pass


def seed(store, n):
    ttl = [f"@prefix enr: <{ENRICH_NS}> .", f"@prefix rdfs: <{RDFS_NS}> .",
           f'<urn:test:genre> rdfs:label "{GENRE}" .']
    points = []
    for i in range(n):
        pid = f"00000000-0000-0000-0000-0000000000a{i}"
        ttl.append(f'<urn:ostler:preference:{pid}> enr:hasGenre <urn:test:genre> ; '
                   f'enr:enrichmentConfidence 0.9 ; enr:matchedTitle "Synthetic Film {i}" .')
        points.append({"id": pid, "payload": {"category": "movie", "subject": f"Synthetic Film {i}",
                                              "source": "netflix", "strength": 0.9,
                                              "observed_at": "2026-10-01T00:00:00Z"}})
    store.load("\n".join(ttl).encode(), format=RdfFormat.TURTLE)
    return points


def produce(n):
    raw = Store()
    st = GraphStore(raw)
    status = Path(tempfile.mkdtemp(prefix="route-test-")) / "status.json"
    rc = derive_runner.run("synthetic_owner", Gateway(raw, seed(raw, n)), st,
                           PyShaclValidator(), Mirror(), status, now=NOW)
    return raw, rc

def _free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def serve_over_http(raw):
    """Boot the real ical-server against a SPARQL stub backed by ``raw``."""
    lock = threading.Lock()

    class Edge(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _sparql(self):
            if self.command == "POST":
                n = int(self.headers.get("Content-Length") or 0)
                body = self.rfile.read(n).decode("utf-8", "replace")
                ctype = self.headers.get("Content-Type", "")
                if "form-urlencoded" in ctype:
                    body = urllib.parse.parse_qs(body).get("query", [""])[0]
                return body
            return urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query).get("query", [""])[0]

        def do_POST(self):
            path = urllib.parse.urlsplit(self.path).path
            if path.endswith("/query"):
                q = self._sparql()
                try:
                    with lock:
                        res = raw.query(q)
                        names = [v.value for v in res.variables]
                        rows = [{v.value: {"type": "literal", "value": sol[v].value}
                                 for v in res.variables if sol[v] is not None} for sol in res]
                    out = {"head": {"vars": names}, "results": {"bindings": rows}}
                except Exception:
                    out = {"head": {"vars": []}, "results": {"bindings": []}}
            else:
                out = {"result": {"points": [], "next_page_offset": None}, "status": "ok"}
            data = json.dumps(out).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        do_GET = do_POST
        do_PUT = do_POST

    edge = ThreadingHTTPServer(("127.0.0.1", _free_port()), Edge)
    threading.Thread(target=edge.serve_forever, daemon=True).start()
    edge_url = "http://127.0.0.1:%d" % edge.server_address[1]
    work = Path(tempfile.mkdtemp(prefix="route-http-"))
    port = _free_port()
    env = {k: v for k, v in os.environ.items() if "proxy" not in k.lower()}
    env.pop("OSTLER_DB_KEY", None)
    env.update({
        "OSTLER_API_PORT": str(port), "OXIGRAPH_URL": edge_url, "QDRANT_URL": edge_url,
        "EMBED_OLLAMA_URL": edge_url, "OSTLER_SERVICE_TOKEN": "fixture-service-token",
        "USER_ID": "fixtureowner", "USER_NAME": "Sam Smith", "HOME": str(work),
        "PWG_HOME": str(work / "pwg"), "NO_PROXY": "*", "PYTHONDONTWRITEBYTECODE": "1",
        "WIKI_BASE_URL": "http://wiki.example",
        "PYTHONPATH": os.pathsep.join([str(REPO / "vendor/cm041"), str(REPO / "vendor")]),
    })
    server = AAPI / "ical-server.py"
    proc = subprocess.Popen([sys.executable, str(server)], env=env, cwd=str(AAPI),
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    return proc, edge, "http://127.0.0.1:%d" % port


def get(url, token=None):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"} if token else {})
    try:
        with opener.open(req, timeout=10) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def arm4(raw):
    print("arm 4: over HTTP, the real ical-server serves the derived graph")
    proc, edge, url = serve_over_http(raw)
    try:
        for _ in range(150):
            if proc.poll() is not None:
                print("CANNOT-RUN: ical-server exited: " + proc.stderr.read().decode()[-600:])
                sys.exit(2)
            try:
                get(url + "/health")
                break
            except Exception:
                time.sleep(0.1)
        else:
            print("CANNOT-RUN: ical-server did not come up")
            sys.exit(2)
        code, body = get(url + "/api/v1/preferences/derived?limit=8&min_confidence=0", "fixture-service-token")
        check(code == 200, f"GET /api/v1/preferences/derived -> {code}")
        try:
            data = json.loads(body)
        except Exception:
            data = {}
        check(data.get("degraded") is False and GENRE in [i.get("label") for i in data.get("items", [])],
              f"served the derived label over HTTP (degraded={data.get('degraded')}, {data.get('cannot_check')})")
        code_noauth, _ = get(url + "/api/v1/preferences/derived")
        check(code_noauth in (401, 403), f"without the service token the route is closed ({code_noauth})")
    finally:
        proc.kill()
        proc.wait(5)
        edge.shutdown()


def main():
    contract = json.loads(CONTRACT.read_text())
    keys = set(contract["items"][0])

    print("arm 1: what the engine writes, the route serves")
    raw, rc = produce(5)
    check(rc == 0, f"producer wrote (rc={rc})")
    resp = dp.build_derived_preferences_response(
        dp.DerivedGraphReader(lambda q: flat(raw, q)), "synthetic_owner", min_confidence=0.0)
    check(resp["degraded"] is False, f"served healthy (degraded={resp['degraded']}, {resp.get('cannot_check')})")
    labels = [i["label"] for i in resp["items"]]
    check(GENRE in labels, f"derived label served: {labels}")
    check(all(set(i) == keys for i in resp["items"]), f"every item has exactly the contract keys {sorted(keys)}")
    check(set(resp) == set(contract), f"top-level keys match the contract: {sorted(resp)}")
    because = next((i["because"] for i in resp["items"] if i["label"] == GENRE), [])
    check(because and all(b.startswith("Synthetic Film") for b in because),
          f"'because' resolves derivedFrom -> matchedTitle: {because}")

    print("arm 2: RED CONTROL -- nothing derived is served degraded, not empty-and-healthy")
    raw2, rc2 = produce(1)
    check(rc2 == 0, "producer ran (proven empty)")
    resp2 = dp.build_derived_preferences_response(
        dp.DerivedGraphReader(lambda q: flat(raw2, q)), "synthetic_owner", min_confidence=0.0)
    check(resp2["degraded"] is True and resp2["items"] == [] and resp2.get("cannot_check"),
          f"degraded with a reason: {resp2.get('cannot_check')!r}")

    print("arm 3: the route is wired and declared")
    srv = (AAPI / "ical-server.py").read_text()
    check('if parsed.path == "/api/v1/preferences/derived":' in srv
          and "result = api_preferences_derived(limit=limit, min_confidence=min_conf)" in srv,
          "do_GET routes the path to api_preferences_derived")
    check(dp.DERIVED_GRAPH == DERIVED_GRAPH and dp.ENRICH_NS == ENRICH_NS,
          "the route reads the graph and overlay namespace the writer uses")
    hc = json.loads((AAPI / "hub_contract.yaml").read_text())
    routes = hc.get("routes", hc) if isinstance(hc, dict) else hc
    check(any(isinstance(r, dict) and r.get("id") == "ical GET /api/v1/preferences/derived" for r in routes),
          "hub_contract.yaml declares ical GET /api/v1/preferences/derived")

    arm4(raw)

    print(f"\n{'FAILED: ' + str(len(FAILS)) if FAILS else 'all passed'}")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
