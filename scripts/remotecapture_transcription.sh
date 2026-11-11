#!/usr/bin/env bash
# Turn Ostler RemoteCapture's spoken transcription on or off, in place.
#
#   enable   move the parked app from staged/ into /Applications/Ostler, copy the staged
#            LaunchAgent into ~/Library/LaunchAgents and bootstrap it.
#            REFUSES unless a current ACCEPTED spoken_capture_recording_consent record exists.
#   disable  bootout the live agent, remove it from ~/Library/LaunchAgents, and move the app
#            back into staged/. The staged copy stays, so enable works again with no reinstall.
#   status   print the consent state, the app location, and where the plist is.
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
#   REMOTECAPTURE_APPS_DIR  /Applications/Ostler, overridable for tests (install.sh OSTLER_APPS_DIR)
set -uo pipefail

ACTION="${1:-status}"
LABEL="${REMOTECAPTURE_LABEL:-com.creativemachines.ostler-remotecapture}"
HOME_DIR="${REMOTECAPTURE_HOME:-$HOME}"
APP_SUPPORT="${HOME_DIR}/Library/Application Support/Ostler RemoteCapture"
STAGED="${APP_SUPPORT}/${LABEL}.plist.staged"
LIVE="${HOME_DIR}/Library/LaunchAgents/${LABEL}.plist"
# The app is parked outside /Applications until consent is accepted. install.sh
# _ostler_remotecapture_park writes the same STAGED_APP path.
APPS_DIR="${REMOTECAPTURE_APPS_DIR:-/Applications/Ostler}"
APP="${APPS_DIR}/Ostler RemoteCapture.app"
STAGED_APP="${HOME_DIR}/Library/Application Support/Ostler/staged/Ostler RemoteCapture.app"
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
        if [ ! -d "$APP" ]; then
            if [ ! -d "$STAGED_APP" ]; then
                echo "CANNOT-RUN: RemoteCapture is neither in ${APPS_DIR} nor parked at ${STAGED_APP}."
                exit 2
            fi
            mkdir -p "$APPS_DIR" && mv "$STAGED_APP" "$APP" || { echo "CANNOT-RUN: could not move RemoteCapture from ${STAGED_APP} into ${APPS_DIR}. Nothing was started."; exit 2; }
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
        if [ -d "$APP" ]; then
            mkdir -p "$(dirname "$STAGED_APP")" && rm -rf "$STAGED_APP" && mv "$APP" "$STAGED_APP" || { echo "FAILED: could not park ${APP} outside /Applications."; exit 1; }
        fi
        if [ -f "$LIVE" ] || [ -d "$APP" ] || agent_loaded; then
            echo "FAILED: ${LABEL} is still live, its plist is still in place, or the app is still in ${APPS_DIR}."
            exit 1
        fi
        echo "DISABLED: ${LABEL} is not loaded, has no plist in LaunchAgents, and the app is parked in staged/. Enable brings it back."
        exit 0
        ;;
    status)
        if consent_accepted; then echo "consent: accepted"; else echo "consent: not accepted"; fi
        if [ -d "$APP" ]; then echo "app: in ${APPS_DIR}"; elif [ -d "$STAGED_APP" ]; then echo "app: parked in staged/"; else echo "app: absent"; fi
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
