#!/usr/bin/env python3
"""Every seeded .pyc on the image was compiled from the .py beside it.

The DMG ships unchecked-hash bytecode (walk_dmg.sh ARM 7, seed-hub-payload-pyc.sh):
Python NEVER compares it with its source, so a .py edited after seeding is
shipped as DEAD text while the old bytecode runs, and nothing would say so
(found 2026-11-04 on Mini16: a source edit to ostler_fda was silently ignored).
An unchecked-hash .pyc still stores its source's SipHash at bytes 8-16, keyed
by its own magic number, so this compares them for every .pyc that has a .py.

THE HASH IS ONLY COMPARABLE UNDER THE INTERPRETER THAT WROTE IT. _imp.source_hash
differs between CPython versions for the same key and bytes (measured 2026-11-04:
an untouched cpython-311 .pyc and its .py read "different bytes" under the
runner's /usr/bin/python3 3.9.6 and match under the bundled 3.11.15; candidate
run 41770746721 reported 2233 of 2233 STALE, a uniform result from a broken
predicate, not a stale build). So a .pyc whose magic number is not this
interpreter's is never judged: it is counted FOREIGN and the run is CANNOT-RUN.
--interpreter-in-root re-runs this file under the interpreter found in <root>
whose name matches the .pyc cache tag (cpython-311 -> python3.11), exactly one,
or reports CANNOT-RUN.

Usage: verify_seeded_pyc_matches_source.py <root> [--require <path-fragment>] [--interpreter-in-root]
Exit: 0 every examined .pyc matches; 1 a mismatch; 2 CANNOT-RUN (nothing
examined, a .pyc from another interpreter, no .pyc under a --require
fragment, a file unreadable, or no single matching interpreter in <root>).
"""
from __future__ import annotations

import importlib.util
import os
import re
import sys

import _imp

REEXEC_ENV = "OSTLER_ARM9_REEXECED"


def source_of(pyc: str) -> str | None:
    head, name = os.path.split(pyc)
    if os.path.basename(head) != "__pycache__":
        return None
    stem = name.split(".", 1)[0]
    return os.path.join(os.path.dirname(head), stem + ".py")


def check(root: str, require: list[str]) -> int:
    examined = mismatched = unreadable = no_source = foreign = 0
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
            if head[0:4] != importlib.util.MAGIC_NUMBER:
                foreign += 1  # another interpreter wrote it; its hash cannot be recomputed here
                continue
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
    if foreign:
        print(f"  CANNOT-RUN: {foreign} hash-based .pyc were written by another interpreter "
              f"(this is {sys.version.split()[0]}); their hashes cannot be recomputed here. Not a pass.")
        return 2
    if unreadable or examined == 0 or any(n == 0 for n in required.values()):
        print("  CANNOT-RUN: nothing (or not everything required) could be compared. Not a pass.")
        return 2
    return 1 if mismatched else 0


def interpreter_in(root: str) -> tuple[str | None, str]:
    """The one executable under <root> named for the hash-based .pyc cache tag."""
    tags = set()
    for d, _dirs, files in os.walk(root):
        for f in files:
            m = re.search(r"\.cpython-3(\d+)\.pyc$", f)
            if m and os.path.basename(d) == "__pycache__":
                tags.add(m.group(1))
    if len(tags) != 1:
        return None, f"found {len(tags)} cpython cache tags ({sorted(tags)}), need exactly 1"
    name = "python3." + tags.pop()
    hits = []
    for d, _dirs, files in os.walk(root):
        for f in files:
            p = os.path.join(d, f)
            if f == name and not os.path.islink(p) and os.access(p, os.X_OK):
                hits.append(p)
    if len(hits) != 1:
        return None, f"found {len(hits)} executable {name} under the root, need exactly 1"
    return hits[0], name


def main(argv: list[str]) -> int:
    if not argv or argv[0].startswith("-"):
        print(__doc__)
        return 2
    root, rest, require, bundled = argv[0], argv[1:], [], False
    while rest:
        if rest[0] == "--require" and len(rest) > 1:
            require.append(rest[1])
            rest = rest[2:]
        elif rest[0] == "--interpreter-in-root":
            bundled = True
            rest = rest[1:]
        else:
            print(f"unknown argument: {rest[0]}")
            return 2
    if bundled and os.environ.get(REEXEC_ENV) != "1":
        interp, why = interpreter_in(root)
        if interp is None:
            print(f"  CANNOT-RUN: no interpreter to recompute with: {why}. Not a pass.")
            return 2
        print(f"  recomputing with {os.path.relpath(interp, root)}")
        sys.stdout.flush()
        args = [interp, "-I", os.path.abspath(__file__), root]
        for r in require:
            args += ["--require", r]
        try:
            os.execve(interp, args, dict(os.environ, **{REEXEC_ENV: "1"}))
        except OSError as e:
            print(f"  CANNOT-RUN: {interp} would not run ({e}). Not a pass.")
            return 2
    return check(root, require)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
