#!/usr/bin/env python3
"""A parser must not label the customer's most sensitive data publishable.

THE SCALE IS SETTLED AND TWO INDEPENDENT DEFINITIONS AGREE. It is
compartment_level, 0 to 6, and it WIDENS THE AUDIENCE as it counts up:

    0 L0Personal  1 L1Family  2 L2Trusted  3 L3Community
    4 L4Public    5 L5Commercial          6 L6Broadcast

base.py carries that name map. privacy_model.py carries the numeric mapping
and says the quiet part out loud in its own comment: L4Public, L5Commercial
and L6Broadcast all collapse to the publishable level.

WHAT WENT WRONG, AND WHY A COMMENT MADE IT WORSE. apple.py wrote
compartment_level=5 at four sites, each commented HIGHEST PRIVACY. The comment
stated the intent correctly and the number said the opposite, so the two most
sensitive Apple sources a customer has -- Health and Notes -- were labelled one
step from Broadcast. The comment is what made it survive review: a reader
checking intent found the right words next to the wrong number.

THE SUBJECT OF THESE ASSERTIONS IS A PERSON'S DATA, not a constant: for each
sensitive source, does the level this parser writes resolve to publishable.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PARSER = ROOT / "vendor/cm019_preferences/services/ingest/src/parsers/apple.py"
MODEL = ROOT / "vendor/cm041/contact_syncer/privacy_model.py"

PASS = FAIL = 0


def ok(m):
    global PASS
    PASS += 1
    print(f"  ok    {m}")


def bad(m):
    global FAIL
    FAIL += 1
    print(f"  FAIL  {m}")


def cannot_run(why):
    print(f"  CANNOT-RUN  {why}")
    print("    NOTHING was checked. This is not a pass.")
    print(f"PASS={PASS} FAIL={FAIL} CANNOT-RUN=1")
    sys.exit(1)


if not PARSER.is_file():
    cannot_run(f"the parser is not at {PARSER}")
if not MODEL.is_file():
    cannot_run(f"the privacy model is not at {MODEL}")

model = MODEL.read_text()
# Derive the publishable set FROM THE MODEL rather than hard-coding it, so a
# change to the model is caught here instead of silently diverging.
publishable = set()
for m in re.finditer(r"^\s*(\d):\s*LEVEL_(\w+),\s*#\s*(\w+)", model, re.M):
    lvl, mapped, name = int(m.group(1)), m.group(2), m.group(3)
    if "publishable" in model.split("\n")[model[: m.start()].count("\n")].lower():
        publishable.add(lvl)
# Second pass: the model marks publishable rows with a trailing comment.
for line in model.split("\n"):
    m = re.match(r"^\s*(\d):\s*LEVEL_\w+,\s*#.*publishable", line)
    if m:
        publishable.add(int(m.group(1)))

print(f"EXAMINED: {PARSER.name} against the publishable set derived from "
      f"{MODEL.name}")
if not publishable:
    cannot_run("could not derive the publishable set from the model; refusing "
               "to judge the parser against an empty set")
ok(f"the publishable set is derived, not typed: {sorted(publishable)}")

src = PARSER.read_text()
writes = [(i + 1, int(m.group(1)), line.strip())
          for i, line in enumerate(src.split("\n"))
          if (m := re.match(r"^\s+compartment_level\s*=\s*(\d)\s*,", line))]
print(f"  denominator: {len(writes)} literal compartment_level write(s) in the parser")
if not writes:
    cannot_run("no literal writes found; the predicate would pass vacuously")

bad_writes = [(ln, lvl, txt) for ln, lvl, txt in writes if lvl in publishable]
if bad_writes:
    for ln, lvl, txt in bad_writes:
        bad(f"line {ln} writes compartment_level={lvl}, which the model calls "
            f"publishable: {txt[:70]}")
else:
    ok(f"no write lands in the publishable set (checked {len(writes)} writes)")

# The specific regression: a level whose comment claims privacy while the
# number means the opposite.
liars = [(ln, lvl, txt) for ln, lvl, txt in writes
         if lvl in publishable and "privacy" in txt.lower()]
if liars:
    bad(f"{len(liars)} write(s) claim privacy in the comment while writing a "
        f"publishable level")
else:
    ok("no write claims privacy in its comment while writing a publishable level")

# CONTROL: the predicate must be able to SEE a bad write. Prove it on a
# synthetic line rather than trusting that zero means clean.
probe = "                compartment_level=5,  # HIGHEST PRIVACY"
m = re.match(r"^\s+compartment_level\s*=\s*(\d)\s*,", probe)
if m and int(m.group(1)) in publishable:
    ok("CONTROL: the predicate flags a synthetic publishable write, so the "
       "zero above is a real absence")
else:
    bad("CONTROL FAILED: the predicate cannot see a known-bad write")

print(f"PASS={PASS} FAIL={FAIL} CANNOT-RUN=0")
sys.exit(0 if FAIL == 0 and PASS >= 4 else 1)
