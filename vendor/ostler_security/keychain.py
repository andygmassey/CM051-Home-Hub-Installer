"""Python client for the Swift helper's Keychain operations.

Stores wrapped DEKs (and other small binary secrets) in the macOS
Keychain with explicit access controls that the `security` CLI
cannot set:

    kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    kSecAttrSynchronizable = false

Why go through the Swift helper for this
----------------------------------------
The `security` command-line tool is simpler and needs no subprocess
dance, but it defaults to `kSecAttrAccessibleWhenUnlocked` (no
"ThisDeviceOnly") and has no flag to change accessibility. That
would allow Time Machine backups to carry the wrapped DEK to a
separate volume – weakening the "passkey is hardware-bound, wrapped
DEK is device-scoped" invariant that passkey auth relies on. So we
route Keychain writes through the same Swift helper that does
passkey ops. One Apple-framework bridge, one set of rules.

Service / account conventions
-----------------------------

Every Ostler Keychain item uses the same service identifier,
distinguished by account suffix keyed by purpose.

    service = "ai.creativemachines.ostler"
    account = "wrapped_dek:<thread_id>"       -> primary-wrapped DEK
              "wrapped_recovery:<thread_id>"  -> recovery-wrapped DEK

The item value is always the raw bytes (40 for wrapped DEK). Python
base64-encodes for JSON transport; the Swift helper decodes before
storing the raw bytes via Security.framework.
"""
from __future__ import annotations

import base64
import binascii
from dataclasses import dataclass
from typing import Optional

from ostler_security import webauthn_client as _wac


# ── Constants ────────────────────────────────────────────────────────

KEYCHAIN_SERVICE = "ai.creativemachines.ostler"

# Account-name templates. Use `account_wrapped_dek(thread_id)` / etc.
# rather than formatting these by hand in callers – keeps the format
# in one place so a typo breaks one test, not silently different
# accounts in different code paths.
_ACCOUNT_WRAPPED_DEK_TEMPLATE = "wrapped_dek:{thread_id}"
_ACCOUNT_WRAPPED_RECOVERY_TEMPLATE = "wrapped_recovery:{thread_id}"


def account_wrapped_dek(thread_id: str = "default") -> str:
    return _ACCOUNT_WRAPPED_DEK_TEMPLATE.format(thread_id=thread_id)


def account_wrapped_recovery(thread_id: str = "default") -> str:
    return _ACCOUNT_WRAPPED_RECOVERY_TEMPLATE.format(thread_id=thread_id)


# ── Result types ─────────────────────────────────────────────────────

@dataclass(frozen=True)
class KeychainResult:
    """Generic outcome for set / delete / exists. Callers check
    `ok` and look at `error_code` / `message` on failure; on success
    the relevant boolean (`created`, `deleted`, `exists`) is populated."""
    ok: bool
    created: Optional[bool] = None
    deleted: Optional[bool] = None
    exists: Optional[bool] = None
    error_code: Optional[str] = None
    message: Optional[str] = None


@dataclass(frozen=True)
class KeychainGetResult:
    ok: bool
    value: Optional[bytes] = None
    error_code: Optional[str] = None
    message: Optional[str] = None


# ── Helper invocation ────────────────────────────────────────────────

def _invoke(request: dict) -> dict:
    """Reuse webauthn_client._run_helper so the subprocess plumbing
    (helper-path env var, timeouts, error wrapping) is shared.

    Accesses a private helper deliberately – making it public would
    invite callers to bypass the typed API. The coupling is stable
    within this package.
    """
    return _wac._run_helper(request, timeout=_wac.DEFAULT_TIMEOUT_SECONDS)


# ── Public API ───────────────────────────────────────────────────────

def set_item(
    *, service: str, account: str, value: bytes
) -> KeychainResult:
    """Store raw bytes under (service, account). Upsert – overwrites
    any existing value for the same key."""
    if not isinstance(value, (bytes, bytearray)):
        raise TypeError(
            f"keychain value must be bytes, got {type(value).__name__}"
        )
    response = _invoke({
        "op": "keychain_set",
        "service": service,
        "account": account,
        "value_b64": base64.b64encode(bytes(value)).decode("ascii"),
    })
    if not response.get("ok"):
        return KeychainResult(
            ok=False,
            error_code=response.get("error_code", _wac.ERROR_INTERNAL),
            message=response.get("message"),
        )
    return KeychainResult(ok=True, created=bool(response.get("created", False)))


def get_item(*, service: str, account: str) -> KeychainGetResult:
    """Retrieve raw bytes for (service, account). `ok=False` with
    `error_code=KEYCHAIN_NOT_FOUND` if the item doesn't exist;
    caller decides whether that's an error or expected."""
    response = _invoke({
        "op": "keychain_get",
        "service": service,
        "account": account,
    })
    if not response.get("ok"):
        return KeychainGetResult(
            ok=False,
            error_code=response.get("error_code", _wac.ERROR_INTERNAL),
            message=response.get("message"),
        )
    value_b64 = response.get("value_b64")
    if not isinstance(value_b64, str):
        return KeychainGetResult(
            ok=False,
            error_code=_wac.ERROR_INTERNAL,
            message="Helper returned no value_b64",
        )
    try:
        value = base64.b64decode(value_b64)
    except (ValueError, binascii.Error):
        return KeychainGetResult(
            ok=False,
            error_code=_wac.ERROR_INTERNAL,
            message="Helper returned invalid base64",
        )
    return KeychainGetResult(ok=True, value=value)


def delete_item(*, service: str, account: str) -> KeychainResult:
    """Delete the item. Idempotent – deleting something absent is
    success with `deleted=False`."""
    response = _invoke({
        "op": "keychain_delete",
        "service": service,
        "account": account,
    })
    if not response.get("ok"):
        return KeychainResult(
            ok=False,
            error_code=response.get("error_code", _wac.ERROR_INTERNAL),
            message=response.get("message"),
        )
    return KeychainResult(ok=True, deleted=bool(response.get("deleted", False)))


def item_exists(*, service: str, account: str) -> KeychainResult:
    response = _invoke({
        "op": "keychain_exists",
        "service": service,
        "account": account,
    })
    if not response.get("ok"):
        return KeychainResult(
            ok=False,
            error_code=response.get("error_code", _wac.ERROR_INTERNAL),
            message=response.get("message"),
        )
    return KeychainResult(ok=True, exists=bool(response.get("exists", False)))


# ── Convenience wrappers for the two Ostler item types ─────────────

def store_wrapped_dek(
    wrapped: bytes, *, thread_id: str = "default"
) -> KeychainResult:
    """Store the primary-KEK-wrapped DEK. 40-byte AES-KW output."""
    return set_item(
        service=KEYCHAIN_SERVICE,
        account=account_wrapped_dek(thread_id),
        value=wrapped,
    )


def load_wrapped_dek(*, thread_id: str = "default") -> KeychainGetResult:
    return get_item(
        service=KEYCHAIN_SERVICE,
        account=account_wrapped_dek(thread_id),
    )


def store_wrapped_recovery(
    wrapped: bytes, *, thread_id: str = "default"
) -> KeychainResult:
    """Store the recovery-KEK-wrapped DEK (the 2nd copy that allows
    unwrap via BIP39 phrase). Same 40-byte AES-KW output shape."""
    return set_item(
        service=KEYCHAIN_SERVICE,
        account=account_wrapped_recovery(thread_id),
        value=wrapped,
    )


def load_wrapped_recovery(*, thread_id: str = "default") -> KeychainGetResult:
    return get_item(
        service=KEYCHAIN_SERVICE,
        account=account_wrapped_recovery(thread_id),
    )
