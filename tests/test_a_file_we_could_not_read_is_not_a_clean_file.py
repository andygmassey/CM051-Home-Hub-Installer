#!/usr/bin/env python3
"""A scan that could not read a file reported ZERO hits, and zero hits is a PASS.

#1629. Every count helper in verify_cut_manifest.py feeds one comparison:

    ok = (total > 0) if must_match else (total == 0)

In the must_match=False direction -- which is every PII and leak scan over the
DMG tree -- ZERO HITS IS A PASS. So a helper that returns 0 when it could not
look does not merely lose a measurement. It manufactures a CLEAN VERDICT for an
artefact nobody finished reading.

THREE MEMBERS OF THE CLASS, found by censusing the family rather than fixing the
one the register named:

    _pattern_hits_bytes   except Exception          -> return 0
    _grep_file            except PermissionError    -> return 0    <- most reachable
    _grep_binary_strings  except TimeoutExpired     -> return 0    <- the one #1629 named

The register named the timeout. The timeout is the LEAST reachable of the three:
measured on the shipped daemon, 16,656,512 bytes, strings -a completes in 0.09s
against a 60s cap at 190 MB/s, so a binary would need to be about 11 GB.

`_grep_file` needs one `chmod 000`, one file owned by another user in a staged
tree, or one I/O error. That is the member that will actually fire, and it was
sitting behind the one that was reported.

WHY AN EXCEPTION RATHER THAN A SENTINEL. `total += -1` silently reduces a real
count, which is worse than the defect. An exception cannot be accumulated,
cannot be compared, and cannot be ignored without a visible `except`.

THE ARM THAT KEEPS THIS HONEST is the one that proves the unreadable file is
genuinely unreadable. Running as root, or on a filesystem that ignores mode
bits, `chmod 000` does not block a read and every arm below would pass for the
wrong reason -- reporting a fixed defect on a machine that never reproduced it.

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

if not hasattr(vcm, "CouldNotMeasure"):
    cant("verify_cut_manifest has no CouldNotMeasure; the fix is absent and every "
         "arm below would report on a module that cannot express the state")

work = pathlib.Path(tempfile.mkdtemp())

# ---------------------------------------------------------------------------
# The unreadable file, and the proof that it is unreadable.
# ---------------------------------------------------------------------------
locked = work / "locked.txt"
locked.write_text("SECRET_TOKEN_SHAPE_THAT_A_LEAK_SCAN_HUNTS\n")
os.chmod(locked, 0o000)

print("== PRECONDITION: the unreadable file is genuinely unreadable ==")
readable = True
try:
    locked.read_bytes()
except PermissionError:
    readable = False
except OSError:
    readable = False
if readable:
    cant(f"{locked} is still readable after chmod 000 (euid={os.geteuid()}). "
         f"Running as root or on a filesystem that ignores mode bits, every arm "
         f"below would pass for the wrong reason and report a fixed defect on a "
         f"machine that never reproduced it")
ok(f"the planted file is unreadable (euid={os.geteuid()}), so the arms below "
   f"exercise the real condition")

print("== an unreadable file RAISES rather than counting zero ==")
try:
    n = vcm._grep_file(locked, "SECRET_TOKEN_SHAPE")
    bad(f"_grep_file returned {n} for a file it could not read -- under "
        f"must_match=False that zero is a PASS, and the gate would certify the "
        f"artefact clean of a leak it never read the file to look for")
except vcm.CouldNotMeasure as e:
    ok(f"_grep_file raises CouldNotMeasure: {str(e)[:80]}")
except Exception as e:  # noqa: BLE001
    bad(f"_grep_file raised {type(e).__name__} rather than CouldNotMeasure, so "
        f"call sites catching CouldNotMeasure will not handle it: {e}")

print("== CONTROL: an ABSENT file is still a legitimate zero ==")
# The discrimination that keeps this from being a blanket. A file that is not
# there during a tree walk hid nothing from us; there is simply nothing to read.
try:
    n = vcm._grep_file(work / "no-such-file.txt", "anything")
    if n == 0:
        ok("CONTROL: an absent file returns 0, not an exception -- 'not there' and "
           "'could not look' stay different")
    else:
        bad(f"CONTROL: an absent file returned {n}")
except vcm.CouldNotMeasure as e:
    bad(f"CONTROL: an absent file raised CouldNotMeasure ({e}) -- every tree walk "
        f"would abort on the first missing path")

print("== CONTROL: a readable file still counts, both directions ==")
plain = work / "plain.txt"
plain.write_text("alpha SECRET_TOKEN_SHAPE beta\n")
try:
    hit = vcm._grep_file(plain, "SECRET_TOKEN_SHAPE")
    miss = vcm._grep_file(plain, "NOTHING_LIKE_THIS")
    if hit == 1 and miss == 0:
        ok("CONTROL: a readable file scores 1 for a present pattern and 0 for an "
           "absent one, so the exception above is a measurement and not a blanket")
    else:
        bad(f"CONTROL: readable file scored hit={hit} miss={miss}, expected 1 and 0")
except vcm.CouldNotMeasure as e:
    bad(f"CONTROL: a perfectly readable file raised CouldNotMeasure: {e}")

print("== the strings(1) timeout raises too, and it is the same class ==")
_real_run = subprocess.run


def _timeout_run(*a, **kw):
    raise subprocess.TimeoutExpired(cmd=a[0] if a else "strings", timeout=60)


binary = work / "fake-binary"
binary.write_bytes(b"MACHO\x00\x00stuff\n")
vcm.subprocess.run = _timeout_run
try:
    n = vcm._grep_binary_strings(binary, "stuff")
    bad(f"_grep_binary_strings returned {n} when strings(1) timed out")
except vcm.CouldNotMeasure as e:
    ok(f"_grep_binary_strings raises on a strings(1) timeout: {str(e)[:70]}")
except Exception as e:  # noqa: BLE001
    bad(f"_grep_binary_strings raised {type(e).__name__}, not CouldNotMeasure: {e}")
finally:
    vcm.subprocess.run = _real_run

print("== CONTROL: with strings(1) restored, a binary still counts ==")
try:
    n = vcm._grep_binary_strings(binary, "stuff")
    if n >= 1:
        ok(f"CONTROL: the real strings(1) path still counts ({n}), so the arm above "
           f"measured the timeout and not a broken function")
    else:
        bad(f"CONTROL: the real strings(1) path scored {n}, expected at least 1")
except vcm.CouldNotMeasure as e:
    cant(f"the real strings(1) path could not run here, so the control cannot "
         f"prove the timeout arm was specific: {e}")

print("== MUST-MISS: every Result-producing call site CATCHES it ==")
# A raise that no caller handles is worse than the zero it replaced: it becomes
# an unhandled exception, which main()'s own comment says gets reported to the
# operator as a product defect.
src = SUBJECT.read_text()
raises = src.count("raise CouldNotMeasure")
catches = src.count("except CouldNotMeasure")
if raises >= 3 and catches >= 4:
    ok(f"{raises} raise site(s) and {catches} catch site(s) -- every helper that "
       f"can refuse has a Result-producing caller that turns it into CANNOT-RUN")
else:
    bad(f"{raises} raise site(s) but only {catches} catch site(s) -- an unhandled "
        f"CouldNotMeasure crashes the gate, and a crash is reported to the "
        f"operator as a defect in the .app")

os.chmod(locked, 0o600)
import shutil
shutil.rmtree(work, ignore_errors=True)

print(f"\n== {PASS} pass / {FAIL} fail / {PASS + FAIL} total ==")
sys.exit(1 if FAIL else 0)
