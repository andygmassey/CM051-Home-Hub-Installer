"""Pro entitlement gate for the Front Page feed (fail-closed).

The Editor's Front Page is Pro proactivity (PRO_SLATE_MONETISATION_SPEC.md
section 0.1, locked 2026-07-12: "Pro = Ostler's ongoing labour ... the Editor
front page. This is where the recurring value chiefly lives"). This module is
the CM059-side gate for the ``front_page_feed`` entitlement.

Division of labour (load-bearing - see docs/DESIGN_NOTE_pro_entitlement_gate.md):

  * The DAEMON is the only licence verifier. Per PRO_TIER_GATING_SPEC.md the
    signed licence (``~/.ostler/licence.json``, Ed25519, embedded public key)
    is verified in ``zeroclaw-runtime``; CM059 must NOT grow a second crypto
    verifier - two implementations of canonical-JSON + signature checks WILL
    drift, and the public key is compiled into the daemon.
  * After verifying, the daemon writes a small plain-JSON **entitlement
    sidecar** for the local Python producers (this emitter) to read::

        ~/.ostler/state/entitlements.json
        {
          "generated_utc":  "2026-07-12T06:00:00+00:00",
          "tier":           "pro",
          "entitlements":   ["front_page_feed"],
          "pro_expires_at": "2026-08-01T00:00:00+00:00"
        }

    The sidecar is a CACHE of a decision the daemon already made fail-closed;
    it carries no secrets and grants nothing the signed licence did not.

This module evaluates that sidecar **fail-closed** (the same posture as the
daemon gate - the exact inverse of ``SignatureMode::Disabled`` fail-open).
Every ambiguous state denies:

  * sidecar missing / unreadable / malformed / not an object   -> deny
  * ``tier`` != "pro"                                          -> deny
  * ``entitlements`` not a list of strings                     -> deny
  * the requested feature not in ``entitlements``              -> deny
  * ``pro_expires_at`` missing / unparseable / in the past     -> deny
  * ``generated_utc`` missing / unparseable / older than
    ``MAX_SIDECAR_AGE_DAYS`` (a dead daemon must not keep
    granting off a stale cache)                                -> deny
  * any exception during evaluation                            -> deny

Enforcement rollout: the gate is wired into the emitter behind
``OSTLER_EDITOR_ENTITLEMENT_GATE=1`` because the daemon-side sidecar writer
does not exist yet (recurring billing is a flagged follow-on in the gating
spec). With the switch unset the feed behaves as today; the moment it is set,
the gate above applies with no code change. Flipping the default to ON ships
together with the daemon writer - the flip plan is in the design note.

Stdlib only. Pure decision function (``is_entitled``) + thin I/O wrapper.
"""

from __future__ import annotations

import json
import os
from datetime import datetime, timezone

# The entitlement key for the Editor's Front Page (snake_case per-feature key,
# same convention as the Pro slate's subscription_hunter / followup_detector).
FEATURE_FRONT_PAGE = "front_page_feed"

# Where the daemon writes the sidecar (shared state dir, same zone as
# hydration_progress.json). Env override for tests / non-standard installs.
SIDECAR_NAME = "entitlements.json"
DEFAULT_STATE_DIR = "~/.ostler/state"

# A sidecar older than this is treated as absent: if the daemon stops
# refreshing it (crashed, uninstalled, licence pulled) the grant lapses
# rather than persisting forever off a stale cache. The daemon refreshes on
# startup and licence-file change; 7 days is a generous heartbeat.
MAX_SIDECAR_AGE_DAYS = 7.0


def sidecar_path() -> str:
    override = os.environ.get("OSTLER_EDITOR_ENTITLEMENTS_FILE")
    if override:
        return os.path.expanduser(override)
    state_dir = os.path.expanduser(
        os.environ.get("OSTLER_STATE_DIR", DEFAULT_STATE_DIR))
    return os.path.join(state_dir, SIDECAR_NAME)


def load_sidecar(path: str | None = None) -> dict | None:
    """Tolerant sidecar read. Returns the parsed object or ``None`` for any
    failure (missing, unreadable, malformed, not a JSON object). ``None`` is a
    DENY downstream - never raises."""
    try:
        with open(path or sidecar_path(), encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception:  # noqa: BLE001 - any read failure is a deny, not an error
        return None
    return data if isinstance(data, dict) else None


def _parse_dt(value) -> datetime | None:
    if isinstance(value, datetime):
        return value if value.tzinfo else value.replace(tzinfo=timezone.utc)
    try:
        dt = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def is_entitled(feature: str, sidecar: dict | None,
                now: datetime | None = None) -> bool:
    """Pure fail-closed entitlement decision. ``True`` ONLY when every check
    passes; every ambiguous, missing, malformed, stale or expired state is a
    deny. Never raises."""
    try:
        now = now or datetime.now(timezone.utc)
        if not isinstance(sidecar, dict):
            return False
        if sidecar.get("tier") != "pro":
            return False
        ents = sidecar.get("entitlements")
        if not isinstance(ents, list) or not all(isinstance(e, str) for e in ents):
            return False
        if feature not in ents:
            return False
        expires = _parse_dt(sidecar.get("pro_expires_at"))
        if expires is None or expires <= now:
            return False
        generated = _parse_dt(sidecar.get("generated_utc"))
        if generated is None:
            return False
        age_days = (now - generated).total_seconds() / 86400.0
        if age_days > MAX_SIDECAR_AGE_DAYS:
            return False  # stale cache: a dead daemon must not keep granting
        return True
    except Exception:  # noqa: BLE001 - fail closed, whatever went wrong
        return False


def gate_enabled() -> bool:
    """Is entitlement enforcement switched on for this install? Off by default
    until the daemon-side sidecar writer ships (see module docstring); the
    gate itself is fully fail-closed whenever it is evaluated."""
    return bool(os.environ.get("OSTLER_EDITOR_ENTITLEMENT_GATE"))


def front_page_entitled(now: datetime | None = None) -> bool | None:
    """The emitter's one-call check. Returns ``None`` when enforcement is off
    (gate not evaluated - legacy behaviour), else the fail-closed boolean."""
    if not gate_enabled():
        return None
    return is_entitled(FEATURE_FRONT_PAGE, load_sidecar(), now)
