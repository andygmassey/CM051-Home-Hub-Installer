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
    # THE ONLY ROW WHERE THE PROMISE LIMB IS ACTUALLY ENFORCEABLE. Contacts is
    # the one capped step that publishes a duration promise of its own:
    # MSG_INFO_PLEASE_WAIT_READING_CONTACTS -- "large libraries can take a
    # couple of minutes". That promise floor is 120s; the measured family floor
    # of 900s is higher, so 900 governs and the promise clears comfortably.
    # Recorded because it is the existence proof that the briefed rule CAN be
    # enforced once per-step copy exists -- today it exists exactly once.
    ("_HYDRATE_CONTACTS_CAP",    "hydrate_graph/contacts",  "MSG_INFO_PLEASE_WAIT_READING_CONTACTS",
     MEASURED_FLOOR_S,
     "PROMISE 'a couple of minutes' = 120s, cleared; MEASURED family floor 900s governs"),
    # ── #628. A READINESS WAIT, NOT A HYDRATE CAP. Read the floor before the row.
    #
    # This one is caught by CAP_DEF because it is spelled `_CAP`, and declaring
    # it here is the right answer rather than renaming it to dodge the regex.
    # But it is NOT a member of the hydrate family, so MEASURED_FLOOR_S (900,
    # "longest clean observed run of that family") does not apply: this is a
    # liveness probe against a local container, not a pass over a customer's
    # mailbox. Borrowing 900 would assert an observation nobody made.
    #
    # ⚠️ THE FLOOR IS 60, NOT 300, AND THE GAP IS THE POINT. Setting the floor
    # equal to the cap would be TAUTOLOGICAL -- unfailable by construction, the
    # same defect as #171's version gate. What we actually measured on the
    # v1.0.61 walk is the NEGATIVE: 30 attempts were INSUFFICIENT, the store had
    # not answered, and the installer went on to discard 3810 of 3810 people
    # (#624). So the floor encodes the one fact in evidence -- 30s is too few --
    # at 2x the value watched failing. The cap sits at 300 with headroom, and
    # anyone lowering it back toward the value we watched fail turns this RED.
    #
    # NO CLEAN RUN OF THIS WAIT HAS BEEN OBSERVED. This is therefore NOT a
    # clean-run floor and must not be described as one, nor raised to 900 by
    # analogy. Replace it with a real number the first time a walk records how
    # long the store actually took to answer, and say which walk.
    ("_QDRANT_READY_CAP",        "graph_db_start",            PHASE_MSG, 60,
     "MEASURED-INSUFFICIENT: 30s watched FAILING on the v1.0.61 walk (#624); "
     "floor = 2x the value observed failing. No clean run observed -- NOT a "
     "clean-run floor, and deliberately below the 300s cap so it can fail"),
    # ⚠️ A DIFFERENT LOOP FROM _QDRANT_READY_CAP ABOVE, AND THE ONE THAT BITES.
    # That one guards graph_db_start and was fine on the v1.0.67 cold walk. THIS
    # one is the wait inside _ostler_ensure_qdrant_collections, which is what
    # ERR-14-STORE-NOT-READY-FOR-IMPORT tests, and its call site is inside
    # cm019_setup -- the step that went ERROR at 132s on that cold walk against
    # this 120s budget.
    #
    # Until 2026-09-05 it was written `local _max="${OSTLER_QDRANT_READY_WAIT_S:-120}"`
    # and CAP_DEF could not see it, so NEITHER protection in this file reached
    # it: not BELOW-FLOOR, and not the UNDECLARED arm that exists to catch
    # exactly a budget nobody declared. 10 caps discoverable, this one 0 of 10.
    #
    # FLOOR = THE SHIPPED VALUE, WHICH IS A RATCHET AND NOT A MEASUREMENT. It
    # asserts only "never lower than today". There is ONE cold observation
    # (>460s to readiness, archie@.240, 2026-09-05) and one observation is not a
    # floor. Raise this the first time a SECOND cold walk agrees, and say which
    # walks -- the same discipline the row above states for itself.
    ("_QDRANT_COLLECTIONS_READY_CAP", "cm019_setup",             PHASE_MSG, 300,
     "RAISED 120 -> 300 ON THE SECOND COLD OBSERVATION, which is the condition "
     "the previous note set for itself. v1.0.67 archie cold: cm019_setup ERROR "
     "at 132s. v1.0.68 archie2 VIRGIN: ERROR at 136s rc=1, DONE status=fail "
     "ERR-14-STORE-NOT-READY-FOR-IMPORT, with graph_db_start itself at 327s. "
     "Both against a 120s budget, both on the Mini 16. The argument is not "
     "'bigger' but that ONE store had TWO budgets 2.5x apart: the sibling "
     "_QDRANT_READY_CAP guards the same Qdrant at 300s and passed both walks "
     "while this one failed both. Still a RATCHET AT THE SHIPPED VALUE and "
     "still NOT a claim that 300 suffices -- only that it is proven better "
     "than 120 twice, and is the value its sibling already uses"),
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
    # DERIVED, for the same reason the cap values are: the first version hardcoded
    # only PHASE_MSG, so the moment a row cited a different governing key the
    # BASELINE arm started failing on a fixture gap rather than on a real defect.
    # Every governing key in the table gets a synthetic definition.
    good_strings = "".join(f'{row[2]}="synthetic duration copy for the self-test"\n'
                           for row in DECLARED)

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
