"""Meeting briefs: a brief that could not be sent must not read as success.

V20: the calendar source defaulted to the Doctor port with no credential, so
the meeting syncer fetched a 404/401 and nothing said why.
V21: the sender exited 0 on every CANNOT-RUN arm (no token, hub unreachable,
empty reply, degraded hub, unreadable degraded flag), so launchd recorded
success and the Doctor card never appeared. Synthetic data only.
"""
import importlib
import json
import os
import re
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "vendor" / "cm041"))

CONFIG = """[[cron.jobs]]
id = "morning-brief"
schedule = "0 9 * * *"
delivery = { mode = "announce", channel = "imessage", to = "synthetic-owner" }
"""


def _sender_text():
    text = (ROOT / "install.sh").read_text(encoding="utf-8")
    m = re.search(r"<<'BRIEFEOF'\n(.*?)\nBRIEFEOF\n", text, re.S)
    assert m, "sender heredoc not found in install.sh"
    return m.group(1)


class _Hub:
    def __init__(self, body):
        self.body = body
        self.seen_auth = []
        outer = self

        class H(BaseHTTPRequestHandler):
            def do_GET(self):
                outer.seen_auth.append(self.headers.get("Authorization"))
                if self.headers.get("Authorization") != "Bearer synthetic-token":
                    self.send_response(401)
                    self.end_headers()
                    return
                self.send_response(200)
                self.end_headers()
                self.wfile.write(outer.body.encode())

            def log_message(self, *a):
                pass

        self.srv = HTTPServer(("127.0.0.1", 0), H)
        self.url = "http://127.0.0.1:%d" % self.srv.server_port
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def close(self):
        self.srv.shutdown()


def _run(tmp_path, token, hub_url):
    home = tmp_path / "home"
    (home / ".ostler" / "assistant-config").mkdir(parents=True)
    (home / ".ostler" / "assistant-config" / "config.toml").write_text(CONFIG)
    script = tmp_path / "sender.sh"
    script.write_text(_sender_text())
    py311 = [p for p in ("/opt/homebrew/bin", "/usr/local/bin") if (Path(p) / "python3.11").exists()]
    env = {
        "HOME": str(home),
        "PATH": os.pathsep.join(py311 + [os.environ["PATH"]]),
        "OSTLER_HUB_HOST": hub_url,
        "OSTLER_BRIEF_QUIET_START": "25",
        "OSTLER_BRIEF_QUIET_END": "0",
    }
    if token:
        env["PWG_SERVICE_TOKEN"] = token
    p = subprocess.run(["bash", str(script)], env=env, capture_output=True, text=True, timeout=60)
    log = (home / ".ostler" / "logs" / "meeting-brief-sender.log").read_text() if (home / ".ostler" / "logs" / "meeting-brief-sender.log").exists() else ""
    return p, log


def test_no_service_token_is_cannot_run_not_success(tmp_path):
    p, log = _run(tmp_path, "", "http://127.0.0.1:1")
    assert p.returncode == 75, (p.returncode, log, p.stderr)
    assert "CANNOT-RUN" in log and "CANNOT-RUN" in p.stderr


def test_unreachable_hub_is_cannot_run(tmp_path):
    p, log = _run(tmp_path, "synthetic-token", "http://127.0.0.1:1")
    assert p.returncode == 75, (p.returncode, log)
    assert "CANNOT-RUN" in p.stderr


def test_empty_reply_is_cannot_run(tmp_path):
    hub = _Hub("")
    try:
        p, log = _run(tmp_path, "synthetic-token", hub.url)
    finally:
        hub.close()
    assert p.returncode == 75, (p.returncode, log)


def test_degraded_hub_is_cannot_run(tmp_path):
    hub = _Hub(json.dumps({"degraded": True, "meetings": []}))
    try:
        p, log = _run(tmp_path, "synthetic-token", hub.url)
    finally:
        hub.close()
    assert p.returncode == 75, (p.returncode, log)


def test_unreadable_degraded_flag_is_cannot_run(tmp_path):
    hub = _Hub("not json")
    try:
        p, log = _run(tmp_path, "synthetic-token", hub.url)
    finally:
        hub.close()
    assert p.returncode == 75, (p.returncode, log)


def test_healthy_hub_with_no_meetings_is_still_success(tmp_path):
    """Control: the fix must not turn the steady state into a fault."""
    hub = _Hub(json.dumps({"degraded": False, "meetings": []}))
    try:
        p, log = _run(tmp_path, "synthetic-token", hub.url)
    finally:
        hub.close()
    assert p.returncode == 0, (p.returncode, log, p.stderr)


def test_calendar_source_defaults_to_the_real_api_with_a_credential(monkeypatch, tmp_path):
    monkeypatch.delenv("CALENDAR_API_URL", raising=False)
    monkeypatch.chdir(tmp_path)
    cfg = importlib.import_module("meeting_syncer.config")
    cfg = importlib.reload(cfg)
    assert ":8089" not in cfg.CALENDAR_API_URL
    assert cfg.CALENDAR_API_URL.endswith(":8090/api/v1")

    from meeting_syncer.calendar_client import fetch_events

    hub = _Hub(json.dumps({"events": [{"uid": "u1", "attendees": ["a@example.invalid"]}]}))
    monkeypatch.setenv("PWG_SERVICE_TOKEN", "synthetic-token")
    try:
        # The stub serves any path; the point is the bearer token is sent.
        events = fetch_events(hub.url, 7)
    finally:
        hub.close()
    assert [e["uid"] for e in events] == ["u1"]
    assert "Bearer synthetic-token" in hub.seen_auth
