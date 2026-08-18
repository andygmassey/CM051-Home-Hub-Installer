"""Regression suite for the context-digest authentication defect (2026-08-18).

THE DEFECT, as measured on a real v1.0.36 install before this suite existed:

    $ curl -s http://127.0.0.1:8090/api/v1/timeline
    {"error": "Unauthorized: missing or invalid service token"}
    $ grep -inE "authorization|bearer|token" bin/generate_pwg_context.py
    111:    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    $ find ~/.ostler -name CONTEXT.md      # never created, on any install
    $ ls ~/.ostler/secrets/                # service_token was there all along

All four ``/api/v1/*`` reads returned 401, ``_get_json`` swallowed the
HTTPError, the failure line blamed two causes nobody had measured, and the
script exited 0. Every light stayed green while the assistant had no
personal-context digest at all.

WHAT THIS SUITE PINS, and why each half is load-bearing:

  1. A run with a VALID token writes a non-empty CONTEXT.md. Without this the
     fix is unproven -- and it doubles as the positive control for (2): it is
     the same fake server, so a failing-for-the-wrong-reason server (down,
     wrong port, refusing everything) turns this test RED too, and cannot let
     the exit-code tests pass on an empty denominator.

  2. A run with an ABSENT or REJECTED token exits NON-ZERO. Without this
     second half the fix is unprotected: someone drops the Authorization
     header again, the digest silently stops being produced, and the exit
     code says 0 exactly as it did before.

The fake ical-server below reproduces the real gate/defect split on purpose:
``/health`` answers 200 with no credential, every ``/api/v1/*`` route fails
closed at 401. That split is what made the install-time health check green
while the consumer was locked out, so the test only means something if it is
present. ``test_fake_server_reproduces_the_gate_defect_split`` asserts it.

The generator is driven as a SUBPROCESS, not imported. The thing under test
is the artefact's exit status, and only a real process has one.

All fixture data is synthetic. No real people, no real organisations.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parent.parent
_SCRIPT = _REPO_ROOT / "bin" / "generate_pwg_context.py"

# The token the fake server accepts. Synthetic, fixed, and obviously fake so a
# leak-scanner never has to decide whether it is real.
_GOOD_TOKEN = "synthetic-service-token-for-tests-0000"

# Exit codes, mirrored from the generator so a change to either side is caught
# here rather than discovered on a customer Mac.
_EXIT_OK = 0
_EXIT_NOTHING_PRODUCED = 2
_EXIT_DEGRADED = 3

# Synthetic payloads. Deliberately unmistakable strings so an assertion cannot
# accidentally match boilerplate from the digest template.
_SUGGESTIONS = {
    "recent_meetings": [
        {
            "name": "Fixture Person",
            "organisation": "Fixture Industries",
            "last_contact": "2026-08-01",
        },
    ],
    "birthdays": [],
    "reconnect": [],
}
_TIMELINE = {
    "items": [
        {
            "summary": "Fixture standup",
            "date": "2026-08-02",
            "kind": "meeting",
        },
    ],
}
_COACH = {"observations": []}

_EMPTY_SPARQL = {"head": {"vars": []}, "results": {"bindings": []}}


class _FakeHubHandler(BaseHTTPRequestHandler):
    """The ical-server's auth posture, reproduced: /health is public, the
    /api/v1/* data plane fails closed at 401 without the bearer.

    Also stands in for Oxigraph on POST /query, always returning zero
    bindings. That is on purpose: it forces every byte of digest content to
    come through the AUTHENTICATED surface, so these tests discriminate on
    the Authorization header and nothing else.
    """

    expected_token = _GOOD_TOKEN

    def log_message(self, *_args):  # noqa: D102 - silence the test console
        pass

    def _send(self, code: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorised(self) -> bool:
        raw = self.headers.get("Authorization") or ""
        prefix = "Bearer "
        if not raw.startswith(prefix):
            return False
        return raw[len(prefix):].strip() == self.expected_token

    def do_GET(self):  # noqa: N802 - BaseHTTPRequestHandler's spelling
        path = self.path.split("?", 1)[0]

        # Public, exactly as the real server has it: _PUBLIC_GET_PATHS.
        if path == "/health":
            self._send(200, {"status": "ok"})
            return

        if not self._authorised():
            self._send(401, {"error": "Unauthorized: missing or invalid service token"})
            return

        if path == "/api/v1/suggestions":
            self._send(200, _SUGGESTIONS)
        elif path == "/api/v1/timeline":
            self._send(200, _TIMELINE)
        elif path == "/api/v1/coach/recent":
            self._send(200, _COACH)
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):  # noqa: N802 - BaseHTTPRequestHandler's spelling
        # Oxigraph stand-in: unauthenticated (as measured on a real Hub) and
        # deliberately empty.
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        if self.path.split("?", 1)[0] == "/query":
            self._send(200, _EMPTY_SPARQL)
        else:
            self._send(404, {"error": "not found"})


@pytest.fixture()
def hub():
    """A running fake Hub. Yields its base URL."""
    server = ThreadingHTTPServer(("127.0.0.1", 0), _FakeHubHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_address[1]}"
    finally:
        server.shutdown()
        server.server_close()


def _base_env(workspace: Path) -> dict:
    """Environment for a generator subprocess, minus anything inherited that
    would make the run measure something other than the code under test.

    ``no_proxy`` is set for the same reason context-refresh-tick.sh sets it on
    a customer Mac: a corporate http_proxy in the environment routes even a
    127.0.0.1 request through the proxy, which then answers 503. Without this
    the suite fails on any proxied developer machine and the failure looks
    exactly like the auth defect it is meant to detect.
    """
    env = dict(os.environ)
    for name in ("OSTLER_SERVICE_TOKEN", "PWG_SERVICE_TOKEN"):
        env.pop(name, None)
    env["no_proxy"] = "127.0.0.1,localhost,::1"
    env["NO_PROXY"] = env["no_proxy"]
    env["ZEROCLAW_WORKSPACE_DIR"] = str(workspace)
    return env


def _direct_urlopen(url: str, timeout: int = 10):
    """urlopen with proxies explicitly disabled, for the same reason."""
    import urllib.request

    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    return opener.open(url, timeout=timeout)


def _run(hub_url: str, workspace: Path, *, token: str | None,
         token_file: Path | None = None) -> subprocess.CompletedProcess:
    """Run the generator as a real process against the fake Hub.

    ``token`` None means "no token in the environment". ``token_file`` is
    pointed somewhere harmless by default: without that pin the generator
    would fall back to the DEVELOPER's own ~/.ostler/secrets/service_token and
    the absent-token test would quietly be testing nothing.
    """
    env = _base_env(workspace)
    if token is not None:
        env["OSTLER_SERVICE_TOKEN"] = token
    env["OSTLER_SERVICE_TOKEN_FILE"] = str(
        token_file if token_file is not None else workspace / "no-such-token-file"
    )
    env["OSTLER_ICAL_BASE_URL"] = hub_url
    env["OXIGRAPH_URL"] = hub_url
    return subprocess.run(
        [sys.executable, str(_SCRIPT)],
        env=env, capture_output=True, text=True, timeout=60, check=False,
    )


# ── The control: the fixture reproduces the split that hid the defect ────────


def test_fake_server_reproduces_the_gate_defect_split(hub):
    """/health answers 200 with no credential while /api/v1/* answers 401.

    This is the shape of the real defect: the install-time health check probed
    the public route and went green, while the consumer used the authenticated
    routes and was refused. If this ever stops holding, every exit-code
    assertion below is measuring a different server than the one that shipped.
    """
    import urllib.error

    with _direct_urlopen(f"{hub}/health") as resp:
        assert resp.status == 200

    with pytest.raises(urllib.error.HTTPError) as caught:
        _direct_urlopen(f"{hub}/api/v1/timeline")
    assert caught.value.code == 401


# ── (1) A valid token produces a non-empty CONTEXT.md ────────────────────────


def test_context_md_written_with_valid_token(hub, tmp_path):
    """The whole point of the script: with the bearer attached, the
    authenticated sections deliver and a non-empty digest lands on disk."""
    workspace = tmp_path / "workspace"
    result = _run(hub, workspace, token=_GOOD_TOKEN)

    context = workspace / "CONTEXT.md"
    assert context.exists(), (
        "CONTEXT.md was not created with a valid token.\n"
        f"exit={result.returncode}\nstdout={result.stdout}\nstderr={result.stderr}"
    )
    body = context.read_text(encoding="utf-8")
    assert body.strip(), "CONTEXT.md was created but is empty"

    # It carries real content from the AUTHENTICATED surface, not just the
    # digest's own boilerplate. Oxigraph returned zero bindings, so every one
    # of these strings had to come through a bearer-guarded route.
    assert "Fixture Person" in body
    assert "Fixture standup" in body
    assert "## People you interact with most" in body

    assert result.returncode == _EXIT_OK, (
        f"expected clean exit, got {result.returncode}\nstderr={result.stderr}"
    )


def test_token_is_read_from_the_secrets_file_when_env_is_unset(hub, tmp_path):
    """Fresh installs never seeded the env for this agent, so the file
    fallback is the path that actually runs on a customer Mac."""
    workspace = tmp_path / "workspace"
    token_file = tmp_path / "service_token"
    token_file.write_text(_GOOD_TOKEN + "\n", encoding="utf-8")

    result = _run(hub, workspace, token=None, token_file=token_file)

    assert (workspace / "CONTEXT.md").exists(), (
        "the secrets-file fallback did not authenticate.\n"
        f"exit={result.returncode}\nstderr={result.stderr}"
    )
    assert result.returncode == _EXIT_OK


# ── (2) An absent or rejected token exits NON-ZERO ───────────────────────────


def test_exits_non_zero_when_token_absent(hub, tmp_path):
    """No token anywhere. Every authenticated read is refused, no digest can
    be assembled, and the run MUST NOT report success.

    This is the half that keeps the fix alive. Drop the Authorization header
    again and this test goes red; without it the regression is silent.
    """
    workspace = tmp_path / "workspace"
    result = _run(hub, workspace, token=None)

    assert result.returncode != 0, (
        "a run that produced zero of six sections exited 0 -- this is the "
        "original defect.\n"
        f"stdout={result.stdout}\nstderr={result.stderr}"
    )
    assert result.returncode == _EXIT_NOTHING_PRODUCED
    assert not (workspace / "CONTEXT.md").exists()


def test_exits_non_zero_when_token_rejected(hub, tmp_path):
    """A present-but-wrong token is refused just as hard, and is reported as
    a rejection rather than as an absence."""
    workspace = tmp_path / "workspace"
    result = _run(hub, workspace, token="wrong-token-value")

    assert result.returncode != 0, (
        f"rejected token exited 0.\nstdout={result.stdout}\nstderr={result.stderr}"
    )
    assert result.returncode == _EXIT_NOTHING_PRODUCED


# ── (3) The message names what was measured ──────────────────────────────────


def test_failure_message_names_the_measured_status(hub, tmp_path):
    """The report must quote the status this process actually saw."""
    workspace = tmp_path / "workspace"
    result = _run(hub, workspace, token=None)

    assert "HTTP 401" in result.stderr, (
        "the failure report does not name the status that was observed.\n"
        f"stderr={result.stderr}"
    )
    assert "/api/v1/timeline" in result.stderr
    assert "0 of 6 sections produced content" in result.stderr


def test_failure_message_does_not_invent_a_cause(hub, tmp_path):
    """The retired string asserted two causes the script never checked.

    On the install that surfaced this, ical-server was answering /health 200
    and the graph held 6,549 person nodes, so BOTH named causes were false.
    The fixture here is the same: the server is UP and answering. A message
    that still claims it is down is lying about a thing it can see.
    """
    workspace = tmp_path / "workspace"
    result = _run(hub, workspace, token=None)

    combined = result.stdout + result.stderr
    assert "ical-server down or empty graph" not in combined, (
        "the invented-cause message is back.\n" + combined
    )
    assert "no data available" not in combined


def test_token_value_never_appears_in_output(hub, tmp_path):
    """Provenance is reported; the credential is not."""
    workspace = tmp_path / "workspace"
    result = _run(hub, workspace, token=_GOOD_TOKEN)
    combined = result.stdout + result.stderr
    assert _GOOD_TOKEN not in combined

    # And on the failure path, where the report is at its most verbose.
    result = _run(hub, workspace / "second", token="wrong-token-value")
    combined = result.stdout + result.stderr
    assert "wrong-token-value" not in combined


# ── (4) A partial run is not a clean run ─────────────────────────────────────


def test_partial_digest_exits_degraded_not_ok(hub, tmp_path, monkeypatch):
    """A digest built while some sources were failing must not exit 0.

    Here Oxigraph is unreachable (pointed at a closed port) while the
    authenticated ical-server is fine, so a digest IS written -- and the exit
    code still confesses. "Some data arrived" is not the same as "everything
    worked", and conflating the two is what this whole suite exists to stop.
    """
    workspace = tmp_path / "workspace"
    env = _base_env(workspace)
    env["OSTLER_SERVICE_TOKEN"] = _GOOD_TOKEN
    env["OSTLER_SERVICE_TOKEN_FILE"] = str(workspace / "no-such-token-file")
    env["OSTLER_ICAL_BASE_URL"] = hub
    # Port 1 on loopback: reserved, nothing listens, connection refused fast.
    env["OXIGRAPH_URL"] = "http://127.0.0.1:1"
    result = subprocess.run(
        [sys.executable, str(_SCRIPT)],
        env=env, capture_output=True, text=True, timeout=60, check=False,
    )

    assert (workspace / "CONTEXT.md").exists(), (
        "the reachable half should still have produced a digest.\n"
        f"stderr={result.stderr}"
    )
    assert result.returncode == _EXIT_DEGRADED, (
        f"partial run exited {result.returncode}, expected {_EXIT_DEGRADED}.\n"
        f"stderr={result.stderr}"
    )
    assert "unreachable" in result.stderr
