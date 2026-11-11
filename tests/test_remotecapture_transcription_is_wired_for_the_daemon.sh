#!/usr/bin/env bash
# THE HUB SETTINGS TOGGLE MUST FIND THE SCRIPT THE INSTALLER PUT DOWN.
#
# ostler-assistant #677 (Hub Settings > spoken transcription) runs
# ${OSTLER_DIR}/bin/remotecapture_transcription.sh with OSTLER_PYTHON from the
# daemon's environment. Until this change install.sh never copied that script
# into ${OSTLER_DIR}/bin, and the assistant's LaunchAgent carried neither
# OSTLER_PYTHON nor OSTLER_REMOTECAPTURE_TRANSCRIPTION_SCRIPT, so the toggle
# had nothing to run. This asserts the three links, end to end, in a sandbox:
#
#   1. the installer's install line lands the script at #677's default path;
#   2. the rendered assistant plist names that same script and a python
#      that can import ostler_security.consent_cli;
#   3. the installed script's `status` runs through that plist's environment.
#
# The real INSTALL_SNIPPET.sh renders the plist, with launchctl stubbed so the
# developer's own LaunchAgents are never touched. THREE STATES. 0 pass, 1 fail,
# 2 cannot-run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER="${REPO}/install.sh"
SNIPPET="${REPO}/assistant-agent/INSTALL_SNIPPET.sh"
SCRIPT_SRC="${REPO}/scripts/remotecapture_transcription.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

for f in "$INSTALLER" "$SNIPPET" "$SCRIPT_SRC"; do
    [ -f "$f" ] || { echo "CANNOT-RUN: missing ${f}" >&2; exit 2; }
done
command -v python3 >/dev/null 2>&1 || { echo "CANNOT-RUN: no python3 to read the plist" >&2; exit 2; }

WORK="$(mktemp -d)" || { echo "CANNOT-RUN: no working directory" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT
H="${WORK}/home"; mkdir -p "$H" "${WORK}/stubs"

# launchctl stub: logs, never touches a real LaunchAgent. `print` reports absent.
cat > "${WORK}/stubs/launchctl" <<'LC'
#!/usr/bin/env bash
[ "$1" = print ] && exit 113
exit 0
LC
chmod +x "${WORK}/stubs/launchctl"
export PATH="${WORK}/stubs:${PATH}"

echo "── 1. the installer lands the script at #677's default path ──"
# #677 default: ${OSTLER_DIR:-$HOME/.ostler}/bin/remotecapture_transcription.sh
LINE="$(grep -F 'install -m 755 "${SCRIPT_DIR}/scripts/remotecapture_transcription.sh"' "$INSTALLER" | head -1)"
if [ -z "$LINE" ]; then
    bad "install.sh has no line installing scripts/remotecapture_transcription.sh"
else
    if grep -qF 'OSTLER_DIR="${OSTLER_DIR:-${HOME}/.ostler}"' "$INSTALLER" \
       && printf '%s' "$LINE" | grep -qF '"${OSTLER_DIR}/bin/remotecapture_transcription.sh"'; then
        ok "install.sh names \${OSTLER_DIR}/bin/remotecapture_transcription.sh and the \$HOME/.ostler default"
    else
        bad "install.sh destination is not #677's default path"
    fi
    env -i HOME="$H" PATH="${WORK}/stubs:/usr/bin:/bin:/usr/sbin:/sbin" SCRIPT_DIR="$REPO" \
        bash -c 'warn() { echo "warn: $*" >&2; }; OSTLER_DIR="${OSTLER_DIR:-${HOME}/.ostler}"; '"$LINE" \
        >/dev/null 2>"${WORK}/install.err"
    INSTALLED="${H}/.ostler/bin/remotecapture_transcription.sh"
    if [ -x "$INSTALLED" ] && cmp -s "$INSTALLED" "$SCRIPT_SRC"; then
        ok "installed copy is executable and byte-identical to scripts/remotecapture_transcription.sh"
    else
        bad "no executable copy at ${INSTALLED} (install stderr: $(tr '\n' ' ' < "${WORK}/install.err"))"
    fi
fi

echo "── 2. the rendered assistant plist names that script and a python that imports consent_cli ──"
# A venv python shim at the path install.sh gives OSTLER_PYTHON, reading the
# vendored ostler_security exactly as the installed venv would.
mkdir -p "${H}/.ostler/.venv/bin" "${H}/.ostler/OstlerAssistant.app/Contents/MacOS"
cat > "${H}/.ostler/.venv/bin/python3" <<PY
#!/usr/bin/env bash
PYTHONPATH="${REPO}/vendor" exec /usr/bin/env python3 "\$@"
PY
chmod +x "${H}/.ostler/.venv/bin/python3"
printf '#!/bin/sh\nexit 0\n' > "${H}/.ostler/OstlerAssistant.app/Contents/MacOS/ostler-assistant"
chmod +x "${H}/.ostler/OstlerAssistant.app/Contents/MacOS/ostler-assistant"

# The real snippet renders the plist. DEFER_START so nothing is bootstrapped.
env -i HOME="$H" PATH="${WORK}/stubs:/usr/bin:/bin:/usr/sbin:/sbin" \
    OSTLER_DIR="${H}/.ostler" OSTLER_INSTALL_ROOT="${REPO}/assistant-agent" \
    OSTLER_ASSISTANT_DEFER_START=true \
    bash "$SNIPPET" >"${WORK}/snippet.out" 2>"${WORK}/snippet.err"
RENDER_RC=$?
PLIST="${H}/Library/LaunchAgents/com.creativemachines.ostler.assistant.plist"
if [ "$RENDER_RC" -ne 0 ] || [ ! -f "$PLIST" ]; then
    bad "INSTALL_SNIPPET.sh did not render the plist (rc ${RENDER_RC}: $(tr '\n' ' ' < "${WORK}/snippet.err"))"
else
    read -r PY_IN_PLIST SCRIPT_IN_PLIST < <(python3 - "$PLIST" <<'PYX'
import plistlib, sys
env = plistlib.load(open(sys.argv[1], "rb")).get("EnvironmentVariables", {})
print(env.get("OSTLER_PYTHON", "-"), env.get("OSTLER_REMOTECAPTURE_TRANSCRIPTION_SCRIPT", "-"))
PYX
    )
    if [ "$PY_IN_PLIST" = "-" ]; then
        bad "rendered plist has no OSTLER_PYTHON in EnvironmentVariables"
    elif [ "$PY_IN_PLIST" != "${H}/.ostler/.venv/bin/python3" ]; then
        bad "plist OSTLER_PYTHON is ${PY_IN_PLIST}, not the venv python install.sh builds"
    elif "$PY_IN_PLIST" -c 'import ostler_security.consent_cli' 2>"${WORK}/import.err"; then
        ok "plist OSTLER_PYTHON imports ostler_security.consent_cli"
    else
        bad "plist OSTLER_PYTHON cannot import consent_cli: $(tr '\n' ' ' < "${WORK}/import.err")"
    fi

    if [ "$SCRIPT_IN_PLIST" = "-" ]; then
        bad "rendered plist has no OSTLER_REMOTECAPTURE_TRANSCRIPTION_SCRIPT"
    elif [ "$SCRIPT_IN_PLIST" = "${H}/.ostler/bin/remotecapture_transcription.sh" ] && [ -x "$SCRIPT_IN_PLIST" ]; then
        ok "plist script path is the installed script (#677's default)"
    else
        bad "plist script path ${SCRIPT_IN_PLIST} is not the installed script"
    fi

    echo "── 3. the installed script's status runs through the plist's environment ──"
    if [ "$PY_IN_PLIST" = "-" ] || [ "$SCRIPT_IN_PLIST" = "-" ]; then
        bad "status not attempted: the plist env is incomplete"
    else
        env -i HOME="$H" PATH="${WORK}/stubs:/usr/bin:/bin:/usr/sbin:/sbin" \
            OSTLER_PYTHON="$PY_IN_PLIST" OSTLER_HOME="${H}/.ostler" \
            OSTLER_REMOTECAPTURE_TRANSCRIPTION_SCRIPT="$SCRIPT_IN_PLIST" \
            bash "$SCRIPT_IN_PLIST" status >"${WORK}/status.out" 2>"${WORK}/status.err"
        ST_RC=$?
        if [ "$ST_RC" -eq 0 ] && grep -q '^consent: not accepted$' "${WORK}/status.out" \
           && grep -q '^staged plist: ' "${WORK}/status.out"; then
            ok "status exits 0 and reports the four state lines under the plist env"
        else
            bad "status rc ${ST_RC}: $(tr '\n' ' ' < "${WORK}/status.err") $(tr '\n' ' ' < "${WORK}/status.out")"
        fi
    fi
fi

echo; echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ]
