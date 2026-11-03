#!/usr/bin/env python3
"""Every seeded .pyc on the image was compiled from the .py beside it.

The DMG ships unchecked-hash bytecode (walk_dmg.sh ARM 7, seed-hub-payload-pyc.sh):
Python NEVER compares it with its source, so a .py edited after seeding is
shipped as DEAD text while the old bytecode runs, and nothing would say so
(found 2026-11-04 on Mini16: a source edit to ostler_fda was silently ignored).
An unchecked-hash .pyc still stores its source's SipHash at bytes 8-16, keyed
by its own magic number, so this compares them for every .pyc that has a .py.

Usage: verify_seeded_pyc_matches_source.py <root> [--require <path-fragment>]
Exit: 0 every examined .pyc matches; 1 a mismatch; 2 CANNOT-RUN (nothing
examined, or no .pyc under a --require fragment, or a file unreadable).
"""
from __future__ import annotations

import os
import sys

import _imp


def source_of(pyc: str) -> str | None:
    head, name = os.path.split(pyc)
    if os.path.basename(head) != "__pycache__":
        return None
    stem = name.split(".", 1)[0]
    return os.path.join(os.path.dirname(head), stem + ".py")


def check(root: str, require: list[str]) -> int:
    examined = mismatched = unreadable = no_source = 0
    required = {r: 0 for r in require}
    bad: list[str] = []
    for d, _dirs, files in os.walk(root):
        for f in files:
            if not f.endswith(".pyc"):
                continue
            pyc = os.path.join(d, f)
            src = source_of(pyc)
            if not src or not os.path.isfile(src):
                no_source += 1
                continue
            try:
                with open(pyc, "rb") as fh:
                    head = fh.read(16)
                with open(src, "rb") as fh:
                    body = fh.read()
            except OSError:
                unreadable += 1
                continue
            if len(head) < 16:
                unreadable += 1
                continue
            flags = int.from_bytes(head[4:8], "little")
            if not flags & 1:
                continue  # timestamp pyc: Python validates it itself (ARM 7 judges the mode)
            examined += 1
            for r in required:
                if r in pyc:
                    required[r] += 1
            key = int.from_bytes(head[0:4], "little")
            if _imp.source_hash(key, body) != head[8:16]:
                mismatched += 1
                bad.append(os.path.relpath(src, root))
    print(f"  examined {examined} hash-based .pyc with a source; {mismatched} compiled from "
          f"different bytes; {unreadable} unreadable; {no_source} with no .py beside them")
    for r, n in required.items():
        print(f"  under '{r}': {n} examined")
    for b in bad[:20]:
        print(f"  STALE: {b}")
    if unreadable or examined == 0 or any(n == 0 for n in required.values()):
        print("  CANNOT-RUN: nothing (or not everything required) could be compared. Not a pass.")
        return 2
    return 1 if mismatched else 0


def main(argv: list[str]) -> int:
    if not argv or argv[0].startswith("-"):
        print(__doc__)
        return 2
    root, rest, require = argv[0], argv[1:], []
    while rest:
        if rest[0] == "--require" and len(rest) > 1:
            require.append(rest[1])
            rest = rest[2:]
        else:
            print(f"unknown argument: {rest[0]}")
            return 2
    return check(root, require)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
