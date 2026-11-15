#!/usr/bin/env bash
# tests/test_upgrade_refreshes_cm019_and_installs_the_derive_agent.sh
#
# 118 BLOCKER. The Sparkle upgrade path (OSTLER_UPGRADE_MODE) refreshed the
# doctor, knowledge and cm048 trees and NOTHING for cm019, and never installed
# com.ostler.derive-preferences. A box that reached 118 by upgrade from 116/117
# therefore never got the derive engine, pyyaml or the agent: no smart-prefs.
#
# The REAL upgrade functions (_upg_refresh_cm019, _upg_install_derive_agent, and
# the hoisted _install_derive_preferences_agent) are lifted out of install.sh and
# run in a sandbox HOME against a fake launchctl and a fake pip, on a 116-SHAPED
# box: a cm019 tree with no derive dir, a venv without pyyaml, no agent, and a
# file of "user data" the upgrade must not touch.
#
#   arm 1  success: derive tree present, `pip install -r requirements.txt` ran in
#          the cm019 venv (pyyaml marker), user data kept, agent plist written,
#          launchctl bootstrap + print + kickstart in that order, rc 0.
#   arm 2  pip FAILS: ERROR is logged, rc non-zero, the previous tree is restored
#          (no derive dir, old file intact, user data intact), NO agent plist and
#          NO launchctl call at all.
#   arm 3  MUTANT: the same install.sh with the pip step deleted fails arm 1, so
#          arm 1 is measuring the pip step.
#   arm 4  order inside _upg_do_upgrade: refresh_cm019 after refresh_cm048, before
#          the VERSION marker.
# Exit: 0 pass, 1 fail, 2 cannot-run.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${INSTALL_SH:-${HERE}/../install.sh}"
[ -r "$INSTALL_SH" ] || { echo "CANNOT-RUN: $INSTALL_SH unreadable"; exit 2; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }
SANDBOX="$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd)/upg-cm019.XXXXXX")" || { echo "CANNOT-RUN: mktemp"; exit 2; }
trap 'rm -rf "$SANDBOX"' EXIT

lift() { # file name indent -> function text
    local f="$1" name="$2" ind="$3" start end
    start="$(grep -nE "^${ind}${name}\(\) \{" "$f" | head -1 | cut -d: -f1)"
    [ -n "$start" ] || return 1
    for end in $(awk -v s="$start" -v i="$ind" 'NR > s && $0 ~ "^" i "\\}" { print NR }' "$f"); do
        sed -n "${start},${end}p" "$f" > "${SANDBOX}/lift.sh"
        if bash -n "${SANDBOX}/lift.sh" 2>/dev/null; then cat "${SANDBOX}/lift.sh"; return 0; fi
    done
    return 1
}

run_upgrade() { # $1 install.sh to lift from, $2 = ok|pipfail, $3 = workdir -> prints rc
    local isf="$1" mode="$2" w="$3"
    local home="${w}/hm" bin="${w}/bin" payload="${w}/payload" cm="${w}/hm/.ostler/services/cm019"
    mkdir -p "$bin" "$payload/services/cm019/services/enrich/src/derive" \
             "$cm/services/enrich/src" "$cm/.venv/bin" "$cm/state" "$home/Library/LaunchAgents" "$home/.ostler/logs"
    # payload (the new build), in the layout gui/Makefile stage-payload really produces
    echo "pyyaml>=6.0" > "$payload/services/cm019/requirements.txt"
    echo "NEW" > "$payload/services/cm019/services/enrich/src/derive/engine.py"
    # the 116-shaped box: old code, a venv with no pyyaml, user data, no agent
    echo "OLD" > "$cm/services/enrich/src/old.py"
    echo "keep me" > "$cm/state/user-data.txt"
    printf '#!/bin/sh\nexit 0\n' > "$cm/.venv/bin/python"
    cat > "$cm/.venv/bin/pip" <<PIP
#!/bin/sh
echo "pip \$*" >> "${w}/pip.log"
[ "${mode}" = "pipfail" ] && exit 1
case "\$*" in *"-r "*) mkdir -p "${cm}/.venv/installed" && touch "${cm}/.venv/installed/pyyaml";; esac
exit 0
PIP
    chmod +x "$cm/.venv/bin/python" "$cm/.venv/bin/pip"
    cat > "${bin}/launchctl" <<STUB
#!/bin/sh
echo "\$*" >> "${w}/launchctl.log"
exit 0
STUB
    chmod +x "${bin}/launchctl"
    {
        for fn in _upg_log:"    " _upg_payload_dir:"    " _upg_resolve_python3:"    " _upg_run_bounded:"    " _upg_refresh_cm019:"    " _upg_install_derive_agent:"    "; do
            lift "$isf" "${fn%%:*}" "${fn#*:}" || { echo "CANNOT-RUN: cannot lift ${fn%%:*}" >&2; return 2; }
        done
        lift "$isf" _install_derive_preferences_agent "" || { echo "CANNOT-RUN: cannot lift the agent installer" >&2; return 2; }
        lift "$isf" _ks_bounded "" || { echo "CANNOT-RUN: cannot lift _ks_bounded" >&2; return 2; }
    } > "${w}/fns.sh" || return 2
    (
        export HOME="$home" PATH="${bin}:${PATH}"
        _UPG_OSTLER_DIR="${home}/.ostler"; _UPG_LOGS_DIR="${_UPG_OSTLER_DIR}/logs"
        _UPG_LA_DIR="${home}/Library/LaunchAgents"; _UPG_DOMAIN="gui/$(id -u)"
        _UPG_PAYLOAD="$payload"; OSTLER_UPGRADE_LOG_PATH="${w}/upgrade.log"
        OSTLER_UPGRADE_PIP_SECONDS=20
        _ostler_wire_store_auth_pth() { return 0; }
        . "${w}/fns.sh"
        _upg_refresh_cm019 || exit 11
        _upg_install_derive_agent || exit 12
        for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q '^kickstart' "${w}/launchctl.log" 2>/dev/null && break; sleep 0.3; done
        exit 0
    ) >"${w}/out.txt" 2>&1
    echo $?
}

if ! grep -q '_upg_refresh_cm019() {' "$INSTALL_SH"; then
    bad "the upgrade path has NO cm019 refresh: a box upgraded by Sparkle never gets the derive engine, pyyaml or the agent"
    grep -q 'OSTLER_UPGRADE_MODE' "$INSTALL_SH" || { echo "CANNOT-RUN: no upgrade block in $INSTALL_SH"; exit 2; }
    echo; echo "$PASS passed, $FAIL failed"; exit 1
fi

echo "arm 1: a 116-shaped box upgrades"
W1="${SANDBOX}/a1"; mkdir -p "$W1"
RC1="$(run_upgrade "$INSTALL_SH" ok "$W1")"
[ "$RC1" = "2" ] && exit 2
CM1="${W1}/hm/.ostler/services/cm019"
[ "$RC1" = "0" ] && ok "refresh + agent install returned 0" || bad "rc=$RC1 (11 = refresh failed, 12 = agent not registered): $(tail -3 "${W1}/out.txt" | tr '\n' '|')"
[ -f "${CM1}/services/enrich/src/derive/engine.py" ] && ok "the derive tree is in place" || bad "no derive tree after the upgrade"
[ -e "${CM1}/.venv/installed/pyyaml" ] && grep -q 'pip install --quiet -r .*requirements.txt' "${W1}/pip.log" \
    && ok "pip install -r requirements.txt ran in the cm019 venv (pyyaml installed)" || bad "requirements were not installed: $(cat "${W1}/pip.log" 2>/dev/null | tr '\n' '|')"
[ "$(cat "${CM1}/state/user-data.txt" 2>/dev/null)" = "keep me" ] && [ -f "${CM1}/services/enrich/src/old.py" ] \
    && ok "user data and existing files untouched (copied over, never deleted)" || bad "existing files were lost"
[ -f "${W1}/hm/Library/LaunchAgents/com.ostler.derive-preferences.plist" ] && ok "the derive agent plist was written" || bad "no derive agent plist"
L1="$(cat "${W1}/launchctl.log" 2>/dev/null)"
B="$(printf '%s\n' "$L1" | grep -n '^bootstrap ' | head -1 | cut -d: -f1)"
P="$(printf '%s\n' "$L1" | grep -n '^print ' | head -1 | cut -d: -f1)"
K="$(printf '%s\n' "$L1" | grep -n '^kickstart ' | head -1 | cut -d: -f1)"
if [ -n "$B" ] && [ -n "$P" ] && [ -n "$K" ] && [ "$B" -lt "$P" ] && [ "$P" -lt "$K" ]; then
    ok "launchctl: bootstrap ($B) < print ($P) < kickstart ($K)"
else bad "launchctl order: bootstrap=$B print=$P kickstart=$K ($(printf '%s' "$L1" | tr '\n' '|'))"; fi

echo "arm 2: pip fails"
W2="${SANDBOX}/a2"; mkdir -p "$W2"
RC2="$(run_upgrade "$INSTALL_SH" pipfail "$W2")"
[ "$RC2" = "2" ] && exit 2
CM2="${W2}/hm/.ostler/services/cm019"
[ "$RC2" = "11" ] && ok "the refresh returned non-zero" || bad "rc=$RC2, wanted 11"
grep -q '^.*ERROR: cm019 pip install' "${W2}/upgrade.log" 2>/dev/null && ok "ERROR logged to the upgrade log" || bad "no ERROR in the upgrade log"
[ ! -e "${CM2}/services/enrich/src/derive/engine.py" ] && [ "$(cat "${CM2}/services/enrich/src/old.py" 2>/dev/null)" = "OLD" ] \
    && [ "$(cat "${CM2}/state/user-data.txt" 2>/dev/null)" = "keep me" ] \
    && ok "the previous tree is restored exactly (new file removed, old and user data intact)" || bad "tree not restored"
[ ! -e "${W2}/hm/Library/LaunchAgents/com.ostler.derive-preferences.plist" ] && [ ! -s "${W2}/launchctl.log" ] \
    && ok "no agent plist and no launchctl call on a failed refresh" || bad "an agent was installed on top of a failed refresh"

echo "arm 3: mutant, the pip step removed"
MUT="${SANDBOX}/install_mut.sh"
python3 - "$INSTALL_SH" "$MUT" <<'PY'
import sys
s = open(sys.argv[1]).read()
old = 'if _upg_run_bounded "${OSTLER_UPGRADE_PIP_SECONDS:-600}" "${_venv}/bin/pip" install --quiet -r "${_dir}/requirements.txt"; then'
assert s.count(old) == 1, "mutation site not found"
open(sys.argv[2], "w").write(s.replace(old, "if true; then"))
PY
[ -s "$MUT" ] || { echo "CANNOT-RUN: the mutant did not apply"; exit 2; }
W3="${SANDBOX}/a3"; mkdir -p "$W3"
RC3="$(run_upgrade "$MUT" ok "$W3")"
CM3="${W3}/hm/.ostler/services/cm019"
if [ "$RC3" = "2" ]; then echo "CANNOT-RUN: the mutant would not lift"; exit 2
elif [ -e "${CM3}/.venv/installed/pyyaml" ]; then bad "the mutant still installed pyyaml; arm 1 is not measuring the pip step"
else ok "without the pip step pyyaml is not installed, so arm 1 would fail"; fi

echo "arm 4: order inside _upg_do_upgrade"
UP="$(awk '/_upg_do_upgrade\(\) \{/,/_upg_do_rollback\(\) \{/' "$INSTALL_SH")"
[ -n "$UP" ] || { echo "CANNOT-RUN: cannot isolate _upg_do_upgrade"; exit 2; }
L48="$(printf '%s\n' "$UP" | grep -n '^        _upg_refresh_cm048$' | head -1 | cut -d: -f1)"
L19="$(printf '%s\n' "$UP" | grep -n '_upg_refresh_cm019' | head -1 | cut -d: -f1)"
LV="$(printf '%s\n' "$UP" | grep -n 'Write VERSION last' | head -1 | cut -d: -f1)"
if [ -n "$L48" ] && [ -n "$L19" ] && [ -n "$LV" ] && [ "$L48" -lt "$L19" ] && [ "$L19" -lt "$LV" ]; then
    ok "cm019 refresh sits after cm048 ($L48) and before VERSION ($LV): line $L19"
else bad "misplaced: cm048=$L48 cm019=$L19 version=$LV"; fi

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
