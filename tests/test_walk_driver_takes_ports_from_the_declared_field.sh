#!/usr/bin/env bash
# The pre-walk port check reads install.sh's DECLARED field, and an empty
# list is CANNOT-RUN -- never a zero-length loop that passes.
#
# THE DEFECT (fix 3 of the three found on promoting the driver into this repo).
# The pre-walk port check took its list from install.sh's own ERROR MESSAGE --
# the text printed when a port is already held. Scraping a failure path has
# two holes and they compound:
#
#   1. it yields a list only when a conflict has ALREADY happened, so on a
#      clean-looking box it yields nothing; and
#   2. when the wording moves, or the message is localised, or the install
#      dies before printing it, the scrape yields an EMPTY list.
#
# An empty list then feeds a `for` loop. The body never executes. Nothing is
# checked. The check reports success. A zero-length loop is the cheapest green
# in the estate and it looks identical to a clean result.
#
# THE FIX. Read the declared assignment
#     OSTLER_PREFLIGHT_PORTS="3000 6333 6379 7878 8044 8144"
# which tests/test_port_preflight_covers_published.sh already holds equal to
# the ports the compose heredocs publish -- so the walk checks what the
# installer will check and the two cannot drift apart in silence. An absent
# field, or one that resolves to no ports, is CANNOT-RUN.
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
trap 'rm -rf "${WORKROOT}"; [ -n "${HOLDER_PID:-}" ] && kill "${HOLDER_PID}" 2>/dev/null' EXIT

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

# make_box <home> <the literal port-declaration line, or empty for none>
make_box() {
    H="$1"; DECL="$2"
    rm -rf "${H}"; mkdir -p "${H}"
    printf '%s\n' "${H}/pty.log"         > "${H}/.walk-log"
    printf '%s\n' "${H}/fake-install.sh" > "${H}/.walk-installsh"
    {
        printf '#!/bin/bash\n'
        [ -n "${DECL}" ] && printf '%s\n' "${DECL}"
        printf 'printf "\\n#OSTLER\\tDONE\\tstatus=ok\\tfailed_steps=0\\n"\n'
        printf 'exit 0\n'
    } > "${H}/fake-install.sh"
    chmod +x "${H}/fake-install.sh"
}

run_box() {  # run_box <driver> <home> -> "rc<TAB>output"
    local D="$1" H="$2" OUT RC
    OUT="$( HOME="${H}" OSTLER_GUI=1 python3 "${D}" 2>&1 )"; RC=$?
    printf '%s\t%s' "${RC}" "$(printf '%s' "${OUT}" | tr '\n' ' ')"
}

check() {  # check <label> <want-rc> <want-substring> <got-rc> <got-out>
    # `grep -c`, never `grep -q`, under the pipefail this file sets: grep -q
    # exits on the first match and SIGPIPEs the producer, so the pipeline can
    # report failure on a needle that IS present -- inverting the verdict of
    # every arm below. grep -c must read to EOF and the COUNT is the test.
    if [ "$4" = "$2" ] && [ "$(printf '%s' "$5" | grep -cF "$3")" -gt 0 ]; then
        pass "$1 (rc=$4)"
    else
        fail "$1" "expected rc=$2 containing '$3'; got rc=$4. Output: $5"
    fi
}

# ---- arm 1: a DECLARED BUT EMPTY list is CANNOT-RUN ---------------------
# The heart of the fix. Nothing to iterate is not the same as nothing wrong.
make_box "${WORKROOT}/empty" 'OSTLER_PREFLIGHT_PORTS=""'
R="$(run_box "${DRIVER}" "${WORKROOT}/empty")"
check "an empty declared port list is CANNOT-RUN, not a silent pass" \
      2 "CANNOT-RUN" "${R%%	*}" "${R#*	}"

# ---- arm 2: an ABSENT field is CANNOT-RUN ------------------------------
# If the assignment is gone the walk has no list at all, and must say so
# rather than infer one from anywhere else.
make_box "${WORKROOT}/absent" ''
R="$(run_box "${DRIVER}" "${WORKROOT}/absent")"
check "an absent OSTLER_PREFLIGHT_PORTS field is CANNOT-RUN" \
      2 "declares no OSTLER_PREFLIGHT_PORTS" "${R%%	*}" "${R#*	}"

# ---- arm 3: POSITIVE CONTROL -- a real list of free ports proceeds ------
# A check that only ever refuses would pass arms 1 and 2 and block every walk.
make_box "${WORKROOT}/ok" "OSTLER_PREFLIGHT_PORTS=\"${FREE_PORTS}\""
R="$(run_box "${DRIVER}" "${WORKROOT}/ok")"
check "a declared list of free ports lets the walk proceed to PASS" \
      0 "PASS" "${R%%	*}" "${R#*	}"

# ---- arm 4: a HELD port is CANNOT-RUN and is NAMED ----------------------
# install.sh's own preflight will refuse to start over a held port, so a walk
# run in that state would measure the refusal and not the product. The port
# number has to appear in the message or the operator cannot act on it.
cat > "${WORKROOT}/holder.py" <<'PY'
import socket, sys, time
s = socket.socket()
# No SO_REUSEADDR: we want a genuinely contended bind, which is what the
# driver's probe has to notice.
s.bind(("127.0.0.1", 0))
s.listen(1)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
time.sleep(120)
PY
# Backgrounded as a plain job. Putting the `&` inside a command substitution
# would background it in a SUBSHELL, and $! in this shell would then be unset
# -- which is exactly how the first draft of this arm failed under `set -u`.
python3 "${WORKROOT}/holder.py" "${WORKROOT}/holder.port" &
HOLDER_PID=$!
# Wait for the holder to publish its port rather than sleeping a guess.
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -s "${WORKROOT}/holder.port" ] && break
    python3 -c 'import time; time.sleep(0.1)'
done
HELD="$(cat "${WORKROOT}/holder.port" 2>/dev/null)"
if [ -z "${HELD}" ]; then
    cannot "no-holder" "could not start a process to hold a port, so the held-port arm measured nothing."
fi
make_box "${WORKROOT}/held" "OSTLER_PREFLIGHT_PORTS=\"${HELD}\""
R="$(run_box "${DRIVER}" "${WORKROOT}/held")"
check "a held declared port is CANNOT-RUN and the port is named" \
      2 "${HELD}" "${R%%	*}" "${R#*	}"
kill "${HOLDER_PID}" 2>/dev/null
HOLDER_PID=""

# ---- arm 5: ANTI-VACUITY -- let the empty list through -----------------
# Neutralise the emptiness refusal and arm 1 must stop holding. Without this,
# arm 1 could be passing because of the arms around it rather than the check
# it names.
MUT="${WORKROOT}/mutated_driver.py"
# Neutralise ONLY the emptiness branch, so an empty list flows on into the
# zero-length loop that is the defect itself. The first draft of this arm
# substituted a fixed port number instead, and the mutant then refused for an
# entirely different reason (port 1 is privileged) -- a mutation that changes
# more than the property under test proves nothing, and this arm caught it.
sed 's/^    if not ports:$/    if False:  # MUTATED: emptiness cannot be observed/' \
    "${DRIVER}" > "${MUT}"
APPLIED="$(grep -c 'MUTATED: emptiness cannot be observed' "${MUT}")"
if [ "${APPLIED}" -ne 1 ]; then
    cannot "mutation-not-applied" \
        "could not neutralise the empty-list refusal in a copy of the driver (applied=${APPLIED}). The anchor has moved; re-point it rather than deleting this arm. NOTHING has been proved."
fi
make_box "${WORKROOT}/mut" 'OSTLER_PREFLIGHT_PORTS=""'
R="$(run_box "${MUT}" "${WORKROOT}/mut")"
if [ "${R%%	*}" != "2" ]; then
    pass "ANTI-VACUITY: without the emptiness check the empty list sails through, so arm 1 is a real check"
else
    fail "mutation-inert" \
        "the mutated driver still returned CANNOT-RUN, so arm 1 may be refusing for a reason other than the empty list. Output: ${R#*	}"
fi

if [ "${FAILED}" -eq 0 ]; then
    echo "OK: 5/5 arms pass -- the port list comes from the declared field and an empty one refuses."
fi
exit "${FAILED}"
