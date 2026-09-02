#!/usr/bin/env python3
"""Fail the cut if any shipped Python entrypoint defines a name AFTER its
``if __name__ == "__main__":`` guard.

WHY THIS EXISTS (v1.0.16 walk, 2026-08-07)
------------------------------------------
`vendor/cm059_editor/compiler/emit_frontpage.py` called `_read_feed()` from
`emit()`, and defined `_read_feed` 4 lines BELOW the `__main__` guard. Run as
a module (`import`), the whole file executes first and the name binds fine --
so every test passed. Run as a SCRIPT, which is exactly how the LaunchAgent
runs it, Python reaches the guard and calls `main()` before it ever executes
that `def`. Result: `NameError: name '_read_feed' is not defined`, on every
single tick, for the entire life of the release.

The Front Page still LOOKED alive because the degraded-feed guard preserves
the last good feed -- so the failure presented as "the Front Page never
updates", not as a crash. That is the worst kind of defect: silent, and
masked by a feature working as designed.

The lesson is not "remember to order your defs". It is that **tests import
and production executes**, and nothing checked the difference. This does.

Exit 0 = clean, 1 = at least one offender.
"""
from __future__ import annotations

import ast
import pathlib
import sys

# Only the trees we actually ship. Tests may legitimately define helpers after
# a guard because they are never run as scripts.
SHIP_ROOTS = ("vendor", "scripts", "lib")
SKIP_PARTS = {".git", "node_modules", "__pycache__", "tests", "test",
              ".venv", "venv", "site-packages"}


def offenders(path: pathlib.Path) -> list[tuple[str, int, int]]:
    """Return (name, def_line, guard_line) for each top-level def/class that
    is unreachable when the file is executed as a script."""
    try:
        tree = ast.parse(path.read_text(encoding="utf-8"))
    except (SyntaxError, UnicodeDecodeError):
        return []  # not our problem; the syntax gate owns that

    guard_line = None
    for node in tree.body:
        if isinstance(node, ast.If):
            dumped = ast.dump(node.test)
            if "__main__" in dumped and "__name__" in dumped:
                guard_line = node.lineno
                break
    if guard_line is None:
        return []

    bad = []
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            if node.lineno > guard_line:
                bad.append((node.name, node.lineno, guard_line))
        elif isinstance(node, ast.Assign) and node.lineno > guard_line:
            for tgt in node.targets:
                if isinstance(tgt, ast.Name):
                    bad.append((tgt.id, node.lineno, guard_line))
    return bad


def main() -> int:
    repo = pathlib.Path(__file__).resolve().parent.parent
    found = 0
    scanned = 0

    for root in SHIP_ROOTS:
        base = repo / root
        if not base.is_dir():
            continue
        for py in base.rglob("*.py"):
            if SKIP_PARTS & set(py.parts):
                continue
            scanned += 1
            for name, line, guard in offenders(py):
                found += 1
                rel = py.relative_to(repo)
                print(f"RED {rel}:{line}: '{name}' is defined AFTER the "
                      f"__main__ guard (line {guard}). Running this file as a "
                      f"script raises NameError before this line executes.")

    if found:
        print(f"\n{found} unreachable top-level definition(s) across "
              f"{scanned} shipped .py files.")
        print("Fix: move the definition ABOVE the `if __name__ == \"__main__\":` "
              "block. Tests that import the module cannot catch this.")
        return 1

    # ANTI-VACUITY FLOOR (A2 silence sweep, tier 3 item 7). Without this the
    # line below prints GREEN with scanned=0 -- a clean verdict over an empty
    # denominator, which is the same shape as the vendor-gate fail-open closed
    # in 2e1ef10f. A discovery glob that stops matching (a directory rename, a
    # moved shipped tree) turns this gate off silently and it keeps saying
    # GREEN. CANNOT-RUN is exit 2, distinct from the RED exit 1 above: "found
    # nothing" and "could not look" are different answers.
    if scanned == 0:
        print("CANNOT-RUN: examined 0 shipped .py files, so this gate proved "
              "nothing. That is NOT a pass -- an unexamined file is exactly "
              "the state it exists to refuse. Check the discovery glob.")
        return 2

    print(f"GREEN no definitions after a __main__ guard ({scanned} shipped "
          f".py files scanned)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
