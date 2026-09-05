#!/usr/bin/env bash
# #1538: "running" and "able to read" are different claims, and the install
# only ever asserted the first.
#
# MEASURED on origin/main ea6b812f, from the code, before this fix:
#
#   _ostler_start_assistant_daemon call sites          4
#     line 29049 indent 0   TOP LEVEL, first bootstrap
#     line 30260 indent 0   TOP LEVEL, final kickstart
#   FDA-aware lines inside that function                0
#
# install.sh:30253 says "UNCONDITIONAL" in capitals, so a customer who does
# nothing DOES reach state=running -- and install.sh:30257 says that on a
# declined or timed-out grant "the daemon starts here without FDA". The one
# customer-facing line that hedged, MSG_INFO_ASSISTANT_FINAL_RESTART_FDA, is
# printed only inside `if [[ "${CHANNEL_IMESSAGE_ENABLED:-false}" == true ]]`.
# So a NON-iMessage install started an FDA-less daemon and said nothing at all.
#
# THE READER NEEDED THREE STATES. _imessage_daemon_fda_granted echoes "granted"
# on auth_value 2 and nothing otherwise, and its `2>/dev/null || true` throws
# away stderr AND the return code -- so "the row says 0" and "we could not look"
# come back identical. Correct for the flow it serves, which fails toward more
# guidance; not good enough to tell a customer what they have.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run. British English throughout.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
INSTALL="${REPO}/install.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  [PASS] $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  [FAIL] $*"; }
cant() { echo "CANNOT-RUN: $*" >&2; echo "== 0 pass / 0 fail / 1 cannot-run =="; exit 2; }

[ -f "$INSTALL" ] || cant "no install.sh at ${INSTALL}"
/usr/bin/grep -q '^_ostler_daemon_fda_state() {' "$INSTALL" \
    || cant "install.sh no longer defines _ostler_daemon_fda_state; re-point this test"

WORK="$(mktemp -d)" || cant "mktemp failed"
trap 'rm -rf "$WORK"' EXIT
SRC="${WORK}/state.sh"
/usr/bin/sed -n '/^_ostler_daemon_fda_state() {/,/^}/p' "$INSTALL" > "$SRC"
[ -s "$SRC" ] || cant "extracted an empty function body -- the anchors moved"

# Drive the real function with sudo/sqlite3 stubbed. $1 = what fake sudo prints,
# $2 = its exit code, $3 = "nosqlite" to hide sqlite3 entirely.
drive() {
    local out="$1" rc="$2" mode="${3:-}"
    local bin="${WORK}/bin"; rm -rf "$bin"; mkdir -p "$bin"
    printf '#!/bin/sh\nprintf "%%s" "%s"\nexit %s\n' "$out" "$rc" > "${bin}/sudo"
    chmod +x "${bin}/sudo"
    # sqlite3 LIVES IN /usr/bin ON macOS, so "do not create a stub" does not hide
    # it -- my first version of this arm passed /usr/bin on PATH and the function
    # correctly answered `granted`. To test the absent case the PATH must contain
    # ONLY the stub directory.
    local _path="${bin}:/usr/bin:/bin"
    if [ "$mode" = "nosqlite" ]; then
        _path="${bin}"
    else
        printf '#!/bin/sh\nexit 0\n' > "${bin}/sqlite3"; chmod +x "${bin}/sqlite3"
    fi
    PATH="${_path}" /bin/bash -c ". '${SRC}'; _ostler_daemon_fda_state" 2>/dev/null
}

a="$(drive 2 0)"
[ "$a" = "granted" ] && ok "auth_value 2 with a clean read -> granted" \
                     || bad "auth_value 2 gave '${a}', expected granted"

b="$(drive 0 0)"
[ "$b" = "denied" ] && ok "auth_value 0 with a clean read -> denied (we looked, and it is off)" \
                    || bad "auth_value 0 gave '${b}', expected denied"

c="$(drive '' 0)"
[ "$c" = "denied" ] && ok "no row at all with a clean read -> denied, not unreadable" \
                    || bad "an absent row gave '${c}', expected denied"

# THE ARM THE WHOLE FIX EXISTS FOR. sudo -n refuses on a fresh install, which is
# the ORDINARY case, and it must not be reported to a customer as a denial.
d="$(drive '' 1)"
[ "$d" = "unreadable" ] && ok "sudo -n refusing (rc 1) -> unreadable, NOT denied -- could-not-look is not a denial" \
                        || bad "a failed read gave '${d}', expected unreadable. A customer would be told their daemon lacks FDA on evidence that says nothing."

e="$(drive 2 0 nosqlite)"
[ "$e" = "unreadable" ] && ok "sqlite3 absent -> unreadable, even though the stub would have said 2" \
                        || bad "a missing sqlite3 gave '${e}', expected unreadable"

# CONTROL: the three verdicts must be distinct, or the checks above pass against
# a reader that returns one constant.
_distinct="$(printf '%s\n%s\n%s\n' "$a" "$b" "$d" | sort -u | /usr/bin/grep -c .)"
[ "${_distinct}" = "3" ] && ok "CONTROL: granted / denied / unreadable are three distinct verdicts (${_distinct})" \
                         || bad "CONTROL: the reader produced ${_distinct} distinct verdict(s) across three different worlds"

# ── the reporter must be unconditional, which is the other half of #1538 ──
_call_indent="$(/usr/bin/awk '$0 ~ /^[[:space:]]*_ostler_report_assistant_fda[[:space:]]*$/ { match($0, /[^ ]/); print RSTART - 1; exit }' "$INSTALL")"
if [ -z "${_call_indent}" ]; then
    bad "_ostler_report_assistant_fda is never CALLED -- the reader exists and nothing runs it"
elif [ "${_call_indent}" = "0" ]; then
    ok "the report is called at top level (indent ${_call_indent}), so every install reaches it"
else
    bad "the report is called at indent ${_call_indent}, i.e. inside a conditional. A non-iMessage install would say nothing, which is the defect."
fi

# CONTROL ON THAT PROXY: a line known to be nested must NOT read as 0.
#
# PINNED BY CONTENT, NOT BY LINE NUMBER. The first version of this control said
# NR==23301, and adding ~70 lines above it moved that line to something else --
# a control anchored to a position in a file the same change edits is measuring
# whatever drifted into the slot.
_nested="$(/usr/bin/awk '/gui_log info "Daemon FDA register-nudge ran/ { match($0, /[^ ]/); print RSTART - 1; exit }' "$INSTALL")"
[ -n "${_nested}" ] && [ "${_nested}" != "0" ] \
    && ok "CONTROL: a known-nested line reads as indent ${_nested}, so indent 0 means something" \
    || bad "CONTROL: the indentation proxy cannot tell nested from top level (got '${_nested}')"

# The report must not be gated on the iMessage channel, which is exactly how the
# old hedging line came to be invisible on most installs.
_gated="$(/usr/bin/awk '/_ostler_report_assistant_fda[[:space:]]*$/{found=NR} END{print found}' "$INSTALL")"
if [ -n "${_gated}" ]; then
    _win="$(/usr/bin/sed -n "$((_gated-6)),${_gated}p" "$INSTALL" | /usr/bin/grep -c 'CHANNEL_IMESSAGE_ENABLED')"
    [ "${_win}" = "0" ] && ok "no CHANNEL_IMESSAGE_ENABLED gate in the six lines above the call" \
                        || bad "the call sits under a CHANNEL_IMESSAGE_ENABLED gate -- the same gate that hid the old line"
fi

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
