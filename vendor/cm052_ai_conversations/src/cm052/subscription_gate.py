"""Subscription gate -- single source of truth for whether ongoing intelligence is active.

The Hub runs ingestion pipelines (iMessage, email, WhatsApp, Safari, etc.),
brief composition, and Reminders push under an active subscription. Every
pipeline calls ``is_active_or_grace()`` at the top of its work loop. When
False, the pipeline pauses (logs + sleeps + continues) but does NOT crash
or exit -- the Hub stays healthy and resumes within 60s of reactivation.

Apple-restraint UX language: never "your data is locked". The customer's
existing data stays accessible regardless of subscription state (Obsidian
vault, two-zone visible data layout, exports). Only ongoing intelligence
pauses.

State storage: a single JSON file at ``~/.ostler/state/subscription_state.json``.
Override via ``OSTLER_SUBSCRIPTION_STATE`` env var for tests.

Fail-open posture: if the Hub cannot reach the iOS Companion (customer on
holiday, network outage, expired StoreKit cache), we treat the customer as
legitimate so long as the last successful validation was within the offline
grace window. We never punish customers on infrastructure problems we
cannot observe.

Sync paths:
1. ``activate_first_month_free()`` -- called by install.sh after license
   verification. Hub gets 30 days of Pro for free.
2. ``refresh_from_companion()`` -- called when the iOS Companion pushes a
   fresh StoreKit receipt via ``POST /api/v1/subscription/receipt``.
3. ``expire_check()`` -- run periodically (e.g. by the Hub status
   broadcaster). Walks the state forward through active -> grace -> inactive
   as time passes.

Helper contract (the only public surface other pipelines depend on):

- ``is_active_or_grace() -> bool`` -- True if the customer's ongoing
  intelligence should keep running.
- ``state_dict() -> dict`` -- for the Doctor banner + diagnostics.
- ``refresh_from_companion(receipt_b64, expires_at_iso) -> None`` --
  writer called when the iOS Companion pushes a fresh receipt.
- ``activate_first_month_free(purchase_date_iso) -> None`` -- writer
  called by install.sh.
- ``expire_check() -> None`` -- periodic state walker.

Per locked memory feedback_subscription_gating_v1 + the 2026-05-27
pricing decision: Hub GBP 99 one-time + Pro GBP 9.99/mo with first 30 days
free at install time.
"""

from __future__ import annotations

import json
import os
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Optional

# Grace window between subscription lapse and ongoing intelligence pausing.
# Within this window, status is "grace" and pipelines still run.
GRACE_DAYS = 14

# Offline grace: if the Hub cannot validate (no Companion contact, network
# outage), pipelines keep running so long as the last successful validation
# was within this window. Apple-restraint: never block a legitimate customer
# on infrastructure failure we cannot observe.
OFFLINE_GRACE_DAYS = 30

# Status enum -- string-typed for JSON-on-disk simplicity.
STATUS_ACTIVE = "active"
STATUS_GRACE = "grace"
STATUS_INACTIVE = "inactive"

# Source enum -- records how the current state landed (for support + UX).
SOURCE_FIRST_MONTH_FREE = "first_month_free"
SOURCE_COMPANION = "companion"
SOURCE_HUB_INITIAL = "hub_initial"
SOURCE_DEFAULT = "default"


def _state_file() -> Path:
    """Resolve the state-file path lazily (allows env-override for tests).

    ``OSTLER_SUBSCRIPTION_STATE`` overrides the default. Otherwise the
    canonical location is ``~/.ostler/state/subscription_state.json``.
    """
    override = os.environ.get("OSTLER_SUBSCRIPTION_STATE")
    if override:
        return Path(override)
    return Path.home() / ".ostler" / "state" / "subscription_state.json"


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _parse_iso(value: Optional[str]) -> Optional[datetime]:
    """Parse an ISO-8601 string (with either ``Z`` or ``+HH:MM``).

    Returns None on missing or unparseable input. Never raises.
    """
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return None


def _load() -> dict:
    """Read the state file. Returns a safe default if missing or corrupt.

    Corrupt files do NOT raise -- they degrade to the default-inactive
    state. The fail-open offline-grace branch in ``is_active_or_grace``
    handles the case where corruption coincides with a recently-valid
    customer.
    """
    path = _state_file()
    if not path.exists():
        return {"status": STATUS_INACTIVE, "source": SOURCE_DEFAULT}
    try:
        raw = path.read_text()
        parsed = json.loads(raw)
        if not isinstance(parsed, dict):
            return {"status": STATUS_INACTIVE, "source": SOURCE_DEFAULT}
        return parsed
    except (OSError, json.JSONDecodeError):
        return {"status": STATUS_INACTIVE, "source": SOURCE_DEFAULT}


def _write(state: dict) -> None:
    """Persist state to disk. Creates parent dir if needed."""
    path = _state_file()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(state, indent=2))


def _iso_now() -> str:
    """Return current UTC time as extended ISO-8601 Zulu."""
    return _now().isoformat().replace("+00:00", "Z")


def is_active_or_grace() -> bool:
    """Return True if ongoing intelligence should keep running.

    Resolution order (each branch short-circuits):

    1. ``status == "active"``: subscription valid. Return True.
    2. ``status == "grace"`` AND ``grace_period_end`` is in the future:
       within the 14-day grace window after lapse. Return True.
    3. **Fail-open offline grace**: ``last_validated_at`` was within
       the last 30 days. We assume the customer is still legitimate even
       if the Hub can no longer reach the Companion (customer on holiday,
       Apple's StoreKit server transient down, etc.). Returns True.
    4. Otherwise: subscription is inactive. Return False.

    Apple-restraint posture: branches 1-3 are designed so that legitimate
    customers cannot be locked out by infrastructure failure we cannot
    observe. A genuinely-cancelled subscription only blocks once BOTH
    the grace window has passed AND there has been no Companion contact
    for 30 days.
    """
    state = _load()
    status = state.get("status", STATUS_INACTIVE)

    if status == STATUS_ACTIVE:
        return True

    if status == STATUS_GRACE:
        grace_end = _parse_iso(state.get("grace_period_end"))
        if grace_end is not None and grace_end > _now():
            return True

    # Fail-open: even if status reads "inactive" (or "grace" with grace_end
    # already past), if Companion sync recently confirmed the customer was
    # legitimate, give them the benefit of the doubt. The customer's actual
    # subscription will be re-validated next time Companion comes online.
    last_validated = _parse_iso(state.get("last_validated_at"))
    if last_validated is not None:
        age = _now() - last_validated
        if age < timedelta(days=OFFLINE_GRACE_DAYS):
            return True

    return False


def state_dict() -> dict:
    """Snapshot the current state. Read-only; for Doctor banner + diagnostics."""
    return _load()


def refresh_from_companion(receipt_b64: str, expires_at_iso: str) -> None:
    """Called when iOS Companion pushes a fresh StoreKit receipt.

    Writes a new active-state with the provided expiry. Resets
    ``grace_period_end`` (so a previously-grace state is cleared on
    successful re-validation). Stores the receipt for support; we never
    forward it to Apple from the Hub (the Companion does any server-side
    StoreKit 2 validation on the iOS side first).
    """
    new_state = {
        "status": STATUS_ACTIVE,
        "last_validated_at": _iso_now(),
        "expires_at": expires_at_iso,
        "grace_period_end": None,
        "source": SOURCE_COMPANION,
        "receipt": receipt_b64,
    }
    _write(new_state)


def activate_first_month_free(purchase_date_iso: str) -> None:
    """Called at install.sh time after license verification succeeds.

    Hub gets 30 days of Pro free with Hub purchase. Customer can then
    subscribe via iOS Companion to extend. Writes the canonical first-
    month-free state: ``status=active`` for 30 days, with a 14-day grace
    period beyond that before ongoing intelligence pauses.
    """
    purchase_dt = _parse_iso(purchase_date_iso)
    if purchase_dt is None:
        # Defensive: caller passed garbage. Fall back to now so install
        # never silently writes a broken state.
        purchase_dt = _now()
    expires = purchase_dt + timedelta(days=30)
    grace_end = expires + timedelta(days=GRACE_DAYS)
    new_state = {
        "status": STATUS_ACTIVE,
        "last_validated_at": _iso_now(),
        "expires_at": expires.isoformat().replace("+00:00", "Z"),
        "grace_period_end": grace_end.isoformat().replace("+00:00", "Z"),
        "source": SOURCE_FIRST_MONTH_FREE,
    }
    _write(new_state)


def expire_check() -> None:
    """Walk state forward as time passes. Idempotent; safe to call often.

    Two transitions:

    - ``active`` past ``expires_at`` -> ``grace`` (grace window starts).
    - ``grace`` past ``grace_period_end`` -> ``inactive``.

    Once ``inactive``, the customer must re-validate via Companion push
    (``refresh_from_companion``) to come back. This function never writes
    a backwards transition; subscription comebacks always go through the
    Companion path.
    """
    state = _load()
    current_status = state.get("status", STATUS_INACTIVE)

    if current_status == STATUS_ACTIVE:
        expires = _parse_iso(state.get("expires_at"))
        if expires is not None and _now() > expires:
            state["status"] = STATUS_GRACE
            _write(state)
            current_status = STATUS_GRACE

    if current_status == STATUS_GRACE:
        grace_end = _parse_iso(state.get("grace_period_end"))
        if grace_end is not None and _now() > grace_end:
            state["status"] = STATUS_INACTIVE
            _write(state)
