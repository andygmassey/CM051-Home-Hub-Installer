"""Live signal cards (E2): reply-debt, gone-quiet, key dates, commitments.

These are the *fast-moving* half of the Editor's two signal families (CM059 spec
section 1.1). Standing interests say what the user is into; live signals say what
needs the user *now*. They are built deterministically - no LLM, no always-on
call - from the loopback relationship endpoints, carrying **names and counts
only, never message bodies or free text** (privacy L2, spec section 4), and
ranked by the unified table in spec section 1.3:

    priority = base_band(class) x proximity(class) x 0.5^(age_days / half_life)

This module supplies ``base_band x proximity``; the age-decay factor is applied
centrally in ``frontpage._apply_ledger_age`` off the card ledger's stable
first-emission timestamp (spec section 1.4). TTL (``expires_utc``) is separate
from decay: TTL kills, decay merely sinks.

Two layers, split for offline testability:

  * ``fetch_signals(base_url)`` - the ONLY network layer. Loopback-only
    (127.0.0.1 / localhost), a short per-endpoint timeout, and each source
    independently optional: a source that is down / times out / returns junk is
    simply omitted, never an error.
  * ``build_signal_cards(raw, now, ledger)`` - PURE. Normalises whatever the
    endpoints returned into canonical shapes, then builds cards. Same inputs ->
    same cards.

The gone-quiet re-emission window (active -> cooldown -> re-eligible, spec
section 1.3) is measured from the ledger's first-emission timestamp so it stays
stable across ticks.

Source privacy is FAIL-CLOSED (audit 2026-07-13, Finding 2): every source item
must declare a privacy level (``privacy`` / ``privacy_level`` / ``privacyLevel``
/ ``level``, either per item or once on the enclosing payload). An item whose
resolved level is L3, unrecognised, or ABSENT is dropped at normalisation and
never becomes a card - an untagged source cannot prove it is safe. The level is
also propagated onto the card (never less restrictive than L2), so even a
builder invoked directly with an L3 item yields a card the central
``privacy_gate`` drops.
"""

from __future__ import annotations

import json
import socket
import urllib.request
from datetime import datetime, timedelta, timezone
from urllib.parse import urlparse

from compiler import card_ledger
from compiler import frontpage as fp

# ---------------------------------------------------------------------------
# User-facing copy. Centralised here as the locale seam (mirrors CM044's
# locale.py intent): E2 keeps English strings but in one table so a locale
# layer can be dropped in without touching the builders. British English.
# ---------------------------------------------------------------------------

_STRINGS = {
    "reply_debt_title_one": "Someone is waiting on you",
    "reply_debt_title_many": "{count} people are waiting on you",
    "reply_debt_body": "{names} {have} messages awaiting your reply.",
    "reply_debt_action": "See who",
    "gone_quiet_title": "You and {name} have gone quiet",
    "gone_quiet_body": ("No contact for {months} months. A short message keeps "
                        "the thread alive."),
    "gone_quiet_body_one": ("No contact for a month. A short message keeps the "
                            "thread alive."),
    "gone_quiet_action": "Draft a hello",
    "birthday_title": "{name}'s birthday is {when}",
    "birthday_body": "{when_cap}.",
    "commitment_title": "Something you committed to is due",
    "commitment_title_with": "Something you owe {who} is due",
    # No free-text commitment body template: commitment text is arbitrary
    # source content (may be L3, e.g. medical), so the card renders names +
    # dates only (audit 2026-07-13, Finding 2).
    "commitment_body_plain": "Due {when}.",
    "commitment_action": "Review commitments",
}

_NUM_WORDS = {0: "no", 1: "one", 2: "two", 3: "three", 4: "four", 5: "five",
              6: "six", 7: "seven", 8: "eight", 9: "nine"}


def _num_word(n: int) -> str:
    return _NUM_WORDS.get(int(n), str(int(n)))


def _cap(text: str) -> str:
    return text[:1].upper() + text[1:] if text else text


# ---------------------------------------------------------------------------
# Proximity factors (spec section 1.3). Pure, deterministic.
# ---------------------------------------------------------------------------

def reply_debt_proximity(count: int) -> float:
    """x(1 + 0.05 * count), capped at 1.5."""
    return min(1.5, 1.0 + 0.05 * max(0, int(count)))


def date_proximity(days_until: float) -> float:
    """x1.0 at <=1 day, linear down to x0.5 at >=7 days (spec key-date rule).
    Overdue (negative) is treated as maximally proximate (x1.0)."""
    if days_until <= 1:
        return 1.0
    if days_until >= 7:
        return 0.5
    return 1.0 - 0.5 * (days_until - 1) / 6.0


def gone_quiet_proximity(months_since: float) -> float:
    """x(months_since / 6), capped at 1.2 (spec gone-quiet rule)."""
    return min(1.2, max(0.0, float(months_since)) / 6.0)


# ---------------------------------------------------------------------------
# Date helpers
# ---------------------------------------------------------------------------

def _parse_dt(value):
    if value is None or isinstance(value, datetime):
        return value
    try:
        dt = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def _days_between(later: datetime, earlier: datetime) -> float:
    return (later - earlier).total_seconds() / 86400.0


def _when_phrase(days_until: int) -> str:
    if days_until <= 0:
        return "today"
    if days_until == 1:
        return "tomorrow"
    return f"in {_num_word(days_until)} days"


# ---------------------------------------------------------------------------
# Normalisation: tolerant of the loopback endpoints' exact field names.
# Canonical internal shapes (post privacy filter - only renderable items):
#   reply_debt:  {"count": int, "names": [str, ...]}
#   reconnect:   [{"name": str, "months_since_contact": float, "privacy": str}]
#   birthdays:   [{"name": str, "days_until": int, "privacy": str}]
#   commitments: [{"what": str, "days_until": int, "who": str | None,
#                  "privacy": str}]
# ---------------------------------------------------------------------------

def _first(d: dict, *keys, default=None):
    for k in keys:
        if isinstance(d, dict) and d.get(k) not in (None, ""):
            return d[k]
    return default


# ---------------------------------------------------------------------------
# Source privacy (fail-closed; audit 2026-07-13, Finding 2).
#
# A source item's declared level decides whether it may become a card at all.
# Resolution order: the item's own tag, else the enclosing payload's tag, else
# L3 (most restrictive). An explicit-but-unrecognised value is ALSO L3 - a typo
# must never publish. Only L0/L1/L2 items are renderable; the resolved level is
# propagated onto the card, clamped to at-least-L2 (signal cards name people).
# ---------------------------------------------------------------------------

_LEVEL_ORDER = {"L0": 0, "L1": 1, "L2": 2, "L3": 3}
_RENDERABLE_SOURCE_LEVELS = {"L0", "L1", "L2"}
_MOST_RESTRICTIVE = "L3"
_PRIVACY_KEYS = ("privacy", "privacy_level", "privacyLevel", "level")


def _declared_privacy(obj) -> str | None:
    """The privacy level ``obj`` itself declares: a normalised known level,
    ``L3`` for an explicit-but-unrecognised value, or None when absent."""
    if not isinstance(obj, dict):
        return None
    raw = _first(obj, *_PRIVACY_KEYS)
    if raw is None:
        return None
    level = str(raw).strip().upper()
    return level if level in _LEVEL_ORDER else _MOST_RESTRICTIVE


def _source_privacy(item, payload=None) -> str:
    """Resolved privacy level of one source item (fail-closed).

    The item's own tag wins; otherwise the enclosing payload's tag is
    inherited; otherwise L3 - an untagged item cannot prove it is safe."""
    own = _declared_privacy(item)
    if own is not None:
        return own
    inherited = _declared_privacy(payload)
    if inherited is not None:
        return inherited
    return _MOST_RESTRICTIVE


def _renderable(item, payload=None) -> bool:
    return _source_privacy(item, payload) in _RENDERABLE_SOURCE_LEVELS


def _card_privacy(source_level) -> str:
    """The privacy stamp for a card built from a source at ``source_level``:
    never less restrictive than L2 (signal cards name people), and never less
    restrictive than the source itself (an L3 source yields an L3 card, which
    the central ``privacy_gate`` then drops - defence in depth)."""
    level = source_level if source_level in _LEVEL_ORDER else _MOST_RESTRICTIVE
    return level if _LEVEL_ORDER[level] >= _LEVEL_ORDER["L2"] else "L2"


def _normalise_reply_debt(raw) -> dict:
    """Accept {"count", "names"}, {"count", "waiting":[{name}]}, or a bare list
    of {name}. Names only - any message-body field on the source is ignored.

    Fail-closed privacy: a person item counts (and is named) only if its
    resolved level is renderable - own tag, or inherited from the payload. The
    bare-strings ``names`` / aggregate ``count`` shape is usable only when the
    payload itself carries a renderable tag to vouch for it."""
    if isinstance(raw, list):
        kept = [x for x in raw if isinstance(x, dict) and _renderable(x)]
        names = [_first(x, "name", "display_name", "first_name") for x in kept]
        names = [n for n in names if n]
        return {"count": len(kept), "names": names}
    if isinstance(raw, dict):
        payload_ok = _declared_privacy(raw) in _RENDERABLE_SOURCE_LEVELS
        people = (raw.get("waiting") or raw.get("people")
                  or raw.get("contacts") or [])
        kept = [x for x in people if isinstance(x, dict) and _renderable(x, raw)]
        names = [_first(x, "name", "display_name", "first_name") for x in kept]
        names = [n for n in names if n]
        if payload_ok:
            names = names or [n for n in (raw.get("names") or []) if n]
            count = raw.get("count")
            if count is None:
                count = len(people) or len(names)
        else:
            count = len(kept)
        return {"count": int(count or 0), "names": names}
    return {"count": 0, "names": []}


def _months_since(item: dict, now: datetime) -> float | None:
    m = _first(item, "months_since_contact", "months_since", "months")
    if m is not None:
        try:
            return float(m)
        except (TypeError, ValueError):
            return None
    last = _parse_dt(_first(item, "last_contact", "last_seen", "last_contact_utc"))
    if last is not None:
        return max(0.0, _days_between(now, last) / 30.0)
    return None


def _days_until(item: dict, now: datetime, *date_keys: str) -> int | None:
    d = _first(item, "days_until", "days", "in_days")
    if d is not None:
        try:
            return int(d)
        except (TypeError, ValueError):
            return None
    when = _parse_dt(_first(item, *date_keys))
    if when is not None:
        return int(round(_days_between(when, now)))
    return None


def _normalise_suggestions(raw, now: datetime) -> tuple[list, list]:
    if not isinstance(raw, dict):
        return [], []
    recon_src = (raw.get("reconnect") or raw.get("stale_contacts")
                 or raw.get("gone_quiet") or [])
    reconnect = []
    for it in recon_src:
        if not isinstance(it, dict) or not _renderable(it, raw):
            continue
        name = _first(it, "name", "display_name")
        months = _months_since(it, now)
        if name and months is not None:
            reconnect.append({"name": name, "months_since_contact": months,
                              "privacy": _source_privacy(it, raw)})
    bday_src = raw.get("birthdays") or []
    birthdays = []
    for it in bday_src:
        if not isinstance(it, dict) or not _renderable(it, raw):
            continue
        name = _first(it, "name", "display_name")
        du = _days_until(it, now, "date", "birthday", "next")
        if name and du is not None:
            birthdays.append({"name": name, "days_until": du,
                              "privacy": _source_privacy(it, raw)})
    return reconnect, birthdays


def _normalise_commitments(raw, now: datetime) -> list:
    payload = raw if isinstance(raw, dict) else None
    if isinstance(raw, dict):
        raw = raw.get("commitments") or raw.get("items") or []
    if not isinstance(raw, list):
        return []
    out = []
    for it in raw:
        if not isinstance(it, dict) or not _renderable(it, payload):
            continue
        # ``what`` is arbitrary source free text (may itself be L3 content).
        # It is kept ONLY as the card's stable identity key - card ids are
        # sha1 hashes, so it never appears in the feed artefact - and is
        # never rendered (audit 2026-07-13, Finding 2).
        what = _first(it, "title", "what", "summary", "text", default="")
        who = _first(it, "with", "who", "counterparty", "owner_other")
        du = _days_until(it, now, "due", "due_date", "date", "deadline")
        if du is None:
            continue
        out.append({"what": str(what), "who": who, "days_until": du,
                    "privacy": _source_privacy(it, payload)})
    return out


# ---------------------------------------------------------------------------
# Card builders (pure). Each returns a card dict (or None to suppress).
# ---------------------------------------------------------------------------

def _ledger_created(ledger, cid: str, now: datetime) -> datetime:
    fe = _parse_dt(card_ledger.first_emitted(ledger, cid))
    return fe or now


def reply_debt_card(count: int, names, now: datetime, ledger=None,
                    privacy: str = "L2"):
    count = int(count or 0)
    if count <= 0:
        return None
    cid = fp.card_id("signal", "reply_debt")
    created = _ledger_created(ledger, cid, now)
    shown = [n for n in (names or []) if n][:2]
    if count == 1:
        title = _STRINGS["reply_debt_title_one"]
    else:
        title = _STRINGS["reply_debt_title_many"].format(count=_cap(_num_word(count)))
    if shown and len(shown) < count:
        extra = count - len(shown)
        subject = ", ".join(shown) + f" and {_num_word(extra)} other" + (
            "s" if extra != 1 else "")
    elif shown:
        subject = " and ".join(shown) if len(shown) == 2 else shown[0]
    else:
        subject = "Some people"
    have = "have" if (count != 1) else "has"
    body = _STRINGS["reply_debt_body"].format(names=subject, have=have)
    card = fp._make_card(
        "signal", "reply_debt", title=title, body=body, now=now,
        domain="people", priority=fp.BAND_REPLY_DEBT * reply_debt_proximity(count),
        action={"label": _STRINGS["reply_debt_action"], "kind": "open_reply_debt"},
        source="ostler:conversations", privacy=_card_privacy(privacy),
        signal={"type": "reply_debt", "count": count})
    card["created_utc"] = fp._iso(created)
    return card


def gone_quiet_card(name: str, months_since: float, now: datetime, ledger=None,
                    privacy: str = "L2"):
    if not name:
        return None
    cid = fp.card_id("signal", f"gone_quiet::{name}")
    fe = _parse_dt(card_ledger.first_emitted(ledger, cid))
    # Lifecycle window (spec 1.3): active for TTL days, then a cooldown, then
    # re-eligible as a fresh cycle. Measured from the ledger's first emission.
    cycle = fp.GONE_QUIET_TTL_DAYS + fp.GONE_QUIET_COOLDOWN_DAYS
    if fe is None:
        cycle_start = now
    else:
        age_days = max(0.0, _days_between(now, fe))
        pos = age_days % cycle
        if pos >= fp.GONE_QUIET_TTL_DAYS:
            return None  # in cooldown: swept and not re-emitted yet
        cycle_index = int(age_days // cycle)
        cycle_start = fe + timedelta(days=cycle_index * cycle)
    expires = cycle_start + timedelta(days=fp.GONE_QUIET_TTL_DAYS)
    m = int(round(months_since))
    body = (_STRINGS["gone_quiet_body_one"] if m == 1
            else _STRINGS["gone_quiet_body"].format(months=_num_word(m)))
    card = fp._make_card(
        "signal", f"gone_quiet::{name}",
        title=_STRINGS["gone_quiet_title"].format(name=name), body=body, now=now,
        domain="people",
        priority=fp.BAND_GONE_QUIET * gone_quiet_proximity(months_since),
        expires_utc=expires,
        action={"label": _STRINGS["gone_quiet_action"],
                "kind": "open_concierge_draft"},
        source="ostler:people", privacy=_card_privacy(privacy),
        signal={"type": "gone_quiet", "months_since_contact": round(months_since, 1)})
    card["created_utc"] = fp._iso(cycle_start)
    return card


def birthday_card(name: str, days_until: int, now: datetime, ledger=None,
                  privacy: str = "L2"):
    if not name or days_until is None:
        return None
    du = int(days_until)
    cid = fp.card_id("signal", f"birthday::{name}")
    created = _ledger_created(ledger, cid, now)
    # TTL: the date + 1 day (proximity carries urgency; no age decay).
    expires = now + timedelta(days=du + 1)
    when = _when_phrase(du)
    card = fp._make_card(
        "signal", f"birthday::{name}",
        title=_STRINGS["birthday_title"].format(name=name, when=when),
        body=_STRINGS["birthday_body"].format(when_cap=_cap(f"{when} away") if du > 1
                                               else _cap(when)),
        now=now, domain="dates",
        priority=fp.BAND_KEY_DATE * date_proximity(du),
        expires_utc=expires, source="ostler:people",
        privacy=_card_privacy(privacy),
        signal={"type": "birthday", "days_until": du})
    card["created_utc"] = fp._iso(created)
    return card


def commitment_card(what: str, days_until: int, who, now: datetime, ledger=None,
                    privacy: str = "L2"):
    """Commitment-due card. ``what`` (arbitrary source free text, possibly L3
    content) is used ONLY inside the sha1-hashed card id for stable identity -
    the rendered card carries the counterparty name and the due date, never the
    commitment text (audit 2026-07-13, Finding 2)."""
    if days_until is None:
        return None
    du = int(days_until)
    key = f"commitment::{who or ''}::{what}"
    cid = fp.card_id("signal", key)
    created = _ledger_created(ledger, cid, now)
    # TTL: due date + 3 days.
    expires = now + timedelta(days=du + 3)
    when = _when_phrase(du) if du >= 0 else "already"
    title = (_STRINGS["commitment_title_with"].format(who=who) if who
             else _STRINGS["commitment_title"])
    body = _STRINGS["commitment_body_plain"].format(when=when)
    card = fp._make_card(
        "signal", key, title=title, body=body, now=now, domain="commitments",
        priority=fp.BAND_COMMITMENT * date_proximity(du),
        expires_utc=expires,
        action={"label": _STRINGS["commitment_action"], "kind": "open_commitments"},
        source="ostler:commitments", privacy=_card_privacy(privacy),
        signal={"type": "commitment", "days_until": du})
    card["created_utc"] = fp._iso(created)
    return card


def build_signal_cards(raw: dict | None, now: datetime, ledger=None) -> list:
    """Turn the raw loopback signal payloads into ranked signal cards (pure).

    ``raw`` is ``{"reply_debt": <json>, "suggestions": <json>,
    "commitments": <json>}`` - any subset present. Missing / malformed families
    are simply skipped. Returns cards with ``base_band x proximity`` priority and
    stable TTLs; central age-decay is applied later in ``build_frontpage``."""
    if not raw or not isinstance(raw, dict):
        return []
    cards: list = []

    rd = _normalise_reply_debt(raw.get("reply_debt"))
    card = reply_debt_card(rd["count"], rd["names"], now, ledger=ledger)
    if card:
        cards.append(card)

    reconnect, birthdays = _normalise_suggestions(raw.get("suggestions"), now)
    for it in reconnect:
        card = gone_quiet_card(it["name"], it["months_since_contact"], now,
                               ledger=ledger, privacy=it["privacy"])
        if card:
            cards.append(card)
    for it in birthdays:
        card = birthday_card(it["name"], it["days_until"], now, ledger=ledger,
                             privacy=it["privacy"])
        if card:
            cards.append(card)

    for it in _normalise_commitments(raw.get("commitments"), now):
        card = commitment_card(it["what"], it["days_until"], it["who"], now,
                               ledger=ledger, privacy=it["privacy"])
        if card:
            cards.append(card)

    return cards


# ---------------------------------------------------------------------------
# Network layer (the ONLY one). Loopback-only, per-endpoint best-effort.
# ---------------------------------------------------------------------------

_LOOPBACK_HOSTS = {"127.0.0.1", "localhost", "::1"}
_DEFAULT_TIMEOUT = 5.0

_ENDPOINTS = {
    "reply_debt": "/api/v1/reply-debt",
    "suggestions": "/api/v1/suggestions",
    "commitments": "/api/v1/commitments?owner=user&status=open",
}


def _is_loopback(base_url: str) -> bool:
    try:
        host = urlparse(base_url).hostname or ""
    except Exception:
        return False
    return host in _LOOPBACK_HOSTS


def _get_json(url: str, timeout: float):
    """GET one loopback URL. Returns parsed JSON, or None on any failure
    (connection refused, timeout, non-200, malformed body)."""
    try:
        req = urllib.request.Request(url, headers={"Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310
            if getattr(resp, "status", 200) not in (200, None):
                return None
            return json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, socket.timeout, ValueError, OSError):
        return None
    except Exception:  # noqa: BLE001 - a signal fetch never breaks the feed
        return None


def fetch_signals(base_url: str = "http://127.0.0.1:8090",
                  timeout: float = _DEFAULT_TIMEOUT) -> dict:
    """Fetch the live-signal payloads from the loopback ical-server.

    Loopback-only by hard guard (spec section 4 / A-E2-6): a non-loopback
    ``base_url`` yields ``{}`` and makes zero network calls. Each endpoint is
    independently optional - one being down never suppresses the others."""
    if not _is_loopback(base_url):
        return {}
    base = base_url.rstrip("/")
    out: dict = {}
    for key, path in _ENDPOINTS.items():
        data = _get_json(base + path, timeout)
        if data is not None:
            out[key] = data
    return out
