#!/usr/bin/env bash
# stage-payload must leave ZERO .pyc in the assembled payload BEFORE the
# seeding step runs (register #644).
#
# THE DEFECT, MEASURED (Archie, 2026-09-03). A local/emergency cut refused at
# stage-payload with "4 of 94 .pyc are not unchecked-hash". The four were
# `cpython-314` files under services/doctor/__pycache__/, with COPY mtimes 2 s
# before the 3.11 seeding step wrote its files. stage-payload assembles the
# payload with `cp -R vendor/doctor/agent -> services/doctor` (and knowledge,
# cm048), which copies the operator's ambient __pycache__ WHOLESALE out of the
# working tree. The seeder compiles for the bundled 3.11 (`cpython-311.pyc`)
# and NEVER touches the operator's `cpython-314.pyc` -- different cache tag --
# so those ambient files survive into the payload. CI never sees it: __pycache__
# is gitignored, so a clean checkout has none. Sibling of #534 (co_filename
# baking the build path); every Xcode bundle phase already strips __pycache__
# after its cp, and stage-payload was the one assembly step that did not.
#
# THE NAMED PROOF (Archie's bar): the assembled payload contains ZERO .pyc
# before the seeding step, asserted with a COUNT and a control that FAILS if
# the exclusion is removed. NOT "green today" -- deleting the four files by
# hand once also produces a green.
#
# This drives the REAL strip script (gui/scripts/strip-payload-pyc.sh) over a
# fixture shaped like the assembled payload, and reads the stage-payload recipe
# out of the Makefile so the wiring cannot drift from the build. Herestrings,
# not `producer | grep -q`: under pipefail an early-exiting grep can invert.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/gui/scripts/strip-payload-pyc.sh"
MK="$REPO_ROOT/gui/Makefile"
FAILED=0
fail() { echo "FAIL [$1]: $2" >&2; FAILED=1; }
pass() { echo "PASS: $1"; }

# The Makefile is infrastructure; its absence is CANNOT-RUN. The strip script
# is the FIX this test defines -- its absence is a FAIL, not a cannot-run,
# because "the strip is not implemented" is exactly the red state under test.
[[ -f "$MK" ]] || { echo "FAIL [makefile-missing]: $MK. CANNOT-RUN is not a pass." >&2; exit 2; }

# ── Arm 1: stage-payload WIRES the strip, and BEFORE the seeding step ────────
# Read line numbers out of the recipe; do not retype the command here.
strip_ln="$(grep -n 'strip-payload-pyc.sh' "$MK" | head -1 | cut -d: -f1)"
seed_ln="$(grep -n 'seed-hub-payload-pyc.sh' "$MK" | head -1 | cut -d: -f1)"
if [[ -z "$strip_ln" ]]; then
  fail "wiring" "gui/Makefile never invokes strip-payload-pyc.sh -- the payload .pyc strip is not wired into stage-payload."
elif [[ -z "$seed_ln" ]]; then
  fail "wiring" "gui/Makefile has no seed-hub-payload-pyc.sh call to order against."
elif (( strip_ln >= seed_ln )); then
  fail "ordering" "strip-payload-pyc.sh (line $strip_ln) must run BEFORE seed-hub-payload-pyc.sh (line $seed_ln); a strip after seeding would delete the freshly-seeded .pyc."
else
  pass "stage-payload wires strip-payload-pyc.sh at line $strip_ln, before seeding at line $seed_ln"
fi

# ── Arm 2: the strip removes EVERY .pyc from a payload-shaped fixture ────────
if [[ ! -f "$SCRIPT" ]]; then
  fail "script-missing" "$SCRIPT does not exist -- the payload .pyc strip is not implemented."
else
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/payloadstrip.XXXXXX")"
  trap 'rm -rf "$WORK"' EXIT
  PAY="$WORK/ostler-payload"
  # Shape it like the real assembled payload: three python services, each with
  # ambient __pycache__ carrying BOTH the wrong-tag (cpython-314) files that
  # survive seeding and a right-tag (cpython-311) one, plus a nested dir.
  mkdir -p "$PAY/services/doctor/__pycache__" \
           "$PAY/services/knowledge/__pycache__" \
           "$PAY/services/cm048/sub/__pycache__"
  printf 'x=1\n' > "$PAY/services/doctor/agent.py"
  printf 'y=1\n' > "$PAY/services/knowledge/kn.py"
  printf 'z=1\n' > "$PAY/services/cm048/sub/pipe.py"
  : > "$PAY/services/doctor/__pycache__/agent.cpython-314.pyc"
  : > "$PAY/services/doctor/__pycache__/agent.cpython-311.pyc"
  : > "$PAY/services/knowledge/__pycache__/kn.cpython-314.pyc"
  : > "$PAY/services/cm048/sub/__pycache__/pipe.cpython-314.pyc"

  planted="$(find "$PAY" -type f -name '*.pyc' | wc -l | tr -d ' ')"
  # Anti-vacuity: the fixture must actually carry the defect, or "0 after" is meaningless.
  if (( planted == 0 )); then
    fail "vacuous-fixture" "the fixture planted 0 .pyc; a strip proving 0 remain would be vacuous."
  else
    pass "fixture planted $planted .pyc across 3 services (denominator)"
    # ── Arm 3: mutation control -- the predicate DISCRIMINATES. On the same
    # fixture WITHOUT running the strip, the .pyc count is still $planted, so
    # the Arm-2 assertion below genuinely fails on an unstripped payload.
    unstripped="$(find "$PAY" -type f -name '*.pyc' | wc -l | tr -d ' ')"
    if (( unstripped == planted )); then
      pass "mutation control: an unstripped payload still shows $planted .pyc (the 0-check is not vacuously green)"
    else
      fail "mutation-control" "expected $planted .pyc before stripping, found $unstripped."
    fi

    bash "$SCRIPT" "$PAY"; rc=$?
    remain="$(find "$PAY" -type f -name '*.pyc' | wc -l | tr -d ' ')"
    pcache="$(find "$PAY" -type d -name '__pycache__' | wc -l | tr -d ' ')"
    src="$(find "$PAY" -type f -name '*.py' | wc -l | tr -d ' ')"
    if (( remain != 0 )); then
      fail "pyc-survive" "$remain .pyc survived the strip (planted $planted); the assembled payload still carries ambient bytecode."
    else
      pass "strip removed all $planted .pyc; 0 remain in the assembled payload"
    fi
    (( pcache == 0 )) || fail "pycache-dirs" "$pcache __pycache__ dir(s) survived the strip."
    (( src == 3 ))    || fail "source-collateral" "expected 3 .py source files to SURVIVE, found $src -- the strip must remove bytecode only."
    (( rc == 0 ))     || fail "script-rc" "strip-payload-pyc.sh exited $rc on a payload it fully cleaned; it must exit 0 iff 0 .pyc remain."
  fi
fi

if (( FAILED )); then
  echo "" >&2; echo "RESULT: FAIL -- stage-payload does not guarantee a .pyc-free payload before seeding." >&2
  exit 1
fi
echo "RESULT: PASS -- the assembled payload is .pyc-free before the seeding step."
