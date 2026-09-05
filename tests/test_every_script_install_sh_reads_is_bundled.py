#!/usr/bin/env python3
"""Every path install.sh reads under ${OSTLER_DIR}/scripts/ must be bundled there.

WHY THIS EXISTS. MEASURED on archie2, a virgin account on the Mini 16, walking
the v1.0.68 DMG on 2026-09-05, on a run that ended
`DONE status=ok failed_steps=0 errors=0`:

    WARN step=tailscale_connect
         msg=Namespace migrator not found at
             ~/.ostler/scripts/migrate_graph_namespace.py; skipping

install.sh builds that path itself at :24910 and warns about it at :24942. The
bundle phase in gui/project.yml copied exactly ONE file into `scripts/`, so that
warning has fired on every install ever made and the migration it guards has
never once run on a customer Mac.

THE CLASS, AND WHY A CALLER-ONLY FIX IS NOT A FIX. install.sh:24873 records that
`scripts/migrate_graph_namespace.py` "existed and NOTHING CALLED IT". Adding the
caller without adding the bundling line MOVED the defect: before, it shipped and
nothing ran it; after, something ran it and it did not ship. Both states leave
every customer in the pre-migration namespace, and the second is quieter, because
the install prints a WARN and stays green.

WHAT THIS ASSERTS, AND WHAT IT DELIBERATELY DOES NOT. It asserts that the two
halves of one contract agree: for every literal `${OSTLER_DIR}/scripts/<name>`
install.sh reads, gui/project.yml must contain a bundling line that puts
`<name>` into `Resources/scripts/`. It does NOT assert that the file works, that
the caller is correct, or that the migration succeeds. Those are runtime
questions and this is a contract question.

SIBLING, NOT DUPLICATE. CM051 #1552 asks "does each bundled package come from the
source its OWN cp line names" -- it walks from the bundler outward. This walks
from the CALLER inward and finds the opposite failure: a path with no bundler at
all. A package bundled from the wrong place and a file bundled from nowhere are
different defects and #1552 cannot see the second.

THREE STATES. 0 pass, 1 fail, 2 cannot-run.
"""
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
INSTALL = REPO / "install.sh"
PROJECT = REPO / "gui" / "project.yml"


def cannot_run(msg: str) -> "None":
    print(f"CANNOT-RUN: {msg}", file=sys.stderr)
    raise SystemExit(2)


for f in (INSTALL, PROJECT):
    if not f.is_file():
        cannot_run(f"{f} is not a file; nothing was compared")

install_src = INSTALL.read_text(errors="replace")
project_src = PROJECT.read_text(errors="replace")

# Paths install.sh constructs under its own scripts/ directory. Both spellings,
# because install.sh uses ${OSTLER_DIR} and ${SCRIPT_DIR} for the same tree at
# different phases and a pattern that knows only one of them is half a search.
PAT = re.compile(
    r"\$\{(?:OSTLER_DIR|SCRIPT_DIR)(?::-[^}]*)?\}/scripts/([A-Za-z0-9._-]+)"
)
wanted = sorted(set(PAT.findall(install_src)))

# 🔴 A KNOWN-SPELLINGS PATTERN ASSERTS OVER A SUBSET AND PRINTS A TOTAL.
#
# TNM broke this by injecting ONE line into install.sh:
#
#     _mutant_helper="${RESOURCES_DIR}/scripts/a_third_spelling.sh"
#
# and the gate returned:
#
#     install.sh reads 2 file(s) from its own scripts/ directory:
#       bundled  deferred-register-device.sh
#       bundled  migrate_graph_namespace.py
#     PASS  rc=0
#
# Green, on a tree with an unbundled script it reads. And the harm is worse
# than an incomplete check: it PRINTS "2 file(s)" when the answer is 3, so a
# reader has a number to trust and the number is wrong. The anti-vacuity guard
# below cannot catch it -- it fires only on EMPTY, and a pattern degrading from
# three to two passes with a confident total.
#
# NOT a hardcoded floor, which would need bumping every time a script is added.
# Count ANY variable prefix and require the two sets to AGREE: if install.sh
# reads scripts/ through a variable this file does not know, that is CANNOT-RUN
# and the unknown name is printed. It reddens the instant a third appears.
#
# TRUE NEGATIVE, recorded so nobody widens the regex to fix it: the only other
# `/scripts/` prefix in the file is `.github/scripts/`, a CI path. Matching
# "everything with /scripts/" would start demanding CI scripts ship in the .app.
ANYVAR = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-[^}]*)?\}/scripts/[A-Za-z0-9._-]+")
_seen_vars = {v for v in ANYVAR.findall(install_src)}
_unknown = _seen_vars - {"OSTLER_DIR", "SCRIPT_DIR"}
if _unknown:
    cannot_run(
        "install.sh reads scripts/ through variable(s) this gate does not know: "
        + ", ".join(sorted(_unknown))
        + ". The known-spellings pattern would assert over a SUBSET while "
        "printing a total, which is worse than not checking: the number would "
        "be stated and wrong. Add the spelling here, or explain why it is not "
        "a payload path."
    )

# A ZERO HERE IS A BROKEN PREDICATE, NOT A CLEAN TREE. install.sh has read files
# out of scripts/ since v1.0.12; if this finds nothing the regex has rotted and
# every assertion below would pass vacuously.
if not wanted:
    cannot_run(
        "found NO ${OSTLER_DIR}/scripts/<file> references in install.sh. "
        "install.sh has read that directory for dozens of versions, so this is "
        "a dead pattern rather than a clean tree, and a pass would be vacuous."
    )

missing = []
for name in wanted:
    # The bundler must name the file on a copy INTO Resources/scripts/. Matching
    # the bare filename anywhere in project.yml is what #1552 proved insufficient:
    # a needle found anywhere does not bind a package to a source.
    copied = re.search(
        r"cp\s+\"?\$\{[A-Za-z_][A-Za-z0-9_]*\}\"?\s+\"?\$\{DEST\}/scripts/"
        + re.escape(name),
        project_src,
    )
    # 🔴 NO SUBSTRING FALLBACK. My first draft accepted `"/scripts/<name>" in
    # project_src` as a second chance, which is precisely the needle-anywhere
    # test #1552 has just proved insufficient -- a filename mentioned in a
    # comment, an inputFiles entry or a neighbouring package's path would have
    # satisfied it. The COPY is the thing that puts the file in the bundle, so
    # the copy is what must be found.
    if not copied:
        missing.append(name)

print(f"install.sh reads {len(wanted)} file(s) from its own scripts/ directory:")
for name in wanted:
    print(f"  {'MISSING FROM BUNDLER' if name in missing else 'bundled':<21} {name}")

if missing:
    print()
    print("FAIL: install.sh reads a path the bundler never creates.", file=sys.stderr)
    for name in missing:
        print(
            f"  scripts/{name} is read by install.sh and has no bundling line in "
            f"gui/project.yml, so the shipped .app cannot contain it.",
            file=sys.stderr,
        )
    print(
        "\n  A caller without a bundler is not a smaller defect than a bundler "
        "without a caller. It is the same defect, quieter: the install warns "
        "and stays green.",
        file=sys.stderr,
    )
    raise SystemExit(1)

print(f"\nPASS: all {len(wanted)} script(s) install.sh reads are bundled into Resources/scripts/.")
raise SystemExit(0)
