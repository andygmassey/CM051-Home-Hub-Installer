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
#   This test pins the contract (updated 2026-07-07 for the
#   conversation bundle feeds + data_step subtract entries):
#     1. TOTAL_STEPS is computed by counting `progress` lines in
#        install.sh, not hard-coded.
#     2. With every evaluable gate on, TOTAL_STEPS == total
#        progress calls.
#     3. With all evaluable gates off, TOTAL_STEPS == total - 5
#        (GDPR + 4 bundle feeds); plaintext mode subtracts data_step
#        too (total - 6).
#     4. The subtract list at the top of Phase 3 has exactly one
#        entry per `progress` call gated on compute-time-evaluable
#        state -- adding a new conditional `progress` line without a
#        matching subtract entry (or a justified BEST_EFFORT_ALLOWLIST
#        entry) will trip this test.
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
# Find every `progress "..."` line that is inside an `if [[ ... ]]`
# (i.e. indented more than the unconditional column-0 calls). Each
# such call must have a matching `&& TOTAL_STEPS=$((TOTAL_STEPS - 1))`
# entry at the top of Phase 3 -- UNLESS its gate depends on Phase 3
# state that does not exist at compute time. Those are carried on an
# explicit allowlist here (rule updated 2026-07-07, matching the
# BEST-EFFORT EXCEPTIONS note in install.sh's subtract block):
#
#   - wiki_recompile_catchup_agent: gated on the tick script Phase 3
#     itself installs, so it fires on every successful install; a
#     compute-time [[ -x ]] would wrongly subtract a firing step.
#
# (data_step is NOT allowlisted: its evaluable ALLOW_PLAINTEXT arm
# has a subtract entry; the Qdrant-reachability arm is best-effort
# by documented design.)
BEST_EFFORT_ALLOWLIST=("wiki_recompile_catchup_agent")
# The allowlist must not rot: each allowlisted id must still be a
# real conditional progress call.
for allow_id in "${BEST_EFFORT_ALLOWLIST[@]}"; do
    if ! grep -qE "^[[:space:]]+progress \".*\" \"${allow_id}\"" "$INSTALL_SCRIPT"; then
        echo "FAIL [allowlist-rot]: allowlisted step '${allow_id}' is no longer a conditional progress call; remove it from BEST_EFFORT_ALLOWLIST" >&2
        exit 1
    fi
done

CONDITIONAL_PROGRESS_COUNT="$(grep -cE '^[[:space:]]+progress "' "$INSTALL_SCRIPT")"
SUBTRACT_COUNT="$(grep -cE '&& TOTAL_STEPS=\$\(\(TOTAL_STEPS - 1\)\)' "$INSTALL_SCRIPT")"
EXPECTED_SUBTRACTS=$(( CONDITIONAL_PROGRESS_COUNT - ${#BEST_EFFORT_ALLOWLIST[@]} ))

if [[ "$EXPECTED_SUBTRACTS" -ne "$SUBTRACT_COUNT" ]]; then
    echo "FAIL [drift]: conditional progress() calls (${CONDITIONAL_PROGRESS_COUNT}) minus best-effort allowlist (${#BEST_EFFORT_ALLOWLIST[@]}) does not match subtract entries (${SUBTRACT_COUNT})" >&2
    echo "  Conditional progress() calls:" >&2
    grep -nE '^[[:space:]]+progress "' "$INSTALL_SCRIPT" >&2
    echo "  Subtract entries:" >&2
    grep -nE '&& TOTAL_STEPS=\$\(\(TOTAL_STEPS - 1\)\)' "$INSTALL_SCRIPT" >&2
    echo "  Add a '[[ <gate-false> ]] && TOTAL_STEPS=\$((TOTAL_STEPS - 1))' line" >&2
    echo "  for each new conditional progress() call (or, if its gate is" >&2
    echo "  genuinely Phase-3 state, add it to BEST_EFFORT_ALLOWLIST here" >&2
    echo "  AND to the BEST-EFFORT EXCEPTIONS note in install.sh)." >&2
    exit 1
fi
echo "PASS: subtract list matches conditional progress() count (${CONDITIONAL_PROGRESS_COUNT} - ${#BEST_EFFORT_ALLOWLIST[@]} allowlisted = ${SUBTRACT_COUNT})"

# ── End-to-end: computation with EXPORTS_DIR set ────────────────
# Extract the TOTAL_STEPS computation block from install.sh, run
# it in isolation with a mocked EXPORTS_DIR, assert the result.
TOTAL_PROGRESS_CALLS="$(grep -cE '^[[:space:]]*progress "' "$INSTALL_SCRIPT")"

# The block runs from `TOTAL_STEPS="$(grep ` to `CURRENT_STEP=0`.
COMPUTE_BLOCK="$(mktemp)"
trap 'rm -f "$COMPUTE_BLOCK"' EXIT

awk '
    /^TOTAL_STEPS="\$\(grep / { capture = 1 }
    capture                   { print }
    /^CURRENT_STEP=0$/        { capture = 0; exit }
' "$INSTALL_SCRIPT" > "$COMPUTE_BLOCK"

if [[ ! -s "$COMPUTE_BLOCK" ]]; then
    echo "FAIL [extract]: could not extract the TOTAL_STEPS computation block" >&2
    exit 1
fi

# BASH_SOURCE cannot be assigned on macOS system bash 3.2, so bake the
# script path into the block textually for the child-shell runs.
COMPUTE_BLOCK_REAL="$COMPUTE_BLOCK.real"
COMPUTE_BLOCK_MISSING="$COMPUTE_BLOCK.missing"
sed "s|\${BASH_SOURCE\[0\]}|$INSTALL_SCRIPT|g" "$COMPUTE_BLOCK" > "$COMPUTE_BLOCK_REAL"
sed "s|\${BASH_SOURCE\[0\]}|/nonexistent-path-for-fallback-test|g" "$COMPUTE_BLOCK" > "$COMPUTE_BLOCK_MISSING"

# Source the block via a child shell with controlled environment.
# The block reads ${BASH_SOURCE[0]}; BASH_SOURCE is not assignable
# on macOS system bash 3.2, so substitute the path textually into
# the extracted block instead (SELF_PATH placeholder).
#
# Harness updated 2026-07-07: the subtract list now covers the
# conversation bundle feeds + the data_step plaintext skip, so the
# "everything on" case needs a fixture environment where every
# evaluable gate is TRUE (fixture HOME with Library/Mail +
# Library/Messages/chat.db; USER_FACING_ROOT with Transcripts;
# channel + consent flags on; ALLOW_PLAINTEXT=0).
FIXTURE_ROOT="$(mktemp -d)"
trap 'rm -f "$COMPUTE_BLOCK" "$COMPUTE_BLOCK_REAL" "$COMPUTE_BLOCK_MISSING"; rm -rf "$FIXTURE_ROOT"' EXIT
mkdir -p "$FIXTURE_ROOT/home/Library/Mail" \
         "$FIXTURE_ROOT/home/Library/Messages" \
         "$FIXTURE_ROOT/userfacing/Transcripts"
touch "$FIXTURE_ROOT/home/Library/Messages/chat.db"

T_ALL_ON="$(
    EXPORTS_DIR=/tmp/fixture-exports \
    HOME="$FIXTURE_ROOT/home" \
    USER_FACING_ROOT="$FIXTURE_ROOT/userfacing" \
    CHANNEL_WHATSAPP_ENABLED=true \
    CHANNEL_WHATSAPP_CONSENT_ACCEPTED=true \
    OSTLER_CONSENT_THIRD_PARTY_DECISION=accepted \
    ALLOW_PLAINTEXT=0 \
    bash -c "
    set -e
    $(cat "$COMPUTE_BLOCK_REAL")
    echo \$TOTAL_STEPS
")"

if [[ "$T_ALL_ON" -ne "$TOTAL_PROGRESS_CALLS" ]]; then
    echo "FAIL [end-to-end-all-on]: TOTAL_STEPS=${T_ALL_ON}, expected ${TOTAL_PROGRESS_CALLS} (every progress call counts when all gates are on)" >&2
    exit 1
fi
echo "PASS: TOTAL_STEPS=${T_ALL_ON} when every evaluable gate is on (matches all progress() calls)"

# All evaluable gates OFF: GDPR + 4 bundle feeds subtract (the
# data_step plaintext subtract does NOT fire with ALLOW_PLAINTEXT=0).
T_ALL_OFF="$(
    EXPORTS_DIR= \
    HOME="$FIXTURE_ROOT/emptyhome" \
    USER_FACING_ROOT="$FIXTURE_ROOT/emptyuserfacing" \
    CHANNEL_WHATSAPP_ENABLED=false \
    CHANNEL_WHATSAPP_CONSENT_ACCEPTED=false \
    OSTLER_CONSENT_THIRD_PARTY_DECISION= \
    ALLOW_PLAINTEXT=0 \
    bash -c "
    set -e
    $(cat "$COMPUTE_BLOCK_REAL")
    echo \$TOTAL_STEPS
")"

if [[ "$T_ALL_OFF" -ne "$((TOTAL_PROGRESS_CALLS - 5))" ]]; then
    echo "FAIL [end-to-end-all-off]: TOTAL_STEPS=${T_ALL_OFF}, expected $((TOTAL_PROGRESS_CALLS - 5)) (GDPR + 4 bundle feeds subtracted)" >&2
    exit 1
fi
echo "PASS: TOTAL_STEPS=${T_ALL_OFF} when all evaluable gates are off (GDPR + 4 bundle feeds subtracted)"

# Plaintext mode additionally subtracts the data_step.
T_PLAINTEXT="$(
    EXPORTS_DIR= \
    HOME="$FIXTURE_ROOT/emptyhome" \
    USER_FACING_ROOT="$FIXTURE_ROOT/emptyuserfacing" \
    CHANNEL_WHATSAPP_ENABLED=false \
    CHANNEL_WHATSAPP_CONSENT_ACCEPTED=false \
    OSTLER_CONSENT_THIRD_PARTY_DECISION= \
    ALLOW_PLAINTEXT=1 \
    bash -c "
    set -e
    $(cat "$COMPUTE_BLOCK_REAL")
    echo \$TOTAL_STEPS
")"

if [[ "$T_PLAINTEXT" -ne "$((TOTAL_PROGRESS_CALLS - 6))" ]]; then
    echo "FAIL [end-to-end-plaintext]: TOTAL_STEPS=${T_PLAINTEXT}, expected $((TOTAL_PROGRESS_CALLS - 6)) (data_step also subtracted in plaintext mode)" >&2
    exit 1
fi
echo "PASS: TOTAL_STEPS=${T_PLAINTEXT} in plaintext mode (data_step also subtracted)"

# ── Defensive fallback ──────────────────────────────────────────
# When BASH_SOURCE points at an unreadable file, the auto-count
# returns 0 / fails the regex check. Fallback must produce a sane
# value so the progress bar never divides by zero.
T_FALLBACK="$(
    EXPORTS_DIR= \
    HOME="$FIXTURE_ROOT/emptyhome" \
    USER_FACING_ROOT="$FIXTURE_ROOT/emptyuserfacing" \
    CHANNEL_WHATSAPP_ENABLED=false \
    CHANNEL_WHATSAPP_CONSENT_ACCEPTED=false \
    OSTLER_CONSENT_THIRD_PARTY_DECISION= \
    ALLOW_PLAINTEXT=0 \
    bash -c "
    set -e
    $(cat "$COMPUTE_BLOCK_MISSING")
    echo \$TOTAL_STEPS
")"

if [[ "$T_FALLBACK" -le 0 ]]; then
    echo "FAIL [fallback]: defensive fallback produced TOTAL_STEPS=${T_FALLBACK} (must be > 0)" >&2
    exit 1
fi
echo "PASS: defensive fallback yields TOTAL_STEPS=${T_FALLBACK} when BASH_SOURCE is unreadable"

echo ""
echo "ALL TOTAL_STEPS DYNAMIC TESTS PASSED"
