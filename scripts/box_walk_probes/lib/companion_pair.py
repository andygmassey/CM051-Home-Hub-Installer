#!/usr/bin/env python3
"""companion_pair.py -- pair a synthetic companion the way the iPhone does.

The customer's iPhone (CM031 HubPairingAPI.swift) pairs through exactly two
calls on the Hub's companion listener, after the owner has shown a QR:

  POST /auth/pair/init      {spec_version, pairing_token, device_label}
                            -> {registration_challenge, rp_id, ...}
  POST /auth/pair/register  {pairing_token, credential_id, attestation_object,
                             client_data_json, prf_output, companion_proof,
                             authenticator_data, assertion_client_data_json,
                             signature}
                            -> {wrapped_dek, hub_proof, device_token}

It never calls /pair or /api/pair. Those legacy 6-digit routes are refused on
:8443 by ostler-assistant #492/#501, so a walk probe that still paired through
them would measure a door the customer does not use, and would go CANNOT-RUN
or red the day the hardening ships.

This script is that flow, non-interactively:

  1. The OWNER opens a pairing window: POST /admin/paircode/new on the
     loopback admin port with the install's admin token. The response's
     qr_payload carries the pairing_token the QR would show.
  2. /auth/pair/init with that token.
  3. /auth/pair/register with a SOFTWARE passkey: a fresh P-256 key, a
     `none` attestation whose authData carries the COSE public key, a
     webauthn.create clientDataJSON over the server challenge, a random
     32-byte PRF output, companion_proof = HMAC-SHA256(KEK, "creativemachines/
     pair/proof/v1") with KEK = HKDF-SHA256(prf, salt "creativemachines/auth/
     v1", info "creativemachines/kek/primary/v1/default"), and an ES256
     assertion over authenticatorData || SHA-256(webauthn.get clientDataJSON).
     Every constant is the Hub's (ostler-assistant pair_handshake.rs,
     webauthn.rs, api_auth_pair.rs).

Needs `cryptography`. Run it with an interpreter that has it (the Ostler venv
does); `find_python()` picks one, and none is a CANNOT-RUN, never a FAIL.

CLI:
  companion_pair.py pair --admin-base URL --gateway URL --admin-token-path P
      prints one JSON line: {"ok": bool, "stage": str, "http": int|null,
      "detail": str, "device_token": str|null}. The token is printed because
      the calling probe needs it as a bearer; it is a synthetic device's.
  companion_pair.py legacy --admin-base URL --gateway URL --admin-token-path P
      the OLD flow (6-digit code -> POST /pair), kept only so a red/green run
      can show the old flow is refused and the new one is not.
  companion_pair.py --self-test
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import ssl
import struct
import sys
import urllib.error
import urllib.request

SPEC_VERSION = 1
HKDF_SALT_V1 = b"creativemachines/auth/v1"
PRIMARY_KEK_INFO = b"creativemachines/kek/primary/v1/default"
COMPANION_PROOF_INPUT = b"creativemachines/pair/proof/v1"
DEVICE_LABEL = "walk-probe synthetic companion"


def b64u(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def b64u_decode(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


# ── minimal CBOR encoder (maps, ints, bytes, text) ──────────────────────────

def _cbor_head(major: int, n: int) -> bytes:
    if n < 24:
        return bytes([(major << 5) | n])
    if n < 0x100:
        return bytes([(major << 5) | 24, n])
    if n < 0x10000:
        return bytes([(major << 5) | 25]) + struct.pack(">H", n)
    return bytes([(major << 5) | 26]) + struct.pack(">I", n)


def cbor(value) -> bytes:
    if isinstance(value, bool):
        raise TypeError("bool not needed")
    if isinstance(value, int):
        return _cbor_head(0, value) if value >= 0 else _cbor_head(1, -1 - value)
    if isinstance(value, bytes):
        return _cbor_head(2, len(value)) + value
    if isinstance(value, str):
        raw = value.encode()
        return _cbor_head(3, len(raw)) + raw
    if isinstance(value, dict):
        out = _cbor_head(5, len(value))
        for k, v in value.items():
            out += cbor(k) + cbor(v)
        return out
    raise TypeError(type(value))


# ── the companion's half of SHARED_AUTH_SPEC §3.3 ───────────────────────────

def hkdf_sha256(ikm: bytes, salt: bytes, info: bytes, length: int = 32) -> bytes:
    prk = hmac.new(salt, ikm, hashlib.sha256).digest()
    okm, block = b"", b""
    i = 1
    while len(okm) < length:
        block = hmac.new(prk, block + info + bytes([i]), hashlib.sha256).digest()
        okm += block
        i += 1
    return okm[:length]


def companion_proof(prf: bytes) -> bytes:
    kek = hkdf_sha256(prf, HKDF_SALT_V1, PRIMARY_KEK_INFO)
    return hmac.new(kek, COMPANION_PROOF_INPUT, hashlib.sha256).digest()


def build_register(pairing_token: str, challenge_b64u: str, rp_id: str, origin: str):
    """The register body, and the private key (for the self-test)."""
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.asymmetric import ec

    key = ec.generate_private_key(ec.SECP256R1())
    nums = key.public_key().public_numbers()
    x, y = nums.x.to_bytes(32, "big"), nums.y.to_bytes(32, "big")
    cose_key = cbor({1: 2, 3: -7, -1: 1, -2: x, -3: y})
    cred_id = os.urandom(16)
    rp_hash = hashlib.sha256(rp_id.encode()).digest()
    # flags: UP (0x01) | UV (0x04) | AT (0x40)
    auth_data_reg = (rp_hash + bytes([0x45]) + struct.pack(">I", 0)
                     + bytes(16) + struct.pack(">H", len(cred_id)) + cred_id + cose_key)
    attestation = cbor({"fmt": "none", "attStmt": {}, "authData": auth_data_reg})
    client_data_create = json.dumps(
        {"type": "webauthn.create", "challenge": challenge_b64u, "origin": origin},
        separators=(",", ":"))
    prf = os.urandom(32)
    # The assertion: authenticatorData without attested data, UP|UV.
    auth_data_get = rp_hash + bytes([0x05]) + struct.pack(">I", 1)
    client_data_get = json.dumps(
        {"type": "webauthn.get", "challenge": challenge_b64u, "origin": origin},
        separators=(",", ":"))
    signed = auth_data_get + hashlib.sha256(client_data_get.encode()).digest()
    signature = key.sign(signed, ec.ECDSA(hashes.SHA256()))  # DER, as ring's ASN1 verifier wants
    body = {
        "spec_version": SPEC_VERSION,
        "pairing_token": pairing_token,
        "credential_id": b64u(cred_id),
        "attestation_object": b64u(attestation),
        "client_data_json": b64u(client_data_create.encode()),
        "prf_output": b64u(prf),
        "companion_proof": b64u(companion_proof(prf)),
        "authenticator_data": b64u(auth_data_get),
        "assertion_client_data_json": client_data_get,
        "signature": b64u(signature),
    }
    return body, key


# ── HTTP ─────────────────────────────────────────────────────────────────────

def _http(method, url, body=None, headers=None, timeout=15):
    data = None if body is None else (body if isinstance(body, bytes) else json.dumps(body).encode())
    req = urllib.request.Request(url, data=data, method=method, headers=dict(headers or {}))
    if data is not None and "Content-Type" not in req.headers:
        req.add_header("Content-Type", "application/json")
    handlers = [urllib.request.ProxyHandler({})]
    if url.lower().startswith("https://"):
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE  # the Hub's companion leaf is self-signed and pinned by the app
        handlers.append(urllib.request.HTTPSHandler(context=ctx))
    opener = urllib.request.build_opener(*handlers)
    try:
        with opener.open(req, timeout=timeout) as r:
            return r.getcode(), r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read().decode("utf-8", "replace") if exc.fp else ""


def _result(ok, stage, http=None, detail="", token=None, replay_http=None):
    return {"ok": ok, "stage": stage, "http": http, "detail": detail, "device_token": token,
            "replay_http": replay_http}


def _admin(admin_token_path):
    try:
        tok = open(os.path.expanduser(admin_token_path)).read().strip()
    except OSError:
        return None
    return tok or None


def open_window(admin_base, admin_token):
    """The owner opens a pairing window. Returns (pairing_token, rp_id, hub_addr, detail)."""
    try:
        rc, body = _http("POST", admin_base.rstrip("/") + "/admin/paircode/new", b"",
                         {"Authorization": "Bearer " + admin_token})
    except Exception as exc:
        return None, None, None, "admin endpoint unreachable ({})".format(str(exc)[:80])
    try:
        env = json.loads(body)
        qr = env.get("qr_payload")
        if isinstance(qr, str):
            qr = json.loads(qr)
        return qr["pairing_token"], qr.get("rp_id") or "", qr.get("hub_addr") or "", "http {}".format(rc)
    except Exception:
        return None, None, None, "no qr_payload.pairing_token in the admin response (http {}, {} bytes)".format(rc, len(body))


def pair(admin_base, gateway, admin_token_path, replay=False):
    admin = _admin(admin_token_path)
    if not admin:
        return _result(False, "admin", None, "no readable admin token at {}".format(admin_token_path))
    token, rp_id, _hub, detail = open_window(admin_base, admin)
    if not token:
        return _result(False, "window", None, detail)
    gw = gateway.rstrip("/")
    try:
        rc, body = _http("POST", gw + "/auth/pair/init",
                         {"spec_version": SPEC_VERSION, "pairing_token": token,
                          "device_label": DEVICE_LABEL, "client_version": "walk-probe/1"})
    except Exception as exc:
        return _result(False, "init", None, "no answer from /auth/pair/init ({})".format(str(exc)[:80]))
    if rc != 200:
        return _result(False, "init", rc, body[:160])
    try:
        init = json.loads(body)
        challenge = init["registration_challenge"]
        rp = init.get("rp_id") or rp_id
    except Exception:
        return _result(False, "init", rc, "init answered 200 without registration_challenge")
    try:
        reg, _key = build_register(token, challenge, rp, "https://" + rp)
    except ImportError:
        return _result(False, "crypto", None, "this python has no `cryptography`; run with the Ostler venv")
    try:
        rc, body = _http("POST", gw + "/auth/pair/register", reg)
    except Exception as exc:
        return _result(False, "register", None, "no answer from /auth/pair/register ({})".format(str(exc)[:80]))
    if rc != 200:
        return _result(False, "register", rc, body[:200])
    try:
        dev = json.loads(body).get("device_token")
    except Exception:
        dev = None
    if not dev:
        return _result(False, "register", rc, "register answered 200 without device_token")
    replay_http = None
    if replay:
        # CONTROL: the token register just spent must be refused. A token
        # that still opens init after a successful register is a standing key.
        try:
            replay_http, _ = _http("POST", gw + "/auth/pair/init",
                                   {"spec_version": SPEC_VERSION, "pairing_token": token,
                                    "device_label": DEVICE_LABEL})
        except Exception:
            replay_http = None
    return _result(True, "register", rc, "paired through /auth/pair/init + /auth/pair/register",
                   dev, replay_http)


def legacy(admin_base, gateway, admin_token_path):
    """The OLD probe flow, for the red arm only: 6-digit code -> POST /pair."""
    admin = _admin(admin_token_path)
    if not admin:
        return _result(False, "admin", None, "no admin token")
    rc, body = _http("POST", admin_base.rstrip("/") + "/admin/paircode/new", b"",
                     {"Authorization": "Bearer " + admin})
    try:
        code = json.loads(body).get("pairing_code")
    except Exception:
        code = None
    if not code:
        return _result(False, "code", rc, "no pairing_code")
    rc, body = _http("POST", gateway.rstrip("/") + "/pair", b"", {"X-Pairing-Code": code})
    try:
        tok = json.loads(body).get("token")
    except Exception:
        tok = None
    return _result(bool(tok), "legacy-pair", rc, body[:160], tok)


def find_python(candidates=None):
    """First interpreter that can import `cryptography`, or None."""
    import subprocess
    for py in candidates or [os.environ.get("OSTLER_PAIR_PY", ""),
                             os.path.expanduser("~/.ostler/.venv/bin/python3"),
                             sys.executable, "python3"]:
        if not py:
            continue
        try:
            if subprocess.run([py, "-c", "import cryptography"], capture_output=True,
                              timeout=20).returncode == 0:
                return py
        except Exception:
            continue
    return None


def self_test():
    """Offline: the register body is internally consistent with the Hub's checks."""
    fails = []
    # HKDF against RFC 5869 test case 1.
    okm = hkdf_sha256(bytes.fromhex("0b" * 22), bytes.fromhex("000102030405060708090a0b0c"),
                      bytes.fromhex("f0f1f2f3f4f5f6f7f8f9"), 42)
    if okm.hex() != ("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf"
                     "34007208d5b887185865"):
        fails.append("HKDF does not match RFC 5869 test case 1")
    try:
        from cryptography.hazmat.primitives import hashes
        from cryptography.hazmat.primitives.asymmetric import ec
    except ImportError:
        print("SELF-TEST CANNOT-RUN: no `cryptography` in this python")
        return 78
    ch = b64u(os.urandom(32))
    body, key = build_register("synthetic-token", ch, "ostler-hub.local", "https://ostler-hub.local")
    cd = json.loads(b64u_decode(body["client_data_json"]))
    if cd["type"] != "webauthn.create" or cd["challenge"] != ch:
        fails.append("registration clientDataJSON type/challenge wrong")
    cdg = json.loads(body["assertion_client_data_json"])
    if cdg["type"] != "webauthn.get" or cdg["challenge"] != ch:
        fails.append("assertion clientDataJSON type/challenge wrong")
    ad = b64u_decode(body["authenticator_data"])
    signed = ad + hashlib.sha256(body["assertion_client_data_json"].encode()).digest()
    try:
        key.public_key().verify(b64u_decode(body["signature"]), signed, ec.ECDSA(hashes.SHA256()))
    except Exception:
        fails.append("assertion signature does not verify")
    prf = b64u_decode(body["prf_output"])
    if b64u_decode(body["companion_proof"]) != companion_proof(prf) or len(prf) != 32:
        fails.append("companion_proof is not HMAC(KEK(prf))")
    att = b64u_decode(body["attestation_object"])
    if b"authData" not in att or b"none" not in att:
        fails.append("attestation object lacks fmt none / authData")
    # MUTANT: a wrong challenge must not verify as the server's.
    bad, _ = build_register("t", b64u(os.urandom(32)), "ostler-hub.local", "https://x")
    if json.loads(bad["assertion_client_data_json"])["challenge"] == ch:
        fails.append("mutant: a different challenge produced the same clientData")
    if fails:
        print("SELF-TEST FAIL: " + "; ".join(fails))
        return 1
    print("SELF-TEST PASS: HKDF matches RFC 5869, clientData types and challenge bind, "
          "the ES256 assertion verifies, companion_proof = HMAC(KEK(prf))")
    return 0


def main(argv):
    if argv[:1] == ["--self-test"]:
        return self_test()
    if argv[:1] in (["pair"], ["legacy"]):
        a = dict(zip(argv[1::2], argv[2::2]))
        args = (a.get("--admin-base", "http://127.0.0.1:8000"),
                a.get("--gateway", "https://127.0.0.1:8443"),
                a.get("--admin-token-path", "~/.ostler/secrets/zeroclaw_admin_token"))
        if argv[0] == "pair":
            print(json.dumps(pair(*args, replay=a.get("--replay") == "1")))
        else:
            print(json.dumps(legacy(*args)))
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
