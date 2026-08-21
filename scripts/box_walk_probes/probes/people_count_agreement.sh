#!/usr/bin/env bash
# probes/people_count_agreement.sh
# ============================================================================
# QUESTION: do the graph store and the Doctor API agree on how many people
#           exist?
#
# WHY IT MATTERS. Task #273 measured three surfaces on one box and got three
# answers: Oxigraph 6376, Doctor hydration 6755, UI 6547. Not one of them was
# flagged. Each surface is internally consistent and confident.
#
# The customer-visible consequence is subtler than a wrong number. It is that
# NO NUMBER IN THE PRODUCT CAN BE TRUSTED as a count of anything, because the
# same disagreement mechanism applies to preferences, meetings and messages.
# A count is the simplest possible product claim; if that is unreliable, the
# harder claims are too.
#
# TOLERANCE IS DELIBERATE AND DEFAULTS LOW. Some drift is legitimate -- an
# ingest may land between two queries. OSTLER_PEOPLE_TOLERANCE_PCT sets how
# much. It is a percentage, not an absolute, so the check does not silently
# weaken as the graph grows.
# ============================================================================

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/probe.sh"

PROBE_NAME="people_count_agreement"
PROBE_QUESTION="do Oxigraph and the Doctor API agree on the number of people?"

OXIGRAPH_URL="${OSTLER_OXIGRAPH_URL:-http://127.0.0.1:7878/query}"
DOCTOR_PEOPLE_URL="${OSTLER_DOCTOR_PEOPLE_URL:-http://127.0.0.1:8089/doctor/api/people/count}"
TOLERANCE_PCT="${OSTLER_PEOPLE_TOLERANCE_PCT:-2}"

count_oxigraph() {
    if [ "${SELF_TEST_LOCAL:-0}" -eq 1 ]; then printf '%s' "${FAKE_OXI:-UNAVAILABLE}"; return; fi
    local q out
    # ── THE TYPE IRI, AND WHY IT IS NOT foaf ANY MORE ────────────────────
    #
    # This asked for foaf:Person. The namespace migration ran 2026-08-21 at
    # 02:43Z and moved every Person node to the Ostler ontology, so on a
    # current box:
    #
    #   ?p a <http://xmlns.com/foaf/0.1/Person>          ->      0
    #   ?p a <https://schema.ostler.ai/ontology#Person>  ->  6,847
    #
    # A zero from a dead type IRI is INDISTINGUISHABLE from an empty graph.
    # Worse than useless here: had the Doctor side been readable, this probe
    # would have compared 0 against ~6,847 and thrown a confident RED at a
    # perfectly healthy box. Textbook "gates keyed to NAMES rot".
    #
    # UNION over both IRIs rather than a straight swap. The old one costs
    # nothing when it matches nothing, and a box that has NOT yet migrated is
    # a real state we still need a true count for -- swapping would just move
    # the false zero to the other population. COUNT(DISTINCT ?p) makes a node
    # carrying both types count once.
    q='SELECT (COUNT(DISTINCT ?p) AS ?n) WHERE { { ?p a <https://schema.ostler.ai/ontology#Person> } UNION { ?p a <http://xmlns.com/foaf/0.1/Person> } }'
    out="$(box_run "curl -sS -m 10 -G '$OXIGRAPH_URL' --data-urlencode 'query=$q' -H 'Accept: application/sparql-results+json' 2>/dev/null")"
    printf '%s' "$out" | python3 -c '
import json,sys
raw=sys.stdin.read().strip()
if not raw: print("UNAVAILABLE"); sys.exit(0)
try:
    b=json.loads(raw)["results"]["bindings"]
    print(b[0]["n"]["value"] if b else "UNAVAILABLE")
except Exception:
    print("UNAVAILABLE")
' 2>/dev/null || printf 'UNAVAILABLE'
}

count_doctor() {
    if [ "${SELF_TEST_LOCAL:-0}" -eq 1 ]; then printf '%s' "${FAKE_DOC:-UNAVAILABLE}"; return; fi
    local out
    out="$(box_run "curl -sS -m 10 '$DOCTOR_PEOPLE_URL' 2>/dev/null")"
    printf '%s' "$out" | python3 -c '
import json,sys,re
raw=sys.stdin.read().strip()
if not raw: print("UNAVAILABLE"); sys.exit(0)
try:
    d=json.loads(raw)
    for k in ("count","people","total","people_count"):
        if isinstance(d,dict) and k in d and isinstance(d[k],int):
            print(d[k]); sys.exit(0)
    print("UNAVAILABLE")
except Exception:
    m=re.search(r"\d+", raw)
    print(m.group(0) if m else "UNAVAILABLE")
' 2>/dev/null || printf 'UNAVAILABLE'
}

# adjudicate <a> <b> <tolerance_pct> -> "AGREE|DISAGREE|INSUFFICIENT <detail>"
adjudicate_counts() {
    local a="$1" b="$2" tol="$3"
    case "$a" in ''|*[!0-9]*) a="UNAVAILABLE" ;; esac
    case "$b" in ''|*[!0-9]*) b="UNAVAILABLE" ;; esac

    if [ "$a" = "UNAVAILABLE" ] || [ "$b" = "UNAVAILABLE" ]; then
        local n=0
        [ "$a" != "UNAVAILABLE" ] && n=$((n + 1))
        [ "$b" != "UNAVAILABLE" ] && n=$((n + 1))
        printf 'INSUFFICIENT %s of 2 count surfaces readable (oxigraph=%s doctor=%s); a comparison needs both' "$n" "$a" "$b"
        return
    fi

    # A shared zero is NOT agreement. Two dead surfaces both return nothing and
    # look identical, which is the single most likely false pass here.
    if [ "$a" -eq 0 ] && [ "$b" -eq 0 ]; then
        printf 'INSUFFICIENT both surfaces report 0 people; two dead queries agree perfectly, so this proves nothing'
        return
    fi

    local diff hi
    if [ "$a" -ge "$b" ]; then diff=$((a - b)); hi="$a"; else diff=$((b - a)); hi="$b"; fi
    local allowed=$(( hi * tol / 100 ))

    if [ "$diff" -gt "$allowed" ]; then
        printf 'DISAGREE oxigraph=%s doctor=%s differ by %s, above the %s%% tolerance of %s' "$a" "$b" "$diff" "$tol" "$allowed"
        return
    fi
    printf 'AGREE oxigraph=%s doctor=%s differ by %s, within the %s%% tolerance of %s' "$a" "$b" "$diff" "$tol" "$allowed"
}

run_probe() {
    if ! box_reachable; then
        probe_cannot_run "cannot reach box ${OSTLER_BOX_HOST:-(local)} over ssh; no counts read"
    fi

    local oxi doc
    oxi="$(count_oxigraph)"
    doc="$(count_doctor)"
    probe_note "oxigraph SPARQL count : $oxi"
    probe_note "doctor api count      : $doc"

    local readable=0
    for v in "$oxi" "$doc"; do [ "$v" != "UNAVAILABLE" ] && readable=$((readable + 1)); done
    probe_examined "$readable" "of 2 people-count surfaces readable"

    local r token detail
    r="$(adjudicate_counts "$oxi" "$doc" "$TOLERANCE_PCT")"
    token="${r%% *}"; detail="${r#* }"

    case "$token" in
        DISAGREE)     probe_fail "people counts disagree: $detail (task #273). A count is the simplest claim the product makes." ;;
        INSUFFICIENT) probe_cannot_run "$detail" ;;
        *)            probe_pass "$detail" ;;
    esac
}

self_test() {
    SELF_TEST_LOCAL=1
    probe_examined 4 "synthetic count pairs (negative control)"
    local r

    # 1. The #273 spread: 6376 vs 6755 is ~5.6%, must exceed a 2% tolerance.
    r="$(adjudicate_counts 6376 6755 2)"
    if [ "${r%% *}" != "DISAGREE" ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: the real task #273 spread (6376 vs 6755) adjudicated as '${r%% *}'. This probe cannot detect the defect it names."
    fi

    # 2. Legitimate small drift must pass.
    r="$(adjudicate_counts 6376 6380 2)"
    if [ "${r%% *}" != "AGREE" ]; then
        probe_pass "NEGATIVE CONTROL OVER-FIRED: a 4-person drift on 6376 adjudicated as '${r%% *}'. It would fail boxes that are merely mid-ingest."
    fi

    # 3. Two dead surfaces must NOT read as agreement.
    r="$(adjudicate_counts 0 0 2)"
    if [ "${r%% *}" != "INSUFFICIENT" ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: two zero counts adjudicated as '${r%% *}'. Two dead queries agree perfectly, and reading that as a pass is the exact failure this suite exists to prevent."
    fi

    # 4. One surface unreadable must refuse rather than pass.
    r="$(adjudicate_counts 6376 UNAVAILABLE 2)"
    if [ "${r%% *}" != "INSUFFICIENT" ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: a single readable surface adjudicated as '${r%% *}'."
    fi

    probe_fail "negative control behaved correctly on all 4 pairs (real spread caught, drift allowed, double-zero and single-surface both refused)"
}

probe_main "$@"
