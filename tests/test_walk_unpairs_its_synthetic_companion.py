"""Walk #27 item 5a: after a walk, Doctor read "Paired".

The pairing probes pair a software passkey through the real
/auth/pair/register flow and nothing unpaired it. companion_pair.py unpair
must revoke, through the Hub's own DELETE /api/devices/{id}, exactly the
devices the walk paired (paired_at at or after the walk start), remove the
passkey file only when the walk found none, and report the end state from
/health. A stub gateway models the Hub's companion_paired rule
(devices.db row OR passkey.json present, zeroclaw-gateway api.rs:107).
All data synthetic.
"""
from __future__ import annotations

import importlib.util
import json
import os
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts/box_walk_probes/lib/companion_pair.py"
RUNNER = ROOT / "scripts/box_walk_probes/run_box_walk.sh"

WALK_START = 1_800_000_000  # 2027-01-15T08:00:00Z
OWNER_DEVICE = {"id": "owner-legacy-device", "paired_at": "2027-01-10T09:00:00Z"}
WALK_DEVICE = {"id": "walk-device", "paired_at": "2027-01-15T08:20:00.123456789Z"}


def _load():
    spec = importlib.util.spec_from_file_location("companion_pair_under_test", HELPER)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class _Hub:
    def __init__(self, passkey: Path):
        self.devices = {d["id"]: dict(d) for d in (OWNER_DEVICE, WALK_DEVICE)}
        self.passkey = passkey
        self.deleted = []
        hub = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _send(self, code, obj):
                body = json.dumps(obj).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                if self.path == "/api/devices":
                    if self.headers.get("Authorization") != "Bearer synthetic-bearer":
                        return self._send(401, {})
                    return self._send(200, {"devices": list(hub.devices.values())})
                if self.path == "/health":
                    cp = bool(hub.devices) or hub.passkey.exists()
                    return self._send(200, {"companion_paired": cp, "paired": bool(hub.devices)})
                self._send(404, {})

            def do_DELETE(self):
                dev = self.path.rsplit("/", 1)[-1]
                if dev in hub.devices:
                    del hub.devices[dev]
                    hub.deleted.append(dev)
                    return self._send(200, {"message": "Device revoked"})
                self._send(404, {})

        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.base = "http://127.0.0.1:%d" % self.srv.server_address[1]
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def close(self):
        self.srv.shutdown()


class WalkUnpair(unittest.TestCase):
    def setUp(self):
        self.m = _load()
        self.tmp = tempfile.TemporaryDirectory()
        self.passkey = Path(self.tmp.name) / "passkey.json"
        self.passkey.write_text("{}")
        self.hub = _Hub(self.passkey)

    def tearDown(self):
        self.hub.close()
        self.tmp.cleanup()

    def _unpair(self, remove_passkey=True, since=WALK_START):
        return self.m.unpair(self.hub.base, "https://unused", "/nonexistent", since,
                             remove_passkey=remove_passkey, passkey_path=str(self.passkey),
                             bearer="synthetic-bearer")

    def test_the_walk_device_is_revoked_and_the_owners_is_not(self):
        r = self._unpair()
        self.assertEqual(self.hub.deleted, ["walk-device"])
        self.assertEqual((r["revoked"], r["left_since"]), (1, 0))

    def test_end_state_is_unpaired_when_the_walk_found_no_passkey(self):
        self.hub.devices.pop("owner-legacy-device")
        r = self._unpair(remove_passkey=True)
        self.assertFalse(self.passkey.exists())
        self.assertIs(r["companion_paired"], False, r)
        self.assertTrue(r["ok"], r)

    def test_control_a_passkey_left_in_place_still_reads_paired(self):
        # Proves the end-state check can fail: revoke alone is not unpaired.
        self.hub.devices.pop("owner-legacy-device")
        r = self._unpair(remove_passkey=False)
        self.assertTrue(self.passkey.exists())
        self.assertIs(r["companion_paired"], True, r)

    def test_no_walk_start_refuses_to_revoke_anything(self):
        r = self._unpair(since=0)
        self.assertEqual(self.hub.deleted, [])
        self.assertFalse(r["ok"])

    def test_the_walk_runner_baselines_before_pairing_and_unpairs_after(self):
        text = RUNNER.read_text()
        base = text.index("companion_walk_baseline ||")
        seed = text.index("conversation_capture_seed_apply ||")
        self.assertLess(base, seed, "the baseline must be taken before the first pairing seed")
        # The unpair runs inside walk_cleanup (normal end and the abort trap,
        # tests/test_walk_cleanup_runs_on_abort.sh), after the seed forgets.
        cleanup = text[text.index("walk_cleanup() {"):text.index("_walk_exit_trap() {")]
        self.assertIn("companion_walk_unpair", cleanup)
        self.assertGreater(cleanup.index("companion_walk_unpair"),
                           cleanup.index("conversation_capture_seed_forget"))


if __name__ == "__main__":
    unittest.main()
