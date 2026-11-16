#!/usr/bin/env python3
"""data_conservation: two rows that read the wrong thing, read correctly now.

(ii) people/all compared SHOWN for ONE source (fda_people_index) with a STORED
     total that counts every source. Walk 131: 5208 "lost" where the other
     source's items were in the wiki. SHOWN is now summed over every source.
(iii) whatsapp/people compared an IN count from the install summary with a
     STORED count from the hydrate marker, two different runs. That is not a
     measurement. The row is CANNOT-RUN (NOT-MEASURED), never LOST.

Runs the REAL adjudicate() on the REAL expected.json, on synthetic facts.
Against the pre-fix expected.json both rows come out LOST, which is the RED.
Exit 0 pass, 1 fail. Synthetic counts only.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.join(os.path.dirname(HERE), "scripts", "box_walk_probes", "lib")
EXPECTED = os.path.join(os.path.dirname(HERE), "scripts", "box_walk_probes", "fixtures",
                        "data_conservation", "expected.json")
sys.path.insert(0, LIB)
import data_conservation as dc  # noqa: E402

fails = []


def check(label, ok):
    print(("  ok    " if ok else "  FAIL  ") + label)
    if not ok:
        fails.append(label)


with open(EXPECTED) as fh:
    profile = json.load(fh)["profiles"]["chain"]["rows"]


def row(rid):
    return [r for r in profile if r.get("id") == rid][0]


def verdict(rid, facts):
    return dc.adjudicate_row(row(rid), facts)["verdict"]


# ---- (ii) people/shown: SHOWN = wiki People pages, less the product's declared skips ----
# (replaces the old people/all row, which summed overlapping sources; CM051 #3555)
people = {
    "cnt.loaded": 95, "cnt.merged.fold_people": 5,
    "cnt.skip.empty_profile": 3, "cnt.skip.org_as_person": 2, "cnt.skip.junk_single_token": 0,
    "w.pages.People": 90,
}
check("people/shown is not a loss when every gap is a declared skip (EXPLAINED): {}".format(
    verdict("people/shown", people)), verdict("people/shown", people) in ("CONSERVED", "EXPLAINED"))

# one page genuinely missing from the wiki, no declared reason, must still be LOST
missing = dict(people, **{"w.pages.People": 89})
check("an unexplained shown loss is still LOST: {}".format(verdict("people/shown", missing)),
      verdict("people/shown", missing) == "LOST")

# absent counts file: no product facts, so NOT-MEASURED, never a pass
absent = {"w.pages.People": 90}
check("no product counts file gives NOT-MEASURED, not a pass: {}".format(verdict("people/shown", absent)),
      verdict("people/shown", absent) == "NOT-MEASURED")

# ---- (iii) whatsapp/people: cross-run, so NOT-MEASURED ----------------------
wa = {"log.whatsapp_people_added": 467, "hyd.whatsapp.item_count": 293, "doctor.whatsapp.item_count": 293}
res = dc.adjudicate_row(row("whatsapp/people"), wa)
check("whatsapp/people is NOT-MEASURED across runs, never LOST (verdict={})".format(res["verdict"]),
      res["verdict"] == "NOT-MEASURED")
check("the NOT-MEASURED reason names the cross-run cause", "cross-run" in res["why"])
rows, counts = dc.adjudicate({"rows": [row("whatsapp/people")]}, wa)
word, code = dc.overall(rows, counts)
check("a cross-run row alone makes the probe CANNOT-RUN (78), not FAIL: {} {}".format(word, code),
      word == "CANNOT-RUN" and code == 78)
# A real LOST elsewhere still dominates
lost_facts = dict(missing, **{"log.whatsapp_people_added": 467, "hyd.whatsapp.item_count": 293,
                             "doctor.whatsapp.item_count": 293})
rows, counts = dc.adjudicate({"rows": [row("people/shown"), row("whatsapp/people")]}, lost_facts)
word, code = dc.overall(rows, counts)
check("a LOST row still makes the whole probe FAIL, even beside a cross-run row: {} {}".format(word, code),
      word == "FAIL" and code == 1)

print("FAIL: " + "; ".join(fails) if fails else "PASS")
sys.exit(1 if fails else 0)
