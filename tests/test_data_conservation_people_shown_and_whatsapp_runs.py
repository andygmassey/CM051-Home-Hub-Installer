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


# ---- (ii) people/all: SHOWN summed over every source --------------------------
people = {
    "hyd.people.item_count": 5000, "hyd.contacts.item_count": 2000,
    "q.people.total": 7000, "x.class.Person": 7000,
    "w.shown.people.source=fda_people_index": 5000,
    "w.shown.people.source=icloud_contacts": 2000,
}
people["w.shown.people.source_sum"] = dc.shown_source_sum(people, "people")
check("the source sum adds every people source (={})".format(people["w.shown.people.source_sum"]),
      people["w.shown.people.source_sum"] == 7000)
check("people/all reads CONSERVED when every source is shown (fda 5000 + icloud 2000 = stored 7000): {}".format(
    verdict("people/all", people)), verdict("people/all", people) == "CONSERVED")

# the same facts with one source genuinely missing from the wiki must still be LOST
missing = dict(people, **{"w.shown.people.source=icloud_contacts": 0})
missing["w.shown.people.source_sum"] = dc.shown_source_sum(missing, "people")
check("an unexplained shown loss in one source is still LOST: {}".format(verdict("people/all", missing)),
      verdict("people/all", missing) == "LOST")

# absent, never zero: no source group measured means the sum is absent
check("no measured source group gives an absent sum, not 0",
      dc.shown_source_sum({"q.people.total": 7000}, "people") is None)

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
rows, counts = dc.adjudicate({"rows": [row("people/all"), row("whatsapp/people")]}, lost_facts)
word, code = dc.overall(rows, counts)
check("a LOST row still makes the whole probe FAIL, even beside a cross-run row: {} {}".format(word, code),
      word == "FAIL" and code == 1)

print("FAIL: " + "; ".join(fails) if fails else "PASS")
sys.exit(1 if fails else 0)
