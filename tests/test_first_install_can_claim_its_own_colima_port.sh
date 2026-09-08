#!/usr/bin/env bash
# test_first_install_can_claim_its_own_colima_port.sh
#
# A FIRST INSTALL COULD NOT COMPLETE ON A GENUINELY COLD BOX, and the reason was
# a check that cannot be satisfied by the run it judges.
#
# MEASURED 2026-09-08, first honestly-cold walk of v1.0.76: install.sh starts
# colima at docker_install, colima publishes 6333/7878 through its own ssh mux,
# graph_db_start preflights them, signal 1 PASSES (holder argv names
# ${HOME}/.colima/) and signal 2 fails only because store-curl.conf has not been
# written yet -- by this very install. ERR-06-PORTS-HELD, rc=1, DONE status=fail.
#
# No walk caught it before because no walk had ever been cold: --reset never
# uninstalled (#1828), so colima was always already up with the credential on
# disk and signal 2 passed. The first cold walk found it in ninety seconds.
#
# THE DISTINCTION THIS TEST DEFENDS: absent is not unreadable.
#   absent      -> a first install claiming its own port. Allowed.
#   unreadable  -> the file exists and we cannot open it, which is the
#                  cross-account case #549 keeps open. Still HELD.
# Collapsing those two is how this fix would become a hole.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

[ -r install.sh ] || { echo "CANNOT-RUN: install.sh unreadable. Nothing checked." >&2; exit 3; }

# DENOMINATOR: extract the function, and refuse rather than pass if the shape moved.
fn="$(awk '/^_port_is_our_own_forward\(\) \{/{s=1} s{print} s&&/^    \}$/{exit}' install.sh)"
n="$(printf '%s' "$fn" | grep -c '')"
if [ "${n:-0}" -lt 20 ]; then
    printf 'CANNOT-RUN: extracted %s line(s) of _port_is_our_own_forward, expected >=20. The parse is wrong, so a pass would be meaningless.\n' "$n" >&2
    exit 3
fi
ok "denominator: extracted ${n} lines of _port_is_our_own_forward"

# 1. THE FIX: an ABSENT credential on a signal-1 holder is claimable.
if [ "$(printf '%s' "$fn" | grep -cF 'if [ ! -e "${_conf}" ]; then')" -gt 0 ]; then
    ok "absent credential is a distinct branch (a first install can claim its own port)"
else
    bad "no absent-credential branch: signal 2 is unsatisfiable during the install that writes the credential, so a FIRST install can never pass the port preflight -- the v1.0.76 cold-walk abort"
fi

# 2. THE GUARD: unreadable must STILL be refused. If this line goes, the fix
#    stops being narrow and starts being a cross-account hole (#549).
if [ "$(printf '%s' "$fn" | grep -cF '[ -r "${_conf}" ] || return 1')" -gt 0 ]; then
    ok "an UNREADABLE credential is still HELD (#549 stays closed)"
else
    bad "the unreadable-credential refusal is gone: a 0600 file owned by another account would now be claimed as ours"
fi

# 3. ORDERING: the absent branch must come BEFORE the readable test, or it is
#    dead code -- -r on a missing file is already false.
_a="$(printf '%s' "$fn" | grep -nF 'if [ ! -e "${_conf}" ]; then' | head -1 | cut -d: -f1)"
_r="$(printf '%s' "$fn" | grep -nF '[ -r "${_conf}" ] || return 1' | head -1 | cut -d: -f1)"
if [ -n "$_a" ] && [ -n "$_r" ] && [ "$_a" -lt "$_r" ]; then
    ok "the absent branch precedes the readable test (line ${_a} before ${_r}), so it is reachable"
else
    bad "the absent branch does not precede the readable test (absent=${_a:-none} readable=${_r:-none}); -r already fails on a missing file, so the fix would be dead code"
fi

# 4. SIGNAL 1 IS STILL REQUIRED. The fix must not let a port be claimed without
#    proving the holder is this user's colima.
if [ "$(printf '%s' "$fn" | grep -c 'colima')" -gt 0 ]; then
    ok "signal 1 (holder argv names this user's colima) is still in the function"
else
    bad "signal 1 is gone: a port could be claimed without proving whose forward holds it"
fi

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
