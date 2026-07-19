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

Card schema (DESIGN section 4; v0.2 adds the last two, both optional) - every
card, whatever its kind, shares it::

    {
      "id", "kind", "domain", "title", "body", "priority",
      "created_utc", "expires_utc", "state", "action",
      "evidence", "source", "feedback",
      "privacy",   # "L1" (about the operator) | "L2" (names a person)  [E2]
      "signal"     # typed provenance for live signal cards, names-only [E2]
    }

E2 adds a second card family alongside standing interests: **live signal cards**
(reply-debt, gone-quiet, key dates, commitments) built in ``signals.py`` from the
loopback relationship endpoints and ranked by the unified table in spec section
1.3 (``base_band x proximity x age-decay``). They carry ``privacy: "L2"`` and are
gated fail-closed so no L3 content can ever reach the feed.

TTL + decay (DESIGN section 4): ephemeral cards
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

from compiler import card_ledger

SCHEMA_VERSION = "0.2"

# A profile with at least this many confident interests is "rich" enough to lead
# the Front Page with interest cards (steady state). Below it, we are still
# onboarding / hydrating and the page leans on the settling + confirm cards.
MIN_STEADY_INTERESTS = 6

# How many interest cards to surface, and the cap per domain so one rich domain
# (music, say) cannot crowd everything else off the page.
MAX_INTEREST_CARDS = 12
MAX_PER_DOMAIN = 4

# Feed hygiene caps (E2, spec section 1.3): a burst of live signals must not
# crowd the whole page, and the feed as a whole stays scannable.
MAX_SIGNAL_CARDS = 5
MAX_FEED_CARDS = 20

# Priority bands. Higher floats sort first. Decay pulls cards down over time.
PRIORITY_SETTLING = 100.0
PRIORITY_ONBOARDING = 80.0
PRIORITY_INTEREST_TOP = 60.0   # the single strongest interest starts here
PRIORITY_INTEREST_FLOOR = 5.0  # a weak interest never sinks below this

# Signal-card base bands (E2, spec section 1.3 ranking table). Proximity factors
# live with the signal builders (signals.py) since they depend on live magnitude
# (reply-debt count, days-until, months-since); a card's pre-decay priority is
# ``base_band x proximity``.
BAND_REPLY_DEBT = 90.0
BAND_KEY_DATE = 85.0
BAND_COMMITMENT = 75.0
BAND_GONE_QUIET = 70.0
BAND_CONSENT = 82.0

# Scout novelty (E3, spec section 1.3): a scout card's pre-decay priority is
# ``BAND_SCOUT x relevance-vs-profile`` (the builders supply relevance in 0..1).
BAND_SCOUT = 65.0

# Half-life (days) for card-age priority decay. A persistent card that has been
# sitting for one half-life is worth half its starting priority, so fresh and
# actioned-but-stale cards self-sort without anyone tending the feed.
DECAY_HALF_LIFE_DAYS = 7.0

# Per-CLASS age half-life (days). Age is measured from the card's FIRST emission
# (the ledger, card_ledger.py), applied centrally in build_frontpage - this is
# the E1 fix for the "created_utc re-stamped every tick so decay never bit" bug.
# A class absent from this map does NOT age-decay: the settling card is
# regenerated and dies when hydration ends; key-date and commitment cards let
# proximity + TTL carry their urgency rather than sinking with age.
HALF_LIFE_BY_CLASS = {
    "interest": 540.0,           # a favourite fades slowly, never vanishes
    "onboarding": DECAY_HALF_LIFE_DAYS,  # a confirm card sinks if ignored (7d)
    "reply_debt": 2.0,           # a fresh reply-debt is urgent, then sinks fast
    "gone_quiet": 7.0,           # a reconnect nudge fades over a week
    "scout": 3.0,                # novelty is perishable (spec 1.3 scout row)
}

# Gone-quiet lifecycle (spec section 1.3): a reconnect card shows for up to
# GONE_QUIET_TTL_DAYS, then goes quiet for GONE_QUIET_COOLDOWN_DAYS before it is
# eligible to re-emit as a fresh cycle. Anchored to the ledger first-emission.
GONE_QUIET_TTL_DAYS = 14
GONE_QUIET_COOLDOWN_DAYS = 30

# Privacy fail-closed (spec section 4): only L1 (about the operator) and L2
# (names another person, counts-only) may reach the feed. Anything else - most
# importantly an L3-sourced card - is dropped. A card with NO privacy field is
# treated as L3 and dropped too: an untagged card cannot prove it is safe
# (audit 2026-07-13, Finding 2). Every in-repo builder stamps a level via
# _make_card, so only foreign/malformed cards pay this tax.
PRIVACY_ALLOWED = {"L1", "L2"}

# Every level the producer can legitimately stamp. Anything outside this set
# (missing, typo'd, empty) is untrusted and fails closed to L3.
_RECOGNISED_PRIVACY = {"L0", "L1", "L2", "L3"}


def _row_privacy(row: dict) -> str:
    """The privacy a card INHERITS from its source interest row, fail-closed.
    The producer stamps each interest row (interest_profile.classify_privacy);
    an L2 row names a person, an L3 row is sensitive. A card must carry that
    level, NOT a blanket L1 - otherwise an L2/L3 interest ships as an L1 card
    and a downstream consumer trusting ``privacy:"L1"`` as "safe to send" would
    egress it. Missing/unrecognised -> L3, so an untagged row cannot buy itself
    L1 (and is then dropped by the fail-closed privacy_gate)."""
    lvl = (row or {}).get("privacy")
    return lvl if lvl in _RECOGNISED_PRIVACY else "L3"

# Pro entitlement (PRO_SLATE_MONETISATION_SPEC section 0.1, locked 2026-07-12:
# the Editor Front Page is Pro proactivity). When the ``front_page_feed``
# entitlement is DENIED (entitlement.py, fail-closed) these proactive/curated
# card families are suppressed. The system settling card is install state, not
# proactivity, and stays: the paywall is on Ostler's ongoing labour, never on
# knowing what your install is doing.
PRO_GATED_KINDS = {"interest", "signal", "onboarding", "consent"}
PRIORITY_PRO_LOCKED = 90.0  # below settling (100), above everything gated off

# Exploration slot (E4, spec section 1.5 anti-filter-bubble): with a saturated
# profile, ONE of the MAX_INTEREST_CARDS slots is reserved for an adjacent,
# sub-threshold interest, labelled honestly as a hunch. Its feedback trains
# the pick (drop removes the candidate from the next compile via the ordinary
# CorrectionStore path). The 1-in-12 slice is an open product question (spec
# section 6 Q6); the slot only exists when the profile actually overflows the
# cap, so a thin profile never loses a real interest to a hunch. TTL keeps
# hunches rotating rather than camping.
EXPLORATION_TTL_DAYS = 7


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
               feedback=None, privacy: str = "L3",
               signal: dict | None = None) -> dict:
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
        "privacy": privacy,
        "signal": signal,
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
        privacy="L1",  # Ostler's own status copy about the operator; no PII
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
        privacy="L1",  # onboarding copy + a count; about the operator, no PII
    )


def pro_locked_card(now: datetime) -> dict:
    """The single honest card shown when the Front Page's Pro entitlement is
    denied (gate evaluated, answer no). No dark patterns: it says plainly what
    the Front Page does and that it is part of Pro; nothing counts down,
    nothing nags, and it is dismissable like any other card. Copy is
    placeholder pending the operator's product pass (flagged in the design note)."""
    return _make_card(
        "system", "pro_locked",
        title="Your Front Page is part of Ostler Pro",
        body=("The Editor curates a Front Page from your world - reconnections "
              "worth making, dates coming up, things you are into. It is part "
              "of Ostler Pro. Everything Ostler has already compiled for you "
              "stays yours, readable as ever."),
        now=now, priority=PRIORITY_PRO_LOCKED,
        action={"label": "About Ostler Pro", "kind": "open_pro_info"},
        source="ostler:editor",
        privacy="L1",  # generic product copy; about the operator, no PII
    )


def interest_card(it: dict, now: datetime, rank: int, n: int) -> dict:
    """Phase C card: one inferred interest, with its evidence and the rate/
    correct affordances. Priority is the interest's own score mapped into the
    interest **base band** (top-ranked highest). Age decay is applied centrally
    in ``build_frontpage`` off the card ledger's first-emission timestamp (E1),
    not here - so it measures true card age, not this tick."""
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
        priority=base,
        action={"label": "Spot on", "kind": "strengthen"},
        evidence=evidence,
        source="ostler:interest_profile",
        feedback=it.get("feedback"),
        privacy=_row_privacy(it),  # inherit the interest row's level, NOT L1
    )


def exploration_pick(profile: dict, picked: list[dict]) -> dict | None:
    """The E4 anti-filter-bubble pick: the strongest liked interest that did
    NOT make the top set, preferring one from a domain the page is not already
    showing (adjacent beats merely-next). ``None`` when nothing is left - a
    thin profile has no sub-threshold pool to explore."""
    picked_ids = {it.get("id") for it in picked}
    picked_domains = {it.get("domain") for it in picked}
    pool = [it for block in profile.get("domains", [])
            for it in block.get("interests", [])
            if it.get("polarity") != "dislike"
            and it.get("id") not in picked_ids]
    if not pool:
        return None
    pool.sort(key=lambda it: it.get("score", 0.0), reverse=True)
    for it in pool:
        if it.get("domain") not in picked_domains:
            return it
    return pool[0]


def exploration_card(it: dict, now: datetime, ledger=None) -> dict:
    """One hunch card, labelled honestly (spec section 1.5: "A hunch, based
    on..."). Identity is stable per ISO week, so re-ticks keep its ledger age
    and dismiss state and a new week may bring a new hunch; TTL is 7 days
    from first emission. It carries ``sources`` = the underlying interest id,
    so the ordinary feedback verbs train the pick - a ``drop`` removes the
    candidate from the next compile via the CorrectionStore (A-E4-4)."""
    iso = now.isocalendar()
    key = f"exploration::{iso[0]}-W{iso[1]:02d}"
    cid = card_id("interest", key)
    fe = _parse_dt(card_ledger.first_emitted(ledger, cid))
    created = fe or now
    card = _make_card(
        "interest", key,
        title=it["subject"],
        body=("A hunch, based on what Ostler already knows you're into - "
              "say if it lands."),
        now=now, domain=it.get("domain"),
        priority=PRIORITY_INTEREST_FLOOR,
        expires_utc=created + timedelta(days=EXPLORATION_TTL_DAYS),
        action={"label": "Spot on", "kind": "strengthen"},
        evidence="an exploration pick: below Ostler's usual confidence bar",
        source="ostler:interest_profile",
        privacy=_row_privacy(it),  # inherit the interest row's level, NOT L1
    )
    card["created_utc"] = _iso(created)
    card["exploration"] = True
    if it.get("id"):
        card["sources"] = [it["id"]]
    return card


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


def card_class(card: dict) -> str:
    """The ranking class of a card (spec section 1.3). For ``signal`` cards the
    class is the signal type (reply_debt / gone_quiet / key-date via birthday /
    commitment); a scout-produced card (source ``ostler:scout_*``) is class
    ``scout`` whatever its kind (a digest is ``kind: interest`` but its novelty
    is perishable - half-life 3 days, not 540); every other kind is its own
    class. Drives both the age half-life (``HALF_LIFE_BY_CLASS``) and, for
    signals, which band the builder used."""
    if card.get("kind") == "signal":
        stype = (card.get("signal") or {}).get("type")
        return {"reply_debt": "reply_debt", "gone_quiet": "gone_quiet",
                "birthday": "key_date", "key_date": "key_date",
                "commitment": "commitment"}.get(stype, "signal")
    if str(card.get("source") or "").startswith("ostler:scout_"):
        return "scout"
    return card.get("kind", "")


def _apply_ledger_age(cards: list[dict], ledger: dict | None,
                      now: datetime) -> None:
    """Overlay the ledger's stable first-emission timestamp onto ``created_utc``
    (in place), then age-decay each card's priority from that true first sighting
    rather than this tick. This is the E1 decay fix: without it ``created_utc``
    was re-stamped to ``now`` every tick, so age was always ~0 and decay/TTL
    never bit. A card with no ledger entry (first emission) keeps ``created_utc``
    = now -> age 0 -> full band, which is correct.

    Signal cards (E2) manage their own ``created_utc`` in the builder - reply-debt
    uses the first sighting, gone-quiet uses its current cycle start - so this
    pass does NOT overwrite it for them; it only applies the class age-decay."""
    for c in cards:
        if c.get("kind") != "signal":
            fe = card_ledger.first_emitted(ledger, c["id"])
            if fe:
                c["created_utc"] = fe
        half_life = HALF_LIFE_BY_CLASS.get(card_class(c))
        if half_life:
            c["priority"] = round(
                decay_priority(c["priority"], c.get("created_utc"), now,
                               half_life_days=half_life), 4)


def privacy_gate(cards: list[dict]) -> list[dict]:
    """Fail-closed privacy filter (spec section 4): keep only cards whose privacy
    is in ``PRIVACY_ALLOWED`` (L1 owner-data / L2 names-a-person, counts only).
    An L3-sourced card - or any card with an unrecognised level - is dropped, so
    a bug upstream can never leak private content onto the Front Page. A missing
    (or empty) field is treated as L3 and dropped: an untagged card cannot prove
    it is safe (audit 2026-07-13, Finding 2; the builders always set a level)."""
    return [c for c in cards if (c.get("privacy") or "L3") in PRIVACY_ALLOWED]


def dedup_by_id(cards: list[dict]) -> list[dict]:
    """Producer-side dedup: keep the first (highest-priority, since the list is
    already ranked) card per id. Ids are unique by construction today, so this
    is a defence line, mirroring the Hub's render-time TTL/dedup/rank defence:
    a builder bug or a merged stale artefact must not put the same card on the
    page twice. Order-preserving."""
    seen: set[str] = set()
    out: list[dict] = []
    for c in cards:
        cid = c.get("id")
        if cid in seen:
            continue
        if cid is not None:
            seen.add(cid)
        out.append(c)
    return out


def entitlement_gate(cards: list[dict], entitled: bool | None,
                     now: datetime) -> list[dict]:
    """Fail-closed Pro gate over an assembled card list (spec: the Front Page
    is Pro proactivity; entitlement.py holds the decision logic).

    ``entitled`` is three-state: ``None`` = enforcement off (gate not
    evaluated - the pre-gate behaviour, everything passes); ``True`` = Pro
    verified, everything passes; ``False`` (INCLUDING every ambiguous state
    upstream - missing/malformed/stale/expired sidecar all collapse to False
    in ``entitlement.is_entitled``) = the proactive families
    (``PRO_GATED_KINDS``) are dropped and one honest pro-locked card is added.
    Anything not recognised as exactly ``None`` or ``True`` denies."""
    if entitled is None:
        return cards
    if entitled is True:
        return cards
    kept = [c for c in cards if c.get("kind") not in PRO_GATED_KINDS]
    kept.append(pro_locked_card(now))
    return kept


def _apply_feed_caps(cards: list[dict]) -> list[dict]:
    """Enforce the feed hygiene caps on an already-ranked (priority-desc) list:
    at most ``MAX_SIGNAL_CARDS`` signal cards, then ``MAX_FEED_CARDS`` overall.
    Lower-priority signal cards are dropped first so the strongest live signals
    survive; interest/system/onboarding cards keep their places."""
    kept: list[dict] = []
    signals_kept = 0
    for c in cards:
        if c.get("kind") == "signal":
            if signals_kept >= MAX_SIGNAL_CARDS:
                continue
            signals_kept += 1
        kept.append(c)
    return kept[:MAX_FEED_CARDS]


def build_frontpage(profile: dict, *, now: datetime | None = None,
                    settling: dict | None = None,
                    card_states: dict | None = None,
                    ledger: dict | None = None,
                    signals: dict | None = None,
                    scout_cards: list | None = None,
                    demo: bool = False,
                    entitled: bool | None = None,
                    exploration: bool = True) -> dict:
    """Compile the Front Page card feed from a Phase-0 interest profile plus
    optional settling + card-state + ledger + live-signal inputs. Pure: same
    inputs -> same feed. ``ledger`` (card_ledger.py) supplies each card's true
    first-emission time so age decay measures real card age (E1). ``signals``
    (E2) is the raw loopback payload (see signals.py) that yields the live
    reply-debt / gone-quiet / key-date / commitment cards; ``scout_cards``
    (E3) are pre-built, consent-gated scout cards (scouts.run_scouts - e.g.
    the weekly newsletters digest) that join the assembly like any other
    family; ``demo`` hard-suppresses both live-signal AND scout cards (spec
    section 4 demo posture - proactive live content never renders in demo).

    ``entitled`` is the Pro ``front_page_feed`` decision (entitlement.py):
    ``None`` = enforcement off (legacy behaviour), ``True`` = Pro verified,
    anything else = fail-closed deny -> proactive families suppressed and one
    honest pro-locked card shown."""
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

    # E4 exploration slot: only when the profile actually saturates the cap
    # does one slot go to an honest hunch (an adjacent, sub-threshold pick).
    # Suppressed in demo mode like every other proactive family; ``exploration
    # = False`` is the emitter's kill switch.
    hunch = None
    if exploration and not demo and len(tops) >= MAX_INTEREST_CARDS:
        pick = exploration_pick(profile, tops)
        if pick is not None:
            tops = tops[:MAX_INTEREST_CARDS - 1]
            hunch = exploration_card(pick, now, ledger=ledger)

    n = len(tops)
    for rank, it in enumerate(tops):
        cards.append(interest_card(it, now, rank, n))
    if hunch is not None:
        cards.append(hunch)

    # E2 live signal cards - deterministic, loopback-fed, privacy L2. Suppressed
    # wholesale in demo mode. Imported lazily to avoid an import cycle (signals
    # imports this module for its bands + card constructors).
    if not demo:
        from compiler import signals as _signals
        cards.extend(_signals.build_signal_cards(signals, now, ledger=ledger))

    # E3 scout cards - already consent-gated + built upstream (scouts.py); the
    # central assembly below still applies ledger age, TTL, states, the
    # fail-closed privacy + Pro gates and the feed caps to them, exactly as to
    # every other family. Demo mode suppresses them wholesale.
    if not demo and scout_cards:
        cards.extend(scout_cards)

    # Feed assembly: overlay the ledger (stable created_utc) and age-decay from
    # first emission, TTL sweep, state store, fail-closed privacy gate,
    # fail-closed Pro entitlement gate, then rank by (decayed) priority,
    # dedup by id, and enforce the feed hygiene caps on the ranked list.
    _apply_ledger_age(cards, ledger, now)
    cards = [c for c in cards if not is_expired(c, now)]
    cards = apply_card_states(cards, card_states, now)
    cards = privacy_gate(cards)
    cards = entitlement_gate(cards, entitled, now)
    cards.sort(key=lambda c: c.get("priority", 0.0), reverse=True)
    cards = dedup_by_id(cards)
    cards = _apply_feed_caps(cards)

    envelope_pro = (None if entitled is None else
                    {"feature": "front_page_feed", "entitled": bool(entitled is True)})
    out = {
        "schema_version": SCHEMA_VERSION,
        "generated_utc": _iso(now),
        "phase": phase,
        "card_count": len(cards),
        "cards": cards,
        "stats": {
            "phase": phase,
            "interest_cards": sum(1 for c in cards if c["kind"] == "interest"
                                  and card_class(c) != "scout"),
            "signal_cards": sum(1 for c in cards if c["kind"] == "signal"),
            "system_cards": sum(1 for c in cards if c["kind"] == "system"),
            "onboarding_cards": sum(1 for c in cards if c["kind"] == "onboarding"),
            "profile_interests": profile.get("stats", {}).get("interests", 0),
        },
    }
    # Additive, optional (schema stays 0.2): present only when the gate was
    # actually evaluated, so pre-gate consumers see an unchanged envelope.
    if envelope_pro is not None:
        out["pro"] = envelope_pro
    # Additive, optional: the scout-card count appears only when a scout
    # actually contributed, so a no-consent feed stays byte-identical to the
    # pre-scout (E2) envelope on the same inputs (A-E3-4).
    n_scout = sum(1 for c in cards if card_class(c) == "scout")
    if n_scout:
        out["stats"]["scout_cards"] = n_scout
    # Additive, optional: present only when the exploration slot (E4) or a
    # consent offer actually made the page, so earlier envelopes are unchanged.
    n_explore = sum(1 for c in cards if c.get("exploration") is True)
    if n_explore:
        out["stats"]["exploration_cards"] = n_explore
    n_consent = sum(1 for c in cards if c.get("kind") == "consent")
    if n_consent:
        out["stats"]["consent_cards"] = n_consent
    return out


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
