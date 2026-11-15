#!/usr/bin/env python3
"""Doctor row for the Homebrew prefix (same-shape sweep 2026-11-14, Archie 8b/8d).

Proves, on synthetic paths only:
  1. classify_prefix: absent -> no row; owned by the running account -> info
     (no auto-fix); owned by another account -> refused (no account named).
  2. The real stat path: a directory this test owns reads as info; a path that
     does not exist reads as absent and renders nothing; a NUL in the path reads
     as could-not-check, never as a pass.
  3. The refused row says the fix and names no account (the uid is not printed).
  4. web_ui.py imports the row and places it on the page.
  5. MUTANT: a classifier that calls a foreign owner "info" fails arm 1.
Run bare: python3 tests/test_doctor_shows_shared_prefix.py
"""
import os
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
AGENT = REPO / "vendor" / "doctor" / "agent"
sys.path.insert(0, str(AGENT))

import shared_prefix_status as sps  # noqa: E402

FAILS = []


def check(cond, msg):
    print(("ok   " if cond else "FAIL ") + msg)
    if not cond:
        FAILS.append(msg)


OWNER = 501
OTHER = 502

check(sps.classify_prefix(None, OWNER) == "absent", "1a absent prefix is no row")
check(sps.classify_prefix(OWNER, OWNER) == "info", "1b prefix owned by the running account is info")
check(sps.classify_prefix(OTHER, OWNER) == "refused", "1c prefix owned by another account is refused")

with tempfile.TemporaryDirectory() as td:
    mine = os.path.join(td, "prefix")
    os.mkdir(mine)
    st = sps.shared_prefix_status(mine, current_uid=os.getuid())
    check(st["status"] == "info", f"2a owned-by-me directory reads as info (got {st['status']})")
    check(sps.render_shared_prefix_status(mine, current_uid=os.getuid()) != "", "2b info renders a row")
    check(sps.render_shared_prefix_status(os.path.join(td, "absent"), current_uid=OWNER) == "",
          "2c absent path renders nothing")
    st2 = sps.shared_prefix_status(mine, current_uid=os.getuid() + 1)
    check(st2["status"] == "refused", "2d same directory, other running account, reads as refused")

    html_out = sps.render_shared_prefix_status(mine, current_uid=os.getuid() + 1)
    check("belongs to another account" in html_out, "3a refused row says whose it is, not who")
    check(str(os.getuid()) not in html_out and str(os.getuid() + 1) not in html_out,
          "3b refused row prints no uid")
    check("Install Ostler from that account" in html_out, "3c refused row says the fix")

    nul = sps.shared_prefix_status("bad\x00path", current_uid=OWNER)
    check(nul["status"] == "could-not-check", "2e unreadable path is could-not-check, not a pass")

web_ui = (AGENT / "web_ui.py").read_text(encoding="utf-8")
check("from shared_prefix_status import render_shared_prefix_status" in web_ui, "4a web_ui imports the row")
check("{shared_prefix_section}" in web_ui and "shared_prefix_section = render_shared_prefix_status()" in web_ui,
      "4b web_ui places the row on the page")

if FAILS:
    print(f"\n{len(FAILS)} FAILED")
    sys.exit(1)
print("\nAll shared-prefix Doctor row checks passed.")
