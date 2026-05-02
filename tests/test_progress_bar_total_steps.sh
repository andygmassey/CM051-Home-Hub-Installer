#!/usr/bin/env bash
#
# tests/test_progress_bar_total_steps.sh
#
# Asserts that install.sh's progress bar denominator (TOTAL_STEPS
# + conditional adders) matches the number of `progress "..."`
# call sites in the script. A mismatch means a new step landed
# without bumping TOTAL_STEPS (or vice-versa), which on a fresh
# customer install shows up as a percentage that under-fills or
# overflows -- a "this thing looks broken" first impression we
# spent the hardening PR getting rid of.
#
# Why this lives in tests/ rather than as inline shellcheck:
#   - shellcheck doesn't understand the semantic relationship
#     between TOTAL_STEPS and the literal `progress` call count;
#     this is a script-level invariant, not a syntax issue
#   - the sibling tests (test_user_facing_tree.sh,
#     test_uninstaller_keep_prompt.sh, test_wiki_compose_paths.sh)
#     already established the "extract content from install.sh,
#     assert structural invariants" pattern -- this fits in
#
# Pure bash + grep + awk. No docker, no install run.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${REPO_ROOT}/install.sh"

if [[ ! -f "$INSTALL_SCRIPT" ]]; then
    echo "FAIL: install.sh not found at $INSTALL_SCRIPT" >&2
    exit 1
fi

# ── 1. Extract the static TOTAL_STEPS base ──────────────────
# Single literal assignment: `TOTAL_STEPS=<integer>` (no
# arithmetic, no quotes). Grep just the first match anchored at
# the start of the line, then strip the prefix.
BASE_LINE="$(grep -n -E '^TOTAL_STEPS=[0-9]+' "$INSTALL_SCRIPT" || true)"
if [[ -z "$BASE_LINE" ]]; then
    echo "FAIL: could not find a literal TOTAL_STEPS=<int> assignment" >&2
    exit 1
fi
BASE="$(echo "$BASE_LINE" | head -1 | sed -E 's/^[0-9]+:TOTAL_STEPS=([0-9]+).*/\1/')"
if ! [[ "$BASE" =~ ^[0-9]+$ ]]; then
    echo "FAIL: extracted TOTAL_STEPS base is not a number: $BASE" >&2
    exit 1
fi

# ── 2. Count the `+1` adders ────────────────────────────────
# Both conditional (`[[ ... ]] && TOTAL_STEPS=$((TOTAL_STEPS +
# 1))`) and unconditional (`TOTAL_STEPS=$((TOTAL_STEPS + 1))`)
# variants increment by one each, so we just count occurrences.
INCREMENTS="$(grep -c -E 'TOTAL_STEPS=\$\(\(TOTAL_STEPS \+ 1\)\)' "$INSTALL_SCRIPT" || true)"
if ! [[ "$INCREMENTS" =~ ^[0-9]+$ ]]; then
    INCREMENTS=0
fi

MAX_TOTAL_STEPS=$((BASE + INCREMENTS))

# ── 3. Count `progress "..."` call sites ────────────────────
# Match `progress "...` with optional leading whitespace (some
# call sites are nested inside conditionals -- the indentation
# does not affect the count, just the runtime gating). The
# function definition itself ('progress() {') is excluded by
# the trailing space + quote requirement.
PROGRESS_CALLS="$(grep -c -E '^\s*progress "' "$INSTALL_SCRIPT" || true)"
if ! [[ "$PROGRESS_CALLS" =~ ^[0-9]+$ ]]; then
    PROGRESS_CALLS=0
fi

echo "  TOTAL_STEPS base: ${BASE}"
echo "  +1 adders:        ${INCREMENTS}"
echo "  Maximum total:    ${MAX_TOTAL_STEPS}"
echo "  progress calls:   ${PROGRESS_CALLS}"

# ── 4. Assert the bar can hit but never exceed 100% ─────────
# We compare with `==` rather than `>=` so that if a `progress`
# call is REMOVED without dropping the matching TOTAL_STEPS,
# the test catches the under-fill case as well as the over-
# fill case the original hardening item was about.
if [[ "$MAX_TOTAL_STEPS" -ne "$PROGRESS_CALLS" ]]; then
    echo "FAIL: TOTAL_STEPS denominator (${MAX_TOTAL_STEPS}) does not match" >&2
    echo "      the number of progress call sites (${PROGRESS_CALLS})." >&2
    echo "" >&2
    echo "      If you added a new progress \"...\" call, bump TOTAL_STEPS" >&2
    echo "      (or add a TOTAL_STEPS=\$((TOTAL_STEPS + 1)) line if the" >&2
    echo "      step is conditional). If you removed one, drop the" >&2
    echo "      matching number." >&2
    echo "" >&2
    echo "      Progress call sites:" >&2
    grep -n -E '^\s*progress "' "$INSTALL_SCRIPT" >&2
    exit 1
fi

echo "PASS: progress bar denominator matches call count (max ${MAX_TOTAL_STEPS} steps)"
