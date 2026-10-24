"""Scoring for derived nodes (Chunk 2).

Strength reuses the Chunk-0 shared math (services/common/strength.py) so a
derived node is scored by the exact tuned curve ingest uses. Confidence is a
separate, published evidence-trust axis (NOT lean), per design section 1.4.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import List, Sequence

from strength import calculate_strength

from .model import EvidenceItem

# Confidence / intensity tuning. In config (dimensions.yaml) long term; here as
# named defaults so a test can reference them.
COUNT_SAT = 8
CONF_CONSUME_MIN = 0.35
PASSION_COUNT = 5
PASSION_RECENT_DAYS = 540
STRONG_STRENGTH = 0.45
PASSION_STRENGTH = 0.70
CONTRA_MIN = 0.25


@dataclass(frozen=True)
class GroupScore:
    strength: float
    confidence: float
    intensity_tier: str
    evidence_count: int
    source_count: int
    contestedness: float
    is_contested: bool
    like_count: int
    dislike_count: int
    first_observed_at: datetime | None
    last_observed_at: datetime | None


def _as_aware(dt: datetime | None) -> datetime | None:
    """Coerce a naive datetime to UTC so aware/naive values never mix."""
    if dt is not None and dt.tzinfo is None:
        return dt.replace(tzinfo=timezone.utc)
    return dt


def _days_since(dt: datetime | None, now: datetime) -> int:
    if dt is None:
        return 0
    dt = _as_aware(dt)
    delta = (now - dt).days
    return max(delta, 0)


def contestedness(items: Sequence[EvidenceItem]) -> float:
    """Minority polarity share in [0, 1]. 0 when all evidence agrees."""
    likes = sum(1 for i in items if i.item_strength >= 0)
    dislikes = len(items) - likes
    total = likes + dislikes
    if total == 0:
        return 0.0
    return min(likes, dislikes) / total


def score_group(items: Sequence[EvidenceItem], now: datetime | None = None) -> GroupScore:
    """Score one (dimension, value) group of evidence into a derived node's axes."""
    now = now or datetime.now(timezone.utc)
    assert items, "cannot score an empty evidence group"

    count = len(items)
    likes = sum(1 for i in items if i.item_strength >= 0)
    dislikes = count - likes

    # base_strength: evidence mean (NOT max) so one binge cannot dominate; sign
    # preserved so dislikes roll into a negative derived strength.
    base_strength = sum(i.item_strength for i in items) / count

    sources = {i.source for i in items if i.source}
    source_count = max(len(sources), 1)

    observeds = [_as_aware(i.observed_at) for i in items if i.observed_at is not None]
    first_obs = min(observeds) if observeds else None
    last_obs = max(observeds) if observeds else None
    days_since_last = _days_since(last_obs, now)

    strength = calculate_strength(
        frequency=count,
        base_strength=base_strength,
        days_since_last=days_since_last,
        source_count=source_count,
    )

    c = contestedness(items)
    count_c = min(1.0, math.log1p(count) / math.log1p(COUNT_SAT))
    diversity_c = min(1.0, source_count / 3)
    quality_c = sum(i.enrichment_confidence for i in items) / count
    confidence = (0.5 * count_c + 0.2 * diversity_c + 0.3 * quality_c) * (1 - 0.5 * c)

    is_contested = (
        likes > 0 and dislikes > 0 and min(likes, dislikes) / count > CONTRA_MIN
    )

    strong = abs(strength) >= STRONG_STRENGTH
    recent = days_since_last <= PASSION_RECENT_DAYS
    if abs(strength) >= PASSION_STRENGTH and count >= PASSION_COUNT and recent:
        tier = "passion"
    elif strong:
        tier = "strong"
    else:
        tier = "casual"

    return GroupScore(
        strength=strength,
        confidence=confidence,
        intensity_tier=tier,
        evidence_count=count,
        source_count=source_count,
        contestedness=c,
        is_contested=is_contested,
        like_count=likes,
        dislike_count=dislikes,
        first_observed_at=first_obs,
        last_observed_at=last_obs,
    )
