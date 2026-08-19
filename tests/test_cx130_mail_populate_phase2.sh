#!/usr/bin/env bash
#
# tests/test_cx130_mail_populate_phase2.sh
#
# CX-130 (v1.0.1): the "account exists but Mail.app has not fetched yet
# -> open Mail and wait while it syncs" prompt (the CX-100 state-2
# wait-for-populate) must fire in the QUESTIONS phase (Phase 2), not in
# the unattended Phase-3 execution region. A customer who walks away
# after answering the questions must not return to a blocking "Open
# Apple Mail?" dialog ~16% into the install.
#
# This mirrors the CX-37 hoist of the "no Mail account -> Internet
# Accounts" prompt (guarded by MAIL_PROMPT_SHOWN_EARLY). CX-130 adds the
# twin guard MAIL_POPULATE_PROMPT_SHOWN_EARLY for the populate prompt.
#
# Axes:
#   1. install.sh parses.
#   2. The Phase-2 populate probe exists and calls
#      _three_state_wait_for_populate BEFORE the Phase-3 boundary.
#   3. The early populate probe sets + exports
#      MAIL_POPULATE_PROMPT_SHOWN_EARLY.
#   4. The Phase-3 populate block is guarded on
#      [[ -z "${MAIL_POPULATE_PROMPT_SHOWN_EARLY:-}" ]] so it SKIPS when
#      the early prompt already ran (and remains as a fallback otherwise).
#   5. The Phase-2 populate probe is gated on OSTLER_GUI == 1 (headless
#      safety) and _has_fda (CX-103 -- account count is unreliable
#      without FDA).
#   6. The Phase-3 populate block still rewrites the sidecar + emits
#      gui_emit MAIL_ACCOUNTS_FOUND (side-effects preserved).
#
# Synthetic / static only -- pure bash + awk + grep over install.sh.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
FAILED=0

failure() { echo "FAIL: $*" >&2; FAILED=1; }

[[ -f "$INSTALL_SH" ]] || { echo "FATAL: install.sh not found" >&2; exit 2; }

# Axis 1: parse.
if ! bash -n "$INSTALL_SH"; then
    echo "FATAL: install.sh fails bash -n" >&2
    exit 2
fi
echo "PASS: install.sh parses"

# Locate the Phase-3 boundary (the unattended-install marker).
BOUNDARY="$(grep -nE 'PHASE 3: INSTALL EVERYTHING' "$INSTALL_SH" | head -1 | cut -d: -f1)"
[[ -n "$BOUNDARY" ]] || { echo "FATAL: Phase-3 boundary not found" >&2; exit 2; }
echo "PASS: Phase-3 boundary at line $BOUNDARY"

# Axis 2: the EARLY populate probe + its wait call live before the boundary.
EARLY_PROBE_LINE="$(grep -n 'CX-130 populate probe: entering' "$INSTALL_SH" | head -1 | cut -d: -f1)"
[[ -n "$EARLY_PROBE_LINE" ]] || failure "CX-130 early populate probe block not found"
if [[ -n "$EARLY_PROBE_LINE" ]]; then
    if [[ "$EARLY_PROBE_LINE" -lt "$BOUNDARY" ]]; then
        echo "PASS: CX-130 early populate probe is in Phase 2 (line $EARLY_PROBE_LINE < $BOUNDARY)"
    else
        failure "CX-130 early populate probe at $EARLY_PROBE_LINE is AFTER the Phase-3 boundary ($BOUNDARY)"
    fi
fi

# The early block must actually call _three_state_wait_for_populate, and
# that call must be before the boundary.
EARLY_WAIT_LINE="$(awk -v s="$EARLY_PROBE_LINE" 'NR>=s && /_three_state_wait_for_populate \\$/ {print NR; exit}' "$INSTALL_SH")"
# Fallback: the call may not end with a backslash; match the bare call too.
if [[ -z "$EARLY_WAIT_LINE" ]]; then
    EARLY_WAIT_LINE="$(awk -v s="$EARLY_PROBE_LINE" -v b="$BOUNDARY" 'NR>=s && NR<b && /_three_state_wait_for_populate/ {print NR; exit}' "$INSTALL_SH")"
fi
[[ -n "$EARLY_WAIT_LINE" && "$EARLY_WAIT_LINE" -lt "$BOUNDARY" ]] \
    || failure "CX-130 early block does not call _three_state_wait_for_populate before the Phase-3 boundary"
[[ -n "$EARLY_WAIT_LINE" ]] && echo "PASS: early _three_state_wait_for_populate call at line $EARLY_WAIT_LINE (< $BOUNDARY)"

# Axis 3: the early probe sets + exports the guard flag.
if grep -qE '^\s*MAIL_POPULATE_PROMPT_SHOWN_EARLY=1' "$INSTALL_SH" \
   && grep -qE 'export MAIL_POPULATE_PROMPT_SHOWN_EARLY' "$INSTALL_SH"; then
    echo "PASS: early probe sets + exports MAIL_POPULATE_PROMPT_SHOWN_EARLY"
else
    failure "early probe does not set/export MAIL_POPULATE_PROMPT_SHOWN_EARLY"
fi

# Axis 4: the Phase-3 populate block is guarded on the early flag.
# Find the Phase-3 populate condition (after the boundary) -- it is the
# block that checks MAIL_HAS_FETCHED != "true" with the SHOWN_EARLY guard.
if awk -v b="$BOUNDARY" '
    NR>b && /MAIL_HAS_FETCHED.*!=.*"true"/ { hit=1 }
    hit && /MAIL_POPULATE_PROMPT_SHOWN_EARLY/ { print "guarded"; exit }
    hit && /_three_state_wait_for_populate/ { print "unguarded"; exit }
' "$INSTALL_SH" | grep -q guarded; then
    echo "PASS: Phase-3 populate block is guarded on MAIL_POPULATE_PROMPT_SHOWN_EARLY"
else
    failure "Phase-3 populate block is NOT guarded on MAIL_POPULATE_PROMPT_SHOWN_EARLY -- it would double-prompt mid-install"
fi

# Axis 5: the early probe is GUI-gated + FDA-gated (headless safety + CX-103).
# Inspect the ~10 lines immediately after the "entering" marker, where the
# probe's guard condition lives.
EARLY_BLOCK="$(awk -v s="$EARLY_PROBE_LINE" 'NR>=s && NR<=s+12' "$INSTALL_SH")"
if grep -qE 'OSTLER_GUI:-0.*==.*"1"' <<< "$EARLY_BLOCK"; then
    echo "PASS: early populate probe is gated on OSTLER_GUI == 1"
else
    failure "early populate probe is not OSTLER_GUI-gated -- headless installs could block"
fi
if grep -qw '_has_fda' <<< "$EARLY_BLOCK"; then
    echo "PASS: early populate probe is gated on _has_fda (CX-103)"
else
    failure "early populate probe does not call _has_fda -- account count unreliable without FDA"
fi

# Axis 6: the Phase-3 block still rewrites the sidecar + emits the marker.
if grep -qE 'gui_emit MAIL_ACCOUNTS_FOUND' "$INSTALL_SH"; then
    echo "PASS: gui_emit MAIL_ACCOUNTS_FOUND marker preserved"
else
    failure "gui_emit MAIL_ACCOUNTS_FOUND marker missing -- side-effect lost"
fi
if grep -qE 'write_pipeline_signals.py' "$INSTALL_SH"; then
    echo "PASS: pipeline_signals.json writer call preserved"
else
    failure "write_pipeline_signals.py call missing -- Doctor sidecar side-effect lost"
fi

if (( FAILED == 0 )); then
    echo "ALL PASS: tests/test_cx130_mail_populate_phase2.sh"
    exit 0
else
    echo "FAILED: tests/test_cx130_mail_populate_phase2.sh" >&2
    exit 1
fi
