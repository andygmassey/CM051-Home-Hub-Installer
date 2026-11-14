#!/usr/bin/env python3
"""GET /api/v1/preferences/derived is never blank while the first pass runs.

A fresh box's derived graph is empty for tens of minutes (the first derive pass
is slow), and the answer was a bare `items: []` with a cannot_check reason. The
"What you like" page showed nothing. Now an answer with no items also carries
`still_learning`: how many interests the interest profile holds, so the page can
say "Still learning: N interests found so far".

Drives the REAL ical-server.py as a subprocess (the same way
test_api_list_pagination_is_additive.py does), with a stub Oxigraph on localhost
and a synthetic interest profile. Stdlib only.

  arm 1  an EMPTY derived graph: items [] and still_learning reports the
         profile's 5 non-sensitive interests in its count and text.
  arm 2  CONTROL: a derived graph WITH a node serves items and carries no
         still_learning key (the note must not appear once there is content).
  arm 3  an UNREACHABLE store (the degraded path): still_learning is present too.
  arm 4  a FRESH in_progress status file (the first pass is running): still
         learning, not stale.
  arm 5  a 4-hour-old in_progress status file (the pass was killed part-way):
         still_learning says the last preferences pass did not finish
         (status "stale"), never "still learning" forever.
  arm 6  CONTROL: a stale record with a node served: items, no note.

ICAL_SERVER may point at another ical-server.py (that is how the red on
origin/main was watched). Exit: 0 pass, 1 real failure, 2 cannot-run.
"""

from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SERVER = Path(os.environ.get("ICAL_SERVER") or (REPO / "vendor/cm041/assistant_api/ical-server.py"))
TOKEN = "fixture-service-token"
NOTE_TEXT = "Still learning: {} interests found so far"

if not SERVER.is_file():
    print(f"CANNOT-RUN: {SERVER} is missing")
    sys.exit(2)

PASS = 0
FAIL = 0


def check(cond: bool, msg: str) -> None:
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  PASS {msg}")
    else:
        FAIL += 1
        print(f"  FAIL {msg}")


# A node the stub returns for every SPARQL query: one like, broad tier, L1.
ONE_NODE = {
    "s": {"type": "uri", "value": "urn:synthetic:derived:node-1"},
    "dimension": {"type": "literal", "value": "media.film.genre"},
    "subject": {"type": "literal", "value": "synthetic-genre-beta"},
    "strength": {"type": "literal", "value": "0.8"},
    "confidence": {"type": "literal", "value": "0.9"},
    "category": {"type": "literal", "value": "films"},
    "tier": {"type": "literal", "value": "broad"},
    "privacy": {"type": "literal", "value": "L1"},
}


class StubOxigraph(BaseHTTPRequestHandler):
    bindings: list = []

    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        self.rfile.read(n)
        data = json.dumps({"head": {"vars": []},
                           "results": {"bindings": type(self).bindings}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/sparql-results+json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


PROFILE = {
    "generated_at": "2026-01-01T00:00:00Z",
    "schema_version": 1,
    "interests": [{"name": f"Synthetic Topic {i}", "domain": "Music", "score": float(i),
                   "confidence": 0.9, "polarity": "like", "sources": ["fixture"],
                   "evidence": "e"} for i in range(1, 6)],
}


def _status_record(hours_ago: float) -> dict:
    """What derive_runner writes while a pass runs, stamped ``hours_ago``."""
    stamp = (datetime.now(timezone.utc) - timedelta(hours=hours_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")
    return {"schema": 1, "last_run_at": stamp, "outcome": "in_progress",
            "progress": {"readers_done": 2, "readers_total": 8, "items_so_far": 9,
                         "started_at": stamp, "updated_at": stamp}}


@contextmanager
def server(oxi_url: str, status: dict | None = None):
    work = Path(tempfile.mkdtemp(prefix="still-learning-"))
    prof = work / "interest_profile.json"
    prof.write_text(json.dumps(PROFILE))
    ostler = work / "ostler"
    if status is not None:
        (ostler / "state").mkdir(parents=True)
        (ostler / "state" / "derived-preferences.json").write_text(json.dumps(status))
    port = _free_port()
    env = {k: v for k, v in os.environ.items() if "proxy" not in k.lower()}
    env.pop("OSTLER_DB_KEY", None)
    env.update({
        "OSTLER_API_PORT": str(port), "OXIGRAPH_URL": oxi_url, "OSTLER_DIR": str(ostler),
        "QDRANT_URL": oxi_url, "EMBED_OLLAMA_URL": oxi_url,
        "OSTLER_SERVICE_TOKEN": TOKEN, "USER_ID": "fixtureowner",
        "USER_NAME": "synthetic-owner", "HOME": str(work), "PWG_HOME": str(work / "pwg"),
        "OSTLER_INTEREST_PROFILE": str(prof), "NO_PROXY": "*",
        "PYTHONDONTWRITEBYTECODE": "1", "WIKI_BASE_URL": "http://wiki.example",
        "PYTHONPATH": os.pathsep.join([str(SERVER.parent.parent), str(SERVER.parent.parent.parent)]),
    })
    proc = subprocess.Popen([sys.executable, str(SERVER)], env=env, cwd=str(SERVER.parent),
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    url = f"http://127.0.0.1:{port}"
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    for _ in range(150):
        if proc.poll() is not None:
            raise RuntimeError("ical-server exited: " + proc.stderr.read().decode()[-600:])
        try:
            opener.open(url + "/health", timeout=1).read()
            break
        except Exception:
            time.sleep(0.1)
    else:
        raise RuntimeError("ical-server did not come up")
    try:
        yield url, opener
    finally:
        proc.kill()
        proc.wait(5)


def get_derived(url: str, opener) -> dict:
    req = urllib.request.Request(url + "/api/v1/preferences/derived",
                                 headers={"Authorization": "Bearer " + TOKEN})
    with opener.open(req, timeout=20) as r:
        return json.loads(r.read())


def main() -> int:
    try:
        stub = ThreadingHTTPServer(("127.0.0.1", _free_port()), StubOxigraph)
    except OSError as exc:
        print(f"CANNOT-RUN: could not bind a stub store: {exc}")
        return 2
    threading.Thread(target=stub.serve_forever, daemon=True).start()
    stub_url = f"http://127.0.0.1:{stub.server_address[1]}"
    try:
        print("arm 1: an empty derived graph still says how far it has got")
        StubOxigraph.bindings = []
        with server(stub_url) as (url, op):
            body = get_derived(url, op)
        note = body.get("still_learning") or {}
        check(body.get("items") == [], "items is empty (nothing derived yet)")
        check(note.get("interests_so_far") == 5, f"interests_so_far={note.get('interests_so_far')} (want 5)")
        check(note.get("text") == NOTE_TEXT.format(5), f"text={note.get('text')!r}")

        print("arm 2: CONTROL -- once there is a node, no still_learning note")
        StubOxigraph.bindings = [ONE_NODE]
        with server(stub_url) as (url, op):
            body = get_derived(url, op)
        check(len(body.get("items") or []) >= 1, f"items served ({len(body.get('items') or [])})")
        check("still_learning" not in body, "no still_learning key when items are served")

        print("arm 3: an unreachable store still answers with the note")
        dead = f"http://127.0.0.1:{_free_port()}"
        with server(dead) as (url, op):
            body = get_derived(url, op)
        check(body.get("degraded") is True and body.get("items") == [],
              "degraded with no items (the silent-empty rule holds)")
        check((body.get("still_learning") or {}).get("interests_so_far") == 5,
              "still_learning present with the profile count")

        print("arm 4: a fresh in-progress pass is still learning, not stale")
        StubOxigraph.bindings = []
        with server(stub_url, status=_status_record(0.01)) as (url, op):
            body = get_derived(url, op)
        note = body.get("still_learning") or {}
        check(note.get("text") == NOTE_TEXT.format(5) and "status" not in note,
              f"fresh pass -> still learning, note={note}")

        print("arm 5: a killed pass (4h old) says it did not finish, not still learning")
        StubOxigraph.bindings = []
        with server(stub_url, status=_status_record(4)) as (url, op):
            body = get_derived(url, op)
        note = body.get("still_learning") or {}
        check(note.get("status") == "stale", f"status={note.get('status')!r} (want stale)")
        check(note.get("text") == "Last preferences pass did not finish",
              f"text={note.get('text')!r}")
        check(note.get("interests_so_far") == 5, f"interests_so_far={note.get('interests_so_far')} (want 5)")

        print("arm 6: CONTROL -- a stale record with a node served carries no note")
        StubOxigraph.bindings = [ONE_NODE]
        with server(stub_url, status=_status_record(4)) as (url, op):
            body = get_derived(url, op)
        check(len(body.get("items") or []) >= 1 and "still_learning" not in body,
              "items served, no still_learning key")
    finally:
        stub.shutdown()

    print(f"\n{PASS} passed, {FAIL} failed")
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
