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
# Find every `progress "..."` line that is inside an `if [[ ... ]]`
# (i.e. indented more than the unconditional column-0 calls). Each
# such call must have a matching `&& TOTAL_STEPS=$((TOTAL_STEPS - 1))`
# entry at the top of Phase 3.
CONDITIONAL_PROGRESS_COUNT="$(grep -cE '^[[:space:]]+progress "' "$INSTALL_SCRIPT")"
SUBTRACT_COUNT="$(grep -cE '&& TOTAL_STEPS=\$\(\(TOTAL_STEPS - 1\)\)' "$INSTALL_SCRIPT")"

if [[ "$CONDITIONAL_PROGRESS_COUNT" -ne "$SUBTRACT_COUNT" ]]; then
    echo "FAIL [drift]: conditional progress() calls (${CONDITIONAL_PROGRESS_COUNT}) does not match subtract entries (${SUBTRACT_COUNT})" >&2
    echo "  Conditional progress() calls:" >&2
    grep -nE '^[[:space:]]+progress "' "$INSTALL_SCRIPT" >&2
    echo "  Subtract entries:" >&2
    grep -nE '&& TOTAL_STEPS=\$\(\(TOTAL_STEPS - 1\)\)' "$INSTALL_SCRIPT" >&2
    echo "  Add a `[[ -z \"\$<gate>\" ]] && TOTAL_STEPS=\$((TOTAL_STEPS - 1))` line" >&2
    echo "  for each conditional progress() call, paired with the gate's Phase 2 flag." >&2
    exit 1
fi
echo "PASS: subtract list matches conditional progress() count (${CONDITIONAL_PROGRESS_COUNT})"

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

# Source the block via a child shell with controlled environment.
# The block uses ${BASH_SOURCE[0]}, which the child shell must see
# as the install.sh path. `bash -c` clears BASH_SOURCE so we
# rebuild it explicitly.
T_WITH_GDPR="$(EXPORTS_DIR=/tmp/fixture-exports bash -c "
    set -e
    BASH_SOURCE=('$INSTALL_SCRIPT')
    $(cat "$COMPUTE_BLOCK")
    echo \$TOTAL_STEPS
")"

if [[ "$T_WITH_GDPR" -ne "$TOTAL_PROGRESS_CALLS" ]]; then
    echo "FAIL [end-to-end-with-gdpr]: TOTAL_STEPS=${T_WITH_GDPR}, expected ${TOTAL_PROGRESS_CALLS} (every progress call counts)" >&2
    exit 1
fi
echo "PASS: TOTAL_STEPS=${T_WITH_GDPR} when EXPORTS_DIR is set (matches all progress() calls)"

T_NO_GDPR="$(EXPORTS_DIR= bash -c "
    set -e
    BASH_SOURCE=('$INSTALL_SCRIPT')
    $(cat "$COMPUTE_BLOCK")
    echo \$TOTAL_STEPS
")"

if [[ "$T_NO_GDPR" -ne "$((TOTAL_PROGRESS_CALLS - 1))" ]]; then
    echo "FAIL [end-to-end-no-gdpr]: TOTAL_STEPS=${T_NO_GDPR}, expected $((TOTAL_PROGRESS_CALLS - 1)) (GDPR step subtracted)" >&2
    exit 1
fi
echo "PASS: TOTAL_STEPS=${T_NO_GDPR} when EXPORTS_DIR is empty (GDPR subtracted)"

# ── Defensive fallback ──────────────────────────────────────────
# When BASH_SOURCE points at an unreadable file, the auto-count
# returns 0 / fails the regex check. Fallback must produce a sane
# value so the progress bar never divides by zero.
T_FALLBACK="$(EXPORTS_DIR= bash -c "
    set -e
    BASH_SOURCE=('/nonexistent-path-for-fallback-test')
    $(cat "$COMPUTE_BLOCK")
    echo \$TOTAL_STEPS
")"

if [[ "$T_FALLBACK" -le 0 ]]; then
    echo "FAIL [fallback]: defensive fallback produced TOTAL_STEPS=${T_FALLBACK} (must be > 0)" >&2
    exit 1
fi
echo "PASS: defensive fallback yields TOTAL_STEPS=${T_FALLBACK} when BASH_SOURCE is unreadable"

echo ""
echo "ALL TOTAL_STEPS DYNAMIC TESTS PASSED"
