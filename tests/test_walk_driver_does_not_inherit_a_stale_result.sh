#!/usr/bin/env bash
# A walk that dies must not leave the PREVIOUS walk's verdict behind.
#
# THE DEFECT (fix 1 of the three found on promoting the driver into this repo).
# The handed-over driver wrote ~/.walk-rc exactly once, at its last line, and
# never cleared it at the start. So any run that did not reach that line --
# a crash, a kill, a reboot, an operator's ^C -- left the previous run's exit
# code in place, and whoever read the file next got run N-1's answer labelled
# as run N's. The stale value that matters is 0: it reports SUCCESS for a walk
# that never finished, which is the single most expensive thing a walk record
# can say.
#
# WHAT THIS TEST DOES. It plants a stale `0` result, backdates it, and then
# makes the driver die AFTER it starts and BEFORE it can produce a result of
# its own -- by pointing the pty log at a directory that does not exist, which
# is a real failure mode and not a contrived one. The result file must not
# still say 0 afterwards. Absent is the correct answer; absent is honest.
#
# ANTI-VACUITY. A second arm runs a MUTATED copy of the driver with the clear
# removed, and requires the stale value to SURVIVE. Without that arm this test
# would pass just as happily against a driver that never writes a result at
# all, and a test that cannot fail is not evidence.
#
# rc=2 means this harness could not set itself up and NOTHING was measured.
# It is not a pass and it is not a defect in the driver.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRIVER="${OSTLER_WALK_DRIVER:-${REPO_ROOT}/scripts/walk_drive.py}"
FAILED=0

fail() { echo "FAIL [$1]: $2" >&2; FAILED=1; }
pass() { echo "PASS: $1"; }
cannot() { echo "CANNOT-RUN [$1]: $2" >&2; exit 2; }

[ -f "${DRIVER}" ] || cannot "driver-missing" "${DRIVER} not found -- nothing was checked."
command -v python3 >/dev/null 2>&1 || cannot "no-python3" "python3 is not on PATH."

WORKROOT="$(mktemp -d)"
trap 'rm -rf "${WORKROOT}"' EXIT

# One walk box, from scratch, with a stale verdict already sitting in it.
# Returns via globals: H (the fake HOME).
setup_box() {
    H="$1"
    rm -rf "${H}"
    mkdir -p "${H}"
    # A pty log inside a directory that does not exist. The driver gets far
    # enough to have cleared the old result and then cannot continue.
    printf '%s\n' "${H}/no-such-dir/pty.log"  > "${H}/.walk-log"
    printf '%s\n' "${H}/fake-install.sh"      > "${H}/.walk-installsh"
    printf '#!/bin/bash\nexit 0\n'            > "${H}/fake-install.sh"
    chmod +x "${H}/fake-install.sh"
    # The stale verdict from "run N-1", backdated so it is unambiguously older
    # than the run that is about to start.
    printf '0\n' > "${H}/.walk-rc"
    touch -t 202601010000 "${H}/.walk-rc"
}

run_driver() {  # run_driver <driver> <home>
    ( HOME="$2" python3 "$1" >/dev/null 2>&1 )
    echo $?
}

# ---- arm 1: the real driver must not leave the stale verdict -------------
setup_box "${WORKROOT}/real"
RC="$(run_driver "${DRIVER}" "${WORKROOT}/real")"
if [ -f "${WORKROOT}/real/.walk-rc" ]; then
    LEFT="$(cat "${WORKROOT}/real/.walk-rc" 2>/dev/null | tr -d '[:space:]')"
    fail "stale-survived" \
        "the driver died (rc=${RC}) and ~/.walk-rc still reads '${LEFT}'. That is the PREVIOUS run's verdict being handed to the next reader as this run's."
else
    pass "a run that dies leaves NO result rather than the previous one (driver rc=${RC})"
fi

# The run-start stamp is the other half of the fix: without it a reader has
# nothing to adjudicate a result's age against.
if [ -f "${WORKROOT}/real/.walk-run-start" ]; then
    pass "the run stamped its start, so a later result can be dated against it"
else
    fail "no-run-stamp" \
        "~/.walk-run-start was not written, so no reader can tell this run's result from a leftover."
fi

# ---- arm 2: --read-result must REFUSE a result older than the run --------
# Direct proof of the second half: a result file that predates the run start
# is somebody else's result, and handing it back is the whole defect.
STALE_H="${WORKROOT}/stale-read"
rm -rf "${STALE_H}"; mkdir -p "${STALE_H}"
printf '0\n' > "${STALE_H}/.walk-rc"
touch -t 202601010000 "${STALE_H}/.walk-rc"
printf '2026-01-02T00:00:00Z\n' > "${STALE_H}/.walk-run-start"   # run started AFTER
OUT="$( HOME="${STALE_H}" python3 "${DRIVER}" --read-result 2>&1 )"
RC=$?
# `grep -c`, never `grep -q`, because this file sets pipefail: grep -q exits on
# the FIRST match and SIGPIPEs the producer, so the pipeline can report failure
# on a needle that IS present. grep -c must read to EOF, and the count is what
# is tested rather than the pipeline's status. Caught by
# tests/test_pipefail_shortcircuit_inversion.sh on the PR that added this file.
if [ "${RC}" -eq 2 ] && [ "$(printf '%s' "${OUT}" | grep -c 'STALE')" -gt 0 ]; then
    pass "--read-result refuses (rc=2) a result that predates its run"
else
    fail "stale-read-accepted" \
        "expected rc=2 and the word STALE; got rc=${RC}. Output: ${OUT}"
fi

# ---- arm 3: ANTI-VACUITY -- remove the clear, the stale value must survive
# If this arm does NOT reproduce the defect, arm 1 proves nothing: it would
# be passing because the driver never writes a result, not because it clears
# one. A control must be able to fail.
MUT="${WORKROOT}/mutated_driver.py"
sed 's/^            os\.unlink(RESULT)$/            pass  # MUTATED: clear removed/' \
    "${DRIVER}" > "${MUT}"
APPLIED="$(grep -c 'MUTATED: clear removed' "${MUT}")"
if [ "${APPLIED}" -ne 1 ]; then
    cannot "mutation-not-applied" \
        "could not remove the result-clear from a copy of the driver (applied=${APPLIED}). The anchor has moved; re-point it rather than deleting this arm. NOTHING has been proved about the driver."
fi
setup_box "${WORKROOT}/mut"
RC="$(run_driver "${MUT}" "${WORKROOT}/mut")"
if [ -f "${WORKROOT}/mut/.walk-rc" ]; then
    pass "ANTI-VACUITY: without the clear the stale verdict survives, so arm 1 is a real check"
else
    fail "mutation-inert" \
        "the mutated driver ALSO left no stale result (rc=${RC}), so arm 1 could not have detected the defect it claims to detect."
fi

if [ "${FAILED}" -eq 0 ]; then
    echo "OK: 4/4 arms pass -- a dead walk cannot publish the last walk's verdict."
fi
exit "${FAILED}"
