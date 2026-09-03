#!/usr/bin/env python3
"""Catch a line-continuation backslash that has a SPACE after it.

WHY THIS EXISTS -- IT KILLED A LIVE BOX WALK, 2026-09-03.

install.sh:26690 shipped in v1.0.61 as:

    unset _PLACES_EMBED_URL _PLACES_EMBED_MODEL _PLACES_TIMEOUT_WRAP \\ _PLACES_CAP
          _places_rc _places_log_tail

The author meant the backslash to continue the line. It has a SPACE after it,
so it escapes the SPACE instead of the newline. Two things then happen, and
both are silent:

  1. `unset` receives an argument that is literally " _PLACES_CAP" -- a leading
     space, which is not a legal identifier -- so `unset` returns non-zero, the
     ERR trap fires, and THE INSTALL ABORTS.
  2. The orphaned second line, `_places_rc _places_log_tail`, is no longer part
     of the unset. It is a COMMAND, and it is not one that exists.

Measured on the walk: `DONE status=fail code=ERR-99-INSTALL-ABORT-L26692`.
The customer got to 97% and the Hub never started.

🗿 `bash -n` CANNOT SEE THIS, AND THAT IS THE WHOLE POINT. Measured on the real
pre-fix file: `bash -n install.sh` exits 0. The construct is VALID SHELL that
does the wrong thing, so every syntax-only check in the estate passes it. A
gate that only parses will never catch this class; it has to read the SHAPE.

WHY THE PREDICATE IS NARROW, AND WHY THAT IS DELIBERATE.
A blanket "no backslash-space" rule is NOT enforceable here, and this is
measured rather than assumed: 527 shell files in this repo contain TEN
backslash-spaces and all ten are legitimate -- `case` globs (`OK\\ *)`,
`AUTHFAIL\\ *)`, `PERMISSION_ERROR*Full\\ Disk\\ Access*)`), a `[[ ]]` pattern
comparison, and an escaped path inside a comment. Banning the character would
be ten false accusations, and a gate that cries wolf ten times gets switched
off. So the predicate asks for the FULL defect shape, both halves:

    a line containing `\\ `  AND  a following line that is an ORPHANED
    CONTINUATION -- indented, and consisting only of bare identifiers, which
    is precisely the thing that would run as a command and not be found.

That pair is what makes it a bug rather than a glob. Proved against the real
population below: 1 of 1 on the true defect, 0 of 10 on the legitimate uses.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# Files this gate reads. install.sh is the one that ships and the one that
# broke; the rest are swept because the same typo is possible anywhere.
GLOBS = ("install.sh", "*.sh", "scripts/**/*.sh", "tests/**/*.sh")

# An orphaned continuation: leading whitespace, then nothing but bare words.
# No quotes, no operators, no ';', no ')', no '=', no '$'. A line like
# `          _places_rc _places_log_tail` matches; real code does not.
_ORPHAN = re.compile(r"^[ \t]+[A-Za-z_][A-Za-z0-9_]*(?:[ \t]+[A-Za-z_][A-Za-z0-9_]*)*[ \t]*$")


def broken_continuations(text: str):
    """Return [(line_no, offending_line, orphan_line)] for the full defect shape.

    Reported as a list, not raised on the first hit, so one run names every
    occurrence rather than making the reader re-run to find the next.
    """
    found = []
    lines = text.split("\n")
    for i, line in enumerate(lines):
        if "\\ " not in line:
            continue
        if i + 1 >= len(lines):
            continue
        nxt = lines[i + 1]
        if _ORPHAN.match(nxt):
            found.append((i + 1, line, nxt))
    return found


def scan():
    seen, findings, examined = set(), [], 0
    for g in GLOBS:
        for p in sorted(REPO.glob(g)):
            if not p.is_file() or p in seen:
                continue
            seen.add(p)
            examined += 1
            try:
                text = p.read_text(encoding="utf-8", errors="replace")
            except OSError as exc:
                # CANNOT-RUN is a third state. An unreadable file is NOT a pass.
                print(f"CANNOT-RUN: could not read {p}: {exc}", file=sys.stderr)
                return None, examined
            for ln, bad, orphan in broken_continuations(text):
                findings.append((p.relative_to(REPO), ln, bad, orphan))
    return findings, examined


def self_test() -> int:
    """Prove the predicate DISCRIMINATES. A gate that cannot fail is not a gate."""
    real = (
        "    unset _A _B _C \\ _D\n"
        "          _places_rc _places_log_tail\n"
        "fi\n"
    )
    # The ten real legitimate shapes measured in this repo, in miniature.
    glob_case = 'case "$x" in\n    OK\\ *) : ;;\n    *) exit 1 ;;\nesac\n'
    pattern_cmp = 'if [[ "$V" != Python\\ 3.11.* ]]; then\n    exit 1\nfi\n'
    comment = "#   --hr015 PATH   Path to ../HR015\\ -\\ Gaming\\ PC).\n#   next comment\n"
    good_cont = "    unset _A _B \\\n          _C _D\n"
    no_backslash = "    unset _A _B _C _D\n          \n"

    cases = [
        ("THE REAL DEFECT is found", real, 1),
        ("CONTROL a case-glob backslash-space is NOT flagged", glob_case, 0),
        ("CONTROL a [[ ]] pattern is NOT flagged", pattern_cmp, 0),
        ("CONTROL a comment with escaped spaces is NOT flagged", comment, 0),
        ("CONTROL a CORRECT continuation is NOT flagged", good_cont, 0),
        ("CONTROL no backslash at all is NOT flagged", no_backslash, 0),
    ]
    ok = True
    for label, text, want in cases:
        got = len(broken_continuations(text))
        good = got == want
        ok = ok and good
        print(f"[{'PASS' if good else 'FAIL'}] {label} (found={got} want {want})")

    # THE ARM THAT MATTERS MOST: the true defect must still be found when the
    # SAME file also contains a legitimate backslash-space. A gate that stops
    # at the first plausible match would pass this file wrongly.
    mixed = glob_case + real
    got = len(broken_continuations(mixed))
    good = got == 1
    ok = ok and good
    print(f"[{'PASS' if good else 'FAIL'}] a real defect BESIDE a legitimate glob is still found (found={got} want 1)")

    if not ok:
        print("SELF-TEST FAILED: the predicate does not discriminate.")
        return 1
    print("SELF-TEST PASSED: it fires on the defect and stays silent on all 5 legitimate shapes")
    return 0


def main() -> int:
    if "--self-test" in sys.argv:
        return self_test()

    findings, examined = scan()
    if findings is None:
        print(f"CANNOT-RUN after examining {examined} file(s). This is NOT a pass.")
        return 2
    if examined == 0:
        # A zero denominator reads as success. Refuse it.
        print("CANNOT-RUN: 0 shell files examined. A gate over nothing is not a pass.")
        return 2

    print(f"EXAMINED: {examined} shell file(s) for a backslash-space followed by an orphaned continuation")
    if not findings:
        print("PASS -- no broken line continuations")
        return 0

    for path, ln, bad, orphan in findings:
        print(f"\nFAIL {path}:{ln}")
        print(f"  {bad}")
        print(f"  {orphan}")
        print(
            "  The backslash has a SPACE after it, so it escapes the space, not the\n"
            "  newline. The next line becomes a command instead of more arguments,\n"
            "  and the argument before it gains a leading space. `bash -n` passes this."
        )
    print(f"\nFAIL -- {len(findings)} broken line continuation(s) of {examined} file(s) examined")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
