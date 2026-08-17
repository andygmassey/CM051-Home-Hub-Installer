#!/usr/bin/env python3
"""AppleParser must stay registered BEFORE AppleTVParser, and the comment must
stop saying the opposite.

`pipeline.py` reads:

    AppleParser(),                                          # line 72
    ...
    AppleTVParser(),   # Before AppleParser - tight path/name match, no overlap

The comment is FACTUALLY BACKWARDS. AppleTV is registered AFTER Apple, and
`IngestPipeline._get_parser` takes the FIRST claimer, so AppleTV never sees the
three Apple TV filenames Apple already claims by substring.

THE TRAP THIS GATE EXISTS TO CLOSE. Reading that comment, the obvious "fix" is
to move AppleTVParser above AppleParser so the tighter matcher wins. That would
DESTROY DATA. Measured on a real Apple Media Services export, counts only:

    file      Apple claims   Apple yield      AppleTV claims   AppleTV yield
    .csv      yes            462              yes              440
    .zip      yes            3167             yes              1082
    .csv      yes            761              no               --
    .csv      yes            16               no               --
    .csv      yes            10               no               --
    .zip      yes            153              no               --

    contested files: 2      Apple-only: 4      AppleTV-only: 0
    TOTAL if Apple wins  : 4569
    TOTAL if AppleTV wins: 2462     <- a loss of 2,107 records

Only TWO files are contested and Apple yields MORE on BOTH of them. Apple's
handlers read the same columns AppleTV expects and additionally understand
rows AppleTV drops. So the ORDER IS CORRECT and the COMMENT IS WRONG, which is
the reverse of how it reads.

The cost of the current state is provenance, not data: those records carry
`source="apple"` rather than `"apple_tv"`, and AppleTVParser is dead code for
its three primary filenames. Both are real, neither is worth 2,107 records.

WHAT THIS PINS
  1. AppleParser is registered BEFORE AppleTVParser, read out of the SHIPPED
     pipeline.py rather than restated here.
  2. No comment in the registration block claims AppleTV precedes Apple.

If a future change genuinely makes AppleTV the better parser, re-measure yield
on both first, update the table above, and change this test deliberately. Do
not flip the order because a comment told you to.

Exit: 0 pass, 1 a real failure, 2 cannot-run (never a silent pass).
"""

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PIPELINE_PY = (REPO / "vendor" / "cm019_preferences" / "services" / "ingest"
               / "src" / "pipeline.py")

PASS = 0
FAIL = 0


def ok(msg):
    global PASS
    print(f"  PASS  {msg}")
    PASS += 1


def no(msg):
    global FAIL
    print(f"  FAIL  {msg}")
    FAIL += 1


if not PIPELINE_PY.is_file():
    print(f"CANNOT RUN: pipeline.py missing at {PIPELINE_PY}", file=sys.stderr)
    sys.exit(2)

src = PIPELINE_PY.read_text(encoding="utf-8")
m = re.search(r"self\.parsers:\s*List\[BaseParser\]\s*=\s*\[(.*?)\n\s*\]", src, re.S)
if not m:
    print("CANNOT RUN: could not locate the parser registration list",
          file=sys.stderr)
    sys.exit(2)

block = m.group(1)
order = re.findall(r"^\s*(\w+)\(\)\s*,", block, re.M)

for needed in ("AppleParser", "AppleTVParser"):
    if needed not in order:
        print(f"CANNOT RUN: {needed} is not registered at all", file=sys.stderr)
        sys.exit(2)

# --- limb 1: the ORDER, read from the shipped file --------------------------
i_apple = order.index("AppleParser")
i_tv = order.index("AppleTVParser")
if i_apple < i_tv:
    ok(f"AppleParser (position {i_apple + 1}) is registered before "
       f"AppleTVParser (position {i_tv + 1}) -- Apple yields 4569 vs 2462")
else:
    no(f"AppleTVParser (position {i_tv + 1}) now precedes AppleParser "
       f"(position {i_apple + 1}). MEASURED: that costs 2,107 records on a "
       f"real Apple Media Services export. Re-measure before changing this.")

# --- limb 2: no comment may claim the reverse -------------------------------
# The defect being pinned is a comment that documents the opposite of the
# behaviour and thereby invites a data-destroying reorder.
bad = []
for line in block.splitlines():
    if "#" not in line:
        continue
    comment = line.split("#", 1)[1].lower()
    if "before appleparser" in comment.replace("-", " ").replace("_", " "):
        bad.append(line.strip())
if bad:
    for b in bad:
        no(f"a registration comment claims AppleTV precedes Apple: {b!r}")
else:
    ok("no registration comment claims AppleTVParser precedes AppleParser")

print(f"\n{PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
