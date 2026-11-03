"""walk 121 / Archie on #3279: over the 6000-char cap the digest trims whole
LINES, never a whole block while it can shrink. Calendar loses past events
first (oldest first), then the furthest-future ones; Preferences and Tastes
keep at least one line; no partial line; total <= 6000. Synthetic only."""
from __future__ import annotations

import importlib.util
from datetime import datetime, timezone
from pathlib import Path

import pytest

_SCRIPT = Path(__file__).resolve().parent.parent / "bin" / "generate_pwg_context.py"


def _gen():
    spec = importlib.util.spec_from_file_location("generate_pwg_context", _SCRIPT)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def _cal(g, owner="Jane Doe", past=3, future=3):
    """Calendar lines + dates, relative to now so the test never goes stale."""
    now = datetime.now(timezone.utc)
    lines = [f"**{owner}:**"]
    for k in range(-past, future + 1):
        if k == 0:
            continue
        ts = now.replace(year=now.year + (1 if k > 0 else -1) * 0) 
        day = (now.toordinal() + k * 3)
        when = datetime.fromordinal(day).strftime("%Y-%m-%d") + " 09:00"
        ln = f"- event{k:+d} {'x' * 100} ({when})"
        lines.append(ln)
        g._CALENDAR_WHEN[(owner, ln)] = when
    return lines


@pytest.fixture()
def gen(monkeypatch, tmp_path):
    for k in ("USER_ID", "USER_NAME", "USER_EMAIL", "WIKI_OPERATOR_NAME", "WIKI_OPERATOR_EMAILS"):
        monkeypatch.delenv(k, raising=False)
    monkeypatch.setenv("OSTLER_DIR", str(tmp_path / "none"))
    g = _gen()
    g.MAX_CHARS = 6000
    return g


def _stub(g, monkeypatch, cal_lines, prefs, tastes):
    pad = lambda tag, n: ["- %s %s" % (tag, "x" * 120)] * n  # noqa: E731
    stubs = {
        "_about_you_section": ["- Name: Jane Doe"],
        "_autonomy_section": pad("auto", 6),
        "_user_asserted_section": pad("asserted", 6),
        "_routines_priorities_section": pad("routine", 6),
        "_people_section": pad("person", 6),
        "_tastes_section": tastes,
        "_channel_style_section": pad("channel", 4),
        "_meetings_section": pad("meeting", 5),
        "_calendar_by_owner_section": cal_lines,
        "_preferences_section": prefs,
        "_orgs_section": pad("org", 6),
    }
    for name, lines in stubs.items():
        monkeypatch.setattr(g, name, lambda lines=lines: list(lines))


def _build(gen, monkeypatch, **kw):
    cal = _cal(gen, **{k: v for k, v in kw.items() if k in ("past", "future")})
    prefs = ["- What you like (derived from your history): a; b; c"] + ["- pref %s" % ("p" * 100)] * 7
    tastes = ["- taste %s" % ("t" * 100)] * 6
    _stub(gen, monkeypatch, cal, prefs, tastes)
    built = {}
    orig = gen._reset_measurements

    def keep():  # build_digest resets the ledger; re-seed dates after it
        orig()
        gen._CALENDAR_WHEN.update(built)
    built.update(gen._CALENDAR_WHEN)
    monkeypatch.setattr(gen, "_reset_measurements", keep)
    return gen.build_digest()


def test_over_cap_keeps_calendar_preferences_and_tastes_lines(gen, monkeypatch):
    gen.MAX_CHARS = 10 ** 6
    assert len(_build(gen, monkeypatch)) > 6000, "fixture must be over the cap"
    gen.MAX_CHARS = 6000
    d = _build(gen, monkeypatch)
    assert len(d) <= 6000
    assert "## Calendar events by owner" in d and "- event+1 " in d
    assert "## Preferences and things to keep in mind" in d and "What you like" in d
    assert "## Tastes" in d and "- taste " in d
    assert "Shortened to fit the size cap" in d


def test_no_partial_line(gen, monkeypatch):
    d = _build(gen, monkeypatch)
    for ln in d.splitlines():
        if ln.startswith("- event") or ln.startswith("- pref ") or ln.startswith("- taste "):
            assert ln.rstrip().endswith((")", "p", "t")) and ("x" * 100 in ln or "p" * 100 in ln or "t" * 100 in ln)


def test_calendar_trim_order_past_before_future(gen):
    now = datetime.now(timezone.utc)
    fmt = lambda k: datetime.fromordinal(now.toordinal() + k).strftime("%Y-%m-%d") + " 09:00"  # noqa: E731
    lines = ["**Jane Doe:**"]
    for tag, k in (("far-future", 30), ("near-future", 2), ("old-past", -20), ("recent-past", -1)):
        ln = f"- {tag}"
        lines.append(ln)
        gen._CALENDAR_WHEN[("Jane Doe", ln)] = fmt(k)
    seq = []
    cur = lines
    while any(not x.startswith("**") for x in cur):
        nxt = gen._trim_calendar_one(cur)
        gone = [x for x in cur if x not in nxt and not x.startswith("**")]
        seq += gone
        cur = nxt
    assert seq == ["- old-past", "- recent-past", "- far-future", "- near-future"]
    assert cur == [], "owner header must go with its last event"
