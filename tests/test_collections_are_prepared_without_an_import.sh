#!/usr/bin/env bash
# #1820: the Qdrant collection pre-creation must run even when nothing is imported.
#
# WHY THIS EXISTS. _ostler_ensure_qdrant_collections used to have exactly ONE
# call site, nested inside `if [[ ${#_IMPORT_DIRS[@]} -gt 0 ... ]]`. So #606's
# pre-creation -- whose entire purpose is to make the collections exist when
# NO source data arrives -- was unreachable for the customer with no exports on
# day one. Measured on the v1.0.75 cold walk: the walk answered "n" to "Import
# these during install?", the branch never ran, ERR-14 never fired because the
# code never ran, and the install finished with conversations and
# evernote_knowledge absent (authenticated on the box: people 200,
# preferences 200, conversations 404, evernote_knowledge 404).
#
# The defect was invisible to every previous walk because a WARM box already
# carries the collections from an earlier run that did import.
#
# THIS TEST ASSERTS BEHAVIOUR, NOT TEXT. It extracts the guard region from the
# shipped install.sh, stubs the function, and runs it with an EMPTY import set.
# A grep for "the call exists" would pass on the broken version too, since the
# call existed all along -- in the wrong place.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$HERE/install.sh"
pass=0; fail=0
ok()  { printf '  [PASS] %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  [FAIL] %s\n' "$1"; fail=$((fail + 1)); }

echo "== collections are prepared even with nothing to import =="

# STRUCTURAL LIMB FIRST, because it is the one that fails LOUDLY on the defect.
# The broken version has the call ONLY at indentation 4, inside the branch. The
# fixed version has one at column 0. Measured on the mutant: without this limb
# the behavioural test could only report CANNOT-RUN (the extraction anchors on
# the hoisted line, which the defect does not have), and CANNOT-RUN is
# fail-closed but it does not SAY what is wrong.
n_toplevel="$(grep -c '^if ! _ostler_ensure_qdrant_collections; then$' "$SRC")"
if [ "$n_toplevel" -ge 1 ]; then
    ok "a TOP-LEVEL call exists, so the pre-creation is reachable without an import"
else
    bad "NO top-level call: _ostler_ensure_qdrant_collections is only reachable from inside a branch -- this is #1820"
fi
n_indented="$(grep -c '^[[:space:]]\{1,\}if ! _ostler_ensure_qdrant_collections; then$' "$SRC")"
if [ "$n_indented" -ge 1 ]; then
    ok "CONTROL: the in-branch fatal call survives too (ERR-14 path preserved)"
else
    bad "the in-branch ERR-14 call is GONE -- the import precondition was lost in the hoist"
fi


# The region under test: from the unconditional call down to the import guard.
region="$(awk '/^if ! _ostler_ensure_qdrant_collections; then$/{f=1} f{print} f&&/^if \[\[ \$\{#_IMPORT_DIRS\[@\]\} -gt 0/{exit}' "$SRC")"
if [ -z "$region" ]; then
    bad "could not extract the guard region -- the behavioural limb cannot run (the structural verdict above still stands)"
    echo; echo "$pass passed, $fail failed"; exit 1
fi
n_lines="$(printf '%s\n' "$region" | grep -c .)"
if [ "$n_lines" -gt 40 ]; then
    bad "extracted ${n_lines} lines, implausible for this region -- refusing to eval"
    echo; echo "$pass passed, $fail failed"; exit 2
fi

run_region() {   # run_region <n-import-dirs>  -> prints CALLED or NOT-CALLED
    local n="$1"
    bash -c '
        set -uo pipefail
        _CALLED=0
        _ostler_ensure_qdrant_collections() { _CALLED=1; return 0; }
        warn() { :; }
        _OSTLER_QDRANT_MISSING_COLLECTIONS=""
        IMPORT_SCRIPT=/bin/echo
        _IMPORT_DIRS=()
        [ "$1" -gt 0 ] && _IMPORT_DIRS=(/tmp)
        '"$region"'
            :
        fi
        [ "$_CALLED" -eq 1 ] && echo CALLED || echo NOT-CALLED
    ' _ "$n" 2>/dev/null
}

# THE DEFECT ITSELF: no import dirs, and the collections must still be prepared.
got="$(run_region 0)"
if [ "$got" = "CALLED" ]; then
    ok "with ZERO import dirs, the pre-creation still runs (this is #1820)"
else
    bad "with ZERO import dirs the pre-creation did NOT run (got '${got}') -- #1820 is back"
fi

# CONTROL: it must still run when there IS an import, or the test proves nothing
# about reachability -- a stub that never fires would pass the case above by
# always printing CALLED.
got="$(run_region 1)"
if [ "$got" = "CALLED" ]; then
    ok "CONTROL: with import dirs present it also runs, so the probe is not one-sided"
else
    bad "CONTROL FAILED: with import dirs it did not run either (got '${got}')"
fi

# NEGATIVE CONTROL on the harness: a region with the call removed must report
# NOT-CALLED, or CALLED means nothing.
region_broken="$(printf '%s\n' "$region" | grep -v '^if ! _ostler_ensure_qdrant_collections; then$' | grep -v '^    warn ' | grep -v '^fi$')"
got="$(region="$region_broken" bash -c '
    _CALLED=0
    _ostler_ensure_qdrant_collections() { _CALLED=1; return 0; }
    warn() { :; }
    _IMPORT_DIRS=()
    IMPORT_SCRIPT=/bin/echo
    [ "$_CALLED" -eq 1 ] && echo CALLED || echo NOT-CALLED' 2>/dev/null)"
if [ "$got" = "NOT-CALLED" ]; then
    ok "NEGATIVE CONTROL: with the call stripped, the harness reports NOT-CALLED"
else
    bad "NEGATIVE CONTROL FAILED: harness said '${got}' with the call stripped -- it cannot discriminate"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
