#!/usr/bin/env bash
# One store must not be guarded by two budgets, and the collection budget must
# never be the smaller one.
#
# WHY THIS EXISTS. MEASURED, twice, on the Mini 16, both against a 120s budget:
#
#   v1.0.67  archie   cold    cm019_setup ERROR at 132s
#   v1.0.68  archie2  VIRGIN  cm019_setup ERROR at 136s rc=1
#                             DONE status=fail ERR-14-STORE-NOT-READY-FOR-IMPORT
#                             "missing: people conversations preferences
#                              evernote_knowledge"
#                             and graph_db_start had itself taken 327s
#
# The second was a HUMAN walk on a virgin account -- the normal first-install
# case, not an edge case. The customer was told "Your data was not imported".
# Nothing was lost, because the refusal is deliberate and correct, but the
# install failed on a TIMER rather than a fault.
#
# 🔴 THE DEFECT WAS NOT THAT 120 IS SMALL. IT IS THAT ONE DEPENDENCY HAD TWO
# BUDGETS 2.5x APART. Qdrant is waited for twice:
#
#   _QDRANT_READY_CAP              graph_db_start     300s   passed both walks
#   _QDRANT_COLLECTIONS_READY_CAP  cm019_setup        120s   FAILED both walks
#
# The larger one never failed and the smaller one always did. A second budget
# for the same store, set lower, is a trap that only fires on slow boxes --
# which is to say, on customer boxes.
#
# This asserts the RELATION, not the value. Either may be tuned; the collection
# budget may never be tightened below the readiness budget again, because the
# collections cannot exist before the store does.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${REPO}/install.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

[ -f "$SUBJECT" ] || { echo "CANNOT-RUN: no install.sh at ${SUBJECT}" >&2; exit 2; }

# Read the DEFAULTS out of the two top-level assignments. Anchored to line
# start so a mention inside a comment or a function cannot be picked up.
_default_of() {  # <CAP name> -> the numeric default, or empty
    /usr/bin/sed -n "s/^${1}=\"\\\${[A-Z0-9_]*:-\\([0-9][0-9]*\\)}\".*/\\1/p" "$SUBJECT" | head -1
}

READY="$(_default_of _QDRANT_READY_CAP)"
COLL="$(_default_of _QDRANT_COLLECTIONS_READY_CAP)"

if [ -z "$READY" ] || [ -z "$COLL" ]; then
    echo "CANNOT-RUN: could not read both caps from ${SUBJECT}." >&2
    echo "  _QDRANT_READY_CAP='${READY:-<none>}' _QDRANT_COLLECTIONS_READY_CAP='${COLL:-<none>}'" >&2
    echo "  A cap that cannot be read has not been checked. If either was renamed," >&2
    echo "  this file must be updated rather than left scanning for a dead name." >&2
    exit 2
fi

ok "both caps are readable as top-level defaults (ready=${READY}s collections=${COLL}s)"

# THE PROPERTY. Collections cannot exist before the store does, so the budget
# that waits for the collections must not be shorter than the one that waits
# for the store.
if [ "$COLL" -ge "$READY" ]; then
    ok "the collection budget (${COLL}s) is NOT shorter than the store budget (${READY}s)"
else
    bad "the collection budget is ${COLL}s but the store budget is ${READY}s. The collections cannot exist before the store, so this only ever fires on a slow box -- which is to say a customer box. That is ERR-14-STORE-NOT-READY-FOR-IMPORT, measured twice."
fi

# The two observed cold failures must both be inside the budget now, or the
# raise did not actually address what it was raised for.
for obs in 132 136; do
    if [ "$COLL" -gt "$obs" ]; then
        ok "the ${obs}s cold observation now fits inside the ${COLL}s budget"
    else
        bad "a measured cold failure at ${obs}s is still outside the ${COLL}s budget"
    fi
done

# The non-numeric fallback must not silently reinstate a value we have twice
# proved insufficient. An operator typo must not be worse than no override.
_fallbacks="$(/usr/bin/grep -E '^[[:space:]]*_QDRANT_COLLECTIONS_READY_CAP=[0-9]+$' "$SUBJECT" | /usr/bin/sed 's/.*=//')"
if [ -z "$_fallbacks" ]; then
    bad "no numeric fallback assignment found; the non-numeric-override branch may have moved"
else
    _low=0
    for v in $_fallbacks; do [ "$v" -lt "$COLL" ] && _low=$((_low + 1)); done
    if [ "$_low" -eq 0 ]; then
        ok "every hard-coded fallback matches the default, so an operator typo cannot reinstate the old budget"
    else
        bad "${_low} fallback assignment(s) are below the ${COLL}s default. A bad override would silently restore the value that failed twice."
    fi
fi

# ── NEGATIVE CONTROL, pinned to the tree that SHIPPED the 120s budget ────
# 647c98a5 is CM051 main at the time the v1.0.68 virgin walk failed. Pinned to
# a fixed sha, never a branch: a control reading origin/main inverts the moment
# this merges.
_CONTROL_SHA="647c98a5"
echo "── negative control: ${_CONTROL_SHA} (the tree whose install failed on a virgin Mac) ──"
CTL="$(mktemp)" || { echo "CANNOT-RUN: no temp file" >&2; exit 2; }
trap 'rm -f "$CTL"' EXIT
if ! git -C "$REPO" show "${_CONTROL_SHA}:install.sh" > "$CTL" 2>/dev/null; then
    echo "CANNOT-RUN: control blob ${_CONTROL_SHA}:install.sh is unreadable." >&2
    echo "  A shallow clone cannot see it, and scanning nothing must not read" >&2
    echo "  as a passing control." >&2
    exit 2
fi

_ctl_default_of() {
    /usr/bin/sed -n "s/^${1}=\"\\\${[A-Z0-9_]*:-\\([0-9][0-9]*\\)}\".*/\\1/p" "$CTL" | head -1
}
C_READY="$(_ctl_default_of _QDRANT_READY_CAP)"
C_COLL="$(_ctl_default_of _QDRANT_COLLECTIONS_READY_CAP)"

# CONTROL ON THE CONTROL: the reader must work on the old tree too, or a
# missing value below would mean "could not parse" rather than "was smaller".
if [ -n "$C_READY" ] && [ -n "$C_COLL" ]; then
    ok "CONTROL ON THE CONTROL: both caps are readable at ${_CONTROL_SHA} (ready=${C_READY}s collections=${C_COLL}s), so the parser is not the variable"
else
    bad "could not read the caps at ${_CONTROL_SHA}; this control proves nothing"
fi

if [ -n "$C_COLL" ] && [ -n "$C_READY" ] && [ "$C_COLL" -lt "$C_READY" ]; then
    ok "control ${_CONTROL_SHA}: collections ${C_COLL}s < store ${C_READY}s, reproducing the split budget that failed the virgin walk"
else
    bad "control ${_CONTROL_SHA} does not show the split budget (collections=${C_COLL} store=${C_READY}); this harness is not measuring the defect"
fi

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
