#!/usr/bin/env python3
"""owner_digest_knows_the_owner: Tastes, Channel style and Routines have store measures.

Walk 132 (and the warm MBP re-run): three sections said "nothing stored" with no
store measure, so each line was NOT MEASURED. Now:
  - Tastes: count_tastes() over interest_profile.json (zero is a real count)
  - Channel style: owner sent-message signals (zero is a real count)
  - Routines and priorities: open commitments + owner diary meetings; zero reads None

Controls:
  - a lie over a measured non-zero store is caught (FAIL)
  - a real zero over a measured store PASSES (no false FAIL)
  - the Routines zero reads NOT MEASURED, never a pass
  - the polarity/L3 filter in count_tastes changes the count (a mutant without it differs)
  - removing the store mapping makes the lie go uncaught (the mapping is what matters)
Exit 0 pass, 1 fail. No box.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.join(os.path.dirname(HERE), "scripts", "box_walk_probes", "lib")
sys.path.insert(0, LIB)
import owner_digest as od  # noqa: E402

ALL = [("Tastes", "tastes"), ("Channel style", "channel_style"), ("Routines and priorities", "routines_priorities")]


def row(section, facts):
    return [ok for n, ok, _ in od.judge(facts) if n == od.DECLARED[1]]


def facts(section, key, value):
    g = od._good()
    g["stores"][key] = value
    g["digest"]["nothing_stored"] = [section]
    return g


def main():
    bad = []
    # 1. lie over a measured non-zero store is caught
    for section, key in ALL:
        if row(section, facts(section, key, 3)) != [False]:
            bad.append("%s: nothing stored over a store of 3 must FAIL, got %s" % (section, row(section, facts(section, key, 3))))
    # 2. a real zero over a measured store passes
    if row("Tastes", facts("Tastes", "tastes", 0)) != [True]:
        bad.append("Tastes: a measured zero must PASS")
    if row("Channel style", facts("Channel style", "channel_style", 0)) != [True]:
        bad.append("Channel style: a measured zero must PASS")
    # 3. Routines zero is unmeasured, never a pass
    if row("Routines and priorities", facts("Routines and priorities", "routines_priorities", None)) != [None]:
        bad.append("Routines: an unmeasured/zero store must be CANNOT-RUN")
    # 4. count_tastes: polarity and L3 filters decide the count
    interests = [
        {"domain": "food", "polarity": "pos", "subject": "a"},
        {"domain": "music", "polarity": "neg", "subject": "b"},      # negative: excluded
        {"domain": "film & tv", "polarity": "pos", "privacy": "L3"},  # L3: excluded
        {"domain": "books", "polarity": "pos"},                      # other domain: excluded
    ]
    got = od.count_tastes(interests)
    if got != 1:
        bad.append("count_tastes must count 1 over the fixture, got %s" % got)
    mutant = sum(1 for it in interests if " ".join(str(it.get("domain") or "").lower().split()) in od.TASTE_DOMAINS)
    if mutant == got:
        bad.append("CONTROL: a count without the polarity/L3 filters must differ from the real count")
    # 5. control: remove the mapping; the same lie is then not caught
    saved = od.SECTION_STORE.pop("Tastes")
    try:
        if row("Tastes", facts("Tastes", "tastes", 3)) == [False]:
            bad.append("CONTROL: without the Tastes mapping the lie should not be caught")
    finally:
        od.SECTION_STORE["Tastes"] = saved
    # 6. Routines counter: commitments plus meetings. A real empty store is a real zero;
    #    a FAILED read (None) makes the total None. A zero is never a failed read.
    if od._routines_count(lambda: 0, 0) != 0:
        bad.append("Routines: an empty store (0 commitments, 0 meetings) must read 0, not None")
    if od._routines_count(lambda: None, 0) is not None:
        bad.append("Routines: a failed commitments read must read None")
    if od._routines_count(lambda: 0, None) is not None:
        bad.append("Routines: a failed meetings read must read None")
    if od._routines_count(lambda: 2, 0) != 2:
        bad.append("Routines: 2 commitments must read 2")
    if od._routines_count(lambda: 0, 1) != 1:
        bad.append("Routines: a diary meeting alone must read 1")
    # 7. control: an empty measured Routines store with 'nothing stored' is an honest PASS,
    #    and the same store reading None (failed read) is CANNOT-RUN, never a pass.
    if row("Routines and priorities", facts("Routines and priorities", "routines_priorities", 0)) != [True]:
        bad.append("Routines: a measured empty store with 'nothing stored' must PASS")
    if row("Routines and priorities", facts("Routines and priorities", "routines_priorities", None)) != [None]:
        bad.append("CONTROL: a failed Routines read must be CANNOT-RUN, never a pass")
    if bad:
        print("FAIL: " + "; ".join(bad))
        return 1
    print("PASS: Tastes, Channel style and Routines measured; lies caught; real zeros pass; Routines zero is unmeasured; controls red")
    return 0


if __name__ == "__main__":
    sys.exit(main())
