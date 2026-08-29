#!/usr/bin/env bash
# CM051 #567 -- the port preflight must recognise OUR OWN colima store forward
# and continue, WITHOUT waving through a foreign one.
#
# THE DEFECT. Lima publishes each container port through its own ssh
# control-master, so a live store port is held by `ssh`. _check_port read
# `ps -o comm=` (bare "ssh"), never saw the colima socket path in the full
# argv, and errored MSG_ERR_PORT_HELD_BY_OUR_PROCESS -- telling the customer to
# quit their own knowledge graph. On a re-run after #566 left colima up, #566
# ("re-run the installer") and #567 ("quit it and run again") trap the customer.
#
# THE FIX. _port_is_our_own_forward requires BOTH signals: (1) the holder's
# FULL argv names $HOME/.colima/, and (2) the port answers 200 to our
# per-install store credential (sound because store auth is enforced by
# default). A named residual leaves 3000/6379/8044/8144 HELD -- no identity
# probe, so ownership is unprovable there.
#
# OBSERVABLE, per the #1250 bar: did _check_port CONTINUE (rc 0) or HOLD
# (rc 1) -- NOT the wording. Arm 2 strips the ownership recognition and the
# arm-1 scenario MUST go RED (HELD), or the test cannot see the fix.
# Arms 3 and 4 are the ones that matter: a fix that turns every occupied port
# into "probably ours" is worse than the bug.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
# Override hook: an anti-vacuity meta-check drives this test against MUTATED
# copies of install.sh to prove each arm fails on a broken fix (see the #567 PR).
INSTALL_SH="${OSTLER_567_TEST_INSTALL_SH:-${REPO}/install.sh}"

PASS=0; FAIL=0; CANT=0
ok()   { printf '  [PASS] %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  [FAIL] %s\n' "$*"; FAIL=$((FAIL+1)); }
# CANNOT-RUN is neither PASS nor FAIL: a check that could not run has not
# passed, but it is not the product failing either (#1239).
cant() { printf '  [CANNOT-RUN] %s\n' "$*"; CANT=$((CANT+1)); }

[ -r "${INSTALL_SH}" ] || { cant "install.sh unreadable at ${INSTALL_SH}"; echo "== 0 pass / 0 fail / 1 cannot-run =="; exit 2; }

# ---- lift the two functions under test. The absolute /usr/sbin/lsof is
#      rewritten to a bare `lsof` so a shell-function stub can shadow it; an
#      absolute path bypasses function lookup and would reach the real binary.
lift_fn() {  # $1 = function name; emits its body from `name() {` to the closing `    }`
    awk -v fn="$1" '
        $0 ~ ("^" fn "\\(\\) \\{") { grab=1 }
        grab { print }
        grab && $0 == "    }" { exit }
    ' "${INSTALL_SH}"
}

OWN_FN="$(lift_fn _port_is_our_own_forward)"
CHK_FN="$(lift_fn _check_port | sed 's#/usr/sbin/lsof#lsof#g')"

# A lift that silently returned nothing would let every arm pass on an empty
# function. Assert both bodies carry their load-bearing tokens before trusting.
# grep -c, never a pipe into a short-circuiting consumer: that SIGPIPEs the
# producer under pipefail and can invert the verdict (the repo's own ratchet).
# grep -c reads to EOF, so no SIGPIPE, and it stays POSIX (no herestring bashism).
if [ "$(printf '%s' "${OWN_FN}" | grep -c 'store-curl.conf')" -eq 0 ] \
   || [ "$(printf '%s' "${CHK_FN}" | grep -c '_port_is_our_own_forward')" -eq 0 ]; then
    cant "arm 0: lift failed -- _port_is_our_own_forward absent, or _check_port does not call it (predicate broken, or the fix is missing)"
    echo "== ${PASS} pass / ${FAIL} fail / $((CANT+1)) cannot-run =="; exit 2
fi
ok "arm 0: both functions lifted and _check_port wires the ownership check"

# ---- rig: a temp OSTLER_DIR with a store-curl.conf, and stubbed leaves ------
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
export OSTLER_DIR="${TMP}/.ostler"; mkdir -p "${OSTLER_DIR}/secrets"
printf 'header = "api-key: testkey"\n' > "${OSTLER_DIR}/secrets/store-curl.conf"
export HOME="${TMP}/home"; mkdir -p "${HOME}/.colima/_lima/colima"
OUR_ARGV="ssh: ${HOME}/.colima/_lima/colima/ssh.sock [mux]"

# controllable stub state (read inside the stubs / subshells)
STUB_ARGV=""      # what `ps -o command=` reports for the holder
STUB_CURL_RC=0    # curl exit: 0 = 200 (ours), 22 = 401 (foreign/unauth)

MSG_WARN_PORT_CHECK_COULD_NOT_RUN="warn %s"
MSG_ERR_PORT_HELD_BY_OUR_PROCESS="held-ours %s %s %s"
MSG_ERR_PORT_HELD_BY_ANOTHER_ACCOUNT="held-other %s"
warn() { :; }
err()  { :; }
dbg()  { :; }
lsof() { printf '4242\n'; }                    # a holder pid always exists here
ps()   { case "$*" in *command=*) printf '%s\n' "${STUB_ARGV}" ;; *comm=*) printf 'ssh\n' ;; esac; }
curl() { return "${STUB_CURL_RC}"; }
_port_bind_probe() { printf 'held\n'; }        # force the HELD path
_port_listeners()  { printf '1\n'; }

eval "${OWN_FN}"
eval "${CHK_FN}"

run_check() {  # $1 = port -> echoes _check_port's rc, isolated in a subshell
    ( _check_port "$1" "/usr/bin/true" >/dev/null 2>&1; echo $? )
}

# ---------------------------------------------------------------- arm 1
# our own store on 6333: our colima argv + our credential 200 -> CONTINUE
STUB_ARGV="${OUR_ARGV}"; STUB_CURL_RC=0
rc="$(run_check 6333)"
[ "${rc}" = "0" ] \
    && ok  "arm 1: our own colima store on 6333 (both signals) -> install CONTINUES" \
    || bad "arm 1: our own store on 6333 did NOT continue (rc=${rc}) -- the #567 dead-end persists"

# ---------------------------------------------------------------- arm 2
# MUTATION: strip the ownership recognition; the arm-1 scenario must go RED.
# Defined only inside the subshell so the real function survives for arms 3-5.
rc="$( _port_is_our_own_forward() { return 1; }; _check_port 6333 /usr/bin/true >/dev/null 2>&1; echo $? )"
[ "${rc}" = "1" ] \
    && ok  "arm 2: MUTATION (ownership check stripped) -> arm-1 scenario HELDs (rc=1); the defect reproduces and the test can see the fix" \
    || bad "arm 2: mutation did not reproduce the defect (rc=${rc}); the test is blind to the fix"

# ---------------------------------------------------------------- arm 3  (matters)
# a genuinely foreign holder: argv is NOT our colima -> HELD, never waved through
STUB_ARGV="ssh -L 6333:localhost:6333 someone@otherhost"; STUB_CURL_RC=0
rc="$(run_check 6333)"
[ "${rc}" = "1" ] \
    && ok  "arm 3: a foreign forward (argv not \$HOME/.colima/) stays HELD" \
    || bad "arm 3: a FOREIGN forward was waved through (rc=${rc}) -- worse than the bug"

# ---------------------------------------------------------------- arm 4  (matters)
# signal 1 only: our colima argv, but the store 401s our credential -> HELD
STUB_ARGV="${OUR_ARGV}"; STUB_CURL_RC=22
rc="$(run_check 6333)"
[ "${rc}" = "1" ] \
    && ok  "arm 4: our colima argv but store 401 (signal 2 absent) -> HELD, never 'ours' (no-auth-store trap closed)" \
    || bad "arm 4: signal 1 alone was accepted (rc=${rc}) -- a keyless/foreign store would pass"

# ---------------------------------------------------------------- arm 5  (residual)
# a port with no credentialed identity probe (6379): both apparent signals, still HELD
STUB_ARGV="${OUR_ARGV}"; STUB_CURL_RC=0
rc="$(run_check 6379)"
[ "${rc}" = "1" ] \
    && ok  "arm 5: 6379 has no identity probe -> HELD (residual pinned; ownership unprovable)" \
    || bad "arm 5: 6379 proceeded (rc=${rc}) -- ownership claimed on a port it cannot prove"

echo "== ${PASS} pass / ${FAIL} fail / ${CANT} cannot-run =="
[ "${FAIL}" -gt 0 ] && exit 1
[ "${CANT}" -gt 0 ] && exit 2
exit 0
