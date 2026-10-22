"""Recency weighting for derived preferences (PWG), one table, one formula.

The constants below are the SAME numbers as the Ostler memory-hygiene decay
table (CM041 ``ostler_hygiene/model.py`` HygieneConfig, MEMORY_HYGIENE_SPEC
3.3): preferences 540d, situational 30d, default 365d, floor 0.35. CM019 cannot
import CM041, so this module is the single definition on the CM019 side and the
CM051 test ``tests/test_derive_half_life_matches_hygiene.py`` fails if the two
ever drift. Do not copy these numbers anywhere else; import them.

Formula (identical to ostler_hygiene.decay.recency_weight):

    weight = max(floor, 0.5 ** (age_days / half_life))

Evergreen dimensions (dietary / medical) never decay: weight is 1.0 for a like
AND a dislike. An item with no observation time cannot be called stale: 1.0.
Decay only lowers weight, it never deletes evidence.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Optional

PREFERENCE_HALF_LIFE_DAYS = 540.0
SITUATIONAL_HALF_LIFE_DAYS = 30.0
DEFAULT_HALF_LIFE_DAYS = 365.0
# 0.35, not the V2 ingest 0.4: this is the hygiene floor, so a derived node and
# a hygiene-weighted fact about the same thing fade to the same minimum.
RECENCY_FLOOR = 0.35

# Dimensions (exact or dotted prefix) whose evidence never decays. Mirrors the
# hygiene evergreen list "dietary/medical". Matched by prefix so a dimension
# added later (food.ingredient.*, health.allergy) is safe by default.
EVERGREEN_DIMENSION_PREFIXES = (
    "food.ingredient",
    "food.diet",
    "food.allergy",
    "health.dietary",
    "health.diet",
    "health.medical",
    "health.allergy",
    "health.condition",
)


def is_evergreen_dimension(dimension: str) -> bool:
    d = (dimension or "").lower()
    return any(d == p or d.startswith(p + ".") for p in EVERGREEN_DIMENSION_PREFIXES)


def resolve_half_life(
    dimension: str, override: Optional[float] = None, evergreen: bool = False
) -> Optional[float]:
    """Half-life in days for a dimension; ``None`` means it never decays.

    Order: evergreen (flag or dietary/medical prefix) beats everything, then a
    per-dimension override from dimensions.yaml, then the 540d preference default.
    """
    if evergreen or is_evergreen_dimension(dimension):
        return None
    if override is not None and override > 0:
        return float(override)
    return PREFERENCE_HALF_LIFE_DAYS


def recency_weight(age_days: float, half_life_days: Optional[float]) -> float:
    """Weight in [RECENCY_FLOOR, 1.0]; 1.0 when it does not decay."""
    if half_life_days is None or age_days <= 0:
        return 1.0
    return max(RECENCY_FLOOR, 0.5 ** (age_days / half_life_days))


def age_days(observed_at: Optional[datetime], now: datetime) -> float:
    """Fractional days from observed_at to now; 0 when unknown or in the future."""
    if observed_at is None:
        return 0.0
    if observed_at.tzinfo is None:
        observed_at = observed_at.replace(tzinfo=timezone.utc)
    return max((now - observed_at).total_seconds() / 86400.0, 0.0)
