"""The Doctor's routine table reads each routine's own surfaces (v1.0.106).

Andy, 2026-09-28, second time of asking: a Doctor table of which sources are
in, which run on a routine, when each last ran, and whether it works. The
existing /api/v1/sources said email and iMessage were "no_data 0" on the
v1.0.105 walk box while their own routines had read 11,507 emails and every
iMessage. vendor/doctor/agent/routine_status.py reads the LaunchAgent plist,
launchd and the routine's log instead.

This EXECUTES read_routine_status() on a synthetic LaunchAgents dir and log
dir, with launchd stubbed per label, and checks every health branch and the
count parser. Synthetic data only.

EXIT CODES   0 all pass   1 a check failed   2 CANNOT-RUN
"""
import os
import plistlib
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
AGENT = Path(sys.argv[1]) if len(sys.argv) > 1 else REPO / "vendor" / "doctor" / "agent"
sys.path.insert(0, str(AGENT))
try:
    import routine_status as rs
except Exception as exc:
    print(f"CANNOT-RUN: could not import routine_status from {AGENT}: {exc}", file=sys.stderr)
    sys.exit(2)

fails = 0


def check(label, ok):
    global fails
    print(("  ok    " if ok else "  FAIL  ") + label)
    if not ok:
        fails += 1


with tempfile.TemporaryDirectory() as td:
    la, logs = Path(td) / "LaunchAgents", Path(td) / "logs"
    la.mkdir()
    logs.mkdir()
    labels = [r[0] for r in rs._ROUTINES]
    email_ingest, email_bundle, imsg, wa, spoken = labels[:5]

    def plist(label, interval):
        (la / f"{label}.plist").write_bytes(plistlib.dumps({"Label": label, "StartInterval": interval}))

    for lb in (email_ingest, email_bundle, imsg, wa, spoken):
        plist(lb, 900)
    (logs / "email-ingest.log").write_text("x\nEmitted 12 message(s) to /tmp/a\nEmitted 34 message(s) to /tmp/b\n")
    (logs / "whatsapp-bundle.log").write_text('noise\n{\n  "chats_scanned": 17,\n  "chats_dispatched": 16,\n  "ok": true\n}\n')
    (logs / "imessage-bundle.log").write_text('[ingest] {"imessage": {"status": "ok", "people_created": 7}}\n')
    (logs / "email-bundle.log").write_text("ran\n")
    old = time.time() - 5 * 3600
    os.utime(logs / "email-bundle.log", (old, old))
    # spoken-bundle: no log at all

    launchd = {
        email_ingest: {"loaded": True, "running": False, "last_exit": 0},
        email_bundle: {"loaded": True, "running": False, "last_exit": 0},
        imsg: {"loaded": True, "running": False, "last_exit": 78},
        wa: {"loaded": True, "running": False, "last_exit": 0},
        spoken: {"loaded": False, "running": False, "last_exit": None},
    }
    rs._launchd_state = lambda label: launchd.get(label, {"loaded": False, "running": False, "last_exit": None})
    rows = {r["routine"]: r for r in rs.read_routine_status(launch_dir=la, log_dir=logs)}

    check("every declared routine has a row", len(rows) == len(rs._ROUTINES))
    check("interval read from the plist", rows[email_ingest]["interval_s"] == 900)
    check("a recent clean run is ok", rows[email_ingest]["health"] == "ok")
    check("'Emitted N' gives the LAST run's count", rows[email_ingest]["latest"] == {"emitted": 34})
    check("pretty JSON counts parsed, booleans dropped",
          rows[wa]["latest"] == {"chats_scanned": 17, "chats_dispatched": 16})
    check("nested JSON counts flattened", rows[imsg]["latest"].get("imessage.people_created") == 7)
    check("a non-zero last exit is failing, with the code",
          rows[imsg]["health"] == "failing" and "78" in rows[imsg]["reason"])
    check("no run for 5 h on a 15 min routine is stale", rows[email_bundle]["health"] == "stale")
    check("not loaded in launchd is failing", rows[spoken]["health"] == "failing")
    missing = labels[5]
    check("no plist is not_installed", rows[missing]["health"] == "not_installed")
    check("last_run_at is an ISO timestamp", str(rows[email_ingest]["last_run_at"]).startswith("20"))

print(f"\n{'PASS' if fails == 0 else 'FAIL'}: {fails} failed")
sys.exit(1 if fails else 0)
