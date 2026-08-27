#!/usr/bin/env bash
# The wiki-image CONTENT gate must be RUN, and must not report a pass when it
# could not look.
# =============================================================
#
# TWO DEFECTS, ONE FILE, BOTH FOUND 2026-08-23.
#
# (1) NOT INVOKED. tests/test_pinned_wiki_image_has_design_system.sh is the only
#     check in the estate that opens a wiki image and reads what is inside it.
#     Its name appeared in cut-gate-wrappers.yml -- in the `paths:` filter, a
#     TRIGGER -- and tests/TEST_WIRING.tsv scored that as WIRED. No workflow
#     ever ran it. Its only invocation was scripts/run_all_cut_gates.sh, which
#     runs on a human's laptop at cut time.
#
#     Denominator, measured on origin/main 5faaf73 rather than asserted: of 201
#     WIRED rows naming a workflow, 160 are genuinely invoked after `jobs:`. Of
#     the 41 that are not, 36 are Swift files that xcodebuild runs as a whole
#     target and 4 are invoked by dotted module path (python3 -m unittest
#     tests.x), which a filename grep cannot see. Exactly ONE was a real false
#     label, and it was this gate.
#
# (2) CANNOT-RUN REPORTED AS PASS. Its skip() printed "(Skipping is NOT a
#     pass.)" and then exited 0. Three preconditions took that path: docker
#     absent, docker not running, no CM044 checkout. Every automated consumer
#     reads the status, so "I could not look" and "the design system is present
#     and current" were byte-identical.
#
# Together those two are the exact pair of failure modes the gate was built to
# outlaw -- a months-old stylesheet shipping behind a valid digest, unseen.
#
# WHY A SEPARATE FILE. The gate itself needs docker, a network and (for the
# byte half) a CM044 checkout. This file needs none of them: it asserts the
# gate's WIRING and its EXIT-CODE CONTRACT, which are properties of the text
# and of a run with docker deliberately removed. That is why it can be a
# blocking check on every PR while the gate it guards cannot.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

GATE="tests/test_pinned_wiki_image_has_design_system.sh"
WF=".github/workflows/cut-gate-wrappers.yml"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }

echo "== the gate's wiring and exit-code contract =="

# ── 1. CONTROL, RUN FIRST ─────────────────────────────────────────────────
# Everything below reads two files. If either is missing or unparseable, every
# later assertion would fail for a reason that has nothing to do with the
# defect -- and a wall of reds is indistinguishable from a real regression.
# Prove the operands are readable before asserting anything about them.
if [[ -f "$GATE" && -f "$WF" ]]; then
    ok "CONTROL: both operands exist ($GATE, $WF)"
else
    bad "CONTROL: an operand is missing" "gate=$([[ -f $GATE ]] && echo yes || echo NO) wf=$([[ -f $WF ]] && echo yes || echo NO)"
    echo "REFUSING TO CONTINUE -- the remaining assertions would be vacuous."
    echo "PASS=$PASS FAIL=$FAIL"; exit 1
fi

if bash -n "$GATE" 2>/dev/null; then
    ok "CONTROL: the gate parses under bash"
else
    bad "CONTROL: the gate does not parse" "$(bash -n "$GATE" 2>&1 | head -2)"
fi

# ── 2. THE WORKFLOW MUST INVOKE IT, NOT MERELY NAME IT ────────────────────
# Split at `jobs:`. Everything above is triggers (`on:`, `paths:`); everything
# below is what actually executes. A name above the line is documentation.
WF_BODY="$(awk '/^jobs:/{f=1} f' "$WF")"
WF_HEAD="$(awk '/^jobs:/{exit} {print}' "$WF")"

if grep -qF -- "$GATE" <<< "$WF_BODY"; then
    ok "the workflow INVOKES the gate (named after jobs:)"
else
    bad "the workflow does not invoke the gate" \
        "its name appears only in the trigger block -- that is a path filter, not a run step"
fi

# The trigger entry must ALSO survive, or a change to the gate stops triggering
# the workflow that runs it. Both halves are load-bearing; they are not
# alternatives.
if grep -qF -- "$GATE" <<< "$WF_HEAD"; then
    ok "the gate is still in paths: so editing it triggers this workflow"
else
    bad "the gate is not in paths:" "a change to the gate would not run the gate"
fi

# ── 3. IT MUST BE INVOKED IN THE MODE THAT CANNOT FALSE-RED ───────────────
# The byte-identity half compares against a CM044 working tree. In CI the only
# tree obtainable is CM044 main, which legitimately runs ahead of the pinned
# image between a merge and the next re-pin. Invoking the full gate here would
# go red on a correct image every time CM044 lands a commit, and a gate that
# cries wolf gets switched off. Assert the flag is present on the run line.
GATE_RUN_LINE="$(grep -F -- "$GATE" <<< "$WF_BODY" | head -1)"
if grep -q -- '--presence-only' <<< "$GATE_RUN_LINE"; then
    ok "invoked with --presence-only (the half with no CM044 dependency)"
else
    bad "invoked WITHOUT --presence-only" \
        "line: ${GATE_RUN_LINE:-<none>} -- the byte half would false-red whenever CM044 main moves"
fi

# ── 4. THE STEP MUST NOT BE SKIPPABLE ─────────────────────────────────────
# Without if: always(), an earlier failing step in the same job drops this one,
# and the one gate that reads the shipped artefact goes quiet exactly when
# something else is already wrong.
# Scan WF_BODY, not the whole file. The gate's name also appears in the
# `paths:` trigger above `jobs:`, and an awk over the whole file matches THAT
# first and exits -- reporting on the trigger block while claiming to report on
# the step. This assertion failed on its first run for exactly that reason,
# which is the same wrong-surface mistake the rest of this file exists to catch.
STEP_BLOCK="$(awk -v g="$GATE" '
    /^      - name:/ { blk=""; }
    { blk = blk $0 "\n" }
    index($0, g) { print blk; exit }
' <<< "$WF_BODY")"
if grep -q 'if: always()' <<< "$STEP_BLOCK"; then
    ok "the step carries if: always()"
else
    bad "the step has no if: always()" "an earlier failure would silently skip it"
fi

# ── 5. CANNOT-RUN MUST NOT EXIT 0 — MEASURED, NOT READ ────────────────────
# Run the real gate with docker removed from PATH. That drives it down the
# first precondition branch, which is the branch that used to return 0.
STUB="$(mktemp -d)"
trap 'rm -rf "$STUB"' EXIT
# A PATH with no docker in it. coreutils stay reachable so the failure is
# attributable to docker's absence and not to a crippled environment.
NODOCKER_PATH="$STUB/bin:/usr/bin:/bin"
mkdir -p "$STUB/bin"

out="$(PATH="$NODOCKER_PATH" bash "$GATE" --presence-only 2>&1)"; rc=$?
if [[ $rc -eq 2 ]]; then
    ok "no docker -> exit 2 (CANNOT-RUN), measured"
elif [[ $rc -eq 0 ]]; then
    bad "no docker -> exit 0" "THE DEFECT: 'could not look' is reporting as a pass"
else
    bad "no docker -> exit $rc" "expected 2; got: $(head -1 <<< "$out")"
fi

# It must also SAY so. An exit code with no explanation sends the next reader
# hunting for a failure that did not happen.
if grep -q 'CANNOT-RUN' <<< "$out"; then
    ok "the CANNOT-RUN path names itself in its output"
else
    bad "the CANNOT-RUN path is silent about why" "got: $(head -2 <<< "$out")"
fi

# ── 6. NO REMAINING exit 0 ON A PRECONDITION ──────────────────────────────
# The behavioural probe above covers ONE branch (docker absent). The other two
# -- daemon down, no CM044 checkout -- cannot be driven from here without a
# docker daemon, so assert structurally that the old shape is gone.
if grep -qE '^\s*skip\(\)' "$GATE"; then
    bad "the gate still defines skip()" "$(grep -nE '^\s*skip\(\)' "$GATE" | head -1)"
else
    ok "skip() is gone from the gate"
fi
# `| grep -q .` is the exact defect this repo ratchets against, and it was in
# this file: grep -q exits on the FIRST match, the upstream grep takes SIGPIPE,
# and under the `set -o pipefail` on line 37 the pipeline reports FAILURE on a
# needle that IS present -- the verdict comes out inverted, so a gate that still
# held a bare `exit 0` would have been reported as clean. grep -c cannot
# short-circuit. It exits 1 on a count of zero, so the capture needs `|| true`
# or the assignment takes the whole chain down with it.
n_bare_exit0="$(grep -nE 'exit 0' "$GATE" | grep -vcE '^\s*[0-9]+:\s*#' || true)"
if [ "${n_bare_exit0:-0}" -gt 0 ]; then
    bad "the gate still contains a bare 'exit 0'" \
        "$(grep -nE 'exit 0' "$GATE" | head -2 | tr '\n' ' ')"
else
    ok "no precondition path in the gate exits 0"
fi

# ── 7. THE PRESENCE HALF NEEDS ITS OWN POSITIVE CONTROL ───────────────────
# In --presence-only the two diff-based controls do not run. Without a control
# of its own, the entire CI invocation would have no proof it can fail -- which
# is the shape this whole file exists to outlaw.
if grep -q 'POSITIVE CONTROL FAILED -- after removing every line containing' "$GATE"; then
    ok "the presence half carries its own positive control"
else
    bad "the presence half has no positive control" \
        "in --presence-only the diff controls never run, so nothing proves it can fail"
fi

# ── 8. DEMONSTRATED RED ───────────────────────────────────────────────────
# A gate with no proof it can fail is indistinguishable from a gate that always
# passes. So assertions 2 and 6 are re-run against DELIBERATELY BROKEN COPIES of
# their own inputs and required to FAIL there.
#
# THIS SECTION USED TO READ LIVE origin/main, AND THAT WAS THE DEFECT.
# A negative control taken from origin/main works exactly once. The moment the
# fix this file guards is merged, main CONTAINS the fix, the mutants vanish, and
# both arms report "proves nothing" -- permanently. Measured: green on PR #1135
# at 700edbee, red on main three minutes later at a19ff437 (run 33052765715),
# with no change to the file in between. The subject had overwritten its own
# control. A control the subject can overwrite is not an independent control.
#
# A synthetic mutant cannot be overwritten by merging anything, so these arms
# stay meaningful for the life of the file.
#
# Each arm asserts its MUTATION TOOK EFFECT before asserting the predicate
# fails on it. Without that, a no-op mutation makes the arm pass vacuously --
# which is the same "proves nothing" shape one level down.

# Mutant A: the workflow body with the gate's invocation line deleted.
MUT_WF_BODY="$(grep -vF -- "$GATE" <<< "$WF_BODY")"
if [[ "$MUT_WF_BODY" == "$WF_BODY" ]]; then
    bad "DEMONSTRATED RED (wiring): the mutation was a no-op" \
        "nothing was removed, so the assertion below would pass having tested nothing"
elif grep -qF -- "$GATE" <<< "$MUT_WF_BODY"; then
    bad "DEMONSTRATED RED (wiring)" \
        "assertion 2 still passes on a workflow with the invocation REMOVED -- it proves nothing"
else
    ok "DEMONSTRATED RED (wiring): assertion 2 fails when the invocation is removed"
fi

# Mutant B: the gate with a skip() put back exactly as it read before the fix.
MUT_GATE="$(printf 'skip() {\n    echo "(Skipping is NOT a pass.)"\n    exit 0\n}\n')
$(cat "$GATE")"
if ! grep -qE '^\s*skip\(\)' <<< "$MUT_GATE"; then
    bad "DEMONSTRATED RED (exit code): the mutation did not take" \
        "the injected skip() is invisible to the predicate, so the assertion below is vacuous"
elif grep -qE '^\s*skip\(\)' <<< "$MUT_GATE"; then
    ok "DEMONSTRATED RED (exit code): assertion 6 fails when skip() is reintroduced"
else
    bad "DEMONSTRATED RED (exit code)" \
        "a gate carrying skip() still passes assertion 6 -- it proves nothing"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
