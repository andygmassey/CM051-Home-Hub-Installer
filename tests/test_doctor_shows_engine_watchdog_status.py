#!/usr/bin/env python3
"""The Doctor's "Background engine" row reads the supervisor's logind record.

Proves, against synthetic records written to a temp dir:
  1. a restart shows the restart time, in the words the customer sees.
  2. a healthy check with no restart shows "running normally".
  3. a check that could not run, a missing record, an unreadable record and a
     stale record all show "couldn't check". None of them ever shows "running".
  4. a timed-out or unparseable probe (CANNOT-RUN) is never read as healthy.
  5. web_ui.py actually renders the row: import, call and placeholder present.

Run bare: ``python3 tests/test_doctor_shows_engine_watchdog_status.py``.
Exit 0 = all pass. Synthetic data only.
"""

import json
import os
import sys
import tempfile
import time
import calendar

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "vendor", "doctor", "agent"))
import engine_watchdog_status as ew  # noqa: E402

FAILS = []
PASSES = []


def check(name, ok, detail=""):
    (PASSES if ok else FAILS).append(name)
    print(("  [pass] " if ok else "  [FAIL] ") + name + ("" if ok or not detail else " -- " + detail))


def iso(epoch):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


_N = [0]


def record(d, verdict, checked, last_restart=0):
    # One file per record: every case must read its own file, never a neighbour's.
    _N[0] += 1
    p = os.path.join(d, "logind_health_%d.json" % _N[0])
    with open(p, "w", encoding="utf-8") as fh:
        json.dump({"verdict": verdict, "action": "restarted" if last_restart else "none",
                   "detail": "x", "checked": checked, "last_restart_epoch": last_restart}, fh)
    return p


def row(path, now):
    return ew.render_engine_watchdog_status(ew.read_engine_watchdog_status(path, now=now))


NOW = time.time()
RESTART_AT = int(NOW - 120)

with tempfile.TemporaryDirectory(prefix="doctor-engine-") as d:
    # 1. restarted: the time shown is the recorded restart time.
    p = record(d, "HEALTHY", iso(NOW), last_restart=RESTART_AT)
    html_out = row(p, NOW)
    expect = time.strftime("%H:%M on %d %b", time.localtime(RESTART_AT))
    check("restart shows 'a system service was stuck and was restarted at'",
          "a system service was stuck and was restarted at" in html_out, html_out)
    check("the restart time shown is the recorded restart time",
          expect in html_out, "expected %r in row" % expect)

    # 2. healthy, no restart.
    p = record(d, "HEALTHY", iso(NOW))
    out = row(p, NOW)
    check("healthy with no restart shows 'running normally'", "running normally" in out, out)

    # 3. couldn't check: CANNOT-RUN, missing, unreadable, stale. Never "running".
    cases = {
        "CANNOT-RUN record": record(d, "CANNOT-RUN", iso(NOW)),
        "missing record": os.path.join(d, "absent.json"),
    }
    bad = os.path.join(d, "garbage.json")
    with open(bad, "w") as fh:
        fh.write("{not json")
    cases["unreadable record"] = bad
    cases["stale record"] = record(d, "HEALTHY", iso(NOW - 3600))
    for name, path in cases.items():
        out = row(path, NOW)
        check("%s shows 'couldn't check'" % name, "couldn't check" in out, out)
        check("%s never shows 'running normally'" % name, "running normally" not in out, out)

    # 4. a probe that timed out or was unparseable is CANNOT-RUN, never HEALTHY.
    p = record(d, "CANNOT-RUN", iso(NOW), last_restart=0)
    st = ew.read_engine_watchdog_status(p, now=NOW)
    check("CANNOT-RUN is read as cannot_check, not running", st["state"] == "cannot_check", str(st))

    # 5. web_ui.py renders it.
    web = open(os.path.join(REPO, "vendor", "doctor", "agent", "web_ui.py"), encoding="utf-8").read()
    check("web_ui imports render_engine_watchdog_status",
          "from engine_watchdog_status import render_engine_watchdog_status" in web)
    check("web_ui calls render_engine_watchdog_status()",
          "engine_watchdog_section = render_engine_watchdog_status()" in web)
    check("web_ui places {engine_watchdog_section} on the page",
          "{engine_watchdog_section}" in web)

print("\ndoctor engine watchdog row: %d passed, %d failed" % (len(PASSES), len(FAILS)))
sys.exit(1 if FAILS else 0)
