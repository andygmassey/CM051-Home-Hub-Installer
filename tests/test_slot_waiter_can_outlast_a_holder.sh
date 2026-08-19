#!/usr/bin/env bash
# A waiter's patience must be able to outlast a holder's right to the slot.
#
# MEASURED on the v1.0.33 box, 2026-08-17. Nothing was missing: the waiters
# dir, max-hold and starve-after all existed and all behaved as written. The
# RATIO between two defaults guaranteed starvation.
#
#   MAX_HOLD 900s  vs  WAIT 75s   ->  a waiter gives up 12 times over before
#                                     the holder is ever obliged to yield
#
# Observed: email-bundle holding with 895s remaining while imessage-bundle got
# 4s. Twelve contentions logged; whatsapp, imessage and spoken all starved.
#
# This is the invariant, not the numbers: whatever the values, a waiter that
# keeps asking must be able to outlive a holder. Tuning either knob without
# the other reopens the defect.
set -uo pipefail
SH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/install.sh"
PASS=0; FAIL=0
ok(){ printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }
[[ -f "$SH" ]] || { echo "CANNOT RUN: no install.sh at $SH"; exit 2; }

val(){ grep -oE "_OSTLER_SLOT_$1=\"\\\$\{OSTLER_SLOT_${1}_SECS:-[0-9]+\}\"" "$SH" \
        | head -1 | grep -oE '[0-9]+\}' | tr -d '}'; }
HOLD="$(val MAX_HOLD)"; WAIT="$(val WAIT)"; STARVE="$(val STARVE_AFTER)"

# Zero-denominator guard: if the greps found nothing we must not pass on "".
if [[ -z "$HOLD" || -z "$WAIT" || -z "$STARVE" ]]; then
    echo "CANNOT RUN: could not read one of the defaults (hold='$HOLD' wait='$WAIT' starve='$STARVE')."
    echo "  The predicate is wrong, not the tree. Refusing to report a verdict."
    exit 2
fi
echo "  read: MAX_HOLD=${HOLD}s WAIT=${WAIT}s STARVE_AFTER=${STARVE}s"

# 1. THE INVARIANT. A waiter polls and re-asks, so its patience must not be
#    an order of magnitude under the holder's right, or it can never win.
if [[ "$HOLD" -le $(( WAIT * 4 )) ]]; then
    ok "a holder's max hold (${HOLD}s) is within 4x a waiter's patience (${WAIT}s)"
else
    no "MAX_HOLD ${HOLD}s is more than 4x WAIT ${WAIT}s -- a waiter can never outlast a holder"
fi

# 2. The starvation escalation must fire inside a plausible install, not hours later.
if [[ "$STARVE" -le 3600 ]]; then
    ok "starvation is declared within an hour (${STARVE}s), not after the fact"
else
    no "STARVE_AFTER ${STARVE}s fires long after the install ends -- nobody can act on it"
fi

# 3. Positive control: the predicate must DETECT the shipped-broken ratio.
if [[ 900 -gt $(( 75 * 4 )) ]]; then
    ok "positive control: the 900/75 ratio that shipped WOULD fail this test"
else
    no "positive control failed -- this test cannot see the defect it guards"
fi

echo; echo "  $PASS passed, $FAIL failed"; [[ $FAIL == 0 ]] || exit 1
echo "A WAITER CAN OUTLAST A HOLDER"
