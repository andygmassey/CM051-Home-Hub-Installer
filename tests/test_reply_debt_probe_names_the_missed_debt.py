#!/usr/bin/env python3
"""When the reply-debt probe or the morning probe grades a brief and a waiting
person is MISSED, the evidence must say WHICH debt: name, shape, resolved flag, age.

v1.0.121 trial: the probe said "names the 2 people the Hub says are waiting (1 of
2)" and nothing about who. This drives the real box_reply_debt() and box_morning()
(Hub, chat, cron and store calls replaced by stand-ins at the module boundary) and
the real judges, with synthetic debts:
  - a SEED cast name (Jane Smith) WITH seed provenance (person_uri under the
    walk-fixture URN namespace) missed: the evidence line carries the name,
    its shape, resolved=True and the age
  - a cast-name string (Tom Jones) WITHOUT seed provenance: could be a real
    person, so "<not a seed name>" and shape only, never the name
  - a non-seed name (Ana Brown, cast tokens but not a seed fixture name) missed:
    the evidence carries the SHAPE and never the name
  - a raw number missed: shape "digits", the digits never printed
  - control: nothing missed, no MISSED text, judge passes

WOW_MOMENTS_SUBJECT=<path> points at another copy (the trial tree's, for RED).
Exit: 0 holds | 1 broken
"""
import importlib.util
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SUBJ = os.environ.get("WOW_MOMENTS_SUBJECT") or os.path.join(HERE, "..", "scripts", "box_walk_probes", "lib", "wow_moments.py")
spec = importlib.util.spec_from_file_location("wow_moments_subject", SUBJ)
w = importlib.util.module_from_spec(spec)
spec.loader.exec_module(w)

SEED = "Jane Smith"
NONSEED = "Ana Brown"
DIGITS = "+44 7700 900123"
COMMON = "Tom Jones"
DEBTS = [
    {"person_name": SEED, "person_uri": "urn:ostler-walk-fixture:wow7/jane", "resolved": True, "waiting_hours": 26.54, "privacy_level": "L1"},
    {"person_name": NONSEED, "resolved": True, "waiting_hours": 5, "privacy_level": "L1"},
    {"person_name": DIGITS, "resolved": True, "waiting_hours": 3.2, "privacy_level": "L1"},
]
COMMON_DEBTS = [
    {"person_name": COMMON, "person_uri": "urn:example:person:abc", "resolved": True, "waiting_hours": 7, "privacy_level": "L1"},
    {"person_name": COMMON, "resolved": True, "waiting_hours": 8, "privacy_level": "L1"},
]
fail = 0


def check(label, ok, detail=""):
    global fail
    print("  %s  %s%s" % ("ok  " if ok else "FAIL", label, "" if ok else "  [" + str(detail)[-260:] + "]"))
    fail += 0 if ok else 1


def judge_text(lines):
    return "\n".join(lines)


# ---- reply-debt probe, end to end through box_reply_debt + judge_reply_debt
def run_reply_debt(answer_text, debts):
    w._hub = lambda path: (200, {"degraded": False, "debts": debts})
    w.ws_chat = lambda q, deadline_s=420: (["pwg_reply_debt"], answer_text, None)
    w.unsaved_window_hours = lambda: 72
    cap = w.box_reply_debt()
    cap = json.loads(json.dumps(cap))     # what crosses the wire from the box
    lines, rc = w.judge_reply_debt(cap)
    return judge_text(lines), rc


out, rc = run_reply_debt("You owe a reply to nobody I know.", DEBTS)
check("reply debt: a missed debt is a FAIL", rc == w.EX_FAIL, rc)
check("reply debt: the missed SEED name is in the evidence", ("name=" + SEED) in out, out)
check("reply debt: its resolved flag and age are in the evidence", "resolved=True" in out and "age_h=26.5" in out, out)
check("reply debt: the seed debt's shape is in the evidence", "shape=2 words, latin" in out, out)
check("reply debt: a NON-seed name is never printed", NONSEED not in out and "Brown" not in out, out)
check("reply debt: a non-seed debt is reported by shape", "name=<not a seed name>" in out, out)
check("reply debt: a raw number is never printed, its shape is", "7700" not in out and "digits" in out, out)

out, rc = run_reply_debt("You owe a reply to nobody I know.", COMMON_DEBTS)
check("reply debt: a cast-name string WITHOUT seed provenance is not printed", COMMON not in out and "Jones" not in out, out)
check("reply debt: it is reported as <not a seed name> with its shape", out.count("name=<not a seed name>") == 2 and "shape=2 words, latin" in out, out)
seeded_common = [dict(COMMON_DEBTS[0], person_uri="urn:ostler-walk-fixture:wow7/tom")]
out, rc = run_reply_debt("You owe a reply to nobody I know.", seeded_common)
check("reply debt: the same name WITH seed provenance is printed", ("name=" + COMMON) in out, out)

out, rc = run_reply_debt("Waiting on you: %s, %s and %s." % (SEED, NONSEED, DIGITS), DEBTS)
check("control, reply debt: every debt named passes", rc == w.EX_PASS, out)
check("control, reply debt: no MISSED text when nothing is missed", "MISSED" not in out, out)

# ---- morning probe, end to end through box_morning + judge_morning
def run_morning(brief, debts):
    w._morning_prompt = lambda: "Write today's brief with promises."
    w._store_update = lambda sparql: 204

    def hub(path):
        if path.startswith("/api/v1/commitments"):
            return 200, {"commitments": [{"action": w.OWNER_PROMISE}]}
        if path.startswith("/api/v1/reply-debt"):
            return 200, {"degraded": False, "debts": debts}
        return 200, {"events": []}
    w._hub = hub

    def http(method, url, body=None, headers=None, timeout=30):
        if method == "POST":
            return 200, {"job": {"id": "j1"}}
        if method == "GET":
            return 200, [{"output": brief + " Post the walk-probe budget sheet.", "status": "ok"}]
        return 200, None
    w._http = http
    w._secret = lambda name, env=None: "tok"
    real_sleep = time.sleep
    time.sleep = lambda s: None
    try:
        cap = w.box_morning(wait_s=60)
    finally:
        time.sleep = real_sleep
    cap = json.loads(json.dumps(cap))
    lines, rc = w.judge_morning(cap)
    return judge_text(lines), rc


out, rc = run_morning("Good morning. Nobody is waiting.", COMMON_DEBTS)
check("morning: a cast-name string WITHOUT seed provenance is not printed", COMMON not in out and "Jones" not in out and out.count("name=<not a seed name>") == 2, out)
out, rc = run_morning("Good morning. Jane Smith is waiting on you.", DEBTS)
check("morning: a missed waiting person is a FAIL", rc == w.EX_FAIL, rc)
check("morning: the missed SEED debt is not listed as missed", ("name=" + SEED) not in out, out)
check("morning: the missed non-seed debt is reported by shape, never name", "name=<not a seed name>" in out and "Brown" not in out, out)
check("morning: the missed raw number is reported by shape, never digits", "7700" not in out and "digits" in out, out)
out, rc = run_morning("Good morning. Jane Smith, Ana Brown and +44 7700 900123 are waiting on you.", DEBTS)
check("control, morning: all named passes", rc == w.EX_PASS, out)
check("control, morning: no MISSED text", "MISSED" not in out, out)
out, rc = run_morning("Good morning. Ana Brown and +44 7700 900123 are waiting on you.", DEBTS)
check("morning: when the SEED name is the one missed, it is named", rc == w.EX_FAIL and ("name=" + SEED) in out and "resolved=True" in out, out)

print("FAIL" if fail else "all hold")
sys.exit(1 if fail else 0)
