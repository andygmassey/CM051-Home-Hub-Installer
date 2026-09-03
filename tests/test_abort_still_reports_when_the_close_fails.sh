#!/usr/bin/env bash
#
# tests/test_abort_still_reports_when_the_close_fails.sh
#
# #640. An install that dies must ALWAYS emit exactly one terminal DONE
# marker, INCLUDING when the step-close inside gui_done is itself failing.
#
# THE DEFECT THIS FAILS ON. gui_done() closes the open step before it records
# that a terminal marker has gone out:
#
#     if [[ "$status" != "ok" && -n "${__OSTLER_STEP_ID:-}" ]]; then
#         gui_step_end error          # <- fallible
#     fi
#     OSTLER_DONE_EMITTED=1           # <- guard
#     ... gui_emit DONE ...           # <- the customer's only statement
#
# install.sh runs under `set -Eeuo pipefail` (install.sh:29). Without a
# tolerated close, a failure anywhere inside gui_step_end takes the shell down
# INSIDE gui_done -- after the caller committed to reporting, before the guard,
# before the marker. The run then ends with NO terminal marker at all, which
# the GUI renders as its no-DONE crash fallback: a red banner over an install
# that never said why it stopped. On the pre-fix file arm 2 below scores 0.
#
# WHY THE OBVIOUS FIX IS NOT THE FIX, recorded so nobody re-derives it:
# moving `OSTLER_DONE_EMITTED=1` above the close does NOT help. Measured, it
# still yields 0 markers, and it is worse, because the guard then also silences
# install.sh's EXIT backstop. Only tolerating the close works.
#
# WHAT IS INJECTED, AND WHAT IS NOT CLAIMED. Arm 2 forces gui_emit to fail for
# STEP_END only. That stands in for any command failing inside gui_step_end
# (EPIPE on the GUI fd being the realistic route). This test does NOT claim
# that fault is reachable in production; it asserts that IF it happens the
# customer is still told. That is the whole point of an abort path.
#
# Pure bash + standard tools. No network, no box, no fixtures.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${REPO_ROOT}/lib/progress_emitter.sh"
INSTALLER="${REPO_ROOT}/install.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$LIB"       ]] || fail "lib/progress_emitter.sh not found at $LIB"
[[ -f "$INSTALLER" ]] || fail "install.sh not found at $INSTALLER"

WORK="$(mktemp -d -t ostler-640)"
trap 'rm -rf "$WORK"' EXIT

# ── Extract the REAL ERR handler from install.sh ──────────────────
#
# Sliced by its own delimiters rather than by line number, so this test does
# not rot the next time anything above it moves. Both markers are literal
# comments in install.sh; if either stops matching, that is a CANNOT-RUN and
# is reported as a failure rather than silently skipped.
awk '/^_ostler_on_err\(\) \{$/,/^# ─── OSTLER_ERR_TRAP_END/' \
    "$INSTALLER" > "${WORK}/handler.inc"

handler_lines="$(wc -l < "${WORK}/handler.inc" | tr -d ' ')"
if [[ "$handler_lines" -lt 20 ]]; then
    fail "could not extract _ostler_on_err from install.sh (got ${handler_lines} lines).
      This is CANNOT-RUN, not a pass: the delimiters in install.sh moved."
fi
grep -q "^trap '_ostler_on_err" "${WORK}/handler.inc" \
    || fail "extracted handler carries no ERR trap line -- extraction is wrong.
      This is CANNOT-RUN, not a pass."

# ── The harness both arms share ───────────────────────────────────
cat > "${WORK}/run.sh" <<'HARNESS'
#!/bin/bash
set -Eeuo pipefail
LIB="$1"; HANDLER="$2"; INJECT="$3"

export OSTLER_GUI=1
# shellcheck disable=SC1090
source "$LIB"

# Keep the real emitter, then shadow it so arm 2 can fail STEP_END only.
eval "$(declare -f gui_emit | sed '1s/^gui_emit/__real_gui_emit/')"
gui_emit() {
    if [[ "$INJECT" == "1" && "${1:-}" == "STEP_END" ]]; then
        __real_gui_emit "$@"
        return 1
    fi
    __real_gui_emit "$@"
}

# shellcheck disable=SC1090
source "$HANDLER"

OSTLER_DONE_EMITTED=""
gui_step_begin t640 "Harness step" 3 1 1
false            # abort, the way a real failing command does
HARNESS
chmod +x "${WORK}/run.sh"

count_done() {
    # Markers go to STDERR (routing changed 2026-05-13); capture only that.
    bash "${WORK}/run.sh" "$LIB" "${WORK}/handler.inc" "$1" 2>&1 >/dev/null \
        | grep -c 'DONE' || true
}

rc=0

# ── Arm 1, CONTROL: no injection. Proves the harness can report at all ──
control="$(count_done 0)"
if [[ "$control" == "1" ]]; then
    echo "ok   arm 1 CONTROL: a clean abort emits exactly 1 DONE marker"
else
    echo "FAIL arm 1 CONTROL: expected 1 DONE marker, got ${control}."
    echo "     The harness itself is broken; arm 2 proves nothing. CANNOT-RUN."
    rc=1
fi

# ── Arm 2, THE DEFECT: the close fails. Scores 0 before the fix ──
injected="$(count_done 1)"
if [[ "$injected" == "1" ]]; then
    echo "ok   arm 2 INJECTED: the close failed and the customer was STILL told"
else
    echo "FAIL arm 2 INJECTED: expected 1 DONE marker, got ${injected}."
    echo "     gui_done's step-close is fatal, so a failure there destroys the"
    echo "     only terminal marker the run produces and the GUI shows a bare"
    echo "     crash banner. Fix: gui_step_end error || true  (#640)."
    rc=1
fi

# ── Arm 3: the fix must not have cost us the close on the happy path ──
# A tolerated close must still CLOSE. If failed_steps stopped counting, the
# `|| true` was applied too widely.
steps="$(bash "${WORK}/run.sh" "$LIB" "${WORK}/handler.inc" 0 2>&1 >/dev/null \
         | grep -c 'failed_steps=1' || true)"
if [[ "$steps" == "1" ]]; then
    echo "ok   arm 3: the close still runs and still counts the failed step"
else
    echo "FAIL arm 3: expected failed_steps=1 on the DONE line, got ${steps} match(es)."
    echo "     Tolerating the close must not stop it happening."
    rc=1
fi

[[ "$rc" -eq 0 ]] && echo "PASS: tests/test_abort_still_reports_when_the_close_fails.sh"
exit "$rc"
