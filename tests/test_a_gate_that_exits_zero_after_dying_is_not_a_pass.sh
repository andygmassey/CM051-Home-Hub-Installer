#!/usr/bin/env bash
# tests/test_a_gate_that_exits_zero_after_dying_is_not_a_pass.sh
# ============================================================================
# A CUT GATE THAT PRINTS AN INTERPRETER ERROR AND EXITS 0 IS NOT A PASS.
#
# MEASURED 2026-08-26. scripts/verify_must_contain.sh used `declare -A`, a bash
# 4 builtin. /bin/bash is 3.2.57 on every Mac. Under 3.2 it printed
#
#     declare: -A: invalid option
#     line 68: what: unbound variable
#
# and EXITED 0. On the real cuts/v1.0.47 BOM the true answer is rc=1 -- there
# are unlanded rows. run_all_cut_gates.sh saw rc=0 and printed
#
#     PASS  MUST_CONTAIN BOM  every promised capability landed
#
# The gate that decides whether the promised capabilities landed certified a
# cut it never read.
#
# Fixing that one file does not close the class. The NEXT gate to acquire a
# bash-4 builtin, a typo'd variable under `set -u`, or a syntax error in an
# unexercised branch does exactly the same thing, silently. run() already
# captured stderr (2>&1) and then discarded it whenever rc==0 -- the evidence
# was always there, nothing looked at it.
#
# THE DISCRIMINATOR: bash prefixes its OWN diagnostics with "<script>: line N:".
# A gate's deliberate output does not look like that. Anchoring on that shape,
# rather than on words like "error" or "not found", is what lets a gate report
# "image not found in registry" as a legitimate finding without being flagged.
# That is arm 3 and it is not theoretical.
#
# 🔴 THE PREDICATE IS EXTRACTED FROM THE SHIPPED SCRIPT, NOT RE-TYPED.
# A test that re-implements the thing it checks passes with the real code
# deleted. If the extraction comes back empty this exits 2 CANNOT-RUN.
#
# Run: bash tests/test_a_gate_that_exits_zero_after_dying_is_not_a_pass.sh
# ============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$REPO_ROOT/scripts/run_all_cut_gates.sh"
[ -r "$RUNNER" ] || { echo "CANNOT-RUN: no readable $RUNNER"; exit 2; }

S=$(grep -n '^_interpreter_died()' "$RUNNER" | head -1 | cut -d: -f1)
if [ -z "$S" ]; then
    echo "CANNOT-RUN: _interpreter_died() is not defined in run_all_cut_gates.sh."
    echo "  The arm this test guards has been removed or renamed. Re-point this"
    echo "  test rather than deleting it -- a gate certifying a cut it never read"
    echo "  is what it exists to catch. Not a pass."
    exit 2
fi
E=$(awk -v s="$S" 'NR>s && /^}$/{c++; if(c==2){print NR; exit}}' "$RUNNER")
BODY="$(sed -n "${S},${E}p" "$RUNNER")"
case "$BODY" in
    *"run()"*) : ;;
    *) echo "CANNOT-RUN: extraction did not capture run(). Anchors moved. Not a pass."; exit 2 ;;
esac

c_grn=""; c_red=""; c_off=""; GREEN=0; RED=0; RESULTS=()
eval "$BODY"

FAILURES=0
ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

# ── THE SPECIMEN ──────────────────────────────────────────────────────────
# Prefer the REAL pre-fix gate out of git history: a synthetic stand-in proves
# the predicate matches a string I chose, which is a weaker claim. Fall back
# only if history is unavailable (shallow CI checkout), and SAY WHICH was used
# so a green here is never mistaken for the stronger evidence.
SPEC="$(mktemp)"; trap 'rm -f "$SPEC"' EXIT
SPEC_KIND="synthetic"
if git -C "$REPO_ROOT" show origin/main:scripts/verify_must_contain.sh > "$SPEC" 2>/dev/null \
   && grep -q 'declare -A' "$SPEC" 2>/dev/null; then
    SPEC_KIND="REAL pre-fix verify_must_contain.sh from origin/main"
    SPEC_ARGS="$REPO_ROOT/cuts/v1.0.47/MUST_CONTAIN.tsv"
    [ -f "$SPEC_ARGS" ] || SPEC_KIND="synthetic"
fi
if [ "$SPEC_KIND" = "synthetic" ]; then
    # Same shape as the measured failure: a bash diagnostic, then exit 0.
    printf '#!/bin/bash\nprintf "%%s: line 68: what: unbound variable\\n" "$0" >&2\nexit 0\n' > "$SPEC"
    SPEC_ARGS=""
fi
printf 'EXAMINED: predicate extracted from run_all_cut_gates.sh:%s-%s\n' "$S" "$E"
printf 'EXAMINED: specimen = %s\n\n' "$SPEC_KIND"

# ── ARM 1: the specimen must be RED.
GREEN=0; RED=0
if [ -n "$SPEC_ARGS" ]; then
    run "MUST_CONTAIN BOM" "every promised capability landed" /bin/bash "$SPEC" "$SPEC_ARGS" >/dev/null 2>&1
else
    run "MUST_CONTAIN BOM" "every promised capability landed" /bin/bash "$SPEC" >/dev/null 2>&1
fi
[ "$RED" -eq 1 ] && ok "SPECIMEN: a gate that exits 0 after an interpreter error is RED" \
                 || bad "SPECIMEN NOT CAUGHT (red=$RED green=$GREEN) -- this is the actual defect"

# ── ARM 2: THE CONTROL. Without it, a predicate that reds EVERYTHING passes
# ── arm 1 and this file certifies nothing.
GREEN=0; RED=0
run "healthy" "a clean gate" /bin/bash -c 'echo "all good"; exit 0' >/dev/null 2>&1
[ "$GREEN" -eq 1 ] && ok "CONTROL: a clean gate is still GREEN" \
                   || bad "CONTROL FAILED: a clean gate went RED -- the predicate reds everything"

# ── ARM 3: THE FALSE-POSITIVE CONTROL, and the reason for the anchoring.
GREEN=0; RED=0
run "findingy" "reports a finding" /bin/bash -c 'echo "image not found in registry"; echo "error: none"; exit 0' >/dev/null 2>&1
[ "$GREEN" -eq 1 ] && ok "CONTROL: 'not found'/'error' in a gate's OWN output does not trip it" \
                   || bad "FALSE POSITIVE: flagged a gate reporting a legitimate finding"

# ── ARM 4: a gate that dies AND exits non-zero was already RED. Counted once.
GREEN=0; RED=0
run "loud" "dies loudly" /bin/bash -c 'echo "x: line 4: boom"; exit 3' >/dev/null 2>&1
[ "$RED" -eq 1 ] && ok "a gate that dies AND exits non-zero is RED exactly once" \
                 || bad "miscounted a loud failure: red=$RED"

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "PASS -- a cut gate cannot certify a cut it never read."
    [ "$SPEC_KIND" = "synthetic" ] && echo "        (specimen was SYNTHETIC: git history unavailable here.)"
    exit 0
fi
echo "FAIL -- $FAILURES assertion(s) failed."
exit 1
