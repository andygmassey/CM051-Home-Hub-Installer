#!/usr/bin/env bash
# ============================================================================
# test_assistant_fda_is_asked_on_every_mac.sh -- the Ostler assistant's Full
# Disk Access is requested on EVERY install, not only on a Mac that already
# has Messages history (TCC background sweep 2026-10-15).
#
# THE DEFECT, read from source on origin/main f0f2ac2f: the whole daemon-FDA
# block in install.sh sat inside `if [[ -f ~/Library/Messages/chat.db ]]`. On
# a Mac with no Messages history the assistant was never asked for the grant
# that every brokered feed needs (fda-rerun, contacts, email, WhatsApp, voice
# notes, AI chats), and the installer printed "Assistant can read Messages
# history; iMessage channel will work." on the way past.
#
# WHAT THIS RUNS: the probe block exactly as install.sh ships it, in a fake
# HOME, with the install-time helpers stubbed and osascript, open, killall,
# pgrep, pkill, sleep and sudo replaced by recorders on PATH. The real
# lib/write_pipeline_signals.py writes the Doctor's signal. Nothing touches
# this machine's System Settings, TCC or launchd.
#
# EXIT CODES   0 every arm passed   1 an arm failed   2 CANNOT-RUN
#
# --repo-root <dir>  run against another tree (used to show RED on main).
# ============================================================================
set -uo pipefail

REPO_ROOT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-root) REPO_ROOT="${2:-}"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
if [[ -z "$REPO_ROOT" ]]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
INSTALL_SH="${REPO_ROOT}/install.sh"
STRINGS="${REPO_ROOT}/install.sh.strings.en-GB.sh"
WRITER="${REPO_ROOT}/lib/write_pipeline_signals.py"

cannot_run() { echo "CANNOT-RUN: $*" >&2; exit 2; }
for f in "$INSTALL_SH" "$STRINGS" "$WRITER"; do
    [[ -f "$f" ]] || cannot_run "missing ${f}"
done
command -v python3 >/dev/null 2>&1 || cannot_run "no python3 on PATH"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/daemonfda.XXXXXX")" || cannot_run "mktemp failed"
trap 'rm -rf "$WORK"' EXIT

# The block: from the probe's opening line to its closing unset.
awk '
    index($0, "info \"$MSG_INFO_IMESSAGE_FDA_PROBE_BEGIN\"") == 1 { g = 1 }
    g { print }
    g && $0 == "unset _imessage_fda_probe_failure_line" { exit }
' "$INSTALL_SH" > "${WORK}/block.sh"
grep -q '^unset _imessage_fda_probe_failure_line$' "${WORK}/block.sh" \
    || cannot_run "could not extract the daemon FDA probe block from install.sh"

mkdir -p "${WORK}/stubbin"
for c in osascript open killall pgrep pkill sudo; do
    printf '#!/bin/sh\necho "%s $*" >> "$STUB_LOG"\n[ "%s" = pgrep ] && exit 1\nexit 0\n' "$c" "$c" > "${WORK}/stubbin/${c}"
    chmod +x "${WORK}/stubbin/${c}"
done
printf '#!/bin/sh\nexit 0\n' > "${WORK}/stubbin/sleep"; chmod +x "${WORK}/stubbin/sleep"

# run <label> <has_chat_db:0|1> <granted:0|1> <gui:0|1>
run() {
    local label="$1" chat="$2" granted="$3" gui="$4"
    local home="${WORK}/${label}"
    mkdir -p "${home}/Library/Messages" "${home}/.ostler/state" "${home}/app/OstlerAssistant.app"
    [[ "$chat" == 1 ]] && : > "${home}/Library/Messages/chat.db"
    printf '#!/bin/sh\necho "SELF-TEST: DENIED stub"\nexit 1\n' > "${home}/ostler-assistant"
    chmod +x "${home}/ostler-assistant"
    cat > "${WORK}/${label}.driver.sh" <<EOF
set -uo pipefail
source "${STRINGS}"
info()  { printf 'INFO %s\n' "\$*"; }
warn()  { printf 'WARN %s\n' "\$*"; }
ok()    { printf 'OK %s\n' "\$*"; }
gui_log() { :; }
_imessage_daemon_fda_granted() { [ "${granted}" = 1 ] && echo granted; return 0; }
_imessage_daemon_fda_listed() { return 0; }
_ostler_fda_pane_line1() { printf '%s' "\$2"; }
_ostler_fda_entry_name() { echo "OstlerAssistant"; }
_ostler_fda_bundle_locator() { return 1; }
_ostler_fda_path_line() { :; }
_ostler_run_with_deadline() { shift; "\$@"; }
_ostler_start_assistant_daemon() { echo "DAEMON_STARTED"; }
ASSISTANT_BINARY_INSTALLED=true
ASSISTANT_BINARY="${home}/ostler-assistant"
ASSISTANT_APP_BUNDLE="${home}/app/OstlerAssistant.app"
OSTLER_DIR="${home}/.ostler"
SCRIPT_DIR="${REPO_ROOT}"
OSTLER_GUI=${gui}
OSTLER_OSASCRIPT_DIALOG_TIMEOUT_S=5
TAILSCALE_CONFIRM=skip
source "${WORK}/block.sh"
EOF
    HOME="$home" PATH="${WORK}/stubbin:${PATH}" STUB_LOG="${WORK}/${label}.stubs" \
        bash "${WORK}/${label}.driver.sh" > "${WORK}/${label}.out" 2>&1
    echo $?
}
needed() {
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("imessage_chat_db_fda_needed"))' \
        "${WORK}/${1}/.ostler/state/pipeline_signals.json" 2>/dev/null || echo "no-signal"
}

PASS=0
FAIL=0
ok_()  { printf '  [pass] %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

echo "== A. no Messages history, not granted: the grant is still asked for =="
run nohist 0 0 1 >/dev/null
grep -q '^osascript ' "${WORK}/nohist.stubs" 2>/dev/null \
    && ok_ "the Full Disk Access dialog was shown" \
    || bad "no Full Disk Access dialog on a Mac with no Messages history"
grep -q '^open .*-R ' "${WORK}/nohist.stubs" 2>/dev/null || grep -q 'x-apple.systempreferences' "${WORK}/nohist.stubs" 2>/dev/null \
    && ok_ "System Settings or Finder was opened for the grant" \
    || bad "nothing was opened for the grant"
! grep -q "can read Messages history" "${WORK}/nohist.out" \
    && ok_ "no claim that the assistant can read Messages" \
    || bad "printed a 'can read Messages history' claim with no grant"
[[ "$(needed nohist)" == "False" ]] \
    && ok_ "the iMessage card stays off (it can only clear via chat.db)" \
    || bad "imessage_chat_db_fda_needed=$(needed nohist) on a Mac with no chat.db"

echo "== B. Messages history, not granted: asked, and the iMessage card is armed =="
run hist 1 0 1 >/dev/null
grep -q '^osascript ' "${WORK}/hist.stubs" 2>/dev/null && ok_ "the Full Disk Access dialog was shown" \
    || bad "no dialog with Messages history present"
[[ "$(needed hist)" == "True" ]] && ok_ "imessage_chat_db_fda_needed=True" \
    || bad "imessage_chat_db_fda_needed=$(needed hist)"

echo "== C. no Messages history, already granted: no dialog, the daemon starts =="
run granted 0 1 1 >/dev/null
! grep -q '^osascript ' "${WORK}/granted.stubs" 2>/dev/null && ok_ "no dialog when already granted" \
    || bad "a dialog was shown although the grant exists"
grep -q '^DAEMON_STARTED$' "${WORK}/granted.out" && ok_ "the daemon was started with its grant" \
    || bad "the daemon was not started after a confirmed grant"
grep -q "$(. "$STRINGS"; printf '%s' "$MSG_INFO_IMESSAGE_FDA_DAEMON_TCC_GRANTED")" "${WORK}/granted.out" \
    && ok_ "says the assistant already has Full Disk Access" || bad "no granted line"

echo "== D. headless (no GUI), no history, not granted: still told plainly =="
run headless 0 0 0 >/dev/null
grep -q "$(. "$STRINGS"; printf '%s' "$MSG_INFO_IMESSAGE_FDA_PROBE_NEEDS_GRANT")" "${WORK}/headless.out" \
    && ok_ "the needs-grant line is printed" || bad "no needs-grant line on a headless install"

echo "== E. the customer copy says what the grant covers =="
. "$STRINGS"
for w in "Mail," "Calendar," "Reminders," "Contacts"; do
    grep -q "$w" <<<"$MSG_WARN_ASSISTANT_RUNNING_WITHOUT_FDA" && ok_ "the no-grant warning names ${w}" \
        || bad "the no-grant warning does not name ${w}"
done
! grep -q "keep working for everything else" <<<"$MSG_WARN_ASSISTANT_RUNNING_WITHOUT_FDA" \
    && ok_ "the warning no longer says everything else keeps working" \
    || bad "the warning still understates what stops"
! grep -qi "Messages" <<<"$MSG_PROMPT_IMESSAGE_FDA_ASSIST_TITLE" \
    && ok_ "the dialog title is not about Messages only" \
    || bad "the dialog title is still about Messages only: ${MSG_PROMPT_IMESSAGE_FDA_ASSIST_TITLE}"

echo
echo "RESULT: ${PASS} passed, ${FAIL} failed"
[[ "$PASS" -gt 0 ]] || cannot_run "no arm passed, so nothing was measured"
[[ "$FAIL" -eq 0 ]]
