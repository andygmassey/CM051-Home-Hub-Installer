"""The card ledger: a per-card first-emission record (E1).

Why this exists (the latent decay bug it fixes):

    ``frontpage._make_card`` stamped ``created_utc`` to *now* on every tick. The
    feed is regenerated hourly, so a card that has sat on the page for a week was
    re-minted with ``created_utc = now`` each time. Any age-based priority decay
    therefore measured age from *this* tick, i.e. always ~0 - so decay never bit
    and an old card camped at the top forever. TTL had the same blind spot.

The fix is a small, durable ledger keyed on the card's *stable* id
(``frontpage.card_id`` - a hash of kind + interest/slug, deliberately stable
across ticks). The ledger records when each id was **first** emitted; the feed
builder copies that first-emission timestamp onto the card as ``created_utc``
instead of re-stamping it. Age (and therefore decay and TTL) is then measured
from the real first sighting, exactly as the spec's ranking formula requires
(priority ``= base x proximity x 0.5^(age_days / half_life)`` with ``age_days``
from first emission, CM059 spec section 1.3-1.4).

Shape on disk (``~/.ostler/editor/card_ledger.json``)::

    {
      "card_3fa2b19c04d1": { "first_emitted_utc": "2026-07-10T06:00:00+00:00",
                             "last_emitted_utc":  "2026-07-12T06:00:00+00:00" },
      "_pruned_utc": "2026-07-12T06:00:00+00:00"
    }

Robustness rules (spec section 1.4): an entry is created on first emission;
``created_utc`` is *copied from* the ledger, never re-stamped; entries are pruned
``PRUNE_AFTER_DAYS`` after their ``last_emitted_utc``; a corrupt or missing
ledger degrades to today's behaviour (age 0 - every card looks fresh) and never
blocks a feed.

Pure + I/O split, mirroring the rest of the compiler: ``reconcile`` is a pure
function of (ledger, emitted ids, now); ``load_ledger`` / ``save_ledger`` do the
atomic file I/O in the emitter.
"""

from __future__ import annotations

import json
import os
from datetime import datetime, timedelta, timezone

DEFAULT_LEDGER = os.path.expanduser("~/.ostler/editor/card_ledger.json")
LEDGER_NAME = "card_ledger.json"

# Prune an id this many days after it was last emitted, so a card that stops
# appearing (interest dropped, signal cleared) does not linger in the ledger for
# ever. 90 days is generous: a card re-appearing inside the window keeps its true
# age; one re-appearing after it simply starts fresh (age 0), which is honest.
PRUNE_AFTER_DAYS = 90

_PRUNED_KEY = "_pruned_utc"


def _parse_dt(value):
    if value is None or isinstance(value, datetime):
        return value
    try:
        dt = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def _iso(dt: datetime) -> str:
    return dt.isoformat()


def load_ledger(path: str | None = None) -> dict:
    """Read the ledger. A missing or corrupt file degrades to an empty ledger
    (every card then looks fresh - age 0), never raises."""
    path = path or os.environ.get("OSTLER_EDITOR_CARD_LEDGER", DEFAULT_LEDGER)
    try:
        with open(os.path.expanduser(path), encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception:
        return {}
    if not isinstance(data, dict):
        return {}
    # keep only well-formed per-card entries (+ the pruned marker); drop junk
    out: dict = {}
    for key, val in data.items():
        if key == _PRUNED_KEY:
            out[key] = val
            continue
        if isinstance(val, dict) and val.get("first_emitted_utc"):
            out[key] = {
                "first_emitted_utc": val.get("first_emitted_utc"),
                "last_emitted_utc": val.get("last_emitted_utc")
                or val.get("first_emitted_utc"),
            }
    return out


def first_emitted(ledger: dict | None, card_id: str) -> str | None:
    """The stable first-emission timestamp for ``card_id`` (ISO string), or
    ``None`` when the id is unknown (i.e. this is its first emission)."""
    if not ledger:
        return None
    entry = ledger.get(card_id)
    if isinstance(entry, dict):
        return entry.get("first_emitted_utc")
    return None


def reconcile(ledger: dict | None, emitted_ids, now: datetime) -> dict:
    """Fold this tick's emitted card ids into the ledger (pure).

    * A brand-new id gets ``first_emitted_utc = last_emitted_utc = now``.
    * A known id keeps its ``first_emitted_utc`` and refreshes ``last_emitted_utc``
      to ``now`` (this is what keeps age measured from the *first* sighting).
    * Entries whose ``last_emitted_utc`` is older than ``PRUNE_AFTER_DAYS`` are
      dropped, unless they were emitted this tick.

    Returns a fresh dict; the input ledger is not mutated.
    """
    now_iso = _iso(now)
    emitted = set(emitted_ids or [])
    out: dict = {}
    cutoff = now - timedelta(days=PRUNE_AFTER_DAYS)

    # carry forward existing entries, pruning stale ones
    for card_id, entry in (ledger or {}).items():
        if card_id == _PRUNED_KEY:
            continue
        if not isinstance(entry, dict) or not entry.get("first_emitted_utc"):
            continue
        if card_id in emitted:
            continue  # refreshed below
        last = _parse_dt(entry.get("last_emitted_utc") or entry.get("first_emitted_utc"))
        if last is not None and last < cutoff:
            continue  # pruned
        out[card_id] = {
            "first_emitted_utc": entry["first_emitted_utc"],
            "last_emitted_utc": entry.get("last_emitted_utc") or entry["first_emitted_utc"],
        }

    # record / refresh everything emitted this tick
    for card_id in emitted:
        prior = first_emitted(ledger, card_id)
        out[card_id] = {
            "first_emitted_utc": prior or now_iso,
            "last_emitted_utc": now_iso,
        }

    out[_PRUNED_KEY] = now_iso
    return out


def save_ledger(ledger: dict, path: str | None = None) -> str:
    """Atomically persist the ledger."""
    path = os.path.expanduser(
        path or os.environ.get("OSTLER_EDITOR_CARD_LEDGER", DEFAULT_LEDGER))
    parent = os.path.dirname(path) or "."
    os.makedirs(parent, exist_ok=True)
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(ledger, fh, indent=2, ensure_ascii=False)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)
    return path
