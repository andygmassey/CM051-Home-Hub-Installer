#!/usr/bin/env bash
#
# tests/test_derive_reads_conversations_mirror_not_documents.sh
#
# THE DEFECT (v1.0.121 cold walk, Mini16): no_python_is_tcc_responsible FAIL.
# The derive-preferences agent is bare launchd python, and its
# stated_transcripts reader defaults to ~/Documents/Ostler/Conversations, so
# TCC charged a Documents request to the bundled python3.11 as responsible.
# The fix: the signed fda-rerun wrapper mirrors that folder into
# ~/.ostler/state/conversations_mirror and the derive plist points
# OSTLER_CONVERSATIONS_DIR there.
#
# WHAT THIS RUNS (synthetic data, sandbox HOME):
#   1  the plist the REAL _install_derive_preferences_agent writes sets
#      OSTLER_CONVERSATIONS_DIR to a path outside ~/Documents
#   2  the REAL _ostler_conversations_mirror, lifted from install.sh, copies a
#      transcript into exactly that path
#   3  a transcript removed from the source is removed from the mirror
# INSTALL_SH may point at another copy (how the red is watched).
# Exit 0 pass, 1 fail, 2 cannot-run. Bash 3.2 portable.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${INSTALL_SH:-$(cd "${HERE}/.." && pwd)/install.sh}"
[ -r "$INSTALL_SH" ] || { echo "CANNOT-RUN: $INSTALL_SH unreadable"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "CANNOT-RUN: no python3"; exit 2; }
command -v rsync >/dev/null 2>&1 || { echo "CANNOT-RUN: no rsync"; exit 2; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }
SANDBOX="$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd)/derive-mirror.XXXXXX")" || { echo "CANNOT-RUN: mktemp"; exit 2; }
trap 'rm -rf "$SANDBOX"' EXIT

lift() { # lift <function name> <outfile>
    local start end
    start="$(grep -nE "^$1\\(\\) \\{" "$INSTALL_SH" | head -1 | cut -d: -f1)"
    [ -n "$start" ] || return 1
    for end in $(awk -v s="$start" 'NR > s && /^\}/ { print NR }' "$INSTALL_SH"); do
        sed -n "${start},${end}p" "$INSTALL_SH" > "$2"
        bash -n "$2" 2>/dev/null && return 0
    done
    return 1
}
lift _install_derive_preferences_agent "${SANDBOX}/agent.sh" || { echo "CANNOT-RUN: cannot lift the derive agent installer"; exit 2; }
lift _ostler_conversations_mirror "${SANDBOX}/mirror.sh" || { echo "FAIL: _ostler_conversations_mirror is not defined in install.sh"; exit 1; }

BIN="${SANDBOX}/bin"; mkdir -p "$BIN"
printf '#!/bin/sh\nexit 0\n' > "${BIN}/launchctl"; chmod +x "${BIN}/launchctl"
H="${SANDBOX}/home"; O="${H}/.ostler"; mkdir -p "${O}/logs" "${H}/Library/LaunchAgents"
(
    export HOME="$H" PATH="${BIN}:${PATH}"
    OSTLER_DIR="$O"; LOGS_DIR="${O}/logs"
    ok() { :; }; warn() { :; }; info() { :; }; _ks_bounded() { :; }
    . "${SANDBOX}/agent.sh"
    _install_derive_preferences_agent
) >/dev/null 2>&1
PLIST="${H}/Library/LaunchAgents/com.ostler.derive-preferences.plist"
[ -f "$PLIST" ] || { echo "CANNOT-RUN: the function wrote no plist"; exit 2; }
root="$(python3 -I -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1],"rb")).get("EnvironmentVariables",{}).get("OSTLER_CONVERSATIONS_DIR",""))' "$PLIST")"
case "$root" in
    '') bad "1 the derive plist sets no OSTLER_CONVERSATIONS_DIR; the reader falls back to ~/Documents" ;;
    "${H}/Documents"*) bad "1 OSTLER_CONVERSATIONS_DIR is inside ~/Documents: ${root}" ;;
    *) ok "1 derive plist reads conversations from ${root#"$H"/}" ;;
esac

SRC="${H}/Documents/Ostler/Conversations/2026-11-01/synthetic-a"; mkdir -p "$SRC"
printf 'synthetic owner line\n' > "${SRC}/transcript.md"
(
    export HOME="$H"; OSTLER_DIR="$O"
    . "${SANDBOX}/mirror.sh"
    _ostler_conversations_mirror
)
if [ -n "$root" ] && [ -f "${root}/2026-11-01/synthetic-a/transcript.md" ]; then ok "2 the mirror holds the transcript at the path the plist names"
else bad "2 no transcript at '${root}/2026-11-01/synthetic-a/transcript.md' after the mirror ran"; fi

rm -rf "$SRC"
(
    export HOME="$H"; OSTLER_DIR="$O"
    . "${SANDBOX}/mirror.sh"
    _ostler_conversations_mirror
)
if [ -n "$root" ] && [ ! -e "${root}/2026-11-01/synthetic-a" ]; then ok "3 a removed conversation leaves the mirror"
else bad "3 a removed conversation is still in the mirror"; fi

echo "pass=${PASS} fail=${FAIL}"
[ "$FAIL" -eq 0 ]
