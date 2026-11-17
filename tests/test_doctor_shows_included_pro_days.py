#!/usr/bin/env python3
"""The Doctor tells the owner how many days of Ostler Pro are left: 180, 90 or 0.

END TO END THROUGH THE SHIPPED PIECES. The real vendored subscription gate
(vendor/cm041/assistant_api/subscription_gate.py, activate_included_pro) writes
subscription_state.json for a founding licence, a standard licence and no
licence; the real vendored Doctor (vendor/doctor/agent, collect_licence_state
and check_licence_state, taken at the 134 doctor re-pin) reads it back. The
customer-facing line is "Days of Ostler Pro left: N."

MONEY. A wrong number tells a customer they bought less, or more, than they
did. Same window as the included-Pro fix (CM051 #3579 family).

THREE STATES: exit 0 pass, 1 fail, 2 cannot-run. Synthetic dates only.
"""
import importlib
import json
import os
import pathlib
import sys
import tempfile
from datetime import datetime, timedelta, timezone

REPO = pathlib.Path(__file__).resolve().parent.parent
GATE_DIR = REPO / "vendor" / "cm041" / "assistant_api"
DOCTOR_DIR = REPO / "vendor" / "doctor" / "agent"
PURCHASE = datetime(2026, 1, 5, 9, 30, tzinfo=timezone.utc)
PASS, FAIL = [], []


def ok(m):
    PASS.append(m)
    print("  [PASS] " + m)


def bad(m):
    FAIL.append(m)
    print("  [FAIL] " + m)


def cant(m):
    print("CANNOT-RUN: " + m, file=sys.stderr)
    sys.exit(2)


sys.path[:0] = [str(GATE_DIR), str(DOCTOR_DIR)]
try:
    gate = importlib.import_module("subscription_gate")
    S = importlib.import_module("status_collector")
    D = importlib.import_module("diagnostic_rules")
except Exception as exc:  # noqa: BLE001
    cant("could not import the gate or the Doctor: %s: %s" % (type(exc).__name__, exc))

for name in ("collect_licence_state", "SystemSnapshot"):
    if not hasattr(S, name):
        bad("the vendored Doctor has no %s, so no licence row can exist" % name)
if not hasattr(D, "check_licence_state"):
    bad("the vendored Doctor has no check_licence_state rule")
elif D.check_licence_state not in D.ALL_RULES:
    bad("check_licence_state exists but is not in ALL_RULES, so it never runs")
else:
    ok("check_licence_state is registered in ALL_RULES")
# WIRED, not only present: the snapshot every Doctor page renders from must
# call the licence collector, or the rule only ever sees None.
import inspect  # noqa: E402
_full = inspect.getsource(S.collect_full_snapshot)
if "collect_licence_state()" in _full and "licence_state=licence_state" in _full:
    ok("collect_full_snapshot reads the licence state into the snapshot")
else:
    bad("collect_full_snapshot never calls collect_licence_state, so the row is unwired")
if FAIL:
    print("\n== %d pass / %d fail ==" % (len(PASS), len(FAIL)))
    sys.exit(1)

CASES = (
    # label, included_plan, tier_state, expected days
    ("founding licence", "founding", gate.TIER_STATE_ABSENT, 180),
    ("standard licence", "standard", gate.TIER_STATE_ABSENT, 90),
    ("no licence", None, gate.TIER_STATE_UNVERIFIED, 0),
)

with tempfile.TemporaryDirectory() as tmp:
    for label, plan, tier_state, want in CASES:
        state = pathlib.Path(tmp) / (label.replace(" ", "_") + ".json")
        os.environ["OSTLER_SUBSCRIPTION_STATE"] = str(state)
        gate.activate_included_pro(
            purchase_date_iso=PURCHASE.isoformat().replace("+00:00", "Z"),
            licence_tier_state=tier_state, included_plan=plan)
        lic = S.collect_licence_state(now=PURCHASE)
        if lic is None:
            # No licence may leave no file at all; the Doctor must still not
            # claim a window. Absent reads as no row, which is 0 by omission:
            # say which it was.
            if want == 0:
                ok("%s: no state written, so the Doctor claims no Pro days" % label)
            else:
                bad("%s: the gate wrote nothing the Doctor could read" % label)
            continue
        findings = D.check_licence_state(S.SystemSnapshot(licence_state=lic))
        blob = " ".join(f.get("detail", "") for f in findings)
        line = "Days of Ostler Pro left: %d." % want
        if line in blob and blob.count("Days of Ostler Pro left") == 1:
            ok("%s: the Doctor reads '%s' (gate wrote status=%s, %s)"
               % (label, line, json.loads(state.read_text()).get("status"),
                  "included_days=%s" % json.loads(state.read_text()).get("included_days")))
        else:
            bad("%s: expected '%s' once, the Doctor said %r" % (label, line, blob))

    # 0 FROM A RECORD. With no licence the gate writes no record, and the
    # Doctor deliberately shows no licence row for an absent record (absent is
    # not inactive). The 0 a customer can read comes from a record the gate
    # wrote: a standard window walked past its end by the gate's own
    # expire_check (never paid, so no grace) reads inactive, and the Doctor
    # must say 0, whatever days the stale expiry would compute to.
    state = pathlib.Path(tmp) / "standard_after_window.json"
    os.environ["OSTLER_SUBSCRIPTION_STATE"] = str(state)
    gate.activate_included_pro(
        purchase_date_iso=PURCHASE.isoformat().replace("+00:00", "Z"),
        licence_tier_state=gate.TIER_STATE_ABSENT, included_plan="standard")
    later = PURCHASE + timedelta(days=200)
    real_now = gate._now
    gate._now = lambda: later
    try:
        gate.expire_check()
    finally:
        gate._now = real_now
    status = json.loads(state.read_text()).get("status")
    lic = S.collect_licence_state(now=later)
    blob = " ".join(f.get("detail", "") for f in
                    D.check_licence_state(S.SystemSnapshot(licence_state=lic)))
    if status == "inactive" and "Days of Ostler Pro left: 0." in blob:
        ok("standard licence after its window: gate wrote inactive, the Doctor reads 'Days of Ostler Pro left: 0.'")
    else:
        bad("standard licence after its window: gate status %r, the Doctor said %r" % (status, blob))

print("\n== %d pass / %d fail / %d total ==" % (len(PASS), len(FAIL), len(PASS) + len(FAIL)))
if len(PASS) + len(FAIL) < 6:
    cant("only %d checks ran" % (len(PASS) + len(FAIL)))
sys.exit(1 if FAIL else 0)
