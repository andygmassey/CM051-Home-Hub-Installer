#!/usr/bin/env python3
"""The "A hunch" card must not offer a paragraph as an interest.

Ostler #30 console walk: the card showed a long LinkedIn recommendation as an
interest. The interest profile had already flagged it too_long (and sunk its
confidence), but exploration_pick ranked on score alone and ignored the flag,
so a lone sub-threshold entry was still the "strongest liked interest left".

Synthetic data only.
"""
from __future__ import annotations

import sys
from datetime import datetime, timezone
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "vendor" / "cm059_editor"))

from compiler import frontpage  # noqa: E402

NOW = datetime(2026, 10, 15, tzinfo=timezone.utc)
PARAGRAPH = ("Marta is a wonderful colleague who plays piano and listens to jazz every day "
             "with great dedication to the craft over many years")


def _it(i, subject, domain, score, flags=()):
    return {"id": i, "subject": subject, "domain": domain, "score": score,
            "polarity": "like", "flags": list(flags)}


def _profile(*items):
    doms = {}
    for it in items:
        doms.setdefault(it["domain"], []).append(it)
    return {"domains": [{"domain": d, "interests": v} for d, v in doms.items()]}


@pytest.mark.parametrize("flag", ["too_long", "too_short", "empty", "url_only"])
def test_exploration_pick_skips_flagged_entries(flag):
    top = _it("a", "Fixture Jazz", "Music", 0.9)
    bad = _it("b", PARAGRAPH, "Reading", 0.5, [flag])
    assert frontpage.exploration_pick(_profile(top, bad), [top]) is None


def test_exploration_pick_prefers_the_clean_entry_over_a_higher_scoring_flagged_one():
    top = _it("a", "Fixture Jazz", "Music", 0.9)
    bad = _it("b", PARAGRAPH, "Reading", 0.8, ["too_long"])
    ok = _it("c", "Fixture Sailing", "Sport", 0.2)
    assert frontpage.exploration_pick(_profile(top, bad, ok), [top])["id"] == "c"


def test_control_an_unflagged_entry_is_still_picked():
    top = _it("a", "Fixture Jazz", "Music", 0.9)
    ok = _it("c", "Fixture Sailing", "Sport", 0.2)
    assert frontpage.exploration_pick(_profile(top, ok), [top])["id"] == "c"


def test_rotation_bench_skips_flagged_entries_too():
    top = _it("a", "Fixture Jazz", "Music", 0.9)
    bad = _it("b", PARAGRAPH, "Reading", 0.5, ["too_long"])
    out = frontpage._rotation_picks(_profile(top, bad), [top], NOW, 2)
    assert all(it["id"] != "b" for it in out)
