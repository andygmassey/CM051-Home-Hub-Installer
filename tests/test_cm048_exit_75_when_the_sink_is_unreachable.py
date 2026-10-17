"""pwg-convo process exits 75 (EX_TEMPFAIL) when the model/gateway cannot be
REACHED, and 1 when it REJECTED this item. The catch-up adapters read 75 as an
outage (no poison attempt) and 1 as a rejection (counts toward quarantine).

Real subprocess against the real CLI; the sink is a closed port, or a stub that
answers 400. Synthetic transcript only."""
from __future__ import annotations

import http.server
import json
import os
import subprocess
import sys
import threading
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PKG = REPO / "vendor" / "cm048_pipeline"

RUNNER = (
    "import sys; sys.path.insert(0, '.');"
    "from src import processor; processor.BASE_DELAY_SECONDS = 0;"
    "from src import cli; sys.exit(cli.main(sys.argv[1:]))"
)


def _run(tmp_path, ollama_url):
    t, m = tmp_path / "t.md", tmp_path / "m.json"
    t.write_text("Alice: hello\nBob: hi there\n")
    m.write_text(json.dumps({"conversation_id": "2026-01-01_synthetic", "date": "2026-01-01",
                             "source": "test", "participants": ["Alice", "Bob"]}))
    env = dict(os.environ, OSTLER_OLLAMA_URL=ollama_url, OSTLER_STATE_DIR=str(tmp_path / "state"),
               OSTLER_USER_ID="synthetic-user")
    return subprocess.run([sys.executable, "-c", RUNNER, "process", str(t), str(m)],
                          cwd=PKG, env=env, capture_output=True, text=True, timeout=120)


def test_a_refused_connection_exits_75(tmp_path):
    r = _run(tmp_path, "http://127.0.0.1:1")
    assert r.returncode == 75, f"rc={r.returncode} err={r.stderr[-400:]}"


class _Reject(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.send_response(400)
        self.end_headers()
        self.wfile.write(b"{}")

    def log_message(self, *a):
        pass


def test_a_server_that_rejects_the_item_does_not_exit_75(tmp_path):
    srv = http.server.HTTPServer(("127.0.0.1", 0), _Reject)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        r = _run(tmp_path, f"http://127.0.0.1:{srv.server_port}")
    finally:
        srv.shutdown()
    assert r.returncode not in (0, 75), f"rc={r.returncode} err={r.stderr[-400:]}"
