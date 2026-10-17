"""A tiny Qdrant stand-in for forget tests: answers every POST with a chosen
status and records what was asked. Loopback only.

Forget reports done only when BOTH stores were purged, so a test that used to
point QDRANT_URL at a closed port (and was told "forgotten") now needs a
Qdrant that actually accepts the delete. ``status`` 200 accepts, 404 is
"collection does not exist", anything else is a failure.

``script`` (optional) is a list of statuses for successive DELETE calls, the
last one repeating, so a test can say "500 first, then 200". ``held`` is how
many vectors the read-back count query reports (0 = gone). ``bare404`` makes a
404 carry a body that does NOT say a collection is missing.
"""
from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class FakeQdrant:
    def __init__(self, status: int = 200):
        self.status = status
        self.script = []
        self.held = 0
        self.bare404 = False
        self.deletes = []
        self.counts = []
        outer = self

        class H(BaseHTTPRequestHandler):
            def do_POST(self):
                n = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(n) or b"{}")
                if "/points/count" in self.path:
                    outer.counts.append((self.path, body))
                    status = 200
                    payload = json.dumps({"result": {"count": outer.held}}).encode()
                else:
                    outer.deletes.append((self.path, body))
                    status = outer.status
                    if outer.script:
                        status = outer.script.pop(0) if len(outer.script) > 1 else outer.script[0]
                    if status == 200:
                        payload = b'{"status":"ok","result":{"status":"completed"}}'
                    elif status == 404 and outer.bare404:
                        payload = b'404 page not found'
                    elif status == 404:
                        payload = b'{"status":{"error":"Not found: Collection `people` does not exist!"}}'
                    else:
                        payload = b'{"status":{"error":"boom"}}'
                self.send_response(status)
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
