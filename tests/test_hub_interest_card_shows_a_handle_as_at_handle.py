"""DMG #22: the Hub home "Is this you?" interest card showed a raw Instagram
handle ("Private / some_account") as its label, which the customer-read judge
rightly fails as an internal snake_case key. A handle-kind interest (the
Instagram parser keeps the bare username, category instagram_creator) must be
labelled "@handle" in the SHIPPED vendor/cm059_editor copy, and the judge must
accept an @-prefixed handle and still flag every other snake_case token.
Synthetic data only. Exit 0 pass, 1 fail, 2 CANNOT-RUN.
"""
from __future__ import annotations

import pathlib
import sys
from datetime import datetime, timezone

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "vendor" / "cm059_editor"))
sys.path.insert(0, str(ROOT / "scripts" / "box_walk_probes" / "lib"))
try:
    from compiler import frontpage as fp
    from compiler import render_frontpage as rf
    import customer_read as cr
except Exception as exc:  # noqa: BLE001
    print(f"CANNOT-RUN: import failed: {exc!r}")
    sys.exit(2)

NOW = datetime(2026, 10, 1, 7, 0, tzinfo=timezone.utc)
FAILS = []


def check(label, ok):
    print(("  ok    " if ok else "  FAIL  ") + label)
    if not ok:
        FAILS.append(label)


def interest(subject, category):
    return {"id": "int_000000000001", "subject": subject, "category": category, "domain": "media",
            "polarity": "like", "privacy": "L1", "score": 0.9, "evidence": ["seen recently"]}


def page_for(it):
    card = fp.interest_card(it, NOW, 0, 1)
    feed = {"schema_version": "0.2", "generated_utc": fp._iso(NOW), "phase": "steady",
            "card_count": 1, "cards": [card], "stats": {}}
    return card, rf.render(feed)


card, html_out = page_for(interest("some_account", "instagram_creator"))
check("handle interest: card title is @some_account", card["title"] == "@some_account")
check("handle interest: rendered label is >@some_account<", ">@some_account<" in html_out and ">some_account<" not in html_out)
check("an already-@ handle is not double-prefixed", fp.interest_card(interest("@ann_lee", "instagram_creator"), NOW, 0, 1)["title"] == "@ann_lee")
check("a non-handle interest is unchanged", fp.interest_card(interest("Jazz", "music_genre"), NOW, 0, 1)["title"] == "Jazz")
check("exploration card also shows @handle", fp.exploration_card(interest("some_account", "instagram_creator"), NOW)["title"] == "@some_account")


def flags(text):
    return [name for rx, name in cr.JARGON if rx.search(text)]


check("judge accepts @some_account", "snake_case key" not in flags("Private\n@some_account\nIs this you?"))
check("judge accepts @ann_lee_99", "snake_case key" not in flags("@ann_lee_99"))
check("judge still flags the raw some_account", "snake_case key" in flags("Private\nsome_account\nIs this you?"))
check("judge still flags tv_show beside an @handle", "snake_case key" in flags("@ann_lee likes tv_show"))
check("judge still flags a multi-part key", "snake_case key" in flags("music_genre_name"))

print("FAIL" if FAILS else "PASS")
sys.exit(1 if FAILS else 0)
