#!/usr/bin/env python3
"""No GDPR Art. 9 special-category topic ever becomes an interest card
(board row 2471, v1.0.119).

All eight Art. 9(1) classes, with synthetic examples, driven through the
SHIPPED vendored Front Page (vendor/cm059_editor): the real build_frontpage()
assembly, the last-gate over interest cards built off-profile (a hunch), and
the scout topic selector whose results come back as a scout card. Each
sensitive example must yield NO card and NO scout topic; each ordinary
control (including words that merely contain a stem, like "History") must
still card. Exit 0 pass, 1 fail, 2 CANNOT-RUN.
"""
import os
import sys
import tempfile
from datetime import datetime, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "vendor", "cm059_editor"))
# l1_interests re-reads the owner's install answer from under HOME: never
# the real one.
os.environ["HOME"] = tempfile.mkdtemp(prefix="art9-card-")
os.environ.pop("OSTLER_DIR", None)
try:
    from compiler import frontpage
    from compiler import scout_external
except Exception as exc:
    print("CANNOT-RUN: {}".format(exc))
    sys.exit(2)

NOW = datetime(2026, 10, 29, 9, 0, tzinfo=timezone.utc)
FAILS = []

# Synthetic subjects, two or more per class. None is a real person.
SENSITIVE = {
    "racial_ethnic_origin": ["Ethnic minority networking", "Hispanic heritage events"],
    "political_opinions": ["Election night coverage", "labour party conference"],
    "religious_philosophical_beliefs": ["Sunday church services", "Ramadan iftar recipes"],
    "trade_union_membership": ["Trade union meetings", "Picket line solidarity"],
    "genetic_data": ["Genetic ancestry testing", "23andMe results"],
    "biometric_data": ["Fingerprint unlock enrolment", "Iris scan registration"],
    "health": ["Diabetes support group", "Marathon for diabetes charity", "Anxiety therapy"],
    "sex_life_orientation": ["Gay bars", "LGBTQ film nights", "Bisexual meetups"],
}
# Ordinary interests that must still card, several of which merely CONTAIN a
# sensitive stem mid-word or name a sensitive word inside a known phrase.
CONTROLS = ["Trail running", "History podcasts", "Magazine design", "Story writing",
            "Archive footage", "Christmas markets", "Saturday football",
            "Retail therapy weekends"]


def check(name, cond, detail=""):
    print(("  ok    " if cond else "  FAIL  ") + name + (("  -- " + detail) if detail and not cond else ""))
    if not cond:
        FAILS.append(name)


def interest(i, subject, domain):
    return {"id": "art9-%d" % i, "subject": subject, "domain": domain,
            "score": 0.9, "polarity": "like", "strength": 0.9,
            "privacy": "L1", "sources": ["synthetic:test"]}


def titles_for(subjects):
    blocks = [{"domain": "d%d" % k, "count": 1,
               "interests": [interest(k, s, "d%d" % k)]} for k, s in enumerate(subjects)]
    feed = frontpage.build_frontpage({"domains": blocks, "stats": {"interests": len(subjects)}},
                                     now=NOW, exploration=False)
    return [c.get("title") or "" for c in feed.get("cards", []) if c.get("kind") == "interest"]


def low(t):
    return t.strip().lower()


# 1. The real assembly, one sensitive subject beside one control per run.
for cls, examples in sorted(SENSITIVE.items()):
    for ex in examples:
        titles = [low(t) for t in titles_for([ex, "Trail running"])]
        check("{}: {!r} is never carded".format(cls, ex), low(ex) not in titles, repr(titles))
        check("{}: the control beside {!r} still cards".format(cls, ex),
              "trail running" in titles, repr(titles))

# 2. Controls: every one cards, in one feed.
titles = [low(t) for t in titles_for(CONTROLS)]
for c in CONTROLS:
    check("control {!r} still cards".format(c), low(c) in titles, repr(titles))

# 3. A hunch card built straight from a row (not via the filtered profile)
#    is caught by the last gate over the assembled feed.
gate = getattr(frontpage, "sensitive_card_gate", None)
for cls, examples in sorted(SENSITIVE.items()):
    hunch = frontpage.exploration_card(interest(900, examples[0], "dx"), NOW)
    kept = gate([hunch]) if gate else [hunch]
    check("{}: an off-profile hunch card on {!r} is dropped by the feed gate".format(
        cls, examples[0]), kept == [], "no sensitive_card_gate" if gate is None else repr(kept))
ok_hunch = frontpage.exploration_card(interest(901, "Trail running", "dx"), NOW)
check("the feed gate keeps an ordinary hunch card",
      gate is not None and gate([ok_hunch]) == [ok_hunch])

# 4. Scout topics: a special-category subject never becomes an outbound query
#    (and so never comes back as a scout card).
all_sensitive = [s for ex in SENSITIVE.values() for s in ex]
prof = {"domains": [{"domain": "Film & TV", "interests":
                     [interest(1000 + k, s, "Film & TV") for k, s in enumerate(all_sensitive + CONTROLS)]}]}
picked = {low(it.get("subject") or "") for it in scout_external.l1_interests(prof)}
for s in all_sensitive:
    check("scout topics exclude {!r}".format(s), low(s) not in picked)
check("scout topics keep the ordinary controls",
      all(low(c) in picked for c in CONTROLS), repr(sorted(picked)))

# 5. The single list names all eight Art. 9(1) classes.
try:
    from compiler import sensitive_topics
    names = set(sensitive_topics.ART9_CLASSES)
except Exception as exc:  # absent on a tree without the shared list
    names = set()
    print("  note  no shared list: {}".format(exc))
for cls in sorted(SENSITIVE):
    check("the shared list carries class {}".format(cls), cls in names)

print("{} fail".format(len(FAILS)))
sys.exit(1 if FAILS else 0)
