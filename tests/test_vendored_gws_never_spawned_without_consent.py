"""gws (the Google Workspace CLI) is NEVER spawned without a configured Google
account AND an explicit "accepted" opt-in.

Defect (v1.0.123 walk): with no Google connector and no consent, the Hub ran
/usr/local/bin/gws about every 4 minutes (the meeting-brief sender's poll of
/calendar), opening TLS to Google each time. No credentials, so no data read,
but the box's IP and timing went to Google unasked. Every gws call site was
unconditional: Google Calendar (/calendar, the timeline, the meeting brief),
Gmail (/email), recent mail (/api/v1/email/recent) and /health?detailed=1.

Three layers of proof, all through the real HTTP handler:
  1. BOUNDARY: subprocess.run is recorded; no argv[0] == GWS_BIN may appear.
  2. REAL PROCESS: GWS_BIN points at a fake gws that appends to a marker file;
     the marker must stay absent.
  3. MUTANTS (in-suite): each call site's gate is removed from the source in
     memory and the same no-consent scenario must then SPAWN gws. A test that
     cannot see a removed gate is not a test of the gate.
Plus the CONTROL: credentials + "accepted" spawns the fake gws exactly once
per endpoint, so the predicate is shown to be able to see a spawn at all.

Synthetic fixtures only; no real Google account is touched.

VENDORED COPY of CM041 assistant_api/tests/test_gws_never_spawned_without_consent.py
(CM041 #245), run against the SHIPPED vendor/cm041/assistant_api/ical-server.py.
Vendored-only differences: the shipped calendar reads the local Apple Calendar
store first (an empty store is provided), and recent mail reaches gws only as
the fallback when apple_mail.json is unreadable (left absent here, which is
exactly the state that made the brief spawn gws).
"""
from __future__ import annotations

import importlib.util
import json
import os
import socket
import stat
import sys
import tempfile
import threading
import types
import unittest
import urllib.error
import urllib.request
from http.server import HTTPServer
from pathlib import Path
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
VENDOR_API = HERE.parent / "vendor" / "cm041" / "assistant_api"
SERVER_FILE = VENDOR_API / "ical-server.py"
sys.path.insert(0, str(VENDOR_API / "tests"))
from test_ical_server_wire_shape import ical_server as _shipped  # noqa: E402  (installs the ostler_security stub)

_NO_PROXY = urllib.request.build_opener(urllib.request.ProxyHandler({}))
_DEAD = "http://127.0.0.1:9"  # refused at once: no store is reachable

# Every endpoint that reached a gws call site before the gate.
ENDPOINTS = (
    "/calendar",
    "/calendar/today",
    "/api/v1/timeline",
    "/email",
    "/api/v1/email/recent",
    "/health?detailed=1",
)

# Each call site's gate, and what a mutant replaces it with.
GATES = {
    "calendar": ('    if not google_connector_allowed(GOOGLE_CALENDAR_CONSENT_ID):\n'
                 '        raise GoogleNotConnected("Google Calendar")',
                 '    if False:\n        raise GoogleNotConnected("Google Calendar")'),
    "gmail": ('    if not google_connector_allowed(GOOGLE_GMAIL_CONSENT_ID):\n'
              '        return {"error": "Gmail not connected"',
              '    if False:\n        return {"error": "Gmail not connected"'),
    "recent_mail": ('    if not google_connector_allowed(GOOGLE_GMAIL_CONSENT_ID):\n'
                    '        return {"emails": [], "count": 0, "hours": hours,',
                    '    if False:\n        return {"emails": [], "count": 0, "hours": hours,'),
    "health": ('    if not (google_connector_allowed(GOOGLE_CALENDAR_CONSENT_ID)\n'
               '            or google_connector_allowed(GOOGLE_GMAIL_CONSENT_ID)):',
               '    if False:'),
    "consent_ignored": ('    return _gws_credentials_present() and _connector_consent_accepted(tickbox_id)',
                        '    return _gws_credentials_present()'),
}
# The endpoint each mutant must make spawn gws.
MUTANT_ENDPOINT = {
    "calendar": "/calendar",
    "gmail": "/email",
    "recent_mail": "/api/v1/email/recent",
    "health": "/health?detailed=1",
    "consent_ignored": "/calendar",
}


def _load(source: str | None = None, name: str = "ical_server_gws_gate"):
    """Load the server; with ``source``, a mutated copy keeping the real
    ``__file__`` so its path-derived imports resolve exactly as unmutated."""
    if source is None:
        spec = importlib.util.spec_from_file_location(name, SERVER_FILE)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    mod = types.ModuleType(name)
    mod.__file__ = str(SERVER_FILE)
    sys.modules[name] = mod
    exec(compile(source, str(SERVER_FILE), "exec"), mod.__dict__)
    return mod


server = _shipped


def _free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class _Box:
    """A throwaway HOME (gws credentials) + OSTLER_HOME (consent registry),
    a fake gws that records each spawn, and the real server on a free port."""

    def __init__(self, mod, *, creds=False, consent=None, consent_raw=None):
        self.mod = mod
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.home = root / "home"
        self.ostler = root / "ostler"
        (self.ostler / "posture").mkdir(parents=True)
        self.home.mkdir()
        if creds:
            d = self.home / ".config" / "gws"
            d.mkdir(parents=True)
            (d / "credentials.enc").write_text("synthetic-not-a-credential")
        reg = self.ostler / "posture" / "consent.json"
        if consent_raw is not None:
            reg.write_text(consent_raw)
        elif consent is not None:
            reg.write_text(json.dumps({"schema_version": 1, "records": {
                tid: {"tickbox_id": tid, "decision": consent}
                for tid in (mod.GOOGLE_CALENDAR_CONSENT_ID,
                            mod.GOOGLE_GMAIL_CONSENT_ID)}}))
        self.fda = root / "fda"
        self.fda.mkdir()
        (self.fda / "calendar_events.json").write_text("[]")
        self.marker = root / "gws_spawned.log"
        self.fake = root / "gws"
        self.fake.write_text(
            "#!/bin/sh\n"
            f"echo \"$*\" >> '{self.marker}'\n"
            "echo '{\"items\": [], \"messages\": [], \"resultSizeEstimate\": 0}'\n")
        self.fake.chmod(self.fake.stat().st_mode | stat.S_IXUSR)

    def spawns(self):
        if not self.marker.exists():
            return []
        return [ln for ln in self.marker.read_text().splitlines() if ln.strip()]

    def __enter__(self):
        m = self.mod
        self._patches = [
            patch.dict(os.environ, {"OSTLER_HOME": str(self.ostler),
                                    "OSTLER_SERVICE_TOKEN": "test-token"}),
            patch.object(m, "FDA_IMPORT_DIR", str(self.fda)),
            patch.dict(m.GWS_ENV, {"HOME": str(self.home)}),
            patch.object(m, "GWS_BIN", str(self.fake)),
            patch.object(m, "ICAL_SCRIPT", "/nonexistent/ical-query.sh"),
        ]
        for attr in ("OXIGRAPH_URL", "QDRANT_URL", "EMBED_OLLAMA_URL"):
            if hasattr(m, attr):
                self._patches.append(patch.object(m, attr, _DEAD))
        for p in self._patches:
            p.start()
        self.port = _free_port()
        self.httpd = HTTPServer(("127.0.0.1", self.port), m.Handler)
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()
        return self

    def __exit__(self, *exc):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join(timeout=2)
        for p in reversed(self._patches):
            p.stop()
        self.tmp.cleanup()

    def get(self, path):
        req = urllib.request.Request(f"http://127.0.0.1:{self.port}{path}",
                                     headers={"X-Ostler-Service": "test-token"})
        try:
            with _NO_PROXY.open(req, timeout=30) as r:
                return r.status, json.loads(r.read() or b"{}")
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read() or b"{}")


class TestNoConsentNoSpawn(unittest.TestCase):
    """The customer state: no Google account, no opt-in."""

    def test_boundary_subprocess_never_receives_gws(self):
        seen = []
        real_run = server.subprocess.run

        def recording_run(cmd, *a, **kw):
            seen.append(list(cmd) if isinstance(cmd, (list, tuple)) else [cmd])
            return real_run(cmd, *a, **kw)

        with _Box(server) as box, \
             patch.object(server.subprocess, "run", side_effect=recording_run):
            for ep in ENDPOINTS:
                box.get(ep)
            gws_calls = [c for c in seen if c and c[0] == server.GWS_BIN]
        self.assertEqual(gws_calls, [], f"gws spawned with no consent: {gws_calls}")

    def test_real_process_marker_stays_absent(self):
        with _Box(server) as box:
            for ep in ENDPOINTS:
                box.get(ep)
            self.assertEqual(box.spawns(), [], "fake gws ran with no consent")
            self.assertFalse(box.marker.exists())

    def test_calendar_and_timeline_say_not_connected_not_error(self):
        with _Box(server) as box:
            st, body = box.get("/calendar")
            self.assertEqual(st, 200, body)
            self.assertIn("Google", body.get("not_connected", []), body)
            self.assertNotIn("Google Calendar", body.get("sources", []), body)
            st, _ = box.get("/api/v1/timeline")
            self.assertEqual(st, 200)
            self.assertEqual(box.spawns(), [])

    def test_mail_says_not_connected(self):
        with _Box(server) as box:
            _, body = box.get("/email")
            self.assertEqual(body.get("not_connected"), ["Gmail"], body)
            self.assertEqual(box.spawns(), [])

    def test_health_reports_not_connected_without_degrading_on_gws(self):
        with _Box(server) as box:
            _, body = box.get("/health?detailed=1")
            self.assertEqual(body["checks"]["gws"],
                             {"ok": False, "not_connected": True}, body)
            self.assertEqual(box.spawns(), [])

    def test_fail_closed_on_every_partial_or_unreadable_state(self):
        cases = {
            "creds, no registry": dict(creds=True),
            "accepted, no creds": dict(consent="accepted"),
            "creds, declined": dict(creds=True, consent="declined"),
            "creds, wrong case": dict(creds=True, consent="Accepted"),
            "creds, boolean true": dict(creds=True, consent=True),
            "creds, malformed registry": dict(creds=True, consent_raw="{not json"),
            "creds, no records key": dict(creds=True, consent_raw='{"schema_version": 1}'),
            "creds, other tickbox only": dict(
                creds=True, consent_raw=json.dumps({"records": {
                    "whatsapp_unofficial_risk": {"decision": "accepted"}}})),
        }
        for label, kw in cases.items():
            with self.subTest(label), _Box(server, **kw) as box:
                for ep in ENDPOINTS:
                    box.get(ep)
                self.assertEqual(box.spawns(), [], label)

    def test_empty_credentials_file_is_not_an_account(self):
        with _Box(server, consent="accepted") as box:
            d = box.home / ".config" / "gws"
            d.mkdir(parents=True)
            (d / "credentials.json").write_text("")
            box.get("/calendar")
            self.assertEqual(box.spawns(), [])


class TestConsentedControl(unittest.TestCase):
    """Credentials + "accepted": gws runs as before, exactly once per endpoint
    (the fake returns no items/messages, so no per-message follow-ups)."""

    def test_each_endpoint_spawns_exactly_once(self):
        expect = {
            "/calendar": "calendar events list",
            "/api/v1/timeline": "calendar events list",
            "/email": "gmail users messages list",
            "/api/v1/email/recent": "gmail users messages list",
            "/health?detailed=1": "--version",
        }
        for ep, argv in expect.items():
            with self.subTest(ep), _Box(server, creds=True, consent="accepted") as box:
                box.get(ep)
                got = box.spawns()
                self.assertEqual(len(got), 1, f"{ep}: {got}")
                self.assertTrue(got[0].startswith(argv), f"{ep}: {got}")

    def test_macos_fallback_config_dir_counts_as_configured(self):
        with _Box(server, consent="accepted") as box:
            d = box.home / "Library" / "Application Support" / "gws"
            d.mkdir(parents=True)
            (d / "credentials.json").write_text("{}")
            box.get("/calendar")
            self.assertEqual(len(box.spawns()), 1)


class TestGateMutants(unittest.TestCase):
    """Remove one gate at a time; the no-consent scenario must then spawn gws.
    Mutant "consent_ignored" keeps the gates but drops the consent check, and
    runs with credentials present, so it proves consent is load-bearing."""

    def test_every_mutant_is_caught(self):
        src = SERVER_FILE.read_text()
        for name, (gate, mutant) in GATES.items():
            with self.subTest(name):
                self.assertEqual(src.count(gate), 1, f"gate text for {name} moved")
                mod = _load(src.replace(gate, mutant), name=f"ical_server_mut_{name}")
                kw = dict(creds=True) if name == "consent_ignored" else {}
                with _Box(mod, **kw) as box:
                    box.get(MUTANT_ENDPOINT[name])
                    self.assertGreaterEqual(
                        len(box.spawns()), 1,
                        f"mutant {name} spawned nothing: the test is blind to it")


if __name__ == "__main__":
    unittest.main()
