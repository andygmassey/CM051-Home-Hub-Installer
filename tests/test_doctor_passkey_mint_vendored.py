#!/usr/bin/env python3
"""tests/test_doctor_passkey_mint_vendored.py

Task 133, vendored half (HR015 #1501). Drives the REAL vendor/doctor/agent
web_ui.py, not the upstream copy:

  * the passkey mint and challenge routes relay the gateway's status and body
    unchanged (a refusal is never rewritten to a 200), an unreachable gateway
    is a 503, a 200 with no token is a 502, a cross-site POST is refused and the
    gateway sees nothing;
  * chat-token admits the owner OR a valid paired/minted bearer: no bearer and
    an invalid bearer are refused over the tailnet forwarder, a static
    credential is refused even when the oracle blesses it, and a bearer the
    oracle stops blessing is refused at once;
  * a mint refused as repair_needed puts the exact re-pair row on
    /api/v1/pair/status, and a later successful mint clears it.

The gateway is an httpx.MockTransport. The tailscaled forwarder is simulated by
owner_peer._lookup. HOME is a temp dir per test. No Keychain, no osascript.
Synthetic values only.

Exit codes: 0 pass, 1 a case failed, 2 CANNOT-RUN (missing dependency).
CI: .github/workflows/doctor-passkey-mint-vendored.yml.
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

AGENT = Path(__file__).resolve().parent.parent / "vendor" / "doctor" / "agent"
sys.path.insert(0, str(AGENT))
try:
    import httpx
    from fastapi.testclient import TestClient
except ModuleNotFoundError as exc:  # pragma: no cover
    print("CANNOT-RUN: missing dependency (%s). pip install fastapi httpx" % exc,
          file=sys.stderr)
    sys.exit(2)

LOOPBACK = ("127.0.0.1", 50000)
TAILSCALED = "/usr/local/bin/tailscaled"
OWNER_PROC = "/usr/bin/python3"
MINTED = "ospk_" + "synthetic" + "-bearer"
STATIC = "static" + "-admin-" + "token"
REPAIR_TEXT = "Re-pair this iPhone to use Ostler away from home."
MINT_BODY = {"challenge": "c1", "credential_id": "cred1", "authenticator_data": "a",
             "client_data_json": "d", "signature": "s"}
REASONS = ["replay", "expired_challenge", "wrong_credential", "repair_needed",
           "bad_signature", "up_unset", "sign_count", "rp_mismatch"]


class Base(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        home = self._tmp.name
        env = {"HOME": home, "OSTLER_DIR": os.path.join(home, ".ostler"),
               "DOCTOR_GATEWAY_URL": "http://127.0.0.1:8000",
               "DOCTOR_VALIDATOR_URL": "http://127.0.0.1:8000"}
        p = mock.patch.dict(os.environ, env)
        p.start()
        self.addCleanup(p.stop)
        for v in ("OSTLER_ADMIN_TOKEN", "OSTLER_MACHINE_ADMIN_TOKEN", "OSTLER_EXTENSION_TOKEN"):
            os.environ.pop(v, None)
        import owner_peer, passkey_proxy, proxy, web_ui
        self.owner_peer, self.pp, self.proxy, self.web_ui = owner_peer, passkey_proxy, proxy, web_ui
        self.addCleanup(self._tmp.cleanup)
        self.addCleanup(setattr, passkey_proxy, "_transport_factory", None)
        self.valid = {MINTED}

        async def _oracle(token, validator_url=None, client=None):
            return token in self.valid

        q = mock.patch.object(proxy, "_is_paired_bearer", _oracle)
        q.start()
        self.addCleanup(q.stop)
        self.peer(TAILSCALED)

    def peer(self, command):
        q = mock.patch.object(
            self.owner_peer, "_lookup",
            lambda *a, **k: self.owner_peer.Peer(
                pid=1, uid=self.owner_peer.owner_uid(), command=command))
        q.start()
        self.addCleanup(q.stop)

    def client(self):
        return TestClient(self.web_ui.app, client=LOOPBACK)

    def gateway(self, handler):
        seen = []

        def _h(req):
            seen.append(req)
            return handler(req)

        self.pp._transport_factory = lambda: httpx.MockTransport(_h)
        return seen


class Mint(Base):
    def test_refusals_relayed_unchanged(self):
        for reason in REASONS:
            seen = self.gateway(lambda req, r=reason: httpx.Response(403, json={"error": r}))
            r = self.client().post("/api/v1/auth/passkey/mint", json=MINT_BODY)
            self.assertEqual(r.status_code, 403, reason)
            self.assertEqual(r.json(), {"error": reason})
            self.assertEqual(json.loads(seen[0].content), MINT_BODY)
            self.assertEqual(seen[0].url.path, "/auth/passkey/mint")

    def test_unreachable_is_503_and_tokenless_200_is_502(self):
        def boom(req):
            raise httpx.ConnectError("down")
        self.gateway(boom)
        for r in (self.client().get("/api/v1/auth/passkey/challenge"),
                  self.client().post("/api/v1/auth/passkey/mint", json=MINT_BODY)):
            self.assertEqual(r.status_code, 503)
            self.assertEqual(r.json()["reason"], "ConnectError")
        self.gateway(lambda req: httpx.Response(200, json={"ok": True}))
        self.assertEqual(self.client().post("/api/v1/auth/passkey/mint", json=MINT_BODY).status_code, 502)

    def test_challenge_proxied_with_no_bearer_over_forwarder(self):
        seen = self.gateway(lambda req: httpx.Response(200, json={"challenge": "c1"}))
        r = self.client().get("/api/v1/auth/passkey/challenge")
        self.assertEqual((r.status_code, r.json()["challenge"]), (200, "c1"))
        self.assertEqual(seen[0].url.path, "/auth/passkey/challenge")

    def test_cross_site_mint_refused_and_gateway_sees_nothing(self):
        seen = self.gateway(lambda req: httpx.Response(403, json={"error": "x"}))
        r = self.client().post("/api/v1/auth/passkey/mint", json=MINT_BODY,
                               headers={"Sec-Fetch-Site": "cross-site"})
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.json()["refused_on"], "sec-fetch-site")
        self.assertEqual(seen, [])


class ChatToken(Base):
    def setUp(self):
        super().setUp()
        import chat_token
        q = mock.patch.object(chat_token, "issue_chat_token",
                              lambda request_host=None: {"token": "t", "url": "u"})
        q.start()
        self.addCleanup(q.stop)

    def post(self, bearer=None):
        h = {"Authorization": "Bearer " + bearer} if bearer else {}
        return self.client().post("/api/v1/auth/chat-token", headers=h)

    def test_forwarder_needs_a_valid_bearer(self):
        r = self.post()
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.json()["refused_on"], "peer-is-forwarder")
        self.assertEqual(self.post("nope").status_code, 403)
        ok = self.post(MINTED)
        self.assertEqual((ok.status_code, ok.json()["token"]), (200, "t"))

    def test_unpaired_bearer_is_refused_at_once(self):
        self.assertEqual(self.post(MINTED).status_code, 200)
        self.valid.discard(MINTED)
        self.assertEqual(self.post(MINTED).status_code, 403)

    def test_static_credential_is_never_a_device_bearer(self):
        os.environ["OSTLER_ADMIN_TOKEN"] = STATIC
        self.valid.add(STATIC)  # the oracle wrongly blesses it
        self.assertEqual(self.post(STATIC).status_code, 403)

    def test_handler_itself_admits_a_bearer_with_the_middleware_bypassed(self):
        import asyncio
        from starlette.requests import Request

        def call(auth):
            hdrs = [(b"authorization", auth.encode())] if auth else []
            scope = {"type": "http", "method": "POST", "path": "/api/v1/auth/chat-token",
                     "headers": hdrs, "query_string": b"", "client": LOOPBACK,
                     "server": ("127.0.0.1", 8089)}
            return asyncio.run(self.web_ui.api_chat_token(Request(scope)))

        self.assertEqual(call(None).status_code, 403)
        self.assertEqual(call("Bearer " + MINTED), {"token": "t", "url": "u"})

    def test_on_mac_owner_unaffected(self):
        self.peer(OWNER_PROC)
        r = self.client().post("/api/v1/auth/chat-token")
        self.assertEqual((r.status_code, r.json()["token"]), (200, "t"))


class RepairRow(Base):
    def row(self):
        self.peer(OWNER_PROC)  # the owner on the Mac reads the panel
        r = self.client().get("/api/v1/pair/status", headers={"Host": "127.0.0.1:8089"})
        self.assertEqual(r.status_code, 200, r.text)
        return r.json()["repair_row"]

    def test_row_set_by_repair_needed_and_cleared_by_success(self):
        import pair_status
        state = {"reason": "repair_needed"}
        self.gateway(lambda req: httpx.Response(403, json={"error": state["reason"]})
                     if state["reason"] else httpx.Response(200, json={"token": MINTED, "expires_at": 1}))
        q = mock.patch.object(pair_status, "_fetch_pair_status", lambda **k: pair_status.PairStatus(
            False, None, None, None, "x", "gateway_down"))
        q.start()
        self.addCleanup(q.stop)
        self.assertEqual(pair_status.REPAIR_ROW_TEXT, REPAIR_TEXT)
        self.assertIsNone(self.row())
        self.peer(TAILSCALED)
        self.client().post("/api/v1/auth/passkey/mint", json=MINT_BODY)
        self.assertEqual(self.row(), REPAIR_TEXT)
        state["reason"] = None
        self.peer(TAILSCALED)
        self.client().post("/api/v1/auth/passkey/mint", json=MINT_BODY)
        self.assertIsNone(self.row())

    def test_other_refusals_do_not_raise_the_row(self):
        self.gateway(lambda req: httpx.Response(403, json={"error": "bad_signature"}))
        self.client().post("/api/v1/auth/passkey/mint", json=MINT_BODY)
        self.assertFalse(self.pp.repair_needed())


if __name__ == "__main__":
    unittest.main(verbosity=1)
