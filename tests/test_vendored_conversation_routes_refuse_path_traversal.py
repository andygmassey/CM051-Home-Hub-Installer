"""CM041 #225 (e2dffc09) in the VENDORED ical-server: the conversation routes
refuse a path-traversal id.

Drives vendor/cm041/assistant_api/ical-server.py as a subprocess. A canary
state.json sits OUTSIDE the processing root; every traversal form must be
refused and the canary must never appear in a response:
  * GET /api/v1/conversation/status/<id> with ../, %2e%2e (raw, undecoded),
    an absolute path and a backslash form, sent byte-for-byte with http.client
    so no client normalises the path first;
  * POST /api/v1/conversation/process with the same ids as metadata
    conversation_id / meeting_id: no directory may appear outside the root.

CONTROL: the same status arms run against a MUTANT copy of the server whose
_safe_conversation_dir is a naive join (the pre-#225 shape). The ../ arm must
leak the canary there, so the arms are proven able to see a traversal.
"""
from __future__ import annotations

import http.client
import json
import os
import pathlib
import re
import socket
import subprocess
import sys
import tempfile
import time

import pytest

ROOT = pathlib.Path(__file__).resolve().parent.parent
SERVER = ROOT / "vendor/cm041/assistant_api/ical-server.py"
TOKEN = "fixture-service-token"
CANARY = "traversal-canary-7f3a"

STATUS_IDS = [
    "../secret",
    "..%2fsecret",
    "%2e%2e/secret",
    "%2e%2e%2fsecret",
    "/../secret",
    "..\\secret",
]
ABS_IDS = ["/{home}/secret", "{home}/secret"]


def _free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _start(server_file, home):
    port = _free_port()
    env = {k: v for k, v in os.environ.items() if "proxy" not in k.lower()}
    env.pop("OSTLER_DB_KEY", None)
    env.update({
        "OSTLER_API_PORT": str(port), "OSTLER_SERVICE_TOKEN": TOKEN,
        "USER_ID": "fixtureowner", "HOME": str(home), "NO_PROXY": "*",
        "OSTLER_PROCESSING_DIR": str(home / "processing"),
        "OXIGRAPH_URL": "http://127.0.0.1:9", "QDRANT_URL": "http://127.0.0.1:9",
        "PYTHONDONTWRITEBYTECODE": "1",
        "PYTHONPATH": os.pathsep.join([str(SERVER.parent), str(ROOT / "vendor/cm041"),
                                       str(ROOT / "vendor")]),
    })
    proc = subprocess.Popen([sys.executable, str(server_file)], env=env,
                            cwd=str(SERVER.parent), stdout=subprocess.DEVNULL,
                            stderr=subprocess.PIPE)
    for _ in range(150):
        if proc.poll() is not None:
            pytest.fail("ical-server exited: " + proc.stderr.read().decode()[-800:])
        try:
            c = http.client.HTTPConnection("127.0.0.1", port, timeout=1)
            c.request("GET", "/health")
            c.getresponse().read()
            return proc, port
        except Exception:
            time.sleep(0.1)
    proc.kill()
    pytest.fail("ical-server did not come up")


def _home():
    home = pathlib.Path(tempfile.mkdtemp())
    (home / "processing").mkdir()
    (home / "secret").mkdir()
    (home / "secret" / "state.json").write_text(json.dumps({"leak": CANARY}))
    return home


def _get(port, raw_path):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    c.putrequest("GET", raw_path, skip_host=False, skip_accept_encoding=True)
    c.putheader("Authorization", "Bearer " + TOKEN)
    c.endheaders()
    r = c.getresponse()
    return r.status, r.read().decode("utf-8", "replace")


def _post(port, path, body):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    data = json.dumps(body).encode()
    c.request("POST", path, body=data, headers={
        "Authorization": "Bearer " + TOKEN, "Content-Type": "application/json"})
    r = c.getresponse()
    return r.status, r.read().decode("utf-8", "replace")


def _status_leaks(port, home):
    leaks = []
    for cid in STATUS_IDS + [a.format(home=str(home).lstrip("/")) for a in ABS_IDS]:
        code, body = _get(port, "/api/v1/conversation/status/" + cid)
        if CANARY in body or code == 200:
            leaks.append((cid, code))
    return leaks


@pytest.fixture(scope="module")
def shipped():
    home = _home()
    proc, port = _start(SERVER, home)
    yield port, home
    proc.kill()
    proc.wait(5)


def test_status_route_refuses_every_traversal_form(shipped):
    port, home = shipped
    assert _status_leaks(port, home) == []


def test_status_route_still_serves_a_plain_id(shipped):
    # Positive control: the route works, so the refusals above are refusals.
    port, home = shipped
    d = home / "processing" / "2026-01-01_plain"
    d.mkdir()
    (d / "state.json").write_text(json.dumps({"status": "complete"}))
    code, body = _get(port, "/api/v1/conversation/status/2026-01-01_plain")
    assert code == 200 and json.loads(body)["status"] == "complete"


def test_process_route_never_creates_a_directory_outside_the_root(shipped):
    port, home = shipped
    before = sorted(p.name for p in home.iterdir())
    for cid in ["../escape", "%2e%2e/escape", "/" + str(home).lstrip("/") + "/escape"]:
        for key in ("conversation_id", "meeting_id"):
            _post(port, "/api/v1/conversation/process",
                  {"transcript": "Speaker 1: hello", "metadata": {key: cid}})
    time.sleep(1.0)
    assert sorted(p.name for p in home.iterdir()) == before
    assert not (home / "escape").exists()


def test_control_an_unguarded_server_leaks_the_canary():
    src = SERVER.read_text(encoding="utf-8")
    mutant, n = re.subn(
        r"def _safe_conversation_dir\(conversation_id\):\n",
        "def _safe_conversation_dir(conversation_id):\n"
        "    return PROCESSING_DIR / conversation_id\n\n\n"
        "def _safe_conversation_dir_unused(conversation_id):\n",
        src, count=1)
    assert n == 1, "mutation did not apply; the control proves nothing"
    mdir = pathlib.Path(tempfile.mkdtemp())
    mfile = mdir / "ical-server.py"
    mfile.write_text(mutant, encoding="utf-8")
    home = _home()
    proc, port = _start(mfile, home)
    try:
        leaks = _status_leaks(port, home)
    finally:
        proc.kill()
        proc.wait(5)
    assert ("../secret", 200) in leaks, leaks
