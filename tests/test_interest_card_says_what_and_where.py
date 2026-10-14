"""Front page: every interest card read "One of the things Ostler reckons
you're into." (vendor/cm059_editor/compiler/frontpage.py interest_card). The
body must say where the interest came from, built from the card's own
`sources` and `last_seen`, so twelve cards no longer repeat one sentence.
Shapes measured on macmini16-walk 2026-10-14 (counts only): sources are
platform keys (apple 2566, twitter 209, linkedin 77, spotify 70, apple_tv 45,
whatsapp 31, ...), categories music/interest/professional/education/movie,
last_seen an ISO date. Synthetic data only. Exit 0 pass, 1 fail, 2 CANNOT-RUN.
"""
from __future__ import annotations

import pathlib
import sys
from datetime import datetime, timezone

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "vendor" / "cm059_editor"))
try:
    from compiler import frontpage as fp
except Exception as exc:  # noqa: BLE001
    print(f"CANNOT-RUN: could not import the vendored compiler: {exc!r}")
    sys.exit(2)

NOW = datetime(2026, 10, 14, 7, 0, tzinfo=timezone.utc)
FAILS = []


def card(**kw):
    it = {"id": "i-" + kw.get("subject", "x"), "subject": "Sea kayaking", "domain": "hobbies",
          "polarity": "like", "privacy": "L1", "score": 1.0, "category": "interest",
          "sources": ["twitter"], "last_seen": "2026-09-30", "evidence": []}
    it.update(kw)
    return fp.interest_card(it, NOW, 0, 1)["body"]


def check(name, got, want_in=(), want_not=()):
    bad = [w for w in want_in if w not in got] + [w for w in want_not if w in got]
    print(("  ok   " if not bad else "  FAIL ") + f"{name}: {got!r}")
    if bad:
        FAILS.append(name)


GENERIC = "reckons you're into"
check("a followed account names where", card(category="interest", sources=["twitter"]),
      ["Followed on X"], [GENERIC])
check("music names the service", card(subject="Jazz piano", category="music", sources=["spotify"]),
      ["Spotify"], [GENERIC])
check("a LinkedIn item says it is on the profile", card(category="professional", sources=["linkedin"]),
      ["On your LinkedIn profile"], [GENERIC])
check("an older last_seen gives the year", card(sources=["twitter"], last_seen="2019-05-02"),
      ["2019"], [GENERIC])
check("this year's last_seen adds no date", card(sources=["twitter"], last_seen="2026-09-30"),
      [], ["2026", GENERIC])
check("two sources are both named", card(category="music", sources=["apple", "spotify"]),
      ["Apple Music", "Spotify"], [GENERIC])
check("something the owner said", card(sources=["you"]), ["You told Ostler"], [GENERIC])
check("no source still says something specific", card(sources=[]), [], [GENERIC])
check("an unknown platform key is spoken as words", card(sources=["apple_tv"], category="movie"),
      ["Apple TV"], ["apple_tv", GENERIC])
check("a dislike keeps its own line", card(polarity="dislike"), ["Something to avoid"], [])
check("no em dash in the copy", card(category="music", sources=["apple", "spotify"], last_seen="2020-01-01"),
      [], ["—"])

print(f"{len(FAILS)} failed")
sys.exit(1 if FAILS else 0)
