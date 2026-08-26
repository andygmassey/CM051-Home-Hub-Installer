#!/usr/bin/env bash
# probes/people_stores_reconcile.sh
# ============================================================================
# QUESTION: do the graph and the vector store hold the SAME set of people --
#           not merely the same NUMBER of them?
#
# WHY A SECOND PROBE. people_count_agreement compares two totals. Two totals
# that are both wrong can agree, and on the box measured 2026-08-26 they were
# both wrong in ways a total cannot show:
#
#     qdrant distinct person_uri   7284
#     graph  distinct Person       7111
#     in QDRANT not in GRAPH        203
#     in GRAPH not in QDRANT         30      203 - 30 = 173
#
# The headline "gap of 173" is a NET figure hiding two defects of opposite sign
# that partially cancel. Anyone fixing "173 orphans" deletes 173 of the 203 and
# never learns about the 30. Set arithmetic answers what subtraction cannot.
#
# THE THREE RESIDUALS, each a different defect with a different owner:
#
#   A  terminal untyped merge survivors
#      A merge DELETES the discard's rdf:type and never ASSERTS the survivor's,
#      while copying displayName/givenName/organization onto it. Merging into a
#      URI that was not already a live Person therefore yields a node that
#      acquires every person property and never acquires the type: person-
#      shaped, untyped, invisible to every "?p a pwg:Person" count. 106 of these
#      on the box measured. CM041 fix: "a merge must leave the SURVIVOR typed".
#      A CHAINED merge (A->B, B->C) strips B's type legitimately, so chained
#      survivors are excluded -- 35 of them, and counting those as defects would
#      have been a false red.
#
#   B  orphan vectors
#      A person_uri with a vector and NO presence in the graph at all. 97 on the
#      box. merge_persons is graph-only, so an absorbed node keeps its vector.
#      These inflate every people count the customer sees.
#
#   C  named persons with no vector
#      A graph Person carrying a human name but no vector is a contact the
#      customer cannot find by searching. That is the customer-visible half.
#      DELIBERATELY NARROWED TO *NAMED*: all 30 unvectored persons on the box
#      measured carry prefLabel identical to their email address and no name at
#      all -- 9 are provably role/robot addresses and the other 21 are an
#      address someone was written to once. Embedding those would push raw email
#      addresses into the People tab as if they were contacts. So an unnamed
#      stub is REPORTED and does not fail the probe; whether it should be a
#      Person node at all is a product question, not a defect this gate can
#      settle.
#
# WHY THIS IS NOT A TOLERANCE CHECK. A residual is not drift. Each of A, B and C
# names a specific broken write path, and the correct value for each is zero.
# There is no ingest race that produces a merge survivor with no rdf:type.
# ============================================================================

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/probe.sh"

PROBE_NAME="people_stores_reconcile"
PROBE_QUESTION="do the graph and the vector store hold the same SET of people?"

OXIGRAPH_URL="${OSTLER_OXIGRAPH_URL:-http://127.0.0.1:7878/query}"
QDRANT_URL="${OSTLER_QDRANT_URL:-http://127.0.0.1:6333}"
QDRANT_COLLECTION="${OSTLER_QDRANT_PEOPLE_COLLECTION:-people}"

# The reconciliation is set arithmetic over ~7k URIs from two stores. bash 3.2
# has no associative arrays -- and /bin/bash is 3.2.57 here AND on the cut host
# -- so the join runs in python3 on the box. Single-quoted below and free of
# "$" and backticks so nothing expands on the way through box_run.
read -r -d '' RECONCILE_PY <<'PYPAYLOAD'
import json, sys
try:
    import urllib.request
except Exception as exc:
    print("CANNOTRUN urllib " + str(exc)); sys.exit(0)

OXI = sys.argv[1]; QD = sys.argv[2]; COLL = sys.argv[3]
P   = "https://schema.ostler.ai/ontology#"
SKOS= "http://www.w3.org/2004/02/skos/core#prefLabel"

def sparql(q):
    req = urllib.request.Request(OXI, data=q.encode(), headers={
        "Content-Type": "application/sparql-query",
        "Accept": "application/sparql-results+json"})
    return json.load(urllib.request.urlopen(req, timeout=120))["results"]["bindings"]

def qpost(path, body):
    req = urllib.request.Request(QD + path, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=60))

try:
    # Control FIRST: a store that answers 0 triples is a store we cannot read,
    # and every residual below would then read as a clean zero.
    triples = int(sparql("SELECT (COUNT(*) AS ?n) WHERE { ?s ?p ?o }")[0]["n"]["value"])
    if triples == 0:
        print("CANNOTRUN graph-empty"); sys.exit(0)

    graph = set()
    for b in sparql("SELECT ?p WHERE { ?p a <" + P + "Person> }"):
        graph.add(b["p"]["value"])

    vec, nxt, npoints = set(), None, 0
    while True:
        body = {"limit": 1000, "with_payload": ["person_uri"], "with_vector": False}
        if nxt is not None:
            body["offset"] = nxt
        r = qpost("/collections/" + COLL + "/points/scroll", body)["result"]
        for pt in r["points"]:
            npoints += 1
            u = (pt.get("payload") or {}).get("person_uri")
            if u:
                vec.add(u)
        nxt = r.get("next_page_offset")
        if nxt is None:
            break
    if npoints == 0:
        print("CANNOTRUN qdrant-empty"); sys.exit(0)

    # A: merge survivors that are terminal (did NOT merge onward) and untyped.
    a = int(sparql(
        "SELECT (COUNT(DISTINCT ?o) AS ?n) WHERE { "
        "  ?s <" + P + "mergedInto> ?o . "
        "  FILTER NOT EXISTS { ?o a <" + P + "Person> } "
        "  FILTER NOT EXISTS { ?o <" + P + "mergedInto> ?z } }")[0]["n"]["value"])

    # B: a vector whose URI has no presence in the graph in ANY position.
    b_orphan = 0
    for u in sorted(vec - graph):
        n_s = int(sparql("SELECT (COUNT(*) AS ?n) WHERE { <" + u + "> ?p ?o }")[0]["n"]["value"])
        n_o = int(sparql("SELECT (COUNT(*) AS ?n) WHERE { ?s ?p <" + u + "> }")[0]["n"]["value"])
        if n_s == 0 and n_o == 0:
            b_orphan += 1

    # C: graph Person with no vector, split by whether a HUMAN NAME is known.
    c_named = 0; c_unnamed = 0
    for u in sorted(graph - vec):
        label = ""; email = ""
        rows = sparql("SELECT ?l WHERE { <" + u + "> <" + SKOS + "> ?l }")
        if rows: label = rows[0]["l"]["value"].strip()
        rows = sparql("SELECT ?e WHERE { <" + u + "> <" + P + "email> ?e }")
        if rows: email = rows[0]["e"]["value"].strip()
        dn = sparql("SELECT ?d WHERE { <" + u + "> <" + P + "displayName> ?d }")
        named = bool(dn) or (label != "" and label.lower() != email.lower())
        if named: c_named += 1
        else: c_unnamed += 1

    print("OK %d %d %d %d %d %d %d" % (
        len(graph), len(vec), a, b_orphan, c_named, c_unnamed, len(vec & graph)))
except Exception as exc:
    print("CANNOTRUN " + type(exc).__name__ + " " + str(exc)[:120])
PYPAYLOAD

read_result() {
    if [ "${SELF_TEST_LOCAL:-0}" -eq 1 ]; then printf '%s' "${FAKE_RECONCILE:-CANNOTRUN self-test-unset}"; return; fi
    box_run "python3 - '${OXIGRAPH_URL}' '${QDRANT_URL}' '${QDRANT_COLLECTION}' <<'PYPAYLOAD'
${RECONCILE_PY}
PYPAYLOAD"
}

run_probe() {
    if ! box_reachable; then
        probe_cannot_run "box ${OSTLER_BOX_HOST:-localhost} is not reachable over ssh; nothing was measured"
    fi

    local out
    out="$(read_result)"

    case "$out" in
        OK\ *) : ;;
        CANNOTRUN\ *)
            probe_cannot_run "reconciliation could not run: ${out#CANNOTRUN }" ;;
        "")
            probe_cannot_run "the reconciliation returned NOTHING -- python3 missing on the box, or ssh dropped the payload. An empty answer is not a clean answer." ;;
        *)
            probe_cannot_run "unrecognised reconciliation output (first 120 chars): $(printf '%s' "$out" | head -c 120)" ;;
    esac

    local graph vec a b c_named c_unnamed both
    graph=$(printf '%s' "$out" | awk '{print $2}')
    vec=$(printf '%s'   "$out" | awk '{print $3}')
    a=$(printf '%s'     "$out" | awk '{print $4}')
    b=$(printf '%s'     "$out" | awk '{print $5}')
    c_named=$(printf '%s'   "$out" | awk '{print $6}')
    c_unnamed=$(printf '%s' "$out" | awk '{print $7}')
    both=$(printf '%s'  "$out" | awk '{print $8}')

    probe_examined "$((graph + vec))" "person records across two stores (graph ${graph}, vectors ${vec}, in both ${both})"

    probe_note "residual A  untyped terminal merge survivors : ${a}"
    probe_note "residual B  orphan vectors, no graph presence: ${b}"
    probe_note "residual C  NAMED persons with no vector     : ${c_named}"
    probe_note "            unnamed stubs with no vector     : ${c_unnamed}  (reported, not failed -- see header)"

    local failures=""
    [ "$a" -gt 0 ] && failures="${failures}A=${a} untyped merge survivors; "
    [ "$b" -gt 0 ] && failures="${failures}B=${b} orphan vectors; "
    [ "$c_named" -gt 0 ] && failures="${failures}C=${c_named} named persons unsearchable; "

    if [ -n "$failures" ]; then
        probe_fail "the two stores hold different SETS of people -- ${failures%; }"
    fi
    probe_pass "graph and vector store hold the same set of people; all three residuals are zero"
}


# ---------------------------------------------------------------------------
# self_test -- the probe must be able to DEMONSTRATE a fail, not merely compile.
#
# Each case drives the real verdict logic through FAKE_RECONCILE, so the parser,
# the residual arithmetic and the three-state branching are all exercised. A
# probe whose self-test only checks the happy path cannot tell PASS from
# "measured nothing".
# ---------------------------------------------------------------------------
self_test() {
    # NOTE THE INVERTED CONVENTION, which is deliberate and documented in
    # run_box_walk.sh PHASE 1: a self-test that BEHAVED CORRECTLY exits 1 via
    # probe_fail, because phase 1 reads exit 1 as "this probe can go red on
    # known-bad input". Exiting 0 here means a negative control DID NOT FIRE,
    # and phase 1 treats that as BROKEN. So probe_pass below is the failure
    # path, not the success path.
    SELF_TEST_LOCAL=1
    probe_examined 9 "synthetic reconciliation results (negative control)"
    local rc out fails=0 firstbad=""

    _case() {
        # _case <label> <FAKE value> <expected exit code>
        local label="$1" fake="$2" want="$3"
        out="$(SELF_TEST_LOCAL=1 FAKE_RECONCILE="$fake" run_probe 2>&1)"; rc=$?
        if [ "$rc" -ne "$want" ]; then
            printf '  SELF-TEST FAIL [%s]: expected exit %s, got %s\n' "$label" "$want" "$rc"
            printf '    output: %s\n' "$(printf '%s' "$out" | tail -1)"
            fails=$((fails + 1))
            [ -z "$firstbad" ] && firstbad="$label"
        else
            printf '  ok [%s] exit %s\n' "$label" "$rc"
        fi
    }

    # graph vec A B C_named C_unnamed both
    _case "all residuals zero -> PASS"        "OK 7187 7187 0 0 0 0 7187"   "$PROBE_EX_PASS"
    _case "A untyped survivors -> FAIL"       "OK 7111 7284 106 0 0 30 7081" "$PROBE_EX_FAIL"
    _case "B orphan vectors -> FAIL"          "OK 7187 7284 0 97 0 0 7187"  "$PROBE_EX_FAIL"
    _case "C named unsearchable -> FAIL"      "OK 7200 7187 0 0 13 0 7187"  "$PROBE_EX_FAIL"
    # THE ONE THAT MATTERS MOST: unnamed stubs alone must NOT fail, or the probe
    # goes permanently red on a box where nothing is actually broken.
    _case "unnamed stubs only -> PASS"        "OK 7217 7187 0 0 0 30 7187"  "$PROBE_EX_PASS"
    # CANNOT-RUN is a third outcome and must not collapse into either.
    _case "graph unreadable -> CANNOT-RUN"    "CANNOTRUN graph-empty"       "$PROBE_EX_CANNOT_RUN"
    _case "qdrant empty -> CANNOT-RUN"        "CANNOTRUN qdrant-empty"      "$PROBE_EX_CANNOT_RUN"
    _case "empty output -> CANNOT-RUN"        ""                            "$PROBE_EX_CANNOT_RUN"
    _case "garbage output -> CANNOT-RUN"      "totally unexpected"          "$PROBE_EX_CANNOT_RUN"

    if [ "$fails" -ne 0 ]; then
        probe_pass "NEGATIVE CONTROL DID NOT BEHAVE: ${fails} of 9 self-test cases returned the wrong outcome (first: ${firstbad}). This probe cannot be trusted to distinguish PASS from FAIL from CANNOT-RUN, so its verdicts mean nothing."
    fi
    probe_fail "negative control behaved correctly on all 9 cases: three residuals each drive FAIL independently, unnamed stubs alone do NOT fail, and unreadable/empty/garbage input all return CANNOT-RUN rather than collapsing into a pass"
}

probe_main "$@"
