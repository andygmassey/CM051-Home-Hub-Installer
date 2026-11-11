#!/usr/bin/env bash
# Turn Ostler RemoteCapture's spoken transcription on or off, in place.
#
#   enable   copy the staged LaunchAgent into ~/Library/LaunchAgents and bootstrap it.
#            REFUSES unless a current ACCEPTED spoken_capture_recording_consent record exists.
#   disable  bootout the live agent and remove it from ~/Library/LaunchAgents.
#            The staged copy stays, so enable works again with no reinstall.
#   status   print the consent state and where the plist is.
#
# Exit: 0 done / reported. 3 refused: no accepted consent record. 2 cannot-run:
# RemoteCapture is not staged here, or a required tool is missing. 1 launchctl
# did not bring the agent up. Stdout and stderr are for the caller's log; they
# are not customer-rendered copy. Customer copy lives in install.sh.strings.*.sh.
#
# Environment (all have defaults):
#   OSTLER_PYTHON            python with ostler_security installed (consent_cli)
#   REMOTECAPTURE_HOME      $HOME, overridable for tests
#   REMOTECAPTURE_LABEL     com.creativemachines.ostler-remotecapture
set -uo pipefail

ACTION="${1:-status}"
LABEL="${REMOTECAPTURE_LABEL:-com.creativemachines.ostler-remotecapture}"
HOME_DIR="${REMOTECAPTURE_HOME:-$HOME}"
APP_SUPPORT="${HOME_DIR}/Library/Application Support/Ostler RemoteCapture"
STAGED="${APP_SUPPORT}/${LABEL}.plist.staged"
LIVE="${HOME_DIR}/Library/LaunchAgents/${LABEL}.plist"
UID_NOW="$(id -u)"
TICKBOX="spoken_capture_recording_consent"

consent_accepted() {
    [ -n "${OSTLER_PYTHON:-}" ] && [ -x "${OSTLER_PYTHON}" ] || return 1
    "$OSTLER_PYTHON" -m ostler_security.consent_cli check --tickbox "$TICKBOX" >/dev/null 2>&1
}

agent_loaded() {
    launchctl print "gui/${UID_NOW}/${LABEL}" >/dev/null 2>&1
}

case "$ACTION" in
    enable)
        if ! consent_accepted; then
            echo "REFUSED: no current accepted record for ${TICKBOX}. Record the answer first; nothing was started."
            exit 3
        fi
        if [ ! -f "$STAGED" ]; then
            echo "CANNOT-RUN: no staged LaunchAgent at ${STAGED}. RemoteCapture was not staged on this Mac."
            exit 2
        fi
        mkdir -p "${HOME_DIR}/Library/LaunchAgents" || { echo "CANNOT-RUN: could not create LaunchAgents folder"; exit 2; }
        cp "$STAGED" "$LIVE" && chmod 0644 "$LIVE" || { echo "CANNOT-RUN: could not copy the staged agent into place"; exit 2; }
        # launchctl bootstrap exits 0 on some failures, so judge by launchctl print.
        launchctl bootout "gui/${UID_NOW}/${LABEL}" >/dev/null 2>&1 || true
        launchctl bootstrap "gui/${UID_NOW}" "$LIVE" >/dev/null 2>&1 || true
        if agent_loaded; then
            echo "ENABLED: ${LABEL} is loaded for gui/${UID_NOW}."
            exit 0
        fi
        echo "FAILED: launchctl did not load ${LABEL}. The plist is at ${LIVE}."
        exit 1
        ;;
    disable)
        launchctl bootout "gui/${UID_NOW}/${LABEL}" >/dev/null 2>&1 || true
        rm -f "$LIVE" 2>/dev/null || true
        if [ -f "$LIVE" ] || agent_loaded; then
            echo "FAILED: ${LABEL} is still live or its plist is still in place."
            exit 1
        fi
        echo "DISABLED: ${LABEL} is not loaded and has no plist in LaunchAgents. The staged copy is kept."
        exit 0
        ;;
    status)
        if consent_accepted; then echo "consent: accepted"; else echo "consent: not accepted"; fi
        if [ -f "$LIVE" ]; then echo "live plist: present"; else echo "live plist: absent"; fi
        if [ -f "$STAGED" ]; then echo "staged plist: present"; else echo "staged plist: absent"; fi
        if agent_loaded; then echo "agent: loaded"; else echo "agent: not loaded"; fi
        exit 0
        ;;
    *)
        echo "usage: $0 enable|disable|status" >&2
        exit 2
        ;;
esac
