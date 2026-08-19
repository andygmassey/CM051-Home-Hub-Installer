"""Decay / staleness weighting (MEMORY_HYGIENE_SPEC.md 3.3) -- Phase 2.

Pure, deterministic, clock-injected. The exponential form is the one
used everywhere else in the Ostler estate (CM059 ``recency_decay``,
ostler-assistant ``decay.rs``)::

    recency = max(floor, 0.5 ** (age_days / half_life))

with a **domain half-life table**, not one global constant:

- **Evergreen** (Andy's locked no-decay list: name / family / current
  employer / home / dietary-medical): NO decay, weight held at 1.0. The
  list is by construction the same domain vocabulary as the foundational
  rule tier (spec 3.2/3.3) -- one vocabulary, two uses -- PLUS text-level
  matching (foundational attributes + family phrasing) because the real
  writers leave employer/home facts untagged (AUDIT_3 MEDIUM).
- **Preferences / interests:** 540 days (matches CM059).
- **Situational** (plans, travel, "in Tokyo this week"): 30 days, and
  ``validTo`` is honoured as a hard expiry.
- **Default:** 365 days. Floor 0.35 for everything that decays.

Fail-safe positions, all conservative:

- ``authoritative`` facts never decay (weight 1.0) -- the user said so.
- A fact with NO derivable observation time cannot decay (weight 1.0):
  staleness cannot be claimed against a fact whose age is unknown.
- Decay NEVER deletes anything. It lowers ranking weight; crossing into
  archival is decided in ``weight.py`` with its own guards, and archival
  itself is a reversible verdict-overlay tombstone.
- Reinforcement (spec 3.3): a later corroborating mention refreshes the
  decay clock via ``FactRecord.last_corroborated_at``, so a repeatedly-
  mentioned fact never decays out.
"""
from __future__ import annotations

import re
from datetime import datetime, timezone
from typing import Optional

from ostler_hygiene.contradictions_detect import _extract_attribute
from ostler_hygiene.model import (
    FOUNDATIONAL_ATTRIBUTES,
    FOUNDATIONAL_DOMAINS,
    FactRecord,
    HygieneConfig,
    derive_observed_at,
)

# Andy's evergreen no-decay list == the foundational rule-tier domains.
EVERGREEN_DOMAINS = FOUNDATIONAL_DOMAINS

# Domain vocabulary is free-ish text (CM048 emits e.g. "general", CM041
# factDomain is optional); cover the obvious synonyms, anything else
# falls to the default half-life.
PREFERENCE_DOMAINS = frozenset({
    "preference", "preferences", "interest", "interests",
    "hobby", "hobbies", "music", "food", "entertainment",
    "sport", "sports", "reading", "media",
})
SITUATIONAL_DOMAINS = frozenset({
    "situational", "plan", "plans", "travel", "trip",
    "event", "events", "status",
})


def _aware(dt: datetime) -> datetime:
    """Naive timestamps are treated as UTC (same rule as supersede.py)."""
    return dt if dt.tzinfo is not None else dt.replace(tzinfo=timezone.utc)


# AUDIT_3 MEDIUM: the real writers emit factDomain only in {calendar,
# relationship, social} and leave employer/career facts with NO domain at
# all, so a domain-token-only guard misses exactly the facts it exists to
# protect. Evergreen is therefore ALSO matched on what the fact says:
# the detector's foundational attributes (residence/employer/nationality
# via _extract_attribute) and family-relationship phrasing. Bias is
# deliberately toward OVER-protecting -- an evergreen false-positive
# merely skips decay/archival on one fact, an evergreen false-negative
# archives someone's family/employer/home.
_FAMILY_TERMS = re.compile(
    r"\b(?:wife|husband|spouse|partner|fianc[eé]e?|"
    r"son|daughter|child|children|kids?|"
    r"mother|father|mum|mom|dad|parents?|step(?:mother|father|son|daughter)|"
    r"sister|brother|siblings?|twins?|"
    r"grandmother|grandfather|grandma|grandpa|grandparents?|"
    r"aunt|uncle|cousin|niece|nephew|"
    r"married|engaged|divorced|widowed)\b",
    re.IGNORECASE,
)


def is_evergreen(fact: FactRecord) -> bool:
    if (fact.domain or "").strip().lower() in EVERGREEN_DOMAINS:
        return True
    # Untagged (or writer-vocabulary) facts: fall back to the fact text.
    extracted = _extract_attribute(fact.text or "")
    if extracted is not None and extracted[0] in FOUNDATIONAL_ATTRIBUTES:
        return True
    return bool(_FAMILY_TERMS.search(fact.text or ""))


def half_life_days(
    fact: FactRecord, config: Optional[HygieneConfig] = None,
) -> Optional[float]:
    """Half-life for a fact's domain; ``None`` means "does not decay"."""
    config = config or HygieneConfig()
    if fact.authoritative or is_evergreen(fact):
        return None
    domain = (fact.domain or "").strip().lower()
    if domain in SITUATIONAL_DOMAINS:
        return config.situational_half_life_days
    if domain in PREFERENCE_DOMAINS:
        return config.preference_half_life_days
    return config.default_half_life_days


def decay_clock(fact: FactRecord) -> Optional[datetime]:
    """The timestamp decay ages from: best-known observation time,
    refreshed by any later corroboration (spec 3.3 reinforcement).
    ``None`` = no derivable clock, the fact cannot decay."""
    base = derive_observed_at(fact)
    corroborated = fact.last_corroborated_at
    if base is not None and corroborated is not None:
        return max(_aware(base), _aware(corroborated))
    return corroborated or base


def is_expired(fact: FactRecord, now: datetime) -> bool:
    """``validTo`` (or CM048 ``expires_at`` mapped onto it) has passed."""
    if fact.valid_to is None:
        return False
    return _aware(fact.valid_to) < _aware(now)


def recency_weight(
    fact: FactRecord,
    now: datetime,
    config: Optional[HygieneConfig] = None,
) -> float:
    """Staleness weight in [floor, 1.0]; 1.0 = no decay applies."""
    config = config or HygieneConfig()
    half_life = half_life_days(fact, config)
    if half_life is None:
        return 1.0
    clock = decay_clock(fact)
    if clock is None:
        return 1.0  # age unknown -> full weight (fail-safe)
    age_days = (_aware(now) - _aware(clock)).total_seconds() / 86400.0
    if age_days <= 0:
        return 1.0  # clock skew / future-dated: never boost, never decay
    return max(config.recency_floor, 0.5 ** (age_days / half_life))
