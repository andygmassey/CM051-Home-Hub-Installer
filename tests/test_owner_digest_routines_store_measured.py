#!/usr/bin/env python3
"""owner_digest_knows_the_owner: "Routines and priorities" has a store measure.

Walk 132: the section had no store measure, so its "nothing stored" line was
NOT MEASURED. Now the open-commitments count backs it.

Cases (judge() from lib/owner_digest.py, fixtures from its self-test):
  - section says nothing stored, commitments held > 0      -> FAIL (a lie is caught)
  - section says nothing stored, commitments unmeasured/0  -> CANNOT-RUN (None), never PASS
  - control: the store map without the new key            -> the lie is NOT caught
Exit 0 pass, 1 fail. No box.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.join(os.path.dirname(HERE), "scripts", "box_walk_probes", "lib")
sys.path.insert(0, LIB)
import owner_digest as od  # noqa: E402

ROUTINES = od.DECLARED[1]


def row(facts):
    return [ok for n, ok, _ in od.judge(facts) if n == ROUTINES]


def facts(commitments):
    g = od._good()
    g["stores"]["routines_priorities"] = commitments
    g["digest"]["nothing_stored"] = ["Routines and priorities"]
    return g


def main():
    bad = []
    if row(facts(3)) != [False]:
        bad.append("commitments=3 with 'nothing stored' must FAIL, got %s" % row(facts(3)))
    if row(facts(None)) != [None]:
        bad.append("commitments unmeasured must be CANNOT-RUN, got %s" % row(facts(None)))
    # control: remove the mapping; the same lie must then go unmeasured, not be caught.
    saved = od.SECTION_STORE.pop("Routines and priorities")
    try:
        if row(facts(3)) == [False]:
            bad.append("CONTROL: without the store mapping the lie should not be caught")
    finally:
        od.SECTION_STORE["Routines and priorities"] = saved
    if bad:
        print("FAIL: " + "; ".join(bad))
        return 1
    print("PASS: a commitments store backs the section; zero or unmeasured is CANNOT-RUN; control goes red")
    return 0


if __name__ == "__main__":
    sys.exit(main())
