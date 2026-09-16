#!/usr/bin/env python3
"""Row 1160 part three. A preference with no compartment_level was dropped.

The compartment filter had TWO arms, a numeric range and a string match. A
point carrying NEITHER matched neither and vanished from the result. Measured
on a live box: 934 of 9,948 points, about one in eleven.

THE SUBJECT IS A PERSON'S OWN DATA. A customer with nearly ten thousand
preferences was shown the subset that happened to carry the field, and nothing
told them or us that the rest had been removed before the question was asked.
Being shown less than you own, with no error, is worse than an error.

THE DECISIVE CASE IS A FLOOR OF 0: there the caller asks for EVERYTHING, and
unlabelled points were still dropped. That is not a privacy stance, it is a
filter that does not do what it says.

An absent label is read as the documented default, which BOTH writers declare
(parsers/base.py `int = 2`, pwg_ingest.py DEFAULT_PRIVACY "L2"), so this is
consistency rather than a new privacy decision. The arm is CONDITIONAL: adding
it to a request stricter than that default would widen a privacy-scoped read.
"""
from __future__ import annotations

import importlib.util
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "vendor/cm019_preferences/services/ingest/src/loaders/qdrant_loader.py"

PASS = FAIL = 0
def ok(m):
    global PASS; PASS += 1; print(f"  ok    {m}")
def bad(m):
    global FAIL; FAIL += 1; print(f"  FAIL  {m}")
def cannot_run(w):
    print(f"  CANNOT-RUN  {w}\n    NOTHING was checked. This is not a pass.")
    print(f"PASS={PASS} FAIL={FAIL} CANNOT-RUN=1"); sys.exit(1)

if not SRC.is_file():
    cannot_run(f"loader not at {SRC}")

# The module does `from ..config import settings`, so it must be imported as
# src.loaders.qdrant_loader with src/ on the path's PARENT. Imported as a real
# package rather than stubbed: a stub would let this test pass against code the
# product never executes.
sys.path.insert(0, str(SRC.parents[2]))
try:
    import importlib
    mod = importlib.import_module("src.loaders.qdrant_loader")
except Exception as exc:
    cannot_run(f"{SRC.name} is not importable: {type(exc).__name__}: {exc}")

if not hasattr(mod, "compartment_should_clauses"):
    cannot_run("compartment_should_clauses is absent; nothing to exercise")
build = mod.compartment_should_clauses
default = getattr(mod, "ABSENT_COMPARTMENT_MEANS", None)
if default is None:
    cannot_run("ABSENT_COMPARTMENT_MEANS is absent")

print(f"EXAMINED: {SRC.name}, floors 0 to 6, absent-label default {default}")

def has_absent(cl):
    return any("is_empty" in c for c in cl)

# 1. The decisive case.
if has_absent(build(0)):
    ok("floor 0 (asking for EVERYTHING) includes points with no label")
else:
    bad("floor 0 STILL drops unlabelled points, which is the defect")

# 2. Up to and including the documented default.
if all(has_absent(build(n)) for n in range(0, default + 1)):
    ok(f"every floor 0..{default} includes them, matching the declared default")
else:
    bad(f"some floor at or below {default} still drops them")

# 3. Stricter than the default must NOT widen.
strict = [n for n in range(default + 1, 7) if has_absent(build(n))]
if not strict:
    ok(f"no floor above {default} admits an unlabelled point, so a stricter "
       f"request is not silently widened")
else:
    bad(f"floors {strict} admit unlabelled points into a stricter scope")

# 4. The two original arms survive at every floor.
missing = [n for n in range(0, 7)
           if not any("range" in c for c in build(n))
           or not any("match" in c for c in build(n))]
if not missing:
    ok("the numeric and string arms are present at every floor 0..6")
else:
    bad(f"floors {missing} lost an original arm")

# 5. CONTROL: the predicate must be able to SEE an absent arm's absence.
#    Prove it on a synthetic clause list rather than trusting a zero.
if not has_absent([{"key": "x", "range": {"gte": 0}}]):
    ok("CONTROL: has_absent returns False on a clause list with no is_empty, "
       "so the negatives above are real")
else:
    bad("CONTROL FAILED: has_absent is true for everything")

# 6. CONTROL: and True when one IS present.
if has_absent([{"is_empty": {"key": "compartment_level"}}]):
    ok("CONTROL: and True when an is_empty clause is present")
else:
    bad("CONTROL FAILED: has_absent cannot see an is_empty clause")

print(f"PASS={PASS} FAIL={FAIL} CANNOT-RUN=0")
sys.exit(0 if FAIL == 0 and PASS >= 6 else 1)
