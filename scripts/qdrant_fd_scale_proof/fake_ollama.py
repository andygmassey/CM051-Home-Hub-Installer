"""Stand-in for Ollama /api/embed, for scripts/qdrant_fd_scale_proof.sh only.

Answers each request with a deterministic 768-dim vector after a fixed delay
that models the real embed time, so the CM024 `embed` step writes to Qdrant at
the pace it does on a box. Nothing else about the hydrate path is replaced.

argv: <port> <delay seconds>
"""
import hashlib
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT, DELAY = int(sys.argv[1]), float(sys.argv[2])


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        text = body.get("input")
        text = text if isinstance(text, str) else json.dumps(text)
        h = hashlib.sha256((text or "").encode()).digest()
        vec = [((h[i % 32] + i) % 251) / 251.0 for i in range(768)]
        time.sleep(DELAY)
        out = json.dumps({"model": body.get("model"), "embeddings": [vec], "prompt_eval_count": 10}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
