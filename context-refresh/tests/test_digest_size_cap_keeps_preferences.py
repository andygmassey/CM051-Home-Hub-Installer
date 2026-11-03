"""walk 121: derived_preferences_reach_digest_and_tool and owner_digest's
Preferences arm FAILed on a box whose derive job HAD written 251 nodes: the
digest ran over the 6000-char cap and the cap drops the LAST-listed blocks
first. "Preferences and things to keep in mind" (home of the derived "What you
like" lines, 3dd087ff) was listed after the 1.7k Calendar block, so it was
dropped whole. Preferences must outlive Calendar, Recent meetings and Channel
style; counts-only Channel style goes first. Synthetic only."""
from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest

_SCRIPT = Path(__file__).resolve().parent.parent / "bin" / "generate_pwg_context.py"
LIKES = "- What you like (derived from your history): " + "; ".join("thing%d" % i for i in range(8))


def _gen():
    spec = importlib.util.spec_from_file_location("generate_pwg_context", _SCRIPT)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


@pytest.fixture()
def over_cap(monkeypatch, tmp_path):
    for k in ("USER_ID", "USER_NAME", "USER_EMAIL", "WIKI_OPERATOR_NAME", "WIKI_OPERATOR_EMAILS"):
        monkeypatch.delenv(k, raising=False)
    monkeypatch.setenv("OSTLER_DIR", str(tmp_path / "none"))
    g = _gen()
    pad = lambda tag, n: ["- %s %s" % (tag, "x" * 90)] * n  # noqa: E731
    stubs = {
        "_about_you_section": ["- Name: Jane Doe"],
        "_autonomy_section": pad("auto", 4),
        "_user_asserted_section": [],
        "_routines_priorities_section": pad("routine", 3),
        "_people_section": pad("person", 3),
        "_tastes_section": pad("taste", 2),
        "_channel_style_section": pad("channel", 3),
        "_meetings_section": pad("meeting", 3),
        "_calendar_by_owner_section": pad("cal", 22),
        "_preferences_section": [LIKES],
        "_orgs_section": pad("org", 2),
    }
    for name, lines in stubs.items():
        monkeypatch.setattr(g, name, lambda lines=lines: list(lines))
    g.MAX_CHARS = 6000
    return g


def test_the_digest_is_really_over_the_cap_without_dropping(over_cap):
    g = over_cap
    g.MAX_CHARS = 10 ** 6
    assert len(g.build_digest()) > 6000


def test_preferences_survive_the_cap_and_channel_style_goes_first(over_cap):
    d = over_cap.build_digest()
    assert len(d) <= 6000
    assert "What you like (derived from your history)" in d
    assert "## Preferences and things to keep in mind" in d
    assert "## Channel style" not in d
    assert "Left out to fit the size cap" in d
