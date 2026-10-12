"""Shape sweep (2026-10-12): every bad customer-text shape in ONE synthetic
fixture, rendered offline through the real CM059 Front Page compiler, the real
cm048 enrichment sanitiser, then read by CM051's own customer-read judge.

Shapes: raw @handle, +1 555-01xx number, example.invalid email, "(user)" and
"(other_name)" tags, ISO timestamps, snake_case keys, "{other_name}".
Synthetic data only. Exit via pytest.
"""
from __future__ import annotations

import html
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "vendor" / "cm059_editor"))
sys.path.insert(0, str(ROOT / "vendor" / "cm048_pipeline"))
sys.path.insert(0, str(ROOT / "scripts" / "box_walk_probes" / "lib"))

from compiler import frontpage as fp, render_frontpage, signals  # noqa: E402
from src import enrichment_validation as ev  # noqa: E402
import customer_read  # noqa: E402

NOW = datetime(2026, 10, 12, tzinfo=timezone.utc)
PHONE = "+1 555 0100 222"
EMAIL = "jane@example.invalid"
HANDLE = "@jdoe84"
LEAKS = [
    ("handle", re.compile(r"(?<![\w.])@[A-Za-z0-9_.]*\d[A-Za-z0-9_.]*")),
    ("phone", re.compile(r"\+\d[\d  ]{6,}\d")),
    ("email", re.compile(r"[^\s@]+@[^\s@]+\.[A-Za-z]{2,}")),
    ("role tag", re.compile(r"\((?:user|other|other_name|user_name|other:[\w-]+)\)")),
    ("placeholder", re.compile(r"\{[a-z][a-z0-9_]*\}")),
    ("iso", re.compile(r"20\d\d-[01]\d-[0-3]\d")),
    ("snake_case", re.compile(r"(?<![@\w.])[a-z]+_[a-z]+(?:_[a-z]+)*\b")),
]


def _interest(i, subject, cat="x", ev_=None):
    return {"id": "i%d" % i, "subject": subject, "domain": "film_tv", "category": cat,
            "score": 0.9, "polarity": "like", "strength": 0.9, "privacy": "L1",
            "sources": ["s"], "evidence": ev_ or ["from synthetic"]}


def _shapes(text):
    return [n for n, rx in LEAKS if rx.search(text)]


def _card_text(c):
    return " | ".join(str(c.get(k) or "") for k in ("title", "body", "evidence"))


def _fixture_cards():
    prof = {"domains": [{"domain": "film_tv", "interests": [
        _interest(1, "some_account", "instagram_creator"),
        _interest(2, "deep_sea_diving", "hobby"),
        _interest(3, PHONE),
        _interest(4, "Updated 2026-09-30T08:15:00Z"),
        _interest(5, "{other_name} films"),
        _interest(6, EMAIL),
        _interest(7, "Normal topic", ev_=["Seen 2026-09-30T08:15:00Z with Jo (user) and {other_name}"]),
    ]}], "stats": {"interests": 7}}
    cards = list(fp.build_frontpage(prof, now=NOW)["cards"])
    cards.append(signals.reply_debt_card(3, [HANDLE, PHONE, EMAIL], NOW))
    for n in (HANDLE, PHONE, "{other_name}", "other_name (user)"):
        cards.append(signals.gone_quiet_card(n, 5, NOW))
        cards.append(signals.birthday_card(n, 3, NOW))
    cards.append(signals.birthday_card(EMAIL, 3, NOW))
    cards.append(signals.gone_quiet_card(EMAIL, 5, NOW))
    for who in (PHONE, EMAIL, HANDLE):
        cards.append(signals.commitment_card("x", 2, who, NOW))
    return [c for c in cards if c]


# ---- per-card tests, each bad input ---------------------------------------

def test_reply_debt_names_never_raw():
    c = signals.reply_debt_card(3, [HANDLE, PHONE, EMAIL], NOW)
    assert _shapes(_card_text(c)) == [], _card_text(c)


def test_gone_quiet_and_birthday_suppress_unshowable_names():
    for bad in (HANDLE, PHONE, EMAIL, "{other_name}"):
        assert signals.gone_quiet_card(bad, 5, NOW) is None, bad
        assert signals.birthday_card(bad, 3, NOW) is None, bad


def test_role_tag_is_stripped_from_a_name_not_the_card_lost():
    c = signals.birthday_card("Jo Doe (user)", 3, NOW)
    assert "Jo Doe" in c["title"] and "(user)" not in c["title"]


def test_commitment_who_never_raw():
    for who in (PHONE, EMAIL, HANDLE):
        c = signals.commitment_card("x", 2, who, NOW)
        assert _shapes(_card_text(c)) == [], _card_text(c)


def test_real_names_survive():
    assert fp.person_label("Jane Doe") == "Jane Doe"
    assert fp.person_label("Jean-Luc O'Brien") == "Jean-Luc O'Brien"
    assert "Jane Doe" in signals.gone_quiet_card("Jane Doe", 5, NOW)["title"]


def test_handle_shown_only_for_creator_interests():
    assert fp.display_subject({"subject": "some_account", "category": "instagram_creator"}) == "@some_account"
    assert fp.display_subject({"subject": "deep_sea_diving", "category": "hobby"}) == "Deep sea diving"


def test_evidence_line_iso_becomes_human_date():
    s = fp.clean_card_text("Seen 2026-09-30T08:15:00Z with Jo (user) {other_name}")
    assert s == "Seen 30 Sep 2026 with Jo", s


# ---- cm048 enrichment body ------------------------------------------------

PARTS = [{"id": "owner", "display": "Jane", "role": "user"},
         {"id": PHONE, "display": PHONE, "role": "other"}]
BODY = ("## Summary\nJane (user) met {other_name} " + PHONE + " (other_name).\n\n"
        "### Participants\n- Jane (user)\n- " + PHONE + " (other_name)\n\n"
        "### Key points\n- Call the plumber on +44 7700 900123 about ref AB-1234 (urgent)\n")


def test_body_scaffolding_scrubbed_and_real_content_kept():
    out = ev.sanitise_participants_section(BODY, PARTS, "Jane")
    assert "(user)" not in out and "(other_name)" not in out
    assert PHONE not in out
    assert "+44 7700 900123" in out and "AB-1234" in out and "(urgent)" in out


def test_resolved_participant_handle_becomes_their_name():
    parts = [{"id": PHONE, "display": "Sam Poe", "role": "other"}]
    out = ev.scrub_scaffolding("Texted " + PHONE + " today", parts)
    assert out == "Texted Sam Poe today", out


# ---- offline render + CM051's own judge -----------------------------------

def _text_of(html_doc):
    t = re.sub(r"<(style|script)\b.*?</\1>", " ", html_doc, flags=re.S | re.I)
    t = re.sub(r"</(div|p|h\d|li|section|article)>", "\n", t)
    return html.unescape(re.sub(r"<[^>]+>", " ", t))


def test_rendered_front_page_has_no_leak_shape_and_judge_holds():
    cards = _fixture_cards()
    feed = {"cards": cards, "generated_utc": "2026-10-12T00:00:00Z"}
    text = _text_of(render_frontpage.render(feed))
    assert len(cards) >= 6
    assert _shapes(text) == [], "leak shapes in the rendered Front Page: %s" % _shapes(text)
    base = {n for n, ok, _ in customer_read.judge(customer_read._good()) if ok is False}
    f = customer_read._good()
    f["screens"]["home"]["text"] += "\n" + text
    f["wiki"]["pages"]["front"]["text"] += "\n" + text
    new = {n for n, ok, d in customer_read.judge(f) if ok is False} - base
    assert not new, "customer_read judge fails on the rendered fixture: %s" % sorted(new)
