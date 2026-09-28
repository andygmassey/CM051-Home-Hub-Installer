#!/usr/bin/env python3
"""The Front Page cards only real interests, titled cleanly (#106c, h and i).

Andy's walk (2026-09-28) found a social hashtag, a political memorial one,
shown as "one of the things Ostler reckons you're into", and a hunch titled
with a page's SEO suffix. This drives the real build_frontpage() with a
synthetic profile. Exit 0 pass, 1 fail, 2 CANNOT-RUN.
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "vendor", "cm059_editor"))
try:
    from compiler import frontpage
except Exception as exc:
    print("CANNOT-RUN: {}".format(exc))
    sys.exit(2)

FAILS = []


def check(name, cond, detail=""):
    print(("  ok    " if cond else "  FAIL  ") + name + (("  -- " + detail) if detail and not cond else ""))
    if not cond:
        FAILS.append(name)


def interest(i, subject, domain="film_tv", score=0.9):
    return {"id": "i%d" % i, "subject": subject, "domain": domain,
            "score": score, "polarity": "like", "strength": score,
            "privacy": "L1", "sources": ["synthetic:test"]}


profile = {"domains": [{"domain": "film_tv", "interests": [
    interest(1, "#someonesmemorial"),
    interest(2, "Election night coverage"),
    interest(3, "Weekend Film Festival - Best Website"),
    interest(4, "Wildlife documentaries"),
    interest(5, "Ozempic"),
] + [interest(10 + k, "Hobby %d" % k, score=0.5) for k in range(20)]}],
    "stats": {"interests": 25}}

feed = frontpage.build_frontpage(profile)
titles = [c.get("title", "") for c in feed.get("cards", [])]
joined = " || ".join(titles)
check("a hashtag is never carded", not any(t.startswith("#") for t in titles), joined)
check("a political topic is not carded as an interest",
      not any("Election" in t for t in titles), joined)
check("a health topic is not carded as an interest",
      not any("Ozempic" in t for t in titles), joined)
check("a real interest still cards", any("Wildlife" in t for t in titles), joined)
check("a site suffix is stripped from a carded subject",
      not any("Best Website" in t for t in titles)
      and frontpage.card_subject("Weekend Film Festival - Best Website") == "Weekend Film Festival")
check("an ordinary hyphenated title keeps its meaning",
      frontpage.card_subject("Spider-Man - Into the Spider-Verse")
      == "Spider-Man - Into the Spider-Verse")
check("the caller's profile is not mutated",
      profile["domains"][0]["interests"][0]["subject"] == "#someonesmemorial")
print("{} fail".format(len(FAILS)))
sys.exit(1 if FAILS else 0)
