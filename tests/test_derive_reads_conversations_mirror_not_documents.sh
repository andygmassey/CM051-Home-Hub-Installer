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
#   2  the REAL lib/ostler-conversations-mirror.sh copies an L2 transcript into
#      exactly that path, and withholds an L3 one and one with NO privacy_level
#   3  a transcript removed from the source, or re-levelled to L3, leaves the mirror
#   4  mirror directories are 700 and files 600
#   5  a failing rsync is logged ([mirror] FAIL), not swallowed
#   6  the ostler-fda wrapper in install.sh sources the lib; install.sh installs it
#   7  ostler-uninstall removes state/conversations_mirror
# INSTALL_SH / MIRROR_LIB may point at another copy (how the red is watched).
# Exit 0 pass, 1 fail, 2 cannot-run. Bash 3.2 portable.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${INSTALL_SH:-$(cd "${HERE}/.." && pwd)/install.sh}"
MIRROR_LIB="${MIRROR_LIB:-$(cd "${HERE}/.." && pwd)/lib/ostler-conversations-mirror.sh}"
[ -r "$MIRROR_LIB" ] || { echo "CANNOT-RUN: $MIRROR_LIB unreadable"; exit 2; }
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
grep -q '^_ostler_conversations_mirror() {' "$MIRROR_LIB" || { echo "FAIL: _ostler_conversations_mirror is not defined in $MIRROR_LIB"; exit 1; }

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

CONV="${H}/Documents/Ostler/Conversations"
mk() { # mk <name> <frontmatter line or ''>
    mkdir -p "${CONV}/2026-11-01/$1"
    if [ -n "$2" ]; then printf -- '---\nchannel: im\n%s\n---\nsynthetic owner line\n' "$2" > "${CONV}/2026-11-01/$1/transcript.md"
    else printf -- '---\nchannel: im\n---\nsynthetic owner line\n' > "${CONV}/2026-11-01/$1/transcript.md"; fi
}
run_mirror() { ( export HOME="$H" PATH="${1:-$PATH}"; OSTLER_DIR="$O"; . "$MIRROR_LIB"; _ostler_conversations_mirror ) 2>&1; }
mk l2 'privacy_level: L2'; mk l3 'privacy_level: L3'; mk nolevel ''; mk "odd [x]*" 'privacy_level: "L3"'
mk l0 "privacy_level: 'L0'"
MLOG="$(run_mirror)"
T="2026-11-01"
if [ -n "$root" ] && [ -f "${root}/${T}/l2/transcript.md" ] && [ -f "${root}/${T}/l0/transcript.md" ]; then ok "2a L2 and L0 transcripts are in the mirror at the path the plist names"
else bad "2a L2/L0 transcript missing from '${root}'"; fi
if [ ! -e "${root}/${T}/l3" ] && [ ! -e "${root}/${T}/odd [x]*" ]; then ok "2b the L3 transcripts are ABSENT from the mirror"
else bad "2b an L3 transcript is in the mirror"; fi
if [ ! -e "${root}/${T}/nolevel" ]; then ok "2c the no-level transcript is ABSENT from the mirror (fail closed)"
else bad "2c a transcript with no privacy_level is in the mirror"; fi

rm -rf "${CONV}/${T}/l0"; mk l2 'privacy_level: L3'; mk l1 'privacy_level: L1'
run_mirror >/dev/null
if [ ! -e "${root}/${T}/l0" ]; then ok "3a a deleted conversation leaves the mirror"; else bad "3a a deleted conversation is still in the mirror"; fi
if [ ! -e "${root}/${T}/l2" ]; then ok "3b a conversation re-levelled to L3 leaves the mirror"; else bad "3b a re-levelled L3 conversation is still in the mirror"; fi
[ -f "${root}/${T}/l1/transcript.md" ] || bad "3c a new L1 conversation did not arrive"

badperm="$(find "$root" -type d ! -perm 700 -o -type f ! -perm 600 2>&1 | head -3)"
nfiles="$(find "$root" -type f | wc -l | tr -d ' ')"
if [ -z "$badperm" ] && [ "$nfiles" -ge 1 ]; then ok "4 mirror dirs are 700 and files 600 (${nfiles} file(s) checked)"
else bad "4 wrong modes or empty mirror: ${badperm:-none wrong}, files=${nfiles}"; fi

mkdir -p "${SANDBOX}/failbin"; printf '#!/bin/sh\nexit 23\n' > "${SANDBOX}/failbin/rsync"; chmod +x "${SANDBOX}/failbin/rsync"
case "$(run_mirror "${SANDBOX}/failbin:$PATH")" in *"[mirror] FAIL"*) ok "5 a failing rsync is logged" ;; *) bad "5 a failing rsync left no [mirror] FAIL line" ;; esac

heredoc() { awk -v m="$1" '$0 ~ "<<.?" m ".?$" {on=1; next} $0 == m {on=0} on' "$INSTALL_SH"; }
if heredoc FDAEOF | grep -q 'source .*ostler-conversations-mirror.sh' && heredoc FDAEOF | grep -q '_ostler_conversations_mirror' \
   && grep -q 'cp "${SCRIPT_DIR}/lib/ostler-conversations-mirror.sh"' "$INSTALL_SH" \
   && ! heredoc FDAEOF | grep -q 'SCRIPT_DIR'; then ok "6 ostler-fda sources the mirror lib and install.sh installs it (outside the wrapper, where SCRIPT_DIR exists)"
else bad "6 the wrapper does not source the lib, install.sh does not install it, or the install cp is inside the wrapper (no SCRIPT_DIR at tick time)"; fi
if heredoc UNINSTALLEOF | grep -q 'rm -rf .*state/conversations_mirror'; then ok "7 ostler-uninstall removes state/conversations_mirror"
else bad "7 ostler-uninstall does not remove state/conversations_mirror"; fi

# 8  the helper writes NOTHING to stdout (the wrapper's stdout is read by callers; the
#    forward-window gate saw "[mirror] CANNOT-RUN" there), while stderr keeps the lines
out_ok="$( ( export HOME="$H"; OSTLER_DIR="$O"; . "$MIRROR_LIB"; _ostler_conversations_mirror ) 2>/dev/null )"
out_fail="$( ( export HOME="$H" PATH="${SANDBOX}/failbin:$PATH"; OSTLER_DIR="$O"; . "$MIRROR_LIB"; _ostler_conversations_mirror ) 2>/dev/null )"
err_fail="$( ( export HOME="$H" PATH="${SANDBOX}/failbin:$PATH"; OSTLER_DIR="$O"; . "$MIRROR_LIB"; _ostler_conversations_mirror ) 2>&1 >/dev/null )"
if [ -z "$out_ok" ] && [ -z "$out_fail" ] && case "$err_fail" in *"[mirror] FAIL"*) true ;; *) false ;; esac; then ok "8 mirror status goes to stderr, stdout stays empty (ok and FAIL paths)"
else bad "8 mirror wrote to stdout (ok='${out_ok}' fail='${out_fail}') or lost its stderr FAIL line"; fi
if heredoc FDAEOF | grep 'mirror\] CANNOT-RUN' | grep -q '>&2'; then ok "8b the wrapper's missing-helper CANNOT-RUN line goes to stderr"
else bad "8b the wrapper's missing-helper CANNOT-RUN line is on stdout"; fi

echo "pass=${PASS} fail=${FAIL}"
[ "$FAIL" -eq 0 ]
