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
3. ``expire_check()`` -- run periodically by the ical-server's
   subscription ticker (``_start_subscription_expiry_ticker`` in
   ical-server.py, hourly, under the KeepAlive ``com.ostler.ical-server``
   LaunchAgent). Walks the state forward through active -> grace ->
   inactive as time passes.

   🔴 THE TICKER IS NOT WHAT MAKES THE TRIAL END, and must never be the
   only thing that does. Until 2026-09-16 ``expire_check()`` had ZERO
   production callers, so the state file said ``status=active`` forever
   and every Hub buyer kept Ostler Pro for free for life. A scheduler is
   a thing that can fail to be loaded, so the READER below
   (``is_active_or_grace``) no longer trusts the stored status: it walks
   the state forward itself, in-process, on every call. The ticker only
   persists that walk so the Doctor banner and support can see it.

Paid-once rule (Andy, 2026-07-31, re-made 2026-09-16): "keep it as long
as they've paid (fully) for Pro at least once. ie. not the 30 days free
plus a failed card try." Implemented here as the ``has_ever_paid`` sticky
bit -- see ``_has_ever_paid``. It mirrors the daemon's
``SubscriptionConfig::has_ever_paid`` (zeroclaw-config schema.rs) and the
gate at zeroclaw-runtime subscription/gate.rs, which had the rule while
this file, the one that actually ships to customers, did not.

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
import sys
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

# Sticky bit recording that the customer has fully paid for Ostler Pro at
# least once. Once true it never goes back to false. See _has_ever_paid.
KEY_HAS_EVER_PAID = "has_ever_paid"


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
    """Persist state to disk atomically. Creates parent dir if needed.

    Atomic because there are now TWO writers on a live Hub: the hourly
    expiry ticker, and the receipt endpoint when the phone pushes. A
    plain write truncates first, so a reader landing in that window gets
    a half-file. ``_load`` degrades a corrupt read to default-inactive,
    which for a PAYING customer means no receipt, no source, no
    has_ever_paid -- and the gate would pause someone who has paid. Rare
    is not the same as acceptable when the failure mode is a support
    call from a customer we took money from.

    os.replace is atomic within a filesystem, and the temp file is made
    in the SAME directory so it never crosses one.
    """
    path = _state_file()
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(state, indent=2))
    os.replace(str(tmp), str(path))


def _iso_now() -> str:
    """Return current UTC time as extended ISO-8601 Zulu."""
    return _now().isoformat().replace("+00:00", "Z")


def _has_ever_paid(state: dict) -> bool:
    """Has this customer fully paid for Ostler Pro at least once?

    This is the trust anchor for the 14-day post-lapse grace window and
    for the 30-day offline fail-open. Andy's ruling: grace is a cushion
    for people who actually paid, not a second free month for a trialist
    whose 30 days ran out, and not a reward for a failed card.

    Evidence (any one is enough):

    - the sticky bit is already set;
    - the state carries a ``receipt``, which only ``refresh_from_companion``
      writes, and the iOS app only pushes one after a transaction succeeds
      or is restored. A card that FAILS produces no transaction, so it
      produces no receipt, so it never reaches here -- which is exactly
      the case Andy called out;
    - ``source == "companion"``, same signal on a state written before the
      receipt field existed.

    The last two are the BACKFILL, and they are why a customer who is
    already paying does not lose grace by upgrading to this build. Their
    state file predates the sticky bit, so without the backfill they would
    read as never-paid and lose the cushion they are owed.

    🔴 ``status == "active"`` IS NOT EVIDENCE OF PAYMENT HERE, and this is
    the one place this file must NOT copy the daemon. The Rust backfill
    (``SubscriptionConfig::backfill_has_ever_paid``) does accept Active,
    because on that side a fresh install defaults to ``Grace``. On THIS
    side install.sh calls ``activate_first_month_free``, which writes
    ``status=active`` for the free month. Accepting that as proof would set
    the bit for every single trialist on day zero, the denominator would
    be "everybody", and the rule would read as implemented while changing
    nothing. If you are about to add it, this paragraph is why you should
    not.
    """
    if state.get(KEY_HAS_EVER_PAID) is True:
        return True
    receipt = state.get("receipt")
    if isinstance(receipt, str) and receipt.strip():
        return True
    if state.get("source") == SOURCE_COMPANION:
        return True
    return False


def _walk(state: dict, now: datetime) -> tuple:
    """Pure state-machine step. Returns ``(effective_status, new_state)``.

    Computes what the subscription status IS at ``now``, rather than what
    the file happens to say it was when it was last written. Shared by
    ``expire_check`` (which persists the result) and ``is_active_or_grace``
    (which decides from it), so a reader can never be ahead of a writer
    that did not run.

    Transitions:

    - ``active`` and still inside ``expires_at`` -> ``active``.
    - ``active`` past ``expires_at`` -> the lapse branch below.
    - lapse, customer HAS ever paid -> ``grace`` until ``grace_period_end``,
      then ``inactive``.
    - lapse, customer has NEVER paid -> ``inactive`` immediately. No grace.
      This is Andy's rule and it is the whole revenue fix: the free month
      ends on the day it ends.

    Never raises. Never writes.
    """
    paid = _has_ever_paid(state)
    new_state = dict(state)
    new_state[KEY_HAS_EVER_PAID] = paid
    status = state.get("status", STATUS_INACTIVE)

    if status == STATUS_ACTIVE:
        expires = _parse_iso(state.get("expires_at"))
        if expires is None:
            # Unparseable or absent expiry. For a customer who has paid we
            # fail OPEN (Apple restraint: never lock a payer out on a field
            # we cannot read). For one who never paid we fail CLOSED -- the
            # free month has no defensible end date, so it is over. That
            # asymmetry is deliberate: deleting expires_at from the JSON is
            # the cheapest way to try to farm a permanent free trial.
            if paid:
                new_state["status"] = STATUS_ACTIVE
                return STATUS_ACTIVE, new_state
            new_state["status"] = STATUS_INACTIVE
            return STATUS_INACTIVE, new_state
        if now <= expires:
            new_state["status"] = STATUS_ACTIVE
            return STATUS_ACTIVE, new_state
        status = STATUS_GRACE

    if status == STATUS_GRACE:
        if not paid:
            new_state["status"] = STATUS_INACTIVE
            return STATUS_INACTIVE, new_state
        grace_end = _parse_iso(state.get("grace_period_end"))
        if grace_end is None:
            # refresh_from_companion writes grace_period_end=None on every
            # successful validation (it clears a previous grace). So a
            # paying customer who lapses has no grace date on file at the
            # moment they need one. Derive it from the expiry we just
            # passed rather than granting an unbounded window -- without
            # this, a cancelled subscriber whose phone never pushes again
            # keeps Pro forever, which is the same defect as the trial
            # never ending, wearing different clothes.
            expires = _parse_iso(state.get("expires_at"))
            if expires is not None:
                grace_end = expires + timedelta(days=GRACE_DAYS)
                new_state["grace_period_end"] = (
                    grace_end.isoformat().replace("+00:00", "Z")
                )
        if grace_end is not None and now > grace_end:
            new_state["status"] = STATUS_INACTIVE
            return STATUS_INACTIVE, new_state
        new_state["status"] = STATUS_GRACE
        return STATUS_GRACE, new_state

    new_state["status"] = STATUS_INACTIVE
    return STATUS_INACTIVE, new_state


def _persist_walk(old_state: dict, new_state: dict) -> None:
    """Write the walked state back if it changed. Best effort, never raises.

    The READ decision must never depend on this succeeding: a Hub whose
    state dir is read-only still expires trials correctly, it just cannot
    show the walked status in the Doctor banner.
    """
    if new_state == old_state:
        return
    try:
        _write(new_state)
    except OSError:
        pass


def is_active_or_grace() -> bool:
    """Return True if ongoing intelligence should keep running.

    Resolution order (each branch short-circuits):

    1. The stored state is WALKED FORWARD to now first (``_walk``). The
       stored ``status`` field is a cache, not an authority -- this
       function used to read it directly, and because nothing ever walked
       it, ``status=active`` written at install time never changed and
       every Hub buyer had Ostler Pro free for life.
    2. Effective status ``active`` -> True.
    3. Effective status ``grace`` -> True. Only a customer who has paid
       at least once can BE in grace (see ``_walk``), so this branch can
       no longer hand a never-paid trialist a free fortnight.
    4. **Fail-open offline grace**, gated on ``has_ever_paid``:
       ``last_validated_at`` within the last 30 days. A paying customer
       whose network is down, who is on holiday, or whose StoreKit server
       is having a bad day keeps running. A trialist who never paid does
       NOT -- for them "we could not validate" is not a reason to doubt
       the answer, because there is nothing to validate.
    5. Otherwise: inactive. Return False.

    Apple-restraint posture is unchanged for anyone who has paid: they
    cannot be locked out by infrastructure failure we cannot observe.
    What changed is that the posture no longer extends to someone who has
    never paid, because for them it was not restraint, it was the product
    being free.
    """
    state = _load()
    now = _now()
    effective, walked = _walk(state, now)
    _persist_walk(state, walked)

    if effective in (STATUS_ACTIVE, STATUS_GRACE):
        return True

    # Fail-open, for payers only. Note the denominator this branch must
    # not silently acquire: before the has_ever_paid guard, EVERY install
    # satisfied it for its first 30 days, because install.sh stamps
    # last_validated_at at activation time. It read as a safety net and
    # behaved as a second free month.
    if _has_ever_paid(state):
        last_validated = _parse_iso(state.get("last_validated_at"))
        expires = _parse_iso(state.get("expires_at"))
        if last_validated is not None and (now - last_validated) < timedelta(
            days=OFFLINE_GRACE_DAYS
        ):
            # 🔴 SILENCE IS NOT THE SAME AS AN ANSWER, and this branch used
            # to treat them identically. The fail-open exists for the
            # customer we cannot REACH. If last_validated_at is LATER than
            # the expiry it reported, we did reach them, after the expiry,
            # and Apple's answer was "expired" -- overriding that is not
            # restraint, it is ignoring the only fact we have. And because
            # the iOS app re-pushes on every foreground, last_validated_at
            # keeps moving forward: a customer who cancelled would have
            # kept Ostler Pro for as long as they kept opening the app.
            # Same defect family as the trial that never ends.
            heard_after_expiry = expires is not None and last_validated > expires
            if not heard_after_expiry:
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

    THIS IS THE ONLY PLACE ``has_ever_paid`` IS SET TRUE. A receipt
    reaching this function is the Hub's proof that the customer completed
    a real purchase or restore; the iOS app does not push one otherwise.
    That is what makes the bit mean "paid", and what keeps the free month
    (which arrives through ``activate_first_month_free``, with no receipt)
    from claiming it.
    """
    new_state = {
        "status": STATUS_ACTIVE,
        "last_validated_at": _iso_now(),
        "expires_at": expires_at_iso,
        "grace_period_end": None,
        "source": SOURCE_COMPANION,
        "receipt": receipt_b64,
        KEY_HAS_EVER_PAID: True,
    }
    _write(new_state)


def activate_first_month_free(purchase_date_iso: str) -> None:
    """Called at install.sh time after license verification succeeds.

    Hub gets 30 days of Pro free with Hub purchase. Customer can then
    subscribe via the iOS app to extend. Writes the canonical first-
    month-free state: ``status=active`` for 30 days.

    ``has_ever_paid`` is CARRIED OVER from any existing state, never
    granted. Two consequences, both intended:

    - A customer who is already paying and re-runs the installer keeps
      the bit, so re-running install.sh cannot cost them their grace.
    - A trialist who deletes the state file and reinstalls to farm a
      second free month gets ``has_ever_paid=False`` again, so their
      month still ends on day 30 with no grace after it.

    The 14-day ``grace_period_end`` is still written so support and the
    Doctor banner can see the shape of the window, but it is INERT for a
    never-paid customer: ``_walk`` refuses grace to anyone without the
    bit. Do not read the presence of that field as a granted fortnight.
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
        KEY_HAS_EVER_PAID: _has_ever_paid(_load()),
    }
    _write(new_state)


def expire_check() -> None:
    """Walk state forward as time passes. Idempotent; safe to call often.

    Transitions (all of them live in ``_walk``; this function is the
    persistence half, so the two can never drift apart):

    - ``active`` past ``expires_at``, customer HAS paid -> ``grace``.
    - ``active`` past ``expires_at``, customer has NEVER paid ->
      ``inactive`` immediately.
    - ``grace`` past ``grace_period_end`` -> ``inactive``.

    Once ``inactive``, the customer must re-validate via an iOS receipt
    push (``refresh_from_companion``) to come back. This function never
    writes a backwards transition; subscription comebacks always go
    through the receipt path.

    Called hourly by ``_start_subscription_expiry_ticker`` in
    ical-server.py. A missed tick costs nothing: ``is_active_or_grace``
    walks the same state machine in-process, so the customer-visible
    answer is right whether or not this ever ran.
    """
    state = _load()
    _, walked = _walk(state, _now())
    if walked != state:
        _write(walked)


# Exit code the --check CLI uses for "subscription paused". Deliberately
# NOT 1: a shell caller must be able to tell "the customer is not paying"
# apart from "this script crashed", because those two need opposite
# handling. A crash must never silently pause a paying customer's
# ingestion, and a pause must never look like a bug to be retried.
EXIT_PAUSED = 3


def _main(argv: list) -> int:
    """``python3 subscription_gate.py --check``.

    The seam for the shell tick wrappers (iMessage, WhatsApp, email,
    spoken). Those run in their own venvs, in their own staged service
    directories, and cannot import this module -- but they can run it,
    because install.sh stages the whole of assistant_api/ (including this
    file) to ${OSTLER_DIR}/services/ical-server/, a SIBLING of every
    services/<source> directory the wrappers already know the path to.

    Exit 0 = keep ingesting. Exit 3 = paused, stop before touching new
    data. Anything else = this script itself failed, and the caller must
    treat that as "carry on", never as "paused".
    """
    if "--check" not in argv:
        print("usage: subscription_gate.py --check", file=sys.stderr)
        return 2
    if is_active_or_grace():
        return 0
    snapshot = state_dict()
    print(
        "Ostler Pro is not active (status={status}, source={source}). "
        "Ongoing intelligence is paused; data already ingested stays "
        "fully accessible. Subscribe in the Ostler app to resume.".format(
            status=snapshot.get("status", STATUS_INACTIVE),
            source=snapshot.get("source", SOURCE_DEFAULT),
        )
    )
    return EXIT_PAUSED


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
