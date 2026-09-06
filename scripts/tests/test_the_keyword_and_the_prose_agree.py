#!/usr/bin/env python3
"""Self-test for check_closing_keyword_agrees_with_the_prose.py.

THE FIXTURES BUILD THE KEYWORD AT RUNTIME AND NEVER CARRY IT AS A LITERAL.

That is not fussiness. On 2026-09-06 CM051 #1153 was closed a second time
because a commit message quoted the keyword in order to explain the FIRST
wrong closure. GitHub parses commit messages and PR bodies, not repository
contents, so a literal here would be harmless in the file -- and lethal the
moment somebody copies a fixture into a commit message to describe this test.
Concatenating the word costs one line and removes that whole class.

EVERY ARM CARRIES ITS OPPOSITE. A gate that only ever fires proves nothing, so
the must-miss cases are the load-bearing ones: ordinary English containing the
word "closes", a complete PR that legitimately closes an issue, and partial
prose with no closing reference at all must every one of them PASS.
"""
from __future__ import annotations

import importlib.util
import pathlib
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
GATE = HERE.parent / "check_closing_keyword_agrees_with_the_prose.py"

PASS = 0
FAIL = 0


def ok(msg: str) -> None:
    global PASS
    PASS += 1
    print(f"  [PASS] {msg}")


def bad(msg: str) -> None:
    global FAIL
    FAIL += 1
    print(f"  [FAIL] {msg}")


def cannot(msg: str) -> None:
    print(f"  [CANNOT-RUN] {msg}")
    print(f"== {PASS} pass / {FAIL} fail / 1 cannot-run ==")
    sys.exit(2)


if not GATE.is_file():
    cannot(f"gate not found at {GATE}")

spec = importlib.util.spec_from_file_location("gate", GATE)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

# Built, never written. See the module docstring.
CLOSE = "Clo" + "ses"
FIXES = "Fi" + "xes"
RESOLVED = "Reso" + "lved"

CONFLICTED = [
    (
        "the real #1654 body: a closing reference and '4 of 5'",
        f"{CLOSE} #1153.\n\nFive needles were bare paths. This fixes 4 of 5; "
        "scripts/deferred-register-device.sh stays open.",
    ),
    ("'partially' beside a reference", f"{FIXES} #99.\n\nPartially addresses the parser."),
    ("'still blind' beside a reference", f"{RESOLVED}: owner/repo#42 -- one asset is still blind."),
    ("'the remaining half'", f"{CLOSE} #7. The remaining half needs a live store."),
    ("'4 of its 5'", f"{CLOSE} #1153. This lands 4 of its 5."),
]

CLEAN = [
    ("a complete fix that legitimately closes", f"{CLOSE} #1153.\n\nEvery needle is now cp-unique."),
    ("partial prose with NO closing reference", "Refs #1153. This fixes 4 of 5; the fifth stays open."),
    ("neither", "A tidy-up of some comments."),
    ("ordinary English using the word", "This closes the loop on the parser. 4 of 5 arms done."),
    ("cross-repo reference, complete work", f"{FIXES} andygmassey/HR015-Gaming-PC#755 outright."),
    ("empty body", ""),
]

print("== keyword-vs-prose gate self-test ==")
print()

for label, body in CONFLICTED:
    rc, _ = gate.check(body)
    ok(f"MUST FAIL: {label}") if rc == 1 else bad(f"MUST FAIL but rc={rc}: {label}")

for label, body in CLEAN:
    rc, _ = gate.check(body)
    ok(f"must pass: {label}") if rc == 0 else bad(f"must pass but rc={rc}: {label}")

# ── CANNOT-RUN is a third state, and it is not a pass ───────────────────────
# Driven through the real CLI, because the distinction lives in main() and a
# direct call to check() would never exercise it.
with tempfile.TemporaryDirectory() as td:
    missing = pathlib.Path(td) / "no-such-body.txt"
    proc = subprocess.run(
        [sys.executable, str(GATE), "--pr-body-file", str(missing)],
        capture_output=True, text=True,
    )
    if proc.returncode == 2 and "CANNOT-RUN" in proc.stdout:
        ok("an unreadable body is rc=2 CANNOT-RUN, not rc=0")
    else:
        bad(f"unreadable body gave rc={proc.returncode}, expected 2. out={proc.stdout[:120]!r}")

    # And the happy path through the CLI, so the two are compared like for like.
    good = pathlib.Path(td) / "body.txt"
    good.write_text("A tidy-up of some comments.\n", encoding="utf-8")
    proc = subprocess.run(
        [sys.executable, str(GATE), "--pr-body-file", str(good)],
        capture_output=True, text=True,
    )
    ok("a readable clean body is rc=0 through the CLI") if proc.returncode == 0 else bad(
        f"clean body through the CLI gave rc={proc.returncode}"
    )

# ── The output must never carry the pair it is warning about ───────────────
# The failure message names the reference and the prose separately. If it ever
# printed them adjacent, pasting this gate's own output into a commit message
# would close the issue -- which is the second half of the incident.
rc, out = gate.check(f"{CLOSE} #1153. This lands 4 of its 5.")
joined = "\n".join(out)
if rc == 1 and not gate.CLOSING_RE.search(joined):
    ok("the failure output does not itself contain a closing keyword plus a reference")
else:
    bad("the failure output reproduces the pair it exists to warn about")

print()
print(f"== {PASS} pass / {FAIL} fail / 0 cannot-run ==")
sys.exit(1 if FAIL else 0)
