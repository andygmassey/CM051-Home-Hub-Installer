#!/usr/bin/env bash
#
# test_qdrant_import_gate_refuses_empty_store.sh -- v1061-D003 / reg#624
#
# =============================================================================
# THE DEFECT THIS FAILS ON
# =============================================================================
# On a cold fresh install Qdrant collections do NOT self-create
# (feedback_qdrant_collections_no_self_create_fresh_install). A readiness miss
# at T+0 left them absent; import_data then embedded every person, 404'd on the
# missing collection, and discarded 3810 people SILENTLY while the step reported
# STEP_END status=ok. A happy-path test cannot see this -- that is how it
# shipped. This drives the REAL failure: an empty/unready store, asserting the
# import step REFUSES rather than runs into a void, and that the refusal is
# WIRED ahead of the import so the two facts are connected, not adjacent.
#
# Pass an install.sh path as $1 to point the structural arms at OLD code: on
# origin/main (no gate) the wiring arm FAILS and the function is absent -- the
# RED that proves this test discriminates.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="${1:-$HERE/install.sh}"

fails=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

FN="$(sed -n '/^_ostler_ensure_qdrant_collections() {/,/^}/p' "$INSTALL")"

# ---- arms A-C: drive the lifted function against a stubbed store -------------
run_fn() {   # $1 = store state -> echoes "rc=<0|1> missing=<list>"
  (
    export _STORE_STATE="$1" _CREATED_DIR
    _CREATED_DIR="$(mktemp -d)"
    _OSTLER_REQUIRED_QDRANT_COLLECTIONS=(people conversations preferences evernote_knowledge)
    _OSTLER_STORE_CURL_ARGS=()
    OSTLER_QDRANT_READY_WAIT_S=2
    sleep() { :; }                 # never actually wait in the test
    curl() {                       # a stubbed Qdrant
      local is_put=0 url=""
      for a in "$@"; do
        case "$a" in PUT) is_put=1 ;; http://*) url="$a" ;; esac
      done
      case "$_STORE_STATE" in
        down) return 22 ;;                                 # store never answers
        healthy) return 0 ;;                               # every collection exists
        creatable)                                         # empty, but PUT works
          case "$url" in
            */collections) return 0 ;;                     # readiness answers
            */collections/*)
              local c="${url##*/}"
              if [ "$is_put" = 1 ]; then : > "$_CREATED_DIR/$c"; return 0; fi
              [ -f "$_CREATED_DIR/$c" ] && return 0 || return 22 ;;
          esac ;;
      esac
      return 0
    }
    eval "$FN"
    if _ostler_ensure_qdrant_collections; then rc=0; else rc=1; fi
    printf 'rc=%s missing=%s\n' "$rc" "$_OSTLER_QDRANT_MISSING_COLLECTIONS"
  )
}

if [ -n "$FN" ]; then
  # A: a down / unready store -> the function REFUSES (rc=1) naming every collection.
  #    This is tonight's exact state, and rc=1 is the signal the gate turns into a stop.
  outA="$(run_fn down)"
  if [ "$outA" = "rc=1 missing=people conversations preferences evernote_knowledge" ]; then
    pass "A down store -> rc=1, all four named (the refusal signal fires)"
  else fail "A expected rc=1 naming all four, got: $outA"; fi

  # B: an empty but reachable store -> create the four, then rc=0 (the self-heal).
  outB="$(run_fn creatable)"
  if [ "$outB" = "rc=0 missing=" ]; then pass "B empty-but-reachable -> created all four, rc=0 (self-heal)"
  else fail "B expected rc=0 missing empty, got: $outB"; fi

  # C: a healthy store -> rc=0, nothing missing (does not clobber).
  outC="$(run_fn healthy)"
  if [ "$outC" = "rc=0 missing=" ]; then pass "C healthy store -> rc=0 (idempotent, no refusal)"
  else fail "C expected rc=0, got: $outC"; fi
else
  fail "A-C the function _ostler_ensure_qdrant_collections does not exist in $INSTALL (no gate here)"
fi

# ---- arm D: the refusal is WIRED AHEAD OF the import (the else->stop connection) ----
gate_ln="$(grep -nF 'if ! _ostler_ensure_qdrant_collections; then' "$INSTALL" | head -1 | cut -d: -f1)"
fail_ln="$(grep -nF 'ERR-14-STORE-NOT-READY-FOR-IMPORT' "$INSTALL" | head -1 | cut -d: -f1)"
imp_ln="$(grep -nF 'progress "Importing your data (building your knowledge graph)" "import_data"' "$INSTALL" | head -1 | cut -d: -f1)"
run_ln="$(grep -nF '"$IMPORT_SCRIPT" "${_IMPORT_DIRS[@]}"' "$INSTALL" | head -1 | cut -d: -f1)"
if [ -n "$gate_ln" ] && [ -n "$fail_ln" ] && [ -n "$imp_ln" ] && [ -n "$run_ln" ] \
   && [ "$gate_ln" -lt "$imp_ln" ] && [ "$fail_ln" -gt "$gate_ln" ] && [ "$fail_ln" -lt "$imp_ln" ] \
   && [ "$imp_ln" -lt "$run_ln" ]; then
  pass "D refuse-gate (fail_with_code) sits BEFORE the import_data step and its script call"
else
  fail "D the refuse-gate is not wired ahead of the import (gate=$gate_ln fail=$fail_ln import=$imp_ln run=$run_ln)"
fi

# ---- arm E: the false-reassurance strings are gone from this path ------------
if grep -qiE 'optional collections|the wiki will still build' install.sh.strings.en-GB.sh 2>/dev/null; then
  fail "E a false-reassurance string ('optional collections' / 'the wiki will still build') survives"
else
  pass "E no 'optional collections' / 'wiki will still build' reassurance on this path"
fi

# ---- arms F-I: reg#625 yield floor -- attempted people but stored nothing FAILS ----
YFN="$(sed -n '/^_ostler_import_yield_ok() {/,/^}/p' "$INSTALL")"
if [ -n "$YFN" ]; then
  eval "$YFN"
  if _ostler_import_yield_ok 3810 3810; then pass "F attempted 3810, stored 3810 -> ok (a real import is not a floor violation)"
  else fail "F a healthy import scored a floor violation"; fi
  if _ostler_import_yield_ok 0 0; then pass "G attempted 0 (empty source) -> ok, not a failure"
  else fail "G an empty source scored a floor violation"; fi
  if _ostler_import_yield_ok 3810 0; then fail "H attempted 3810 stored 0 was NOT caught -- tonight's exact silent loss"
  else pass "H attempted 3810, stored 0 -> FAIL (the yield floor fires on the real defect)"; fi
else
  fail "F-H the yield-floor predicate _ostler_import_yield_ok does not exist in $INSTALL"
fi
if grep -qF '_ostler_import_yield_ok "${_import_attempted' "$INSTALL" && grep -qF 'ERR-14-IMPORT-STORED-NOTHING' "$INSTALL"; then
  pass "I the yield floor is wired after import with its own fail_with_code"
else
  fail "I the yield-floor check is not wired after the import step"
fi

echo
if [ "$fails" = "0" ]; then echo "OK -- import refuses an empty store AND fails when it stored nothing, both wired"; exit 0
else echo "FAILED -- $fails arm(s) failed"; exit 1; fi
