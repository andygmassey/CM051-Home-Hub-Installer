#!/usr/bin/env python3
"""v1.0.108 Leak C Doctor surface: a tick that FAILED CLOSED on a missing/
erroring subscription gate must light Doctor RED, and a healthy Hub must
stay silent.

Both directions, plus the controls that keep the rule honest (ok markers,
an absent dir, and a malformed marker all produce NO red). Synthetic, tmp
OSTLER_HOME, read-only rule. No real Hub.
"""
import json
import os
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "vendor" / "doctor" / "agent"))

try:
    import diagnostic_rules as dr
except ImportError as exc:
    print("CANNOT-RUN: cannot import diagnostic_rules (%s)" % exc)
    sys.exit(99)

HOME = Path(tempfile.mkdtemp())
os.environ["OSTLER_HOME"] = str(HOME)
POSTURE = HOME / ".ostler" / "state" / "gate_posture"

fails = []


def check(label, ok):
    print(("  ok    " if ok else "  FAIL  ") + label)
    if not ok:
        fails.append(label)


def _write(surface, payload):
    POSTURE.mkdir(parents=True, exist_ok=True)
    (POSTURE / (surface + ".json")).write_text(json.dumps(payload))


def _clear():
    import shutil
    shutil.rmtree(POSTURE, ignore_errors=True)


# ── Direction 1: a gate_unavailable marker -> exactly one RED finding ──
_clear()
_write("imessage", {"surface": "imessage", "status": "gate_unavailable",
                     "detail": "gate module not found", "at": "2026-10-17T00:00:00Z"})
f = dr.check_subscription_gate_health(None)
check("gate_unavailable -> exactly one finding", len(f) == 1)
if f:
    check("the finding is critical (RED)", f[0]["severity"] == "critical")
    check("category is ingest", f[0]["category"] == "ingest")
    check("surface named in the row", "imessage" in f[0]["title"])
    check("row reassures data is untouched", "untouched" in f[0]["detail"].lower())

# ── Direction 2: an 'ok' marker -> NO finding (healthy Hub is silent) ──
_clear()
_write("imessage", {"surface": "imessage", "status": "ok", "detail": "", "at": "x"})
check("ok marker -> no finding", dr.check_subscription_gate_health(None) == [])

# ── Control: no directory at all -> no finding ──
_clear()
check("absent posture dir -> no finding", dr.check_subscription_gate_health(None) == [])

# ── Control: malformed marker -> skipped, no crash, no finding ──
_clear()
POSTURE.mkdir(parents=True, exist_ok=True)
(POSTURE / "email.json").write_text("{not json")
check("malformed marker -> no finding, no raise", dr.check_subscription_gate_health(None) == [])

# ── Direction 1b: two failing surfaces -> two RED findings ──
_clear()
_write("imessage", {"surface": "imessage", "status": "gate_unavailable", "detail": "d", "at": "x"})
_write("email_ingest", {"surface": "email_ingest", "status": "gate_unavailable", "detail": "d", "at": "x"})
two = dr.check_subscription_gate_health(None)
check("two failing surfaces -> two findings", len(two) == 2)
check("both are critical", all(x["severity"] == "critical" for x in two))

# ── Wiring control: the rule is actually in ALL_RULES (run on every poll) ──
check("rule is registered in ALL_RULES", dr.check_subscription_gate_health in dr.ALL_RULES)

print("FAIL" if fails else "PASS")
sys.exit(1 if fails else 0)
