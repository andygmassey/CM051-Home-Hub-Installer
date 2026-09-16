#!/usr/bin/env python3
"""A failing box_walk_probe row must not throw away the evidence it printed.

WHY THIS EXISTS. no_unexpected_egress prints the offending process and remote
address BEFORE its closing "VERDICT: FAIL -- ..." line (probe_note, in
scripts/box_walk_probes/probes/no_unexpected_egress.sh). check_box_walk_probe
in scripts/verify_cut_manifest.py used to build its Result's detail as

    stdout_snippet = result.stdout.decode(...).strip().splitlines()[-1:] or [""]
    detail = f"probe={probe} exit={exit_code} stdout={stdout_snippet[0][:200]!r}"

-- the LAST LINE of stdout, truncated to 200 characters. The probe's own
verdict sentence is that last line; the holder and the address are on the
lines above it, and both were discarded before anyone could read them. On two
consecutive real cuts, no_unexpected_egress failed and neither failure could
be attributed to a process or an address for exactly this reason.

WHAT THIS PROVES, on the running code:

  1. A probe whose identifying detail sits BEFORE its verdict line still
     surfaces that detail somewhere a Result consumer can reach it -- either
     directly in `detail`, or in a file `detail` points at via `full_output=`.
  2. MUST-MISS CONTROL: the identifying detail genuinely is NOT on the last
     line of the probe's raw stdout. If it were, recovering it would prove
     nothing about the fix -- this arm confirms the fixture exercises the
     actual defect shape rather than a strawman.
  3. The same holds for a CANNOT-RUN row (timeout), not only a FAIL one.
  4. A PASSing probe is left alone: no evidence file is manufactured for a
     row that measured cleanly.
  5. A write failure in the evidence path degrades to a stated reason rather
     than crashing the whole gate.

RUN THIS AGAINST THE ORIGINAL, PRE-FIX FILE FIRST:

    git show <pre-fix-sha>:scripts/verify_cut_manifest.py > /tmp/old_vcm.py
    VCM_PATH=/tmp/old_vcm.py python3 tests/test_a_failing_probes_early_output_is_not_discarded.py

Arm 1 and arm 3 must FAIL there -- the identifying string is not reachable at
all, from either `detail` or a file -- proving this test exercises the real
defect and not a fixture-shaped echo of the fix.
"""
import importlib.util
import os
import pathlib
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parents[1]
SUBJECT = pathlib.Path(os.environ.get("VCM_PATH", str(REPO / "scripts" / "verify_cut_manifest.py")))

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

spec = importlib.util.spec_from_file_location("vcm_evidence_subject", str(SUBJECT))
vcm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vcm)

work = pathlib.Path(tempfile.mkdtemp())
probe_dir = work / "scripts" / "box_walk_probes" / "probes"
probe_dir.mkdir(parents=True)
evidence_dir = work / "evidence"


def write_probe(name: str, body: str) -> None:
    p = probe_dir / f"{name}.sh"
    p.write_text(body)
    p.chmod(0o755)


HOLDER = "HOLDER_PROC_TAG_98213"
ADDRESS = "REMOTE_ADDR_TAG_198.51.100.77:443"

# Shaped exactly like no_unexpected_egress: identifying detail printed BEFORE
# the closing verdict line, on stdout, then a non-zero exit.
write_probe(
    "egress_shaped",
    "#!/bin/bash\n"
    "echo 'EXAMINED: 3 established connections'\n"
    f"echo '  OUTSIDE THE BOUNDARY, UNDECLARED (1): {HOLDER} -> {ADDRESS}'\n"
    "echo 'VERDICT: FAIL -- 1 connection(s) attributable to Ostler reached an undeclared destination'\n"
    "exit 1\n",
)

# The same shape on a CANNOT-RUN exit (78), so the fix is checked on both
# non-PASS statuses this function can return from a real subprocess run, not
# only FAIL.
write_probe(
    "cannotrun_shaped",
    "#!/bin/bash\n"
    f"echo '  candidate before the cap: {HOLDER} -> {ADDRESS}'\n"
    "echo 'VERDICT: CANNOT-RUN -- could not finish in time'\n"
    "exit 78\n",
)

write_probe("clean", "#!/bin/bash\necho 'VERDICT: PASS -- nothing outside the boundary'\nexit 0\n")

ctx = {"cm051_dir": work}

os.environ["OSTLER_BOX_HOST"] = "probe@example.invalid"
os.environ["OSTLER_BOX_WALK_EVIDENCE_DIR"] = str(evidence_dir)


def run(probe_name):
    entry = {"id": f"row-{probe_name}", "title": "t", "proof": {"probe": probe_name}}
    return vcm.check_box_walk_probe(entry, ctx)


def raw_last_line(probe_name):
    """Exactly what the OLD code read: the probe's own last stdout line."""
    r = subprocess.run(["/bin/bash", str(probe_dir / f"{probe_name}.sh")], capture_output=True, check=False)
    lines = r.stdout.decode("utf-8", "replace").strip().splitlines()
    return lines[-1] if lines else ""


def recoverable_text(res):
    """Everything a reader of this Result can actually see: the detail string,
    plus the content of any file a `full_output=<path>` reference in it names."""
    text = res.detail or ""
    for token in text.split():
        if token.startswith("full_output="):
            p = pathlib.Path(token[len("full_output="):])
            if p.is_file():
                text += "\n" + p.read_text(encoding="utf-8", errors="replace")
    return text


print("== MUST-MISS: the identifying string is genuinely NOT on the last line ==")
if HOLDER not in raw_last_line("egress_shaped") and ADDRESS not in raw_last_line("egress_shaped"):
    ok("egress_shaped's own last stdout line carries neither the holder nor the address -- "
       "a fixture that actually exercises the defect, not a strawman")
else:
    bad("the fixture's identifying string leaked onto the last line; this arm proves nothing")

print("== a FAIL row still surfaces its early output ==")
r = run("egress_shaped")
if r.status != "FAIL":
    bad(f"expected FAIL, got {r.status}: {r.detail}")
else:
    ok("egress_shaped scored FAIL")
    text = recoverable_text(r)
    if HOLDER in text and ADDRESS in text:
        ok("both the holder and the remote address are recoverable from this Result")
    else:
        bad(f"the holder/address printed before the verdict line did not survive: detail={r.detail!r}")

print("== a CANNOT-RUN row ALSO surfaces its early output ==")
r = run("cannotrun_shaped")
if r.status != "CANNOT-RUN":
    bad(f"expected CANNOT-RUN, got {r.status}: {r.detail}")
else:
    ok("cannotrun_shaped scored CANNOT-RUN")
    text = recoverable_text(r)
    if HOLDER in text and ADDRESS in text:
        ok("both the holder and the remote address are recoverable from this Result")
    else:
        bad(f"the holder/address printed before the CANNOT-RUN verdict did not survive: detail={r.detail!r}")

print("== CONTROL: a PASSing probe manufactures no evidence file ==")
r = run("clean")
if r.status != "PASS":
    bad(f"expected PASS, got {r.status}: {r.detail}")
elif "full_output=" in (r.detail or ""):
    bad(f"a clean row should not need an evidence file, and one was referenced: {r.detail}")
else:
    ok("a clean PASS carries no full_output pointer -- evidence is written only when there is a finding")

print("== a write failure in the evidence path degrades, it does not crash ==")
blocked = work / "blocked_evidence"
blocked.write_text("not a directory")  # mkdir(parents=True) on this path must raise
os.environ["OSTLER_BOX_WALK_EVIDENCE_DIR"] = str(blocked / "nested")
try:
    r = run("egress_shaped")
    if r.status == "FAIL" and "UNWRITEABLE:" in (r.detail or ""):
        ok("an evidence directory that cannot be created is reported as UNWRITEABLE, and the row still scores FAIL")
    elif r.status == "FAIL":
        bad(f"the row still scored FAIL but did not say the evidence write failed: {r.detail}")
    else:
        bad(f"expected FAIL even when evidence cannot be written, got {r.status}")
except Exception as e:  # noqa: BLE001 -- this arm's whole point is that nothing here may raise
    bad(f"a write failure in the evidence path raised instead of degrading: {e.__class__.__name__}: {e}")
finally:
    os.environ["OSTLER_BOX_WALK_EVIDENCE_DIR"] = str(evidence_dir)

print()
print(f"== {PASS} pass / {FAIL} fail / {PASS + FAIL} total ==")
sys.exit(1 if FAIL else 0)
