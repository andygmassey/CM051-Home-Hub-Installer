"""A real HTTP socket speaking the two Oxigraph endpoints the people code uses
(``POST /query`` and ``POST /update``), backed by pyoxigraph's in-memory Store:
the same engine as the Hub's store, run without a union default graph, so an
unqualified query sees the default graph only.

Why a socket and not a stub: the forget handler (urllib), the identity
resolver (httpx) and every syncer's own writer (httpx) reach the store by
different clients. One fake behind a URL means each of them runs unmodified.

Synthetic data only.
"""
from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pyoxigraph

PWG = "https://schema.ostler.ai/ontology#"
PREFIXES = (
    "PREFIX pwg: <https://schema.ostler.ai/ontology#>\n"
    "PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>\n"
    "PREFIX foaf: <http://xmlns.com/foaf/0.1/>\n"
    "PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>\n"
)


class FakeOxigraph:
    def __init__(self) -> None:
        self.ds = pyoxigraph.Store()
        self.lock = threading.Lock()
        self.updates: list[str] = []
        outer = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):  # silence
                pass

            def do_POST(self):  # noqa: N802
                n = int(self.headers.get("Content-Length") or 0)
                body = self.rfile.read(n).decode("utf-8")
                try:
                    if self.path.startswith("/query"):
                        with outer.lock:
                            res = outer.ds.query(body)
                            if isinstance(res, pyoxigraph.QueryBoolean):
                                out = json.dumps({"head": {}, "boolean": bool(res)}).encode()
                            else:
                                out = res.serialize(format=pyoxigraph.QueryResultsFormat.JSON)
                        self.send_response(200)
                        self.send_header("Content-Type", "application/sparql-results+json")
                        self.end_headers()
                        self.wfile.write(out if isinstance(out, bytes) else out.encode())
                    elif self.path.startswith("/update"):
                        with outer.lock:
                            outer.updates.append(body)
                            outer.ds.update(body)
                        self.send_response(204)
                        self.end_headers()
                    else:
                        self.send_response(404)
                        self.end_headers()
                except Exception as exc:  # surface parse errors to the client
                    self.send_response(400)
                    self.end_headers()
                    self.wfile.write(str(exc).encode())

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.url = f"http://127.0.0.1:{self.httpd.server_address[1]}"
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def close(self) -> None:
        self.httpd.shutdown()
        self.httpd.server_close()

    # -- test conveniences -------------------------------------------------
    def update(self, sparql: str) -> None:
        with self.lock:
            self.ds.update(PREFIXES + sparql)

    def ask(self, sparql: str) -> bool:
        with self.lock:
            return bool(self.ds.query(PREFIXES + sparql))

    def person_names(self) -> list[str]:
        with self.lock:
            rows = self.ds.query(
                PREFIXES
                + "SELECT ?n WHERE { ?p a pwg:Person . OPTIONAL { ?p pwg:displayName ?n } }"
            )
            return sorted(r["n"].value if r["n"] is not None else "" for r in rows)

    def person_count(self) -> int:
        return len(self.person_names())
