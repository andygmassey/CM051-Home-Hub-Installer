#!/bin/bash
# =============================================================================
# A RE-PROMPT LOOP MUST BE ABLE TO GIVE UP.
#
# Found by Archie on 2026-09-07, by accident, on the walk box: an install.sh
# spinning for 2h19m with 50:51 of CPU, its log at 1,755,085,045 bytes and
# growing at ~218 KB/s, every line identical:
#
#     What would you like to call your assistant?: [warn] Your assistant needs a name.
#
# `gui_read` returns empty on EOF. Forever. The loop re-prompts on empty. So
# anything that closes the GUI's end of that pipe turns a question into a
# disk-filling loop, and the box then hits install.sh's own 15 GB floor and
# refuses the install NAMING THE WRONG CAUSE -- the customer is told they are
# out of disk by the process that consumed it.
#
# WHAT THIS GATE GUARDS, AND WHAT IT DELIBERATELY DOES NOT.
#
# It guards the SHAPE: a `while [[ -z "$VAR" ]]` loop whose body asks the user
# for input must carry a bound in its own condition, so that a machine which
# never answers eventually loses rather than spins.
#
# It does NOT claim the three current instances are fixed. They are not. This
# is a ONE-WAY RATCHET against tests/PROMPT_LOOP_UNBOUNDED_CEILING, the same
# idiom as tests/TEST_WIRING_CEILING: a fourth instance fails the build today,
# and the ceiling may only ever be lowered. The fix touches install.sh and so
# unpins a cut; the gate is a test file and does not. That is the whole reason
# the two are separable, and the reason this lands first.
#
# 🗿 WHY THE PREDICATE IS "BODY ASKS FOR INPUT" AND NOT "LOOP HAS NO COUNTER".
#
# install.sh contains FIVE loops of the `while [[ -z "$VAR" ]]` shape, not
# three. Two of them -- the Tailscale URL wait at ~25474 and the Tailscale IP
# wait at ~25530 -- are correctly bounded and must NOT be reported. They are
# not an exception carved out to make the number come right; they are the
# MUST-MISS CONTROL, they live in the same file as the subject, and they prove
# this predicate discriminates instead of counting every while-loop it sees.
# A gate that flagged all five would be indistinguishable from `grep -c while`.
#
# The narrowing is on the BODY (does it call gui_read / read), because that is
# what makes the loop a question rather than a wait. A wait that never settles
# is a different defect with a different fix.
#
# ⚠️ THE SEARCH IS BY SHAPE, NOT BY THE ENGLISH. Archie's first grep for the
# visible sentence returned ZERO, because the string lives in the locale file
# as MSG_WARN_YOUR_ASSISTANT_NEEDS_NAME_PICK_FROM and install.sh names only the
# variable. A false absence, and it read exactly like a clean result.
# =============================================================================
set -Eeuo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
TARGET="${PROMPT_LOOP_TARGET:-${REPO_ROOT}/install.sh}"
CEILING_FILE="${PROMPT_LOOP_CEILING_FILE:-${REPO_ROOT}/tests/PROMPT_LOOP_UNBOUNDED_CEILING}"

# CANNOT-RUN is a third state and is never a pass. Each of these exits 2, not 1,
# so a caller can tell "I could not look" from "I looked and it is bad".
if [[ ! -f "$TARGET" ]]; then
    printf 'verify_prompt_loops: CANNOT-RUN -- no such file: %s\n' "$TARGET" >&2
    exit 2
fi
if [[ ! -f "$CEILING_FILE" ]]; then
    printf 'verify_prompt_loops: CANNOT-RUN -- ceiling file absent: %s\n' "$CEILING_FILE" >&2
    exit 2
fi

CEILING="$(tr -d '[:space:]' < "$CEILING_FILE")"
if ! [[ "$CEILING" =~ ^[0-9]+$ ]]; then
    printf 'verify_prompt_loops: CANNOT-RUN -- ceiling is not an integer: %q\n' "$CEILING" >&2
    exit 2
fi

# The classifier is python because the job is "find the matching `done` and read
# the body", which is a parsing job, and a shell pipeline that pretends to do it
# would be the kind of scanner that over-runs its subject.
/usr/bin/python3 - "$TARGET" "$CEILING" <<'PY'
import re, sys

path, ceiling = sys.argv[1], int(sys.argv[2])
lines = open(path, encoding="utf-8", errors="replace").read().splitlines()

# The subject: a while-loop guarding on a variable being EMPTY.
WHILE = re.compile(r'^\s*while\s+\[\[\s+-z\s+"\$\{?(\w+)')
# A bound in the CONDITION -- a numeric comparison against an attempt counter.
BOUND = re.compile(r'-(lt|le|gt|ge)\s')
# The body asks a human something.
ASKS = re.compile(r'\bgui_read\b|(?<![\w-])read\s+(-[rp]\S*\s+)*\w')
# An EOF guard: the loop notices the stream died instead of asking again.
EOFG = re.compile(r'\bbreak\b|\bEOF\b|read\s+.*-t\s|\|\|\s*break')

found, unbounded = [], []
for i, ln in enumerate(lines):
    m = WHILE.match(ln)
    if not m:
        continue
    var = m.group(1)
    # Walk to the matching `done` at the same indent. Two independent stops:
    # the matching `done`, and a hard cap, so a malformed body cannot make this
    # scanner run to the end of a 31k-line file and report on someone else's code.
    indent = len(ln) - len(ln.lstrip())
    body, j, cap = [], i + 1, min(len(lines), i + 400)
    closed = False
    while j < cap:
        cur = lines[j]
        if cur.strip() == "done" and (len(cur) - len(cur.lstrip())) == indent:
            closed = True
            break
        body.append(cur)
        j += 1
    body_txt = "\n".join(body)
    asks = bool(ASKS.search(body_txt))
    bounded = bool(BOUND.search(ln))
    guarded = bool(EOFG.search(body_txt))
    found.append((i + 1, var, asks, bounded, guarded, closed))
    if asks and not bounded and not guarded:
        unbounded.append((i + 1, var))

print("== re-prompt loops that cannot give up ==")
print(f"   subject: {path}")
print(f"   {'line':>6}  {'variable':<28} asks  bounded  eof-guard  closed")
for ln_no, var, asks, bounded, guarded, closed in found:
    print(f"   {ln_no:>6}  {var:<28} {str(asks):<5} {str(bounded):<8} "
          f"{str(guarded):<10} {closed}")

# VACUITY CONTROL. If the shape matched nothing at all, the predicate is broken
# and must say so rather than report a clean sheet. install.sh has contained
# loops of this shape since it was written; zero means the regex stopped
# matching, which is exactly how a gate starts guarding nothing.
if not found:
    print("\nverify_prompt_loops: CANNOT-RUN -- the loop shape matched NOTHING in "
          f"{path}. That is a broken predicate, not a clean result.", file=sys.stderr)
    sys.exit(2)

# A body whose `done` was never found was not measured. Do not score it.
unclosed = [f for f in found if not f[5]]
if unclosed:
    print("\nverify_prompt_loops: CANNOT-RUN -- could not find the matching `done` "
          f"for {len(unclosed)} loop(s): {[f[0] for f in unclosed]}", file=sys.stderr)
    sys.exit(2)

n = len(unbounded)
print(f"\n   loops of this shape: {len(found)}   asking input and unbounded: {n}   "
      f"ceiling: {ceiling}")

if n > ceiling:
    print(f"\nFAIL: {n} unbounded re-prompt loop(s), ceiling is {ceiling}.", file=sys.stderr)
    for ln_no, var in unbounded:
        print(f"  {path}:{ln_no}  {var} re-prompts forever when the reader hits EOF",
              file=sys.stderr)
    print("\nBound the attempts, or guard EOF. A customer whose GUI pipe closes\n"
          "should get a refusal, not a disk-filling loop that blames their disk.",
          file=sys.stderr)
    sys.exit(1)

# The other half of the ratchet: a backlog that shrank without the ceiling
# following it silently re-opens room for a regression.
if n < ceiling:
    print(f"\nFAIL: the backlog shrank to {n} but the ceiling still says {ceiling}.\n"
          f"Lower it, or the space you just freed is space a regression can use:\n"
          f"    printf '{n}\\n' > tests/PROMPT_LOOP_UNBOUNDED_CEILING", file=sys.stderr)
    sys.exit(1)

print(f"\nPASS: {n} unbounded, at the ceiling of {ceiling}. No new instance.")
PY
