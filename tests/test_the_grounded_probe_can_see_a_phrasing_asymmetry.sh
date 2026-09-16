#!/usr/bin/env bash
# tests/test_the_grounded_probe_can_see_a_phrasing_asymmetry.sh
# ============================================================================
# CM051 #1162. "One in three questions fails" and "this exact string fails
# every time" are different findings with different owners, and until now
# nothing in this repo could tell them apart.
#
# THE DEFECT, MEASURED BEFORE THE FIX, on origin/main c4d4b5af:
#
#   the rephrasing "What subjects am I most drawn to?"  -> 0 files tree-wide
#   POSITIVE CONTROL, same predicate, same corpus:
#   the plain phrasing "What are my interests?"         -> 4 files
#   a second customer question, "What do you know about me?" -> 3 files
#
#   So the predicate finds a customer-question string when one exists, and the
#   zero is real absence rather than a broken reader. The battery was three
#   DISTINCT questions; no rephrasing pair existed anywhere; the probe was
#   structurally incapable of observing the asymmetry it was walked into.
#
# WHAT THIS FILE PROVES, and the two halves fail in opposite directions:
#
#   ARM A  the probe's own self-test CATCHES the removal of each half of the
#          new machinery. Five mutations of the REAL probe file, each of which
#          must PROVE IT APPLIED before its assertion is scored. A mutation
#          that silently failed to apply looks exactly like one that was
#          caught, and that is how a mutation ladder becomes decoration.
#
#   ARM B  a WALK-SHAPED run of run_probe, over a box stub that answers the
#          plain phrasing with no tool call and the rephrasing with a grounded
#          turn, produces a FAIL whose text NAMES the asymmetry and both
#          strings. That is the consumer-side half: the person reading the walk
#          record gets a repro case instead of a rate.
#
# CANNOT-RUN IS A THIRD STATE HERE TOO. Missing bash, a missing probe file or a
# missing lib is exit 2, never a pass: "nothing was wrong" and "nothing was
# examined" print identically otherwise.
#
# Exit codes: 0 every arm passed / 1 an arm failed / 2 could not run.
# British English throughout. No em dashes.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROBE_REL="scripts/box_walk_probes/probes/assistant_answers_grounded.sh"
LIB_REL="scripts/box_walk_probes/lib/probe.sh"
PROBE="${REPO_ROOT}/${PROBE_REL}"
LIB="${REPO_ROOT}/${LIB_REL}"

PLAIN='What are my interests?'
REPHRASED='What subjects am I most drawn to?'

fails=0
arms=0

cannot_run() {
    printf 'CANNOT-RUN: %s\n' "$1" >&2
    printf '            Nothing was examined. This is not a pass.\n' >&2
    exit 2
}

ok()   { arms=$(( arms + 1 )); printf '  PASS  %s\n' "$1"; }
bad()  { arms=$(( arms + 1 )); fails=$(( fails + 1 )); printf '  FAIL  %s\n' "$1"; }

[ -r "$PROBE" ] || cannot_run "probe not readable: ${PROBE}"
[ -r "$LIB" ]   || cannot_run "probe lib not readable: ${LIB}"
command -v mktemp >/dev/null 2>&1 || cannot_run "no mktemp on PATH"

WORK="$(mktemp -d)" || cannot_run "could not make a scratch directory"
trap 'rm -rf "$WORK"' EXIT

echo "=== the grounded probe can see a phrasing asymmetry (CM051 #1162) ==="
echo "    probe: ${PROBE_REL}"
echo "    shell: ${BASH_VERSION}"
echo

# ---------------------------------------------------------------------------
# A scratch copy of the probe tree. Mutations are applied HERE, never to the
# tracked file, so a red arm cannot leave a doctored probe behind for a later
# step to measure.
# ---------------------------------------------------------------------------
stage() {   # stage <dir>
    mkdir -p "$1/probes" "$1/lib"
    cp "$PROBE" "$1/probes/assistant_answers_grounded.sh"
    cp "$LIB"   "$1/lib/probe.sh"
}

# ===========================================================================
# ARM A: the self-test ladder, on the REAL probe file.
# ===========================================================================
#
# The self-test's convention is inverted on purpose and it trips everybody
# once: `VERDICT: FAIL` (rc 1) means THE CONTROL FIRED, which is the healthy
# state, and `VERDICT: PASS` (rc 0) is how this suite spells BROKEN. So a
# mutation is CAUGHT when the self-test's rc moves 1 -> 0.
selftest_rc() {   # selftest_rc <staged dir> -> prints rc
    local rc
    /bin/bash "$1/probes/assistant_answers_grounded.sh" --self-test >/dev/null 2>&1
    rc=$?
    printf '%s' "$rc"
}

# A mutation that did not apply is indistinguishable from one that was caught.
# Every arm below therefore states a WITNESS, something measurably different
# about the mutated file, and is scored only once the witness holds.
mutate_arm() {  # mutate_arm <label> <sed-or-perl fn name> <witness fn name>
    local label="$1" apply="$2" witness="$3" d rc
    d="${WORK}/$(printf '%s' "$label" | tr -c 'a-zA-Z0-9' '_')"
    stage "$d"
    "$apply" "$d/probes/assistant_answers_grounded.sh"
    if ! "$witness" "$d/probes/assistant_answers_grounded.sh"; then
        bad "${label}: THE MUTATION DID NOT APPLY. Its assertion is NOT scored; a mutant that never ran looks exactly like one that was caught."
        return
    fi
    rc="$(selftest_rc "$d")"
    if [ "$rc" = "0" ]; then
        ok "${label}: caught (self-test rc 1 -> 0, the control stopped firing)"
    else
        bad "${label}: NOT caught, self-test still rc ${rc}. The mutation applied and the probe's own control did not notice."
    fi
}

# --- baseline: unmutated, the control must fire -----------------------------
BASE="${WORK}/baseline"
stage "$BASE"
base_rc="$(selftest_rc "$BASE")"
if [ "$base_rc" = "1" ]; then
    ok "baseline: the unmutated probe's self-test fires its control (rc 1)"
else
    bad "baseline: the unmutated probe's self-test returned rc ${base_rc}, expected 1. Every mutation arm below would be measuring a broken baseline."
fi

# --- M1: the rephrasing is deleted from the battery -------------------------
m1_apply()   { grep -v -F -x -- "$REPHRASED" "$1" > "$1.tmp" && mv "$1.tmp" "$1"; }
m1_witness() { [ "$(grep -c -F -x -- "$REPHRASED" "$1")" -eq 0 ]; }
mutate_arm "M1 rephrasing removed from the battery" m1_apply m1_witness

# --- M2: the pair declaration is emptied ------------------------------------
# The exact shape of the regression this guards: somebody keeps the reader and
# drops the data it reads, and every look-alike arm still passes vacuously.
m2_apply() {
    perl -0pi -e "s/^_rephrasing_pairs\(\) \{\n.*?\n\}\n/_rephrasing_pairs() {\n    :\n}\n/ms" "$1"
}
m2_witness() { [ "$(grep -c -F -- "printf '%s\\t%s\\n' '${PLAIN}'" "$1")" -eq 0 ]; }
mutate_arm "M2 pair declaration emptied" m2_apply m2_witness

# --- M3: the asymmetry reader is silenced -----------------------------------
m3_apply() {
    perl -0pi -e "s/^_phrasing_asymmetry\(\) \{.*?\n\}\n/_phrasing_asymmetry() {\n    return 0\n}\n/ms" "$1"
}
# The witness must name something ONLY the reader's body carries. The literal
# 'PHRASING ASYMMETRY' will not do: self_test greps for it too, so that count
# can never reach zero and the arm would report a mutation that DID apply as
# one that did not. Measured on the unmutated file: 2 occurrences of the
# sentence below, both inside _phrasing_asymmetry; 0 after the mutation.
m3_witness() { [ "$(grep -c -F -- 'One exact string, not one question in N.' "$1")" -eq 0 ]; }
mutate_arm "M3 asymmetry reader silenced" m3_apply m3_witness

# --- M4: the asymmetry reader shouts on everything --------------------------
# The opposite failure to M3, and the one a must-hit-only ladder cannot see: a
# reader that always reports an asymmetry turns every uniform failure into a
# manufactured repro case.
m4_apply() {
    perl -0pi -e "s/^_phrasing_asymmetry\(\) \{.*?\n\}\n/_phrasing_asymmetry() {\n    printf 'PHRASING ASYMMETRY: unconditional\\\\n'\n}\n/ms" "$1"
}
m4_witness() { [ "$(grep -c -F -- 'PHRASING ASYMMETRY: unconditional' "$1")" -eq 1 ]; }
mutate_arm "M4 asymmetry reader fires unconditionally" m4_apply m4_witness

# --- M5: an existing battery question is weakened ---------------------------
# "Without weakening the existing battery" is a claim, so it is pinned. This
# rewrites question 2 into something the pair no longer matches.
m5_apply() {
    perl -pi -e "s/^\Q${PLAIN}\E\$/Tell me my interests please/" "$1"
}
m5_witness() { [ "$(grep -c -F -x -- 'Tell me my interests please' "$1")" -eq 1 ]; }
mutate_arm "M5 an existing battery question is rewritten" m5_apply m5_witness

# ===========================================================================
# ARM B: a WALK-SHAPED run, and the consumer-side half.
# ===========================================================================
#
# The subject of the assertion here is a PERSON: whoever reads the walk record.
# Arm A proves the machinery is sound. This proves that on a box behaving
# exactly as the one measured on 2026-08-27, the record they receive names the
# failing string and its rephrasing instead of reporting a rate.
#
# THE STUB REPLACES THE SSH, AND NOTHING ELSE. box_reachable and box_run are
# appended to a COPY of the real lib, so every other line of the real probe --
# the battery, the pair check, adjudicate_turn, classify_verdict, the
# precedence ladder and the verdict wording, is the shipped code. The control
# for that claim is M6 below: mutate the real probe and this arm must change.
stage_walk() {  # stage_walk <dir> <mode>
    local d="$1" mode="$2"
    stage "$d"
    cat >> "$d/lib/probe.sh" <<'STUBEOF'

# ---- TEST STUB (tests/test_the_grounded_probe_can_see_a_phrasing_asymmetry.sh)
# Replaces the ssh boundary only. Appended after the real definitions so it
# overrides them; the probe file itself is untouched.
box_reachable() { return 0; }
box_run() {
    case "$1" in
        *"What are my interests?"*)
            printf 'FRAME session_start\nFRAME chunk_reset\nFRAME done\n' ;;
        *"What subjects am I most drawn to?"*)
            printf 'FRAME session_start\nFRAME tool_call pwg_preferences\nFRAME tool_result pwg_preferences OK\nFRAME done\n' ;;
        *"What do you know about me?"*|*"Who have I been in contact with recently?"*)
            printf 'FRAME session_start\nFRAME tool_call pwg_overview\nFRAME tool_result pwg_overview OK\nFRAME done\n' ;;
    esac
    return 0
}
STUBEOF
    if [ "$mode" = "uniform" ]; then
        # Every question fails the same way: a capability gap, not an
        # asymmetry. The record must NOT manufacture a repro case out of it.
        cat >> "$d/lib/probe.sh" <<'STUBEOF'
box_run() {
    case "$1" in
        *"?"*) printf 'FRAME session_start\nFRAME chunk_reset\nFRAME done\n' ;;
    esac
    return 0
}
STUBEOF
    fi
}

walk_out() {  # walk_out <dir> -> stdout of a walk-shaped run
    ( cd "$1" && /bin/bash "probes/assistant_answers_grounded.sh" 2>&1 )
}

WB="${WORK}/walk_asym"
stage_walk "$WB" asym
out="$(walk_out "$WB")"
rc=$?
printf '%s\n' "$out" | sed 's/^/      | /'

if [ "$(printf '%s\n' "$out" | grep -c '^VERDICT: FAIL')" -eq 1 ]; then
    ok "walk: the box answering the plain phrasing without a tool call is a FAIL"
else
    bad "walk: expected exactly one 'VERDICT: FAIL' line, got rc=${rc}. A box that answered a customer's plainest question from nothing must not read as clean."
fi
if [ "$(printf '%s\n' "$out" | grep -c 'PHRASING ASYMMETRY')" -ge 1 ]; then
    ok "walk: the record NAMES the asymmetry rather than reporting a rate"
else
    bad "walk: the record carries no 'PHRASING ASYMMETRY' line. The reader is back to '1 of 4 failed', which is the rate #1162 says is not actionable."
fi
if [ "$(printf '%s\n' "$out" | grep -c -F -- "$PLAIN")" -ge 1 ] \
   && [ "$(printf '%s\n' "$out" | grep -c -F -- "$REPHRASED")" -ge 1 ]; then
    ok "walk: both strings are in the record, so the reader has a repro case"
else
    bad "walk: the record does not carry both strings verbatim. A label without the two questions is not a repro case."
fi
if [ "$(printf '%s\n' "$out" | grep -c '^EXAMINED: ')" -eq 1 ]; then
    ok "walk: a denominator was printed"
else
    bad "walk: no EXAMINED line. A verdict with no denominator cannot be audited."
fi

# --- MUST-MISS: a uniform failure is not an asymmetry -----------------------
WU="${WORK}/walk_uniform"
stage_walk "$WU" uniform
out_u="$(walk_out "$WU")"
if [ "$(printf '%s\n' "$out_u" | grep -c '^VERDICT: FAIL')" -eq 1 ]; then
    ok "walk (uniform failure): still a FAIL, so the pair work weakens nothing"
else
    bad "walk (uniform failure): expected a FAIL. Adding the pair must not make a wholly broken box read as clean."
fi
if [ "$(printf '%s\n' "$out_u" | grep -c 'PHRASING ASYMMETRY')" -eq 0 ]; then
    ok "walk (uniform failure): NO asymmetry claimed, so a capability gap stays a capability gap"
else
    bad "walk (uniform failure): an asymmetry was reported where every question failed. That manufactures a repro case out of the exact reading #1162 refuses."
fi

# --- M6: the control for arm B's stub ---------------------------------------
# Does arm B actually drive the real probe file, or only the stub? Delete the
# rephrasing from the battery in the staged copy: the run must lose its
# asymmetry line. If it does not, the stub is answering for the probe and every
# green above is a statement about this test rather than about the product.
WC="${WORK}/walk_control"
stage_walk "$WC" asym
grep -v -F -x -- "$REPHRASED" "$WC/probes/assistant_answers_grounded.sh" > "$WC/p.tmp" \
  && mv "$WC/p.tmp" "$WC/probes/assistant_answers_grounded.sh"
if [ "$(grep -c -F -x -- "$REPHRASED" "$WC/probes/assistant_answers_grounded.sh")" -ne 0 ]; then
    bad "M6 control: THE MUTATION DID NOT APPLY, so this control is not scored."
else
    out_c="$(walk_out "$WC")"
    if [ "$(printf '%s\n' "$out_c" | grep -c '^VERDICT: CANNOT-RUN')" -eq 1 ]; then
        ok "M6 control: with the rephrasing gone the run REFUSES (CANNOT-RUN), so arm B is reading the real probe file and a declared pair that is never asked is never silently tolerated"
    else
        bad "M6 control: expected CANNOT-RUN once the declared pair member left the battery. Got: $(printf '%s\n' "$out_c" | grep '^VERDICT:' | head -1)"
    fi
fi

# ===========================================================================
echo
echo "arms scored: ${arms}   failed: ${fails}"
if [ "$fails" -gt 0 ]; then
    echo "RESULT: FAIL, ${fails} of ${arms} arms"
    exit 1
fi
if [ "$arms" -lt 12 ]; then
    echo "RESULT: CANNOT-RUN, only ${arms} arms were scored, expected at least 12."
    echo "        A ladder that scored almost nothing is green in the same way as"
    echo "        one that scored everything."
    exit 2
fi
echo "RESULT: PASS, ${arms} of ${arms} arms"
exit 0
