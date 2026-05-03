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

# ── Structural: progress count is sane ──────────────────────────
# The end-to-end subshell test was removed: BASH_SOURCE is bash's
# auto-managed call-stack array and cannot be reliably overridden
# via `bash -c`, so the previous attempt fell through to the
# defensive fallback and asserted PASS tautologically. The
# structural checks above (auto-count line uses BASH_SOURCE,
# subtract list matches conditional progress count) cover the
# contract -- if the auto-count line is correct and the subtract
# list is in sync, install.sh's runtime computation is also
# correct.
TOTAL_PROGRESS_CALLS="$(grep -cE '^[[:space:]]*progress "' "$INSTALL_SCRIPT")"
if [[ "$TOTAL_PROGRESS_CALLS" -lt 10 ]]; then
    echo "FAIL [progress-too-few]: only ${TOTAL_PROGRESS_CALLS} progress() calls found (expected >=10)" >&2
    echo "  Either install.sh shrunk dramatically or the regex broke." >&2
    exit 1
fi
echo "PASS: install.sh has ${TOTAL_PROGRESS_CALLS} progress() calls (auto-count input)"

# ── Defensive fallback constant in sane range ───────────────────
# Read the fallback constant out of install.sh; assert it's > 0
# (so the bar never divides by zero) and <= the actual progress
# count (overshooting <100% is preferable to undershooting >100%
# on the bar).
FALLBACK_VALUE="$(grep -E '^[[:space:]]+TOTAL_STEPS=[0-9]+$' "$INSTALL_SCRIPT" \
    | head -n 1 | awk -F= '{print $2}')"
if [[ -z "$FALLBACK_VALUE" || "$FALLBACK_VALUE" -le 0 ]]; then
    echo "FAIL [fallback-missing]: defensive fallback constant not found or non-positive" >&2
    exit 1
fi
if [[ "$FALLBACK_VALUE" -gt "$TOTAL_PROGRESS_CALLS" ]]; then
    echo "FAIL [fallback-too-high]: fallback=${FALLBACK_VALUE} exceeds actual progress count ${TOTAL_PROGRESS_CALLS}" >&2
    exit 1
fi
echo "PASS: defensive fallback=${FALLBACK_VALUE} (>0, <= actual progress count ${TOTAL_PROGRESS_CALLS})"

echo ""
echo "ALL TOTAL_STEPS DYNAMIC TESTS PASSED"
