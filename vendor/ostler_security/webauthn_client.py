"""Python-side driver for the Ostler Swift passkey helper.

Spawns `ostler-passkey-helper` as a one-shot subprocess, writes one
JSON request on stdin, reads one JSON response on stdout, process exits.
See DAY_ZERO_AUDIT.md §3 for the wire protocol.

Tests use a Python mock helper (see tests/fakes/mock_passkey_helper.py)
driven via the `OSTLER_PASSKEY_HELPER` env var so CI can exercise
the subprocess path without requiring the real Swift binary or Touch ID.

Usage
-----

    from ostler_security import webauthn_client as wac

    # Setup – once per installation
    reg = wac.register(
        user_id=os.urandom(16),
        user_name="user@local",
        user_display_name="User",
        prf_salt=key_derivation.generate_prf_salt(),
    )
    if reg.ok:
        store(reg.credential_id, reg.prf_salt)
        kek = key_derivation.derive_kek_from_prf(reg.prf_output)

    # Unlock – every app launch
    ast = wac.assert_(credential_id=stored_id, prf_salt=stored_salt)
    if ast.ok:
        kek = key_derivation.derive_kek_from_prf(ast.prf_output)
"""
from __future__ import annotations

import base64
import binascii
import json
import os
import subprocess
from dataclasses import dataclass
from typing import Any, Dict, Optional


# ── Defaults / knobs ─────────────────────────────────────────────────

# Per SHARED_AUTH_SPEC.md §0: rp_id is tied to the company domain,
# not the product name. Stable across future product rebrands. A
# WebAuthn credential's rp_id is baked at registration and can't be
# changed without re-registering.
RP_ID = "creativemachines.ai"

# Per SHARED_AUTH_SPEC.md §1.1: the WebAuthn PRF extension's `first`
# evaluation input is a fixed 23-byte ASCII literal. Identical on Hub
# and Companion. **Do not parameterise this.** Every wrapped DEK
# currently in existence is derived from this exact byte string;
# changing it invalidates every user's key material. See the spec's
# Appendix B - "cleaning up" to `lifeline/prf/v1` is an explicitly-
# flagged MUST-NOT-HAPPEN deviation. (The literal `creativemachines/prf/v1`
# above is the post-rebrand-but-pre-customer namespaced form; the comment
# preserves the historical `lifeline/prf/v1` name as a do-not-touch
# reminder for the audit trail.)
PRF_EVAL_INPUT = b"creativemachines/prf/v1"

DEFAULT_HELPER_PATH = "/usr/local/bin/ostler-passkey-helper"

# macOS's own Touch ID dialog times out around 60-90s; allow a bit of
# slack for the subprocess IPC on top.
DEFAULT_TIMEOUT_SECONDS = 120.0


# ── Error codes (keep in sync with DAY_ZERO_AUDIT.md §3) ────────────

ERROR_USER_CANCELED = "USER_CANCELED"
ERROR_NO_CREDENTIAL = "NO_CREDENTIAL"
ERROR_PRF_UNSUPPORTED = "PRF_UNSUPPORTED"
ERROR_OS_TOO_OLD = "OS_TOO_OLD"
ERROR_INVALID_REQUEST = "INVALID_REQUEST"
ERROR_INTERNAL = "INTERNAL"
ERROR_TIMEOUT = "TIMEOUT"
ERROR_HELPER_NOT_FOUND = "HELPER_NOT_FOUND"


# ── Result types ─────────────────────────────────────────────────────

@dataclass(frozen=True)
class RegisterResult:
    """Outcome of a `register` call."""
    ok: bool
    credential_id: Optional[str] = None
    public_key: Optional[str] = None
    prf_output: Optional[bytes] = None
    error_code: Optional[str] = None
    message: Optional[str] = None


@dataclass(frozen=True)
class AssertResult:
    """Outcome of an `assert` call."""
    ok: bool
    credential_id: Optional[str] = None
    prf_output: Optional[bytes] = None
    error_code: Optional[str] = None
    message: Optional[str] = None


# ── Helper discovery ─────────────────────────────────────────────────

def helper_path() -> str:
    """Path to the Swift helper binary, overridable via env."""
    return os.environ.get("OSTLER_PASSKEY_HELPER", DEFAULT_HELPER_PATH)


# ── Encoding helpers ─────────────────────────────────────────────────

def _b64url(data: bytes) -> str:
    """RFC 4648 §5 base64url, no padding – WebAuthn standard."""
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _hex(data: bytes) -> str:
    return binascii.hexlify(data).decode("ascii")


def _from_hex(s: str) -> bytes:
    # Raises binascii.Error on malformed input – caller wraps as INTERNAL.
    return binascii.unhexlify(s)


# ── Core subprocess plumbing ─────────────────────────────────────────

def _run_helper(request: Dict[str, Any], *, timeout: float) -> Dict[str, Any]:
    """Spawn the helper once, post the request, return parsed response.

    Never raises on helper-reported auth errors (those come back as
    ``{"ok": false, "error_code": "...", ...}``). Only IO-level failures
    get converted to synthetic error dicts.
    """
    path = helper_path()
    if not os.path.exists(path):
        return {
            "ok": False,
            "error_code": ERROR_HELPER_NOT_FOUND,
            "message": f"Passkey helper not found at {path}",
        }

    payload = (json.dumps(request) + "\n").encode("utf-8")

    try:
        proc = subprocess.run(
            [path],
            input=payload,
            capture_output=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return {
            "ok": False,
            "error_code": ERROR_TIMEOUT,
            "message": f"Passkey helper timed out after {timeout:.0f}s",
        }
    except OSError as exc:
        return {
            "ok": False,
            "error_code": ERROR_INTERNAL,
            "message": f"Failed to invoke helper: {exc}",
        }

    stderr_text = proc.stderr.decode("utf-8", errors="replace").strip()
    if proc.returncode != 0:
        return {
            "ok": False,
            "error_code": ERROR_INTERNAL,
            "message": stderr_text or f"Helper exited {proc.returncode}",
        }

    stdout_text = proc.stdout.decode("utf-8", errors="replace").strip()
    if not stdout_text:
        return {
            "ok": False,
            "error_code": ERROR_INTERNAL,
            "message": "Helper returned empty response",
        }
    # If the helper wrote multiple lines (debug noise + response), take
    # the last non-empty line as the response.
    response_line = stdout_text.splitlines()[-1]
    try:
        return json.loads(response_line)
    except json.JSONDecodeError as exc:
        return {
            "ok": False,
            "error_code": ERROR_INTERNAL,
            "message": f"Helper returned invalid JSON: {exc}",
        }


# ── Public API ───────────────────────────────────────────────────────

def register(
    *,
    user_id: bytes,
    user_name: str,
    user_display_name: str,
    rp_id: str = RP_ID,
    timeout: float = DEFAULT_TIMEOUT_SECONDS,
) -> RegisterResult:
    """Register a new passkey and obtain a PRF output.

    Shown as a Touch ID / Face ID prompt via the Swift helper. The
    returned ``credential_id`` is the opaque handle to persist; the
    ``prf_output`` is fed to `key_derivation.derive_primary_kek()`.

    The PRF evaluation input is NOT a parameter – it is the fixed
    module constant `PRF_EVAL_INPUT` per SHARED_AUTH_SPEC.md §1.1.
    Callers cannot supply a different value because doing so would
    silently invalidate existing wrapped DEKs.
    """
    request = {
        "op": "register",
        "rp_id": rp_id,
        "user_id": _b64url(user_id),
        "user_name": user_name,
        "user_display_name": user_display_name,
        "request_prf": True,
        "prf_eval_input": _hex(PRF_EVAL_INPUT),
    }
    response = _run_helper(request, timeout=timeout)
    return _parse_register_response(response)


def assert_(
    *,
    credential_id: str,
    challenge: Optional[bytes] = None,
    rp_id: str = RP_ID,
    timeout: float = DEFAULT_TIMEOUT_SECONDS,
) -> AssertResult:
    """Authenticate with an existing passkey and obtain a PRF output.

    ``credential_id`` is the base64url handle returned from `register()`.
    The PRF evaluation input is fixed as in `register()`.
    """
    if challenge is None:
        # Fresh challenge each call. Not currently verified on the Hub
        # in v1 (the passkey ceremony exists here for the PRF output,
        # not mutual authentication), but the real WebAuthn shape still
        # demands a per-call challenge and we don't fight that.
        challenge = os.urandom(32)

    request = {
        "op": "assert",
        "rp_id": rp_id,
        "credential_id": credential_id,
        "challenge": _b64url(challenge),
        "request_prf": True,
        "prf_eval_input": _hex(PRF_EVAL_INPUT),
    }
    response = _run_helper(request, timeout=timeout)
    return _parse_assert_response(response)


# ── Response parsing ─────────────────────────────────────────────────

def _parse_register_response(r: Dict[str, Any]) -> RegisterResult:
    if not r.get("ok"):
        return RegisterResult(
            ok=False,
            error_code=r.get("error_code", ERROR_INTERNAL),
            message=r.get("message"),
        )
    try:
        prf_hex = r["prf_output"]
        prf = _from_hex(prf_hex)
    except (KeyError, binascii.Error) as exc:
        return RegisterResult(
            ok=False,
            error_code=ERROR_INTERNAL,
            message=f"Helper returned invalid prf_output: {exc}",
        )
    return RegisterResult(
        ok=True,
        credential_id=r.get("credential_id"),
        public_key=r.get("public_key"),
        prf_output=prf,
    )


def _parse_assert_response(r: Dict[str, Any]) -> AssertResult:
    if not r.get("ok"):
        return AssertResult(
            ok=False,
            error_code=r.get("error_code", ERROR_INTERNAL),
            message=r.get("message"),
        )
    try:
        prf_hex = r["prf_output"]
        prf = _from_hex(prf_hex)
    except (KeyError, binascii.Error) as exc:
        return AssertResult(
            ok=False,
            error_code=ERROR_INTERNAL,
            message=f"Helper returned invalid prf_output: {exc}",
        )
    return AssertResult(
        ok=True,
        credential_id=r.get("credential_id"),
        prf_output=prf,
    )
