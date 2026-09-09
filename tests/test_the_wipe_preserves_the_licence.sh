#!/usr/bin/env bash
# The store wipe must not destroy the licence the next install requires.
#
# MEASURED 2026-09-09 on the v1.0.82 walk. The shipped uninstaller removes
# everything under ~/.ostler except power.conf (install.sh:21732). The licence
# lives at ~/.ostler/license/license.json (install.sh:1970). ttywalk's licence
# preflight runs BEFORE the wipe block, so it passes; the wipe then deletes the
# licence; and the install that follows dies at ERR-02-LICENCE-REQUIRED with the
# box already wiped and no uninstaller left to retry with. The walk observed
# exactly that shape on its second priming attempt.
#
# It had never fired before because no earlier wipe had ever found a shipped
# uninstaller to run. Under the WIPE decision of 2026-09-09 every walk wipes, so
# without the save-and-restore every walk hits it.
#
# WHAT THIS TESTS, and what it deliberately does not. It extracts the two real
# limbs from ttywalk.sh BY CONTENT and runs them either side of the uninstaller's
# ACTUAL removal command, taken from install.sh:21732. It does not stub docker or
# the rest of the wipe block: the question here is whether the licence survives a
# find that deletes everything under ~/.ostler, and whether the restore happens
# after the residue count rather than before it.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${REPO}/scripts/ttywalk.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

[ -f "$SUBJECT" ] || { echo "CANNOT-RUN: no ttywalk.sh at ${SUBJECT}" >&2; exit 2; }
WORK="$(mktemp -d)" || { echo "CANNOT-RUN: no working directory" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# --- extract the two limbs BY CONTENT, so a moved block still tests ----------
SAVE="${WORK}/save.sh"
awk '
    /^        _LIC="\$HOME\/\.ostler\/license\/license\.json"$/ { f = 1 }
    f { print; if ($0 ~ /no licence to preserve at/) { g = 1 } }
    g && /^        fi$/ { exit }
' "$SUBJECT" > "$SAVE"

RESTORE="${WORK}/restore.sh"
awk '
    /^        if \[ -n "\$_LIC_BAK" \] && \[ -s "\$_LIC_BAK" \]; then$/ { f = 1 }
    f { print; if ($0 ~ /already refuses a walk/) { g = 1 } }
    g && /^        fi$/ { exit }
' "$SUBJECT" > "$RESTORE"

for part in "$SAVE" "$RESTORE"; do
    if ! /usr/bin/grep -q '_LIC' "$part"; then
        echo "CANNOT-RUN: could not extract $(basename "$part") from ${SUBJECT}." >&2
        echo "  Scanning nothing must not read as a passing test." >&2
        exit 2
    fi
    if ! bash -n "$part" 2>/dev/null; then
        echo "CANNOT-RUN: extracted $(basename "$part") does not parse; the extraction is wrong." >&2
        exit 2
    fi
done

# The uninstaller's REAL removal, install.sh:21732, verbatim in shape.
UNINSTALL='find "${HOME}/.ostler" -mindepth 1 -maxdepth 1 ! -name "power.conf" -exec rm -rf {} + 2>/dev/null || true
rmdir "${HOME}/.ostler" 2>/dev/null || true'

# The residue predicate the wipe block uses, so arm 2 measures the real thing.
RESIDUE='find "$HOME/.ostler" -mindepth 1 -type f ! -path "$HOME/.ostler/power.conf" 2>/dev/null | grep -c . || true'

_mkhome() {
    local h="${WORK}/$1"; rm -rf "$h"
    mkdir -p "${h}/.ostler/license" "${h}/.ostler/bin" "${h}/.ostler/services/cm019"
    printf '%s' "$h"
}

# Run: save, uninstall, MEASURE RESIDUE, restore. Echoes "<residue>|<output>".
_run() { # $1 = HOME, $2 = restore limb to use
    local h="$1" r="$2" w="${WORK}/run.sh"
    { cat "$SAVE"
      printf '%s\n' "$UNINSTALL"
      printf '_RESIDUE_AT_COUNT=$(%s)\n' "$RESIDUE"
      printf 'echo "RESIDUE_AT_COUNT=${_RESIDUE_AT_COUNT}"\n'
      cat "$r"
    } > "$w"
    HOME="$h" bash "$w" 2>&1
}

printf 'THE WIPE PRESERVES THE LICENCE\n\n'

echo "-- 1. MUST PASS: a licence present before the wipe is present after it --"
H="$(_mkhome keep)"
printf '{"licence":"synthetic-walk-fixture","id":"not-a-real-key"}\n' > "${H}/.ostler/license/license.json"
BEFORE_SUM="$(shasum -a 256 "${H}/.ostler/license/license.json" | cut -d' ' -f1)"
: > "${H}/.ostler/bin/ostler-uninstall"
OUT="$(_run "$H" "$RESTORE")"
if [ -s "${H}/.ostler/license/license.json" ]; then
    AFTER_SUM="$(shasum -a 256 "${H}/.ostler/license/license.json" | cut -d' ' -f1)"
    if [ "$BEFORE_SUM" = "$AFTER_SUM" ]; then
        ok "the licence survives the wipe and is BYTE-IDENTICAL"
    else
        bad "the licence survives but its bytes changed"
    fi
else
    bad "THE LICENCE WAS DESTROYED BY THE WIPE. The next install dies at ERR-02: ${OUT}"
fi

echo "-- and the rest of ~/.ostler really was removed, or arm 1 proves nothing --"
if [ -d "${H}/.ostler/services/cm019" ]; then
    bad "the simulated uninstaller removed nothing; arm 1 is vacuous"
else
    ok "the uninstaller really did empty ~/.ostler, so surviving meant something"
fi

echo "-- 2. THE RESIDUE COUNT READS 0 AT THE MOMENT IT RUNS --"
# The restore must happen AFTER the count. If it ran before, the harness would
# plant a file and then fail the walk for finding it.
case "$OUT" in
    *RESIDUE_AT_COUNT=0*) ok "residue is 0 when the check runs: the restore is after the count" ;;
    *)                    bad "residue was not 0 at the count: $(printf '%s' "$OUT" | tr '\n' ' ')" ;;
esac

echo "-- and the restore reported itself in words --"
case "$OUT" in
    *"licence restored"*) ok "the restore says so, with a byte count, so a log can be audited" ;;
    *)                    bad "the restore printed nothing: $(printf '%s' "$OUT" | tr '\n' ' ')" ;;
esac

echo "-- 3. NO LICENCE: it says so and does not invent one --"
H2="$(_mkhome nolicence)"
: > "${H2}/.ostler/bin/ostler-uninstall"
OUT2="$(_run "$H2" "$RESTORE")"
if [ -e "${H2}/.ostler/license/license.json" ]; then
    bad "a licence file appeared where none existed"
else
    case "$OUT2" in
        *"no licence to preserve"*) ok "an absent licence is reported and nothing is fabricated" ;;
        *)                          bad "absence was not reported: $(printf '%s' "$OUT2" | tr '\n' ' ')" ;;
    esac
fi

echo "-- 4. MUTATION: with the restore disabled, arm 1 MUST fail --"
MUT="${WORK}/restore_mutant.sh"
sed 's|^            if cp "\$_LIC_BAK" "\$_LIC" 2>/dev/null; then|            if false; then|' "$RESTORE" > "$MUT"
if [ "$(/usr/bin/grep -c 'if false; then' "$MUT")" -lt 1 ]; then
    bad "MUTATION DID NOT APPLY, so the arm below proves nothing"
else
    ok "the mutant really has the restore disabled (the injection landed)"
    H3="$(_mkhome mutant)"
    printf '{"licence":"synthetic-walk-fixture","id":"not-a-real-key"}\n' > "${H3}/.ostler/license/license.json"
    : > "${H3}/.ostler/bin/ostler-uninstall"
    _run "$H3" "$MUT" >/dev/null 2>&1
    if [ -s "${H3}/.ostler/license/license.json" ]; then
        bad "the licence survived even with the restore disabled; arm 1 is not testing the restore"
    else
        ok "MUST-FAIL: without the restore the licence is destroyed, so the restore is load-bearing"
    fi
fi

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
