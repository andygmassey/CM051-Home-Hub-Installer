#!/usr/bin/env bash
# probes/photo_sentinel_gone_after_install.sh
# ============================================================================
# QUESTION: after install, is any photoLatitude or photoLongitude at or below -179
#           left in the store, and what did the migration log as its before-count?
#
# WHY. Photos stores -180 for "no location". An earlier extractor wrote it into
# the graph as a real coordinate: 13,432 of 45,890 PhotoEvents on the Mini16 graph
# (Archie, 2026-11-15). scripts/repair_photo_sentinel_coordinates.py deletes them
# on upgrade and writes a marker with the counts it measured. This probe reads
# both: the marker's before-count, and the live store.
#
# THE PASS CONDITION IS A ZERO EARNED BY A CONTROL. A zero from a wrong predicate
# or an empty store looks identical, so the probe also counts photoLatitude
# triples of ANY value. No photo coordinates at all means nothing was examined,
# and that is NOT MEASURED, not PASS.
#
# CANNOT-RUN is not PASS. A missing marker (the repair never verified on this box),
# an unreachable store, or a refused store credential all report CANNOT-RUN.
# ============================================================================

PROBE_NAME="photo_sentinel_gone_after_install"
PROBE_QUESTION="after install, is any photoLatitude or photoLongitude at or below -179 left in the store, and what did the migration log as its before-count?"

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/probe.sh"

OXIGRAPH_URL="${OSTLER_OXIGRAPH_URL:-http://127.0.0.1:7878/query}"
PWG="https://schema.ostler.ai/ontology#"
MARKER_PATH='$HOME/.ostler/state/repair_photo_sentinel_coords_v1.done'
STORE_CONF='$HOME/.ostler/secrets/store-curl.conf'

# Both surfaces: the default graph AND named graphs (the migration's own rule).
_Q_SENTINEL="PREFIX pwg: <${PWG}>
SELECT (COUNT(*) AS ?n) WHERE {
  { ?e ?p ?v . FILTER(?p IN (pwg:photoLatitude, pwg:photoLongitude) && ?v <= -179) }
  UNION { GRAPH ?g { ?e ?p ?v . FILTER(?p IN (pwg:photoLatitude, pwg:photoLongitude) && ?v <= -179) } }
}"
_Q_CONTROL="PREFIX pwg: <${PWG}>
SELECT (COUNT(*) AS ?n) WHERE {
  { ?e ?p ?v . FILTER(?p IN (pwg:photoLatitude, pwg:photoLongitude)) }
  UNION { GRAPH ?g { ?e ?p ?v . FILTER(?p IN (pwg:photoLatitude, pwg:photoLongitude)) } }
}"

# Pure verdict from the three measured numbers. Kept separate so the self-test can
# drive every branch without a store. Prints one line: VERDICT_KIND <detail>.
#   $1 before-count from the marker ("" when the marker is absent)
#   $2 live sentinel count from the store ("" when the store did not answer)
#   $3 control count of photo coordinates of any value ("" when unavailable)
_verdict_for() {
    local before="$1" live="$2" control="$3"
    if [ -z "$before" ] && [ -z "$live" ]; then
        echo "CANNOT_RUN migration marker absent and store unreachable: the repair has not verified on this box"; return
    fi
    if [ -z "$live" ]; then
        echo "CANNOT_RUN store did not answer the sentinel count; nothing was measured"; return
    fi
    if [ "$live" -gt 0 ]; then
        echo "FAIL ${live} sentinel coordinate triples remain after install (migration logged before=${before:-unknown})"; return
    fi
    if [ -z "$control" ] || [ "$control" -eq 0 ]; then
        echo "CANNOT_RUN no photo coordinates of any value on this box: the zero examined nothing (migration logged before=${before:-unknown})"; return
    fi
    echo "PASS 0 sentinel coordinate triples remain; ${control} photo coordinate triples examined; migration logged before=${before:-unknown}"
}

_box_store_count() {
    # Prints the integer count, or nothing when the store did not answer with one.
    local q="$1" out code
    out="$(box_run "curl -sS --noproxy '*' -m 20 -G -K ${STORE_CONF} '$OXIGRAPH_URL' --data-urlencode 'query=${q}' -H 'Accept: application/sparql-results+json' -w '\n%{http_code}' 2>/dev/null")" || true
    code="$(printf '%s\n' "$out" | tail -n1)"
    case "$code" in 200) ;; *) return 0 ;; esac
    printf '%s\n' "$out" | sed '$d' | grep -o '"value": *"[0-9]*"' | head -1 | grep -o '[0-9]*'
}

run_probe() {
    probe_examined 1 "migration marker on this box, then the live sentinel and control counts"
    local marker before live control
    marker="$(box_run "cat ${MARKER_PATH} 2>/dev/null" || true)"
    before=""
    if [ -n "$marker" ]; then
        before="$(printf '%s\n' "$marker" | grep -o '"before": *{[^}]*}' | grep -o '"sentinel_coord_triples": *[0-9]*' | grep -o '[0-9]*$' | head -1)"
    fi
    live="$(_box_store_count "$_Q_SENTINEL")"
    control="$(_box_store_count "$_Q_CONTROL")"
    local verdict
    verdict="$(_verdict_for "$before" "$live" "$control")"
    case "$verdict" in
        PASS\ *)       probe_pass "${verdict#PASS }" ;;
        FAIL\ *)       probe_fail "${verdict#FAIL }" ;;
        CANNOT_RUN\ *) probe_cannot_run "${verdict#CANNOT_RUN }" ;;
        *)             probe_cannot_run "unrecognised verdict from the counts: ${verdict}" ;;
    esac
}

self_test() {
    local bad=0 got
    got="$(_verdict_for 13432 0 45890)"; case "$got" in PASS*13432*) ;; *) bad=1; echo "control: clean store, before 13432 -> ${got}";; esac
    got="$(_verdict_for 13432 3 45890)"; case "$got" in FAIL*3*) ;; *) bad=1; echo "control: 3 remain -> ${got}";; esac
    got="$(_verdict_for "" "" "")"; case "$got" in CANNOT_RUN*) ;; *) bad=1; echo "control: nothing answered -> ${got}";; esac
    got="$(_verdict_for 13432 0 0)"; case "$got" in CANNOT_RUN*) ;; *) bad=1; echo "control: zero examined -> ${got}";; esac
    got="$(_verdict_for 13432 "" 45890)"; case "$got" in CANNOT_RUN*) ;; *) bad=1; echo "control: store silent -> ${got}";; esac
    probe_examined 5 "verdict cases (clean, residue, no marker and no store, zero examined, store silent)"
    if [ "$bad" -eq 0 ]; then probe_pass "self-test: all five verdict branches behave"; fi
    probe_fail "self-test: a verdict branch returned the wrong kind"
}

probe_main "$@"
