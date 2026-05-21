"""Auto-lock after inactivity.

Tracks the last activity timestamp and locks the system (clears
the in-memory encryption key) after a configurable period of
inactivity.

Configuration:
    DEFAULT_TIMEOUT = 15 minutes (configurable, minimum 5 minutes)

The auto-lock is implemented as a lightweight timer that checks
on each API request whether the timeout has elapsed. No background
threads required.

Re-unlock hook
--------------
After `lock()` fires (explicit or timeout), a caller can re-unlock
without knowing WHICH authentication mechanism is in play by
invoking `reunlock()`. The actual auth – passphrase prompt, passkey
Touch ID, etc. – is injected at `AutoLock` construction time as an
optional `reunlock_callback` that returns the freshly-derived DEK
(or None on user-cancel / helper failure). This keeps AutoLock
auth-agnostic: it knows about timeouts and key zeroing, nothing
about passkeys or passphrases.
"""
from __future__ import annotations

import time
from typing import Any, Callable, Optional, Union


DEFAULT_TIMEOUT_SECONDS = 15 * 60  # 15 minutes
MIN_TIMEOUT_SECONDS = 5 * 60       # 5 minutes minimum


# Two supported callback shapes (see `_normalise_reunlock_result()`):
#
#   A. Simple bytes-returning callable:
#        def cb() -> Optional[bytes]: ...
#      Returns the 32-byte DEK or None on any failure. Used by
#      `reunlock()` in its bool-returning mode.
#
#   B. Result-object-returning callable (e.g., returning
#      `passkey.UnlockResult`):
#        def cb() -> AnyObjectWith_ok_dek_error_code_message: ...
#      The object must have `.ok` (bool) and `.dek` (bytes or None) at
#      minimum; `.error_code` (str) and `.message` (str) let
#      `reunlock_or_raise()` throw typed exceptions.
#
# Both shapes share the same parameter – `reunlock_callback`. Callers
# choose whichever fits their world and invoke `reunlock()` or
# `reunlock_or_raise()` accordingly.
ReunlockCallback = Callable[[], Any]


def _normalise_to_bytes(result: Any) -> Optional[bytes]:
    """Reduce a reunlock-callback return value to `Optional[bytes]`.

    Accepts either a raw bytes/bytearray (simple callback shape)
    or a result object with `.ok` and `.dek` attributes (rich
    shape – e.g. `passkey.UnlockResult`). Returns the DEK bytes
    on success, `None` on any failure.
    """
    if result is None:
        return None
    if isinstance(result, (bytes, bytearray)):
        return bytes(result)
    ok = getattr(result, "ok", None)
    dek = getattr(result, "dek", None)
    if ok is True and isinstance(dek, (bytes, bytearray)):
        return bytes(dek)
    return None


class AutoLock:
    """Auto-lock manager for Ostler sessions."""

    def __init__(
        self,
        timeout_seconds: int = DEFAULT_TIMEOUT_SECONDS,
        reunlock_callback: Optional[ReunlockCallback] = None,
    ):
        """Initialise the auto-lock timer.

        Args:
            timeout_seconds: Seconds of inactivity before locking.
                Minimum 5 minutes. Default 15 minutes.
            reunlock_callback: Optional zero-arg callable returning the
                freshly-derived 32-byte DEK, or None on failure.
                Invoked by `reunlock()` when the auto-lock has fired
                and a caller wants to resume the session. When not
                provided, `reunlock()` is a no-op that returns False.
        """
        self.timeout = max(timeout_seconds, MIN_TIMEOUT_SECONDS)
        self._last_activity: float = time.time()
        self._locked: bool = True  # Start locked
        self._encryption_key: Optional[bytes] = None
        self._reunlock_callback: Optional[ReunlockCallback] = reunlock_callback

    def unlock(self, encryption_key: bytes) -> None:
        """Unlock the system with the derived encryption key.

        The key is stored as a mutable bytearray so it can be securely
        zeroed on lock (ATK-1 fix).
        """
        self._encryption_key = bytearray(encryption_key)
        self._locked = False
        self._last_activity = time.time()

    def touch(self) -> None:
        """Record activity – resets the inactivity timer.

        Call this on every API request, database query, or user
        interaction to prevent auto-lock.
        """
        self._last_activity = time.time()

    def check(self) -> bool:
        """Check if the system should be locked due to inactivity.

        Returns True if still unlocked, False if locked or timed out.
        If timed out, automatically locks and clears the key.
        """
        if self._locked:
            return False

        if time.time() - self._last_activity > self.timeout:
            self.lock()
            return False

        return True

    def lock(self) -> None:
        """Manually lock the system. Securely zeros and clears the
        encryption key from memory (ATK-1 fix).

        Uses `_memory.zeroize()` for the actual scrub – see that
        module's docstring for the ctypes.memset-with-indexed-
        fallback semantics. Key bytes are genuinely cleared from the
        underlying buffer before we drop the last reference.
        """
        from . import _memory
        key = self._encryption_key
        if key is not None:
            if isinstance(key, bytearray):
                _memory.zeroize(key)
            self._encryption_key = None
        self._locked = True

    @property
    def is_locked(self) -> bool:
        """Check lock status, triggering auto-lock if timed out."""
        self.check()
        return self._locked

    @property
    def encryption_key(self) -> Optional[bytes]:
        """Get the encryption key if unlocked, None if locked.

        Automatically checks for timeout before returning.
        Returns an immutable copy so callers don't hold a reference
        to the mutable bytearray that gets zeroed on lock (BT9-3 fix).
        """
        if not self.check():
            return None
        return bytes(self._encryption_key)

    @property
    def seconds_remaining(self) -> int:
        """Seconds until auto-lock. 0 if already locked."""
        if self._locked:
            return 0
        remaining = self.timeout - (time.time() - self._last_activity)
        return max(0, int(remaining))

    def reunlock(self) -> bool:
        """Re-unlock the session after auto-lock / explicit lock.

        Delegates to the callback passed at construction time, which
        owns the actual auth step (Touch ID prompt for passkey-backed
        installations, passphrase prompt for legacy, etc.).

        Returns True on success (session is now unlocked), False on any
        failure – no callback configured, user cancelled, or the
        callback returned None. AutoLock doesn't introspect failures;
        the caller handles them based on its own UX.

        For error-specific handling (UserCanceledError vs
        NoCredentialError vs InternalError, etc.) use
        `reunlock_or_raise()` instead.

        Idempotent: if the session is already unlocked, returns True
        without re-invoking the callback. Updates the activity timer
        in that case so a 'reunlock' gesture also counts as activity.
        """
        if not self._locked:
            self._last_activity = time.time()
            return True

        if self._reunlock_callback is None:
            return False

        try:
            result = self._reunlock_callback()
        except Exception:
            # Callback exceptions are treated as auth failure. The
            # callback should map its own failure modes to `None` –
            # anything that escapes is a bug we don't want to crash
            # the session over. Typed-exception handling lives in
            # `reunlock_or_raise()`.
            return False

        fresh_key = _normalise_to_bytes(result)
        if fresh_key is None:
            return False

        self.unlock(fresh_key)
        return True

    def reunlock_or_raise(self) -> None:
        """Re-unlock, raising typed exceptions on any failure.

        Same core logic as `reunlock()` but fails loudly with an
        exception from `ostler_security.errors` instead of
        returning False. Callers that care about WHY authentication
        failed – e.g., distinguish a recoverable UserCanceled from a
        deployment-problem NoCredential – use this method.

        Exception types
        ---------------

        - No callback configured → `InternalError`
        - Callback returns None / failure result →
          the exception matching the result's `error_code`; an
          unknown code → `InternalError`
        - Callback raises `OstlerAuthError` → propagated unchanged
        - Callback raises any other exception → wrapped in
          `InternalError`

        Idempotent on already-unlocked sessions: returns without
        invoking the callback but still touches the activity timer.
        """
        # Import lazily to avoid a circular import at module load
        # time (`errors` imports from `webauthn_client`; AutoLock is
        # imported by almost everything).
        from . import errors as _errors

        if not self._locked:
            self._last_activity = time.time()
            return

        if self._reunlock_callback is None:
            raise _errors.InternalError(
                "no reunlock callback configured on this AutoLock"
            )

        try:
            result = self._reunlock_callback()
        except _errors.OstlerAuthError:
            # Callback was considerate enough to use our taxonomy –
            # let it through unchanged.
            raise
        except Exception as exc:
            raise _errors.InternalError(
                f"reunlock callback raised: {exc}"
            ) from exc

        # Rich result: look for a failure marker.
        if result is None:
            raise _errors.InternalError(
                "reunlock callback returned None – caller should "
                "map its failure modes to a specific error_code"
            )

        # Bytes shape (or bytearray): success.
        if isinstance(result, (bytes, bytearray)):
            self.unlock(bytes(result))
            return

        # Result-object shape. Both fields must be present.
        ok = getattr(result, "ok", None)
        dek = getattr(result, "dek", None)
        error_code = getattr(result, "error_code", None)
        message = getattr(result, "message", None)

        if ok is True and dek is not None:
            self.unlock(dek)
            return

        # ok is False or ambiguous → raise the matching exception.
        raise _errors.exception_for_code(error_code, message)
