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
measured rather than assumed. The sweep used to reach only 645 of the 708
real shell files that ship or run in this tree (measured 2026-09-12; earlier
counts differ as the tree grows and shrinks) -- everything under lib/,
bin/, gui/scripts/, tools/, .githooks/, .github/scripts/ and every vendor/
subtree was invisible to it, including live runtime scripts such as
lib/ostler-model-fit.sh, lib/ostler-container-engine.sh,
lib/ostler-ingest-slot.sh, bin/ostler-engine-supervisor.sh and
bin/require_signing_secrets.sh. It now sweeps every `.sh` file this repo
tracks (see _tracked_shell_files below), and on the full population that is
36 backslash-spaces across 13 files, all legitimate -- `case` globs
(`OK\\ *)`, `AUTHFAIL\\ *)`, `PERMISSION_ERROR*Full\\ Disk\\ Access*)`), `[[ ]]`
pattern comparisons, and escaped paths inside comments. Banning the character
outright would be dozens of false accusations, and a gate that cries wolf that
often gets switched off. So the predicate asks for the FULL defect shape, both
halves:

    a line containing `\\ `  AND  a following line that is an ORPHANED
    CONTINUATION -- indented, and consisting only of bare identifiers, which
    is precisely the thing that would run as a command and not be found.

That pair is what makes it a bug rather than a glob. Proved against the real
population below: 1 of 1 on the true defect, 0 of 5 on the legitimate shapes
in miniature -- and, on the actual tree, 0 of 36 real backslash-spaces across
708 tracked shell files.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# 🔴 THIS USED TO BE A HAND-MAINTAINED GLOB TUPLE --
# ("install.sh", "*.sh", "scripts/**/*.sh", "tests/**/*.sh") -- and it reached
# 645 of the 708 real shell files in the tree (measured 2026-09-12). Missing:
# everything under lib/, bin/, gui/scripts/, tools/, .githooks/,
# .github/scripts/, and every vendor/ subtree -- 63 files, including live
# runtime scripts that ship and run (lib/ostler-model-fit.sh,
# lib/ostler-container-engine.sh, lib/ostler-ingest-slot.sh,
# bin/ostler-engine-supervisor.sh, bin/require_signing_secrets.sh among
# them). The docstring above claimed a full sweep and the code never printed
# the true denominator, so the gap was invisible: EXAMINED read a real,
# honestly-counted number, and that number was quietly wrong for what "no
# broken line continuations" actually means.
#
# The population is now every `.sh` file this repo TRACKS, via `git
# ls-files` -- not a glob tuple that has to be remembered and extended by
# hand every time a new directory ships a shell script. An untracked file is
# by definition not what ships; a tracked one always is, wherever it lives.
def _tracked_shell_files() -> list[Path] | None:
    """Every .sh file `git ls-files` reports, relative to REPO.

    Returns None (never an empty list standing in for "nothing to check") if
    git itself could not answer -- CANNOT-RUN, not a silent fall-back to a
    narrower population that would reintroduce exactly the gap this rewrite
    closes.
    """
    try:
        proc = subprocess.run(
            ["git", "ls-files", "-z"],
            cwd=REPO,
            capture_output=True,
            check=True,
            timeout=30,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
        print(f"CANNOT-RUN: 'git ls-files' failed: {exc}", file=sys.stderr)
        return None
    names = proc.stdout.decode("utf-8", errors="replace").split("\0")
    return sorted(REPO / n for n in names if n.endswith(".sh") and n)


# 🔴 FAIL RATHER THAN PASS IF THE DENOMINATOR COLLAPSES. This is a sanity
# floor on the ENUMERATION itself, not a policy about the repo's shell-file
# count: it exists so a future regression in _tracked_shell_files (wrong cwd,
# a `git ls-files` that silently narrows, this script moved to a
# subdirectory) is caught as a FAILURE, not read as "a very clean run".
# Measured on this tree at the time of this fix: 708 tracked .sh files. Set
# well below that and well above zero, so a genuine, deliberate future shrink
# of the population only needs this constant moved in the same PR -- the same
# ratchet discipline other gates in this repo apply via a tracked baseline
# file (e.g. tests/condition_function_pipeline_baseline.txt); this one is
# small enough to keep inline rather than adding a fourth file to maintain.
MIN_EXPECTED_SHELL_FILES = 400

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


def denominator_collapsed(total: int) -> bool:
    """True when the enumerated population is implausibly small.

    A separate, directly-testable function rather than an inline comparison,
    so self_test can pin BOTH sides of the floor without stubbing subprocess
    or the filesystem.
    """
    return total < MIN_EXPECTED_SHELL_FILES


def scan():
    """Returns (findings, examined, total).

    findings is None on CANNOT-RUN (enumeration failed, or a tracked file
    could not be read/was missing from the working tree) -- examined and
    total are still meaningful in that case, so the caller can report how far
    the sweep got before it had to stop.
    """
    tracked = _tracked_shell_files()
    if tracked is None:
        return None, 0, 0

    total = len(tracked)
    findings: list[tuple[Path, int, str, str]] = []
    examined = 0
    for p in tracked:
        if not p.is_file():
            # Tracked by git but absent from the working tree. Not silently
            # subtracted from the denominator -- that is exactly how a gap
            # would hide again -- CANNOT-RUN instead, naming the file.
            print(
                f"CANNOT-RUN: {p} is tracked by git but not present in the working tree",
                file=sys.stderr,
            )
            return None, examined, total
        examined += 1
        try:
            text = p.read_text(encoding="utf-8", errors="replace")
        except OSError as exc:
            # CANNOT-RUN is a third state. An unreadable file is NOT a pass.
            print(f"CANNOT-RUN: could not read {p}: {exc}", file=sys.stderr)
            return None, examined, total
        for ln, bad, orphan in broken_continuations(text):
            findings.append((p.relative_to(REPO), ln, bad, orphan))
    return findings, examined, total


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

    # THE DENOMINATOR-COLLAPSE FLOOR. Two arms, both sides of it, exactly as
    # boundary arms are pinned elsewhere in this suite: a plainly-collapsed
    # count must trip it, and the real, live population on THIS checkout
    # must not.
    collapsed_got = denominator_collapsed(3)
    good = collapsed_got is True
    ok = ok and good
    print(f"[{'PASS' if good else 'FAIL'}] a 3-file enumeration is a collapsed denominator (got {collapsed_got})")

    live = _tracked_shell_files()
    if live is None:
        ok = False
        print("[FAIL] CONTROL could not run: 'git ls-files' failed on this checkout, so the live-population arm below is unmeasured")
    else:
        live_total = len(live)
        good = not denominator_collapsed(live_total)
        ok = ok and good
        print(
            f"[{'PASS' if good else 'FAIL'}] CONTROL: the real population on this checkout "
            f"({live_total} tracked .sh files) is NOT a collapsed denominator "
            f"(floor is {MIN_EXPECTED_SHELL_FILES})"
        )

    if not ok:
        print("SELF-TEST FAILED: the predicate does not discriminate.")
        return 1
    print("SELF-TEST PASSED: it fires on the defect and stays silent on all 5 legitimate shapes, and the denominator floor discriminates a collapsed count from the real population")
    return 0


def main() -> int:
    if "--self-test" in sys.argv:
        return self_test()

    findings, examined, total = scan()
    if findings is None:
        print(f"CANNOT-RUN after examining {examined} of {total} tracked shell file(s). This is NOT a pass.")
        return 2
    if denominator_collapsed(total):
        print(
            f"FAIL -- denominator collapsed: only {total} tracked .sh file(s) found "
            f"(floor is {MIN_EXPECTED_SHELL_FILES}). Either this is a real, deliberate "
            f"shrink of the shell-file population -- move MIN_EXPECTED_SHELL_FILES down "
            f"in the SAME PR -- or the enumeration itself broke (wrong cwd, a narrowed "
            f"'git ls-files', this script moved). Either way, reporting a clean sweep "
            f"over a silently-shrunk population is the exact failure this gate exists "
            f"to prevent, so this is a FAIL rather than a PASS over less than it claims."
        )
        return 1
    if examined == 0:
        # A zero denominator reads as success. Refuse it.
        print("CANNOT-RUN: 0 shell files examined. A gate over nothing is not a pass.")
        return 2
    if examined != total:
        # Should be unreachable given scan()'s own control flow (any gap
        # already returns findings=None above), but a silent mismatch must
        # never stand in for the CANNOT-RUN it would actually be.
        print(f"CANNOT-RUN: examined {examined} of {total} tracked shell file(s); {total - examined} were never read.")
        return 2

    print(f"EXAMINED: {examined} of {total} tracked shell file(s) for a backslash-space followed by an orphaned continuation")
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
