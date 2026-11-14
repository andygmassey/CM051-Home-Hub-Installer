#!/usr/bin/env bash
# TURNING SPOKEN TRANSCRIPTION ON LATER MUST NOT REQUIRE A REINSTALL.
#
# Before this change, a customer who left spoken transcription off got no
# RemoteCapture at all, and the notice told them to "run the installer again"
# to turn it on. The installer now stages the app and a DISABLED LaunchAgent
# plist for every answer. scripts/remotecapture_transcription.sh enable is the
# in-place path: it copies the staged plist into ~/Library/LaunchAgents and
# bootstraps it, but only on an ACCEPTED consent record.
#
# This runs the real script against a sandboxed HOME, a stubbed consent_cli and
# a stubbed launchctl that keeps its own state, and asserts what a customer gets.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${REPO}/scripts/remotecapture_transcription.sh"
INSTALLER="${REPO}/install.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

[ -f "$INSTALLER" ] || { echo "CANNOT-RUN: no install.sh at ${INSTALLER}" >&2; exit 2; }
WORK="$(mktemp -d)" || { echo "CANNOT-RUN: no working directory" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

LABEL="com.creativemachines.ostler-remotecapture"

# ── the installer and the script must agree on where the staged plist lives ──
echo "── the staged path is one path, written by the installer and read by the script ──"
if /usr/bin/grep -q 'REMOTECAPTURE_STAGED_PLIST="${REMOTECAPTURE_APP_SUPPORT_DIR}/${REMOTECAPTURE_LAUNCHAGENT_LABEL}.plist.staged"' "$INSTALLER" \
   && /usr/bin/grep -q 'REMOTECAPTURE_APP_SUPPORT_DIR="${HOME}/Library/Application Support/Ostler RemoteCapture"' "$INSTALLER" \
   && /usr/bin/grep -q 'STAGED="${APP_SUPPORT}/${LABEL}.plist.staged"' "$SCRIPT" 2>/dev/null \
   && /usr/bin/grep -q 'APP_SUPPORT="${HOME_DIR}/Library/Application Support/Ostler RemoteCapture"' "$SCRIPT" 2>/dev/null; then
    ok "installer and script name the same staged plist"
else
    bad "installer and script do not agree on the staged plist path (or the script is missing)"
fi

if [ ! -f "$SCRIPT" ]; then
    bad "scripts/remotecapture_transcription.sh does not exist: there is no in-place path to turn transcription on"
    echo; echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="; exit 1
fi

# ── stubs ───────────────────────────────────────────────────────────────────
mkdir -p "${WORK}/bin"
# consent_cli stub: accepted iff STUB_CONSENT=accepted.
cat > "${WORK}/py" <<'PY'
#!/usr/bin/env bash
[ "${STUB_CONSENT:-}" = accepted ] && exit 0
exit 1
PY
chmod +x "${WORK}/py"
# launchctl stub with state: "loaded" exists once bootstrap has succeeded.
cat > "${WORK}/bin/launchctl" <<'LC'
#!/usr/bin/env bash
echo "$*" >> "${STUB_STATE}/launchctl.log"
case "$1" in
    bootstrap) [ -f "$3" ] && touch "${STUB_STATE}/loaded" && exit 0; exit 5 ;;
    bootout)   rm -f "${STUB_STATE}/loaded"; exit 0 ;;
    print)     [ -f "${STUB_STATE}/loaded" ] && exit 0; exit 113 ;;
esac
exit 0
LC
chmod +x "${WORK}/bin/launchctl"

# ── a fresh box: the installer's effects for a declined answer ──────────────
new_box() {
    local s="${WORK}/box-$1"
    rm -rf "$s"; mkdir -p "$s/fakehome/Library/LaunchAgents" "$s/fakehome/Library/Application Support/Ostler RemoteCapture" "$s/state" "$s/apps/Ostler"
    printf '%s\n' '<plist>staged, inert</plist>' > "$s/fakehome/Library/Application Support/Ostler RemoteCapture/${LABEL}.plist.staged"
    # The installer parks the verified app outside /Applications for a declined answer.
    mkdir -p "$s/fakehome/Library/Application Support/Ostler/staged/Ostler RemoteCapture.app/Contents/MacOS"
    : > "$s/fakehome/Library/Application Support/Ostler/staged/Ostler RemoteCapture.app/Contents/MacOS/RemoteCapture"
    echo "$s"
}
# The sandboxed apps folder stands in for /Applications/Ostler. Never the real one.
app_in()     { [ -d "$1/apps/Ostler/Ostler RemoteCapture.app" ]; }
app_staged() { [ -d "$1/fakehome/Library/Application Support/Ostler/staged/Ostler RemoteCapture.app" ]; }
run_script() {  # $1 box, $2 consent (accepted|none), $3.. action
    local box="$1" consent="$2"; shift 2
    local subject="$SCRIPT"
    if [ -n "${SUBJECT_OVERRIDE:-}" ]; then subject="$SUBJECT_OVERRIDE"; fi
    env -i HOME="$box/fakehome" PATH="${WORK}/bin:/usr/bin:/bin" \
        REMOTECAPTURE_HOME="$box/fakehome" REMOTECAPTURE_LABEL="$LABEL" \
        REMOTECAPTURE_APPS_DIR="$box/apps/Ostler" \
        OSTLER_PYTHON="${WORK}/py" STUB_CONSENT="$consent" STUB_STATE="$box/state" \
        bash "$subject" "$@" 2>&1
}
live_plist() { echo "$1/fakehome/Library/LaunchAgents/${LABEL}.plist"; }

echo "── declined (or never answered): the staged agent is NOT started, and the in-place path refuses ──"
B="$(new_box declined)"
out="$(run_script "$B" none enable)"; rc=$?
if [ "$rc" -eq 3 ]; then ok "enable without an accepted consent record is REFUSED (rc 3)"
else bad "enable without consent returned rc=${rc}: ${out}"; fi
if [ ! -f "$(live_plist "$B")" ] && ! /usr/bin/grep -q bootstrap "$B/state/launchctl.log" 2>/dev/null; then
    ok "refused enable leaves no plist in LaunchAgents and never calls bootstrap"
else
    bad "refused enable still wrote a LaunchAgent or called bootstrap"
fi
if ! app_in "$B" && app_staged "$B"; then
    ok "declined: the app is NOT in /Applications/Ostler; it is parked in staged/ (nothing can double-click it)"
else
    bad "declined: app in apps=$(app_in "$B" && echo yes || echo no) staged=$(app_staged "$B" && echo yes || echo no). A declined app must not sit in /Applications."
fi
out="$(run_script "$B" none status)"
case "$out" in *"app: parked in staged/"*) ok "status reports the app parked while declined" ;;
    *) bad "status does not report the parked app: ${out}" ;; esac

echo "── accepted later: enable turns it on in place, with no reinstall ──"
out="$(run_script "$B" accepted enable)"; rc=$?
if [ "$rc" -eq 0 ] && [ -f "$(live_plist "$B")" ] && [ -f "$B/state/loaded" ]; then
    ok "enable after consent copies the staged plist into LaunchAgents and loads it (rc 0)"
else
    bad "enable after consent did not load the agent (rc=${rc}): ${out}"
fi
if app_in "$B" && ! app_staged "$B"; then
    ok "enable moves the app from staged/ into /Applications/Ostler before the agent starts"
else
    bad "enable did not move the app into place (in=$(app_in "$B" && echo yes || echo no) staged=$(app_staged "$B" && echo yes || echo no))"
fi
if /usr/bin/grep -q "bootstrap gui/$(id -u) $(live_plist "$B")" "$B/state/launchctl.log" 2>/dev/null; then
    ok "it is bootstrapped from LaunchAgents, the path launchd reads"
else
    bad "bootstrap was not called on the LaunchAgents plist"
fi
out="$(run_script "$B" accepted status)"
case "$out" in *"agent: loaded"*) ok "status reports the agent loaded, from the launchctl print the enable relies on" ;;
    *) bad "status does not show the agent loaded after enable: ${out}" ;; esac

echo "── disable stands it down and keeps the staged copy, so enable works again ──"
out="$(run_script "$B" accepted disable)"; rc=$?
if [ "$rc" -eq 0 ] && [ ! -f "$(live_plist "$B")" ] && [ ! -f "$B/state/loaded" ] \
   && [ -f "$B/fakehome/Library/Application Support/Ostler RemoteCapture/${LABEL}.plist.staged" ]; then
    ok "disable boots it out, removes the LaunchAgents plist, keeps the staged copy (rc 0)"
else
    bad "disable left the agent live or deleted the staged copy (rc=${rc}): ${out}"
fi
if ! app_in "$B" && app_staged "$B"; then
    ok "disable parks the app back in staged/, out of /Applications"
else
    bad "disable left the app in /Applications (in=$(app_in "$B" && echo yes || echo no) staged=$(app_staged "$B" && echo yes || echo no))"
fi
out="$(run_script "$B" accepted enable)"; rc=$?
if [ "$rc" -eq 0 ] && [ -f "$B/state/loaded" ] && app_in "$B"; then
    ok "enable again after disable succeeds with no reinstall, app back in /Applications/Ostler"
else
    bad "re-enable after disable failed (rc=${rc}): ${out}"
fi

echo "── nothing staged on this Mac: enable says so and does not pretend ──"
B2="$(new_box nostage)"; rm -f "$B2/fakehome/Library/Application Support/Ostler RemoteCapture/${LABEL}.plist.staged"
out="$(run_script "$B2" accepted enable)"; rc=$?
if [ "$rc" -eq 2 ] && [ ! -f "$(live_plist "$B2")" ]; then
    ok "no staged plist: CANNOT-RUN (rc 2), nothing written"
else
    bad "no staged plist did not report CANNOT-RUN (rc=${rc}): ${out}"
fi
B4="$(new_box noapp)"; rm -rf "$B4/fakehome/Library/Application Support/Ostler"
out="$(run_script "$B4" accepted enable)"; rc=$?
if [ "$rc" -eq 2 ] && [ ! -f "$(live_plist "$B4")" ] && ! app_in "$B4"; then
    ok "no app anywhere: CANNOT-RUN (rc 2), agent not written, nothing faked into /Applications"
else
    bad "no app did not report CANNOT-RUN (rc=${rc}): ${out}"
fi

# ── MUTATION: remove the consent check and the refusal must disappear ───────
echo "── mutation: enable without the consent check ──"
MUT="${WORK}/mutant.sh"
/usr/bin/sed 's/^        if ! consent_accepted; then$/        if false; then/' "$SCRIPT" > "$MUT"
if ! /usr/bin/grep -q 'if false; then' "$MUT"; then
    echo "CANNOT-RUN: the mutation did not apply, so it is not evidence of anything." >&2; exit 2
fi
SUBJECT_OVERRIDE="$MUT"
B3="$(new_box mutant)"
out="$(run_script "$B3" none enable)"; rc=$?
unset SUBJECT_OVERRIDE
if [ "$rc" -ne 3 ]; then
    ok "MUTATION: without the check, an unconsented enable is NOT refused, so the refusal test is measuring the check"
else
    bad "MUTATION: the mutant still refused. The refusal assertion is not measuring the consent check."
fi

# ── MUTATION: enable skips the app move and the placement assertion must fail ─
echo "── mutation: enable without moving the app into /Applications ──"
MUT2="${WORK}/mutant-app.sh"
/usr/bin/sed 's/mkdir -p "\$APPS_DIR" && mv "\$STAGED_APP" "\$APP" ||/true ||/' "$SCRIPT" > "$MUT2"
if ! /usr/bin/grep -q '^            true || {' "$MUT2"; then
    echo "CANNOT-RUN: the app-move mutation did not apply, so it is not evidence of anything." >&2; exit 2
fi
SUBJECT_OVERRIDE="$MUT2"
B5="$(new_box mutantapp)"
out="$(run_script "$B5" accepted enable)"; rc=$?
unset SUBJECT_OVERRIDE
if ! app_in "$B5"; then
    ok "MUTATION: without the move, enable leaves the app parked, so the app-placement assertion is measuring the move"
else
    bad "MUTATION: the mutant still moved the app. The placement assertion is not measuring the move."
fi

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
