#!/usr/bin/env bash
#
# tests/test_progress_bar_cannot_exceed_one_hundred.sh
#
# progress() is the bar the CUSTOMER watches for the entire install. Its
# percentage was UNCLAMPED, while the only other percentage in this file --
# the Ollama pull parser at :1517 -- has always clamped with exactly the line
# progress() was missing. Two computations, one contract, one of them enforced.
#
# WHY IT CAN EXCEED 100, measured not assumed. TOTAL_STEPS is seeded by
# counting `progress "` lines in BASH_SOURCE, then DECREMENTED at seven sites
# (:10158 plus six mid-run at :20703-:21229 and :26238). The fallback seed at
# :10168 is a HARDCODED constant, and the mid-run decrements subtract from
# THAT -- so on any invocation where BASH_SOURCE is unreadable, TOTAL_STEPS
# lands below the number of steps that actually run and CURRENT_STEP overtakes
# it. TNM derived 105-106%; this test makes the derivation unnecessary.
#
# 🔴 AND THE PERCENTAGE IS THE SMALLER HALF. Follow the arithmetic:
#
#     FILLED = PCT * BAR_WIDTH / 100     PCT=105, BAR_WIDTH=30  ->  31
#     EMPTY  = BAR_WIDTH - FILLED                               ->  -1
#     printf "%${EMPTY}s"                                       ->  "%-1s"
#
# A NEGATIVE printf WIDTH IS NOT AN ERROR. It is the left-justify flag. So the
# bar silently renders wider than its own declared width and nothing anywhere
# reports a problem -- the failure mode is a lie on screen, not a crash.
#
# WHY THIS TEST READS THE ARITHMETIC OUT OF install.sh RATHER THAN RESTATING IT.
# A hand-copied formula here would be a SECOND artefact with ONE consumer: it
# would keep passing after the real lines changed, which is the exact shape
# that has bitten this repo repeatedly. The lines are extracted from the real
# file and evaluated, so if the real formula changes this test changes with it
# or reports CANNOT-RUN.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="${REPO_ROOT}/install.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
rc=0

[[ -f "$INSTALLER" ]] || fail "install.sh not found at ${INSTALLER}"

# ── Arm 1: the ARITHMETIC, taken from the real file ───────────────
#
# Pull the four lines that compute the bar. Anchored on their exact text so a
# rename or a refactor reports CANNOT-RUN rather than silently measuring
# nothing.
BAR_MATH="$(grep -E '^[[:space:]]*local (PCT|BAR_WIDTH|FILLED|EMPTY)=' "$INSTALLER" \
            | sed -e 's/^[[:space:]]*local //' | head -4)"
MATH_N="$(printf '%s\n' "$BAR_MATH" | grep -c . || true)"

if [[ "${MATH_N:-0}" -ne 4 ]]; then
    fail "expected 4 bar-arithmetic lines in install.sh, extracted ${MATH_N:-0}.
      The formula moved or was renamed. This is CANNOT-RUN, not a pass:
      the arm below would evaluate nothing and report success."
fi

# Does the clamp travel with the arithmetic? Extract it the same way.
CLAMP="$(grep -E '^[[:space:]]*\(\( PCT > 100 \)\) && PCT=100' "$INSTALLER" \
         | sed -e 's/^[[:space:]]*//' | head -1)"

run_bar() {   # $1 = CURRENT_STEP, $2 = TOTAL_STEPS, $3 = "clamped"|"raw"
    local CURRENT_STEP="$1" TOTAL_STEPS="$2" mode="$3"
    local PCT BAR_WIDTH FILLED EMPTY
    eval "$(printf '%s\n' "$BAR_MATH" | sed -n 1p)"      # PCT
    [[ "$mode" == "clamped" && -n "$CLAMP" ]] && eval "$CLAMP"
    eval "$(printf '%s\n' "$BAR_MATH" | sed -n 2p)"      # BAR_WIDTH
    eval "$(printf '%s\n' "$BAR_MATH" | sed -n 3p)"      # FILLED
    eval "$(printf '%s\n' "$BAR_MATH" | sed -n 4p)"      # EMPTY
    printf '%s %s\n' "$PCT" "$EMPTY"
}

# THE DEFECT'S OWN INPUT. Not invented: the fallback seeds 40, the six mid-run
# decrements take it to ~35, and 37 steps run. Measured on the live branch by
# ttywalk run 3 (37 of 37) and cross-derived by TNM from the raw count of 41.
DEFECT_CURRENT=37
DEFECT_TOTAL=35

# 1a THE UNCLAMPED FORMULA MUST STILL MISBEHAVE. If it does not, the harness
#    has stopped reproducing the defect and arm 1b proves nothing.
read -r raw_pct raw_empty <<< "$(run_bar "$DEFECT_CURRENT" "$DEFECT_TOTAL" raw)"
if [[ "$raw_pct" -gt 100 && "$raw_empty" -lt 0 ]]; then
    echo "ok   arm 1a: unclamped, ${DEFECT_CURRENT}/${DEFECT_TOTAL} gives pct=${raw_pct} and EMPTY=${raw_empty}"
    echo "     (a negative printf width left-justifies -- it does NOT error)"
else
    echo "FAIL arm 1a: expected pct>100 AND EMPTY<0 from the unclamped formula,"
    echo "     got pct=${raw_pct} EMPTY=${raw_empty}. The defect no longer"
    echo "     reproduces, so arm 1b is vacuous. CANNOT-RUN, not a pass."
    rc=1
fi

# 1b WITH THE CLAMP: never above 100, and the bar never wider than itself.
read -r ok_pct ok_empty <<< "$(run_bar "$DEFECT_CURRENT" "$DEFECT_TOTAL" clamped)"
if [[ -z "$CLAMP" ]]; then
    echo "FAIL arm 1b: no clamp line found in install.sh."
    echo "     progress() computes a customer-facing percentage with no upper"
    echo "     bound, while :1517 clamps its own. Add: (( PCT > 100 )) && PCT=100"
    rc=1
elif [[ "$ok_pct" -le 100 && "$ok_empty" -ge 0 ]]; then
    echo "ok   arm 1b: clamped, same input gives pct=${ok_pct} and EMPTY=${ok_empty}"
else
    echo "FAIL arm 1b: clamp present but ineffective -- pct=${ok_pct} EMPTY=${ok_empty}."
    rc=1
fi

# 1c THE CLAMP MUST NOT DAMAGE THE NORMAL CASE. A bound that also rewrites
#    healthy values would be worse than the defect.
read -r mid_pct mid_empty <<< "$(run_bar 18 37 clamped)"
if [[ "$mid_pct" -eq 48 && "$mid_empty" -eq 16 ]]; then
    echo "ok   arm 1c: a mid-install step is untouched (18/37 -> pct=48, EMPTY=16)"
else
    echo "FAIL arm 1c: the clamp altered a NORMAL value: 18/37 gave pct=${mid_pct}"
    echo "     EMPTY=${mid_empty}, expected pct=48 EMPTY=16."
    rc=1
fi

# ── Arm 2: BOTH percentages in this file are bounded ──────────────
#
# The defect was not "a missing line" but "two computations, one contract,
# only one enforced". Grade the CLASS, so a third percentage added later has
# to answer the same question.
pct_sites="$(grep -cE '^[[:space:]]*(local )?(PCT|pct)=\$?\(\(' "$INSTALLER" || true)"
clamp_sites="$(grep -cE '\(\( ?(PCT|pct) > 100 ?\)\) && (PCT|pct)=100' "$INSTALLER" || true)"

# POSITIVE CONTROL: the predicate must SEE the clamp that has been in this file
# all along (:1517). A zero here is a dead predicate, not a clean tree.
if [[ "${clamp_sites:-0}" -lt 1 ]]; then
    echo "FAIL arm 2 control: found 0 clamp sites, but :1517 has had one for"
    echo "     months. The predicate cannot see the shape it grades. CANNOT-RUN."
    rc=1
elif [[ "${clamp_sites:-0}" -ge "${pct_sites:-0}" ]]; then
    echo "ok   arm 2: ${clamp_sites} clamp(s) for ${pct_sites} percentage computation(s)"
else
    echo "FAIL arm 2: ${pct_sites} percentage computations but only ${clamp_sites} clamped."
    echo "     Every percentage shown to a customer needs an upper bound."
    rc=1
fi

[[ "$rc" -eq 0 ]] && echo "PASS: tests/test_progress_bar_cannot_exceed_one_hundred.sh"
exit "$rc"
