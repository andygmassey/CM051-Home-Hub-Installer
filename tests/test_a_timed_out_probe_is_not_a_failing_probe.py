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

# ============================================================================
# people_count_agreement's timeout SCALES WITH THE POPULATION.
#
# WHY THIS EXISTS. MEASURED: the customer's address book is about 8700 people.
# The flat cap above was sized for the largest book anyone had walked, about
# 1800, and people_count_agreement reported CANNOT-RUN against the real book --
# "exceeded BOX_WALK_PROBE_TIMEOUT_SECONDS", the exact instrument-error shape
# the arms above already guard for assistant_answers_grounded. A probe whose
# own internal wait (_await_converge, up to CONVERGE_WAIT_S plus
# STABILITY_WAIT_S) is bounded by the SAME install-time convergence install.sh
# measures at K=0.7 s/person needs a cap that scales the same way, not a
# bigger flat guess.
# ============================================================================

print()
print("== people_count_agreement's timeout scales with the population (#K derivation) ==")

floor_s = vcm.PEOPLE_COUNT_AGREEMENT_TIMEOUT_FLOOR_SECONDS
baseline = vcm.PEOPLE_COUNT_AGREEMENT_TIMEOUT_BASELINE_PERSONS
ceiling_s = vcm.PEOPLE_COUNT_AGREEMENT_TIMEOUT_CEILING_SECONDS

t_unreadable = vcm._people_count_agreement_timeout_seconds(None)
if t_unreadable == floor_s:
    ok(f"an unreadable count takes the floor ({floor_s}s), never a generous guess")
else:
    bad(f"an unreadable count computed {t_unreadable}s, not the floor {floor_s}s")

t_baseline = vcm._people_count_agreement_timeout_seconds(baseline)
if t_baseline == floor_s:
    ok(f"at the baseline ({baseline} persons, the largest book ever walked), the budget is "
       f"still the floor -- no scaling below the size that was already known to fit")
else:
    bad(f"at the baseline the budget computed {t_baseline}s, not the floor {floor_s}s")

# THE REAL BOOK. K = 0.7 s/person (7/10), install.sh's own measured value
# (0.504 s/person measured on 1822 persons / 919s, with install.sh's stated
# 1.5x margin) -- reused rather than re-derived, because this probe waits on
# the IDENTICAL identity-resolver convergence install.sh already measured.
persons_real = 8700
t_real = vcm._people_count_agreement_timeout_seconds(persons_real)
expected_minimum = floor_s + (persons_real - baseline) * 7 // 10

# THE PROBE'S OWN FIXED WAIT FLOOR: CONVERGE_WAIT_S(1800 default) +
# STABILITY_WAIT_S(300 default). A budget for 8700 real people that is not
# even past this fixed floor could not have been the intended fix.
probe_own_floor = 1800 + 300
if t_real > probe_own_floor:
    ok(f"8700 persons -> {t_real}s, past the probe's own fixed "
       f"CONVERGE_WAIT_S+STABILITY_WAIT_S floor ({probe_own_floor}s)")
else:
    bad(f"8700 persons -> {t_real}s, at or under the probe's own fixed wait floor "
        f"({probe_own_floor}s) -- this would still time out on the real book")

if t_real >= expected_minimum:
    ok(f"8700 persons -> {t_real}s, at least the K-derived minimum {expected_minimum}s "
       f"(floor {floor_s}s + {persons_real - baseline} persons past baseline * 7/10)")
else:
    bad(f"8700 persons -> {t_real}s, BELOW the K-derived minimum {expected_minimum}s -- "
        f"the budget is smaller than the work a large book implies")

if t_real > vcm.BOX_WALK_PROBE_TIMEOUT_SECONDS:
    ok(f"the scaled budget ({t_real}s) exceeds the flat cap ({vcm.BOX_WALK_PROBE_TIMEOUT_SECONDS}s) "
       f"that killed the real walk")
else:
    bad(f"the scaled budget ({t_real}s) does not exceed the flat cap -- the real defect "
        f"would still reproduce")

t_huge = vcm._people_count_agreement_timeout_seconds(50_000_000)
if t_huge == ceiling_s:
    ok(f"an absurd population clamps at the ceiling ({ceiling_s}s) rather than growing without bound")
else:
    bad(f"an absurd population computed {t_huge}s, not the ceiling {ceiling_s}s")

print("== MUST-MISS: a formula that ignores persons (the pre-fix shape) fails the K-derived-minimum arm ==")

# A mutant standing in for "the budget was bumped to a bigger flat number"
# rather than actually scaled -- the launch directive's own warning ("do not
# simply multiply the number until it passes"). If this mutant still clears
# the K-derived-minimum check above, that check proves nothing.
_mutant_flat_bigger = max(floor_s, 3000)  # "just raise the constant" -- still population-blind
if _mutant_flat_bigger < expected_minimum:
    ok(f"MUST-MISS: a flat-bigger-number mutant ({_mutant_flat_bigger}s) is BELOW the "
       f"K-derived minimum ({expected_minimum}s) for 8700 persons, so the arm above would "
       f"have caught it")
else:
    bad(f"MUST-MISS: a flat-bigger-number mutant ({_mutant_flat_bigger}s) still clears the "
        f"K-derived minimum ({expected_minimum}s) -- the check above cannot tell a real "
        f"per-person scaling from a bigger guess")

print("== end-to-end: check_box_walk_probe uses the scaled timeout for THIS probe, and only this probe ==")

captured = {}


class _FakeCompleted:
    returncode = 0
    stdout = b"VERDICT: PASS -- ok\n"
    stderr = b""


def _fake_run(args, capture_output=True, check=False, timeout=None):
    captured["timeout"] = timeout
    return _FakeCompleted()


write_probe("people_count_agreement", "#!/bin/bash\necho 'VERDICT: PASS'\nexit 0\n")
write_probe("some_other_probe", "#!/bin/bash\necho 'VERDICT: PASS'\nexit 0\n")

_orig_subprocess_run = subprocess.run
_orig_people_count_for_timeout = vcm._people_count_for_timeout
vcm._people_count_for_timeout = lambda cm051_dir: persons_real   # no real ssh in a test

vcm.subprocess.run = _fake_run
try:
    r = run("people_count_agreement")
finally:
    vcm.subprocess.run = _orig_subprocess_run

expected_scaled = vcm._people_count_agreement_timeout_seconds(persons_real)
if captured.get("timeout") == expected_scaled:
    ok(f"check_box_walk_probe invoked people_count_agreement with the population-scaled "
       f"timeout ({captured.get('timeout')}s for {persons_real} persons)")
else:
    bad(f"check_box_walk_probe invoked the probe with timeout={captured.get('timeout')!r}, "
        f"expected the scaled {expected_scaled}s")

captured.clear()
vcm.subprocess.run = _fake_run
try:
    run("some_other_probe")
finally:
    vcm.subprocess.run = _orig_subprocess_run
vcm._people_count_for_timeout = _orig_people_count_for_timeout

if captured.get("timeout") == vcm.BOX_WALK_PROBE_TIMEOUT_SECONDS:
    ok("CONTROL: an unrelated probe still takes the flat BOX_WALK_PROBE_TIMEOUT_SECONDS, so "
       "the scaling is scoped to people_count_agreement only")
else:
    bad(f"CONTROL: an unrelated probe took timeout={captured.get('timeout')!r}, expected the "
        f"flat {vcm.BOX_WALK_PROBE_TIMEOUT_SECONDS}s -- the scaling leaked to a probe it "
        f"should not touch")

print("== REAL TIMING: unfixed vs fixed, against an actual clock (small durations standing in "
      "for the real ~117-minute wait 8700 persons implies) ==")

# A probe that outlasts a small, population-blind cap but fits comfortably
# under an explicit stand-in for the scaled one. 2.5s here plays the role
# ~117 minutes plays against the real ~600s flat cap.
write_probe("people_count_agreement", "#!/bin/bash\nsleep 2.5\necho 'VERDICT: PASS'\nexit 0\n")

_orig_scale_fn = vcm._people_count_agreement_timeout_seconds
_orig_flat_cap = vcm.BOX_WALK_PROBE_TIMEOUT_SECONDS
vcm._people_count_for_timeout = lambda cm051_dir: persons_real

# UNFIXED: reproduce the pre-fix shape exactly -- the per-probe formula is not
# consulted at all, every probe (this one included) takes the flat cap, and
# the flat cap is sized the way BOX_WALK_PROBE_TIMEOUT_SECONDS was sized
# before this fix: for the largest book ever walked, not the real one.
vcm._people_count_agreement_timeout_seconds = lambda persons: vcm.BOX_WALK_PROBE_TIMEOUT_SECONDS
vcm.BOX_WALK_PROBE_TIMEOUT_SECONDS = 1
r_unfixed = run("people_count_agreement")
if r_unfixed.status == "CANNOT-RUN":
    ok(f"UNFIXED: a population-blind cap kills the probe before it can finish "
       f"(status={r_unfixed.status})")
else:
    bad(f"UNFIXED arm did not reproduce the timeout (status={r_unfixed.status}) -- the "
        f"demonstration proves nothing")

# FIXED: restore the real per-probe formula. OSTLER_BOX_WALK_PEOPLE_COUNT_TIMEOUT_SECONDS
# is the explicit override the fix itself ships (same "the env override still
# wins" rule install.sh's own converge budget follows); used here only to keep
# this arm's real sleep short, standing in for the ~7030s the formula itself
# already proved it computes for 8700 persons above.
vcm._people_count_agreement_timeout_seconds = _orig_scale_fn
vcm.BOX_WALK_PROBE_TIMEOUT_SECONDS = _orig_flat_cap
os.environ["OSTLER_BOX_WALK_PEOPLE_COUNT_TIMEOUT_SECONDS"] = "5"
try:
    r_fixed = run("people_count_agreement")
finally:
    os.environ.pop("OSTLER_BOX_WALK_PEOPLE_COUNT_TIMEOUT_SECONDS", None)
    vcm._people_count_for_timeout = _orig_people_count_for_timeout

if r_fixed.status == "PASS":
    ok(f"FIXED: the same probe, the same {persons_real}-person book, completes under the "
       f"population-scaled budget (status={r_fixed.status})")
else:
    bad(f"FIXED arm did not pass (status={r_fixed.status}, detail={r_fixed.detail!r})")

print()
print(f"== {PASS} pass / {FAIL} fail / {PASS + FAIL} total ==")
sys.exit(1 if FAIL else 0)
