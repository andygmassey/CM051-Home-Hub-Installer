#!/usr/bin/env bash
# tests/test_upgrade_refreshes_assistant_api_and_context_refresh.sh
#
# 118. The Sparkle upgrade path left assistant_api (the ical-server and the live
# /api/v1/preferences/derived route: round-robin, tier filter, tier fallback) and
# context-refresh (CONTEXT.md, the digest) as they were, so an upgraded box kept the
# previous build's route and digest. The REAL functions are lifted out of install.sh
# and run in a sandbox HOME against a fake launchctl, a fake curl and fake installers.
#
#   A  success: the new ical-server.py is in place, people_rules.py removed, pwg_privacy.py
#      refreshed, `kickstart -k` of com.ostler.ical-server sent, the health probe
#      GET /api/v1/preferences/derived?tier=all answered 200 with the service token
#      passed on STDIN (never argv); context-refresh refreshed, its installer run
#      with the tree as OSTLER_INSTALL_ROOT, its label confirmed by launchctl print.
#   B  the new ical-server answers 500: rc non-zero, the previous code is restored
#      (added file removed), the old server is restarted (a second kickstart -k) and
#      answers 200 again.
#   C  the new context-refresh installer fails: rc non-zero, the previous tree is
#      restored and ITS installer is re-run.
#   D  MUTANTS: (1) the probe replaced by `true` makes B wrongly succeed; (2) the
#      restart without -k makes A fail. So A and B measure the probe and the restart.
# Exit: 0 pass, 1 fail, 2 cannot-run.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${INSTALL_SH:-${HERE}/../install.sh}"
[ -r "$INSTALL_SH" ] || { echo "CANNOT-RUN: $INSTALL_SH unreadable"; exit 2; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }
SANDBOX="$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd)/upg-api.XXXXXX")" || { echo "CANNOT-RUN: mktemp"; exit 2; }
trap 'rm -rf "$SANDBOX"' EXIT

if ! grep -q '_upg_refresh_assistant_api() {' "$INSTALL_SH" || ! grep -q '_upg_refresh_context_refresh() {' "$INSTALL_SH"; then
    bad "the upgrade path has NO assistant_api / context-refresh refresh: an upgraded box keeps the previous derived route and digest"
    echo; echo "$PASS passed, $FAIL failed"; exit 1
fi

lift() { # file name indent -> function text
    local f="$1" name="$2" ind="$3" start end t
    start="$(grep -nE "^${ind}${name}\(\) \{" "$f" | head -1 | cut -d: -f1)"
    [ -n "$start" ] || return 1
    t="$(mktemp "${SANDBOX}/lift.XXXXXX")"
    for end in $(awk -v s="$start" -v i="$ind" 'NR > s && $0 ~ "^" i "\\}" { print NR }' "$f"); do
        sed -n "${start},${end}p" "$f" > "$t"
        if bash -n "$t" 2>/dev/null; then cat "$t"; return 0; fi
    done
    return 1
}

# scenario: ok | api500 | ctxfail ; $1 = install.sh to lift from ; $2 = scenario ; $3 = workdir
run_upgrade() {
    local isf="$1" mode="$2" w="$3"
    local home="${w}/home" bin="${w}/bin" payload="${w}/payload" os="${w}/home/.ostler"
    local ical="${os}/services/ical-server" ctx="${os}/context-refresh"
    mkdir -p "$bin" "$payload/services/assistant_api" "$payload/services/context-refresh/bin" \
             "$ical" "$ctx/bin" "$os/secrets" "$os/logs" "$home/Library/LaunchAgents"
    echo "SECRETTOKEN123" > "$os/secrets/service_token"
    # the previous build
    echo "OLD" > "$ical/ical-server.py"; echo "old rules" > "$ical/people_rules.py"
    cat > "$ctx/INSTALL_SNIPPET.sh" <<SNIP
#!/usr/bin/env bash
echo "old-snippet root=\$OSTLER_INSTALL_ROOT" >> "${w}/snippet.log"
exit 0
SNIP
    # the new build
    echo "NEW" > "$payload/services/assistant_api/ical-server.py"
    echo "new rules" > "$payload/services/assistant_api/people_rules.py"
    echo "new route helper" > "$payload/services/assistant_api/derived_preferences.py"
    echo "NEWPRIVACY" > "$payload/services/pwg_privacy.py"
    cat > "$payload/services/context-refresh/INSTALL_SNIPPET.sh" <<SNIP
#!/usr/bin/env bash
echo "new-snippet root=\$OSTLER_INSTALL_ROOT" >> "${w}/snippet.log"
[ "${mode}" = "ctxfail" ] && exit 1
exit 0
SNIP
    chmod +x "$ctx/INSTALL_SNIPPET.sh" "$payload/services/context-refresh/INSTALL_SNIPPET.sh"
    cat > "${bin}/launchctl" <<STUB
#!/bin/sh
echo "\$*" >> "${w}/launchctl.log"
exit 0
STUB
    # the fake health probe: 200 unless the NEW ical-server is installed and the scenario says it is broken
    cat > "${bin}/curl" <<STUB
#!/bin/sh
echo "\$*" >> "${w}/curl.argv"
cat >> "${w}/curl.stdin"
if [ "${mode}" = "api500" ] && [ "\$(cat "${ical}/ical-server.py" 2>/dev/null)" = "NEW" ]; then printf 500; else printf 200; fi
STUB
    chmod +x "${bin}/launchctl" "${bin}/curl"
    {
        for fn in _upg_log _upg_run_bounded _upg_payload_dir _upg_backup_tree _upg_restore_tree \
                  _upg_probe_derived_route _upg_restart_ical _upg_refresh_assistant_api _upg_refresh_context_refresh; do
            lift "$isf" "$fn" "    " || { echo "CANNOT-RUN: cannot lift $fn" >&2; return 2; }
        done
        lift "$isf" _ks_bounded "" || { echo "CANNOT-RUN: cannot lift _ks_bounded" >&2; return 2; }
    } > "${w}/fns.sh" || return 2
    (
        export HOME="$home" PATH="${bin}:${PATH}"
        _UPG_OSTLER_DIR="$os"; _UPG_LOGS_DIR="$os/logs"; _UPG_DOMAIN="gui/$(id -u)"
        _UPG_PAYLOAD="$payload"; _UPG_SECRETS_TOKEN="$os/secrets/service_token"
        OSTLER_UPGRADE_LOG_PATH="${w}/upgrade.log"
        OSTLER_UPGRADE_HEALTH_TRIES=3; OSTLER_UPGRADE_HEALTH_SLEEP=0; OSTLER_UPGRADE_RESTART_SETTLE=0
        . "${w}/fns.sh"
        rc=0
        _upg_refresh_assistant_api || rc=$((rc + 1))
        _upg_refresh_context_refresh || rc=$((rc + 10))
        sleep 0.5   # _ks_bounded backgrounds the kick
        exit $rc
    ) >"${w}/out.txt" 2>&1
    echo $?
}

mkw() { local d="${SANDBOX}/$1"; mkdir -p "$d"; echo "$d"; }

echo "A: success"
WA="$(mkw a)"; RA="$(run_upgrade "$INSTALL_SH" ok "$WA")"; [ "$RA" = "2" ] && exit 2
ICAL="${WA}/home/.ostler/services/ical-server"
[ "$RA" = "0" ] && ok "both refreshes returned 0" || bad "rc=$RA ($(tail -3 "${WA}/out.txt" | tr '\n' '|'); log: $(tail -3 "${WA}/upgrade.log" 2>/dev/null | tr '\n' '|'))"
[ "$(cat "$ICAL/ical-server.py")" = "NEW" ] && [ ! -e "$ICAL/people_rules.py" ] && [ "$(cat "${WA}/home/.ostler/services/pwg_privacy.py" 2>/dev/null)" = "NEWPRIVACY" ] \
    && ok "new ical-server.py in place, people_rules.py removed, pwg_privacy.py refreshed" || bad "assistant_api tree wrong"
grep -qE "^kickstart -k gui/[0-9]+/com\.ostler\.ical-server$" "${WA}/launchctl.log" \
    && ok "kickstart -k com.ostler.ical-server (a plain kickstart of a running job is a no-op)" || bad "no kickstart -k of the ical-server: $(tr '\n' '|' < "${WA}/launchctl.log")"
grep -q "preferences/derived?tier=all" "${WA}/curl.argv" && ! grep -q SECRETTOKEN123 "${WA}/curl.argv" && grep -q "Bearer SECRETTOKEN123" "${WA}/curl.stdin" \
    && ok "health probe GET /api/v1/preferences/derived?tier=all, token on stdin and never in argv" || bad "health probe wrong: argv=$(cat "${WA}/curl.argv" 2>/dev/null)"
grep -q "new-snippet root=${WA}/home/.ostler/context-refresh" "${WA}/snippet.log" \
    && grep -q "print gui/[0-9]*/com.creativemachines.ostler.context-refresh" "${WA}/launchctl.log" \
    && ok "context-refresh: the tree's installer ran and the label was confirmed by launchctl print" || bad "context-refresh not installed/verified"

echo "B: the new ical-server answers 500"
WB="$(mkw b)"; RB="$(run_upgrade "$INSTALL_SH" api500 "$WB")"; [ "$RB" = "2" ] && exit 2
ICB="${WB}/home/.ostler/services/ical-server"
[ "$RB" -ne 0 ] && [ $((RB % 10)) -eq 1 ] && ok "assistant_api refresh returned non-zero" || bad "rc=$RB"
[ "$(cat "$ICB/ical-server.py")" = "OLD" ] && [ "$(cat "$ICB/people_rules.py")" = "old rules" ] && [ ! -e "$ICB/derived_preferences.py" ] \
    && ok "previous code restored exactly (the added file is gone)" || bad "not restored"
[ "$(grep -c '^kickstart -k .*ical-server' "${WB}/launchctl.log")" -ge 2 ] && grep -q "previous ical-server is serving again" "${WB}/upgrade.log" \
    && ok "the old server was restarted and answers 200 again" || bad "no restart of the restored server"
grep -q "ERROR: ical-server did not come back healthy" "${WB}/upgrade.log" && ok "ERROR logged" || bad "no ERROR logged"

echo "C: the new context-refresh installer fails"
WC="$(mkw c)"; RC="$(run_upgrade "$INSTALL_SH" ctxfail "$WC")"; [ "$RC" = "2" ] && exit 2
[ "$RC" -ge 10 ] && ok "context-refresh refresh returned non-zero" || bad "rc=$RC"
[ "$(grep -c 'old-snippet' "${WC}/snippet.log")" -ge 1 ] && ! [ -e "${WC}/home/.ostler/context-refresh/bin/new-only" ] \
    && ok "the previous tree was restored and its installer re-run" || bad "no restore: $(cat "${WC}/snippet.log" | tr '\n' '|')"

echo "D: mutants"
M1="${SANDBOX}/m1.sh"
python3 - "$INSTALL_SH" "$M1" <<'PY'
import sys
s = open(sys.argv[1]).read()
old = 'if [[ "$_rc" -eq 0 ]] && _upg_probe_derived_route; then'
assert s.count(old) == 1
open(sys.argv[2], "w").write(s.replace(old, 'if [[ "$_rc" -eq 0 ]] && true; then'))
PY
[ -s "$M1" ] || { echo "CANNOT-RUN: mutant 1 did not apply"; exit 2; }
WM1="$(mkw m1)"; RM1="$(run_upgrade "$M1" api500 "$WM1")"
[ "$RM1" = "0" ] && ok "mutant 1 (probe skipped): the 500 server is wrongly accepted, so B measures the probe" || bad "mutant 1 still red-flagged (rc=$RM1); B is not measuring the probe"
M2="${SANDBOX}/m2.sh"
python3 - "$INSTALL_SH" "$M2" <<'PY'
import sys
s = open(sys.argv[1]).read()
old = '_ks_bounded "${_UPG_DOMAIN}/com.ostler.ical-server" -k'
assert s.count(old) == 1
open(sys.argv[2], "w").write(s.replace(old, '_ks_bounded "${_UPG_DOMAIN}/com.ostler.ical-server"'))
PY
[ -s "$M2" ] || { echo "CANNOT-RUN: mutant 2 did not apply"; exit 2; }
WM2="$(mkw m2)"; run_upgrade "$M2" ok "$WM2" >/dev/null
grep -qE "^kickstart -k " "${WM2}/launchctl.log" && bad "mutant 2 still sent kickstart -k" || ok "mutant 2 (no -k): A's kickstart -k check would fail"

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
