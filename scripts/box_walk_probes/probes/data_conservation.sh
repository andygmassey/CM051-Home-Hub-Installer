#!/usr/bin/env bash
# probes/data_conservation.sh
# ============================================================================
# QUESTION: for every source and category, do the items the importers SAW
#           (IN), the items the stores HOLD (STORED) and the items a customer
#           can FIND in the wiki (SHOWN) agree, or is there an UNEXPLAINED loss?
#
# WHY. 2026-10-15: a sweep found about eleven silent drops (68,314 of 70,667
# music preferences hidden by a missing "apple" allow-list entry; calendars of
# type "other" at the most-private level; four parsers' social rows filtered;
# unmatched import files skipped uncounted). Each was found by reading code.
# None was found by a count, because nothing compared one stage's count with
# the next. This probe does, and an unexplained shortfall is a FAIL.
#
# THE DECISION lives in lib/data_conservation.py adjudicate(), ONE function.
# run_probe calls it on live facts; self_test calls the SAME function on
# mutated facts (a deleted store, an unexplained shown drop, an over-declared
# exclusion) and on a real wiki-text reader fed an allow-list copy with "apple"
# removed. A change to the decision breaks both in the same edit.
#
# READ-ONLY against the install: GET, Qdrant scroll, SPARQL SELECT, file reads.
# Never creates an index, never writes, never prints the credential.
#
# PROFILES (fixtures/data_conservation/expected.json)
#   chain        default. No golden numbers: each stage must account for the one
#                before it, less the exclusions the file declares. Valid on ANY
#                box, because it compares the box with ITSELF.
#   full         golden. The box was loaded with the synthetic demo-life set plus
#                the exports; every row has an exact expected IN/STORED/SHOWN.
#   <other>      set OSTLER_CONSERVATION_PROFILE.
#
# EXIT: 0 PASS, 1 FAIL (any LOST), 78 CANNOT-RUN (an instrument could not read,
# or no rows). CANNOT-RUN is not a pass.
#
# macOS bash 3.2 + BSD userland. British English; " -- " not em-dashes.
# ============================================================================

set -uo pipefail
HERE_PROBE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE_PROBE}/../lib/probe.sh"

PROBE_NAME="data_conservation"
PROBE_QUESTION="per source and category, do IN, STORED and SHOWN agree, or is there an unexplained loss?"

DC_LIB="${HERE_PROBE}/../lib/data_conservation.py"
DC_EXPECTED="${OSTLER_CONSERVATION_EXPECTED:-${HERE_PROBE}/../fixtures/data_conservation/expected.json}"
DC_PROFILE="${OSTLER_CONSERVATION_PROFILE:-chain}"
DC_PY="${OSTLER_PROBE_PYTHON:-python3}"
DC_TABLE_OUT="${OSTLER_CONSERVATION_TABLE_OUT:-}"

# Prints the facts JSON from the box. The lib is shipped as a heredoc so the
# box needs nothing installed; its python3 is the system one (3.9 safe).
dc_collect() {
    box_run "python3 - collect <<'PYPAYLOAD'
$(cat "$DC_LIB")
PYPAYLOAD"
}

run_probe() {
    [ -r "$DC_LIB" ]      || probe_cannot_run "lib/data_conservation.py is not readable at ${DC_LIB}"
    [ -r "$DC_EXPECTED" ] || probe_cannot_run "expected.json is not readable at ${DC_EXPECTED}"
    command -v "$DC_PY" >/dev/null 2>&1 || probe_cannot_run "no ${DC_PY} on the runner to adjudicate with"
    if ! box_reachable; then
        probe_cannot_run "box ${OSTLER_BOX_HOST:-<local>} is not reachable over ssh. Nothing was measured; this is not a pass."
    fi

    local work facts_json out rc
    work="$(mktemp -d)" || probe_cannot_run "no scratch directory"
    facts_json="${work}/facts.json"
    dc_collect > "$facts_json"
    if ! "$DC_PY" -c 'import json,sys; json.load(open(sys.argv[1]))' "$facts_json" 2>/dev/null; then
        probe_cannot_run "the box returned no readable facts JSON (python3 missing on the box, or ssh dropped the payload). An empty answer is not a clean answer."
    fi

    out="$("$DC_PY" "$DC_LIB" adjudicate --expected "$DC_EXPECTED" --facts "$facts_json" --profile "$DC_PROFILE")"
    rc=$?
    [ -n "$DC_TABLE_OUT" ] && printf '%s\n' "$out" > "$DC_TABLE_OUT"

    local nrows nlost nnm
    nrows="$(printf '%s\n' "$out" | sed -n 's/^ROWS \([0-9]*\):.*/\1/p')"
    nlost="$(printf '%s\n' "$out" | sed -n 's/.*INFLATED \([0-9]*\), LOST \([0-9]*\) *=>.*/\1 \2/p' | awk '{print $1+$2}')"
    nnm="$(printf '%s\n' "$out" | sed -n 's/.*NOT-MEASURED \([0-9]*\),.*/\1/p')"
    probe_examined "${nrows:-0}" "source/category rows (profile ${DC_PROFILE}), each IN->STORED->SHOWN"

    printf '%s\n' "$out" | while IFS= read -r line; do probe_note "$line"; done

    case "$rc" in
        0)  probe_pass "no unexplained loss across ${nrows} rows (profile ${DC_PROFILE}). Every gap is either absent or declared in expected.json with its reason." ;;
        1)  # probe_fail, NOT probe_fail_or_advisory: the probe itself must exit non-zero on any
            # LOST or INFLATED row. Its walk_promote_scope.tsv row is `advisory`, which is
            # what keeps a red from refusing a promote; the walk still counts it a FAIL.
            probe_fail "${nlost} of ${nrows} rows LOST or INFLATED items between IN, STORED and SHOWN with no declared reason (profile ${DC_PROFILE}); the LOST rows are in the table above, worst first." ;;
        78) probe_cannot_run "${nnm:-some} of ${nrows:-0} rows could not be read (store unreachable, log absent, or no rows). Not a pass; see the NOT-MEASURED rows above." ;;
        *)  probe_cannot_run "adjudicator exited ${rc}: $(printf '%s' "$out" | head -c 200)" ;;
    esac
}

self_test() {
    # No box, no network: the lib's own mutation tests drive the SAME
    # adjudicate() that run_probe uses.
    PROBE_EXAMINED_SET=0
    local out rc
    out="$("${OSTLER_PROBE_PYTHON:-python3}" "$DC_LIB" selftest 2>&1)"; rc=$?
    probe_examined 7 "mutation arms (deleted store, unexplained shown drop, over-declared exclusion, absent fact, empty set, allow-list copy without apple, unmutated control)"
    if [ "$rc" -ne 0 ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: ${out}"
    fi
    # Prove the shipped expected.json is parseable and every profile has rows.
    if [ -r "$DC_EXPECTED" ]; then
        local pr
        pr="$("${OSTLER_PROBE_PYTHON:-python3}" -c 'import json,sys; d=json.load(open(sys.argv[1])); print(" ".join("%s=%d" % (k, len(v.get("rows", []))) for k, v in sorted(d.get("profiles", {}).items())))' "$DC_EXPECTED" 2>&1)" \
            || probe_pass "NEGATIVE CONTROL DID NOT FIRE: expected.json unparseable: ${pr}"
        case "$pr" in *"=0"*|"") probe_pass "NEGATIVE CONTROL DID NOT FIRE: a profile with zero rows: ${pr}" ;; esac
    fi
    probe_fail "negative control behaved correctly: every mutation produced LOST, the unmutated control produced none, an absent fact was NOT-MEASURED, and an empty row set was CANNOT-RUN. ${out}"
}

probe_main "$@"
