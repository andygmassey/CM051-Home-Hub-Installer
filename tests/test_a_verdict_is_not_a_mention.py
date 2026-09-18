#!/usr/bin/env python3
"""A row that DESCRIBES an unfinished verdict is not a row that DECLARES one.

WHY THIS EXISTS. `_is_ungated` decides whether a cut-manifest row carries
proof. During a cut an ungated row is BLOCKING and the cut stops, so a row
counted ungated by mistake stops a shippable cut for no reason, and a row
counted gated by mistake ships work nobody finished. Both directions are
expensive and they are not symmetrical: the second is worse.

Until now the unfinished markers were matched as plain substrings anywhere in
the gate text. Row 2114 is THE ROW ABOUT THE STRIKE. It has to quote the strike
sentence and list the markers in order to describe them, so the predicate read
the row's own documentation as the row's own verdict. It had been miscounted
since PR #2115 landed, and it surfaced only because two agents counted the same
field carefully and disagreed by exactly one.

WHAT THIS PINS, and the last arm is the one that matters. A rule that ignores
brackets can be bypassed by putting a real verdict in brackets. The shape that
actually occurs on this board is a row that does BOTH: quotes a marker while
describing something, and declares one about its own work. That row must still
be caught, and arm 5 fails if it is not.

Exit 0 all arms pass, 1 any arm fails, 2 the subject could not be reached.
"""
from __future__ import annotations

import os
import pathlib
import subprocess
import sys
import types

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests"))

PASS = 0
FAIL = 0


def ok(msg: str) -> None:
    global PASS
    PASS += 1
    print(f"  ok    {msg}")


def bad(msg: str, detail: str = "") -> None:
    global FAIL
    FAIL += 1
    print(f"  FAIL  {msg}")
    if detail:
        for line in str(detail).splitlines():
            print(f"        | {line}")


def cannot_run(msg: str) -> int:
    print(f"CANNOT-RUN: {msg}", file=sys.stderr)
    return 2


def _rows(obj, acc):
    if isinstance(obj, dict):
        if "issue" in obj:
            acc.append(obj)
        for v in obj.values():
            _rows(v, acc)
    elif isinstance(obj, list):
        for v in obj:
            _rows(v, acc)
    return acc


def _norm(r) -> str:
    return " ".join(str(r.get("gate", "")).upper().split())


def main() -> int:
    try:
        import test_the_cut_checklist_is_complete as subject
    except Exception as exc:  # pragma: no cover - import failure is CANNOT-RUN
        return cannot_run(f"cannot import the subject: {exc}")

    for name in ("_verdict_markers", "_mention_spans", "_is_ungated",
                 "_UNFINISHED_MARKERS"):
        if not hasattr(subject, name):
            return cannot_run(f"the subject has no {name}; it is not the module this test pins")

    manifests = sorted((ROOT / "cut-manifests").glob("v*.yaml"))
    if not manifests:
        return cannot_run("no per-cut manifest to read")
    board = max(manifests, key=lambda p: [int(x) for x in p.stem[1:].split(".")])
    rows = _rows(yaml.safe_load(board.read_text(encoding="utf-8")), [])
    if not rows:
        return cannot_run(f"{board.name} parsed to zero rows, so nothing was examined")
    by_issue = {str(r["issue"]): r for r in rows}
    print(f"EXAMINED: {len(rows)} rows in {board.name}")

    print()
    print("ARM 1: the finder WORKS. A marker declared in running prose is found.")
    # POSITIVE CONTROL FIRST. Every absence assertion below is worthless if the
    # finder cannot find anything at all, and an empty list prints identically
    # either way.
    control = "NOT STARTED, AND THERE IS NO FIX SURFACE IN THIS REPOSITORY."
    got = subject._verdict_markers(control)
    if got:
        ok(f"(1) the control gate yields {got}, so the finder is alive")
    else:
        bad("(1) the finder returned nothing on a gate that plainly declares one",
            control)

    print()
    print("ARM 2: five real rows that MUST keep their verdicts, from the board itself")
    must_keep = {
        "947": ["CANNOT FIX", "NO PR OPENED"],
        "948": ["NOT STARTED"],
        "942": ["NOT STARTED", "NOTHING WRITES"],
        "928": ["NOT STARTED"],
        "929": ["NOT STARTED"],
    }
    for issue, expected in must_keep.items():
        row = by_issue.get(issue)
        if row is None:
            bad(f"(2) row {issue} is not on {board.name}, so this arm measured nothing")
            continue
        found = subject._verdict_markers(_norm(row))
        if sorted(set(found)) == sorted(set(expected)):
            ok(f"(2) row {issue} still declares {sorted(set(found))}")
        else:
            bad(f"(2) row {issue} declares {sorted(set(found))}, expected {sorted(set(expected))}",
                "a row that says its own work is unfinished must stay ungated")

    print()
    print("ARM 3: row 2114 quotes all four markers and declares none of them")
    row = by_issue.get("2114")
    if row is None:
        bad("(3) row 2114 is not on the board, so this arm measured nothing")
    else:
        g = _norm(row)
        quoted = [m for m in subject._UNFINISHED_MARKERS if m in g]
        declared = subject._verdict_markers(g)
        if len(quoted) >= 3 and not declared:
            ok(f"(3) row 2114 mentions {len(quoted)} marker(s) and declares 0")
        elif not quoted:
            bad("(3) row 2114 quotes no marker at all, so this arm proves nothing",
                "the row was rewritten; re-measure before trusting the count")
        else:
            bad(f"(3) row 2114 declares {declared}", g[:300])

    print()
    print("ARM 4: MUST-MISS. Each shape of quotation is refused, each declaration is kept.")
    cases = [
        ("a bare declaration", "CANNOT FIX IN THIS REPOSITORY.", True),
        ("inside brackets", "SEVEN ROWS SAID SO (NOT STARTED, CANNOT FIX) LAST WEEK.", False),
        ("inside double quotes", 'THE MARKER IS THE PHRASE "NOT STARTED" AND NOTHING ELSE.', False),
        ("after a row citation", "INCLUDING ROW 953, NOTHING WRITES PREFERENCE NODES.", False),
        ("nested brackets", "A LIST (OUTER (INNER NOT STARTED) TAIL) ENDS HERE.", False),
    ]
    for label, text, want in cases:
        found = bool(subject._verdict_markers(text))
        if found == want:
            ok(f"(4) {label}: {'declared' if want else 'ignored'}, as required")
        else:
            bad(f"(4) {label}: got {'declared' if found else 'ignored'}, wanted "
                f"{'declared' if want else 'ignored'}", text)

    print()
    print("ARM 5: THE BYPASS ARM. Quoting a marker does not launder a declaration")
    print("       made in the same gate. This is the shape that actually occurs.")
    both = ("THE SEVEN ROWS WERE MARKED (NOT STARTED, CANNOT FIX). "
            "THIS ROW'S OWN WORK IS NOT STARTED AND NOBODY HAS PICKED IT UP.")
    found = subject._verdict_markers(both)
    if found:
        ok(f"(5) a gate that quotes AND declares is still caught: {sorted(set(found))}")
    else:
        bad("(5) a gate that quotes a marker in brackets hid its own declaration",
            both)

    print()
    print("ARM 6: the whole-board diff against the SHIPPED predicate on origin/main")
    try:
        src = subprocess.run(
            ["git", "-C", str(ROOT), "show",
             "origin/main:tests/test_the_cut_checklist_is_complete.py"],
            capture_output=True, text=True, check=True).stdout
    except Exception as exc:
        print(f"  CANNOT-RUN (6) origin/main blob unreachable: {exc}")
        print("        | not counted as a pass; the arm did not run")
        src = None
    if src is not None:
        shipped = types.ModuleType("_shipped")
        shipped.__dict__["__file__"] = str(ROOT / "tests" / "test_the_cut_checklist_is_complete.py")
        try:
            exec(compile(src, "<origin/main>", "exec"), shipped.__dict__)
        except Exception as exc:
            bad(f"(6) origin/main's predicate does not execute: {exc}")
            shipped = None
        if shipped is not None:
            if hasattr(shipped, "_verdict_markers") and hasattr(subject, "_verdict_markers"):
                # Both sides carry the fix, so the comparison is a thing
                # against itself and cannot fail. Say so rather than pass.
                print("  CANNOT-RUN (6) origin/main already carries the fix, so the")
                print("        | before/after diff has no before. Re-point the arm")
                print("        | at the last revision without it, or retire it.")
            else:
                before = {str(r["issue"]) for r in rows if shipped._is_ungated(r)}
                after = {str(r["issue"]) for r in rows if subject._is_ungated(r)}
                out = sorted(before - after, key=int)
                into = sorted(after - before, key=int)
                if out == ["2114"] and not into:
                    ok(f"(6) exactly one row moves: {len(before)} ungated to {len(after)}, "
                       f"out={out}, in={into}")
                else:
                    bad(f"(6) the diff is not the one that was justified: "
                        f"{len(before)} to {len(after)}, out={out}, in={into}",
                        "every moved row needs a person's justification, not an aggregate")

    print()
    print(f"=== {PASS} passed / {FAIL} failed ===")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
