#!/usr/bin/env bash
# test_settling_contacts_reaches_100_when_sync_finished.sh
#
# Walk #16 console (Andy): the settling bar "always seems to be ~80-odd%".
# Measured on the box: contacts.json read 2381 of 2425 and never moved. The
# contact sync had FINISHED: 2381 imported, 44 skipped. install.sh reported
# done=imported against a total measured from the address book, so a finished
# channel could never reach 100%.
#
# This test runs install.sh's own contacts-count block with a stubbed
# settling_report_measured and asserts the DONE it reports:
#   arm 1  finished sync, 2381 imported + 44 skipped   -> done 2425
#   arm 2  finished sync with an errors LIST of 3       -> done counts them
#   arm 3  TIMED-OUT sync (did not see every card)      -> done = imported only
#   arm 4  malformed JSON                               -> the zero branch (0 of 0)
# Red on main: arm 1 reports 2381 and arm 2 reports imported only.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
INSTALL_SH="$HERE/../install.sh"
[ -r "$INSTALL_SH" ] || { echo "FAIL: install.sh not found"; exit 1; }

# The block runs from the count parse through the settling if/else and its fi.
BLOCK="$(awk '
    /_HYDRATE_CONTACTS_COUNT="\$\($/ && !s { s=1 }
    s { print }
    s && /settling_report contacts 0 0 true/ { z=1; next }
    z && /^    fi$/ { exit }
' "$INSTALL_SH")"
case "$BLOCK" in
    *settling_report_measured\ contacts*) echo "PASS: extracted the contacts-count block ($(printf '%s\n' "$BLOCK" | wc -l | tr -d ' ') lines)" ;;
    *) echo "FAIL: could not extract the contacts-count block from install.sh"; exit 1 ;;
esac

fails=0
run_arm() {
    local label="$1" json="$2" timed_out="$3" want="$4" got
    got="$(
        _HYDRATE_CONTACTS_JSON="$json"
        _HYDRATE_CONTACTS_TIMED_OUT="$timed_out"
        settling_report_measured() { printf '%s' "$2"; }
        settling_report() { printf 'zero:%s' "$2"; }
        eval "$BLOCK"
    )"
    if [ "$got" = "$want" ]; then
        echo "PASS: $label -> done=$got"
    else
        echo "FAIL: $label -> done=$got (want $want)"
        fails=$((fails + 1))
    fi
}

run_arm "finished sync, 2381 imported + 44 skipped" \
    '{"imported": 2381, "skipped": 44, "errors": [], "deleted": 0}' false 2425
run_arm "finished sync, errors list of 3" \
    '{"imported": 100, "skipped": 2, "errors": ["a", "b", "c"], "deleted": 0}' false 105
run_arm "timed-out sync reports imported only" \
    '{"imported": 2381, "skipped": 44, "errors": [], "deleted": 0}' true 2381
run_arm "malformed JSON reports nothing as done" \
    'not json' false 'zero:0'

echo "denominator: 4 arms through install.sh's own block"
[ "$fails" -eq 0 ] || exit 1
exit 0
