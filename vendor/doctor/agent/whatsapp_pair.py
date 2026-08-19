"""Read the WhatsApp Web pair code the daemon publishes, for Doctor.

WHY THIS MODULE EXISTS

Andy ruled WhatsApp non-negotiable for v1. Two defects had to fall before a
customer could link their account, and both were fixed elsewhere:

  * the shipped daemon carried no ``whatsapp-web`` feature at all
    (ostler-assistant #304);
  * install.sh wrote ``enabled = true`` with no backend selector, which is
    inert (CM051 #583).

This is the third: even once the channel runs and requests a pair code, the
code had exactly one exit from the process, an ``eprintln!`` to daemon stderr.
A code on a headless Hub's stderr is not a surface a customer can use.

ostler-assistant now publishes it as a state file. This module reads it.

THE CONTRACT, agreed with the writer rather than reverse-engineered:

    ${OSTLER_HOME}/state/whatsapp_pair.json      file 0600, dir 0700
    {
      "code":          "8-char string",
      "requested_at":  unix seconds,
      "expires_at":    unix seconds,
      "validity_secs": integer
    }

Written temp-then-rename, so a half-written file cannot be read and a truncated
code cannot be shown to a customer.

``expires_at`` is MEASURED by the writer, not assumed here. It binds the
``timeout`` on wa-rs's ``Event::PairingCode``, which comes from
``PairCodeUtils::code_validity()``. Doctor must not apply its own TTL policy on
top: a countdown that disagrees with WhatsApp's is worse than no countdown,
because the customer trusts the one on screen.

WHY THE ERROR TAXONOMY IS EXPLICIT AND NOT A BARE ``Optional``

The states a customer can be in look identical from a null and are not the same
problem at all:

    no_channel     they never consented to WhatsApp
    not_requested  channel is on, the daemon has not asked for a code yet
    expired        there WAS a code, it aged out, ask for another
    unreadable     the file exists and we cannot parse or open it

Collapsing those into "no pair code available" tells a stuck customer nothing,
and tells support less. ``pair_status.py`` established this shape for the iOS
pairing panel; this mirrors it rather than inventing a second vocabulary.
"""

from __future__ import annotations

import json
import logging
import os
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

log = logging.getLogger(__name__)


# The daemon's engine zone. Same root the consent gate and the channel poll
# cursors use. NOT under the customer's data/ tree and NOT under Caches.
_STATE_FILENAME = "whatsapp_pair.json"

# A pair code that is about to die is worse than useless: the customer types it
# and WhatsApp rejects it. Treat a code with less than this left as expired so
# the panel says "ask for a new one" instead of showing a doomed one.
_MIN_USEFUL_SECONDS = 5


@dataclass
class WhatsAppPairStatus:
    """Structured result a Doctor route can JSON-serialise directly."""

    available: bool
    code: Optional[str]
    expires_at: Optional[int]
    seconds_remaining: Optional[int]
    error: Optional[str]
    error_kind: Optional[str]

    def to_dict(self) -> dict:
        return {
            "available": self.available,
            "code": self.code,
            "expires_at": self.expires_at,
            "seconds_remaining": self.seconds_remaining,
            "error": self.error,
            "error_kind": self.error_kind,
        }


def state_path() -> Path:
    """Resolve the pair-code state file.

    Honours ``OSTLER_HOME`` then ``OSTLER_DIR`` (the installer sets
    ``OSTLER_DIR=~/.ostler``), falling back to ``~/.ostler``. Mirrors how the
    rest of Doctor resolves the engine zone so the two cannot drift onto
    different roots.
    """
    base = os.environ.get("OSTLER_HOME") or os.environ.get("OSTLER_DIR")
    root = Path(base) if base else Path.home() / ".ostler"
    return root / "state" / _STATE_FILENAME


def _unavailable(kind: str, message: str) -> WhatsAppPairStatus:
    return WhatsAppPairStatus(
        available=False,
        code=None,
        expires_at=None,
        seconds_remaining=None,
        error=message,
        error_kind=kind,
    )


def fetch_pair_status(
    path: Optional[Path] = None,
    now: Optional[int] = None,
) -> WhatsAppPairStatus:
    """Read the current pair code, if there is a usable one.

    Never raises. A Doctor panel that 500s tells the customer less than a panel
    that says "not requested yet", and this runs on the dashboard's polling
    path where an exception would blank the whole card.

    ``now`` is injectable so expiry tests do not have to sleep, and so a test
    cannot pass merely because it ran fast.
    """
    target = path if path is not None else state_path()
    current = int(time.time()) if now is None else now

    try:
        if not target.is_file():
            # Not an error. The overwhelmingly common case is a customer who
            # never turned WhatsApp on, and the second most common is one whose
            # daemon has not reached the pairing step yet. The caller decides
            # which copy to show using the channel's configured state; this
            # module refuses to guess at it from a missing file.
            return _unavailable(
                "not_requested",
                "No pair code has been requested yet.",
            )
        raw = target.read_text(encoding="utf-8")
    except OSError as exc:
        log.warning("whatsapp pair state unreadable at %s: %s", target, exc)
        return _unavailable("unreadable", "Could not read the pairing file.")

    try:
        payload = json.loads(raw)
    except (ValueError, TypeError) as exc:
        # Deliberately does NOT log `raw`. A malformed file may still contain a
        # live pair code, and this logger's output lands in doctor.err, which
        # the support-diagnostics bundle tails.
        log.warning("whatsapp pair state is not valid JSON at %s: %s", target, exc)
        return _unavailable("unreadable", "The pairing file could not be read.")

    if not isinstance(payload, dict):
        return _unavailable("unreadable", "The pairing file could not be read.")

    code = payload.get("code")
    expires_at = payload.get("expires_at")

    if not isinstance(code, str) or not code.strip():
        return _unavailable("unreadable", "The pairing file has no code in it.")
    # `bool` is an `int` subclass in Python and would sail through a naive
    # isinstance check, so exclude it explicitly rather than trust the writer.
    if isinstance(expires_at, bool) or not isinstance(expires_at, int):
        return _unavailable("unreadable", "The pairing file has no expiry in it.")

    remaining = expires_at - current
    if remaining < _MIN_USEFUL_SECONDS:
        # Report the expiry honestly rather than hand back a code that WhatsApp
        # will reject. The customer needs "ask for another", not "try harder".
        return _unavailable(
            "expired",
            "That pairing code has expired. Ask for a new one.",
        )

    return WhatsAppPairStatus(
        available=True,
        code=code.strip(),
        expires_at=expires_at,
        seconds_remaining=remaining,
        error=None,
        error_kind=None,
    )
