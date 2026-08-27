#!/bin/bash
# test_every_marker_pattern_compiles.sh
#
# scripts/cut_markers.manifest is read by scripts/verify_cut_provenance.sh, which
# now runs its marker arms with `grep -rqE`. Two things follow from that, and
# neither one is checked anywhere else:
#
#   1. A pattern that does not COMPILE under ERE makes grep exit 2. Since
#      e075edd3 that is reported as CANNOT-RUN rather than as ABSENT, which is
#      the safe verdict -- but it is still a row that has stopped measuring, and
#      nothing tells you it stopped. A `wiki_image_absent` LOCK row that cannot
#      compile is a lock nobody is holding.
#
#   2. -E makes alternation the natural thing to write, and this file CANNOT
#      CARRY IT. The manifest is pipe-delimited and the gate parses it with
#      `IFS='|' read -r kind target pattern desc`, so a pattern written as
#      `foo|bar` sets pattern=foo and desc="bar|<the real description>". The
#      gate then greps for `foo`, silently, and goes green on half a pattern.
#      That hazard did not exist while the arms ran BRE; turning on -E created
#      it, so the guard against it lands with -E and not later.
#
# Both limbs print the DENOMINATOR they examined, and both carry a control that
# must FAIL, so a limb cannot pass by examining nothing.
#
# Runs on macos-latest in cut-gate-wrappers.yml: the cut job is macos-26, and
# BSD ERE is not GNU ERE. A pattern proven on ubuntu is not proven for the cut.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="${REPO_ROOT}/scripts/cut_markers.manifest"
GATE="${REPO_ROOT}/scripts/verify_cut_provenance.sh"

PASS=0
FAIL=0

ok()   { echo "  [pass] $*"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }

[ -f "$MANIFEST" ] || { echo "CANNOT-RUN: no ${MANIFEST}"; exit 2; }
[ -f "$GATE" ]     || { echo "CANNOT-RUN: no ${GATE}"; exit 2; }

# The kinds that carry a regex in field 3. Anything else in the manifest sets
# field 3 to '-' and ignores it. Derived from the manifest header, and limb 0
# refuses to let a NEW kind pass through unexamined.
pattern_kind() {
    case "$1" in
        vendor_grep|assistant_tag_grep|wiki_image_grep|wiki_image_absent) return 0 ;;
        *) return 1 ;;
    esac
}
known_kind() {
    pattern_kind "$1" && return 0
    case "$1" in
        daemon_tag|vendor_file) return 0 ;;
        *) return 1 ;;
    esac
}

# The compile probe. Deliberately the same shape the gate uses -- `grep` off
# PATH, -E, and `--` before the pattern -- so this measures the dialect the gate
# will actually meet, not the one this test would prefer.
compiles() {
    local pat="$1"
    printf '' | grep -qE -- "$pat" >/dev/null 2>&1
    [ "$?" -lt 2 ]
}

echo "== the gate really does parse field 3 as the pattern =="
if grep -q "IFS='|' read -r kind target pattern desc" "$GATE"; then
    ok "(0a) verify_cut_provenance.sh splits on | into kind/target/pattern/desc"
else
    bad "(0a) the gate's parser is not the one this test assumes -- re-read it before trusting anything below"
fi

echo "== every kind in the manifest is a kind this test knows about =="
UNKNOWN_KINDS="$(awk -F'|' '/^[^#]/ && NF>0 {print $1}' "$MANIFEST" | sort -u | while read -r k; do
    [ -z "$k" ] && continue
    known_kind "$k" || echo "$k"
done)"
KINDS_SEEN="$(awk -F'|' '/^[^#]/ && NF>0 {print $1}' "$MANIFEST" | sort -u | tr '\n' ' ')"
echo "        kinds present: ${KINDS_SEEN}"
if [ -z "$UNKNOWN_KINDS" ]; then
    ok "(0b) no unrecognised kind (a new kind must be classified here, not skipped in silence)"
else
    bad "(0b) unrecognised kind(s), so this test does not know whether they carry a regex: ${UNKNOWN_KINDS}"
fi

echo "== FORMAT: exactly four pipe fields, because a fifth is a truncated pattern =="
ROWS=0
BADFMT=0
while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    ROWS=$((ROWS+1))
    nf="$(printf '%s' "$line" | awk -F'|' '{print NF}')"
    if [ "$nf" -ne 4 ]; then
        BADFMT=$((BADFMT+1))
        echo "        line ${ROWS}: ${nf} fields, not 4 -- if the extra pipe is inside the pattern, the gate is greping only the part before it"
        printf '        %.120s\n' "$line"
    fi
done < "$MANIFEST"
echo "        rows examined: ${ROWS}"
if [ "$ROWS" -eq 0 ]; then
    bad "(1a) DENOMINATOR ZERO -- the manifest parsed to no rows at all, so this limb proved nothing"
else
    ok "(1a) denominator is real: ${ROWS} rows"
fi
if [ "$BADFMT" -eq 0 ]; then
    ok "(1b) all ${ROWS} rows are 4-field"
else
    bad "(1b) ${BADFMT} row(s) are not 4-field"
fi

echo "== COMPILE: every pattern-bearing row compiles under the grep the gate will use =="
echo "        grep in use: $(command -v grep)  [$(grep --version 2>/dev/null | head -1 || echo 'BSD grep, no --version')]"
PATROWS=0
BADPAT=0
while IFS='|' read -r kind target pattern desc; do
    case "${kind:-}" in ''|'#'*) continue ;; esac
    pattern_kind "$kind" || continue
    PATROWS=$((PATROWS+1))
    if ! compiles "$pattern"; then
        BADPAT=$((BADPAT+1))
        msg="$(printf '' | grep -qE -- "$pattern" 2>&1 >/dev/null)"
        echo "        ${kind} :: ${target} :: ${pattern}"
        echo "            grep said: ${msg}"
    fi
done < "$MANIFEST"
echo "        pattern-bearing rows examined: ${PATROWS} of ${ROWS}"
if [ "$PATROWS" -eq 0 ]; then
    bad "(2a) DENOMINATOR ZERO -- no pattern-bearing row was examined, so a green here means nothing"
else
    ok "(2a) denominator is real: ${PATROWS} pattern-bearing rows"
fi
if [ "$BADPAT" -eq 0 ]; then
    ok "(2b) all ${PATROWS} patterns compile (rc<2)"
else
    bad "(2b) ${BADPAT} pattern(s) do not compile -- each is a row that reports CANNOT-RUN and measures nothing"
fi

echo "== CONTROLS: each limb must be able to fail =="
CTRL_BAD_CAUGHT=0
for p in 'a**' '[[:bogus:]]' '['; do
    compiles "$p" || CTRL_BAD_CAUGHT=$((CTRL_BAD_CAUGHT+1))
done
if [ "$CTRL_BAD_CAUGHT" -eq 3 ]; then
    ok "(3a) CONTROL: 3 of 3 known-uncompilable patterns are caught by the same helper"
else
    bad "(3a) CONTROL FAILED: only ${CTRL_BAD_CAUGHT} of 3 known-bad patterns were caught -- limb 2 cannot fail, so its green is empty"
fi
if compiles 'navigation\.tabs\.sticky'; then
    ok "(3b) CONTROL: a real manifest-shaped pattern still compiles (the helper is not failing everything)"
else
    bad "(3b) CONTROL FAILED: a known-good pattern was rejected"
fi
SYNTH='wiki_image_grep|wiki-site:/docs/x|alpha|beta|desc'
synth_nf="$(printf '%s' "$SYNTH" | awk -F'|' '{print NF}')"
if [ "$synth_nf" -ne 4 ]; then
    ok "(3c) CONTROL: a row whose pattern contains an ERE alternation counts ${synth_nf} fields, so limb 1 catches it"
else
    bad "(3c) CONTROL FAILED: the alternation row counted 4 fields -- limb 1 cannot see the truncation it exists for"
fi

echo
echo "marker patterns: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
