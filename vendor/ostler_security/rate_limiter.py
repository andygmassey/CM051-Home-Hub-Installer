"""Rate limiting for passphrase attempts.

Prevents brute-force attacks on the passphrase by enforcing
exponential backoff after failed attempts.

Configuration:
    MAX_ATTEMPTS = 5 before first lockout
    LOCKOUT_SECONDS = [30, 60, 120, 300, 600] – escalating delays
    LOCKOUT_WINDOW = 15 minutes – failed attempts older than this
    are not counted

Uses the audit log to track failed attempts, so rate limiting
persists across restarts.
"""
from __future__ import annotations

import time
from datetime import datetime, timedelta, timezone
from typing import Optional

from .audit_log import AuditLog, EVENT_UNLOCK_FAILED


# ── Configuration ────────────────────────────────────────────────────

MAX_ATTEMPTS = 5
LOCKOUT_WINDOW_MINUTES = 15
LOCKOUT_SECONDS = [30, 60, 120, 300, 600]  # Escalating delays
TOKEN_EXPIRY_SECONDS = 60  # BT9R3-3: auth tokens expire after 60 seconds


class RateLimiter:
    """Rate limiter for passphrase unlock attempts."""

    def __init__(self, audit_log: AuditLog):
        self.audit_log = audit_log
        self._consecutive_failures = 0
        self._locked_until: Optional[float] = None
        # BT8-2: initialise to None, not empty string (empty string was matchable)
        self._expected_token: Optional[str] = None
        self._token_issued_at: Optional[float] = None  # BT9R3-3: token expiry

    def check(self) -> tuple[bool, str]:
        """Check if an unlock attempt is allowed right now.

        Returns:
            (allowed, message) – if not allowed, message says how long to wait.
        """
        # Check if currently locked out
        if self._locked_until and time.time() < self._locked_until:
            remaining = int(self._locked_until - time.time())
            return False, (
                f"Too many failed attempts. Try again in {remaining} seconds."
            )

        # Count failures since the most recent success OR the window start,
        # whichever is more recent (IF-3 fix)
        window_start = (
            datetime.now(timezone.utc) - timedelta(minutes=LOCKOUT_WINDOW_MINUTES)
        ).isoformat()

        # Find most recent success
        recent_events = self.audit_log.recent(limit=100)
        last_success_time = None
        for event in recent_events:
            if event.get("event_type") == "system_unlock" and event.get("success") == 1:
                last_success_time = event["timestamp"]
                break

        # Count failures after the most recent success or window start
        count_after = last_success_time if last_success_time and last_success_time > window_start else window_start
        recent_failures = self.audit_log.failed_unlocks_since(count_after)

        if recent_failures >= MAX_ATTEMPTS:
            # Calculate lockout duration based on how many times we've exceeded
            lockout_index = min(
                (recent_failures - MAX_ATTEMPTS) // MAX_ATTEMPTS,
                len(LOCKOUT_SECONDS) - 1,
            )
            lockout_duration = LOCKOUT_SECONDS[lockout_index]
            self._locked_until = time.time() + lockout_duration
            return False, (
                f"Too many failed attempts ({recent_failures} in the last "
                f"{LOCKOUT_WINDOW_MINUTES} minutes). "
                f"Try again in {lockout_duration} seconds."
            )

        return True, "OK"

    def record_failure(self) -> None:
        """Record a failed unlock attempt.

        BT9R3-3: also invalidates any outstanding auth token.
        """
        self._consecutive_failures += 1
        self._expected_token = None
        self._token_issued_at = None

    def record_success(self, _auth_token: Optional[str] = None) -> None:
        """Record a successful unlock – resets the lockout state.

        FA-3: requires _auth_token from the unlock flow to prevent
        unauthorized callers from resetting the rate limiter.
        """
        # BT10-6 / ATK-6: defeat the record_success timing side-channel.
        #
        # The previous code short-circuited on `self._expected_token is
        # None or _auth_token is None` BEFORE calling compare_digest.
        # That meant an attacker polling this method could distinguish
        # "a token is currently outstanding" (slow path – compare_digest
        # runs) from "no token outstanding" (fast path – early return
        # skips the expensive string compare). That leaks state that
        # the API otherwise doesn't expose.
        #
        # Fix: always run compare_digest against a fixed-length dummy
        # so timing is (approximately) uniform regardless of whether
        # _expected_token was set. Also compute the expiry check
        # unconditionally so the "valid-but-expired" path doesn't
        # diverge in timing from "invalid token". Gate on the combined
        # booleans at the end.
        import secrets as _secrets

        now = time.time()
        # secrets.token_hex(16) always produces 32-char strings, so the
        # dummy matches the expected length. compare_digest is length-
        # safe but fixed length keeps the work constant per call.
        dummy_token = "0" * 32

        expected_for_compare = (
            self._expected_token
            if self._expected_token is not None
            else dummy_token
        )
        provided_for_compare = (
            _auth_token if _auth_token is not None else dummy_token
        )
        tokens_equal = _secrets.compare_digest(
            provided_for_compare, expected_for_compare,
        )

        token_issued = self._token_issued_at
        token_age = now - (token_issued if token_issued is not None else 0.0)
        not_expired = (
            token_issued is not None and token_age <= TOKEN_EXPIRY_SECONDS
        )

        token_valid = (
            self._expected_token is not None
            and _auth_token is not None
            and tokens_equal
            and not_expired
        )

        # Clear expired token state even when rejecting, so a subsequent
        # call doesn't keep seeing the same stale token. Done AFTER the
        # computation above to keep that work uniform per call.
        if token_issued is not None and token_age > TOKEN_EXPIRY_SECONDS:
            self._expected_token = None
            self._token_issued_at = None

        if not token_valid:
            return  # Silent reject – don't help attackers debug

        self._consecutive_failures = 0
        self._locked_until = None
        # BT8-3: invalidate token after use (prevent replay)
        self._expected_token = None
        self._token_issued_at = None
        from .audit_log import EVENT_UNLOCK
        self.audit_log.log(EVENT_UNLOCK, "rate_limiter", details="unlock_success")

    def generate_auth_token(self) -> str:
        """Generate a one-time token for record_success. Called by check()
        when an attempt is allowed – the caller passes this to
        record_success() after verifying the passphrase.

        BT9-5: idempotent – returns existing token if one is active
        (not expired), preventing concurrent callers from invalidating
        each other.
        """
        # Return existing token if still valid
        if self._expected_token is not None and self._token_issued_at is not None:
            if (time.time() - self._token_issued_at) <= TOKEN_EXPIRY_SECONDS:
                return self._expected_token
            # Token expired – generate a new one
            self._expected_token = None
            self._token_issued_at = None

        import secrets as _secrets
        self._expected_token = _secrets.token_hex(16)
        self._token_issued_at = time.time()
        return self._expected_token
