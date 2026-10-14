"""A tiny Qdrant stand-in for forget tests: answers every POST with a chosen
status and records what was asked. Loopback only.

Forget reports done only when BOTH stores were purged, so a test that used to
point QDRANT_URL at a closed port (and was told "forgotten") now needs a
Qdrant that actually accepts the delete. ``status`` 200 accepts, 404 is
"collection does not exist", anything else is a failure.
"""
from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class FakeQdrant:
    def __init__(self, status: int = 200):
        self.status = status
        self.deletes = []
        outer = self

        class H(BaseHTTPRequestHandler):
            def do_POST(self):
                n = int(self.headers.get("Content-Length") or 0)
                body = self.rfile.read(n)
                outer.deletes.append((self.path, json.loads(body or b"{}")))
                if outer.status == 200:
                    payload = b'{"status":"ok","result":{"status":"completed"}}'
                elif outer.status == 404:
                    payload = b'{"status":{"error":"Not found: Collection `people` does not exist!"}}'
                else:
                    payload = b'{"status":{"error":"boom"}}'
                self.send_response(outer.status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, *a):
                pass

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.url = "http://127.0.0.1:%d" % self.httpd.server_address[1]
        self._t = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self._t.start()

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()
