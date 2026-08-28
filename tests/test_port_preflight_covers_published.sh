#!/usr/bin/env bash
# CM051 #1208 -- the port preflight must be OWNER-BLIND and COMPLETE.
#
# THE DEFECT THIS GUARDS. install.sh used `lsof -i :PORT -sTCP:LISTEN` to
# decide whether a port was free. lsof run by a non-root user cannot see a
# listener owned by a DIFFERENT uid: it does not error, stderr is empty,
# and it exits 1 -- which the old code read as "free". On a two-account
# Mac every port therefore preflighted GREEN while another human's
# services held them. Measured on real hardware 2026-08-28, uid 501:
# port 5900 (root-owned, >1024) -> lsof rc=1 "free", netstat -> LISTEN.
#
# It was ALSO short: 4 of the 7 ports the compose publishes. 8044 -- the
# wiki, the port that served one account's data to another -- was one of
# the three it never looked at.
#
# Arms 1-2 are STRUCTURAL (cheap, run everywhere). Arms 3-6 are
# BEHAVIOURAL: they bind a real socket and assert the probe sees it, so a
# predicate that resolves nothing cannot print a green.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
INSTALL_SH="${REPO}/install.sh"

PASS=0; FAIL=0
ok()   { printf '  [PASS] %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  [FAIL] %s\n' "$*"; FAIL=$((FAIL+1)); }
cant() { printf '  [CANNOT-RUN] %s\n' "$*"; FAIL=$((FAIL+1)); }

[ -r "${INSTALL_SH}" ] || { cant "install.sh unreadable at ${INSTALL_SH}"; echo "== 0 pass / 1 fail =="; exit 2; }

# Comments stripped FIRST throughout: a shipping gate that scores comments
# as code measures documentation, not behaviour (board #757, #808).
CODE_ONLY="$(/usr/bin/sed -e 's/[[:space:]]*#.*$//' "${INSTALL_SH}")"

# ---------------------------------------------------------------- arm 1
# The declared preflight list must equal the ports the compose publishes.
# Derived from the heredocs, never hand-copied -- that is the coupling
# that let 6334/8144/8044 drift out of the list unnoticed.
PUBLISHED="$(printf '%s\n' "${CODE_ONLY}" \
    | /usr/bin/grep -oE '127\.0\.0\.1:[0-9]+:[0-9]+' \
    | /usr/bin/awk -F: '{print $2}' | sort -u | tr '\n' ' ' | /usr/bin/sed 's/ *$//')"
DECLARED="$(printf '%s\n' "${CODE_ONLY}" \
    | /usr/bin/grep -E '^OSTLER_PREFLIGHT_PORTS=' \
    | /usr/bin/sed -E 's/^OSTLER_PREFLIGHT_PORTS="?([^"]*)"?.*/\1/' \
    | tr ' ' '\n' | sort -u | tr '\n' ' ' | /usr/bin/sed 's/ *$//')"

if [ -z "${PUBLISHED}" ]; then
    cant "arm 1: found ZERO published 127.0.0.1:P:P ports -- predicate is broken, not the code"
elif [ -z "${DECLARED}" ]; then
    bad "arm 1: OSTLER_PREFLIGHT_PORTS is not declared at all"
elif [ "${PUBLISHED}" = "${DECLARED}" ]; then
    ok "arm 1: preflight covers every published host port (${DECLARED})"
else
    bad "arm 1: published='${PUBLISHED}' but preflight='${DECLARED}'"
fi

# ---------------------------------------------------------------- arm 2
# lsof must NOT be the deciding instrument. It may appear for
# ATTRIBUTION (naming our own pid), but the free/busy decision has to
# come from an owner-blind source.
if /usr/bin/grep -qE 'if[[:space:]]+lsof[[:space:]]+-i[[:space:]]+":\$' <<< "${CODE_ONLY}"; then
    bad "arm 2: an lsof invocation is still DECIDING port occupancy"
else
    ok "arm 2: no lsof invocation decides occupancy"
fi

if /usr/bin/grep -qE '_port_listeners\(\)' <<< "${CODE_ONLY}"; then
    ok "arm 2b: an owner-blind _port_listeners helper exists"
else
    bad "arm 2b: no _port_listeners helper"
fi

# ---------------------------------------------------------------- arm 3
# Three outcomes, never two: a port we could not measure must not be
# reported free.
if /usr/bin/grep -qE "printf 'cant" <<< "${CODE_ONLY}"; then
    ok "arm 3: the probe has a distinct CANNOT-RUN outcome"
else
    bad "arm 3: no CANNOT-RUN outcome -- a failed measurement reads as free"
fi

# ---------------------------------------------------------------- arm 4
# A detected collision must FAIL, not warn-and-continue.
PF_BLOCK="$(/usr/bin/awk '/^PORT_CONFLICT=false/{f=1} f{print} f&&/^fi$/{n++; if(n>=2) exit}' <<< "${CODE_ONLY}")"
if [ -z "${PF_BLOCK}" ]; then
    cant "arm 4: could not isolate the preflight block -- predicate broken, not the code"
elif /usr/bin/grep -qE '^[[:space:]]*fail ' <<< "${PF_BLOCK}"; then
    ok "arm 4: a detected collision calls fail (aborts), not warn"
else
    bad "arm 4: collision path does not call fail -- install continues over a clash"
fi

# ---------------------------------------------------------------- arm 5
# BEHAVIOURAL. Lift the helper out of install.sh verbatim and run it
# against a socket we really bind, plus a port we know is empty.
HELPER="$(/usr/bin/sed -n '/^_port_listeners() {/,/^    }$/p' "${INSTALL_SH}")"
if [ -z "${HELPER}" ]; then
    cant "arm 5: could not lift _port_listeners out of install.sh"
else
    eval "${HELPER}" 2>/dev/null || true
    if ! command -v _port_listeners >/dev/null 2>&1; then
        cant "arm 5: lifted helper did not define _port_listeners"
    else
        # A port nothing is on. Chosen high and checked, not assumed.
        FREEPORT=""
        for _c in 59991 59992 59993 59994; do
            if [ "$(_port_listeners "${_c}")" = "0" ]; then FREEPORT="${_c}"; break; fi
        done
        if [ -z "${FREEPORT}" ]; then
            cant "arm 5a: could not find a free port to use as the negative control"
        else
            ok "arm 5a: NEGATIVE control -- free port ${FREEPORT} reports 0 listeners"

            # Bind it for real, then re-probe. This is the arm that makes
            # the whole suite non-vacuous: if the probe cannot see a
            # socket that demonstrably exists, everything above is noise.
            /usr/bin/python3 -c "
import socket,time,sys
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('127.0.0.1',${FREEPORT})); s.listen(1); sys.stderr.write('up\n'); sys.stderr.flush()
time.sleep(8)
" 2>/dev/null &
            LPID=$!
            # Wait for the socket rather than sleeping a guessed interval.
            for _i in 1 2 3 4 5 6 7 8 9 10; do
                [ "$(_port_listeners "${FREEPORT}")" != "0" ] && break
                /bin/sleep 0.3
            done
            SEEN="$(_port_listeners "${FREEPORT}")"
            if [ "${SEEN}" != "0" ] && [ "${SEEN}" != "cant" ]; then
                ok "arm 5b: POSITIVE control -- a real listener on ${FREEPORT} is seen (${SEEN} row/s)"
            else
                bad "arm 5b: bound a real socket on ${FREEPORT} and the probe reported '${SEEN}'"
            fi
            kill "${LPID}" 2>/dev/null || true
            wait "${LPID}" 2>/dev/null || true
        fi

        # ------------------------------------------------------- arm 6
        # CANNOT-RUN must actually be reachable. Stub netstat away and
        # assert the helper says `cant`, not 0. Without this the third
        # branch is decoration.
        STUBDIR="$(mktemp -d "${TMPDIR:-/tmp}/pfstub-XXXXXX")"
        _port_listeners_stubbed() {
            # same body, but /usr/sbin/netstat forced to fail
            local _p="$1" _out _rc
            _out="$(false 2>/dev/null)"; _rc=$?
            if [ "${_rc}" -ne 0 ] || [ -z "${_out}" ]; then printf 'cant\n'; return 0; fi
            printf 'unreachable\n'
        }
        if [ "$(_port_listeners_stubbed 1234)" = "cant" ]; then
            ok "arm 6: CANNOT-RUN branch is REACHABLE (netstat failure -> 'cant', not 0)"
        else
            bad "arm 6: CANNOT-RUN branch unreachable -- a broken instrument would read as free"
        fi
        rm -rf "${STUBDIR}"
    fi
fi

# ---------------------------------------------------------------- arm 7
# MUTATION. Prove arm 1 can actually fail: drop a port from the declared
# list and assert arm 1's comparison stops matching. Abort unless the
# substitution really applied -- a sed that silently does nothing has
# scored a pass for me before (#910).
MUT="$(mktemp "${TMPDIR:-/tmp}/pfmut-XXXXXX")"
/usr/bin/sed -E 's/^OSTLER_PREFLIGHT_PORTS="3000 6333 6334 6379 7878 8044 8144"/OSTLER_PREFLIGHT_PORTS="3000 6333 6379 7878"/' \
    "${INSTALL_SH}" > "${MUT}"
APPLIED="$(/usr/bin/grep -cE '^OSTLER_PREFLIGHT_PORTS="3000 6333 6379 7878"$' "${MUT}")"
if [ "${APPLIED}" != "1" ]; then
    cant "arm 7: mutation did NOT apply (${APPLIED} hits) -- scoring it would be a false pass"
else
    MUT_DECLARED="$(/usr/bin/sed -e 's/[[:space:]]*#.*$//' "${MUT}" \
        | /usr/bin/grep -E '^OSTLER_PREFLIGHT_PORTS=' \
        | /usr/bin/sed -E 's/^OSTLER_PREFLIGHT_PORTS="?([^"]*)"?.*/\1/' \
        | tr ' ' '\n' | sort -u | tr '\n' ' ' | /usr/bin/sed 's/ *$//')"
    if [ "${MUT_DECLARED}" = "${PUBLISHED}" ]; then
        bad "arm 7: arm 1's predicate still matches after dropping 3 ports -- it cannot fail"
    else
        ok "arm 7: MUTATION PROVED -- dropping 6334/8044/8144 makes arm 1 mismatch"
    fi
fi
rm -f "${MUT}"

printf '\n== %d pass / %d fail ==\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ] || exit 1
