#!/usr/bin/env bash
#
# tests/test_total_steps_dynamic.sh
#
# Locks the dynamic `TOTAL_STEPS` computation in install.sh.
#
# Why this test exists:
#
#   The cold-install audit (2026-05-02) found that the Phase 3
#   progress bar over-shot 100%. Hard-coded `TOTAL_STEPS=9` had
#   drifted: `progress` calls had been added by Vane bundling and
#   the GUI-wrapper PR without bumping the base. The bar saturated
#   around step 11 and showed >100% / negative ETA for the wiki,
#   hub-power, email-ingest, wiki-recompile, and assistant-binary
#   phases.
#
#   PR #26's response was to bump 9 -> 14, but that hand-tuned
#   number drifts again the next time someone adds a step. The
#   Clean House fix is to count `progress` calls dynamically.
#
#   This test pins the new contract:
#     1. TOTAL_STEPS is computed by counting `progress` lines in
#        install.sh, not hard-coded.
#     2. With EXPORTS_DIR set, TOTAL_STEPS == total progress calls.
#     3. With EXPORTS_DIR empty, TOTAL_STEPS == total - 1 (the
#        GDPR-import progress call is gated on EXPORTS_DIR).
#     4. The subtract list at the top of Phase 3 has exactly one
#        entry per `progress` call gated on a Phase 2 flag --
#        adding a new conditional `progress` line without a
#        matching subtract entry will trip this test.
#     5. The defensive fallback fires when grep returns 0 (e.g.
#        BASH_SOURCE points at an unreadable /dev/fd/N).
#
# Sister tests:
#   - test_linkedin_export_detect.sh -- LinkedIn auto-detect
#   - test_assistant_config_vane_wiring.sh -- Vane TOML wiring

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${REPO_ROOT}/install.sh"

if [[ ! -f "$INSTALL_SCRIPT" ]]; then
    echo "FAIL: install.sh not found at $INSTALL_SCRIPT" >&2
    exit 1
fi

if ! bash -n "$INSTALL_SCRIPT"; then
    echo "FAIL: install.sh fails bash -n parse check" >&2
    exit 1
fi
echo "PASS: install.sh parses"

# ── Static: TOTAL_STEPS is auto-counted ─────────────────────────
# Pre-fix: `TOTAL_STEPS=9`. Post-fix: grep-based count. A future
# edit that resurrects a hard-coded number would silently let
# drift back in.
if grep -qE '^TOTAL_STEPS=[0-9]+\s*(#|$)' "$INSTALL_SCRIPT"; then
    echo "FAIL [hardcoded-resurrected]: TOTAL_STEPS=<int> hard-coded line is back" >&2
    grep -nE '^TOTAL_STEPS=[0-9]+\s*(#|$)' "$INSTALL_SCRIPT" >&2
    exit 1
fi
echo "PASS: TOTAL_STEPS is not hard-coded to an integer"

if ! grep -qE 'TOTAL_STEPS="?\$\(grep' "$INSTALL_SCRIPT"; then
    echo "FAIL [auto-count-missing]: TOTAL_STEPS auto-count via grep is not present" >&2
    exit 1
fi
echo "PASS: TOTAL_STEPS is computed by grep-counting progress calls"

# ── Static: subtract list matches conditional progress count ────
#
# #629/#627: BOTH SIDES of this comparison used to be wrong, and they
# were wrong in OPPOSITE directions, which is why the arm sat RED
# without anyone reading it (the file was UNWIRED, so nothing ran it).
#
#   RIGHT SIDE was `&& TOTAL_STEPS=$((TOTAL_STEPS - 1))` -- anchored on
#   the `&&` that happens to precede most decrements. install.sh:26212
#   (Apple Notes) writes the same decrement as an if/else, so the
#   predicate could not see it: 6 matched, 7 existed. Match the
#   DECREMENT ITSELF; the operator in front of it is not the subject.
#
#   LEFT SIDE used INDENTATION as a proxy for CONDITIONALITY, and it is
#   not one. Two indented `progress` calls sit inside FUNCTION BODIES and
#   fire unconditionally -- `ostler_assistant` (behind an idempotence
#   early-return whose own comment says it "fires exactly once however
#   many call sites exist") and `import_data` (whose only alternative
#   branch is a fail_with_code that exits). Neither is skippable, so
#   neither may have a decrement; counting them demanded two decrements
#   that MUST NOT exist. Widening only the right side would have left
#   this arm red at 8-vs-7 and invited someone to "fix" it by adding a
#   bogus decrement to a step that always runs -- which would corrupt the
#   denominator for real.
#
# The GDPR decrement is excluded from this arm because it fires at SEED
# time, before CURRENT_STEP exists, and its progress call is at column 0.
# Arms 2 and 3 below cover it directly.
CURRENT_STEP_LINE="$(grep -nE '^CURRENT_STEP=0$' "$INSTALL_SCRIPT" | head -1 | cut -d: -f1 || true)"
if [[ -z "$CURRENT_STEP_LINE" ]]; then
    echo "FAIL [anchor]: could not locate 'CURRENT_STEP=0' to split seed-time from mid-run decrements" >&2
    exit 1
fi

# Mid-run decrements: any form, anywhere after the seeding block.
MIDRUN_SUBTRACT_COUNT="$(awk -v s="$CURRENT_STEP_LINE" 'NR>s' "$INSTALL_SCRIPT" \
    | grep -cE 'TOTAL_STEPS=\$\(\(TOTAL_STEPS - 1\)\)' || true)"

# Indented `progress` calls that are NOT function-body calls. Pinned by
# step id, not by count, so a stale entry fails loudly instead of
# silently shrinking the denominator (the #817 lesson: a baseline must
# PIN, not derive).
UNCONDITIONAL_INDENTED_IDS=(ostler_assistant import_data)
INDENTED_PROGRESS_COUNT="$(grep -cE '^[[:space:]]+progress "' "$INSTALL_SCRIPT" || true)"
ALLOWLIST_SEEN=0
for _id in "${UNCONDITIONAL_INDENTED_IDS[@]}"; do
    # `|| true`: grep -c EXITS 1 on zero matches while still printing "0".
    # Without it, `set -e` kills the script here and the allowlist-stale
    # diagnostic below never prints -- a silent CANNOT-RUN wearing a red.
    _n="$(grep -cE "^[[:space:]]+progress \".*\" \"${_id}\"" "$INSTALL_SCRIPT" || true)"
    if [[ "$_n" -ne 1 ]]; then
        echo "FAIL [allowlist-stale]: expected exactly 1 indented progress call with id '${_id}', found ${_n}" >&2
        echo "  This list names progress calls that are indented because they live inside a" >&2
        echo "  FUNCTION, not because they are conditional. If one moved, was renamed or became" >&2
        echo "  genuinely conditional, update UNCONDITIONAL_INDENTED_IDS and say why." >&2
        exit 1
    fi
    ALLOWLIST_SEEN=$((ALLOWLIST_SEEN + 1))
done
CONDITIONAL_PROGRESS_COUNT=$((INDENTED_PROGRESS_COUNT - ALLOWLIST_SEEN))

if [[ "$CONDITIONAL_PROGRESS_COUNT" -ne "$MIDRUN_SUBTRACT_COUNT" ]]; then
    echo "FAIL [drift]: conditional progress() calls (${CONDITIONAL_PROGRESS_COUNT}) does not match mid-run subtract entries (${MIDRUN_SUBTRACT_COUNT})" >&2
    echo "  Indented progress() calls (${INDENTED_PROGRESS_COUNT}, of which ${ALLOWLIST_SEEN} are in function bodies):" >&2
    grep -nE '^[[:space:]]+progress "' "$INSTALL_SCRIPT" >&2
    echo "  Mid-run subtract entries (after line ${CURRENT_STEP_LINE}):" >&2
    awk -v s="$CURRENT_STEP_LINE" 'NR>s' "$INSTALL_SCRIPT" \
        | grep -nE 'TOTAL_STEPS=\$\(\(TOTAL_STEPS - 1\)\)' >&2
    echo "  Every progress() call that a gate can SKIP needs a matching" >&2
    echo "  TOTAL_STEPS=\$((TOTAL_STEPS - 1)) on the same gate, or the bar never reaches 100%." >&2
    exit 1
fi
echo "PASS: subtract list matches conditional progress() count (${CONDITIONAL_PROGRESS_COUNT} conditional, ${ALLOWLIST_SEEN} allowlisted in-function)"

# ── End-to-end: computation with EXPORTS_DIR set ────────────────
# Extract the TOTAL_STEPS computation block from install.sh, run
# it in isolation with a mocked EXPORTS_DIR, assert the result.
TOTAL_PROGRESS_CALLS="$(grep -cE '^[[:space:]]*progress "' "$INSTALL_SCRIPT")"

# The block runs from `TOTAL_STEPS="$(grep ` to `CURRENT_STEP=0`.
COMPUTE_BLOCK="$(mktemp)"
trap 'rm -f "$COMPUTE_BLOCK" "${COMPUTE_BLOCK_PARAM:-}"' EXIT

awk '
    /^TOTAL_STEPS="\$\(grep / { capture = 1 }
    capture                   { print }
    /^CURRENT_STEP=0$/        { capture = 0; exit }
' "$INSTALL_SCRIPT" > "$COMPUTE_BLOCK"

if [[ ! -s "$COMPUTE_BLOCK" ]]; then
    echo "FAIL [extract]: could not extract the TOTAL_STEPS computation block" >&2
    exit 1
fi

# ⚠️ #629 — READ THIS BEFORE CHANGING THE HARNESS.
#
# This block used to run the compute block under
#   bash -c "BASH_SOURCE=('$INSTALL_SCRIPT'); <block>"
# on the stated theory that "`bash -c` clears BASH_SOURCE so we rebuild it
# explicitly". THE REBUILD DOES NOT STICK. Measured:
#
#   $ bash -c 'BASH_SOURCE=("/path/to/install.sh"); echo "[${BASH_SOURCE[0]}]"'
#   []
#
# bash owns BASH_SOURCE and resets it. So `${BASH_SOURCE[0]}` was EMPTY, the
# seed grep ran against an empty filename, `|| true` swallowed the error, and
# TOTAL_STEPS became 0 -- which means THE DEFENSIVE FALLBACK FIRED ON EVERY
# ARM. Every "end-to-end" number this test has ever printed was the compiled-in
# constant. The live branch has never executed here.
#
# That also made the obvious #629 assertion (fallback == live) VACUOUS: both
# sides were the same constant, so it compared 40 to 40 and could not fail.
#
# FIX: substitute the ONE input the harness cannot legitimately supply. The
# block's own logic runs verbatim; only `${BASH_SOURCE[0]}` becomes `${_TS_SRC}`,
# which each arm sets to either the real install.sh (live branch) or a
# nonexistent path (fallback branch). The substitution is asserted below, so a
# future refactor that renames the expression fails loudly instead of silently
# reverting this test to measuring one branch twice.
COMPUTE_BLOCK_PARAM="$(mktemp)"
sed 's|"\${BASH_SOURCE\[0\]}"|"${_TS_SRC}"|g' "$COMPUTE_BLOCK" > "$COMPUTE_BLOCK_PARAM"

# Match the EXPANSION, not the word: the block's own comments say "BASH_SOURCE"
# in prose, and a predicate that counts those is scoring comments as code --
# the #757/#808 defect, which I am not about to reproduce inside its own fix.
if grep -q '\${BASH_SOURCE\[0\]}' "$COMPUTE_BLOCK_PARAM"; then
    echo "FAIL [param]: a live \${BASH_SOURCE[0]} expansion survived substitution -- the harness would silently test the fallback twice" >&2
    grep -n '\${BASH_SOURCE\[0\]}' "$COMPUTE_BLOCK_PARAM" >&2
    exit 1
fi
if ! grep -q '_TS_SRC' "$COMPUTE_BLOCK_PARAM"; then
    echo "FAIL [param]: no \${_TS_SRC} in the parameterised block -- substitution matched nothing (CANNOT-RUN, not a pass)" >&2
    exit 1
fi

T_WITH_GDPR="$(EXPORTS_DIR=/tmp/fixture-exports _TS_SRC="$INSTALL_SCRIPT" bash -c "
    set -e
    $(cat "$COMPUTE_BLOCK_PARAM")
    echo \$TOTAL_STEPS
")"

# ANTI-VACUITY (live side). Force the fallback constant to 7 but point _TS_SRC
# at the REAL install.sh: if the live branch is genuinely taken the 7 is never
# reached and we still get the full count. If this returns 7, the "live" arms
# are measuring the fallback and every equality below is a tautology.
T_LIVE_PROBE="$(EXPORTS_DIR=/tmp/fixture-exports _TS_SRC="$INSTALL_SCRIPT" bash -c "
    set -e
    $(sed 's/^    TOTAL_STEPS=[0-9]\{1,\}$/    TOTAL_STEPS=7/' "$COMPUTE_BLOCK_PARAM")
    echo \$TOTAL_STEPS
")"
if [[ "$T_LIVE_PROBE" -ne "$TOTAL_PROGRESS_CALLS" ]]; then
    echo "FAIL [anti-vacuity-live]: with the fallback forced to 7 and _TS_SRC pointing at the real install.sh, the block returned ${T_LIVE_PROBE}, not the live count ${TOTAL_PROGRESS_CALLS}" >&2
    echo "  The LIVE branch is not being exercised -- the seed grep is not reading install.sh." >&2
    echo "  CANNOT-RUN, not a pass." >&2
    exit 1
fi
echo "PASS: anti-vacuity -- live branch reached (returned ${T_LIVE_PROBE}, not the forced fallback 7)"

if [[ "$T_WITH_GDPR" -ne "$TOTAL_PROGRESS_CALLS" ]]; then
    echo "FAIL [end-to-end-with-gdpr]: TOTAL_STEPS=${T_WITH_GDPR}, expected ${TOTAL_PROGRESS_CALLS} (every progress call counts)" >&2
    exit 1
fi
echo "PASS: TOTAL_STEPS=${T_WITH_GDPR} when EXPORTS_DIR is set (matches all progress() calls)"

T_NO_GDPR="$(EXPORTS_DIR= _TS_SRC="$INSTALL_SCRIPT" bash -c "
    set -e
    $(cat "$COMPUTE_BLOCK_PARAM")
    echo \$TOTAL_STEPS
")"

if [[ "$T_NO_GDPR" -ne "$((TOTAL_PROGRESS_CALLS - 1))" ]]; then
    echo "FAIL [end-to-end-no-gdpr]: TOTAL_STEPS=${T_NO_GDPR}, expected $((TOTAL_PROGRESS_CALLS - 1)) (GDPR step subtracted)" >&2
    exit 1
fi
echo "PASS: TOTAL_STEPS=${T_NO_GDPR} when EXPORTS_DIR is empty (GDPR subtracted)"

# ── Defensive fallback ──────────────────────────────────────────
# When BASH_SOURCE points at an unreadable file, the auto-count
# returns 0 / fails the regex check.
#
# #629: this arm used to assert only `> 0`. That is the assertion that
# let the constant drift two steps behind the live count and ship a
# progress bar that ended at 105-106%: 38 is greater than zero, so the
# test passed on a wrong number for as long as it existed. `> 0` proves
# the denominator is not a division hazard; it says NOTHING about
# whether it is the RIGHT denominator. Assert EQUALITY with the live
# branch in BOTH EXPORTS_DIR states -- that is the only comparison that
# makes the fallback honest, and it is the one that was never written.
T_FALLBACK="$(EXPORTS_DIR= _TS_SRC=/nonexistent-path-for-fallback-test bash -c "
    set -e
    $(cat "$COMPUTE_BLOCK_PARAM")
    echo \$TOTAL_STEPS
")"

# ANTI-VACUITY: the live and fallback arms must have taken DIFFERENT branches.
# If _TS_SRC were ignored the two would agree trivially and every equality below
# would be a tautology -- which is exactly the defect this rewrite fixes. Prove
# the fallback branch is reachable AND distinguishable by making the constant
# temporarily disagree with the live count and requiring the two to differ.
T_FALLBACK_PROBE="$(EXPORTS_DIR= _TS_SRC=/nonexistent-path-for-fallback-test bash -c "
    set -e
    $(sed 's/^    TOTAL_STEPS=[0-9]\{1,\}$/    TOTAL_STEPS=7/' "$COMPUTE_BLOCK_PARAM")
    echo \$TOTAL_STEPS
")"
if [[ "$T_FALLBACK_PROBE" != "7" ]]; then
    echo "FAIL [anti-vacuity]: with the fallback constant forced to 7 the block returned ${T_FALLBACK_PROBE}, not 7" >&2
    echo "  The fallback branch is NOT being exercised, so every fallback assertion below is vacuous." >&2
    echo "  CANNOT-RUN, not a pass." >&2
    exit 1
fi
echo "PASS: anti-vacuity -- forcing the fallback constant to 7 yields 7, so the fallback branch really runs"

if [[ "$T_FALLBACK" -le 0 ]]; then
    echo "FAIL [fallback]: defensive fallback produced TOTAL_STEPS=${T_FALLBACK} (must be > 0)" >&2
    exit 1
fi

if [[ "$T_FALLBACK" -ne "$T_NO_GDPR" ]]; then
    echo "FAIL [fallback-drift]: fallback TOTAL_STEPS=${T_FALLBACK} but the live count is ${T_NO_GDPR} (EXPORTS_DIR empty)" >&2
    echo "  The compiled-in fallback constant has drifted from the real progress() count." >&2
    echo "  A customer on the \`curl | bash\` path (#682) divides by ${T_FALLBACK} while" >&2
    echo "  ${T_NO_GDPR} steps actually run, so the bar ends at $(( T_NO_GDPR * 100 / T_FALLBACK ))%." >&2
    echo "  Fix the constant in install.sh's defensive-fallback block; do not relax this test." >&2
    exit 1
fi
echo "PASS: fallback TOTAL_STEPS=${T_FALLBACK} EQUALS the live count with EXPORTS_DIR empty"

T_FALLBACK_GDPR="$(EXPORTS_DIR=/tmp/fixture-exports _TS_SRC=/nonexistent-path-for-fallback-test bash -c "
    set -e
    $(cat "$COMPUTE_BLOCK_PARAM")
    echo \$TOTAL_STEPS
")"

if [[ "$T_FALLBACK_GDPR" -ne "$T_WITH_GDPR" ]]; then
    echo "FAIL [fallback-drift-gdpr]: fallback TOTAL_STEPS=${T_FALLBACK_GDPR} but the live count is ${T_WITH_GDPR} (EXPORTS_DIR set)" >&2
    exit 1
fi
echo "PASS: fallback TOTAL_STEPS=${T_FALLBACK_GDPR} EQUALS the live count with EXPORTS_DIR set"

# ── Runtime: progress() clamps PCT at 100 ───────────────────────
# #629, belt to the braces above. Even with the constant correct today,
# a future drift must not render a bar wider than BAR_WIDTH. Extract the
# REAL progress() from install.sh, stub its three collaborators, hand it
# a deliberately-too-small denominator, and read the pct it emits -- the
# same value the GUI consumes. This is a behavioural assertion on the
# shipped function, not a grep for the word "clamp".
PROGRESS_FN="$(mktemp)"
trap 'rm -f "$COMPUTE_BLOCK" "${COMPUTE_BLOCK_PARAM:-}" "$PROGRESS_FN"' EXIT

awk '
    /^progress\(\) \{/ { capture = 1 }
    capture            { print }
    capture && /^\}$/  { exit }
' "$INSTALL_SCRIPT" > "$PROGRESS_FN"

if ! grep -q '^progress() {' "$PROGRESS_FN" || ! tail -1 "$PROGRESS_FN" | grep -q '^}$'; then
    echo "FAIL [extract-progress]: could not extract a complete progress() function" >&2
    exit 1
fi

# TOTAL_STEPS=2 with three calls: the third would be 150% unclamped.
#
# NOT `>/dev/null` on the progress calls -- gui_emit's printf goes to the same
# stdout, so redirecting the bar would redirect the measurement with it and the
# harness would read zero emissions as "no overshoot". The `^pct=` filter below
# separates them instead. NOT `2>/dev/null` on the subshell either: suppressing
# stderr here would turn a broken harness into a silent pass, which is the exact
# shape this whole test exists to catch.
CLAMP_RC=0
CLAMP_OUT="$(bash -c "
    set -e
    gui_step_end()   { :; }
    gui_step_begin() { :; }
    gui_emit()       { printf '%s\n' \"\$3\"; }
    PHASE3_START=\$(date +%s)
    TOTAL_STEPS=2
    CURRENT_STEP=0
    BOLD=''; BLUE=''; NC=''
    $(cat "$PROGRESS_FN")
    progress 'one'   step_one
    progress 'two'   step_two
    progress 'three' step_three
" )" || CLAMP_RC=$?

if [[ "$CLAMP_RC" -ne 0 ]]; then
    echo "FAIL [clamp-harness]: the extracted progress() harness exited ${CLAMP_RC} -- CANNOT-RUN, not a pass" >&2
    echo "  rc=127 means a collaborator stub is missing/misnamed; rc=1 means progress() itself errored." >&2
    printf '%s\n' "$CLAMP_OUT" | sed 's/^/    /' >&2
    exit 1
fi

CLAMP_MAX="$(printf '%s\n' "$CLAMP_OUT" | sed -n 's/^pct=//p' | sort -n | tail -1)"
CLAMP_SEEN="$(printf '%s\n' "$CLAMP_OUT" | grep -c '^pct=' || true)"

if [[ "$CLAMP_SEEN" -ne 3 ]]; then
    echo "FAIL [clamp-harness]: expected 3 pct emissions from progress(), saw ${CLAMP_SEEN}" >&2
    echo "  Raw: ${CLAMP_OUT}" >&2
    echo "  CANNOT-RUN, not a pass: the harness did not exercise progress()." >&2
    exit 1
fi

if [[ -z "$CLAMP_MAX" ]] || [[ "$CLAMP_MAX" -gt 100 ]]; then
    echo "FAIL [clamp]: progress() emitted pct=${CLAMP_MAX} with TOTAL_STEPS=2 and 3 steps" >&2
    echo "  PCT must be clamped at 100. Unclamped, FILLED exceeds BAR_WIDTH and EMPTY goes" >&2
    echo "  negative, so printf renders a bar WIDER than the width it declares." >&2
    exit 1
fi
echo "PASS: progress() clamps pct at ${CLAMP_MAX} when the denominator under-counts (3 steps / TOTAL_STEPS=2)"

echo ""
echo "ALL TOTAL_STEPS DYNAMIC TESTS PASSED"
