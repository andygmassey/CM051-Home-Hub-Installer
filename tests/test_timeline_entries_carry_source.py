#!/usr/bin/env python3
"""Every /api/v1/timeline item and entry says who wrote its title (#2565).

A client could not tell the customer's verbatim calendar title (never
rewritten, decision 2026-10-01) from text Ostler composed, so the walk probe
hub_screens_customer_read exempted em dashes by row kind == "event" instead.

Two halves, both driven through the real code:

  PRODUCER  the vendored ical-server api_timeline(), with a stubbed graph,
            conversation store and live calendar. Every item and every entry
            carries a non-empty `source`; entries carry `title_verbatim`, true
            only for source "calendar". Fails on main before #2565: no field.

  CONTRACT  the producer's own output fed to the consumer AS VENDORED in this
            repo, scripts/box_walk_probes/lib/customer_read.py: the probe
            exempts exactly the calendar titles and still counts a dash in a
            title Ostler composed, on the SAME screen.

Synthetic names only. Exit 0 all pass, 1 any fail, 2 CANNOT-RUN.
"""
import datetime
import importlib.util
import json
import os
import re
import sys
import types

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SERVER = os.path.join(ROOT, "vendor", "cm041", "assistant_api", "ical-server.py")
PROBE = os.path.join(ROOT, "scripts", "box_walk_probes", "lib", "customer_read.py")
DASH = "—"

FAILS = []


def check(name, cond, detail=""):
    print(("  ok    " if cond else "  FAIL  ") + name + (("  -- " + detail) if detail and not cond else ""))
    if not cond:
        FAILS.append(name)


def load_server():
    sec = types.ModuleType("ostler_security")
    for sub in ("database", "posture", "db_key", "region"):
        m = types.ModuleType("ostler_security." + sub)
        setattr(sec, sub, m)
        sys.modules["ostler_security." + sub] = m
    sys.modules["ostler_security"] = sec
    sys.modules["ostler_security.database"].get_db_connection = lambda *a, **k: None
    sys.modules["ostler_security.posture"].record_posture = lambda *a, **k: None
    sys.modules["ostler_security.db_key"].resolve_db_key = lambda *a, **k: types.SimpleNamespace(
        key="stub", source="test", reason="")
    sys.path.insert(0, os.path.join(ROOT, "vendor", "cm041"))
    sys.path.insert(0, os.path.join(ROOT, "vendor", "cm041", "assistant_api"))
    spec = importlib.util.spec_from_file_location("ics_under_test_2565", SERVER)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def load_probe():
    spec = importlib.util.spec_from_file_location("customer_read_2565", PROBE)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


try:
    ics = load_server()
    probe = load_probe()
except Exception as exc:  # reported, not hidden
    print("CANNOT-RUN: could not load the producer or the probe: {}".format(exc))
    sys.exit(2)

TODAY = datetime.date.today()


def day(offset):
    return (TODAY + datetime.timedelta(days=offset)).isoformat()


CAL_TITLE = "Offsite " + DASH + " day one"          # the customer's own words
GRAPH = [
    {"m": "m1", "date": day(-1), "summary": CAL_TITLE, "location": "", "attendees": ""},
    {"m": "m2", "date": day(-2), "summary": "Lunch with Person B", "location": "",
     "attendees": "Person B"},
]
# Ostler composes "WhatsApp with <name>": a dash here is OSTLER'S text.
CONVERSATIONS = [
    {"id": "c1", "payload": {"occurred_at": day(-1), "channel": "whatsapp",
                             "contact_name": "Person " + DASH + " C"}},
]
LIVE = [{"start": day(1) + "T10:00:00", "summary": "Dentist " + DASH + " check-up",
         "location": "", "attendees": [{"name": "Person D"}]}]


def fake_sparql(query):
    limit = int(re.search(r"LIMIT (\d+)", query).group(1))
    return GRAPH[:limit]


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
    return _Resp(json.dumps({"result": {"points": CONVERSATIONS,
                                        "next_page_offset": None}}).encode())


ics._sparql_select = fake_sparql
ics.urllib.request.urlopen = fake_urlopen
ics.subprocess.run = lambda *a, **k: types.SimpleNamespace(stdout="")
ics.parse_ical_output = lambda out: []
ics.query_google_calendar = lambda days: list(LIVE)

print("timeline entries carry source (#2565): producer")
res = ics.api_timeline(days=7, past_days=730, limit=200)
items, entries = res["items"], res["entries"]
check("the stub produced rows from all three sources",
      {i.get("kind") for i in items} >= {"calendar", "conversation"} and len(entries) >= 4,
      "kinds {} entries {}".format(sorted({i.get("kind") for i in items}), len(entries)))
check("every item carries a non-empty source",
      items and all(i.get("source") for i in items),
      "missing on {}".format([i.get("kind") for i in items if not i.get("source")]))
check("every entry carries a non-empty source and a boolean title_verbatim",
      entries and all(e.get("source") and isinstance(e.get("title_verbatim"), bool) for e in entries))
by_title = {e["title"]: e for e in entries}
check("a graph calendar title is source calendar, verbatim",
      by_title.get(CAL_TITLE, {}).get("source") == "calendar"
      and by_title[CAL_TITLE]["title_verbatim"] is True)
check("a live calendar title is source calendar, verbatim",
      by_title.get(LIVE[0]["summary"], {}).get("title_verbatim") is True)
convo = [e for e in entries if e["type"] == "message"]
check("a conversation title (composed by Ostler) is source ostler, not verbatim",
      convo and all(e.get("source") == "ostler" and e.get("title_verbatim") is False for e in convo))
# An error sentinel is Ostler's own text too.
ics._sparql_select = lambda q: (_ for _ in ()).throw(RuntimeError("graph down"))
err = ics.api_timeline(days=7)
err_items = [i for i in err["items"] if i.get("kind") == "meeting_error"]
check("an error sentinel carries source ostler", err_items and err_items[0].get("source") == "ostler")
ics._sparql_select = fake_sparql
# An item with no source is reported as unknown, never guessed verbatim.
orig = ics._timeline_from_graph
ics._timeline_from_graph = lambda **k: ([{"kind": "event", "date": day(-3), "start": day(-3),
                                          "summary": "No provenance", "participants": []}], None)
unk = [e for e in ics.api_timeline(days=7)["entries"] if e["title"] == "No provenance"]
check("an item with no source is 'unknown' and NOT verbatim",
      unk and unk[0]["source"] == "unknown" and unk[0]["title_verbatim"] is False)
ics._timeline_from_graph = orig

print("timeline entries carry source (#2565): contract with the walk probe as vendored here")
api_body = json.loads(json.dumps(res))      # the wire, not the Python objects
api_entries = probe.timeline_api_sources(api_body)
exempt = probe.verbatim_timeline_titles(api_entries)
check("the probe exempts the calendar titles the producer marked",
      CAL_TITLE in exempt and LIVE[0]["summary"] in exempt)
ostler_title = convo[0]["title"] if convo else ""
check("the probe does NOT exempt a title the producer says Ostler wrote",
      ostler_title and ostler_title not in exempt)

# End to end through judge(): the same Timeline screen shows a verbatim
# calendar title with a dash AND an Ostler-composed title with a dash.
good = probe._good()
good["timeline_api_entries"] = api_entries
good["timeline_rows"] = [{"kind": e["type"], "title": e["title"]} for e in entries]
good["screens"]["timeline"]["text"] = "Today\n" + CAL_TITLE + "\n" + LIVE[0]["summary"] + "\n"
want = probe.DECLARED[1]
row = [ok for n, ok, _ in probe.judge(good) if n == want]
check("judge: only verbatim calendar dashes on the Timeline -> PASS", row == [True], "got {}".format(row))
bad = probe._good()
bad["timeline_api_entries"] = api_entries
bad["timeline_rows"] = good["timeline_rows"]
bad["screens"]["timeline"]["text"] = good["screens"]["timeline"]["text"] + ostler_title + "\n"
row = [ok for n, ok, _ in probe.judge(bad) if n == want]
check("judge: a dash in an Ostler-composed title on the SAME screen -> FAIL", row == [False],
      "got {}".format(row))

print("{} fail".format(len(FAILS)))
sys.exit(1 if FAILS else 0)
