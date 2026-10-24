#!/usr/bin/env bash
# tests/test_upgrade_payload_carries_what_the_upgrade_refreshes.sh
#
# An _upg_refresh_* function that looks for services/<x> in the upgrade payload is
# a silent no-op if gui/Makefile's stage-payload never puts services/<x> there.
# That is exactly what happened to cm019: the payload carried doctor, knowledge and
# cm048 only, so a refresh written against the payload would have logged
# "not in payload" and done nothing on every real box.
#
#   arm 1  every services/<x> the upgrade block names has a `cp ... "$$PAYLOAD/services/<x>"`
#          in stage-payload AND an entry in its post-copy `req` loop AND a source
#          that exists in this checkout.
#   arm 2  MUTANT: with the cp line for one tree removed from a copy of the Makefile
#          the check fails, so arm 1 is measuring the Makefile.
#   arm 3  the payload size stays under the 500 MB cap with the new trees (sources
#          measured; the cap check itself lives in stage-payload).
# Exit: 0 pass, 1 fail, 2 cannot-run.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
INSTALL_SH="${INSTALL_SH:-${REPO}/install.sh}"
MAKEFILE="${MAKEFILE:-${REPO}/gui/Makefile}"
[ -r "$INSTALL_SH" ] && [ -r "$MAKEFILE" ] || { echo "CANNOT-RUN: install.sh or gui/Makefile unreadable"; exit 2; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }
TMP="$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd)/payload-carries.XXXXXX")" || { echo "CANNOT-RUN: mktemp"; exit 2; }
trap 'rm -rf "$TMP"' EXIT

# name -> source in this checkout (relative to the repo root)
declare_src() {
    case "$1" in
        doctor) echo vendor/doctor/agent ;;
        knowledge) echo vendor/cm024_knowledge ;;
        cm048) echo vendor/cm048_pipeline ;;
        cm019) echo vendor/cm019_preferences ;;
        assistant_api) echo vendor/cm041/assistant_api ;;
        pwg_privacy.py) echo vendor/cm041/pwg_privacy.py ;;
        ostler_hygiene) echo vendor/cm041/ostler_hygiene ;;
        context-refresh) echo context-refresh ;;
        *) echo "" ;;
    esac
}

UPG="$(awk '/^if \[\[ "\$\{OSTLER_UPGRADE_MODE:-0\}" == "1"/,/^fi$/' "$INSTALL_SH")"
[ -n "$UPG" ] || { echo "CANNOT-RUN: cannot isolate the upgrade block"; exit 2; }
NAMES="$(printf '%s\n' "$UPG" | grep -v '^[[:space:]]*#' \
    | grep -oE '(_UPG_PAYLOAD\}/services/|_upg_payload_dir services/)[A-Za-z0-9_.-]+' \
    | sed -E 's#.*services/##' | sort -u)"
N="$(printf '%s\n' "$NAMES" | grep -c . || true)"
[ "${N:-0}" -ge 5 ] || { echo "CANNOT-RUN: the upgrade block names only ${N:-0} payload trees; the scan is blind"; exit 2; }
# pwg_privacy.py is copied from services/ as a file, named in a [[ -f ]] test
NAMES="$(printf '%s\npwg_privacy.py\n' "$NAMES" | sort -u)"
# KNOWN GAP, found by this very scan and NOT fixed here: _upg_refresh_cm048 looks
# for services/ostler_security in the payload and the payload does not carry it, so
# the cm048 refresh logs "ostler_security dep is not [in the payload]; skipping" on
# every real upgrade and cm048 fixes never reach an upgraded box. Enabling it turns
# on a wholesale cm048 venv rebuild nobody has run on an upgrade: a 118 decision.
KNOWN_GAPS="ostler_security"
NAMES="$(printf '%s\n' $NAMES | grep -vxF "$KNOWN_GAPS" || true)"
echo "  note known gap (reported, not fixed): services/${KNOWN_GAPS} is referenced by the upgrade block and is NOT in the payload"

check_makefile() { # $1 = Makefile -> prints FAIL lines
    local mk="$1" n src
    for n in $NAMES; do
        src="$(declare_src "$n")"
        [ -n "$src" ] || { echo "no source mapping for services/${n} (add it to declare_src)"; continue; }
        grep -qE "cp (-R )?\"\\\$\\\$[A-Z0-9_]+\" \"\\\$\\\$PAYLOAD/services/${n}\"" "$mk" \
            || echo "stage-payload never copies anything to services/${n}"
        grep -qE "for req in .*services/${n}[ /;]" "$mk" || echo "the post-copy req loop does not check services/${n}"
    done
}

echo "arm 1: every services/<x> the upgrade refreshes is in the payload"
OUT="$(check_makefile "$MAKEFILE")"
if [ -z "$OUT" ]; then ok "all $(printf '%s\n' "$NAMES" | grep -c .) payload trees are copied and req-checked: $(echo $NAMES)"; else
    while IFS= read -r l; do bad "$l"; done <<< "$OUT"; fi
for n in $NAMES; do
    src="$(declare_src "$n")"
    [ -n "$src" ] && [ -e "${REPO}/${src}" ] || bad "source for services/${n} missing in this checkout (${src:-unmapped})"
done

echo "arm 2: mutant, the cm019 copy removed from the Makefile"
grep -vE 'PAYLOAD/services/cm019"' "$MAKEFILE" > "${TMP}/Makefile.mut"
cmp -s "${TMP}/Makefile.mut" "$MAKEFILE" && { echo "CANNOT-RUN: the mutant did not apply"; exit 2; }
if check_makefile "${TMP}/Makefile.mut" | grep -q 'services/cm019'; then ok "the check reds when cm019 is not copied into the payload"; else bad "mutant not caught"; fi

echo "arm 3: size"
KB=0
for n in $NAMES; do src="$(declare_src "$n")"; [ -e "${REPO}/${src}" ] && KB=$((KB + $(du -sk "${REPO}/${src}" | cut -f1))); done
if [ "$KB" -lt 204800 ]; then ok "the payload trees named here total ${KB} KB (cap is 500 MB for the whole payload, daemon included)"; else bad "the new trees add ${KB} KB"; fi

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
