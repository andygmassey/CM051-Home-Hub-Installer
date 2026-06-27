"""The Front Page card feed (Phase 1 wiring).

Phase 0 produced the *interest profile* - a ranked, evidence-backed, correctable
view of what the user is into. The Front Page is the next layer up: it turns that
profile (plus install/settling state) into the **card feed** described in
``DESIGN_the_editor_frontpage.md`` section 4 - one card schema, one set of
controls, three lifecycle phases.

This module is the PRODUCER of the feed artefact. A surface (the Hub Doctor
``/frontpage`` route today; the macOS Hub app and iOS app later) renders the same
JSON. "Write once, read everywhere."

Lifecycle phases (DESIGN section 3), decided here from the inputs:

  * **hydrating**  - a fresh install whose brain is still forming. One calm
    settling card carries the story; any interests we already have ride along as
    a low-priority preview so the page is never empty.
  * **onboarding** - hydration done but the profile is still thin / unconfirmed.
    The "confirm your interests" card leads; interests follow.
  * **steady**     - a populated profile. The interest cards lead; the settling
    card is gone.

Card schema (DESIGN section 4) - every card, whatever its kind, shares it::

    {
      "id", "kind", "domain", "title", "body", "priority",
      "created_utc", "expires_utc", "state", "action",
      "evidence", "source", "feedback"
    }

TTL + decay (DESIGN section 4, Andy's load-bearing addition): ephemeral cards
auto-expire (``expires_utc``); priority **decays with age** so even un-expired
cards sink rather than camping at the top. The per-card state store keeps
dismiss / snooze / complete stable across sessions and devices.

Pure + testable: ``build_frontpage`` is a pure function of (profile, now,
settling, card_states). All I/O (reading the settling sidecar, the state store,
writing artefacts) lives in ``emit_frontpage.py``.
"""

from __future__ import annotations

import hashlib
from datetime import datetime, timedelta, timezone

SCHEMA_VERSION = "0.1"

# A profile with at least this many confident interests is "rich" enough to lead
# the Front Page with interest cards (steady state). Below it, we are still
# onboarding / hydrating and the page leans on the settling + confirm cards.
MIN_STEADY_INTERESTS = 6

# How many interest cards to surface, and the cap per domain so one rich domain
# (music, say) cannot crowd everything else off the page.
MAX_INTEREST_CARDS = 12
MAX_PER_DOMAIN = 4

# Priority bands. Higher floats sort first. Decay pulls cards down over time.
PRIORITY_SETTLING = 100.0
PRIORITY_ONBOARDING = 80.0
PRIORITY_INTEREST_TOP = 60.0   # the single strongest interest starts here
PRIORITY_INTEREST_FLOOR = 5.0  # a weak interest never sinks below this

# Half-life (days) for card-age priority decay. A persistent card that has been
# sitting for one half-life is worth half its starting priority, so fresh and
# actioned-but-stale cards self-sort without anyone tending the feed.
DECAY_HALF_LIFE_DAYS = 7.0


# ---------------------------------------------------------------------------
# Pure helpers
# ---------------------------------------------------------------------------

def card_id(kind: str, key: str) -> str:
    """Stable id so a card keeps its identity (and its dismiss/snooze state)
    across ticks. Keyed on kind + a stable key (interest id, or a fixed slug
    for the singleton system/onboarding cards)."""
    h = hashlib.sha1(f"{kind}::{key}".encode("utf-8")).hexdigest()[:12]
    return f"card_{h}"


def _parse_dt(value):
    if value is None or isinstance(value, datetime):
        return value
    try:
        dt = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def decay_priority(base: float, created_utc, now: datetime,
                   half_life_days: float = DECAY_HALF_LIFE_DAYS) -> float:
    """Age-decayed priority: ``base * 0.5 ** (age_days / half_life)``.

    A card created ``now`` keeps its full base; an old persistent card sinks.
    Missing / future ``created_utc`` is treated as age 0 (full base). Never
    returns below 0."""
    created = _parse_dt(created_utc)
    if created is None:
        return max(0.0, base)
    age_days = max(0.0, (now - created).total_seconds() / 86400.0)
    if half_life_days <= 0:
        return max(0.0, base)
    return max(0.0, base * (0.5 ** (age_days / half_life_days)))


def is_expired(card: dict, now: datetime) -> bool:
    """A card with an ``expires_utc`` in the past is dead (ephemeral TTL)."""
    exp = _parse_dt(card.get("expires_utc"))
    return exp is not None and exp <= now


def _iso(dt: datetime | None):
    return dt.isoformat() if dt is not None else None


# ---------------------------------------------------------------------------
# Card constructors
# ---------------------------------------------------------------------------

def _make_card(kind: str, key: str, *, title: str, body: str, now: datetime,
               domain: str | None = None, priority: float = 10.0,
               expires_utc: datetime | None = None, action: dict | None = None,
               evidence: str | None = None, source: str | None = None,
               feedback=None) -> dict:
    return {
        "id": card_id(kind, key),
        "kind": kind,
        "domain": domain,
        "title": title,
        "body": body,
        "priority": round(priority, 4),
        "created_utc": _iso(now),
        "expires_utc": _iso(expires_utc),
        "state": "active",
        "action": action,
        "evidence": evidence,
        "source": source,
        "feedback": feedback,
    }


def settling_card(settling: dict | None, now: datetime) -> dict:
    """Phase A card: 'your brain is still forming'. Carries the real progress
    (percent + a rate-based plain-English line) when the host hands us a
    settling signal, else a calm generic reassurance. Regenerated every tick,
    so it clears itself the moment settling ends (the emitter simply stops
    producing it)."""
    pct = None
    days = None
    if settling:
        pct = settling.get("pct")
        days = settling.get("days_remaining")
    if pct is not None:
        body = (f"Ostler is still reading itself in - about {int(pct)}% through. "
                "Your Front Page fills in and sharpens over the next few days as "
                "the background feeds finish settling.")
    elif days is not None:
        body = (f"Ostler is still settling in - roughly {int(days)} more day"
                f"{'s' if int(days) != 1 else ''} of background reading. "
                "Pages will fill in and sharpen as it goes.")
    else:
        body = ("Ostler is still settling in. Your Front Page fills in and "
                "sharpens over the first few days as the background feeds finish "
                "reading your world.")
    return _make_card(
        "system", "settling",
        title="Your Front Page is still settling in",
        body=body, now=now, priority=PRIORITY_SETTLING,
        evidence=(f"{int(pct)}% of the first read-in done" if pct is not None else None),
        source="ostler:hydration",
    )


def confirm_interests_card(profile: dict, now: datetime) -> dict:
    """Phase B onboarding card: invite the user to confirm / correct what Ostler
    thinks they are into. Persistent until completed (no TTL). Folds the Phase-0
    verify-and-correct surface into the card feed."""
    stats = profile.get("stats", {})
    n = stats.get("interests", 0)
    body = (f"Ostler has spotted {n} interest{'s' if n != 1 else ''} from what it "
            "has read so far. Tell it which are spot on, which are off, and add "
            "anything it has missed - it sharpens everything that follows.")
    return _make_card(
        "onboarding", "confirm_interests",
        title="Confirm what Ostler thinks you're into",
        body=body, now=now, priority=PRIORITY_ONBOARDING,
        action={"label": "Review interests", "kind": "open_interest_profile"},
        evidence=f"{n} interests inferred so far",
        source="ostler:interest_profile",
    )


def interest_card(it: dict, now: datetime, rank: int, n: int) -> dict:
    """Phase C card: one inferred interest, with its evidence and the rate/
    correct affordances. Priority is the interest's own score mapped into the
    interest band (top-ranked highest), then age-decayed like every card."""
    span = max(1, n - 1)
    base = PRIORITY_INTEREST_FLOOR + (PRIORITY_INTEREST_TOP - PRIORITY_INTEREST_FLOOR) * (
        1.0 - rank / span) if n > 1 else PRIORITY_INTEREST_TOP
    evidence = " - ".join(it.get("evidence", [])[:2]) or None
    return _make_card(
        "interest", it["id"],
        title=it["subject"],
        body=("Something to avoid" if it.get("polarity") == "dislike"
              else "One of the things Ostler reckons you're into."),
        now=now, domain=it.get("domain"),
        priority=decay_priority(base, it.get("last_seen"), now,
                                half_life_days=540.0),
        action={"label": "Spot on", "kind": "strengthen"},
        evidence=evidence,
        source="ostler:interest_profile",
        feedback=it.get("feedback"),
    )


# ---------------------------------------------------------------------------
# State store application (pure)
# ---------------------------------------------------------------------------

def apply_card_states(cards: list[dict], states: dict | None,
                      now: datetime) -> list[dict]:
    """Apply the per-card state store (DESIGN section 4) so dismiss / snooze /
    complete are stable across ticks and devices.

    ``states`` maps card-id -> {"state": "dismissed_forever" | "completed" |
    "snoozed_until", "until": "<iso>"}. A dismissed-forever or completed card is
    dropped; a snoozed card is dropped until its ``until`` passes. Unknown ids
    pass through untouched."""
    if not states:
        return cards
    out = []
    for card in cards:
        st = states.get(card["id"])
        if not st:
            out.append(card)
            continue
        kind = st.get("state")
        if kind in ("dismissed_forever", "completed"):
            continue
        if kind == "snoozed_until":
            until = _parse_dt(st.get("until"))
            if until is not None and until > now:
                continue  # still snoozed
        card = dict(card, state=kind or card["state"])
        out.append(card)
    return out


# ---------------------------------------------------------------------------
# The feed builder (pure)
# ---------------------------------------------------------------------------

def _top_interests(profile: dict) -> list[dict]:
    """Flatten the profile's domain blocks into a single ranked list, capped per
    domain so no one domain dominates the feed."""
    per_domain: dict[str, int] = {}
    picked: list[dict] = []
    blocks = sorted(profile.get("domains", []),
                    key=lambda b: -sum(i.get("score", 0) for i in b.get("interests", [])))
    # interleave round-robin-ish by taking the domains' tops in score order
    pool = []
    for b in blocks:
        for it in b.get("interests", []):
            pool.append(it)
    pool.sort(key=lambda it: it.get("score", 0.0), reverse=True)
    for it in pool:
        dom = it.get("domain", "Other")
        if per_domain.get(dom, 0) >= MAX_PER_DOMAIN:
            continue
        picked.append(it)
        per_domain[dom] = per_domain.get(dom, 0) + 1
        if len(picked) >= MAX_INTEREST_CARDS:
            break
    return picked


def decide_phase(profile: dict, settling: dict | None) -> str:
    """Which lifecycle phase are we in? Settling signal -> hydrating; a thin
    profile -> onboarding; a populated profile -> steady."""
    if settling and (settling.get("any_working") or settling.get("days_remaining")):
        return "hydrating"
    n = profile.get("stats", {}).get("interests", 0)
    if n < MIN_STEADY_INTERESTS:
        return "onboarding"
    return "steady"


def build_frontpage(profile: dict, *, now: datetime | None = None,
                    settling: dict | None = None,
                    card_states: dict | None = None) -> dict:
    """Compile the Front Page card feed from a Phase-0 interest profile plus
    optional settling + card-state inputs. Pure: same inputs -> same feed."""
    now = now or datetime.now(timezone.utc)
    phase = decide_phase(profile, settling)
    cards: list[dict] = []

    # Phase A: the settling card leads while the install is still hydrating.
    if phase == "hydrating":
        cards.append(settling_card(settling, now))

    # Phase A/B: invite confirmation while the profile is not yet steady.
    if phase in ("hydrating", "onboarding"):
        cards.append(confirm_interests_card(profile, now))

    # Interest cards: always carry whatever real signal we have so the page is
    # never empty - they just rank below the settling/onboarding cards until the
    # profile is rich enough to lead (steady).
    tops = _top_interests(profile)
    n = len(tops)
    for rank, it in enumerate(tops):
        cards.append(interest_card(it, now, rank, n))

    # TTL sweep, then state store, then rank by (decayed) priority.
    cards = [c for c in cards if not is_expired(c, now)]
    cards = apply_card_states(cards, card_states, now)
    cards.sort(key=lambda c: c.get("priority", 0.0), reverse=True)

    return {
        "schema_version": SCHEMA_VERSION,
        "generated_utc": _iso(now),
        "phase": phase,
        "card_count": len(cards),
        "cards": cards,
        "stats": {
            "phase": phase,
            "interest_cards": sum(1 for c in cards if c["kind"] == "interest"),
            "system_cards": sum(1 for c in cards if c["kind"] == "system"),
            "onboarding_cards": sum(1 for c in cards if c["kind"] == "onboarding"),
            "profile_interests": profile.get("stats", {}).get("interests", 0),
        },
    }


def empty_frontpage(now: datetime | None = None, settling: dict | None = None) -> dict:
    """A graceful feed for the moment before any profile exists at all (the
    artefact is missing on a brand-new install). One settling card, nothing
    else - never a blank page."""
    now = now or datetime.now(timezone.utc)
    cards = [settling_card(settling, now)]
    return {
        "schema_version": SCHEMA_VERSION,
        "generated_utc": _iso(now),
        "phase": "hydrating",
        "card_count": len(cards),
        "cards": cards,
        "stats": {"phase": "hydrating", "interest_cards": 0,
                  "system_cards": 1, "onboarding_cards": 0,
                  "profile_interests": 0},
    }
