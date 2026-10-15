#!/usr/bin/env python3
"""No picker on the Front Page turns a sentence of prose into an interest.

Andy's console walk of v1.0.107 candidate #28: the "A hunch" card showed the
text of a LinkedIn recommendation, filed under music. The row came from the
LinkedIn export's Recommendations_Given.csv (the producer side is fixed in
andygmassey/personal-world-graph#407). The compiler already knew it was not a
taste: interest_profile.noise_flags stamps a subject over 80 characters
"too_long". But the flag is only a confidence penalty, and no picker read it,
so the strongest sub-top row in an empty domain became the hunch.

The shape, not the instance: a subject flagged "too_long", or one longer than
the producer's own 12-word preference ceiling, is a sentence, never a thing
someone is into. This drives the REAL vendored build_frontpage() (every
picker: the ranked top, the rotation and the exploration hunch, across many
ISO weeks) and the two scout pickers that read the same profile.

Fixtures are invented. Exit 0 pass, 1 fail, 2 CANNOT-RUN.
"""
import os
import sys
from datetime import datetime, timedelta, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "vendor", "cm059_editor"))
try:
    from compiler import frontpage
    from compiler import scout_external
    from compiler import scout_newsletters
except Exception as exc:
    print("CANNOT-RUN: {}".format(exc))
    sys.exit(2)

FAILS = []


def check(name, cond, detail=""):
    print(("  ok    " if cond else "  FAIL  ") + name
          + (("  -- " + detail) if detail and not cond else ""))
    if not cond:
        FAILS.append(name)


# 84 characters: over interest_profile's 80-character ceiling, so the
# compiler flags it "too_long", exactly as it did on the walk box.
LONG_REC = ("Ada keeps every project on track, calm under pressure, and a joy "
            "to work with daily.")
# 14 words but under 80 characters: a row compiled before the flag existed,
# or by a path that never set it, must still be refused by its shape.
WORDY_REC = "She is kind and sharp and we all learned a lot from her here"


def interest(iid, subject, domain, score, flags=None, privacy="L1"):
    return {"id": iid, "subject": subject, "domain": domain, "score": score,
            "polarity": "like", "privacy": privacy, "category": domain,
            "sources": ["synthetic"], "flags": list(flags or [])}


def build_profile(prose):
    """Three full domains take the twelve ranked slots; the prose row is the
    strongest liked interest left, alone in its own domain, so it is exactly
    what exploration_pick reaches for."""
    blocks = []
    for d in ("film_tv", "books", "food"):
        items = [interest("%s_top_%d" % (d, k), "%s favourite %d" % (d, k), d, 0.9)
                 for k in range(4)]
        items += [interest("%s_tail_%d" % (d, k), "%s pastime %d" % (d, k), d, 0.3)
                  for k in range(6)]
        blocks.append({"domain": d, "interests": items})
    blocks.append({"domain": "music", "interests": [prose]})
    blocks.append({"domain": "travel", "interests": [
        interest("travel_1", "Island hopping", "travel", 0.2)]})
    n = sum(len(b["interests"]) for b in blocks)
    return {"domains": blocks, "stats": {"interests": n}}


def titles_over_weeks(profile, weeks=12):
    start = datetime(2026, 10, 15, 9, 0, tzinfo=timezone.utc)
    seen = []
    for w in range(weeks):
        feed = frontpage.build_frontpage(profile, now=start + timedelta(weeks=w))
        seen.append([(c.get("title") or "", bool(c.get("exploration")))
                     for c in feed.get("cards", [])])
    return seen


for label, prose in (
        ("a too_long-flagged recommendation",
         interest("rec_long", LONG_REC, "music", 0.6, flags=["too_long"])),
        ("an unflagged 14-word recommendation",
         interest("rec_wordy", WORDY_REC, "music", 0.6))):
    profile = build_profile(prose)
    weeks = titles_over_weeks(profile)
    carded = [t for wk in weeks for t, _ in wk if t == prose["subject"]]
    hunches = [t for wk in weeks for t, ex in wk if ex]
    check(label + " is never carded, in any week, by any picker",
          not carded, "carded %d time(s)" % len(carded))
    # Control: the slot is still used. A gate that killed the hunch outright
    # would also pass the line above.
    check(label + ": a hunch is still offered, from a real interest",
          len(hunches) == len(weeks) and prose["subject"] not in hunches,
          repr(hunches[:3]))

    l1 = [it["subject"] for it in scout_external.l1_interests(profile)]
    check(label + " never seeds an outbound scout query",
          prose["subject"] not in l1)
    nl = [it["subject"] for it in scout_newsletters._profile_interests(profile)]
    check(label + " never steers the newsletter scout",
          prose["subject"] not in nl)

# Controls on the predicate: real long titles and corrections survive.
title12 = "The Lord of the Rings: The Fellowship of the Ring"
check("a real twelve-word-or-shorter title is still cardable",
      frontpage.is_cardable_interest(interest("t", title12, "books", 0.5)))
check("an interest the owner confirmed is kept even if long",
      frontpage.is_cardable_interest(dict(
          interest("c", LONG_REC, "music", 0.5, flags=["too_long"]),
          corrected=True)))

print("%d check(s) failed" % len(FAILS) if FAILS else "all checks passed")
sys.exit(1 if FAILS else 0)
