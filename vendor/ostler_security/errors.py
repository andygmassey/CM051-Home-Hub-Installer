"""Typed exception hierarchy for Ostler authentication errors.

Mirrors the webauthn_client error-code taxonomy so callers that
prefer typed-except dispatch can switch on exception type instead
of string-comparing error codes.

Each exception subclass carries the same `error_code` string that
the bool-returning APIs surface, so the two worlds are
interchangeable.

Usage
-----

    try:
        auto_lock.reunlock_or_raise()
    except UserCanceledError:
        # User pressed Cancel on Touch ID – recoverable, maybe re-prompt
        ...
    except NoCredentialError:
        # No passkey on this device – offer recovery-phrase path
        ...
    except OSTooOldError:
        # Hard deployment error; tell user to upgrade macOS
        ...
    except OstlerAuthError as exc:
        # Catch-all for future unknown error codes – log and exit
        log.error("Auth failed: %s (%s)", exc.error_code, exc)

Mapping from error codes to exceptions lives in `exception_for_code()`;
callers creating exceptions from webauthn/keychain results go via
that helper rather than hand-wiring the subclass.
"""
from __future__ import annotations

from typing import Dict, Optional, Type

from . import webauthn_client as _wac


class OstlerAuthError(Exception):
    """Base class for every Ostler authentication failure.

    Always carries an `error_code` matching the webauthn_client
    constants (`USER_CANCELED`, `NO_CREDENTIAL`, etc.). Use
    `str(exc)` for the human-readable message.
    """

    #: Override in each concrete subclass to the matching
    #: webauthn_client error-code constant.
    error_code: str = "INTERNAL"

    def __init__(self, message: Optional[str] = None) -> None:
        super().__init__(message or self.error_code)


class UserCanceledError(OstlerAuthError):
    """User dismissed the Touch ID / Face ID prompt.

    Recoverable. Caller should offer to re-prompt or exit based on
    its UX.
    """
    error_code = _wac.ERROR_USER_CANCELED


class NoCredentialError(OstlerAuthError):
    """No matching passkey found on this device.

    Indicates either (a) Ostler has never been set up on this
    machine, (b) the iCloud Keychain sync that should have brought
    the passkey across hasn't happened, or (c) the credential_id
    handle file was deleted. Caller should route to the recovery
    flow.
    """
    error_code = _wac.ERROR_NO_CREDENTIAL


class PRFUnsupportedError(OstlerAuthError):
    """Authenticator doesn't support the PRF extension.

    Should not happen on macOS 15+ / iOS 18+ with iCloud Keychain
    passkeys. If this surfaces, a third-party password manager with
    partial WebAuthn support is probably the authoring provider,
    and the user needs to switch to iCloud Keychain.
    """
    error_code = _wac.ERROR_PRF_UNSUPPORTED


class OSTooOldError(OstlerAuthError):
    """Running on pre-macOS-15 / pre-iOS-18.

    Hard stop – there is no non-PRF fallback per
    SHARED_AUTH_SPEC.md §0. User must upgrade the OS.
    """
    error_code = _wac.ERROR_OS_TOO_OLD


class InvalidRequestError(OstlerAuthError):
    """Malformed input – usually surfaces during recovery-phrase
    entry when the phrase is the wrong length or contains unknown
    words. Re-prompt is appropriate."""
    error_code = _wac.ERROR_INVALID_REQUEST


class HelperNotFoundError(OstlerAuthError):
    """Swift passkey helper binary is missing at the expected path.

    Deployment problem – the Ostler installer didn't place the
    helper correctly, or the binary was deleted. Not user-
    recoverable; caller should surface a diagnostic message and
    exit.
    """
    error_code = _wac.ERROR_HELPER_NOT_FOUND


class AuthTimeoutError(OstlerAuthError):
    """Swift helper exceeded its timeout waiting for user input.

    Named `AuthTimeoutError` (not `TimeoutError`) to avoid shadowing
    the built-in. Usually means the user walked away from the Touch
    ID prompt. Recoverable via re-prompt.
    """
    error_code = _wac.ERROR_TIMEOUT


class InternalError(OstlerAuthError):
    """Catch-all for anything that doesn't map to a specific
    error code. Logged as a bug-report trigger."""
    error_code = _wac.ERROR_INTERNAL


# Keychain-side codes from Swift helper (KeychainOps.swift). Not in
# webauthn_client's constant list – they only surface on the
# Security-framework path, but they're part of the overall taxonomy.

class KeychainNotFoundError(OstlerAuthError):
    """The requested Keychain item does not exist."""
    error_code = "KEYCHAIN_NOT_FOUND"


class KeychainDuplicateError(OstlerAuthError):
    """A Keychain item with the same (service, account) already
    exists and the requested op was an add-only, not an upsert.
    Our set_item() path always upserts, so this should not
    surface in normal use."""
    error_code = "KEYCHAIN_DUPLICATE"


class KeychainDeniedError(OstlerAuthError):
    """macOS refused the Keychain operation – either the user
    denied a 'allow Ostler to access the Keychain?' prompt or
    the item's access-control attributes block the current
    context."""
    error_code = "KEYCHAIN_DENIED"


# ── Code → exception-class map ──────────────────────────────────────

_CODE_TO_EXCEPTION: Dict[str, Type[OstlerAuthError]] = {
    _wac.ERROR_USER_CANCELED: UserCanceledError,
    _wac.ERROR_NO_CREDENTIAL: NoCredentialError,
    _wac.ERROR_PRF_UNSUPPORTED: PRFUnsupportedError,
    _wac.ERROR_OS_TOO_OLD: OSTooOldError,
    _wac.ERROR_INVALID_REQUEST: InvalidRequestError,
    _wac.ERROR_HELPER_NOT_FOUND: HelperNotFoundError,
    _wac.ERROR_TIMEOUT: AuthTimeoutError,
    _wac.ERROR_INTERNAL: InternalError,
    "KEYCHAIN_NOT_FOUND": KeychainNotFoundError,
    "KEYCHAIN_DUPLICATE": KeychainDuplicateError,
    "KEYCHAIN_DENIED": KeychainDeniedError,
}


def exception_for_code(
    error_code: Optional[str], message: Optional[str] = None
) -> OstlerAuthError:
    """Construct the correct exception subclass for an error code.

    Unknown codes map to `InternalError` – a defensive default
    that makes sure a caller switching on specific subclasses
    doesn't silently ignore a new code added upstream.
    """
    cls = _CODE_TO_EXCEPTION.get(error_code or "", InternalError)
    return cls(message)


__all__ = [
    "OstlerAuthError",
    "UserCanceledError",
    "NoCredentialError",
    "PRFUnsupportedError",
    "OSTooOldError",
    "InvalidRequestError",
    "HelperNotFoundError",
    "AuthTimeoutError",
    "InternalError",
    "KeychainNotFoundError",
    "KeychainDuplicateError",
    "KeychainDeniedError",
    "exception_for_code",
]
