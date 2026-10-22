#!/usr/bin/env python3
"""The Doctor shows whether "What you like" has a producer, and what it left.

Mirrors the "Where your data came from" table for the one thing that table
cannot show: the recurring preference-derivation agent. Proves:

  1. every state is distinct on the page: not scheduled, scheduled but not run,
     written (with the node count), empty, not written, cannot start,
     unreadable. "Could not check" and "nothing" never print the same.
  2. WRITER/READER VOCABULARY. Every outcome the SHIPPED runner
     (vendor/cm019_preferences/services/enrich/src/derive_runner.py) can write
     is one the Doctor knows. Read from the runner's source, so a new outcome
     there with no word here goes red.
  3. the node count shown is the runner's graph count, and an empty run shows 0,
     not a dash: an honest zero is a measurement.
  4. no preference value can reach the page: the row prints counts and the
     runner's reason only.
  5. web_ui.py actually renders it: import, call and placeholder are all
     present (a vendor-only module nobody renders is the defect this repo keeps
     finding).

Synthetic only. Run bare: ``python3 tests/test_doctor_shows_derived_preferences_status.py``.
"""

import json
import plistlib
import re
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
AGENT = REPO / "vendor" / "doctor" / "agent"
RUNNER = REPO / "vendor" / "cm019_preferences" / "services" / "enrich" / "src" / "derive_runner.py"
sys.path.insert(0, str(AGENT))

import derived_preferences_status as dps  # noqa: E402

FAILS = []


def check(cond, msg):
    print(("  ok   " if cond else "  FAIL ") + msg)
    if not cond:
        FAILS.append(msg)


def _files(tmp: Path, record=None, scheduled=True, raw=None):
    plist = tmp / "agent.plist"
    status = tmp / "derived-preferences.json"
    if scheduled:
        plist.write_bytes(plistlib.dumps({"Label": dps.LABEL, "StartInterval": 21600}))
    if raw is not None:
        status.write_text(raw)
    elif record is not None:
        status.write_text(json.dumps(record))
    return status, plist


def state(tmp, **kw):
    status, plist = _files(tmp, **kw)
    return dps.read_derived_preferences_status(status_file=status, plist_file=plist)


def main() -> int:
    print("1: every state is distinct")
    seen = {}
    cases = {
        "not_scheduled": dict(scheduled=False),
        "not_run": dict(),
        "written": dict(record={"outcome": "written", "graph_node_count": 7,
                                "last_run_at": "2026-10-17T06:00:00Z"}),
        "empty": dict(record={"outcome": "empty", "graph_node_count": 0}),
        "not_written": dict(record={"outcome": "not_written", "graph_node_count": 7,
                                    "reason": "a reader failed; the previous derived graph was kept"}),
        "cannot_start": dict(record={"outcome": "cannot_start", "reason": "missing dependency"}),
        "unreadable": dict(raw="{not json"),
    }
    for want, kw in cases.items():
        with tempfile.TemporaryDirectory() as t:
            st = state(Path(t), **kw)
            check(st["status"] == want, f"{want}: read as {st['status']}")
            html_ = dps.render_derived_preferences_status(st)
            seen[want] = re.search(r'<span style="color:[^"]+">([^<]+)</span>', html_).group(1)
    check(len(set(seen.values())) == len(seen), f"{len(seen)} states, {len(set(seen.values()))} distinct words: {seen}")
    with tempfile.TemporaryDirectory() as t:
        st = state(Path(t))
        check(st["interval_s"] == 21600 and "every 6 hours" in dps.render_derived_preferences_status(st),
              "the cadence is read from the plist")

    with tempfile.TemporaryDirectory() as t:
        st = state(Path(t), scheduled=False, record={"outcome": "written", "graph_node_count": 7})
        check(st["status"] == "not_scheduled" and st["node_count"] == 7,
              "an old record with no agent reads as not scheduled, never up to date")

    print("2: every outcome the shipped runner writes is one the Doctor knows")
    src = RUNNER.read_text()
    outcomes = set(re.findall(r'"outcome"\]?\s*[:=]\s*"([a-z_]+)"', src))
    outcomes |= set(re.findall(r'status\["outcome"\] = "([a-z_]+)" if', src))
    outcomes |= set(re.findall(r'else "([a-z_]+)"\n', src))
    check(len(outcomes) >= 4, f"control: found {len(outcomes)} outcome literal(s) in the runner: {sorted(outcomes)}")
    for o in sorted(outcomes):
        with tempfile.TemporaryDirectory() as t:
            st = state(Path(t), record={"outcome": o, "graph_node_count": 1})
            check(st["status"] != "unreadable", f"runner outcome {o!r} -> Doctor state {st['status']!r}")

    print("3: the count is the runner's graph count, and zero is a measurement")
    with tempfile.TemporaryDirectory() as t:
        h = dps.render_derived_preferences_status(state(Path(t), record={"outcome": "written", "graph_node_count": 7}))
        check('<td style="text-align:right">7</td>' in h, "written shows 7")
        h = dps.render_derived_preferences_status(state(Path(t), record={"outcome": "empty", "graph_node_count": 0}))
        check('<td style="text-align:right">0</td>' in h, "empty shows 0, not a dash")
    with tempfile.TemporaryDirectory() as t:
        h = dps.render_derived_preferences_status(state(Path(t), raw="{not json"))
        check('<td style="text-align:right">&mdash;</td>' in h, "unreadable shows a dash, never 0")

    print("4: no preference value reaches the page")
    with tempfile.TemporaryDirectory() as t:
        rec = {"outcome": "written", "graph_node_count": 2,
               "items": ["SYNTHETIC-TASTE-CANARY"], "label": "SYNTHETIC-TASTE-CANARY"}
        h = dps.render_derived_preferences_status(state(Path(t), record=rec))
        check("SYNTHETIC-TASTE-CANARY" not in h, "a stray field in the record is not rendered")
        h = dps.render_derived_preferences_status(
            state(Path(t), record={"outcome": "not_written", "reason": "<b>x</b>"}))
        check("<b>x</b>" not in h and "&lt;b&gt;" in h, "the runner's reason is escaped")

    print("5: web_ui.py renders it")
    ui = (AGENT / "web_ui.py").read_text()
    check("from derived_preferences_status import render_derived_preferences_status" in ui, "import")
    check(re.search(r"^\s+derived_preferences_section = render_derived_preferences_status\(\)$", ui, re.M) is not None, "call")
    check("{derived_preferences_section}" in ui, "placeholder in the dashboard HTML")
    vo = (REPO / "vendor" / "VENDOR_ONLY.tsv").read_text()
    check("doctor/agent/derived_preferences_status.py\t" in vo, "declared vendor-only, so a sync restores it")

    print(f"\n{'FAILED: ' + str(len(FAILS)) if FAILS else 'all passed'}")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
