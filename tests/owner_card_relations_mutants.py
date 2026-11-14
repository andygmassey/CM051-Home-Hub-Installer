"""Mutation harness for the G1 producer (vendor/cm041 syncer.py).

Each mutant breaks one rule in a COPY of the shipped reader, in a temp tree,
and runs tests/test_owner_card_relations_producer_vendored.py against it.
Caught = suite red. The unmutated control must be green or the run is void.
A mutant whose anchor is not found exactly once is NOT APPLIED and fails the run.

Run: python3 tests/owner_card_relations_mutants.py
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TARGET = os.path.join("vendor", "cm041", "contact_syncer", "syncer.py")
SUITE = os.path.join("tests", "test_owner_card_relations_producer_vendored.py")

MUTANTS = [
    ("M1 owner marker written on every card",
     '                    if pk in owner_pks:\n                        lines.append("X-OSTLER-OWNER-CARD:TRUE")',
     '                    if True:\n                        lines.append("X-OSTLER-OWNER-CARD:TRUE")'),
    ("M2 relations read for the owner only (the old gate)",
     '                        if rr["pk"] is not None and rr["name"]:',
     '                        if rr["pk"] in owner_pks and rr["name"]:'),
    ("M3 relation labels dropped",
     '                        if rlabel:\n                            lines.append(f"item{idx}.X-ABLABEL',
     '                        if False:\n                            lines.append(f"item{idx}.X-ABLABEL'),
    ("M4 relations attributed to no card",
     'relations_by_pk.setdefault(rr["pk"], []).append(',
     'relations_by_pk.setdefault(0, []).append('),
    ("M5 only the first relation emitted",
     'for idx, (rname, rlabel) in enumerate(relations_by_pk.get(pk, []), 1):',
     'for idx, (rname, rlabel) in enumerate(relations_by_pk.get(pk, [])[:1], 1):'),
]


def _suite_rc(root: str) -> int:
    r = subprocess.run([sys.executable, "-m", "pytest", SUITE, "-q", "-p", "no:cacheprovider"],
                       cwd=root, capture_output=True, text=True)
    return r.returncode


def _copy(dst: str) -> None:
    for d in ("vendor", "tests"):
        shutil.copytree(os.path.join(ROOT, d), os.path.join(dst, d),
                        ignore=shutil.ignore_patterns("__pycache__"))


def main() -> int:
    work = tempfile.mkdtemp(prefix="g1mut-")
    try:
        ctrl = os.path.join(work, "control")
        os.makedirs(ctrl)
        _copy(ctrl)
        rc = _suite_rc(ctrl)
        print(f"CONTROL rc={rc} ({'green' if rc == 0 else 'RED: run void'})")
        if rc != 0:
            return 2
        caught = survived = not_applied = 0
        for i, (name, old, new) in enumerate(MUTANTS):
            root = os.path.join(work, f"m{i:02d}")
            os.makedirs(root)
            _copy(root)
            path = os.path.join(root, TARGET)
            text = open(path, encoding="utf-8").read()
            n = text.count(old)
            if n != 1:
                not_applied += 1
                print(f"NOT APPLIED  {name} (anchor found {n} times)")
                continue
            open(path, "w", encoding="utf-8").write(text.replace(old, new))
            if _suite_rc(root) != 0:
                caught += 1
                print(f"CAUGHT       {name}")
            else:
                survived += 1
                print(f"SURVIVED     {name}")
        print(f"SUMMARY mutants={len(MUTANTS)} caught={caught} survived={survived} not_applied={not_applied}")
        return 0 if survived == 0 and not_applied == 0 else 1
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
