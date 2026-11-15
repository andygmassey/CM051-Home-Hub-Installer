#!/usr/bin/env python3
"""The Contacts row is judged against the API's own "contacts" source (v1.0.115 walk, H1).

API_ALIASES maps the API's "people" source onto "contacts" and the judge ORed
the two, so people=ok masked contacts=no_data: the box said contacts had nothing
and the screen correctly said "Nothing to import yet", yet the judge failed it.
The alias is now a fallback used only when the API has no "contacts" row.

Runs the REAL judge (assertion DECLARED[18], the Doctor tab against the box).
Synthetic data only. Exit 0 all pass, 1 any fail.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "scripts", "box_walk_probes", "lib"))
import customer_read as cr  # noqa: E402

NOTHING = "Nothing to import yet"
UPTODATE = "Up to date · 1 hour ago"


def verdict(api_sources, contacts_screen):
    f = cr._good()
    f["api"]["sources"] = api_sources
    rows = [["Mail", UPTODATE], ["WhatsApp", UPTODATE], ["Contacts", contacts_screen]]
    f["screens"]["doctor_sources"]["rows"] = rows
    out = [r for r in cr.judge(f) if r[0] == cr.DECLARED[18]]
    assert len(out) == 1, out
    return out[0]


BASE = [["email", "ok"], ["whatsapp", "ok"]]
# (label, api sources, Contacts row on screen, expected verdict)
CASES = [
    ("H1 shape: contacts=no_data, people=ok, screen 'Nothing to import yet' PASSES",
     BASE + [["contacts", "no_data"], ["people", "ok"]], NOTHING, True),
    ("same, people listed BEFORE contacts (order must not matter) PASSES",
     BASE + [["people", "ok"], ["contacts", "no_data"]], NOTHING, True),
    ("converse: contacts=ok, screen 'Nothing to import yet' FAILS",
     BASE + [["contacts", "ok"], ["people", "ok"]], NOTHING, False),
    ("contacts=no_data, people=ok, screen says Up to date FAILS (people no longer masks)",
     BASE + [["contacts", "no_data"], ["people", "ok"]], UPTODATE, False),
    ("contacts absent, people=ok: falls back to people, 'Up to date' PASSES",
     BASE + [["people", "ok"]], UPTODATE, True),
    ("contacts absent, people=ok: falls back to people, 'Nothing to import yet' FAILS",
     BASE + [["people", "ok"]], NOTHING, False),
]


def main():
    bad = 0
    for label, api, screen, want in CASES:
        got = verdict(api, screen)
        ok = got[1] is want
        bad += not ok
        print("%s  %s  (got %r)" % ("ok  " if ok else "FAIL", label, got[1]))
    print("%d case(s), %d failed" % (len(CASES), bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
