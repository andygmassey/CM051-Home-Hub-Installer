#!/usr/bin/env python3
"""The Doctor's "Background engine" row: customer words, local time, escalation.

Synthetic records only. Proves, through the REAL module:
  1. a heal shows "restarted a stuck background service at HH:MM" in local time,
     with the count when there is more than one today.
  2. an escalated record shows "needs attention".
  3. a healthy record with no heal today shows "running normally".
  4. a missing, unreadable, stale or CANNOT-RUN record shows "couldn't check",
     never "running normally".
  5. customer copy names no internals (no logind, systemd, colima, VM, probe).
  6. web_ui.py imports, calls and places the row.

Run bare: python3 tests/test_doctor_shows_engine_watchdog_status.py
"""

import json
import os
import re
import sys
import tempfile
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "vendor", "doctor", "agent"))
import engine_watchdog_status as ew  # noqa: E402

FAILS, PASSES = [], []
INTERNALS = re.compile(r"logind|systemd|colima|\bVM\b|supervisor|probe|tick|ssh", re.I)


def check(name, ok, detail=""):
    (PASSES if ok else FAILS).append(name)
    print(("  [pass] " if ok else "  [FAIL] ") + name + ("" if ok or not detail else " -- " + detail))


def iso(epoch):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


_N = [0]


def record(d, verdict, checked, heals=(), escalated=False):
    _N[0] += 1
    p = os.path.join(d, "rec_%d.json" % _N[0])
    with open(p, "w", encoding="utf-8") as fh:
        json.dump({"verdict": verdict, "action": "restarted" if heals else "none", "detail": "x",
                   "checked": checked, "last_restart_epoch": max(heals) if heals else 0,
                   "heal_epochs": " ".join(str(h) for h in heals), "escalated": escalated}, fh)
    return p


def row(path, now):
    return ew.render_engine_watchdog_status(ew.read_engine_watchdog_status(path, now=now))


NOW = time.time()
with tempfile.TemporaryDirectory(prefix="doctor-engine-") as d:
    p = record(d, "HEALTHY", iso(NOW), heals=[int(NOW - 120)])
    out = row(p, NOW)
    want = time.strftime("%H:%M", time.localtime(int(NOW - 120)))
    check("a heal shows 'restarted a stuck background service at HH:MM' in local time",
          "restarted a stuck background service at %s." % want in out, out)
    check("no internals in the customer copy for a heal", not INTERNALS.search(out), out)

    p = record(d, "HEALTHY", iso(NOW), heals=[int(NOW - 600), int(NOW - 120)])
    check("two heals today show the count", "(2 times today)" in row(p, NOW), row(p, NOW))

    p = record(d, "WEDGED", iso(NOW), heals=[int(NOW - 60)] * 3, escalated=True)
    out = row(p, NOW)
    check("an escalated record shows 'needs attention'", "needs attention" in out, out)
    check("escalated copy names no internals", not INTERNALS.search(out), out)

    p = record(d, "HEALTHY", iso(NOW))
    out = row(p, NOW)
    check("healthy, no heal today: 'running normally'", "running normally" in out, out)

    old = record(d, "HEALTHY", iso(NOW), heals=[int(NOW - 90000)])
    check("a heal older than 24 h does not show as today", "running normally" in row(old, NOW), row(old, NOW))

    cases = {
        "CANNOT-RUN record": record(d, "CANNOT-RUN", iso(NOW)),
        "stale record": record(d, "HEALTHY", iso(NOW - 3600)),
        "missing record": os.path.join(d, "absent.json"),
    }
    bad = os.path.join(d, "garbage.json")
    with open(bad, "w") as fh:
        fh.write("{not json")
    cases["unreadable record"] = bad
    for name, path in cases.items():
        out = row(path, NOW)
        check("%s: couldn't check" % name, "couldn't check" in out, out)
        check("%s: never 'running normally'" % name, "running normally" not in out, out)

    web = open(os.path.join(REPO, "vendor", "doctor", "agent", "web_ui.py"), encoding="utf-8").read()
    check("web_ui imports the row", "from engine_watchdog_status import render_engine_watchdog_status" in web)
    check("web_ui calls the row", "engine_watchdog_section = render_engine_watchdog_status()" in web)
    check("web_ui places the row", "{engine_watchdog_section}" in web)

print("\ndoctor engine watchdog row: %d passed, %d failed" % (len(PASSES), len(FAILS)))
sys.exit(1 if FAILS else 0)
