#!/usr/bin/env bash
#
# test_qdrant_membership_not_cardinality.sh -- #616 / #615
#
# =============================================================================
# THE DEFECT THIS FAILS ON
# =============================================================================
# install.sh promises to create four Qdrant collections:
#
#     people  conversations  preferences  evernote_knowledge
#
# and then asked ONE question about the result: `count -gt 0`. On the v1.0.60
# walk box the live store answers, measured 2026-09-03T05:20Z:
#
#     GET :6333/collections  ->  preferences, people, safari_history
#
# Three collections. `count -gt 0` is TRUE, so the install printed
# "Search index ready (3 collections)" while `conversations` and
# `evernote_knowledge` were absent, and while one collection it DOES have
# (safari_history) was never in the creation loop at all. The count was
# correct and the claim was false.
#
# A CARDINALITY TEST CANNOT SEE A MISSING MEMBER. Same shape as "23
# LaunchAgents are present" passing regardless of WHICH 23.
#
# =============================================================================
# WHAT THIS TEST DOES, AND WHY IT EXTRACTS RATHER THAN REIMPLEMENTS
# =============================================================================
# ARMS A-D drive the SHIPPING function, lifted verbatim out of install.sh with
# sed and eval'd, with `curl` shadowed by a stub. A reimplementation here would
# be a fixture encoding the answer instead of the property: it would pass
# forever even if install.sh were reverted. Extraction means arms A-D go blind
# the moment the function stops existing, and a blind arm FAILS (arm F).
#
# ARMS E-G read install.sh directly, because three of the ways this fix can be
# silently undone are not visible from the function alone:
#   E  the READY claim must be the LAST arm, reachable only when nothing is
#      missing. Move it first and the defect is back with the fix still present.
#   F  the declared array must be at TOP LEVEL. This is the live trap: the
#      pre-create loop runs only when the store came up ready, so an array
#      declared inside that branch is UNSET on the not-ready path, the checker
#      iterates an empty list, and it reports "nothing missing" on exactly the
#      install where everything is missing. An empty expectation is not a
#      satisfied one.
#   G  the creation loop and the checker must read the SAME array. Two
#      hand-maintained copies drift, and a checker reading a different list
#      from the creator answers a question nobody asked.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${HERE}/install.sh"

pass=0
fail=0
ok()   { printf '  [PASS] %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  [FAIL] %s\n' "$1"; fail=$((fail + 1)); }
blind(){ printf '  [CANNOT-RUN] %s -- this guard is blind, not clean\n' "$1"; fail=$((fail + 1)); }

if [ ! -f "$INSTALL_SH" ]; then
    blind "install.sh not found at ${INSTALL_SH}"
    printf 'qdrant membership: FAILED\n'
    exit 1
fi

# ---------------------------------------------------------------- extract ---
FN_SRC="$(sed -n '/^_initial_hydrate_qdrant_missing_required() {$/,/^}$/p' "$INSTALL_SH")"
if [ -z "$FN_SRC" ]; then
    blind "_initial_hydrate_qdrant_missing_required not found in install.sh (arms A-D cannot run)"
    printf 'qdrant membership: FAILED\n'
    exit 1
fi
eval "$FN_SRC"

# The declared list is read from install.sh too, so the test cannot drift into
# asserting against its own private copy of the expectation.
DECL_LINE="$(grep -n '^_OSTLER_REQUIRED_QDRANT_COLLECTIONS=(' "$INSTALL_SH" | head -1)"
if [ -z "$DECL_LINE" ]; then
    blind "_OSTLER_REQUIRED_QDRANT_COLLECTIONS is not declared at top level"
    printf 'qdrant membership: FAILED\n'
    exit 1
fi
eval "$(printf '%s' "${DECL_LINE#*:}")"

_INITIAL_HYDRATE_QDRANT="http://127.0.0.1:6333"

# ------------------------------------------------------------------- stub ---
# Shadows the real curl. _STUB_RC drives the CANNOT-RUN arms.
_STUB_RC=0
_STUB_BODY=""
curl() {
    if [ "$_STUB_RC" -ne 0 ]; then return "$_STUB_RC"; fi
    printf '%s' "$_STUB_BODY"
}

_body_for() {
    local out="" n
    for n in "$@"; do out="${out:+$out,}{\"name\": \"$n\"}"; done
    printf '{"result": {"collections": [%s]}}' "$out"
}

printf '== ARMS A-D: the shipping function, curl stubbed ==\n'

# ARM A -- THE ORIGINAL FAILING INPUT. The exact live state of the v1.0.60
# walk box. Must name BOTH missing collections.
_STUB_RC=0
_STUB_BODY="$(_body_for preferences people safari_history)"
A_OUT="$(_initial_hydrate_qdrant_missing_required)"
if [ "$(printf '%s' "$A_OUT" | grep -c 'conversations')" -gt 0 ] \
   && [ "$(printf '%s' "$A_OUT" | grep -c 'evernote_knowledge')" -gt 0 ]; then
    ok "A the real v1.0.60 store state names conversations AND evernote_knowledge"
else
    bad "A the real v1.0.60 store state did not name both missing collections (got: '${A_OUT}')"
fi
# ...and must NOT mis-accuse a collection that IS present.
if [ "$(printf '%s' "$A_OUT" | grep -c 'people')" -eq 0 ]; then
    ok "A a present collection (people) is not reported missing"
else
    bad "A reported a present collection as missing (got: '${A_OUT}')"
fi

# ARM B -- POSITIVE CONTROL. Without this the whole test passes if the
# function simply always returns every name.
_STUB_BODY="$(_body_for people conversations preferences evernote_knowledge)"
B_OUT="$(_initial_hydrate_qdrant_missing_required)"
if [ -z "$B_OUT" ]; then
    ok "B all four present returns empty (the check is not always-missing)"
else
    bad "B all four present should return empty, got: '${B_OUT}'"
fi

# ARM C -- CANNOT-RUN, not absence. An unreadable store must never be
# reported as "all four missing": that is a false accusation, and it trains
# the reader to ignore the warning.
_STUB_RC=22
_STUB_BODY=""
C_OUT="$(_initial_hydrate_qdrant_missing_required)"
if [ "$(printf '%s' "$C_OUT" | grep -c '^CANNOT-RUN:')" -gt 0 ]; then
    ok "C an unreadable store is CANNOT-RUN"
else
    bad "C an unreadable store must be CANNOT-RUN, got: '${C_OUT}'"
fi
if [ "$(printf '%s' "$C_OUT" | grep -c 'evernote_knowledge')" -eq 0 ]; then
    ok "C CANNOT-RUN does not masquerade as a list of missing collections"
else
    bad "C an unreadable store was reported as missing collections: '${C_OUT}'"
fi

# ARM D -- a 200 with an unexpected body is also CANNOT-RUN, not absence.
_STUB_RC=0
_STUB_BODY='{"status": "ok"}'
D_OUT="$(_initial_hydrate_qdrant_missing_required)"
if [ "$(printf '%s' "$D_OUT" | grep -c '^CANNOT-RUN:')" -gt 0 ]; then
    ok "D an unexpected response shape is CANNOT-RUN"
else
    bad "D an unexpected response shape must be CANNOT-RUN, got: '${D_OUT}'"
fi

# ARM H -- the use-site guard for the trap arm F describes. Even if the array
# somehow arrives unset at runtime, the checker must say CANNOT-RUN and must
# NOT return "" (which the caller reads as "every collection is present").
# Without this, the scope defect is a SILENT FALSE CLEAN on bash 5.x and an
# ABORTED INSTALL on bash 3.2 -- neither is an acceptable way to discover it.
_H_SAVE=("${_OSTLER_REQUIRED_QDRANT_COLLECTIONS[@]}")
unset _OSTLER_REQUIRED_QDRANT_COLLECTIONS
_STUB_RC=0
_STUB_BODY="$(_body_for people)"
H_OUT="$(_initial_hydrate_qdrant_missing_required 2>/dev/null)"
_OSTLER_REQUIRED_QDRANT_COLLECTIONS=("${_H_SAVE[@]}")
if [ "$(printf '%s' "$H_OUT" | grep -c '^CANNOT-RUN:')" -gt 0 ]; then
    ok "H an unset declared list is CANNOT-RUN, not a silent 'nothing missing'"
else
    bad "H an unset declared list must be CANNOT-RUN, got: '${H_OUT}'"
fi
# ...and the restore must actually have worked, or every arm after this is junk.
if [ "${#_OSTLER_REQUIRED_QDRANT_COLLECTIONS[@]}" -eq 4 ]; then
    ok "H the declared list was restored after the unset arm (4 entries)"
else
    bad "H restore failed; later arms ran against a mangled list (n=${#_OSTLER_REQUIRED_QDRANT_COLLECTIONS[@]})"
fi

printf '== ARMS E-H: install.sh structure ==\n'

# ARM E -- the READY claim must be reachable ONLY when nothing is missing,
# i.e. it must sit LATER in the file than the missing-collections warning.
E_READY="$(grep -n 'MSG_INITIAL_HYDRATE_QDRANT_READY"' "$INSTALL_SH" | tail -1 | cut -d: -f1)"
E_MISS="$(grep -n 'MSG_WARN_QDRANT_COLLECTIONS_MISSING' "$INSTALL_SH" | tail -1 | cut -d: -f1)"
if [ -z "$E_READY" ] || [ -z "$E_MISS" ]; then
    blind "E ordering anchors not found (ready='${E_READY}' missing='${E_MISS}')"
elif [ "$E_MISS" -lt "$E_READY" ]; then
    ok "E the READY claim is the last arm, after the missing-collections warning"
else
    bad "E the READY claim is reachable before the missing check (ready=${E_READY} missing=${E_MISS})"
fi

# ARM F -- THE TRAP, and this arm was a DEAD CONTROL until TNM refuted it.
#
# 🔻 WHAT IT USED TO DO, AND WHY THAT WAS WORTHLESS. It read the declaration
# line and checked it began at COLUMN 0. But COLUMN 0 IS TYPOGRAPHY AND THE
# TRAP IS SCOPE. bash does not require indentation, so a declaration can sit
# at column 0 and still be INSIDE the readiness `if` -- unset on the not-ready
# path, which is the whole defect. TNM built that mutant and my suite passed
# it 9/9 while arm F printed "at top level (column 0), so it cannot be unset".
# A control whose failing case cannot occur is worse than no control, because
# it reports green. Measured, three trees:
#     baseline                                 9 passed
#     decl indented 4 spaces                   FAILED (the :77 blind guard)
#     decl moved INSIDE the if, column 0       9 passed, 0 failed  <- dead
#
# WHAT IT DOES NOW: asks bash's own parser for the SEMANTIC fact. Truncate the
# file immediately after the declaration and parse it. If the declaration is
# genuinely top level, the truncation is a complete program. If it is inside
# an unclosed `if`, bash reports an unexpected EOF. Typography cannot fool it.
F_LINE="${DECL_LINE%%:*}"
F_HEAD="$(mktemp)"; F_CTL="$(mktemp)"
head -n "$F_LINE" "$INSTALL_SH" > "$F_HEAD"
/bin/bash -n "$F_HEAD" 2>/dev/null
F_RC=$?

# The must-fail control, in the SAME run, so a parser that has stopped
# discriminating cannot quietly pass this arm. Truncating at the pre-create
# loop is truncating INSIDE the readiness `if`, so it MUST fail to parse.
F_CTL_LINE="$(grep -n 'for _coll in "\${_OSTLER_REQUIRED_QDRANT_COLLECTIONS\[@\]}"' "$INSTALL_SH" | head -1 | cut -d: -f1)"
if [ -n "$F_CTL_LINE" ]; then
    head -n "$F_CTL_LINE" "$INSTALL_SH" > "$F_CTL"
    /bin/bash -n "$F_CTL" 2>/dev/null
    F_CTL_RC=$?
else
    F_CTL_RC=0   # anchor gone -> control cannot run -> treated as not-firing below
fi
rm -f "$F_HEAD" "$F_CTL"

if [ "$F_CTL_RC" -eq 0 ]; then
    blind "F the must-fail control did not fail (truncating inside the if parsed clean); this arm proves nothing"
elif [ "$F_RC" -eq 0 ]; then
    ok "F the declared array is genuinely TOP LEVEL by bash's parser (control fired: rc=${F_CTL_RC})"
else
    bad "F the declared array is inside a conditional block, so it is unset on the not-ready path (bash -n rc=${F_RC})"
fi

# ARM G -- one list, two readers. A literal list in the creation loop means
# the creator and the checker can drift apart.
G_ARRAY_LOOP="$(grep -c 'for _coll in "\${_OSTLER_REQUIRED_QDRANT_COLLECTIONS\[@\]}"' "$INSTALL_SH")"
G_LITERAL_LOOP="$(grep -c 'for _coll in people conversations preferences evernote_knowledge' "$INSTALL_SH")"
if [ "$G_ARRAY_LOOP" -gt 0 ] && [ "$G_LITERAL_LOOP" -eq 0 ]; then
    ok "G the creation loop reads the same array the checker does"
else
    bad "G creator/checker drift possible (array loop=${G_ARRAY_LOOP} literal loop=${G_LITERAL_LOOP})"
fi

printf '\nqdrant membership: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || { printf 'qdrant membership: FAILED\n'; exit 1; }
printf 'qdrant membership: clean (%s assertions, 1 of them the original failing input)\n' "$pass"
exit 0
