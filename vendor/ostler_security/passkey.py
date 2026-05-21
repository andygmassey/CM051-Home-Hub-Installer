"""Top-level orchestrator for passkey-based unlock.

Ties `webauthn_client`, `key_derivation`, `keychain`, and `audit_log`
together into the three flows the setup wizard + app-launch path
need:

    setup(user_name)                    → first-run: generate DEK,
                                           register passkey, wrap DEK
                                           both ways, persist
    unlock_with_passkey()               → app launch: Touch ID prompt,
                                           unwrap primary-wrapped DEK
    unlock_with_recovery(phrase)        → recovery: BIP39 phrase,
                                           unwrap recovery-wrapped DEK
    rebind_after_recovery(dek, name)    → post-recovery: register new
                                           passkey, re-wrap DEK

The module deliberately does NOT touch `passphrase.py`, `setup_wizard.py`,
or `auto_lock.py` – those get rewired in Day 3. Passkey auth here is
additive; the existing passphrase path keeps working until the wizard
is explicitly swapped.

Public `credential_id` persistence
----------------------------------
The credential_id is a public handle – it's not secret, just a
pointer to "which passkey to use". Stored in a plain file at
`$HOME/.ostler/security/passkey.json` alongside the PRF eval input
so subsequent `unlock_with_passkey()` calls know which credential to
request (and the iOS Companion can be given the same file for sync).
"""
from __future__ import annotations

import json
import logging
import os
import secrets
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

from cryptography.hazmat.primitives.keywrap import InvalidUnwrap

from ostler_security import audit_log as _audit
from ostler_security import key_derivation as _kd
from ostler_security import keychain as _keychain
from ostler_security import webauthn_client as _wac


log = logging.getLogger(__name__)


# ── Public handle file ───────────────────────────────────────────────

DEFAULT_HANDLE_DIR = Path.home() / ".ostler" / "security"
DEFAULT_HANDLE_FILE = DEFAULT_HANDLE_DIR / "passkey.json"


def handle_file() -> Path:
    """Path to the public-handle JSON file. Overridable via env for tests."""
    override = os.environ.get("OSTLER_PASSKEY_HANDLE_FILE")
    if override:
        return Path(override)
    return DEFAULT_HANDLE_FILE


def _write_handle(credential_id: str, user_handle: str) -> None:
    path = handle_file()
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    payload = {
        "credential_id": credential_id,
        "user_handle": user_handle,
        "rp_id": _wac.RP_ID,
    }
    tmp.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    os.replace(tmp, path)


def _read_handle() -> Optional[dict]:
    path = handle_file()
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        log.warning("passkey.json unreadable: %s", exc)
        return None


# ── Result types ─────────────────────────────────────────────────────

@dataclass(frozen=True)
class SetupResult:
    """Outcome of `passkey.setup()`.

    **Caller responsibility for `dek`**: the 32-byte DEK is returned
    so callers can immediately open SQLCipher without a second Touch
    ID prompt. Once consumed, the caller MUST NOT retain the bytes
    object beyond its immediate use – no logging, no serialisation,
    no long-lived variables.

    The DEK lives here as an immutable `bytes`; Python cannot
    zeroize immutable bytes. Callers that want defence-in-depth can
    copy it into a bytearray via `bytearray(result.dek)` and zeroize
    via `ostler_security._memory.zeroize()` after use – see
    SECURITY_MODEL.md for the full runtime-scrub story.
    """
    ok: bool
    dek: Optional[bytes] = None
    recovery_phrase: Optional[str] = None
    credential_id: Optional[str] = None
    error_code: Optional[str] = None
    message: Optional[str] = None


@dataclass(frozen=True)
class UnlockResult:
    """Outcome of `passkey.unlock_with_passkey()` or
    `passkey.unlock_with_recovery()`.

    Same `dek` caller-responsibility rules as `SetupResult` – the
    field is returned for immediate use; callers MUST NOT persist
    or log. See SECURITY_MODEL.md.
    """
    ok: bool
    dek: Optional[bytes] = None
    error_code: Optional[str] = None
    message: Optional[str] = None


@dataclass(frozen=True)
class RebindResult:
    """Outcome of `passkey.rebind_after_recovery()`. Does not carry a
    DEK – the caller already had one when they invoked rebind."""
    ok: bool
    credential_id: Optional[str] = None
    error_code: Optional[str] = None
    message: Optional[str] = None


# ── Orchestration ────────────────────────────────────────────────────

def setup(
    user_name: str,
    user_display_name: Optional[str] = None,
    *,
    thread_id: str = "default",
) -> SetupResult:
    """First-run: generate a DEK, register a passkey, wrap the DEK
    under both the primary KEK (from passkey PRF) AND the recovery
    KEK (from a freshly-generated BIP39 phrase), store both wrapped
    copies + the public credential_id handle.

    Returns the DEK so the caller can immediately open SQLCipher
    with it AND the recovery phrase so the wizard can display it
    once for the user to write down. Neither is persisted by this
    module – callers own that.
    """
    user_display_name = user_display_name or user_name

    # 1. Register passkey via Swift helper (Touch ID prompt on real
    #    machines; stubbed-success on the mock helper).
    user_id = secrets.token_bytes(16)
    reg = _wac.register(
        user_id=user_id,
        user_name=user_name,
        user_display_name=user_display_name,
    )
    if not reg.ok:
        # Register failed before anything was persisted – nothing to
        # clean up, just bubble.
        _audit.log_event(
            _audit.EVENT_PASSKEY_ASSERT_FAILED,
            source="passkey.setup",
            details=f"register failed: {reg.error_code}",
            success=False,
        )
        return SetupResult(
            ok=False,
            error_code=reg.error_code,
            message=reg.message,
        )

    # 2. Generate DEK + recovery phrase.
    dek = _kd.generate_dek()
    phrase = _kd.generate_bip39_phrase()

    # 3. Derive both KEKs.
    primary_kek = _kd.derive_primary_kek(reg.prf_output, thread_id=thread_id)
    recovery_seed = _kd.bip39_phrase_to_seed(phrase)
    recovery_kek = _kd.derive_recovery_kek(recovery_seed, thread_id=thread_id)

    # 4. Wrap the same DEK under both KEKs and persist.
    wrapped_primary = _kd.wrap_dek(dek, primary_kek)
    wrapped_recovery = _kd.wrap_dek(dek, recovery_kek)

    store_primary = _keychain.store_wrapped_dek(
        wrapped_primary, thread_id=thread_id
    )
    if not store_primary.ok:
        return SetupResult(
            ok=False,
            error_code=store_primary.error_code,
            message=f"store wrapped DEK: {store_primary.message}",
        )

    store_recovery = _keychain.store_wrapped_recovery(
        wrapped_recovery, thread_id=thread_id
    )
    if not store_recovery.ok:
        # Roll back the primary wrap so we don't leave a half-setup state.
        _keychain.delete_item(
            service=_keychain.KEYCHAIN_SERVICE,
            account=_keychain.account_wrapped_dek(thread_id),
        )
        return SetupResult(
            ok=False,
            error_code=store_recovery.error_code,
            message=f"store recovery-wrapped DEK: {store_recovery.message}",
        )

    # 5. Persist the public handle.
    user_handle = user_id.hex()
    _write_handle(reg.credential_id, user_handle)

    # 6. Audit + return.
    _audit.log_event(
        _audit.EVENT_PASSKEY_REGISTER,
        source="passkey.setup",
        details=f"rp_id={_wac.RP_ID} thread_id={thread_id}",
    )
    return SetupResult(
        ok=True,
        dek=dek,
        recovery_phrase=phrase,
        credential_id=reg.credential_id,
    )


def unlock_with_passkey(*, thread_id: str = "default") -> UnlockResult:
    """App-launch unlock path. Reads the handle file, prompts Touch ID
    via the Swift helper, derives KEK from PRF, unwraps the DEK."""
    handle = _read_handle()
    if handle is None:
        return UnlockResult(
            ok=False,
            error_code=_wac.ERROR_NO_CREDENTIAL,
            message=(
                f"No passkey handle at {handle_file()}. "
                "Run setup first."
            ),
        )
    credential_id = handle.get("credential_id")
    if not credential_id:
        return UnlockResult(
            ok=False,
            error_code=_wac.ERROR_NO_CREDENTIAL,
            message="Handle file missing credential_id",
        )

    # Retrieve wrapped DEK before prompting – if it's missing, no
    # point burning a Touch ID interaction only to fail afterwards.
    get = _keychain.load_wrapped_dek(thread_id=thread_id)
    if not get.ok:
        _audit.log_event(
            _audit.EVENT_PASSKEY_ASSERT_FAILED,
            source="passkey.unlock",
            details=f"wrapped DEK absent: {get.error_code}",
            success=False,
        )
        return UnlockResult(
            ok=False,
            error_code=get.error_code,
            message=get.message,
        )

    # Touch ID prompt.
    ast = _wac.assert_(credential_id=credential_id)
    if not ast.ok:
        _audit.log_event(
            _audit.EVENT_PASSKEY_ASSERT_FAILED,
            source="passkey.unlock",
            details=f"assert failed: {ast.error_code}",
            success=False,
        )
        return UnlockResult(
            ok=False,
            error_code=ast.error_code,
            message=ast.message,
        )

    kek = _kd.derive_primary_kek(ast.prf_output, thread_id=thread_id)
    try:
        dek = _kd.unwrap_dek(get.value, kek)
    except InvalidUnwrap as exc:
        # Wrong KEK = wrong passkey for this wrapped DEK. Shouldn't
        # happen under normal operation; indicates either tampering
        # of the Keychain item or a drift between credential_id and
        # the wrapped DEK stored alongside it.
        _audit.log_event(
            _audit.EVENT_PASSKEY_ASSERT_FAILED,
            source="passkey.unlock",
            details=f"InvalidUnwrap: {exc}",
            success=False,
        )
        return UnlockResult(
            ok=False,
            error_code=_wac.ERROR_INTERNAL,
            message=(
                "Wrapped DEK failed integrity check under the passkey-"
                "derived KEK. Try recovery-phrase unlock."
            ),
        )

    _audit.log_event(
        _audit.EVENT_UNLOCK,
        source="passkey.unlock",
        details=f"thread_id={thread_id}",
    )
    return UnlockResult(ok=True, dek=dek)


def unlock_with_recovery(
    phrase: str, *, thread_id: str = "default"
) -> UnlockResult:
    """Recovery path. Does NOT require Touch ID. Validates the BIP39
    phrase, derives the recovery KEK, unwraps the recovery-wrapped
    DEK. On success, the caller should invoke `rebind_after_recovery`
    to register a new passkey and re-wrap the DEK under its PRF."""
    try:
        seed = _kd.bip39_phrase_to_seed(phrase)
    except ValueError as exc:
        return UnlockResult(
            ok=False,
            error_code=_wac.ERROR_INVALID_REQUEST,
            message=str(exc),
        )

    get = _keychain.load_wrapped_recovery(thread_id=thread_id)
    if not get.ok:
        return UnlockResult(
            ok=False,
            error_code=get.error_code,
            message=get.message,
        )

    kek = _kd.derive_recovery_kek(seed, thread_id=thread_id)
    try:
        dek = _kd.unwrap_dek(get.value, kek)
    except InvalidUnwrap:
        _audit.log_event(
            _audit.EVENT_RECOVERY_KEY_USED,
            source="passkey.recovery",
            details="InvalidUnwrap – wrong recovery phrase",
            success=False,
        )
        return UnlockResult(
            ok=False,
            error_code=_wac.ERROR_INVALID_REQUEST,
            message=(
                "Recovery phrase did not unwrap the stored DEK. "
                "Double-check the phrase and try again."
            ),
        )

    _audit.log_event(
        _audit.EVENT_RECOVERY_KEY_USED,
        source="passkey.recovery",
        details=f"thread_id={thread_id}",
    )
    return UnlockResult(ok=True, dek=dek)


def rebind_after_recovery(
    dek: bytes,
    user_name: str,
    user_display_name: Optional[str] = None,
    *,
    thread_id: str = "default",
) -> RebindResult:
    """After a recovery-phrase unlock on a new device, register a fresh
    passkey and re-wrap the existing DEK under its PRF-derived KEK.

    Leaves the recovery-wrapped DEK in place (unchanged). The user
    keeps the same recovery phrase across devices; only the primary
    wrap rotates. If the phrase changes too, that's a separate flow
    not in v1 scope.
    """
    user_display_name = user_display_name or user_name
    user_id = secrets.token_bytes(16)

    reg = _wac.register(
        user_id=user_id,
        user_name=user_name,
        user_display_name=user_display_name,
    )
    if not reg.ok:
        return RebindResult(
            ok=False,
            error_code=reg.error_code,
            message=reg.message,
        )

    kek = _kd.derive_primary_kek(reg.prf_output, thread_id=thread_id)
    wrapped = _kd.wrap_dek(dek, kek)
    store = _keychain.store_wrapped_dek(wrapped, thread_id=thread_id)
    if not store.ok:
        return RebindResult(
            ok=False,
            error_code=store.error_code,
            message=store.message,
        )

    _write_handle(reg.credential_id, user_id.hex())
    _audit.log_event(
        _audit.EVENT_PASSKEY_REGISTER,
        source="passkey.rebind",
        details=f"thread_id={thread_id}",
    )
    return RebindResult(ok=True, credential_id=reg.credential_id)
