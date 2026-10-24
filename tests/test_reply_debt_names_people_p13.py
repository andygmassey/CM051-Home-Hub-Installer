"""P13 (v1.0.118 MUST): reply debt names PEOPLE, never the owner, never digits.

v1.0.117 walk: the 18:00 brief said "Waiting on a reply from you" and listed
five raw phone numbers, one of them the OWNER'S OWN mobile. Root causes, in the
shipped tree:

* vendor/cm048_pipeline/src/reply_debt_adapters.py named a 1:1 thread
  ``display_name or handle``; a 1:1 chat has no display_name, so the
  counterpart WAS the raw handle, and nothing mapped a handle to Contacts
  (ical-server calls compute_reply_debts() with no lookup at all);
* its owner test, ``is_owner_handle``, reads only OSTLER_IMESSAGE_SELF_HANDLES,
  which the ical-server plist never sets, so the owner's self-chat inbound
  copies counted as somebody waiting.

This drives the REAL vendored ical-server ``api_reply_debt`` in a child
process (the same harness as test_reply_debt_never_opens_protected_data.py,
audit hook included) against a reply-debt snapshot shaped like the walk, with
the People graph served over HTTP by a stub SPARQL endpoint on an ephemeral
port, so the store boundary is crossed for real.

Fictional cast only: Sam Doe is the owner, Jane Smith and Tom Jones are
contacts. Reserved numbers (+44 7700 900xxx, +1 202-555-01xx) and example.*.
"""
from __future__ import annotations

import importlib.util
import json
import os
import re
import subprocess
import sys
import threading
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location(
    "_rd_harness", ROOT / "tests" / "test_reply_debt_never_opens_protected_data.py"
)
H = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(H)

GRAPH_ROWS = [
    {"p": "urn:test:owner", "is_owner": "true", "name": "Sam", "type": "icloud_contact_uid", "val": "OWNER-CARD"},
    {"p": "urn:test:mecard", "name": "Sam Doe", "type": "phone", "val": "+447700900001"},
    {"p": "urn:test:mecard", "name": "Sam Doe", "type": "phone", "val": "+1 202-555-0101"},
    {"p": "urn:test:jane", "name": "Jane Smith", "type": "phone", "val": "07700 900123"},
    {"p": "urn:test:tom", "name": "Tom Jones", "type": "email", "val": "Tom.Jones@example.org"},
    {"p": "urn:test:provisional", "name": "+447700900777", "type": "phone", "val": "+447700900777"},
]

OWNER_ENV = {
    "USER_PHONE": "+44 7700 900001",
    "USER_EMAIL": "sam.doe@example.com",
    "USER_NAME": "Sam Doe",
}

WALK_HANDLES = [
    "+447700900123",          # Jane, carded in national form
    "+447700900999",          # a real number not in Contacts
    "+447700900001",          # the owner's self-chat inbound copy
    "+12025550101",           # the owner's second number (graph only)
    "6250123",                # 7-digit SMS short code
    "BANK",                   # alphanumeric sender id
    "tom.jones@example.org",  # carded address
]


class _Sparql(BaseHTTPRequestHandler):
    hits: list = []

    def do_POST(self):  # noqa: N802
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode()
        _Sparql.hits.append(body)
        out = {"results": {"bindings": [
            {k: {"type": "literal", "value": v} for k, v in r.items()} for r in GRAPH_ROWS
        ]}}
        data = json.dumps(out).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/sparql-results+json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass


@pytest.fixture()
def store():
    _Sparql.hits = []
    srv = HTTPServer(("127.0.0.1", 0), _Sparql)
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    yield f"http://127.0.0.1:{srv.server_address[1]}"
    srv.shutdown()


@pytest.fixture()
def now() -> datetime:
    return datetime.now(timezone.utc).replace(microsecond=0)


@pytest.fixture()
def home(tmp_path: Path) -> Path:
    h = tmp_path / "home"
    h.mkdir()
    return h


def walk_snapshot(now: datetime) -> dict:
    return {
        "schema": 1, "status": "ok", "generated_at": now.isoformat(), "lookback_days": 90,
        "threads": [
            {"chat_id": f"iMessage;-;{h}", "display_name": None, "participants": [h],
             "is_group": False,
             "last": {"text": "Are you free on Friday?", "is_from_me": False, "sender": h,
                      "timestamp": (now - timedelta(days=3)).isoformat()}}
            for h in WALK_HANDLES
        ],
    }


def run_endpoint(home: Path, extra_env: dict) -> dict:
    env = {
        "HOME": str(home),
        "PATH": os.environ.get("PATH", ""),
        "PYTHONDONTWRITEBYTECODE": "1",
        "USER_ID": "operator",
        "REPLY_DEBT_PROJECT_DIR": str(H.CM048),
        "NO_PROXY": "*",
        **extra_env,
    }
    proc = subprocess.run(
        [sys.executable, "-c", H._CHILD, str(H.SERVER), json.dumps(H.PROTECTED), "endpoint"],
        env=env, cwd=str(home), capture_output=True, text=True, timeout=120,
    )
    assert proc.returncode == 0, f"child failed rc={proc.returncode}\n{proc.stderr[-3000:]}"
    return json.loads(proc.stdout.strip().splitlines()[-1])


def test_the_walk_shape_names_people_and_drops_the_owner_and_short_codes(home, now, store):
    H.connect(home)
    H.write_snapshot(home, walk_snapshot(now))
    out = run_endpoint(home, {**OWNER_ENV, "OXIGRAPH_URL": store})
    assert out["opened"] == [], out["opened"]
    assert _Sparql.hits, "the People graph was never queried: the store boundary is not exercised"
    p = out["payload"]
    assert p["degraded"] is False, p
    assert p["names_degraded"] == "", p
    assert sorted(d["person_name"] for d in p["debts"]) == ["Jane Smith", "Tom Jones", "Unknown number"], p
    assert p["excluded"] == {"owner": 2, "not_a_person": 2}, p
    line = p["brief_line"]
    assert "Jane Smith" in line and "someone not in your contacts" in line, line
    assert not re.search(r"\d{5,}", line), line
    for d in p["debts"]:
        assert not re.search(r"\d{5,}", d["person_name"]), d


def test_a_dead_store_still_drops_the_owner_and_never_prints_digits(home, now):
    H.connect(home)
    H.write_snapshot(home, walk_snapshot(now))
    # A closed port: the graph cannot be read.
    out = run_endpoint(home, {**OWNER_ENV, "OXIGRAPH_URL": "http://127.0.0.1:9"})
    p = out["payload"]
    assert p["names_degraded"].startswith("people_graph_unreachable"), p
    # The configured mobile is still the owner; the second number is only
    # known from the graph, so it now reads as an unsaved number.
    assert p["excluded"] == {"owner": 1, "not_a_person": 2}, p
    assert not re.search(r"\d{5,}", p["brief_line"]), p["brief_line"]
    assert all(d["person_name"] in ("Unknown number", "Unknown sender") for d in p["debts"]), p
    # Not "not in your contacts": the names could not be looked up at all.
    assert "names could not be looked up" in p["brief_line"], p["brief_line"]
    assert "not in your contacts" not in p["brief_line"], p["brief_line"]


def test_control_without_the_owner_env_the_owner_is_not_dropped(home, now, store):
    """Proves the owner assertion above can fail: with no owner identity the
    owner's own number is just another unsaved number."""
    H.connect(home)
    H.write_snapshot(home, walk_snapshot(now))
    out = run_endpoint(home, {"OXIGRAPH_URL": store})
    assert out["payload"]["excluded"]["owner"] == 0, out["payload"]


# ── Archie's review of CM048 #104: two mutants survived. Same kills here,
#    through the real vendored ical-server. ──────────────────────────────

def test_self_handles_alone_mark_the_owner(home, now, store):
    """OSTLER_IMESSAGE_SELF_HANDLES is one of the owner's handle sources;
    dropping it from handle_identity.OWNER_HANDLE_ENV_VARS survived the suite."""
    H.connect(home)
    H.write_snapshot(home, walk_snapshot(now))
    out = run_endpoint(home, {"OSTLER_IMESSAGE_SELF_HANDLES": "+447700900001",
                              "OXIGRAPH_URL": store})
    p = out["payload"]
    assert p["excluded"]["owner"] >= 1, p
    assert all("900001" not in (d.get("thread_id") or "") for d in p["debts"]), p


def test_unresolved_people_are_one_counted_line_not_one_row_each(home, now, store):
    """Listing each unresolved debt as its own row beside the count survived
    the suite. Three unsaved numbers and one contact: exactly two rows."""
    snap = walk_snapshot(now)
    snap["threads"] = [t for t in snap["threads"] if t["chat_id"].endswith("+447700900123")]
    for h in ("+447700900997", "+447700900998", "+447700900999"):
        snap["threads"].append(
            {"chat_id": f"iMessage;-;{h}", "display_name": None, "participants": [h],
             "is_group": False,
             "last": {"text": "Are you free on Friday?", "is_from_me": False, "sender": h,
                      "timestamp": (now - timedelta(days=3)).isoformat()}})
    H.connect(home)
    H.write_snapshot(home, snap)
    p = run_endpoint(home, {**OWNER_ENV, "OXIGRAPH_URL": store})["payload"]
    rows = p["brief_line"].split("\n")[1:]
    assert rows.count("  - 3 people not in your contacts") == 1, p["brief_line"]
    assert len(rows) == 2, p["brief_line"]
    assert "Unknown number" not in p["brief_line"], p["brief_line"]
