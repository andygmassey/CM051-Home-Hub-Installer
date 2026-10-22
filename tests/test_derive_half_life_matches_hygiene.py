#!/usr/bin/env python3
"""Derived preferences fade on the SAME half-life table as memory hygiene (v1.0.118).

  arm 1  constants: the vendored derive recency table equals the vendored
         ostler_hygiene HygieneConfig (540d / 30d / 365d / floor 0.35). One table,
         two owners; this arm is what stops them drifting.
  arm 2  3 recent mentions outrank 3 from four years ago, through the SHIPPED
         registry and the real Aggregator.
  arm 3  a 540d-old item weighs about half a fresh one.
  arm 4  a dietary dislike does not decay; an ordinary dislike does.
  arm 5  the shipped registry overrides news.source to 180d and nothing else.
  arm 6  MUTANTS: a 10-year half-life turns arm 2 red; a drifted constant turns
         arm 1 red.
Synthetic values only. Exit: 0 pass, 1 fail, 2 cannot-run.
"""
from __future__ import annotations

import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TREE = REPO / "vendor" / "cm019_preferences"
sys.path[:0] = [str(TREE / "services" / "common"), str(TREE / "services" / "enrich" / "src"),
                str(REPO / "vendor" / "cm041")]
try:
    import yaml  # noqa: F401
    import recency
    from derive.config import load_dimensions
    from derive.engine import Aggregator
    from derive.model import EvidenceItem
    from ostler_hygiene.model import HygieneConfig
except Exception as exc:  # noqa: BLE001
    print(f"CANNOT-RUN: {type(exc).__name__}: {exc}")
    sys.exit(2)

NOW = datetime(2026, 10, 22, tzinfo=timezone.utc)
PASS = FAIL = 0


def check(cond, msg):
    global PASS, FAIL
    PASS, FAIL = (PASS + 1, FAIL) if cond else (PASS, FAIL + 1)
    print(("  PASS " if cond else "  FAIL ") + msg)


def table_matches_hygiene(mod, hyg):
    return (mod.PREFERENCE_HALF_LIFE_DAYS == hyg.preference_half_life_days
            and mod.SITUATIONAL_HALF_LIFE_DAYS == hyg.situational_half_life_days
            and mod.DEFAULT_HALF_LIFE_DAYS == hyg.default_half_life_days
            and mod.RECENCY_FLOOR == hyg.recency_floor)


def items(dim, ages, strength=0.6):
    return [EvidenceItem(
        preference_id=f"p{i}", user_id="u", domain=dim.split(".")[0], dimension=dim,
        value="x", value_qid=None, item_strength=strength, polarity_source="behavioral",
        source="synthetic", observed_at=NOW - timedelta(days=a),
        enrichment_confidence=0.8, raw_subject="x") for i, a in enumerate(ages)]


AGG = Aggregator(load_dimensions())


def strength(dim, ages, s=0.6):
    out = AGG.aggregate(items(dim, ages, s), now=NOW)
    return out[0].preference_strength if out else None


GENRE = "media.film.genre"

print("arm 1: one table")
hyg = HygieneConfig()
check(table_matches_hygiene(recency, hyg), "derive recency table == HygieneConfig defaults")

print("arm 2: recent outranks old")
rec, old = strength(GENRE, [5, 10, 20]), strength(GENRE, [1460, 1470, 1480])
check(rec is not None and old is not None and rec - old > 0.1, f"3 recent beat 3 old by more than 0.1 (gap {rec - old:.3f})")

print("arm 3: half weight at one half-life")
check(abs(recency.recency_weight(540, 540) - 0.5) < 0.01, "weight at 540d is 0.5")
check(abs(recency.recency_weight(99999, 540) - 0.35) < 1e-9, "floor is 0.35")

print("arm 4: dislikes")
for dim in ("food.diet", "food.ingredient", "health.medical"):
    check(strength(dim, [0, 1, 2], -0.8) == strength(dim, [2000, 2001, 2002], -0.8), f"{dim} dislike does not decay")
a, b = strength("food.cuisine", [0, 1, 2], -0.8), strength("food.cuisine", [2000, 2001, 2002], -0.8)
check(a < b < 0, "an ordinary dislike fades toward zero without flipping sign")

print("arm 5: shipped overrides")
over = {d.dimension: d.half_life_days for d in load_dimensions() if d.half_life_days}
check(over == {"news.source": 180.0}, "only news.source is overridden, at 180d")

print("arm 6: mutants")
real = (recency.PREFERENCE_HALF_LIFE_DAYS, recency.RECENCY_FLOOR)
recency.PREFERENCE_HALF_LIFE_DAYS, recency.RECENCY_FLOOR = 3650.0, 0.4
try:
    rec_m, old_m = strength(GENRE, [5, 10, 20]), strength(GENRE, [1460, 1470, 1480])
    check(rec_m - old_m < 0.1, "10-year half-life collapses the recent/old gap (arm 2 would be red)")
    check(not table_matches_hygiene(recency, hyg), "a drifted table is caught by arm 1")
finally:
    recency.PREFERENCE_HALF_LIFE_DAYS, recency.RECENCY_FLOOR = real

print(f"\n{PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
