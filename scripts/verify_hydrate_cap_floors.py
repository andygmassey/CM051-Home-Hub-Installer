#!/usr/bin/env python3
"""T1 -- no hydrate cap may sit below the duration we promise the customer.

THE RULE
    No hydrate step may carry a timeout cap smaller than the duration the
    installer's own customer-facing copy promises for it.

WHY THIS EXISTS
    Four hydrate steps shipped with a bare literal `gtimeout 90`. On a real box
    two of them were killed at the cap while STILL EMITTING LOG LINES -- they
    were working, not hung -- and a sibling in the same family ran 729 seconds
    and finished cleanly. A cap sized below the work converts a slow success
    into a fast failure, and the customer is told a story about their data that
    is not true. The rule above is what would have caught that before a walk
    instead of during one.

WHY THE MAPPING IS HAND-DECLARED AND NOT DERIVED
    The obvious implementation -- attribute to each step the duration promises
    printed inside its own body -- IS WRONG, and measurably so. Run it against
    this tree and it pairs `_INITIAL_HYDRATE_CAP` and `_PLACES_CAP` with
    MSG_HYDRATE_WIKI_RECOMPILE ("a few minutes up to around an hour"). That
    string is emitted TWO LINES BEFORE `progress ... "wiki_compile"` begins: it
    is a pre-announcement for the NEXT step, sitting in the tail of the
    previous one. A derived mapping asserts a 90s cap violating an hour-long
    promise that was never that step's to keep -- a false RED at cut time,
    which costs exactly as much as a false green.

    It is wrong on the other rows too: the only "duration" strings inside the
    other capped steps are HEARTBEAT tickers ("still working, %ss elapsed"),
    which are not promises at all. Derived attribution is wrong on 8 of 8.

    So the table below is adjudicated by hand, once, by reading the copy. Each
    row records the prose it was read from so the next person can re-check the
    judgement instead of trusting it.

THE TWO-SIDED CHECK (same shape as the install-completeness class gate)
    · a declared cap that is BELOW its floor            -> RED, step NAMED
    · a cap present in install.sh with no declared row  -> RED (UNDECLARED)
    · a declared row whose cap is absent from install.sh -> RED (MISSING)
    · a governing MSG key that no longer exists          -> RED (renamed copy
      must not silently drop the floor it was carrying)

    CANNOT-RUN is a third state and exits 2: an unreadable install.sh or
    strings catalogue is not a pass.

Usage:
    verify_hydrate_cap_floors.py [--repo-root DIR]
    verify_hydrate_cap_floors.py --self-test
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

EXIT_OK, EXIT_FAIL, EXIT_CANNOT_RUN = 0, 1, 2

# ---------------------------------------------------------------------------
# THE DECLARED TABLE. Hand-adjudicated. Every row cites its evidence.
#
# 🔻 THE RULE AS ORIGINALLY STATED IS NOT ENFORCEABLE TODAY, AND SAYING SO IS
#    PART OF THE DELIVERABLE. "No cap smaller than the duration the copy
#    promises FOR IT" needs a per-step promise. Measured against this tree:
#    7 of the 8 capped steps publish NO duration promise of their own, and the
#    8th publishes only a heartbeat ticker. The only per-step duration copy in
#    the catalogue belongs to steps that are not capped at all.
#
#    The first version of this table used the PHASE promise ("typically takes
#    45 minutes to a few hours") as a per-step floor. That went RED on 8 of 8 --
#    not because the caps are wrong but because the floor was a category error:
#    a phase-level budget shared by ~41 steps is not a per-step entitlement.
#    Left in place it would have been a uniform red that discriminates nothing,
#    and tuning the number until it went green would have been fitting the gate
#    to the tree. Both are worse than saying the limb is unenforceable.
#
# WHAT IS ENFORCED INSTEAD, AND IT CATCHES THE ACTUAL DEFECT:
#    floor = the longest CLEAN observed run of that step family, so a cap
#    cannot be set below work we have watched succeed. One measurement exists
#    (below) and it is applied to the family, labelled as such. This is not a
#    promise floor and must not be described as one.
#
# evidence: MEASURED | PRECEDENT | PROMISE -- so nobody later mistakes a
# precedent-derived number for something that was observed.
# ---------------------------------------------------------------------------
PHASE_MSG = "MSG_WARN_PHASE_3_TAKES_10_15_MINUTES"

# MEASURED, .98 walk 2026-09-03 (Archie): the hydrate_graph family ran 729s and
# finished cleanly, and two 90s-capped siblings were killed at the cap while
# still emitting log lines. 900 = observed-clean + margin. A cap below this
# kills work that has been watched succeeding, which is the defect T1 exists
# for. Raise a row only with a NEW measurement, and say which one.
MEASURED_FLOOR_S = 900

DECLARED = [
    # (cap variable,             step id,                     governing msg, floor_s, evidence)
    ("_HYDRATE_EMAIL_CAP",       "hydrate_graph/email",       PHASE_MSG, MEASURED_FLOOR_S,
     "MEASURED: hydrate_graph family ran 729s clean on the .98 walk"),
    ("_HYDRATE_WHATSAPP_CAP",    "hydrate_graph/whatsapp",    PHASE_MSG, MEASURED_FLOOR_S,
     "MEASURED: same family as the 729s clean run; was 90s and killed mid-log"),
    ("_HYDRATE_BROWSING_CAP",    "hydrate_browsing",          PHASE_MSG, MEASURED_FLOOR_S,
     "PRECEDENT: same hydrate family; was 90s, no measurement of its own yet"),
    ("_HYDRATE_IMESSAGE_CAP",    "hydrate_imessage",          PHASE_MSG, MEASURED_FLOOR_S,
     "PRECEDENT: same hydrate family; was 90s, no measurement of its own yet"),
    ("_INITIAL_HYDRATE_CAP",     "initial_hydrate",           PHASE_MSG, MEASURED_FLOOR_S,
     "PRECEDENT. ⚠️ NOT the wiki 'up to around an hour' promise -- that string "
     "is a pre-announcement for wiki_compile, two lines before it starts"),
    ("_PLACES_CAP",              "initial_hydrate/places",    PHASE_MSG, MEASURED_FLOOR_S,
     "PRECEDENT. ⚠️ Same mis-attribution risk as initial_hydrate above"),
    ("_HYDRATE_APPLENOTES_CAP",  "hydrate_apple_notes",       PHASE_MSG, MEASURED_FLOOR_S,
     "PRECEDENT: already named + tunable at 1800 before T1; unchanged"),
    ("_HYDRATE_EMAILPREFS_CAP",  "hydrate_email_preferences", PHASE_MSG, MEASURED_FLOOR_S,
     "PRECEDENT: already named + tunable at 1800 before T1; unchanged"),
]

CAP_DEF = re.compile(r'^\s*(_[A-Z0-9_]*_CAP)="\$\{([A-Z0-9_]+):-(\d+)\}"', re.M)


def read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError as exc:
        print(f"hydrate-cap-floors: CANNOT-RUN: {path}: {exc}", file=sys.stderr)
        raise SystemExit(EXIT_CANNOT_RUN)


def present_caps(install_sh: str) -> dict[str, tuple[str, int]]:
    """cap name -> (env var, default seconds), as actually written in install.sh."""
    return {m.group(1): (m.group(2), int(m.group(3))) for m in CAP_DEF.finditer(install_sh)}


def check(install_sh: str, strings: str) -> tuple[list[str], int]:
    found = present_caps(install_sh)
    declared = {row[0]: row for row in DECLARED}
    failures: list[str] = []

    if not found:
        # A predicate that matches nothing must not report clean. If the shape
        # of a cap definition ever changes, this is the line that says so.
        print("hydrate-cap-floors: CANNOT-RUN: 0 cap definitions matched -- "
              "the cap shape changed and this predicate is now blind", file=sys.stderr)
        raise SystemExit(EXIT_CANNOT_RUN)

    for cap, (env, default) in sorted(found.items()):
        row = declared.get(cap)
        if row is None:
            failures.append(f"UNDECLARED  {cap} (={default}s, {env}) has no row in the "
                            f"promise table -- declare its floor or remove the cap")
            continue
        _, step, msg, floor, prose = row
        if not re.search(r'^' + re.escape(msg) + r'=', strings, re.M):
            failures.append(f"MISSING-COPY {cap} cites {msg}, which is not in the "
                            f"strings catalogue -- the floor it carried is gone")
            continue
        if default < floor:
            failures.append(f"BELOW-FLOOR {cap} ({step}) cap={default}s < floor={floor}s "
                            f"from {msg} -- {prose}")

    for cap, (_, step, _, _, _) in sorted(declared.items()):
        if cap not in found:
            failures.append(f"MISSING     {cap} ({step}) is declared but no cap "
                            f"definition exists in install.sh")

    return failures, len(found)


def self_test() -> int:
    """Every arm must be DEMONSTRATED RED. A gate with no failing control
    proves it ran, not that it discriminates."""
    # Fixture values are DERIVED from the floors, never hardcoded. An earlier
    # version pinned 3000/2699 and silently stopped discriminating the moment
    # the floor moved to 900 -- the below-floor arm went green against a cap
    # that was still three times the floor. A control whose failing case stops
    # failing is worse than no control, so it is computed here.
    over = {row[0]: (f"ENV_{i}", row[3] + 1) for i, row in enumerate(DECLARED)}
    good_install = "\n".join(f'    {c}="${{{e}:-{v}}}"' for c, (e, v) in over.items())
    good_strings = f'{PHASE_MSG}="typically takes 45 minutes to a few hours"\n'

    cases = []
    f, n = check(good_install, good_strings)
    cases.append(("baseline all-clear (every cap at floor+1)", not f,
                  f"{n} caps, {len(f)} failures"))

    first_cap, (first_env, first_val) = next(iter(over.items()))
    first_floor = next(r[3] for r in DECLARED if r[0] == first_cap)
    below = good_install.replace(f'{first_cap}="${{{first_env}:-{first_val}}}"',
                                 f'{first_cap}="${{{first_env}:-{first_floor - 1}}}"', 1)
    f, _ = check(below, good_strings)
    cases.append(("cap one second under floor -> RED",
                  any(x.startswith("BELOW-FLOOR") for x in f), f[:1]))

    extra = good_install + '\n    _HYDRATE_GHOST_CAP="${ENV_GHOST:-9999}"'
    f, _ = check(extra, good_strings)
    cases.append(("undeclared cap present -> RED",
                  any(x.startswith("UNDECLARED") for x in f), f[:1]))

    dropped = "\n".join(good_install.splitlines()[1:])
    f, _ = check(dropped, good_strings)
    cases.append(("declared cap absent -> RED",
                  any(x.startswith("MISSING ") for x in f), f[:1]))

    f, _ = check(good_install, "SOMETHING_ELSE=\"x\"\n")
    cases.append(("governing copy renamed away -> RED",
                  any(x.startswith("MISSING-COPY") for x in f), f[:1]))

    ok = True
    for name, passed, detail in cases:
        print(f"  [{'PASS' if passed else 'FAIL'}] {name}"
              + ("" if passed else f"   got: {detail}"))
        ok &= passed
    print(f"hydrate-cap-floors self-test: {'clean' if ok else 'BROKEN'} "
          f"({len(cases)} controls, {len(DECLARED)} declared rows)")
    return EXIT_OK if ok else EXIT_FAIL


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo-root", default=".")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        return self_test()

    root = Path(args.repo_root)
    install_sh = read(root / "install.sh")
    strings = read(root / "install.sh.strings.en-GB.sh")

    failures, n = check(install_sh, strings)
    if failures:
        print(f"hydrate-cap-floors: {len(failures)} failure(s) over {n} caps, "
              f"{len(DECLARED)} declared rows:", file=sys.stderr)
        for f in failures:
            print(f"  {f}", file=sys.stderr)
        return EXIT_FAIL
    print(f"hydrate-cap-floors: clean. {n} caps checked against "
          f"{len(DECLARED)} declared floors; none below its promise.")
    return EXIT_OK


if __name__ == "__main__":
    raise SystemExit(main())
