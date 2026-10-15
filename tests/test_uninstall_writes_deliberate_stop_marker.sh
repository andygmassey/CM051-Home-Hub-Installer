#!/usr/bin/env bash
# The assistant LaunchAgent is KeepAlive PathState on ~/.ostler/deliberate-stop
# (job alive while the marker is ABSENT). So the uninstaller must:
#   A. write the marker FIRST, before any bootout, docker teardown or removal;
#   B. remove it again at the very end, so a reinstall starts clean;
#   C. (real launchd, throwaway label) marker present => a killed job is NOT
#      respawned, marker absent => it IS. This is the property A relies on.
# Synthetic only. Touches only a throwaway label under the sandbox.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${HERE}/../install.sh"
[[ -f "$INSTALL_SH" ]] || { echo "CANNOT-RUN: no install.sh (exit 2)" >&2; exit 2; }
_fails=0
ok()  { printf '  ok    %s\n' "$1"; }
bad() { _fails=$((_fails+1)); printf '  FAIL  %s\n' "$1"; }

U0="$(grep -n "^cat > \"\${OSTLER_DIR}/bin/ostler-uninstall\" <<'UNINSTALLEOF'" "$INSTALL_SH" | head -1 | cut -d: -f1)"
U1="$(awk -v s="${U0:-0}" 'NR>s && /^UNINSTALLEOF$/{print NR; exit}' "$INSTALL_SH")"
[[ -n "$U0" && -n "$U1" ]] || { echo "CANNOT-RUN: uninstaller heredoc not found (exit 2)" >&2; exit 2; }
BODY="$(sed -n "${U0},${U1}p" "$INSTALL_SH")"

echo "axis A: marker written before anything is stopped or removed"
_w="$(sed -E 's/^[[:space:]]*#.*//' <<<"$BODY" | grep -nE ': > "\$\{HOME\}/\.ostler/deliberate-stop' | head -1 | cut -d: -f1)"
_b="$(sed -E 's/^[[:space:]]*#.*//' <<<"$BODY" | grep -nE '^[[:space:]]*(launchctl bootout|rm -rf|.*_OSTLER_DOCKER" compose down|find .*-exec rm)' | head -1 | cut -d: -f1)"
if [[ -z "$_w" ]]; then bad "1 uninstaller never writes the marker"
elif [[ -z "$_b" ]]; then echo "CANNOT-RUN: no bootout/rm found in uninstaller (exit 2)" >&2; exit 2
elif [[ "$_w" -lt "$_b" ]]; then ok "1 marker written at +${_w}, first teardown action at +${_b}"
else bad "1 marker written at +${_w}, AFTER first teardown action at +${_b}"; fi

echo "axis B: marker gone after the uninstall tail"
SB="$(mktemp -d "${TMPDIR:-/tmp}/dsm.XXXXXX")" || exit 2
SB="$(cd "$SB" && pwd -P)"  # launchd path-watches need the real path, not /var -> /private/var
LABEL="ai.ostler.test.dsm.$$"
cleanup() { launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true; rm -rf "$SB"; }
trap cleanup EXIT
mkdir -p "$SB/home/.ostler/bin"; : > "$SB/home/.ostler/deliberate-stop"; : > "$SB/home/.ostler/power.conf"
TAIL="$(awk '/^if \[\[ -d "\$\{HOME\}\/\.ostler" \]\]; then$/{f=1} f{print} f&&/rm -f "\$\{HOME\}\/\.ostler\/deliberate-stop"/{exit}' <<<"$BODY")"
if grep -q 'rm -f "${HOME}/.ostler/deliberate-stop"' <<<"$TAIL"; then
    HOME="$SB/home" bash -c "$TAIL"
    [[ ! -e "$SB/home/.ostler/deliberate-stop" ]] && ok "2 marker removed" || bad "2 marker survived the uninstall tail"
    [[ -e "$SB/home/.ostler/power.conf" ]] && ok "3 power.conf still kept (control: tail ran)" || bad "3 power.conf lost"
else
    bad "2 uninstaller tail never removes the marker"
fi

echo "axis C: real launchd, marker present => no respawn"
command -v launchctl >/dev/null || { echo "CANNOT-RUN: no launchctl (exit 2)" >&2; exit 2; }
M="$SB/marker"
cat > "$SB/job.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>${LABEL}</string>
<key>ProgramArguments</key><array><string>/bin/sh</string><string>-c</string><string>echo \$\$ >> ${SB}/pids; exec sleep 600</string></array>
<key>RunAtLoad</key><true/>
<key>ThrottleInterval</key><integer>1</integer>
<key>KeepAlive</key><dict><key>PathState</key><dict><key>${M}</key><false/></dict></dict>
</dict></plist>
P
plutil -lint "$SB/job.plist" >/dev/null || { echo "CANNOT-RUN: test plist invalid (exit 2)" >&2; exit 2; }
launchctl bootstrap "gui/$(id -u)" "$SB/job.plist" 2>/dev/null || { echo "CANNOT-RUN: launchctl bootstrap refused (exit 2)" >&2; exit 2; }
waitn() { local i; for i in $(seq 1 40); do [[ -f "$SB/pids" && "$(wc -l < "$SB/pids")" -ge "$1" ]] && return 0; sleep 0.25; done; return 1; }
waitn 1 || { echo "CANNOT-RUN: throwaway job never started (exit 2)" >&2; exit 2; }
pkill -TERM -P 1 -f "sleep 600" 2>/dev/null; kill -TERM "$(tail -1 "$SB/pids")" 2>/dev/null
waitn 2 && ok "4 control: marker absent, killed job respawned" || bad "4 control failed: job did not respawn with marker absent"
: > "$M"; sleep 1.5
kill -TERM "$(tail -1 "$SB/pids")" 2>/dev/null
if waitn 3; then bad "5 job respawned although the marker was present"; else ok "5 marker present, killed job stayed down"; fi

echo "$((_fails)) failed"
[[ "$_fails" -eq 0 ]]
