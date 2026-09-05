#!/usr/bin/env bash
#
# --wipe-stores MUST BE OPT-IN, SINGLE-USE, AND HONEST ABOUT WHICH IT DID.
#
# A reset has never wiped. install.sh writes exactly ONE uninstaller,
# ~/.ostler/bin/ostler-uninstall, and ttywalk's search list names three paths
# this repo never creates -- left that way on purpose (#1516), because the store
# teardown lives inside that uninstaller and adding the path would have made
# every subsequent walk destroy stores that were under investigation.
#
# The consequence is what blocks the promote: the graph, the vectors and the
# compiled wiki carry over install to install, so three of the five
# artefact-owned probes that refused v1.0.67 read data no walk created.
#
# So the operator gets the choice explicitly. This asserts the choice cannot
# happen by accident, cannot persist past the run that asked for it, and cannot
# be silently skipped.
#
#   1. OFF BY DEFAULT: WIPE_STORES=0 at the top, and only --wipe-stores sets it
#   2. it implies --reset, or the block that does the work never runs
#   3. WITHOUT the flag file the real uninstaller is NOT in the search list
#   4. WITH it the real uninstaller IS in the list AND IS RUN
#   5. SINGLE USE: the flag file is removed on read, so the next walk cannot
#      inherit a decision it did not make
#   6. a run that could not arm the flag DIES rather than producing a record
#      that claims a wipe it did not perform
#   7. the help text says what it destroys
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run (anchors moved; nothing measured).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT}/scripts/ttywalk.sh"
[ -f "$SRC" ] || { printf 'CANNOT-RUN: no ttywalk.sh at %s\n' "$SRC" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok    %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$*" >&2; }
cannot() { printf '\nCANNOT-RUN: %s\n' "$1" >&2
           printf '  Nothing was measured. Re-point the anchors; do not delete the arms.\n' >&2
           exit 2; }

WORK="$(mktemp -d)" || cannot "no working directory"
trap 'rm -rf "$WORK"' EXIT

# --- 1 and 2: the flag itself -----------------------------------------------
if [ "$(grep -c '^WIPE_STORES=0$' "$SRC")" -eq 1 ]; then
    ok "WIPE_STORES defaults to 0"
else
    bad "WIPE_STORES does not default to 0 exactly once; a wipe could happen without being asked for"
fi
if [ "$(grep -c -- '--wipe-stores)  WIPE_STORES=1; DO_RESET=1; shift ;;' "$SRC")" -eq 1 ]; then
    ok "--wipe-stores sets the flag AND implies --reset (without --reset the block never runs)"
else
    bad "--wipe-stores does not set both WIPE_STORES and DO_RESET; the flag would be accepted and do nothing"
fi

# --- 6: a run that cannot arm the flag must die -----------------------------
if [ "$(grep -c 'could not arm --wipe-stores' "$SRC")" -eq 1 ]; then
    ok "a run that cannot arm the flag DIES rather than walking on and recording a wipe it did not do"
else
    bad "arming the flag has no failure branch; a failed write would produce a record claiming wiped-by-shipped-uninstaller"
fi

# --- 7: the help text names the volumes -------------------------------------
HELP="$(sed -n '2,60p' "$SRC")"
missing=""
for v in qdrant_data oxigraph_data redis_data wiki-docs vane_data; do
    case "$HELP" in *"$v"*) ;; *) missing="${missing} ${v}" ;; esac
done
if [ -z "$missing" ]; then
    ok "the help text names every volume --wipe-stores destroys"
else
    bad "the help text does not name:${missing}. A destructive flag must say what it destroys."
fi

# --- drive the REAL block ---------------------------------------------------
awk '/^        _ran_uninstaller=""$/,/^        fi$/' "$SRC" > "${WORK}/blk"
n="$(wc -l < "${WORK}/blk" | tr -d ' ')"
[ "$n" -ge 10 ] && [ "$n" -le 80 ] || cannot "extracted ${n} lines for the reset block; the anchors moved"
ok "the reset block extracts to a sane size (${n} lines)"

# CONTROL FIRST: the block must be able to RUN at all. A block that dies on line
# one would satisfy every "did not wipe" assertion below for the wrong reason.
mkdir -p "${WORK}/h"
if HOME="${WORK}/h" bash "${WORK}/blk" >"${WORK}/ctl" 2>&1; then
    ok "CONTROL: the extracted block runs to completion with an empty HOME"
else
    cannot "the extracted block exited non-zero on an empty HOME; every arm below would be measuring that instead"
fi

run_block() {  # run_block <arm-name>  -> stdout in ${WORK}/out.<arm>
    HOME="${WORK}/h" bash "${WORK}/blk" > "${WORK}/out.$1" 2>&1 || true
}

# A stand-in for the real uninstaller. It must be found ONLY when armed.
mkdir -p "${WORK}/h/.ostler/bin"
printf '#!/bin/sh\necho STORE-TEARDOWN-RAN\n' > "${WORK}/h/.ostler/bin/ostler-uninstall"
chmod +x "${WORK}/h/.ostler/bin/ostler-uninstall"

# --- 3: unarmed ---------------------------------------------------------------
rm -f "${WORK}/h/.walk-wipe-stores"
run_block unarmed
if grep -q 'STORE-TEARDOWN-RAN' "${WORK}/out.unarmed"; then
    bad "the real uninstaller RAN without --wipe-stores. A plain --reset would destroy the stores."
else
    ok "unarmed: the real uninstaller is not in the search list and did not run"
fi
if grep -q 'NO SHIPPED UNINSTALLER FOUND' "${WORK}/out.unarmed"; then
    ok "unarmed: the run still says it did NOT uninstall"
else
    bad "unarmed: the announcement did not fire, so a non-wipe would read as a wipe"
fi

# --- 4 and 5: armed -----------------------------------------------------------
printf '%s' 1 > "${WORK}/h/.walk-wipe-stores"
run_block armed
if grep -q 'STORE-TEARDOWN-RAN' "${WORK}/out.armed"; then
    ok "armed: the uninstaller install.sh actually writes IS run"
else
    bad "armed: --wipe-stores did not reach the real uninstaller, so the flag does nothing"
fi
if grep -q 'NO SHIPPED UNINSTALLER FOUND' "${WORK}/out.armed"; then
    bad "armed: the run claims it did not uninstall while it did. The record would say carried-over after a wipe."
else
    ok "armed: the did-not-uninstall announcement correctly does NOT fire"
fi
if [ -f "${WORK}/h/.walk-wipe-stores" ]; then
    bad "the flag file SURVIVED the run. The next walk would wipe without being asked."
else
    ok "SINGLE USE: the flag file is removed on read"
fi

# --- 5 again, by execution: a second run must not wipe ------------------------
run_block second
if grep -q 'STORE-TEARDOWN-RAN' "${WORK}/out.second"; then
    bad "a SECOND run wiped again with no flag. Single-use is not enforced by execution."
else
    ok "a second run with no flag does not wipe -- single use proven by running it twice, not by reading the rm"
fi

printf '\n== %s pass / %s fail / %s total ==\n' "$PASS" "$FAIL" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
