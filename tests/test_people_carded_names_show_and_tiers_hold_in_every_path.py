#!/usr/bin/env python3
"""Phone-only People: a CARDED name always shows, and the name ladder (human
name > email > phone) holds in EVERY path: list, search, stale, recent,
birthdays. Review fixes for CM051 fix/phone-only-people-shown.

Rule A (people_rules.py SHARED RULE): the alphanumeric sender-ID exclusion
applies only to a sender with NO card. "JEAN-LUC", "MARY-JANE", "J.R." with a
card show; the same shapes with no card, and a true sender ID, do not.
Rule B: a phone-shaped stored name yields to the given/family name, and to an
email when there is no human name.

Synthetic cast only. Phone numbers are composed at runtime. Exit 0 pass,
1 fail, 2 cannot-run.
"""
import datetime
import importlib.util
import io
import json
import os
import sys
import time

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
sys.path.insert(0, os.path.join(ROOT, "vendor"))
API = os.path.join(ROOT, "vendor", "cm041", "assistant_api")
try:
    spec = importlib.util.spec_from_file_location("ical_server", os.path.join(API, "ical-server.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
except Exception as exc:  # noqa: BLE001
    print("CANNOT-RUN: could not load ical-server.py:", exc)
    sys.exit(2)

fails = 0


def check(label, ok, detail=""):
    global fails
    print("  {} {}{}".format("ok  " if ok else "FAIL", label, "" if ok else "  -- " + str(detail)))
    if not ok:
        fails += 1


PH1 = "+44" + "7700900001"
PH2 = "+44" + "7700900002"
PH3 = "+44" + "7700900003"
AT = "@"
EM = "alex" + AT + "example.com"
OLD = time.time() - 400 * 86400


def pt(i, name, **kw):
    pl = {"display_name": name, "contact_type": "person", "last_contact_ts": OLD,
          "last_contact": "2025-01-01", "person_uri": "urn:t:%d" % i}
    pl.update(kw)
    return {"id": i, "payload": pl, "score": 0.9}


POINTS = [
    pt(1, PH1, given_name="Alice", family_name="Example", icloud_uid="c1"),
    pt(2, PH2, emails=[EM]),
    pt(3, "JEAN-LUC", icloud_uid="c3"),
    pt(4, "MARY-JANE", icloud_uid="c4"),
    pt(5, "J.R.", icloud_uid="c5"),
    pt(6, "HSBC-ALERT"),
    pt(7, "NHS-ALERT"),
    pt(8, "JEAN-LUC"),
    pt(9, PH3),
]
CARDED = {"urn:t:3", "urn:t:4", "urn:t:5", "urn:t:1"}


class Resp(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def fake_urlopen(req, timeout=None):
    url = req.full_url if hasattr(req, "full_url") else req
    if url.endswith("/points/search"):
        return Resp(json.dumps({"result": POINTS}).encode())
    return Resp(json.dumps({"result": {"points": POINTS, "next_page_offset": None}}).encode())


today = datetime.date.today()
BDAY = "1990-%02d-%02d" % (today.month, today.day)


def fake_sparql(q, *a, **k):
    if "meetingAttendee" in q:
        return [{"p": "urn:t:%d" % i, "name": n, "summary": "s", "date": today.isoformat(), "location": ""}
                for i, n in ((1, PH1), (2, PH2), (3, "JEAN-LUC"), (9, PH3))]
    if "pwg:birthday" in q:
        return [{"p": "urn:t:%d" % i, "name": n, "bday": BDAY, "bnode": "urn:t:%d" % i}
                for i, n in ((1, PH1), (2, PH2), (3, "JEAN-LUC"), (9, PH3))]
    return []


m.urllib.request.urlopen = fake_urlopen
m._embed_text = lambda q, timeout=None: [0.0]
m._sparql_select = fake_sparql
m._load_people_list_self_uris = lambda: set()
m._load_carded_uris = lambda uris: {u for u in uris if u in CARDED}


def names(rows, key="name"):
    return [r[key] for r in rows]


print("--- rule A: pure predicate ---")
f = m._is_nameless_name
for n in ("JEAN-LUC", "MARY-JANE", "J.R."):
    check("carded %r shows" % n, not f(n, has_card=True))
    check("uncarded %r keeps the shape exclusion" % n, f(n))
check("a true sender ID (NHS-ALERT) with no card is hidden", f("NHS-ALERT"))
check("a short code is hidden even with a card", f("87099", has_card=True))

print("--- people_list ---")
lst = names(m.people_list()["people"])
for n in ("Alice Example", EM, "JEAN-LUC", "MARY-JANE", "J.R."):
    check("list shows %r" % n, n in lst, lst)
check("list: no raw phone over a given name", PH1 not in lst)
check("list: email beats phone", PH2 not in lst)
check("list: phone-only shown when nothing better", PH3 in lst, lst)
check("list: true sender ID with no card hidden", "HSBC-ALERT" not in lst and "NHS-ALERT" not in lst, lst)
check("list: uncarded JEAN-LUC (point 8) is not a second carded row", lst.count("JEAN-LUC") == 1, lst)

print("--- people_search ---")
res = names(m.people_search("anyone")["results"])
check("search: carded given name over phone", "Alice Example" in res and PH1 not in res, res)
check("search: email over phone", EM in res and PH2 not in res, res)
check("search: carded all-caps shows", all(n in res for n in ("JEAN-LUC", "MARY-JANE", "J.R.")), res)
check("search: true sender ID hidden", "NHS-ALERT" not in res, res)

print("--- people_stale ---")
st = names(m.people_stale(limit=50)["contacts"])
check("stale: carded given name over phone", "Alice Example" in st and PH1 not in st, st)
check("stale: the raw phone is never shown over an email (the suggestion screen then drops a bare address)", PH2 not in st, st)
check("stale: carded all-caps shows", all(n in st for n in ("JEAN-LUC", "MARY-JANE", "J.R.")), st)

print("--- people_recent ---")
rc = names(m.people_recent(days=7, limit=10)["contacts"])
check("recent: carded given name over phone", "Alice Example" in rc and PH1 not in rc, rc)
check("recent: the raw phone is never shown over an email (the suggestion screen then drops a bare address)", PH2 not in rc, rc)
check("recent: carded all-caps shows", "JEAN-LUC" in rc, rc)

print("--- people_birthdays ---")
bd = m.people_birthdays(days=7)
bd = bd.get("people") or bd.get("contacts") or bd.get("birthdays") or []
bn = names(bd)
check("birthdays: carded given name over phone", "Alice Example" in bn and PH1 not in bn, bn)
check("birthdays: the raw phone is never shown over an email (the suggestion screen then drops a bare address)", PH2 not in bn, bn)
check("birthdays: carded all-caps shows", "JEAN-LUC" in bn, bn)

print("\n{}: {} failed".format("PASS" if fails == 0 else "FAIL", fails))
sys.exit(1 if fails else 0)
