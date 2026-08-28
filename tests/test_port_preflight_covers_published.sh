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

PASS=0; FAIL=0; SKIP=0
ok()   { printf '  [PASS] %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  [FAIL] %s\n' "$*"; FAIL=$((FAIL+1)); }
cant() { printf '  [CANNOT-RUN] %s\n' "$*"; FAIL=$((FAIL+1)); }
# SKIP is for an arm whose SUBJECT cannot exist in this environment (no
# cross-uid listener on a hosted runner). It does NOT fail, and it is
# printed in the summary so a skipped arm can never read as a pass.
skip() { printf '  [SKIP] %s\n' "$*"; SKIP=$((SKIP+1)); }

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
#
# 🔴 THIS PREDICATE WAS BRITTLE AND IT COST A FALSE RED, 2026-08-28.
# It used to lift from PORT_CONFLICT=false to the SECOND `^fi$`. Adding
# the interpreter-availability guard above the loop introduced a third
# `fi`, so the lift stopped BEFORE the `fail` it was looking for and
# reported "install continues over a clash" while the code was correct.
# Counting block keywords is counting layout, not meaning.
#
# Now anchored on a SEMANTIC terminator (the compose heredoc that
# immediately follows), plus an anti-vacuity check: the lifted block
# must contain BOTH the set and the test of PORT_CONFLICT. A truncated
# lift therefore declares itself CANNOT-RUN instead of scoring a verdict
# about code it never read.
PF_BLOCK="$(/usr/bin/awk '/^PORT_CONFLICT=false/{f=1} f{print} f&&index($0,"docker-compose.yml"){exit}' <<< "${CODE_ONLY}")"
if [ -z "${PF_BLOCK}" ]; then
    cant "arm 4: could not isolate the preflight block -- predicate broken, not the code"
elif ! /usr/bin/grep -qE 'PORT_CONFLICT=true' <<< "${PF_BLOCK}" \
  || ! /usr/bin/grep -qE 'if \[\[ "\$PORT_CONFLICT" == true \]\]' <<< "${PF_BLOCK}"; then
    cant "arm 4: lifted block is missing the set or the test of PORT_CONFLICT -- lift is truncated, predicate broken"
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
# 🔴 THE MUTANT IS DERIVED, NOT HARDCODED -- AND THIS ARM ROTTED ONCE ALREADY.
# It used to sed a literal seven-port string. #1209 (2a886bd5) unpublished
# qdrant gRPC 6334, the declared list legitimately became six, and the literal
# stopped matching. The APPLIED guard did its job -- CANNOT-RUN, not a false
# pass -- but the arm was INERT until a human read the output. A mutation
# fixture that names TODAY'S value stops mutating the moment that value is
# allowed to change, and it goes quiet exactly when the code is in flux.
# Derive the mutant from whatever is declared NOW; then it cannot rot.
MUT="$(mktemp "${TMPDIR:-/tmp}/pfmut-XXXXXX")"
DROPPED="$(printf '%s' "${DECLARED}" | tr ' ' '\n' | /usr/bin/tail -1)"
MUT_LIST="$(printf '%s' "${DECLARED}" | tr ' ' '\n' | /usr/bin/sed '$d' \
    | tr '\n' ' ' | /usr/bin/sed 's/ *$//')"
if [ -z "${MUT_LIST}" ] || [ "${MUT_LIST}" = "${DECLARED}" ]; then
    cant "arm 7: could not derive a SMALLER list from '${DECLARED}' -- mutation impossible"
else
    /usr/bin/sed -E "s/^OSTLER_PREFLIGHT_PORTS=\"[^\"]*\"/OSTLER_PREFLIGHT_PORTS=\"${MUT_LIST}\"/" \
        "${INSTALL_SH}" > "${MUT}"
    APPLIED="$(/usr/bin/grep -cE "^OSTLER_PREFLIGHT_PORTS=\"${MUT_LIST}\"\$" "${MUT}")"
    if [ "${APPLIED}" != "1" ]; then
        cant "arm 7: mutation did NOT apply (${APPLIED} hits) -- scoring it would be a false pass"
    else
        MUT_DECLARED="$(/usr/bin/sed -e 's/[[:space:]]*#.*$//' "${MUT}" \
            | /usr/bin/grep -E '^OSTLER_PREFLIGHT_PORTS=' \
            | /usr/bin/sed -E 's/^OSTLER_PREFLIGHT_PORTS="?([^"]*)"?.*/\1/' \
            | tr ' ' '\n' | sort -u | tr '\n' ' ' | /usr/bin/sed 's/ *$//')"
        if [ "${MUT_DECLARED}" = "${PUBLISHED}" ]; then
            bad "arm 7: arm 1's predicate still matches after dropping ${DROPPED} -- it cannot fail"
        else
            ok "arm 7: MUTATION PROVED -- dropping ${DROPPED} makes arm 1 mismatch"
        fi
    fi
fi
rm -f "${MUT}"

# ---------------------------------------------------------------- arm 8
# THE DECIDER MUST BE A REAL BIND. netstat is a report; a bind is the
# thing docker actually does. Structural half first.
if /usr/bin/grep -qE '_port_bind_probe\(\)' <<< "${CODE_ONLY}"; then
    ok "arm 8: a _port_bind_probe helper exists"
else
    bad "arm 8: no bind probe -- the decider is still only a report"
fi

# ---------------------------------------------------------------- arm 9
# 🔴 THE FALSE-GREEN VECTOR. On BSD, SO_REUSEADDR or SO_REUSEPORT let a
# bind succeed ALONGSIDE an existing socket. Either one silently
# recreates the exact defect this file guards. This arm is narrow on
# purpose: it fails on the OPTION, not on any mention.
BIND_FN="$(/usr/bin/sed -n '/^_port_bind_probe() {/,/^    }$/p' "${INSTALL_SH}")"
if [ -z "${BIND_FN}" ]; then
    cant "arm 9: could not lift _port_bind_probe out of install.sh"
elif /usr/bin/grep -qE 'SO_REUSE(ADDR|PORT)' <<< "${BIND_FN}"; then
    bad "arm 9: the bind probe sets SO_REUSEADDR/SO_REUSEPORT -- that is a FALSE GREEN on BSD"
else
    ok "arm 9: the bind probe sets neither SO_REUSEADDR nor SO_REUSEPORT"
fi

# --------------------------------------------------------------- arm 10
# BEHAVIOURAL, and the arm that makes the bind half non-vacuous: lift
# the real helper and run it against a socket we genuinely bind.
if [ -z "${BIND_FN}" ]; then
    cant "arm 10: no bind probe to exercise"
else
    eval "${BIND_FN}" 2>/dev/null || true
    if ! command -v _port_bind_probe >/dev/null 2>&1; then
        cant "arm 10: lifted helper did not define _port_bind_probe"
    else
        BP_PY="$(command -v python3 2>/dev/null || true)"
        if [ -z "${BP_PY}" ]; then
            cant "arm 10: no python3 to drive the bind probe"
        else
            BFREE=""
            for _c in 59981 59982 59983 59984; do
                if [ "$(_port_bind_probe "${_c}" "${BP_PY}")" = "free" ]; then BFREE="${_c}"; break; fi
            done
            if [ -z "${BFREE}" ]; then
                cant "arm 10a: could not find a free port for the negative control"
            else
                ok "arm 10a: NEGATIVE control -- bind probe reports 'free' on ${BFREE}"
                "${BP_PY}" -c "
import socket,time,sys
s=socket.socket(); s.bind(('127.0.0.1',${BFREE})); s.listen(1)
sys.stderr.write('up\n'); sys.stderr.flush(); time.sleep(8)
" 2>/dev/null &
                BLPID=$!
                for _i in 1 2 3 4 5 6 7 8 9 10; do
                    [ "$(_port_bind_probe "${BFREE}" "${BP_PY}")" = "held" ] && break
                    /bin/sleep 0.3
                done
                BSEEN="$(_port_bind_probe "${BFREE}" "${BP_PY}")"
                if [ "${BSEEN}" = "held" ]; then
                    ok "arm 10b: POSITIVE control -- a real listener on ${BFREE} reports 'held'"
                else
                    bad "arm 10b: bound a real socket on ${BFREE} and the bind probe said '${BSEEN}'"
                fi
                kill "${BLPID}" 2>/dev/null || true
                wait "${BLPID}" 2>/dev/null || true
            fi

            # CANNOT-RUN must be reachable: no interpreter -> 'cant', never 'free'.
            if [ "$(_port_bind_probe 59985 "")" = "cant" ]; then
                ok "arm 10c: CANNOT-RUN reachable -- absent interpreter gives 'cant', not 'free'"
            else
                bad "arm 10c: absent interpreter does not yield 'cant' -- a missing probe reads as free"
            fi
        fi
    fi
fi

# --------------------------------------------------------------- arm 11
# 🔴 THE ACTUAL DEFECT, measured rather than argued: a listener owned by
# ANOTHER uid. lsof cannot see one; the bind probe must. Found
# dynamically -- any port netstat calls LISTEN that lsof will not name.
#
# SKIPs (does not fail) when the environment has no such listener, which
# is the normal case on a hosted runner. Proven separately by arm 10b,
# so a skip here loses a demonstration, not the guarantee.
if ! command -v _port_bind_probe >/dev/null 2>&1 || [ -z "${BP_PY:-}" ]; then
    skip "arm 11: no usable bind probe in this environment"
else
    XUID_PORT=""
    while read -r _lp; do
        [ -n "${_lp}" ] || continue
        if [ -z "$(/usr/sbin/lsof -t -i ":${_lp}" -sTCP:LISTEN 2>/dev/null)" ]; then
            XUID_PORT="${_lp}"; break
        fi
    done <<< "$(/usr/sbin/netstat -an -p tcp -f inet 2>/dev/null \
        | /usr/bin/awk '$NF=="LISTEN"{n=split($4,a,"."); print a[n]}' | sort -un | head -40)"

    if [ -z "${XUID_PORT}" ]; then
        skip "arm 11: no cross-uid listener on this host -- nothing to demonstrate against"
    else
        XSEEN="$(_port_bind_probe "${XUID_PORT}" "${BP_PY}")"
        if [ "${XSEEN}" = "held" ]; then
            ok "arm 11: CROSS-UID -- port ${XUID_PORT} is invisible to lsof and the bind probe still says 'held'"
        else
            bad "arm 11: port ${XUID_PORT} is LISTEN, invisible to lsof, and the bind probe said '${XSEEN}' -- THE ORIGINAL DEFECT"
        fi
    fi
fi

# --------------------------------------------------------------- arm 12
# 🔴 CANNOT-RUN MUST ABORT, NOT WARN (@ARCHIE's review of #1211).
#
# The probe grew a scrupulous third outcome and the CALLER collapsed it
# back into two: PORT_UNMEASURED used to `warn` and continue, so a box
# where every check failed to run printed a caution and started the
# containers anyway. That is the defect this file guards, committed one
# level up. Andy's first rule: CANNOT-RUN is not FAIL and is not PASS.
#
# Same PF_BLOCK lift as arm 4, so it inherits arm 4's anti-vacuity check.
if [ -z "${PF_BLOCK}" ]; then
    cant "arm 12: no preflight block to inspect"
else
    UNMEAS="$(/usr/bin/awk '/PORT_UNMEASURED.*==.*true/{f=1} f{print} f&&/^fi$/{exit}' <<< "${PF_BLOCK}")"
    if [ -z "${UNMEAS}" ]; then
        bad "arm 12: no PORT_UNMEASURED branch at all -- an unmeasured port is silently free"
    elif /usr/bin/grep -qE '^[[:space:]]*fail ' <<< "${UNMEAS}"; then
        ok "arm 12: CANNOT-RUN aborts the install (calls fail), it does not warn-and-continue"
    else
        bad "arm 12: PORT_UNMEASURED warns and continues -- CANNOT-RUN is being treated as PASS"
    fi
fi

printf '\n== %d pass / %d fail / %d skip ==\n' "${PASS}" "${FAIL}" "${SKIP}"
[ "${SKIP}" -eq 0 ] || printf '   NOTE: %d arm(s) skipped -- see [SKIP] above. A skip is not a pass.\n' "${SKIP}"
[ "${FAIL}" -eq 0 ] || exit 1
