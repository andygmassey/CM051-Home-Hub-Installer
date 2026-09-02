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
import shlex
import subprocess
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

    # THE CATALOGUE MUST PARSE, AND THE NAMES MUST ACTUALLY BIND.
    #
    # ADDED after this gate MISSED a defect it existed to prevent, within an
    # hour of being written. Eight strings were added whose values contained a
    # mangled quote sequence. Every one matched RE_DEFINITION, so this gate
    # said "clean" -- and the catalogue no longer parsed as bash from that line
    # onward, so NOTHING after it bound and the install would have died.
    #
    # A NAME IN A FILE IS NOT A BOUND VARIABLE. That is the same
    # presence-is-not-behaviour mistake this gate was built to catch, made by
    # the gate itself. So ask bash, which is the thing that will actually read
    # this file at install time, rather than trusting a regex over text.
    #
    # bash is also a genuinely INDEPENDENT instrument from RE_DEFINITION: if
    # the two disagree about which names exist, one of them is wrong and this
    # refuses rather than picking a winner.
    probe = (
        "set -u; source " + shlex.quote(str(CATALOGUE)) + " >/dev/null 2>&1; "
        "compgen -v | grep '^MSG_'"
    )
    proc = subprocess.run(["/bin/bash", "-c", probe], capture_output=True, text=True)
    bound = {n for n in proc.stdout.split() if n.startswith("MSG_")}

    if not bound:
        return _cannot_run(
            f"sourcing {CATALOGUE.name} bound ZERO MSG_ names. The catalogue "
            "does not parse, or does not survive `set -u`. Run "
            f"`bash -n {CATALOGUE.name}` for the syntax error."
        )

    named_but_unbound = sorted(defined - bound)
    if named_but_unbound:
        print(
            f"install-strings-bound: RED -- {len(named_but_unbound)} name(s) "
            "look like definitions but do NOT bind when the catalogue is "
            "sourced. The usual cause is a broken quote earlier in the file, "
            "which silently kills every assignment after it:",
            file=sys.stderr,
        )
        for name in named_but_unbound[:20]:
            print(f"    {name}", file=sys.stderr)
        return 1

    at_risk = references - guarded
    # A name only counts as defined if bash agrees it binds.
    missing = sorted(at_risk - (defined & bound))

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
