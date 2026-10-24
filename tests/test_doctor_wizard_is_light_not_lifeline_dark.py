"""The first-run wizard must not paint Lifeline grounds (HR015 #979, vendored graft).

The vendored wizard (vendor/doctor/agent/first_run.py) already had light cards
and dark text (#14120e) but kept `--bg: #0d0b08` as the page ground, so the page
was dark text on a near-black ground, plus a near-black code box and a
near-black "blocked" status. HR015 #979 swept those; this pins the rendered
wizard bytes, not the source, and pins the named STATUS_COLOUR mapping.

NOT a blanket port of upstream's gate: that gate lists #ece8dd as forbidden, but
in this tree #ece8dd is a LIGHT ground token (--ostler-chassis), so applying
upstream's colour sweep here inverts the token roles (measured: the
test_the_doctor_page_is_on_brand gate goes 9 pass -> 2 fail). Only literals that
are dark grounds in THIS tree's roles are listed.
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "vendor" / "doctor" / "agent"))

import first_run  # noqa: E402
import status_collector as sc  # noqa: E402

SIX = re.compile(r"(?<![&\w])#([0-9a-fA-F]{6})\b")
DARK_GROUNDS = {"#0d0b08", "#0a0908", "#07060a", "#1a1612", "#221c16", "#4a4540"}
BANNED_REDS = {"#c84545", "#d76060", "#e26a6a", "#d96666", "#ef4444"}


def _page():
    snap = sc.SystemSnapshot()
    return first_run.render_wizard(snap, first_run.get_wizard_steps(snap))


def _colours(html):
    return {"#" + m.group(1).lower() for m in SIX.finditer(html)}


def test_control_page_was_read_and_has_colour():
    html = _page()
    assert len(html) > 2000
    assert _colours(html), "page carries no colour; the absence checks below would be vacuous"
    assert "--bg:" in html and "--text-primary:" in html


def test_no_lifeline_ground_or_banned_red_in_the_wizard():
    found = _colours(_page()) & (DARK_GROUNDS | BANNED_REDS)
    assert not found, sorted(found)


def test_page_ground_is_lighter_than_the_text_on_it():
    html = _page()
    bg = re.search(r"--bg:\s*#([0-9a-fA-F]{6})", html).group(1)
    fg = re.search(r"--text-primary:\s*#([0-9a-fA-F]{6})", html).group(1)

    def lum(h):
        r, g, b = (int(h[i:i + 2], 16) for i in (0, 2, 4))
        return 0.2126 * r + 0.7152 * g + 0.0722 * b

    assert lum(bg) > lum(fg) + 100, (bg, fg)


def test_status_colours_are_a_named_mapping_and_what_renders():
    assert set(first_run.STATUS_COLOUR) == {"complete", "partial", "needed", "blocked"}
    html = _page()
    snap = sc.SystemSnapshot()
    used = {s["status"] for s in first_run.get_wizard_steps(snap)}
    assert used, "no wizard steps to check"
    for status in used:
        assert first_run.STATUS_COLOUR[status] in html, status
