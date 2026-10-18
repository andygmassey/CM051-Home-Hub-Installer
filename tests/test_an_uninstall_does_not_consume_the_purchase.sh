#!/usr/bin/env bash
# UNINSTALLING MUST NOT DESTROY THE THING THE CUSTOMER PAID FOR.
#
# Andy decided this on 2026-09-10: the licence is kept across an uninstall.
#
# THE DEFECT, measured 2026-09-16 on origin/main. The generated uninstaller
# emptied ~/.ostler with
#
#     find "${HOME}/.ostler" -mindepth 1 -maxdepth 1 ! -name 'power.conf' \
#          -exec rm -rf {} +
#
# sparing exactly one entry. The licence lives at
# ~/.ostler/license/license.json, so it went with everything else. The
# customer's purchase was consumed by an uninstall that never mentioned it,
# and the reinstall that followed refused at ERR-02-LICENCE-REQUIRED with
# nothing left on the box to retry against. Their only route back was to find
# the welcome email again.
#
# It was not an oversight anyone could have spotted by reading the
# uninstaller: `licen[cs]e`, case-insensitive, had ZERO matches anywhere in
# its body. CONTROL, same pattern, same command, wider subject: 202 matches
# across install.sh as a whole. The pattern works. The uninstaller simply had
# no concept of a licence.
#
# HOW THIS TEST WORKS, and the one thing it refuses to do. It extracts the
# REAL removal command out of install.sh by content and runs it against a
# seeded tree. It does NOT hardcode a copy of that command: a test carrying
# its own copy of the subject passes forever after the subject changes.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${REPO}/install.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

[ -f "$SUBJECT" ] || { echo "CANNOT-RUN: no install.sh at ${SUBJECT}" >&2; exit 2; }
WORK="$(mktemp -d)" || { echo "CANNOT-RUN: no working directory" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# --- extract the REAL removal, by content ------------------------------------
# One line, and it is the line that does the damage. Taken with -F so the
# `grep` on PATH (ugrep on some of these machines) cannot read the braces as
# an interval expression and return a false zero.
REMOVE="${WORK}/remove.sh"
/usr/bin/grep -F 'find "${HOME}/.ostler" -mindepth 1 -maxdepth 1' "$SUBJECT" \
    | /usr/bin/grep -v '^[[:space:]]*#' > "$REMOVE"

_n="$(/usr/bin/grep -c . "$REMOVE" || true)"
if [ "${_n:-0}" -ne 1 ]; then
    echo "CANNOT-RUN: expected exactly one uninstaller removal line, found ${_n}." >&2
    echo "  Testing the wrong line, or none, must not read as a pass." >&2
    exit 2
fi
if ! bash -n "$REMOVE" 2>/dev/null; then
    echo "CANNOT-RUN: the extracted removal does not parse; the extraction is wrong." >&2
    exit 2
fi

# Seed a tree with the shape a real install leaves behind.
_mkhome() {
    local h="${WORK}/$1"; rm -rf "$h"
    mkdir -p "${h}/.ostler/license" "${h}/.ostler/bin" \
             "${h}/.ostler/config" "${h}/.ostler/services/cm019" \
             "${h}/.ostler/assistant-config"
    printf '%s\n' '{"version":1,"license_id":"synthetic-fixture"}' > "${h}/.ostler/license/license.json"
    : > "${h}/.ostler/power.conf"
    : > "${h}/.ostler/config/.env"
    : > "${h}/.ostler/bin/ostler-uninstall"
    : > "${h}/.ostler/services/cm019/marker"
    : > "${h}/.ostler/assistant-config/config.toml"
    printf '%s' "$h"
}

_run_remove() { # $1 = HOME, $2 = removal script
    HOME="$1" bash "$2" 2>&1
}

printf 'AN UNINSTALL DOES NOT CONSUME THE PURCHASE\n\n'

echo "-- 1. MUST PASS: the licence is still there, byte for byte, afterwards --"
H="$(_mkhome keep)"
BEFORE="$(shasum -a 256 "${H}/.ostler/license/license.json" | cut -d' ' -f1)"
_run_remove "$H" "$REMOVE" >/dev/null 2>&1
if [ -s "${H}/.ostler/license/license.json" ]; then
    AFTER="$(shasum -a 256 "${H}/.ostler/license/license.json" | cut -d' ' -f1)"
    if [ "$BEFORE" = "$AFTER" ]; then
        ok "the licence survives the uninstall and is BYTE-IDENTICAL"
    else
        bad "the licence survives but its bytes changed; a reinstall would refuse on the signature"
    fi
else
    bad "THE UNINSTALL DESTROYED THE LICENCE. The customer has paid and cannot reinstall."
fi

echo "-- and the uninstall really did empty the rest, or arm 1 proves nothing --"
# THE ANTI-VACUITY CONTROL. A removal command that removed nothing would
# satisfy arm 1 perfectly while doing no uninstalling at all.
SURVIVORS=0
for p in "${H}/.ostler/config/.env" "${H}/.ostler/services/cm019/marker" \
         "${H}/.ostler/bin/ostler-uninstall" "${H}/.ostler/assistant-config/config.toml"; do
    [ -e "$p" ] && SURVIVORS=$((SURVIVORS+1))
done
if [ "$SURVIVORS" -eq 0 ]; then
    ok "all 4 non-preserved files were removed, so surviving meant something"
else
    bad "${SURVIVORS} of 4 files that should have gone survived; this is not an uninstall"
fi

echo "-- 2. the OTHER declared keep is still kept; this change added one, not swapped one --"
if [ -e "${H}/.ostler/power.conf" ]; then
    ok "power.conf is still preserved alongside the licence"
else
    bad "power.conf was destroyed; the licence keep replaced the hub power keep"
fi

echo "-- 3. THE CUSTOMER IS TOLD. The printed contract names the licence --"
# The subject here is a person reading their terminal, so read the lines the
# uninstaller actually prints rather than the find predicate.
CONTRACT="${WORK}/contract.sh"
awk '
    /^echo "  This will remove:"$/ { f = 1 }
    f { print }
    f && /Automatic login/         { g = 1 }
    g && /^echo ""$/               { exit }
' "$SUBJECT" > "$CONTRACT"
if ! /usr/bin/grep -q 'This will NOT remove' "$CONTRACT"; then
    bad "CANNOT-CHECK: the printed contract did not extract, so arm 3 proves nothing"
else
    CONTRACT_OUT="$(bash "$CONTRACT" 2>&1)"
    # It must appear in the KEEP half, not merely somewhere in the text.
    KEEP_HALF="$(printf '%s\n' "$CONTRACT_OUT" | awk '/This will NOT remove/ { f = 1 } f { print }')"
    if printf '%s' "$KEEP_HALF" | /usr/bin/grep -qi 'licen[cs]e'; then
        ok "the will-NOT-remove half of the printed contract names the licence"
    else
        bad "the uninstall keeps the licence and never tells the customer, which is a surprise either way"
    fi
    # And it must tell them how to remove it, or the keep is imposed on them.
    if printf '%s' "$KEEP_HALF" | /usr/bin/grep -q 'rm -rf ~/.ostler/license'; then
        ok "and gives the customer the command to remove it themselves"
    else
        bad "the customer is told the licence is kept but not how to get rid of it"
    fi
    # CONTROL on the extraction: the REMOVE half must be non-empty too, or the
    # awk above captured something that is not the contract.
    if printf '%s' "$CONTRACT_OUT" | /usr/bin/grep -q 'Docker containers'; then
        ok "CONTROL: the extracted contract really is the contract (its remove half is intact)"
    else
        bad "CONTROL FAILED: the extracted text has no remove half; arm 3 read the wrong block"
    fi
fi

echo "-- 4. MUTATION: with the licence exclusion removed, arm 1 MUST fail --"
MUT="${WORK}/remove_mutant.sh"
/usr/bin/sed "s/ ! -name 'license'//" "$REMOVE" > "$MUT"
if [ "$(/usr/bin/grep -c -- "-name 'license'" "$MUT" || true)" -ne 0 ]; then
    bad "MUTATION DID NOT APPLY, so the arm below proves nothing"
else
    ok "the mutant really has the licence exclusion removed (the injection landed)"
    H2="$(_mkhome mutant)"
    _run_remove "$H2" "$MUT" >/dev/null 2>&1
    if [ -e "${H2}/.ostler/license/license.json" ]; then
        bad "the licence survived WITHOUT the exclusion; arm 1 is not testing the exclusion"
    else
        ok "MUST-FAIL: without the exclusion the licence is destroyed, so the exclusion is load-bearing"
    fi
fi

echo "-- 5. the keep is by NAME AT THE TOP LEVEL, which is what the find can express --"
# Stated rather than glossed. `-maxdepth 1 ! -name 'license'` spares the
# top-level entry called `license` and nothing deeper, exactly as it spares
# `power.conf`. A stray directory called `license` nested further down is
# removed like anything else, which is the behaviour we want.
H3="$(_mkhome deep)"
mkdir -p "${H3}/.ostler/data/license"
: > "${H3}/.ostler/data/license/not-a-licence.json"
_run_remove "$H3" "$REMOVE" >/dev/null 2>&1
if [ -e "${H3}/.ostler/data/license/not-a-licence.json" ]; then
    bad "a nested directory called license was spared; the keep is wider than intended"
else
    ok "a nested 'license' directory is removed: only the top-level engine-zone path is kept"
fi

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
