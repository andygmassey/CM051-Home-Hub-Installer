#!/usr/bin/env bash
# probes/no_person_holds_two_contact_cards.sh
# ============================================================================
# QUESTION: has any single Person node swallowed more than one Contacts card?
#
# WHY IT MATTERS, AND WHY IT IS AN INVARIANT RATHER THAN A GOLDEN CASE.
#
# `icloud_contact_uid` is a CANONICAL key: exactly one macOS Contacts card, for
# ever. The locked dedupe ruleset (Andy + TNM, ratified 2026-06-09) RULE 2 says
# verbatim:
#
#     MUST NOT MERGE: different canonical keys, even if identical display name.
#
# So a Person node carrying two DIFFERENT icloud_contact_uid values is an
# over-merge BY DEFINITION. No judgement, no name comparison, no fuzzy call --
# two canonical keys on one node is the ruleset's own stated violation.
#
# MEASURED on the v1.0.38 fresh box, 2026-08-21, and it is not one bad node:
#
#     over-merged person nodes        128
#     Contacts cards swallowed        263   (135 people lost their own node)
#     worst single node                 5   distinct cards collapsed into one
#     distribution (uids -> nodes)  {2:124, 3:2, 4:1, 5:1}
#     CONTROL: icloud_contact_uid identifiers in the graph  2259
#
# The control matters: 2,259 is non-zero, so 128 is a real count and not an
# artefact of a query that matches everything or nothing.
#
# THIS IS THE INSTRUMENT THAT WAS MISSING, AND ITS ABSENCE IS THE STORY.
# The over-merge has been on the board since #659 as a GOLDEN CASE -- one
# hand-checked pair, re-verified by a human on each box walk, and reported to
# Andy as "still merged" over and over. A golden case can only ever tell you
# about the pair someone thought to look at. It cannot tell you the number is
# 128. Nobody knew it was 128 until this query ran, because nothing ever asked
# the population-level question.
#
# WHAT THIS PROBE DOES *NOT* CLAIM
#
# It does not say which merge was wrong, when it happened, or which writer did
# it. It says the graph currently violates a rule the product has ratified.
# That is deliberately a smaller claim than the fix needs -- but it is a claim
# that can be MEASURED on any box, by anyone, in one query, which the previous
# arrangement could not.
#
# It also does not detect UNDER-merge (two nodes for one human). That is the
# opposite failure and this predicate is blind to it by construction. Stated so
# a green here is never read as "dedupe is healthy".
# ============================================================================

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/probe.sh"

PROBE_NAME="no_person_holds_two_contact_cards"
PROBE_QUESTION="has any Person node swallowed more than one Contacts card (2+ distinct icloud_contact_uid)?"

OXIGRAPH_URL="${OSTLER_OXIGRAPH_URL:-http://127.0.0.1:7878/query}"
ONTO="https://schema.ostler.ai/ontology#"

# STORE CREDENTIAL. Oxigraph is behind the store-proxy and answers 401 to a
# keyless request on every enforce-ON install (#550/#1222). A bare query here
# used to read that 401 as an empty body -> "UNAVAILABLE" -> CANNOT-RUN blaming
# the store, which cannot tell "the probe brought no key" from "the store is
# down". So the probe now presents the install's OWN curl config, exactly as
# people_seed_and_retrieval does after #1268/#1284/#1285.
#
# STORE_CONF_PATH, never the literal STORE_CURL_CONF: the literal carries an
# unexpanded $HOME and single-quoting THAT at a -K site hands curl a path it
# cannot open (rc=26, no request, no http_code, caller reads 000). #1284 is the
# proof. STORE_CONF_PATH is $HOME expanded ON THE BOX (see _store_resolve), and
# every -K use reads it.
STORE_CURL_CONF="${OSTLER_PROBE_STORE_CURL_CONF:-\$HOME/.ostler/secrets/store-curl.conf}"
STORE_CONF_PATH=""   # STORE_CURL_CONF with $HOME expanded on the box
STORE_AUTH=""        # "conf" once the box is proven to carry a usable config
_OX_CODE_FILE=""     # _ox_curl writes the last HTTP code here so the MAIN shell
                     # can adjudicate after the command-substitution subshell

# The violation query. GROUP BY person, keep only those with >1 distinct uid.
_Q_VIOLATIONS="PREFIX p: <${ONTO}>
SELECT ?person (COUNT(DISTINCT ?v) AS ?uids) WHERE {
  ?person a p:Person ; p:hasIdentifier ?i .
  ?i p:identifierType \"icloud_contact_uid\" ; p:identifierValue ?v .
} GROUP BY ?person HAVING (COUNT(DISTINCT ?v) > 1)"

# THE ANTI-VACUITY CONTROL, and it is not optional.
#
# A zero from the query above is the PASS condition. But a zero is exactly what
# a broken predicate returns too -- wrong namespace, wrong predicate name,
# store empty, store unreachable. A dead type IRI returning 0 is precisely how
# people_count_agreement shipped a false green for weeks after the namespace
# migration. So: refuse to interpret a zero unless this control is non-zero.
_Q_CONTROL="PREFIX p: <${ONTO}>
SELECT (COUNT(DISTINCT ?i) AS ?n) WHERE { ?i p:identifierType \"icloud_contact_uid\" }"

# Resolve the store curl config path ON THE BOX ($HOME expands there) and decide
# whether a usable credential exists. Called once at the top of run_probe.
_store_resolve() {
    STORE_CONF_PATH="$(box_run "printf '%s' \"${STORE_CURL_CONF}\"" | tr -d '\r\n')"
    local _h
    _h="$(box_run "/usr/bin/grep -c '^header = ' '${STORE_CONF_PATH}' 2>/dev/null" | tr -d '\r\n ')"
    case "$_h" in ''|*[!0-9]*) _h=0 ;; esac
    if [ "$_h" -gt 0 ]; then STORE_AUTH="conf"; else STORE_AUTH=""; fi
}

# Run a SPARQL query, presenting the store credential when one is usable, and
# record the HTTP code in $_OX_CODE_FILE for the MAIN shell to adjudicate -- this
# runs inside command substitution, so a verdict-exit here would only kill the
# subshell. Echoes the response body. STORE_CONF_PATH is already $HOME-expanded,
# so single-quoting it at the -K site is safe (this is the #1284 correction).
_ox_curl() {
    local _q="$1" _k="" _out
    [ "$STORE_AUTH" = "conf" ] && _k="-K '${STORE_CONF_PATH}'"
    _out="$(box_run "curl -sS --noproxy '*' -m 20 -G ${_k} '$OXIGRAPH_URL' --data-urlencode 'query=${_q}' -H 'Accept: application/sparql-results+json' -w '\n%{http_code}'")"
    printf '%s\n' "$_out" | tail -n1 > "$_OX_CODE_FILE" 2>/dev/null
    printf '%s' "$_out" | sed '$d'
}

# Adjudicate the transport/auth outcome of the last _ox_curl. MUST run in the
# main shell (it exits with a verdict). 000 (no status at all) is a transport
# failure -> CANNOT-RUN; a 401/403 splits on whether a credential was actually
# presented: refused-with-key is a real FAIL, refused-without-key is CANNOT-RUN
# because store auth is enforced and nothing was measured.
_ox_adjudicate() {
    local _what="$1" _code
    _code="$(cat "$_OX_CODE_FILE" 2>/dev/null | tr -d '\r\n ')"
    case "$_code" in
        401|403)
            probe_examined 0 "icloud_contact_uid identifiers"
            if [ "$STORE_AUTH" = "conf" ]; then
                probe_fail "Oxigraph returned HTTP ${_code} on the ${_what} WITH the install's store credential presented (-K, ${STORE_CONF_PATH}). A key the store refuses is a real fault, not a missing probe credential."
            else
                probe_cannot_run "Oxigraph returned HTTP ${_code} on the ${_what} and this run presented NO store credential (${STORE_CONF_PATH:-<unresolved>} carried no header lines). Store auth is ENFORCED since #550/#1222, so a keyless probe cannot read the graph whether or not the data exists -- nothing about the contact-card invariant was measured."
            fi
            ;;
        000|'')
            probe_examined 0 "icloud_contact_uid identifiers"
            probe_cannot_run "no HTTP response from ${OXIGRAPH_URL} on the ${_what} -- curl reported no status at all (refused, timed out, proxied, or a bad argument): a TRANSPORT failure, not a result. Nothing was measured."
            ;;
    esac
}

_sparql_scalar() {
    _ox_curl "$1" \
    | python3 -c '
import json,sys
raw=sys.stdin.read().strip()
if not raw: print("UNAVAILABLE"); sys.exit(0)
try:
    b=json.loads(raw)["results"]["bindings"]
    print(b[0][list(b[0])[0]]["value"] if b else "0")
except Exception:
    print("UNAVAILABLE")
' 2>/dev/null || printf 'UNAVAILABLE'
}

# Returns the violation rows as "<uids> <person>" lines, or UNAVAILABLE.
_fetch_violations() {
    if [ "${SELF_TEST_LOCAL:-0}" -eq 1 ]; then printf '%s' "${FAKE_VIOLATIONS:-}"; return; fi
    _ox_curl "$_Q_VIOLATIONS" \
    | python3 -c '
import json,sys
raw=sys.stdin.read().strip()
if not raw: print("UNAVAILABLE"); sys.exit(0)
try:
    for r in json.loads(raw)["results"]["bindings"]:
        print(r["uids"]["value"], r["person"]["value"])
except Exception:
    print("UNAVAILABLE")
' 2>/dev/null || printf 'UNAVAILABLE'
}

# Summarise violation lines. Shared by run_probe and self_test so the control
# exercises the SHIPPING adjudicator, not a copy of it.
# stdout: "<nodes> <cards_swallowed> <worst>"
summarise_violations() {
    printf '%s' "$1" | python3 -c '
import sys
n=[]
for line in sys.stdin.read().splitlines():
    line=line.strip()
    if not line: continue
    try: n.append(int(line.split()[0]))
    except Exception: pass
print(len(n), sum(n), (max(n) if n else 0))
' 2>/dev/null
}

run_probe() {
    if ! box_reachable; then
        probe_cannot_run "cannot reach box ${OSTLER_BOX_HOST:-(local)}; the graph was not queried"
    fi

    _OX_CODE_FILE="$(mktemp 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/ox_code.$$")"
    _store_resolve

    # CONTROL FIRST. Deliberately before the violation query, so a broken or
    # empty store can never be reported as a clean graph.
    local control
    control="$(_sparql_scalar "$_Q_CONTROL")"
    # Transport/auth is adjudicated BEFORE the "not a number" check below, so a
    # 401 (no key) reads as "keyless, nothing measured" and not as "the ontology
    # namespace moved". _ox_adjudicate exits with the verdict on 000/401.
    _ox_adjudicate "control query"
    case "$control" in
        ''|*[!0-9]*)
            probe_examined 0 "Person nodes"
            probe_cannot_run "the control query did not return a number (got '${control}') -- Oxigraph unreachable or the ontology namespace moved. A zero from the violation query would be meaningless, so no verdict."
            ;;
    esac
    if [ "$control" -eq 0 ]; then
        probe_examined 0 "Person nodes"
        probe_cannot_run "ZERO icloud_contact_uid identifiers in the graph. Either contacts have not been imported yet, or the predicate/namespace is wrong. Either way a clean violation count proves nothing -- this is CANNOT-RUN, not a pass."
    fi

    local rows
    rows="$(_fetch_violations)"
    _ox_adjudicate "violation query"
    if [ "$rows" = "UNAVAILABLE" ]; then
        probe_examined 0 "Person nodes"
        probe_cannot_run "violation query failed against $OXIGRAPH_URL"
    fi

    local s nodes cards worst
    s="$(summarise_violations "$rows")"
    nodes="$(printf '%s' "$s" | cut -d' ' -f1)"
    cards="$(printf '%s' "$s" | cut -d' ' -f2)"
    worst="$(printf '%s' "$s" | cut -d' ' -f3)"

    probe_examined "$control" "icloud_contact_uid identifiers across the graph"
    probe_note "over-merged Person nodes: ${nodes}"

    if [ "${nodes:-0}" -gt 0 ]; then
        probe_note "Contacts cards swallowed: ${cards} (so ${cards} cards share ${nodes} nodes; $((cards - nodes)) people have no node of their own)"
        probe_note "worst single node: ${worst} distinct Contacts cards collapsed into one person"
        # NOT display names -- this output lands in logs and support bundles,
        # and the whole defect is that these nodes carry the names of people
        # who are not each other.
        #
        # AND NOT THE RAW URI EITHER, which is where this stopped before and is
        # a step short. MEASURED on the live box 2026-08-26: of 7111 Person
        # URIs, 1405 are a full uuid5 -- the output of
        # ostler_fda/pwg_ingest.py:_person_id_from_identifier, which is
        #
        #     uuid5(NAMESPACE_URL, "https://schema.ostler.ai/person/" + identifier)
        #
        # over a lowercased email or E.164 phone. Unsalted, with a namespace, a
        # template and an algorithm that are all in a PUBLIC repo. So the
        # mapping identifier -> URI is computable by anyone, and a PUBLISHED URI
        # is a confirmation oracle: guess an address, compute, compare. E.164
        # for a single country is small enough to enumerate exhaustively.
        #
        # Shown with synthetic values rather than by reversing anyone:
        #     someone@example.com -> person_a4d2c110-9224-541e-8152-533deb73e0e8
        #     +447700900123       -> person_959abae0-19e7-5984-beec-2ef4e8480246
        # which is exactly the shape 1405 of the live nodes carry.
        #
        # A SHA-256 prefix is stable across runs, correlates with the CM041
        # reconcile tooling (same scheme), and is not invertible by guessing an
        # address. An operator who needs the real URIs gets them ON THE BOX,
        # where the customer's data already lives. A walk record travels; the
        # graph does not, and the two must not be confused.
        probe_note "first offending nodes (opaque, sha256 prefix): $(printf '%s' "$rows" | head -3 | awk '{print $2}' | while read -r u; do printf '%s ' "$(printf '%s' "$u" | shasum -a 256 | cut -c1-10)"; done)"
        probe_note "  the real URIs stay on the box; re-run this query there if you need them"
        probe_fail "${nodes} Person node(s) each carry 2+ distinct icloud_contact_uid, collapsing ${cards} Contacts cards. That is RULE 2 of the ratified dedupe ruleset -- different canonical keys MUST NOT merge -- violated in the live graph (#659)."
    fi

    probe_pass "no Person node carries more than one icloud_contact_uid (checked against ${control} identifiers, so this zero is a measurement)"
}

self_test() {
    SELF_TEST_LOCAL=1
    local s

    # 1. The real shape: two nodes over-merged, one of them badly.
    #    MUST be counted. This is the shape of the #659 pair -- a relationship
    #    label and a full name landing on one node.
    FAKE_VIOLATIONS="2 https://example.invalid/person_aaa
5 https://example.invalid/person_bbb"
    s="$(summarise_violations "$FAKE_VIOLATIONS")"
    probe_examined 2 "fixture over-merged nodes (negative control)"
    if [ "$s" != "2 7 5" ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: summarised planted violations as '$s', expected '2 7 5'. This probe cannot count the defect it exists for."
    fi

    # 2. A clean graph must summarise to zero and NOT be flagged.
    s="$(summarise_violations "")"
    if [ "$s" != "0 0 0" ]; then
        probe_pass "NEGATIVE CONTROL OVER-FIRED: an empty violation set summarised as '$s'. It would fail every healthy box."
    fi

    # 3. Malformed rows must not silently inflate or crash the count. A probe
    #    that throws on junk reports BROKEN on a box with one odd triple.
    s="$(summarise_violations "not-a-number http://x
3 http://y")"
    if [ "$s" != "1 3 3" ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: malformed input summarised as '$s', expected '1 3 3'. Junk in the result set would corrupt the verdict."
    fi

    probe_fail "negative control behaved correctly (counted planted over-merges, passed a clean set, survived malformed rows)"
}

probe_main "$@"
