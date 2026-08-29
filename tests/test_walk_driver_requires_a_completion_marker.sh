#!/usr/bin/env bash
# An exit code of zero is not a completion signal.
#
# THE DEFECT (fix 2 of the three found on promoting the driver into this repo).
# The handed-over driver returned 0 unconditionally and recorded install.sh's
# own exit status as the verdict. Neither is evidence that the install
# FINISHED:
#
#   - install.sh can exit 0 without finishing. That is #568: a `set -u` abort
#     under bash 3.2 terminates the script with status 0 having run part of
#     it. Every observable of success is present -- zero exit, no error text,
#     a log that simply stops -- and the walk records PASS.
#   - the driver's own 0 was a literal `return 0` and said nothing at all.
#
# So PASS must require POSITIVE evidence of completion, and its absence must
# be reported as CANNOT-RUN or FAIL with the difference stated.
#
# WHY THE DIFFERENCE IS LOAD-BEARING HERE. Measured on origin/main: the only
# completion marker install.sh has is `#OSTLER<TAB>DONE<TAB>status=...`,
# emitted by gui_done via gui_emit -- and gui_emit's first line returns early
# unless OSTLER_GUI=1. Under a plain TTY walk install.sh's gui_done is the
# no-op stub in its own else-branch. So on a TTY walk the marker CANNOT
# appear even on a flawless install. Reporting that as FAIL would accuse the
# product of the harness's blindness; reporting it as PASS is the original
# defect. It is CANNOT-RUN, and it says so.
#
# rc=2 from this file means the harness could not set itself up.

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

# Two ports the kernel has just told us are free. Asking the kernel beats
# hardcoding: a hardcoded pair that happens to be held on the runner would
# make every arm below report CANNOT-RUN for a reason that has nothing to do
# with what is being tested.
FREE_PORTS="$(python3 - <<'PY'
import socket
out = []
for _ in range(2):
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    out.append(str(s.getsockname()[1]))
    s.close()
print(" ".join(out))
PY
)" || cannot "no-free-ports" "could not obtain two free ports from the kernel."

# make_box <home> <emit-marker: yes|no|fail> <exit-code>
make_box() {
    H="$1"; EMIT="$2"; XC="$3"
    rm -rf "${H}"; mkdir -p "${H}"
    printf '%s\n' "${H}/pty.log"         > "${H}/.walk-log"
    printf '%s\n' "${H}/fake-install.sh" > "${H}/.walk-installsh"
    {
        printf '#!/bin/bash\n'
        # The declared field the driver reads for its port preflight. Present
        # and non-empty so THIS test exercises the marker logic and nothing
        # else -- the port field has its own test.
        printf 'OSTLER_PREFLIGHT_PORTS="%s"\n' "${FREE_PORTS}"
        printf 'echo "pretending to install"\n'
        case "${EMIT}" in
            yes)  printf 'printf "\\n#OSTLER\\tDONE\\tstatus=ok\\tfailed_steps=0\\n"\n' ;;
            fail) printf 'printf "\\n#OSTLER\\tDONE\\tstatus=fail\\tfailed_steps=3\\n"\n' ;;
            no)   : ;;
        esac
        printf 'exit %s\n' "${XC}"
    } > "${H}/fake-install.sh"
    chmod +x "${H}/fake-install.sh"
}

# run_box <driver> <home> <gui:0|1>  -> prints "rc<TAB>output"
run_box() {
    local D="$1" H="$2" GUI="$3" OUT RC
    if [ "${GUI}" = "1" ]; then
        OUT="$( HOME="${H}" OSTLER_GUI=1 python3 "${D}" 2>&1 )"; RC=$?
    else
        OUT="$( HOME="${H}" env -u OSTLER_GUI python3 "${D}" 2>&1 )"; RC=$?
    fi
    printf '%s\t%s' "${RC}" "$(printf '%s' "${OUT}" | tr '\n' ' ')"
}

check() {  # check <label> <want-rc> <want-substring> <got-rc> <got-out>
    if [ "$4" = "$2" ] && printf '%s' "$5" | grep -qF "$3"; then
        pass "$1 (rc=$4)"
    else
        fail "$1" "expected rc=$2 containing '$3'; got rc=$4. Output: $5"
    fi
}

# ---- arm 1: rc=0, no marker, marker channel OFF -> CANNOT-RUN -----------
make_box "${WORKROOT}/a" no 0
R="$(run_box "${DRIVER}" "${WORKROOT}/a" 0)"
check "rc=0 with no marker and the channel OFF is CANNOT-RUN, not PASS" \
      2 "CANNOT-RUN" "${R%%	*}" "${R#*	}"

# ---- arm 2: rc=0, no marker, marker channel ON -> FAIL ------------------
# The #568 shape exactly: the channel that carries completion was open and
# nothing terminal came out of it, yet the script claimed success.
make_box "${WORKROOT}/b" no 0
R="$(run_box "${DRIVER}" "${WORKROOT}/b" 1)"
check "rc=0 with no marker and the channel ON is FAIL" \
      1 "FAIL" "${R%%	*}" "${R#*	}"

# ---- arm 3: POSITIVE CONTROL -- marker present, rc=0 -> PASS ------------
# A driver that only ever refuses would pass arms 1 and 2 and be useless.
make_box "${WORKROOT}/c" yes 0
R="$(run_box "${DRIVER}" "${WORKROOT}/c" 1)"
check "a completed install with its marker and rc=0 is PASS" \
      0 "PASS" "${R%%	*}" "${R#*	}"

# ---- arm 4: the installer's own status=fail is a MEASURED failure -------
make_box "${WORKROOT}/d" fail 1
R="$(run_box "${DRIVER}" "${WORKROOT}/d" 1)"
check "status=fail is reported as FAIL and quotes the status" \
      1 "status=fail" "${R%%	*}" "${R#*	}"

# ---- arm 5: marker present but a non-zero exit is still FAIL ------------
# A marker is not a licence to ignore an exit code; something after the
# marker died.
make_box "${WORKROOT}/e" yes 7
R="$(run_box "${DRIVER}" "${WORKROOT}/e" 1)"
check "marker present with rc!=0 is FAIL, not PASS" \
      1 "FAIL" "${R%%	*}" "${R#*	}"

# ---- arm 6: ANTI-VACUITY -- make the adjudication unconditional --------
# Replace the requirement with "always PASS" and arm 1 must stop holding.
# Without this, arms 1-5 could be passing for reasons unrelated to the fix.
MUT="${WORKROOT}/mutated_driver.py"
sed 's/^def adjudicate(log_path, rc, marker_channel_on):$/def adjudicate(log_path, rc, marker_channel_on):\n    return PASS, "MUTATED unconditional pass", ""/' \
    "${DRIVER}" > "${MUT}"
APPLIED="$(grep -c 'MUTATED unconditional pass' "${MUT}")"
if [ "${APPLIED}" -ne 1 ]; then
    cannot "mutation-not-applied" \
        "could not neutralise adjudicate() in a copy of the driver (applied=${APPLIED}). The anchor has moved; re-point it rather than deleting this arm. NOTHING has been proved."
fi
make_box "${WORKROOT}/f" no 0
R="$(run_box "${MUT}" "${WORKROOT}/f" 0)"
if [ "${R%%	*}" = "0" ]; then
    pass "ANTI-VACUITY: neutralising the marker requirement turns arm 1 into a false PASS, so arm 1 is a real check"
else
    fail "mutation-inert" \
        "the mutated driver did NOT report PASS (rc=${R%%	*}), so arm 1 may be passing for an unrelated reason. Output: ${R#*	}"
fi

if [ "${FAILED}" -eq 0 ]; then
    echo "OK: 6/6 arms pass -- PASS requires positive evidence of completion."
fi
exit "${FAILED}"
