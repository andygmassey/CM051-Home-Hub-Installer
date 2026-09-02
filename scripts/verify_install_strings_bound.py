#!/usr/bin/env python3
"""Every MSG_* string install.sh reads must exist in the catalogue.

WHY THIS GATE EXISTS

install.sh runs under `set -uo pipefail` (install.sh, the `set -uo pipefail`
line). Under nounset, reading a variable that was never assigned is not a blank
line and not a warning: bash prints `unbound variable` and the shell dies. In
install.sh that means the customer's install stops dead, part-way, on a string
that a developer simply forgot to add.

MEASURED when this gate was written: install.sh makes 940 distinct MSG_*
references and NOT ONE of them uses the `${VAR:-}` guarded form. So all 940 are
hard aborts if the catalogue drifts, and the catalogue is a separate file that
nothing linked them to.

It has already happened once. The browser-extension token block (B3b) shipped
referencing two strings that were never added; the block sits well below the
`set -uo pipefail` line, so it would have killed the install at that step. It
was found by hand, not by a gate, because no gate looked.

WHAT WAS ALREADY THERE AND WHY IT DID NOT CATCH IT

`.githooks/check-rule-09-strings.sh` exists and runs on every commit. It
contains zero occurrences of `MSG_`: it enforces that customer-facing text goes
through the catalogue, not that the catalogue actually answers. Those are
different properties and only one of them was covered.

THE FLOOR IS THE POINT

A gate that computes "missing = referenced - defined" prints a clean GREEN when
it parses nothing at all: empty minus empty is empty. So the anti-vacuity floor
below is not decoration, it is the only thing standing between a broken regex
and a permanently reassuring pass. It measures the same file with a DIFFERENT
instrument (a plain substring count, not the extraction regex), because a floor
that shares its subject's parser can only ever agree with it.

Exit codes, three states and not two:
    0  every referenced string is defined
    1  RED: at least one is not, and it is named
    2  CANNOT-RUN: a file is missing, or the parse produced a suspicious zero.
       This is NOT a pass. A check that could not run has not passed.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
INSTALL_SH = REPO / "install.sh"
CATALOGUE = REPO / "install.sh.strings.en-GB.sh"

# Any `$MSG_X` or `${MSG_X`, which is every way install.sh reads one.
RE_REFERENCE = re.compile(r"\$\{?(MSG_[A-Z0-9_]+)")
# `${MSG_X:-default}` and friends cannot abort under nounset. Excluded from the
# red set, still counted, so the report says how many are genuinely at risk.
RE_GUARDED = re.compile(r"\$\{(MSG_[A-Z0-9_]+):[-=?+]")
# An assignment at the start of a line, in either file.
RE_DEFINITION = re.compile(r"^\s*(?:local\s+|export\s+)?(MSG_[A-Z0-9_]+)=", re.M)


def _cannot_run(reason: str) -> int:
    print(f"install-strings-bound: CANNOT-RUN -- {reason}", file=sys.stderr)
    print("install-strings-bound: this is NOT a pass.", file=sys.stderr)
    return 2


def main() -> int:
    for path in (INSTALL_SH, CATALOGUE):
        if not path.is_file():
            return _cannot_run(f"{path.name} is not a readable file at {path}")

    sh = INSTALL_SH.read_text(errors="replace")
    cat = CATALOGUE.read_text(errors="replace")

    # INDEPENDENT INSTRUMENT for the floor. A plain substring count shares no
    # code with RE_REFERENCE, so if the regex silently stops matching, these two
    # disagree and we refuse rather than print a clean verdict over nothing.
    substring_hits = sh.count("MSG_")
    catalogue_substring_hits = cat.count("MSG_")

    references = set(RE_REFERENCE.findall(sh))
    guarded = set(RE_GUARDED.findall(sh))
    defined = set(RE_DEFINITION.findall(cat)) | set(RE_DEFINITION.findall(sh))

    if substring_hits == 0:
        return _cannot_run(
            "install.sh contains no 'MSG_' substring at all. Either the file is "
            "not the installer, or the whole string system has been replaced. "
            "Either way this gate is measuring the wrong thing."
        )
    if catalogue_substring_hits == 0:
        return _cannot_run(
            f"{CATALOGUE.name} contains no 'MSG_' substring at all, so the "
            "catalogue is empty or is not the catalogue."
        )
    if not references:
        return _cannot_run(
            f"the reference pattern matched 0 names, but the file contains "
            f"{substring_hits} 'MSG_' substrings. The extraction is broken; a "
            "zero here would otherwise read as a clean pass."
        )
    if not defined:
        return _cannot_run(
            f"the definition pattern matched 0 names, but the catalogue "
            f"contains {catalogue_substring_hits} 'MSG_' substrings."
        )

    at_risk = references - guarded
    missing = sorted(at_risk - defined)

    print(
        f"install-strings-bound: {len(references)} distinct MSG_ references, "
        f"{len(guarded)} of them ${{VAR:-}} guarded, "
        f"{len(at_risk)} able to abort under set -u, "
        f"{len(defined)} definitions available."
    )

    if missing:
        print()
        print(
            f"install-strings-bound: RED -- {len(missing)} referenced string(s) "
            "are not defined anywhere. Under `set -u` each one ABORTS the "
            "customer's install at the step that reads it:",
            file=sys.stderr,
        )
        for name in missing:
            # Name the first line that reads it, so the fix is one jump away.
            line_no = next(
                (
                    i
                    for i, line in enumerate(sh.splitlines(), 1)
                    if name in line and "$" in line
                ),
                None,
            )
            where = f"install.sh:{line_no}" if line_no else "install.sh"
            print(f"    {name}   first read at {where}", file=sys.stderr)
        print(
            f"\nAdd each to {CATALOGUE.name}.",
            file=sys.stderr,
        )
        return 1

    print("install-strings-bound: clean.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
