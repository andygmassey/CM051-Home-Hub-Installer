#!/usr/bin/env python3
"""A timeout that returns 0 hits made a cut gate go GREEN.

WHY THIS EXISTS. #1629, from TNM's AST census of every handler in
verify_cut_manifest.py catching subprocess.TimeoutExpired and the status
literal each returns. Six handlers: two already correct, two fixed by #1626 and
#1628, and this one.

`_grep_binary_strings` returned 0 on a timeout. 0 IS A HIT COUNT. At the
grep_in_artefact call site the very next line was:

    ok = (hits > 0) if must_match else (hits == 0)

so a row with `must_match: false` evaluated `0 == 0` and PASSED. A probe that
could not run made the gate go green.

THIS IS THE ONE THAT FAILS OPEN. Every other instrument defect found the same
night failed SAFE -- they refused, said CANNOT-RUN, and lost coverage quietly.
A wrong red is noisy. A wrong green ships.

In the dmg-tree loop the same 0 met `if not n: continue`, dropping the file
from the population. A partial sweep is not a smaller sweep; it is a sweep
whose denominator you no longer know.

WHY AN EXCEPTION RATHER THAN A SENTINEL. A hit COUNT has no value meaning "I
could not look". 0 means "looked, found nothing", and any sentinel integer is a
number some caller will compare. So the helper raises and the caller decides.

THREE STATES. 0 pass, 1 fail, 2 cannot-run.
"""
import importlib.util
import pathlib
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parents[1]
SUBJECT = REPO / "scripts" / "verify_cut_manifest.py"
PASS = FAIL = 0


def ok(m):
    global PASS
    PASS += 1
    print(f"  [PASS] {m}")


def bad(m):
    global FAIL
    FAIL += 1
    print(f"  [FAIL] {m}")


if not SUBJECT.is_file():
    print(f"CANNOT-RUN: no subject at {SUBJECT}", file=sys.stderr)
    sys.exit(2)

spec = importlib.util.spec_from_file_location("vcm", SUBJECT)
vcm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vcm)

if not hasattr(vcm, "CouldNotMeasure"):
    print("CANNOT-RUN: the module has no CouldNotMeasure; this test cannot express its subject",
          file=sys.stderr)
    sys.exit(2)

work = pathlib.Path(tempfile.mkdtemp())
# Build the real shape resolve_target() expects: app_path/Contents/Resources/
# Ostler.app, whose main binary is what `daemon-binary` resolves to. Faking the
# ctx instead would test my fake rather than the primitive.
app_path = work / "OstlerInstaller.app"
daemon_app = app_path / "Contents" / "Resources" / "Ostler.app"
macos = daemon_app / "Contents" / "MacOS"
macos.mkdir(parents=True)
(daemon_app / "Contents" / "Info.plist").write_text(
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
    '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    '<plist version="1.0"><dict>'
    '<key>CFBundleExecutable</key><string>Ostler</string>'
    '</dict></plist>\n')
binary = macos / "Ostler"
binary.write_bytes(b"\x00\x01SOME-MARKER-STRING\x00\x02padding padding\n")
binary.chmod(0o755)

_real_run = subprocess.run


def _timeout_run(*a, **k):
    raise subprocess.TimeoutExpired(cmd="strings", timeout=1)


print("== a timeout raises, it does not return a count ==")

subprocess.run = _timeout_run
try:
    try:
        n = vcm._grep_binary_strings(binary, "SOME-MARKER-STRING")
        bad(f"a timed-out binary grep returned {n!r} -- a hit count, indistinguishable from "
            f"'looked and found nothing'")
    except vcm.CouldNotMeasure as e:
        if "NOT a hit count" in str(e):
            ok("a timed-out binary grep raises CouldNotMeasure and says it is not a hit count")
        else:
            ok("a timed-out binary grep raises CouldNotMeasure")
finally:
    subprocess.run = _real_run

print("== CONTROL: the same path returns a REAL count when it completes ==")

n = vcm._grep_binary_strings(binary, "SOME-MARKER-STRING")
if n >= 1:
    ok(f"CONTROL: the same helper returns a real count ({n}) when strings(1) completes, so the "
       f"raise above is a measurement and not a broken code path")
else:
    bad(f"CONTROL: the helper returned {n!r} on a binary that DOES contain the marker -- this "
        f"test cannot tell a raise from a broken helper")

n0 = vcm._grep_binary_strings(binary, "A-STRING-THAT-IS-NOT-THERE")
if n0 == 0:
    ok("CONTROL: a genuine absence still returns 0, so 0 keeps its meaning")
else:
    bad(f"CONTROL: a genuine absence returned {n0!r}")

print("== the fail-OPEN arm: must_match:false + a timeout must NOT pass ==")

entry = {"id": "row", "title": "t",
         "proof": {"kind": "grep_in_artefact", "target": "daemon-binary",
                   "pattern": "SOME-MARKER-STRING", "must_match": False}}
ctx = {"app_path": app_path, "cm051_dir": work, "extra_paths": {}}

subprocess.run = _timeout_run
try:
    r = vcm.check_grep_in_artefact(entry, ctx)
finally:
    subprocess.run = _real_run

if r.status == "CANNOT-RUN":
    ok("a timed-out must_match:false row reports CANNOT-RUN")
elif r.status == "PASS":
    bad("a timed-out must_match:false row PASSES -- this is the fail-open defect: a probe that "
        "could not run makes the gate green")
else:
    bad(f"a timed-out must_match:false row reports {r.status!r}")

print("== CONTROL: a genuine absence with must_match:false still PASSES ==")

entry_absent = {"id": "row2", "title": "t",
                "proof": {"kind": "grep_in_artefact", "target": "daemon-binary",
                          "pattern": "A-STRING-THAT-IS-NOT-THERE", "must_match": False}}
r2 = vcm.check_grep_in_artefact(entry_absent, ctx)
if r2.status == "PASS":
    ok("CONTROL: a genuine absence still PASSES, so CANNOT-RUN above is not a blanket refusal")
else:
    bad(f"CONTROL: a genuine absence reports {r2.status!r} ({r2.detail!r}) -- the fix has blinded "
        f"the primitive instead of correcting it")

print()
print(f"== {PASS} pass / {FAIL} fail / {PASS + FAIL} total ==")
sys.exit(1 if FAIL else 0)
