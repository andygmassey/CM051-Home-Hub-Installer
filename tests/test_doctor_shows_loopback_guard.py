#!/usr/bin/env python3
"""Doctor and the Hub read the v1.0.126 loopback guard's status file.

The guard daemon (lib/ostler-loopback-guard.sh) writes key=value lines to a
root-owned status file every 300 s. Before this, only walk probe 3c looked at
the guard; nothing a customer sees did. Proves:

  1. three answers, never two: a fresh ok is ``active``; the daemon's fail is
     ``not-active`` WITH its reason; missing, stale, timeless or an unknown
     verdict is ``could-not-check``. No current answer is never a pass.
  2. the Doctor page renders the tile: import, call and placeholder in
     web_ui.py, and the rendered text differs per state.
  3. the Hub's feed: box_status.box_status() carries ``privacy_guard``, read
     from the same file (the Hub reads /api/v1/box-status through its proxy).
  4. MUTANT: a reader that ignores the age reads a stale ok as active, and arm
     1 goes red on it.

The status files written by the REAL shell lib are read by this reader in
tests/test_loopback_guard.sh (both sides of the contract). Synthetic only.
Run bare: ``python3 tests/test_doctor_shows_loopback_guard.py``.
"""

import os
import re
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
AGENT = REPO / "vendor" / "doctor" / "agent"
sys.path.insert(0, str(AGENT))

import loopback_guard_status as lgs  # noqa: E402

FAILS = []


def check(cond, msg):
    print(("ok   " if cond else "FAIL ") + msg)
    if not cond:
        FAILS.append(msg)


def write(d, body):
    p = os.path.join(d, "status")
    with open(p, "w", encoding="utf-8") as fh:
        fh.write(body)
    return p


def states(reader):
    now = time.time()
    out = {}
    with tempfile.TemporaryDirectory() as d:
        cases = {
            "fresh_ok": f"verdict=ok\nreason=none\nassistant_uid=none\nchecked_at={int(now) - 60}\n",
            "fresh_fail": f"verdict=fail\nreason=anchor_rules_mismatch(4/6)\nchecked_at={int(now) - 60}\n",
            "stale_ok": f"verdict=ok\nreason=none\nchecked_at={int(now) - 3600}\n",
            "no_time": "verdict=ok\n",
            "odd_verdict": f"verdict=maybe\nchecked_at={int(now)}\n",
        }
        for name, body in cases.items():
            os.environ["OSTLER_LG_STATUS_FILE"] = write(d, body)
            out[name] = reader(now)
        os.environ["OSTLER_LG_STATUS_FILE"] = os.path.join(d, "absent")
        out["missing"] = reader(now)
    return out


s = states(lgs.read_loopback_guard)
check(s["fresh_ok"]["status"] == "active", "a fresh ok is active")
check(s["fresh_fail"]["status"] == "not-active" and "anchor_rules_mismatch" in s["fresh_fail"]["reason"],
      "the daemon's fail is not-active and carries its reason")
for k in ("stale_ok", "no_time", "odd_verdict", "missing"):
    check(s[k]["status"] == "could-not-check" and s[k].get("reason"), f"{k} is could-not-check with a reason, never active")

# 2. the page
src = (AGENT / "web_ui.py").read_text(encoding="utf-8")
check("from loopback_guard_status import render_loopback_guard_status" in src, "web_ui imports the tile")
check(re.search(r"loopback_guard_section = render_loopback_guard_status\(\)", src) is not None, "web_ui calls it")
check("{loopback_guard_section}" in src, "web_ui places it on the page")
with tempfile.TemporaryDirectory() as d:
    os.environ["OSTLER_LG_STATUS_FILE"] = write(d, f"verdict=ok\nchecked_at={int(time.time())}\n")
    on = lgs.render_loopback_guard_status()
    os.environ["OSTLER_LG_STATUS_FILE"] = write(d, f"verdict=fail\nreason=pf_not_enabled\nchecked_at={int(time.time())}\n")
    off = lgs.render_loopback_guard_status()
    os.environ["OSTLER_LG_STATUS_FILE"] = os.path.join(d, "absent")
    unk = lgs.render_loopback_guard_status()
check(">On<" in on and "Off:" in off and "pf_not_enabled" in off and "Could not check" in unk,
      "rendered text differs per state (On / Off with reason / Could not check)")
check("border-left" not in on + off + unk, "no left-border callout in the tile")

# 3. the Hub's feed
import box_status  # noqa: E402

with tempfile.TemporaryDirectory() as d:
    os.environ["OSTLER_LG_STATUS_FILE"] = write(d, f"verdict=fail\nreason=pf_not_enabled\nchecked_at={int(time.time())}\n")
    pg = box_status._privacy_guard()
check(pg.get("status") == "not-active" and pg.get("reason") == "pf_not_enabled", "box-status privacy_guard reads the same file")
bsrc = (AGENT / "box_status.py").read_text(encoding="utf-8")
check('"privacy_guard": _privacy_guard(),' in bsrc, "box_status() payload carries privacy_guard")


# 4. MUTANT: ignore the age -> a stale ok reads active, and arm 1 must catch it
def ignores_age(now=None):
    saved = lgs.STATUS_MAX_AGE_SECONDS
    lgs.STATUS_MAX_AGE_SECONDS = 10 ** 9
    try:
        return lgs.read_loopback_guard(now)
    finally:
        lgs.STATUS_MAX_AGE_SECONDS = saved


m = states(ignores_age)
check(m["stale_ok"]["status"] == "active", "MUTANT ignores_age reads a stale ok as active (arm 1 would go red)")

os.environ.pop("OSTLER_LG_STATUS_FILE", None)
print(f"{'PASS' if not FAILS else 'FAIL'}: {len(FAILS)} failure(s)")
sys.exit(1 if FAILS else 0)
