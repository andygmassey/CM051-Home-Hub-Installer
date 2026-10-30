#!/usr/bin/env bash
#
# tests/test_derive_agent_env_can_read_system_load.sh
#
# THE DEFECT (v1.0.121 trial box). derive-preferences.log: "deferred (load:
# unreadable (1m load '', cores '0'); tier floor defers by default)". The tier
# lib reads load and cores with a bare `sysctl`. The derive LaunchAgent plist
# set PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin, which EXCLUDES
# /usr/sbin where macOS keeps sysctl, so every read came back empty. The bundle
# ticks set no PATH, get launchd's default (includes /usr/sbin) and read fine.
#
# WHAT THIS RUNS. The REAL _install_derive_preferences_agent is lifted out of
# install.sh and run in a sandbox HOME (launchctl stubbed on PATH); the plist
# it GENERATES is parsed for its EnvironmentVariables, and the tier lib (as
# install.sh embeds it) is run under `env -i` plus EXACTLY those variables.
# No sysctl stub: the real binary on this host, found only via the plist PATH.
#   1  sysctl resolves under the plist's environment
#   2  the 1-minute load reads as a number
#   3  cores reads > 0
# INSTALL_SH may point at another copy (how the red is watched).
# Exit 0 pass, 1 fail, 2 cannot-run. Bash 3.2 portable. Synthetic only.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
INSTALL_SH="${INSTALL_SH:-${REPO}/install.sh}"
[ -r "$INSTALL_SH" ] || { echo "CANNOT-RUN: $INSTALL_SH unreadable"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "CANNOT-RUN: no python3 to parse the plist"; exit 2; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }

SANDBOX="$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd)/derive-env.XXXXXX")" || { echo "CANNOT-RUN: mktemp"; exit 2; }
trap 'rm -rf "$SANDBOX"' EXIT

start="$(grep -nE '^_install_derive_preferences_agent\(\) \{' "$INSTALL_SH" | head -1 | cut -d: -f1)"
[ -n "$start" ] || { echo "CANNOT-RUN: _install_derive_preferences_agent not found"; exit 2; }
lifted=""
for end in $(awk -v s="$start" 'NR > s && /^\}/ { print NR }' "$INSTALL_SH"); do
    sed -n "${start},${end}p" "$INSTALL_SH" > "${SANDBOX}/agent.sh"
    if bash -n "${SANDBOX}/agent.sh" 2>/dev/null; then lifted=1; break; fi
done
[ -n "$lifted" ] || { echo "CANNOT-RUN: could not lift the function"; exit 2; }
sed -n '/<<.OSTLER_RESOURCE_TIER_EOF.$/,/^OSTLER_RESOURCE_TIER_EOF$/p' "$INSTALL_SH" | sed '1d;$d' > "${SANDBOX}/tier.sh"
grep -q '^ostler_rt_loadavg_1m()' "${SANDBOX}/tier.sh" 2>/dev/null \
    || { echo "CANNOT-RUN: embedded tier lib not found"; exit 2; }

BIN="${SANDBOX}/bin"; mkdir -p "$BIN"
printf '#!/bin/sh\nexit 0\n' > "${BIN}/launchctl"; chmod +x "${BIN}/launchctl"
H="${SANDBOX}/home"; O="${H}/.ostler"; mkdir -p "${O}/logs" "${H}/Library/LaunchAgents"
(
    export HOME="$H" PATH="${BIN}:${PATH}"
    OSTLER_DIR="$O"; LOGS_DIR="${O}/logs"
    ok() { :; }; warn() { :; }; info() { :; }; _ks_bounded() { :; }
    # shellcheck source=/dev/null
    . "${SANDBOX}/agent.sh"
    _install_derive_preferences_agent
) >/dev/null 2>&1
PLIST="${H}/Library/LaunchAgents/com.ostler.derive-preferences.plist"
[ -f "$PLIST" ] || { echo "CANNOT-RUN: the function wrote no plist"; exit 2; }

# EnvironmentVariables as KEY=VALUE lines (NUL-free, one per line).
python3 -I - "$PLIST" > "${SANDBOX}/env.txt" <<'PY' || { echo "CANNOT-RUN: plist unparsable"; exit 2; }
import plistlib, sys
d = plistlib.load(open(sys.argv[1], "rb"))
for k, v in sorted(d.get("EnvironmentVariables", {}).items()):
    print("%s=%s" % (k, v))
PY
grep -q '^PATH=' "${SANDBOX}/env.txt" || { bad "the plist sets no PATH"; }
ENVARGS=()
while IFS= read -r line; do ENVARGS+=("$line"); done < "${SANDBOX}/env.txt"

run_env() { env -i "${ENVARGS[@]}" /bin/bash -c "$1" 2>&1; }

sysctl_path="$(run_env 'command -v sysctl')"
if [ -n "$sysctl_path" ]; then ok "1 sysctl resolves under the plist environment: ${sysctl_path}"
else bad "1 sysctl does NOT resolve under the plist environment (PATH=$(grep '^PATH=' "${SANDBOX}/env.txt"))"; fi

load="$(run_env ". '${SANDBOX}/tier.sh'; ostler_rt_loadavg_1m")"
case "$load" in
    ''|*[!0-9.]*|.|*.*.*) bad "2 load did not read as a number: '${load}'" ;;
    *) ok "2 load reads as a number: ${load}" ;;
esac

cores="$(run_env ". '${SANDBOX}/tier.sh'; ostler_rt_cpu_cores")"
case "$cores" in
    ''|*[!0-9]*|0) bad "3 cores did not read > 0: '${cores}'" ;;
    *) ok "3 cores reads > 0: ${cores}" ;;
esac

echo "pass=${PASS} fail=${FAIL}"
[ "$FAIL" -eq 0 ]
