#!/usr/bin/env python3
"""hub_screens: the timeline "rows are not all one type" arm compares the
screen with what the box actually holds.

Walk33 (v1.0.112, L972) and walk34 (v1.0.113) FAILed this arm with
kinds=['event']: the walk seed holds only calendar events (mail, iMessage and
WhatsApp have 0 items on a fresh walk account), so one kind on screen is the
CORRECT picture. The arm assumed diversity. It now reads the kinds the Hub's
own timeline API holds (facts["timeline"]["box_kinds"]).

Cases (synthetic data only):
  box one kind, screen one kind     -> PASS  (red on the pre-fix lib)
  box 3 kinds, screen one kind      -> FAIL  (the real regression the arm exists for)
  box 3 kinds, screen 3 kinds       -> PASS
  box kinds unknown / error / empty -> None (NOT MEASURED), never PASS
  timeline_api_kinds: good body, 401, non-JSON, no items list

Run against another copy of the lib with HUB_SCREENS_LIB=<path> (the red
control: origin/main before this change fails the one-kind case).

Exit 0 pass, 1 fail.
"""
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.environ.get("HUB_SCREENS_LIB") or os.path.join(
    HERE, "..", "scripts", "box_walk_probes", "lib", "hub_screens.py")
spec = importlib.util.spec_from_file_location("hub_screens", LIB)
hs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hs)

ARM = "timeline: rows are not all one type"
fails = 0


def check(label, cond, detail=""):
    global fails
    print("  {} {}{}".format("ok  " if cond else "FAIL", label, "" if cond else "  -- " + detail))
    if not cond:
        fails += 1


def arm(kinds_on_screen, **box):
    f = hs._good()
    rows = [{"kind": kinds_on_screen[i % len(kinds_on_screen)], "day": "2026-09-20",
             "title": "t%d" % i} for i in range(45)]
    f["timeline"].pop("box_kinds", None)
    f["timeline"].update(rows=rows, **box)
    got = [(ok, d) for n, ok, d in hs.judge(f) if n == ARM]
    assert len(got) == 1, got
    return got[0]


print("timeline kinds arm compares the screen with the box")
ok, d = arm(["event"], box_kinds=["event"])
check("box one kind + screen one kind = PASS", ok is True, d)
check("  detail names the box kind", "box holds one kind (event)" in d, d)
ok, d = arm(["event"], box_kinds=["event", "mail", "message"])
check("box 3 kinds + screen one kind = FAIL", ok is False, "ok={!r} {}".format(ok, d))
check("  detail carries both sets", "mail" in d and "event" in d, d)
ok, d = arm(["event", "mail", "message"], box_kinds=["event", "mail", "message"])
check("box 3 kinds + screen 3 kinds = PASS", ok is True, d)
for label, kw in (("box_kinds missing", {}),
                  ("box_kinds_error", {"box_kinds_error": "HTTP 401"}),
                  ("box_kinds empty", {"box_kinds": []})):
    ok, d = arm(["event"], **kw)
    check("{} = NOT MEASURED (None)".format(label), ok is None and "NOT MEASURED" in d,
          "ok={!r} {}".format(ok, d))

import json
check("timeline_api_kinds good body",
      hs.timeline_api_kinds(200, json.dumps({"items": [{"kind": "event"}, {"kind": "mail"}, {}]}))
      == {"box_kinds": ["event", "mail"]})
for label, st, body in (("401", 401, "{}"), ("non-JSON", 200, "x"), ("no items", 200, "{}")):
    check("timeline_api_kinds " + label + " is an error, not an empty list",
          "box_kinds_error" in hs.timeline_api_kinds(st, body))

print("{} failure(s)".format(fails))
sys.exit(1 if fails else 0)
