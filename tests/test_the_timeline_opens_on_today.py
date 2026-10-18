#!/usr/bin/env python3
"""The Timeline opens on today, pages both ways, and names its rows (#106c).

Andy's walk on v1.0.105 (2026-09-28) found three faults in one screen:

  1. The list ENDED PART WAY THROUGH TODAY and no history was reachable. The
     graph query had no upper date bound and sorted newest-first, so a year of
     future all-day entries filled the 200-row cap before a single past row.
  2. Every row wore a MEETING chip. The entries mapper collapsed every kind
     that was not "meeting" to "calendar", which the Hub maps to MEETING, and
     all-day entries with no attendees were typed "meeting" at the source.
  3. Conversation rows were titled with the bare channel ("whatsapp").

This test drives the real api_timeline() with a stubbed graph and store, so
each assertion fails on the code that shipped in v1.0.105.

Exit 0 all pass, 1 any fail, 2 CANNOT-RUN (the server could not be loaded).
"""
import datetime
import importlib.util
import os
import re
import sys
import types

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SERVER = os.path.join(ROOT, "vendor", "cm041", "assistant_api", "ical-server.py")

FAILS = []


def check(name, cond, detail=""):
    print(("  ok    " if cond else "  FAIL  ") + name + (("  -- " + detail) if detail and not cond else ""))
    if not cond:
        FAILS.append(name)


def load_server():
    # ostler_security is a hard import that refuses to start without an
    # encrypted-DB stack. The timeline code never touches it; stub it.
    sec = types.ModuleType("ostler_security")
    for sub in ("database", "posture", "db_key", "region"):
        m = types.ModuleType("ostler_security." + sub)
        setattr(sec, sub, m)
        sys.modules["ostler_security." + sub] = m
    sys.modules["ostler_security"] = sec
    sys.modules["ostler_security.database"].get_db_connection = lambda *a, **k: None
    sys.modules["ostler_security.posture"].record_posture = lambda *a, **k: None
    sys.modules["ostler_security.db_key"].resolve_db_key = lambda *a, **k: types.SimpleNamespace(key="stub", source="test", reason="")
    sys.path.insert(0, os.path.join(ROOT, "vendor", "cm041"))
    sys.path.insert(0, os.path.join(ROOT, "vendor", "cm041", "assistant_api"))
    spec = importlib.util.spec_from_file_location("ics_under_test", SERVER)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


try:
    ics = load_server()
except Exception as exc:  # pragma: no cover - reported, not hidden
    print("CANNOT-RUN: could not load ical-server.py: {}".format(exc))
    sys.exit(2)

TODAY = datetime.date.today()


def day(offset):
    return (TODAY + datetime.timedelta(days=offset)).isoformat()


# A synthetic graph: 300 FUTURE all-day entries (no attendees, like an MOT or
# a holiday), 3 meetings today, 50 past meetings with attendees.
GRAPH = []
for i in range(300):
    GRAPH.append({"m": "f%d" % i, "date": day(1 + i), "summary": "Reminder %d" % i,
                  "location": "", "attendees": ""})
for i in range(3):
    GRAPH.append({"m": "t%d" % i, "date": day(0), "summary": "Today %d" % i,
                  "location": "", "attendees": "Person A|Person B"})
for i in range(50):
    GRAPH.append({"m": "p%d" % i, "date": day(-1 - i), "summary": "Past %d" % i,
                  "location": "", "attendees": "Person C"})


def fake_sparql(query):
    start = re.search(r'> "(\d{4}-\d{2}-\d{2})"\)', query)
    end = re.search(r'< "(\d{4}-\d{2}-\d{2})"\)', query)
    limit = int(re.search(r"LIMIT (\d+)", query).group(1))
    asc = "ORDER BY ASC" in query
    rows = [r for r in GRAPH
            if (not start or r["date"] > start.group(1))
            and (not end or r["date"] < end.group(1))]
    rows.sort(key=lambda r: r["date"], reverse=not asc)
    return rows[:limit]


CONVERSATIONS = [
    {"id": "c1", "payload": {"occurred_at": day(0), "channel": "whatsapp",
                             "contact_name": "Person D"}},
    {"id": "c2", "payload": {"occurred_at": day(-2), "channel": "sms"}},
]


class _Resp:
    def __init__(self, body):
        self._b = body

    def read(self):
        return self._b

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def fake_urlopen(req, timeout=None):
    import json
    return _Resp(json.dumps({"result": {"points": CONVERSATIONS,
                                        "next_page_offset": None}}).encode())


ics._sparql_select = fake_sparql
ics.urllib.request.urlopen = fake_urlopen
ics.subprocess.run = lambda *a, **k: types.SimpleNamespace(stdout="")
ics.query_google_calendar = lambda days: []

print("the Timeline opens on today (#106c)")

res = ics.api_timeline(days=7, past_days=730, limit=200)
dates = [i["date"] for i in res["items"]]
check("the opening page contains today's rows",
      day(0) in dates, "no row dated today in the first page")
check("the opening page reaches into history",
      any(d < day(0) for d in dates),
      "oldest row {} is not in the past".format(min(dates) if dates else None))
check("the opening page does not run a year ahead",
      max(dates) <= day(8), "newest row {}".format(max(dates) if dates else None))

older = ics.api_timeline(limit=200, before=day(-10))
check("an older page returns only rows before its bound",
      older["items"] and all(i["date"] < day(-10) for i in older["items"]))
later = ics.api_timeline(limit=20, after=day(7))
later_dates = sorted(i["date"] for i in later["items"])
check("a later page returns the EARLIEST rows after its bound",
      later_dates and later_dates[0] == day(8),
      "first later row {}".format(later_dates[0] if later_dates else None))

types_seen = {e["type"] for e in res["entries"]}
check("entries are not all typed meeting",
      types_seen != {"meeting"}, "types {}".format(sorted(types_seen)))
reminder = [e for e in later["entries"] if e["title"].startswith("Reminder")]
check("an attendee-less all-day entry is an event, not a meeting",
      reminder and all(e["type"] == "event" for e in reminder))
convo = [e for e in res["entries"] if e["type"] == "message"]
check("conversations are typed message", bool(convo))
titles = {e["title"].strip().lower() for e in res["entries"]}
check("no row is titled with a bare channel name",
      not (titles & {"whatsapp", "sms", "im", "email", "imessage"}),
      "bare titles {}".format(sorted(titles & {"whatsapp", "sms", "im", "email"})))
check("a conversation title names who it was with",
      "WhatsApp with Person D" in {e["title"] for e in res["entries"]})

bad = ics._safe_iso_day({"before": ['2026-01-01") } DROP']}, "before")
check("a malformed bound is refused, never interpolated", bad[1] is not None)

print("{} fail".format(len(FAILS)))
sys.exit(1 if FAILS else 0)
