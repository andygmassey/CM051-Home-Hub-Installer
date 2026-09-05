#!/usr/bin/env python3
"""A probe that exceeded its cap was reported as FAIL. It measured nothing.

WHY THIS EXISTS. MEASURED 2026-09-06, on the first run of this manifest against
a live box. `assistant_answers_grounded` was 1 of 12 FAILs, reported as:

    FAIL  box-walk-assistant-answers-grounded
          probe invocation failed: Command '[...]' timed out

Re-run directly with no cap, the same probe on the same box COMPLETES and
returns a precise, actionable verdict:

    asked #1: no_tool_call
    asked #2: memory_only
    asked #3: grounded
    VERDICT: 2 of 3 questions COMPLETED without reaching the customer's own data

So the cap replaced a diagnosis with an instrument error, and the summary line
counted it beside genuine defects. A probe that drives a real conversation over
a websocket against a local model is legitimately slow; the cap is right for a
probe that greps a file and wrong for that one.

CANNOT-RUN was ALREADY a first-class status in this file -- rendered, counted
separately, and excluded from the "ran" denominator. This arm simply never
used it.

THE DISTINCTION THAT MUST SURVIVE: a probe that is NOT ON DISK is still a FAIL.
The row names a runtime proof that does not exist, and that is a defect. Only
"it ran and did not finish" is CANNOT-RUN.

THREE STATES. 0 pass, 1 fail, 2 cannot-run.
"""
import importlib.util
import os
import pathlib
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parents[1]
SUBJECT = REPO / "scripts" / "verify_cut_manifest.py"

PASS = FAIL = 0


def ok(msg):
    global PASS
    PASS += 1
    print(f"  [PASS] {msg}")


def bad(msg):
    global FAIL
    FAIL += 1
    print(f"  [FAIL] {msg}")


def cant(msg):
    print(f"CANNOT-RUN: {msg}", file=sys.stderr)
    sys.exit(2)


if not SUBJECT.is_file():
    cant(f"no verify_cut_manifest.py at {SUBJECT}")

spec = importlib.util.spec_from_file_location("vcm", SUBJECT)
vcm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vcm)

work = pathlib.Path(tempfile.mkdtemp())
probe_dir = work / "scripts" / "box_walk_probes" / "probes"
probe_dir.mkdir(parents=True)


def write_probe(name: str, body: str) -> None:
    p = probe_dir / f"{name}.sh"
    p.write_text(body)
    p.chmod(0o755)


# A probe that cannot finish inside the cap, and one that finishes instantly.
write_probe("sleeper", "#!/bin/bash\nsleep 30\nexit 0\n")
write_probe("quick", "#!/bin/bash\necho 'VERDICT: PASS'\nexit 0\n")

ctx = {"cm051_dir": work}


def run(probe_name):
    entry = {"id": f"row-{probe_name}", "title": "t", "proof": {"probe": probe_name}}
    return vcm.check_box_walk_probe(entry, ctx)


# The primitive SKIPs unless the box env var is set, so set it: we are testing
# the invocation path, not the box.
os.environ["OSTLER_BOX_HOST"] = "probe@example.invalid"

# Squeeze the cap so "slow" is reachable in a test rather than in three minutes.
_original_cap = vcm.BOX_WALK_PROBE_TIMEOUT_SECONDS
vcm.BOX_WALK_PROBE_TIMEOUT_SECONDS = 2

print("== a probe that could not finish is CANNOT-RUN, not FAIL ==")

r = run("sleeper")
if r.status == "CANNOT-RUN":
    ok("a probe killed at the cap reports CANNOT-RUN")
elif r.status == "FAIL":
    bad("a probe killed at the cap still reports FAIL -- it is counted beside real defects "
        "and its diagnosis is replaced by an instrument error")
else:
    bad(f"a probe killed at the cap reports {r.status!r}")

if "NOTHING was measured" in (r.detail or ""):
    ok("the detail says NOTHING was measured, so the row cannot be read as a verdict")
else:
    bad("the detail does not say the probe measured nothing")

if "BOX_WALK_PROBE_TIMEOUT_SECONDS" in (r.detail or "") and "2" in (r.detail or ""):
    ok("the detail names the cap it exceeded, so the next reader can raise it or re-run uncapped")
else:
    bad("the detail does not name the cap that killed it")

print("== CONTROL: the statuses are not universal ==")

r = run("quick")
if r.status == "PASS":
    ok("CONTROL: a probe that exits 0 inside the cap still PASSES, so CANNOT-RUN above is a "
       "measurement and not a blanket")
else:
    bad(f"CONTROL: a fast passing probe reports {r.status!r} ({r.detail!r})")

print("== a probe that is NOT ON DISK is still a FAIL, and must not be softened ==")

r = run("no_such_probe_anywhere")
if r.status == "FAIL":
    ok("an unregistered probe FAILs: the row names a runtime proof that does not exist")
else:
    bad(f"an unregistered probe reports {r.status!r} -- softening this would let a row "
        f"claim a proof it never had")

print("== MUST-MISS: the old single-except would score the timeout as FAIL ==")

# Prove the arm can fail: run the sleeper through a stand-in that reproduces the
# pre-fix handler. If this does NOT report FAIL, the arms above prove nothing
# about the change.
try:
    subprocess.run(["/bin/bash", str(probe_dir / "sleeper.sh")],
                   capture_output=True, check=False, timeout=2)
    bad("MUST-MISS: the sleeper did not time out at a 2s cap, so the timeout arms above "
        "never exercised a timeout")
except subprocess.TimeoutExpired:
    ok("MUST-MISS: the sleeper genuinely exceeds a 2s cap, so the arms above exercised a real "
       "timeout rather than a fast error")

vcm.BOX_WALK_PROBE_TIMEOUT_SECONDS = _original_cap

print()
print(f"== {PASS} pass / {FAIL} fail / {PASS + FAIL} total ==")
sys.exit(1 if FAIL else 0)
