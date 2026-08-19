#!/usr/bin/env bash
# test_upgrade_mode_invariants.sh -- v1.0.12 (B-lite) delivery mechanism.
#
# Fixture harness for install.sh's OSTLER_UPGRADE_MODE / OSTLER_UPGRADE_ROLLBACK
# modes. Design + invariants: HR015/launch/BLITE_DELIVERY_DESIGN_v1.0.12.md.
#
# It builds a FAKE ~/.ostler (fake OstlerAssistant.app, fake doctor/ +
# services/{knowledge,cm048}/, and populated data/ secrets/ license/ wiki/
# ~/Documents/Ostler/ plus the service STATE dirs), a fake payload, mocks
# launchctl + codesign via PATH shims, points install.sh at the fixture via
# HOME, and asserts the data-loss-prevention invariants:
#
#   #12  data/secrets/license/wiki/Documents byte-identical (md5) across upgrade
#        (plus the service state dirs processing/coach/posture/config/assistant-config)
#        daemon swapped; .old kept; ~/.ostler/VERSION written
#        launchd plist EnvironmentVariables preserved generically (token + self-handles)
#        token fallback from secrets seeds a pre-#236 plist that lacked the token
#        fully non-interactive (never hangs on stdin)
#   #5   codesign-verify-fail on .new -> non-zero exit + old daemon NOT moved/destroyed
#        rollback restores .old -> .app, parks broken build as .failed, never touches data
#        n+1: a pre-existing prior .old is cleaned at the start of the next upgrade
#
# No network, no real launchctl/codesign, no pip: hermetic and fast.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${HERE}/../install.sh"
REPO_AGENT="${HERE}/../assistant-agent"
WORK="$(mktemp -d -t ostler-upgrade-harness.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

# ── PATH shims: mock launchctl + codesign ──────────────────────────
SHIMS="${WORK}/shims"
mkdir -p "$SHIMS"
cat > "${SHIMS}/launchctl" <<'SH'
#!/usr/bin/env bash
printf 'launchctl %s\n' "$*" >> "${LAUNCHCTL_LOG:-/dev/null}"
exit 0
SH
cat > "${SHIMS}/codesign" <<'SH'
#!/usr/bin/env bash
printf 'codesign %s\n' "$*" >> "${CODESIGN_LOG:-/dev/null}"
# UPG_CODESIGN_FAIL=1 simulates an unsigned / tampered / wrong-Team daemon.
if [[ "${UPG_CODESIGN_FAIL:-0}" == "1" ]]; then exit 1; fi
exit 0
SH
chmod +x "${SHIMS}/launchctl" "${SHIMS}/codesign"

# ── helpers ────────────────────────────────────────────────────────

# Single md5 over {relative path + content} of the given HOME-relative subdirs.
_digest() {
    local base="$1"; shift
    { for sub in "$@"; do
        if [[ -d "${base}/${sub}" ]]; then
            ( cd "$base" && find "$sub" -type f 2>/dev/null | LC_ALL=C sort \
                | while IFS= read -r f; do printf '%s:' "$f"; md5 -q "$f" 2>/dev/null; done )
        fi
    done ; } | md5 -q
}
PROTECTED=(.ostler/data .ostler/secrets .ostler/license .ostler/wiki "Documents/Ostler" \
           .ostler/processing .ostler/coach .ostler/posture .ostler/config .ostler/assistant-config \
           .ostler/services/knowledge .ostler/services/cm048)

_mk_app() {   # $1 = app path, $2 = marker string baked into the binary
    local app="$1" marker="$2"
    mkdir -p "${app}/Contents/MacOS"
    printf '#!/bin/sh\necho %s\n' "$marker" > "${app}/Contents/MacOS/ostler-assistant"
    chmod 0755 "${app}/Contents/MacOS/ostler-assistant"
    cat > "${app}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>ai.ostler.assistant</string>
<key>CFBundleShortVersionString</key><string>${marker}</string>
</dict></plist>
EOF
}

# Build a fresh fake HOME with a complete prior install. Echoes the HOME path.
build_home() {
    local H; H="$(mktemp -d "${WORK}/home.XXXXXX")"
    local O="${H}/.ostler"
    mkdir -p "${O}/data" "${O}/secrets" "${O}/license" "${O}/wiki" \
             "${O}/logs" "${O}/processing" "${O}/coach" "${O}/posture" \
             "${O}/config" "${O}/assistant-config" \
             "${O}/services/knowledge" "${O}/services/cm048" "${O}/doctor" \
             "${H}/Documents/Ostler" "${H}/Library/LaunchAgents"
    # Irreplaceable customer state (the thing an upgrade must never lose).
    printf 'qdrant-and-oxigraph-bytes\n' > "${O}/data/graph.db"
    printf 'CUSTOMER_TOKEN_abc123\n'      > "${O}/secrets/service_token"
    printf 'signed-licence-json\n'        > "${O}/license/license.json"
    printf 'compiled wiki page\n'         > "${O}/wiki/index.html"
    printf 'conversation transcript\n'    > "${H}/Documents/Ostler/convo.md"
    printf 'in-flight bundle\n'           > "${O}/processing/state.json"
    printf 'coach state\n'                > "${O}/coach/state.json"
    printf 'posture state\n'              > "${O}/posture/install.json"
    printf 'config toml\n'                > "${O}/config/.env"
    printf 'daemon config toml\n'         > "${O}/assistant-config/config.toml"
    printf 'knowledge state marker\n'     > "${O}/services/knowledge/CODE_v1"
    printf 'cm048 state marker\n'         > "${O}/services/cm048/CODE_v1"
    printf 'doctor code v1\n'             > "${O}/doctor/web_ui.py"
    # Installed daemon (marker OLD-DAEMON) + VERSION.
    _mk_app "${O}/OstlerAssistant.app" "OLD-DAEMON"
    printf 'hub-v0.4.40\n' > "${O}/VERSION"
    printf '%s' "$H"
}

# An installed assistant plist carrying customer-specific env (post-#236 shape).
write_installed_plist() {   # $1 = HOME, $2 = include-token (1/0)
    local H="$1" tok="$2"
    local P="${H}/Library/LaunchAgents/com.creativemachines.ostler.assistant.plist"
    local token_block=""
    if [[ "$tok" == "1" ]]; then
        token_block='    <key>PWG_SERVICE_TOKEN</key><string>CUSTOMER_TOKEN_abc123</string>'
    fi
    cat > "$P" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.creativemachines.ostler.assistant</string>
<key>ProgramArguments</key><array>
  <string>${H}/.ostler/OstlerAssistant.app/Contents/MacOS/ostler-assistant</string>
  <string>daemon</string></array>
<key>EnvironmentVariables</key><dict>
    <key>ZEROCLAW_WORKSPACE</key><string>${H}/.ostler/assistant-config</string>
    <key>OSTLER_IMESSAGE_SELF_HANDLES</key><string>+15551230000,me@example.com</string>
${token_block}
    <key>OLLAMA_NUM_CTX</key><string>32768</string>
</dict>
<key>RunAtLoad</key><true/>
</dict></plist>
EOF
}

# Build a fresh payload dir with a NEW daemon (marker NEW-DAEMON), the real
# INSTALL_SNIPPET + launchd templates, a doctor code tree, and VERSION.
build_payload() {
    local P; P="$(mktemp -d "${WORK}/payload.XXXXXX")"
    mkdir -p "${P}/assistant-agent"
    cp "${REPO_AGENT}/INSTALL_SNIPPET.sh" "${P}/assistant-agent/"
    cp -R "${REPO_AGENT}/launchd" "${P}/assistant-agent/"
    _mk_app "${P}/assistant-agent/OstlerAssistant.app" "NEW-DAEMON"
    # doctor code refresh source (no requirements.txt -> cp only, no pip).
    mkdir -p "${P}/doctor/agent"
    printf 'doctor code v2\n'  > "${P}/doctor/agent/web_ui.py"
    printf 'new doctor file\n' > "${P}/doctor/agent/new_module.py"
    printf 'hub-v0.4.41\n' > "${P}/VERSION"
    printf '%s' "$P"
}

# Run install.sh in a given mode. Args: HOME PAYLOAD MODEVAR [extra env assignments...]
# Echoes the numeric exit code; a >60s hang is treated as a hard failure (124).
run_install() {
    local H="$1" P="$2" modevar="$3"; shift 3
    local rc
    # Route the routine's own stdout/stderr to a run log so the command
    # substitution captures ONLY the exit code below (the routine also
    # appends to OSTLER_UPGRADE_LOG_PATH independently).
    env HOME="$H" PATH="${SHIMS}:${PATH}" \
        LAUNCHCTL_LOG="${H}/.launchctl.log" CODESIGN_LOG="${H}/.codesign.log" \
        OSTLER_UPGRADE_PAYLOAD_DIR="$P" \
        OSTLER_UPGRADE_LOG_PATH="${H}/.ostler/logs/upgrade.log" \
        "$modevar=1" "$@" \
        perl -e 'alarm shift; exec @ARGV' 60 bash "$INSTALL_SH" \
        </dev/null >>"${H}/.ostler/logs/run.out" 2>&1
    rc=$?
    printf '%s' "$rc"
}

echo "════════════════════════════════════════════════════════════════"
echo " SCENARIO A -- forward upgrade: data byte-identical, daemon swapped,"
echo "               .old kept, VERSION written, plist env preserved."
echo "════════════════════════════════════════════════════════════════"
HA="$(build_home)"; PA="$(build_payload)"
write_installed_plist "$HA" 1
BEFORE="$(_digest "$HA" "${PROTECTED[@]}")"
RC="$(UPG_CODESIGN_FAIL=0 run_install "$HA" "$PA" OSTLER_UPGRADE_MODE)"
AFTER="$(_digest "$HA" "${PROTECTED[@]}")"

[[ "$RC" == "0" ]] && ok "upgrade exited 0" || bad "upgrade exit code was ${RC} (expected 0)"
[[ "$BEFORE" == "$AFTER" ]] \
    && ok "#12 protected trees byte-identical before/after (md5 ${BEFORE})" \
    || bad "#12 protected trees CHANGED (before ${BEFORE} != after ${AFTER})"
grep -q 'NEW-DAEMON' "${HA}/.ostler/OstlerAssistant.app/Contents/MacOS/ostler-assistant" \
    && ok "daemon swapped: live .app is the NEW daemon" \
    || bad "daemon NOT swapped (live .app is not NEW-DAEMON)"
[[ -d "${HA}/.ostler/OstlerAssistant.app.old" ]] \
    && grep -q 'OLD-DAEMON' "${HA}/.ostler/OstlerAssistant.app.old/Contents/MacOS/ostler-assistant" \
    && ok "rollback anchor kept: .old holds the previous (OLD) daemon" \
    || bad ".old missing or does not hold the previous daemon"
[[ ! -e "${HA}/.ostler/OstlerAssistant.app.new" ]] \
    && ok ".new staging path cleaned up after swap" \
    || bad ".new staging path lingered"
[[ "$(tr -d '[:space:]' < "${HA}/.ostler/VERSION" 2>/dev/null)" == "hub-v0.4.41" ]] \
    && ok "~/.ostler/VERSION written = hub-v0.4.41" \
    || bad "~/.ostler/VERSION wrong (got '$(cat "${HA}/.ostler/VERSION" 2>/dev/null)')"
APLIST="${HA}/Library/LaunchAgents/com.creativemachines.ostler.assistant.plist"
plutil -lint "$APLIST" >/dev/null 2>&1 && ok "rendered assistant plist is valid" || bad "rendered assistant plist invalid"
TOK="$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:PWG_SERVICE_TOKEN' "$APLIST" 2>/dev/null)"
[[ "$TOK" == "CUSTOMER_TOKEN_abc123" ]] \
    && ok "plist env preserved: PWG_SERVICE_TOKEN survived (generic overlay)" \
    || bad "PWG_SERVICE_TOKEN lost/changed (got '${TOK:-<unset>}')"
SH_="$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:OSTLER_IMESSAGE_SELF_HANDLES' "$APLIST" 2>/dev/null)"
[[ "$SH_" == "+15551230000,me@example.com" ]] \
    && ok "plist env preserved: OSTLER_IMESSAGE_SELF_HANDLES survived" \
    || bad "self-handles lost/changed (got '${SH_:-<unset>}')"
grep -q 'doctor code v2' "${HA}/.ostler/doctor/web_ui.py" 2>/dev/null \
    && [[ -f "${HA}/.ostler/doctor/new_module.py" ]] \
    && ok "doctor code refreshed from payload (wholesale replace)" \
    || bad "doctor code not refreshed"

echo ""
echo "════════════════════════════════════════════════════════════════"
echo " SCENARIO B -- token fallback: pre-#236 plist without the token is"
echo "               seeded from ~/.ostler/secrets/service_token."
echo "════════════════════════════════════════════════════════════════"
HB="$(build_home)"; PB="$(build_payload)"
write_installed_plist "$HB" 0   # installed plist has NO PWG_SERVICE_TOKEN
RCB="$(UPG_CODESIGN_FAIL=0 run_install "$HB" "$PB" OSTLER_UPGRADE_MODE)"
[[ "$RCB" == "0" ]] && ok "upgrade exited 0" || bad "upgrade exit code ${RCB}"
BPLIST="${HB}/Library/LaunchAgents/com.creativemachines.ostler.assistant.plist"
BTOK="$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:PWG_SERVICE_TOKEN' "$BPLIST" 2>/dev/null)"
[[ "$BTOK" == "CUSTOMER_TOKEN_abc123" ]] \
    && ok "token gap closed: PWG_SERVICE_TOKEN seeded from secrets/service_token" \
    || bad "token fallback did not seed the plist (got '${BTOK:-<unset>}')"

echo ""
echo "════════════════════════════════════════════════════════════════"
echo " SCENARIO C (#5) -- codesign verify FAILS on .new: non-zero exit,"
echo "                  old daemon NOT moved or destroyed, nothing lost."
echo "════════════════════════════════════════════════════════════════"
HC="$(build_home)"; PC="$(build_payload)"
write_installed_plist "$HC" 1
CBEFORE="$(_digest "$HC" "${PROTECTED[@]}")"
RCC="$(UPG_CODESIGN_FAIL=1 run_install "$HC" "$PC" OSTLER_UPGRADE_MODE)"
CAFTER="$(_digest "$HC" "${PROTECTED[@]}")"
[[ "$RCC" != "0" ]] && ok "upgrade exited non-zero on verify fail (code ${RCC})" || bad "upgrade exited 0 despite verify fail"
[[ "$RCC" == "21" ]] && ok "exit code is 21 (codesign verify failed)" || bad "exit code ${RCC} (expected 21)"
[[ -d "${HC}/.ostler/OstlerAssistant.app" ]] \
    && grep -q 'OLD-DAEMON' "${HC}/.ostler/OstlerAssistant.app/Contents/MacOS/ostler-assistant" \
    && ok "old daemon still in place and intact (OLD-DAEMON)" \
    || bad "old daemon was moved/destroyed on verify fail"
[[ ! -e "${HC}/.ostler/OstlerAssistant.app.old" ]] \
    && ok "no .old created (never swapped)" || bad ".old created despite verify fail"
[[ ! -e "${HC}/.ostler/OstlerAssistant.app.new" ]] \
    && ok ".new cleaned up after verify fail" || bad ".new lingered after verify fail"
[[ ! -f "${HC}/.ostler/VERSION" || "$(tr -d '[:space:]' < "${HC}/.ostler/VERSION")" == "hub-v0.4.40" ]] \
    && ok "VERSION not advanced (still the old version)" || bad "VERSION advanced despite failure"
[[ "$CBEFORE" == "$CAFTER" ]] \
    && ok "protected trees byte-identical after failed upgrade" \
    || bad "protected trees changed on failed upgrade"

echo ""
echo "════════════════════════════════════════════════════════════════"
echo " SCENARIO D -- rollback: restore .old -> .app, park broken build as"
echo "               .failed, never touch data/secrets/services."
echo "════════════════════════════════════════════════════════════════"
HD="$(build_home)"; PD="$(build_payload)"
write_installed_plist "$HD" 1
# Simulate a mid-upgrade state: current .app is the (broken) NEW daemon, and
# the previous good daemon is parked at .old (the swap already happened).
_mk_app "${HD}/.ostler/OstlerAssistant.app.old" "OLD-DAEMON"
rm -rf "${HD}/.ostler/OstlerAssistant.app"
_mk_app "${HD}/.ostler/OstlerAssistant.app" "NEW-BROKEN-DAEMON"
DBEFORE="$(_digest "$HD" "${PROTECTED[@]}")"
RCD="$(UPG_CODESIGN_FAIL=0 run_install "$HD" "$PD" OSTLER_UPGRADE_ROLLBACK)"
DAFTER="$(_digest "$HD" "${PROTECTED[@]}")"
[[ "$RCD" == "0" ]] && ok "rollback exited 0" || bad "rollback exit code ${RCD}"
grep -q 'OLD-DAEMON' "${HD}/.ostler/OstlerAssistant.app/Contents/MacOS/ostler-assistant" 2>/dev/null \
    && ok "previous daemon restored to live .app (OLD-DAEMON)" \
    || bad "rollback did not restore the previous daemon"
[[ -d "${HD}/.ostler/OstlerAssistant.app.failed" ]] \
    && grep -q 'NEW-BROKEN-DAEMON' "${HD}/.ostler/OstlerAssistant.app.failed/Contents/MacOS/ostler-assistant" \
    && ok "broken build parked at .failed" || bad "broken build not parked at .failed"
[[ ! -e "${HD}/.ostler/OstlerAssistant.app.old" ]] \
    && ok ".old consumed by the restore" || bad ".old still present after restore"
[[ "$DBEFORE" == "$DAFTER" ]] \
    && ok "rollback left data/secrets/services byte-identical (Invariant 4)" \
    || bad "rollback touched protected trees"

echo ""
echo "════════════════════════════════════════════════════════════════"
echo " SCENARIO E -- rollback with no .old present -> non-zero (50)."
echo "════════════════════════════════════════════════════════════════"
HE="$(build_home)"; PE="$(build_payload)"
RCE="$(UPG_CODESIGN_FAIL=0 run_install "$HE" "$PE" OSTLER_UPGRADE_ROLLBACK)"
[[ "$RCE" == "50" ]] && ok "rollback with no .old exits 50" || bad "rollback exit ${RCE} (expected 50)"
grep -q 'OLD-DAEMON' "${HE}/.ostler/OstlerAssistant.app/Contents/MacOS/ostler-assistant" \
    && ok "live daemon untouched when there is nothing to roll back to" \
    || bad "live daemon disturbed with no .old to restore"

echo ""
echo "════════════════════════════════════════════════════════════════"
echo " SCENARIO F -- n+1: a stale prior .old is cleaned at the start of"
echo "               the next upgrade; the new .old is THIS run's daemon."
echo "════════════════════════════════════════════════════════════════"
HF="$(build_home)"; PF="$(build_payload)"
write_installed_plist "$HF" 1
_mk_app "${HF}/.ostler/OstlerAssistant.app.old" "STALE-OLD"   # leftover from n-1
RCF="$(UPG_CODESIGN_FAIL=0 run_install "$HF" "$PF" OSTLER_UPGRADE_MODE)"
[[ "$RCF" == "0" ]] && ok "upgrade exited 0" || bad "upgrade exit ${RCF}"
grep -q 'NEW-DAEMON' "${HF}/.ostler/OstlerAssistant.app/Contents/MacOS/ostler-assistant" \
    && ok "live .app is the NEW daemon" || bad "live .app not swapped"
if grep -q 'OLD-DAEMON' "${HF}/.ostler/OstlerAssistant.app.old/Contents/MacOS/ostler-assistant" 2>/dev/null \
   && ! grep -q 'STALE-OLD' "${HF}/.ostler/OstlerAssistant.app.old/Contents/MacOS/ostler-assistant" 2>/dev/null; then
    ok "stale n-1 .old cleaned; new .old is this run's swapped-out daemon"
else
    bad "stale .old not cleaned (n+1 sweep failed)"
fi

echo ""
echo "════════════════════════════════════════════════════════════════"
echo " SCENARIO G -- non-interactive: upgrade completes with stdin closed"
echo "               (proves it never blocks on a prompt / read)."
echo "════════════════════════════════════════════════════════════════"
# Every run above already fed </dev/null through a 60s perl alarm; a blocked
# read would surface as exit 124 (SIGALRM). Re-assert explicitly here.
HG="$(build_home)"; PG="$(build_payload)"
write_installed_plist "$HG" 1
RCG="$(UPG_CODESIGN_FAIL=0 run_install "$HG" "$PG" OSTLER_UPGRADE_MODE)"
[[ "$RCG" != "124" ]] && ok "no stdin hang (did not hit the 60s watchdog)" || bad "install.sh blocked on stdin (watchdog fired)"
[[ "$RCG" == "0" ]] && ok "non-interactive upgrade completed cleanly" || bad "non-interactive upgrade exit ${RCG}"

echo ""
echo "════════════════════════════════════════════════════════════════"
printf ' RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
