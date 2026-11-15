"""Shared preference-strength math (PWG).

Chunk 0 of the preference-intelligence layer: this is a byte-identical lift of
``PreferenceFilter._calculate_strength`` (``services/ingest/src/filters.py``) so
both the ingest path and the post-ingest derivation engine score strength with
one, tuned implementation. The function is pure: its output depends only on its
arguments. ``PreferenceFilter._calculate_strength`` now delegates here.

Model: Hu-Koren-Volinsky confidence scaling on a bipolar -1..1 scale.
- Frequency boost: logarithmic, caps at 3x.
- Time decay: 10-year half-life, floored at 0.4 (preferences are VERY stable).
- Cross-source reinforcement: caps at 1.6x.
- Sigmoid ceiling: soft cap approaching +/-0.95.

Do NOT retune here. Any change to the constants is a behaviour change to ingest
and must be made deliberately, with the golden test regenerated on purpose.
"""

import math

# Tuning constants. Named so the golden/mutation tests can reference them and a
# perturbation (e.g. the half-life) turns the characterization test red.
HALF_LIFE_DAYS = 3650  # 10 years - core preferences are remarkably stable
DECAY_FLOOR = 0.4      # never below 40% - old preferences still matter
FREQ_MULT_CAP = 3.0
SOURCE_BOOST_CAP = 1.6
SIGMOID_K = 0.5
STRENGTH_CEILING = 0.95


def calculate_strength(
    frequency: int,
    base_strength: float = 0.5,
    days_since_last: int = 0,
    source_count: int = 1,
) -> float:
    """Calculate preference strength using the V2 model.

    Args:
        frequency: Number of times this preference was observed.
        base_strength: Base strength from parser (-1.0 to +1.0).
        days_since_last: Days since most recent observation.
        source_count: Number of independent sources confirming this preference.

    Returns:
        Adjusted strength between -0.95 and +0.95.
    """
    # Preserve sign, work with magnitude
    sign = 1 if base_strength >= 0 else -1
    magnitude = abs(base_strength)

    # Step 1: Frequency multiplier (logarithmic, caps at 3x)
    if frequency <= 1:
        freq_mult = 1.0
    else:
        freq_mult = min(1.0 + math.log1p(frequency - 1) * 0.5, FREQ_MULT_CAP)

    # Step 2: Time decay (configurable half-life, default 10 years)
    half_life_days = HALF_LIFE_DAYS
    decay_floor = DECAY_FLOOR
    if days_since_last > 0:
        decay = max(math.exp(-0.693 * days_since_last / half_life_days), decay_floor)
    else:
        decay = 1.0  # Recent or no date info

    # Step 3: Cross-source boost (caps at 1.6x)
    if source_count > 1:
        source_boost = min(1.0 + math.log1p(source_count - 1) * 0.3, SOURCE_BOOST_CAP)
    else:
        source_boost = 1.0

    # Step 4: Combine factors
    raw_magnitude = magnitude * freq_mult * decay * source_boost

    # Step 5: Sigmoid ceiling (maps to 0-0.95 range)
    final_magnitude = min(raw_magnitude / (raw_magnitude + SIGMOID_K), STRENGTH_CEILING)

    return sign * final_magnitude
