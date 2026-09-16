#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_port_preflight_survives_a_held_port.sh
#
# The port preflight must still be running after it finds a conflict.
#
# THE DEFECT (same class as #1756's :12399 and :13022)
# ---------------------------------------------------------------------------
# `_check_port` returns STATUS AS DATA. Its own contract, at its definition:
#
#     0 = free, 1 = held (hard failure), 2 = could not measure.
#
# The preflight called it BARE under `set -Eeuo pipefail`, at top-level
# scope, and read the answer with `case $?` on the next line:
#
#     for _pf_port in ${OSTLER_PREFLIGHT_PORTS}; do
#         _check_port "${_pf_port}" "${_PF_PY}"
#         case $? in
#             1) PORT_CONFLICT=true ;;
#             2) PORT_UNMEASURED=true ;;
#         esac
#     done
#
# Under errexit a bare command returning non-zero ends the script, so on 1
# and 2 -- the only two answers this loop exists to collect -- the installer
# aborted before the `case` ran.
#
# WHY IT IS THE CRUEL DIRECTION. A FREE port returns 0, so the preflight
# passes on every machine where there is nothing to find. It breaks only
# when it finds what it is looking for.
#
# WHAT IT KILLED. The #1208 branch a few lines below, added because
# "continuing past a known collision is what put another account's services
# behind our containers". Unreachable: the customer got a generic errexit
# abort instead of the collision report.
#
# ARM 4 IS THE RED CONTROL AND MUST NOT BE DELETED. Arms 1-3 say "the region
# handles rc 0, 1 and 2". They would say the same if the harness had stopped
# executing the region at all. Arm 4 reintroduces the PRE-FIX line and
# requires it to abort, so a green here means the difference was measured.
#
# Exit 0 all pass / 1 a check failed / 2 could not run.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${HERE}/../install.sh"

[[ -f "$INSTALL_SH" ]] || { echo "CANNOT-RUN: no install.sh at ${INSTALL_SH} (exit 2)" >&2; exit 2; }

_fails=0; _total=0
ok()  { _total=$((_total+1)); printf '  ok    %s\n' "$1"; }
bad() { _total=$((_total+1)); _fails=$((_fails+1)); printf '  FAIL  %s\n' "$1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pfp.XXXXXX")" || { echo "CANNOT-RUN: mktemp failed (exit 2)" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# Take the loop VERBATIM out of install.sh rather than restating it here: a
# copy would drift and this file would then be testing its own fiction.
START="$(grep -n '^for _pf_port in ${OSTLER_PREFLIGHT_PORTS}; do$' "$INSTALL_SH" | head -1 | cut -d: -f1)"
[[ -n "$START" ]] || { echo "CANNOT-RUN: could not find the preflight loop (exit 2)" >&2; exit 2; }
END="$(awk -v s="$START" 'NR>=s && /^done$/ {print NR; exit}' "$INSTALL_SH")"
[[ -n "$END" ]] || { echo "CANNOT-RUN: preflight loop has no closing done (exit 2)" >&2; exit 2; }
sed -n "${START},${END}p" "$INSTALL_SH" > "${WORK}/region"

_n="$(wc -l < "${WORK}/region" | tr -d ' ')"
if [[ "$_n" -ge 5 ]]; then
    ok "0 extracted the real preflight loop, ${_n} lines (install.sh:${START}-${END})"
else
    echo "CANNOT-RUN: extracted only ${_n} lines (exit 2)" >&2; exit 2
fi

drive() { # $1 = stub rc, $2 = region file -> prints "rc|CONFLICT|UNMEASURED"
    {
        printf 'set -Eeuo pipefail\n'
        printf 'OSTLER_PREFLIGHT_PORTS=8044\n_PF_PY=stub\n'
        printf 'PORT_CONFLICT=false\nPORT_UNMEASURED=false\n'
        printf '_check_port() { return %s; }\n' "$1"
        cat "$2"
        printf 'printf "%%s|%%s" "$PORT_CONFLICT" "$PORT_UNMEASURED"\n'
    } > "${WORK}/drive.sh"
    local out rc
    out="$(bash "${WORK}/drive.sh" 2>/dev/null)"; rc=$?
    printf '%s|%s' "$rc" "$out"
}

# 1-3. every documented return value must be COLLECTED, not fatal.
r0="$(drive 0 "${WORK}/region")"
[[ "$r0" == "0|false|false" ]] \
    && ok "1 rc 0 (port free)  -> survives, no flags set" \
    || bad "1 rc 0 gave [${r0}], wanted [0|false|false]"

r1="$(drive 1 "${WORK}/region")"
[[ "$r1" == "0|true|false" ]] \
    && ok "2 rc 1 (port HELD)  -> survives, PORT_CONFLICT set" \
    || bad "2 rc 1 gave [${r1}], wanted [0|true|false] -- the installer aborted"

r2="$(drive 2 "${WORK}/region")"
[[ "$r2" == "0|false|true" ]] \
    && ok "3 rc 2 (unmeasured) -> survives, PORT_UNMEASURED set" \
    || bad "3 rc 2 gave [${r2}], wanted [0|false|true] -- the installer aborted"

# 4. RED CONTROL. Rebuild the PRE-FIX shape and require it to abort. Without
#    this, arms 1-3 read identically to a harness that never ran the region.
{
    printf 'for _pf_port in ${OSTLER_PREFLIGHT_PORTS}; do\n'
    printf '    _check_port "${_pf_port}" "${_PF_PY}"\n'
    printf '    case $? in\n        1) PORT_CONFLICT=true ;;\n'
    printf '        2) PORT_UNMEASURED=true ;;\n    esac\ndone\n'
} > "${WORK}/prefix_region"
rp="$(drive 1 "${WORK}/prefix_region")"
if [[ "$rp" == 0\|* ]]; then
    bad "4 RED CONTROL: the pre-fix shape did NOT abort -- this test cannot fail"
else
    ok "4 RED CONTROL: the pre-fix shape aborts on a held port (rc ${rp%%|*})"
fi

# 5. and the source itself must not carry the bare form back.
if grep -qE '^\s*_check_port "\$\{_pf_port\}" "\$\{_PF_PY\}"$' "$INSTALL_SH"; then
    bad "5 install.sh still calls _check_port bare at the preflight"
else
    ok "5 the preflight call site captures the status instead of tripping errexit"
fi

echo
if [[ $_fails -eq 0 ]]; then echo "PASS: ${_total}/${_total}"; exit 0; fi
echo "FAIL: ${_fails} of ${_total}"; exit 1
