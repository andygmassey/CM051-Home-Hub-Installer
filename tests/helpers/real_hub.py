"""Run the REAL vendored ical-server over a REAL SPARQL engine, on a synthetic graph.

The Hub handlers (people/context, person timeline, meeting/upcoming) are
vendor/cm041/assistant_api/ical-server.py, run unmodified as a subprocess. Its
only dependency on Oxigraph is HTTP POST /query and /update, which this module
serves from an in-memory pyoxigraph store. So a test drives the shipped handler
code and the shipped SPARQL, over HTTP, with a graph it seeded itself. No hand
written Hub JSON, no real data: every person here is fictional.

Needs `pyoxigraph` (pip install pyoxigraph). Raises RealHubUnavailable when it
or the server cannot start, so a caller reports CANNOT-RUN rather than a pass.
"""
import json
import os
import pathlib
import socket
import subprocess
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = pathlib.Path(__file__).resolve().parents[2]
ICAL = ROOT / "vendor/cm041/assistant_api/ical-server.py"
PWG = "http://pwg.example/ns#"  # replaced below from the server's own PWG_NS


class RealHubUnavailable(RuntimeError):
    pass


def _free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _sparql_json(results):
    import pyoxigraph as ox

    def term(t):
        if isinstance(t, ox.NamedNode):
            return {"type": "uri", "value": t.value}
        if isinstance(t, ox.BlankNode):
            return {"type": "bnode", "value": t.value}
        return {"type": "literal", "value": t.value}

    names = [v.value for v in results.variables]
    rows = []
    for sol in results:
        row = {}
        for n in names:
            t = sol[n]
            if t is not None:
                row[n] = term(t)
        rows.append(row)
    return {"head": {"vars": names}, "results": {"bindings": rows}}


class _Shim(BaseHTTPRequestHandler):
    store = None

    def log_message(self, *a):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        try:
            if self.path.startswith("/query"):
                res = self.store.query(body, use_default_graph_as_union=False)
                out = json.dumps(_sparql_json(res)).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/sparql-results+json")
            elif self.path.startswith("/update"):
                self.store.update(body)
                out = b""
                self.send_response(204)
            else:
                out = b"nope"
                self.send_response(404)
        except Exception as exc:  # a bad query is a 400, like Oxigraph
            out = str(exc).encode()
            self.send_response(400)
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)


class RealHub:
    """Context manager: `with RealHub() as hub:` then `hub.url`, `hub.update(sparql)`."""

    def __init__(self, extra_env=None):
        self.extra_env = extra_env or {}
        self.proc = None

    def __enter__(self):
        try:
            import pyoxigraph as ox
        except ImportError as exc:
            raise RealHubUnavailable(f"pyoxigraph not installed: {exc}")
        self.store = ox.Store()
        _Shim.store = self.store
        self.shim_port = _free_port()
        self.shim = ThreadingHTTPServer(("127.0.0.1", self.shim_port), _Shim)
        threading.Thread(target=self.shim.serve_forever, daemon=True).start()
        self.port = _free_port()
        env = dict(os.environ)
        env.update({
            "OSTLER_API_PORT": str(self.port),
            "OXIGRAPH_URL": f"http://127.0.0.1:{self.shim_port}",
            "WIKI_BASE_URL": "http://wiki.example",
            "USER_ID": "fixtureowner",
            "USER_NAME": "Sam Smith",
            "OSTLER_SERVICE_TOKEN": self.TOKEN,
            "OWNER_EMAILS": "sam@fixture.example",
            "HOME": os.environ.get("RH_HOME", "/tmp"),
            "PYTHONDONTWRITEBYTECODE": "1",
            "PYTHONPATH": os.pathsep.join([str(ROOT / "vendor/cm041"), str(ROOT / "vendor")]),
        })
        env.update(self.extra_env)
        self.proc = subprocess.Popen(
            [sys.executable, str(ICAL)], env=env, cwd=str(ICAL.parent),
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        self.url = f"http://127.0.0.1:{self.port}"
        for _ in range(100):
            if self.proc.poll() is not None:
                raise RealHubUnavailable(
                    "ical-server exited: " + self.proc.stderr.read().decode()[-800:])
            try:
                urllib.request.urlopen(self.url + "/health", timeout=1)
                return self
            except Exception:
                time.sleep(0.1)
        raise RealHubUnavailable("ical-server did not come up")

    def __exit__(self, *exc):
        if self.proc:
            self.proc.terminate()
            try:
                self.proc.wait(5)
            except Exception:
                self.proc.kill()
        self.shim.shutdown()

    def update(self, sparql):
        self.store.update(sparql)

    TOKEN = "fixture-service-token"

    def get(self, path):
        req = urllib.request.Request(
            self.url + path, headers={"Authorization": "Bearer " + self.TOKEN})
        with urllib.request.urlopen(req, timeout=20) as r:
            return json.loads(r.read())
