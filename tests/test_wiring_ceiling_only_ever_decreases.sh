#!/usr/bin/env bash
#
# THE UNWIRED CEILING IS A ONE-WAY RATCHET. IT MAY NEVER BE RAISED.
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS
# ---------------------------------------------------------------------------
# ANDY, 2026-09-02: "The bigger question is WHY there continue to be 'unwired'
# things at all??? I keep asking, yet you keep finding and/or delivering more."
#
# The answer was verify_test_wiring.sh itself. It failed only when the unwired
# SET GREW, and its own exit table said so:
#
#     0  every test file is wired, OR IS IN THE RECORDED BACKLOG
#
# So 91 tests sat dark and it printed "OK: no test file is newly unwired" on
# every run, truthfully, for months. Nothing ever forced the number DOWN.
#
# 🔴 THAT PERMITTED BACKLOG COST US A LIVE LAUNCH BLOCKER.
# tests/TEST_WIRING.tsv recorded, at line 364:
#
#     test_walkaway_no_phase2_input_leak.sh    UNWIRED    -
#
# That test guards a BLOCKING gui_read at install.sh:11176, sitting inside the
# phase install.sh declares unattended at :9757. A GUI walk-away install stalls
# on a consent sheet with nobody at the keyboard. The test existed. It was in
# the accepted backlog. Nothing ran it. A human found the stall by hand.
#
# ---------------------------------------------------------------------------
# WHAT THIS TEST GUARDS, AND WHY IT IS SEPARATE FROM THE GATE
# ---------------------------------------------------------------------------
# verify_test_wiring.sh compares the backlog to tests/TEST_WIRING_CEILING and
# refuses when actual > ceiling. That is necessary and NOT sufficient: the
# obvious way to make it green is to raise the ceiling. Then the ratchet is
# gone and the gate is decoration again.
#
# So the ceiling needs a guard the gate CANNOT provide about itself: a
# comparison against the ceiling ON THE BASE BRANCH. That is this file.
#
# ⚠️ A RAISED CEILING IS THE ONLY WAY THIS RATCHET CAN DIE, AND IT WOULD DIE
# SILENTLY -- every other check would stay green. Which is exactly the shape of
# the defect it exists to prevent.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${HERE}/.."
CEILING_FILE="${ROOT}/tests/TEST_WIRING_CEILING"
BASE_REF="${BASE_REF:-origin/main}"

if [ ! -r "$CEILING_FILE" ]; then
    printf 'CANNOT-RUN: tests/TEST_WIRING_CEILING is not readable.\n' >&2
    printf '            An absent ceiling is a REMOVED ratchet, and this test\n' >&2
    printf '            cannot tell "removed" from "never existed". No verdict.\n' >&2
    exit 2
fi

_is_int() { printf '%s' "$1" | /usr/bin/grep -qE '^[0-9]+$'; }

head_val="$(tr -d '[:space:]' < "$CEILING_FILE")"
if ! _is_int "$head_val"; then
    printf 'CANNOT-RUN: ceiling on HEAD is not an integer: %s\n' "${head_val:-<empty>}" >&2
    exit 2
fi

# --- CONTROL FIRST. A comparison whose BASE cannot be read proves nothing. ---
#
# If origin/main is unreachable (shallow clone, fresh runner, detached fetch)
# this must say so rather than treat "cannot read base" as "base was fine".
# That distinction is the whole reason for exit 2 in this estate.
if ! git -C "$ROOT" rev-parse --verify --quiet "${BASE_REF}" >/dev/null 2>&1; then
    printf 'CANNOT-RUN: base ref %s is not present in this checkout.\n' "$BASE_REF" >&2
    printf '            Nothing was compared. A ceiling raise would be INVISIBLE\n' >&2
    printf '            right now, so this is not a pass.\n' >&2
    exit 2
fi

base_raw="$(git -C "$ROOT" show "${BASE_REF}:tests/TEST_WIRING_CEILING" 2>/dev/null || true)"
if [ -z "${base_raw}" ]; then
    # The ceiling is NEW on this branch. That is the introducing commit and it
    # is legitimate -- there is nothing to have raised it from. Say so out loud
    # rather than passing silently, so the one run where this is true is
    # visible in the log and every later run is a real comparison.
    printf 'INTRODUCING COMMIT: %s has no ceiling; HEAD introduces it at %s.\n' \
        "$BASE_REF" "$head_val"
    printf 'PASS (by construction -- nothing to compare against yet).\n'
    exit 0
fi

base_val="$(printf '%s' "$base_raw" | tr -d '[:space:]')"
if ! _is_int "$base_val"; then
    printf 'CANNOT-RUN: ceiling on %s is not an integer: %s\n' "$BASE_REF" "${base_val:-<empty>}" >&2
    exit 2
fi

printf '  base(%s) ceiling = %s\n' "$BASE_REF" "$base_val"
printf '  HEAD        ceiling = %s\n' "$head_val"

if [ "$head_val" -gt "$base_val" ]; then
    printf '\nFAIL: THE UNWIRED CEILING WAS RAISED, %s -> %s.\n' "$base_val" "$head_val" >&2
    printf '      That is not a fix, it is the removal of the ratchet. The\n' >&2
    printf '      ceiling exists so the dark-test backlog can only ever DRAIN.\n' >&2
    printf '      Raising it re-permits exactly the state that left\n' >&2
    printf '      test_walkaway_no_phase2_input_leak.sh unrun while it guarded\n' >&2
    printf '      a live walk-away install stall.\n' >&2
    printf '\n      WIRE THE TEST, OR DELETE IT. Those are the two options.\n' >&2
    exit 1
fi

if [ "$head_val" -lt "$base_val" ]; then
    printf '\nPASS: ceiling LOWERED %s -> %s. %s test(s) left the dark.\n' \
        "$base_val" "$head_val" "$((base_val - head_val))"
    exit 0
fi

printf '\nPASS: ceiling unchanged at %s (never raised).\n' "$head_val"
exit 0
