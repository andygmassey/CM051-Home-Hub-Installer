#!/bin/bash
# CM051 #950. THE STORE-AUTH GUARD SILENCED ITS OWN FAILURE.
#
# The sole call that installs the ostler_store_auth .pth into the bundled
# interpreter sits inside
#
#     if [[ ... "${PYTHON3_BIN}" == "${OSTLER_FINAL_DIR}/python/"* ]]
#
# and until this change its warn sat inside the same `if`, beside the call.
# So on any PYTHON3_BIN that is not the bundled interpreter the shim was not
# written AND NOTHING WAS LOGGED. The install printed the same thing whether
# the credential wiring had happened or had been skipped entirely, and the
# whole of the #550 store-auth work was inert and silent.
#
# SIX VALUES DO NOT MATCH, none of them exotic: the four degrade branches in
# _ostler_relocate_bundled_python, a plain `command -v python3`, and two
# Homebrew kegs.
#
# WHY THE EXISTING TEST COULD NOT CATCH IT, and it is the reason this one
# exists rather than an extra arm on that one:
# tests/test_store_auth_covers_every_interpreter.sh is STATIC. It asserts the
# wiring CALL EXISTS at 15 sites against a floor of 15. A call inside a guard
# that evaluates false still exists. Presence is not execution and a static
# test cannot tell them apart. This one EXECUTES the shipped block.
#
# THE WRITE IS STILL GUARDED AND THAT IS CORRECT. Writing a .pth into a
# Homebrew keg or /usr/bin/python3 modifies software the customer did not get
# from us. This test asserts the guard still refuses to write there, so a
# later "fix" that just removes the guard fails here.
#
# HAS IT EVER FAILED: ARM 4 rebuilds the pre-fix block (no else) every run and
# asserts it is SILENT. A green ARM 4 means the mutant did not apply.
set -uo pipefail

# NO `... | grep -q` ANYWHERE IN HERE, and the first draft of this file used it
# NINE times. It exits on first match and SIGPIPEs the producer, and this repo
# ratchets against it (tests/test_pipefail_shortcircuit_inversion.sh, baseline
# 69). The remedy used throughout is the one that ratchet itself prints:
#
#     [ "$(... | grep -c PAT)" -gt 0 ]        grep -c must read to EOF
#
# rather than the herestring form, because that is a bashism and this file is
# meant to stay runnable under any POSIX shell the walk might use.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="${ROOT}/install.sh"
[ -r "$INSTALL" ] || { echo "CANNOT-RUN: ${INSTALL} is not readable."; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
BLOCK="${WORK}/block.sh"

awk '/^if \[\[ -n "\$\{PYTHON3_BIN:-\}" && "\$\{PYTHON3_BIN\}" == "\$\{OSTLER_FINAL_DIR\}\/python\/"\* \]\]; then$/ { f = 1 }
     f { print }
     f && /^fi$/ { exit }' "$INSTALL" > "$BLOCK"
LINES="$(grep -c . "$BLOCK" || true)"
if [ "${LINES:-0}" -lt 5 ]; then
    echo "CANNOT-RUN: extracted only ${LINES:-0} lines. The guard has moved;"
    echo "            re-point the awk range rather than deleting this test."
    exit 2
fi
echo "EXAMINED: ${LINES} lines of the SHIPPED guard out of install.sh"

MUTANT="${WORK}/mutant.sh"
awk '!/^else$/ && !/store-auth \.pth NOT wired/' "$BLOCK" > "$MUTANT"
# The mutant must differ, or arm 4 proves nothing.
if cmp -s "$BLOCK" "$MUTANT"; then
    echo "CANNOT-RUN: the pre-fix mutant is identical to the subject, so it"
    echo "            did not apply and ARM 4 would pass vacuously."
    exit 2
fi

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        | /'; return 0; }

# run <block> <python3_bin> -> prints WARN/WIRED lines
run() {
    PYTHON3_BIN="$2" OSTLER_FINAL_DIR="${WORK}/ostler" HOME="${WORK}/home" \
    /bin/bash -c '
        set -uo pipefail
        warn() { printf "WARN %s\n" "$*"; }
        _ostler_wire_store_auth_pth() { printf "WIRED %s %s\n" "$1" "${2:-}"; return 0; }
        . "'"$1"'"
    ' 2>&1
}

BUNDLED="${WORK}/ostler/python/bin/python3"

echo
echo "ARM 1: the bundled interpreter is still wired, unchanged"
out="$(run "$BLOCK" "$BUNDLED")"
[ "$(printf '%s\n' "$out" | grep -c '^WIRED ')" -gt 0 ] \
    && ok "(1) the bundled interpreter still gets the shim" || no "(1)" "$out"
[ "$(printf '%s\n' "$out" | grep -c '^WARN ')" -gt 0 ] \
    && no "(1b) it warned on the HEALTHY path, which would cry wolf on every install" "$out" \
    || ok "(1b) and says nothing, because nothing was skipped"

echo
echo "ARM 2: THE DEFECT. A non-bundled interpreter must be SAID OUT LOUD."
for py in "/opt/homebrew/bin/python3" "/usr/local/bin/python3" "/usr/bin/python3" ""; do
    label="${py:-<unset>}"
    out="$(run "$BLOCK" "$py")"
    if [ "$(printf '%s\n' "$out" | grep -c '^WARN .*store-auth .pth NOT wired')" -gt 0 ]; then
        ok "(2) ${label}: the skip is logged"
    else
        no "(2) ${label}: the shim was skipped and NOTHING was logged" "$out"
    fi
    if [ "$(printf '%s\n' "$out" | grep -c '^WIRED ')" -gt 0 ]; then
        no "(2b) ${label}: a .pth was written into an interpreter we do not own" "$out"
    fi
done
ok "(2b) no .pth is written into an interpreter we do not own, on any of the four"

echo
echo "ARM 3: the message carries what a reader needs"
out="$(run "$BLOCK" "/opt/homebrew/bin/python3")"
[ "$(printf '%s\n' "$out" | grep -c '/opt/homebrew/bin/python3')" -gt 0 ] \
    && ok "(3a) it names the interpreter that was actually used" || no "(3a)" "$out"
[ "$(printf '%s\n' "$out" | grep -c '#950')" -gt 0 ] \
    && ok "(3b) it carries the issue number, so a log can be grepped for it" || no "(3b)" "$out"
[ "$(printf '%s\n' "$out" | grep -cE 'cm059-editor|ical-server|ostler_hygiene')" -gt 0 ] \
    && ok "(3c) it names the blast radius: the services with no venv of their own" || no "(3c)" "$out"
[ "$(printf '%s\n' "$out" | grep -c 'NO credential')" -gt 0 ] \
    && ok "(3d) and says what that MEANS, not just that a file is missing" || no "(3d)" "$out"

echo
echo "ARM 4: THE MUTANT. The pre-fix block must be SILENT on the same input."
out="$(run "$MUTANT" "/opt/homebrew/bin/python3")"
if [ "$(printf '%s\n' "$out" | grep -c '^WARN ')" -gt 0 ]; then
    no "(4) the pre-fix block ALSO warned, so arm 2 proves nothing"
else
    ok "(4) the pre-fix block says nothing at all: the silence, reproduced"
fi

echo
echo "=== ${PASS} passed / ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
