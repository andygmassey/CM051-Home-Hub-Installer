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
# THAT TEXT IS SUPERSEDED (Andy, 2026-10-30). The original RULE 2 wording
# above, as ratified on 2026-06-09 and enforced since #659, no longer stands
# alone. RULE 2 NOW READS:
#
#     MUST NOT MERGE: different canonical keys, even if identical display name,
#     EXCEPT that two Contacts cards (different icloud_contact_uid) whose FULL
#     NAMES ARE THE SAME and which share an email address, a validated
#     person-specific phone number or a LinkedIn URL ARE one person and MERGE. Generational suffixes
#     are part of the name: "John Smith" and "John Smith Jr" (Sr, Jnr, II, III,
#     IV, with or without a comma) are different names and do not merge. A key
#     held by 3+ distinct names is never a merge key. A conflict on any other
#     canonical key (linkedin_url, whatsapp_lid) is never overridden.
#
#     "Validated person-specific phone" is the ratified rule as the code holds
#     it (Archie 2026-10-30: "mobile" was a paraphrase): a number that
#     phonenumbers validates as MOBILE, FIXED_LINE_OR_MOBILE, PERSONAL_NUMBER or
#     VOIP. A FIXED_LINE (household or office), toll-free, shared-cost, premium,
#     UAN, pager or unvalidated number is never a key.
#
# Andy's decision, verbatim, 2026-10-30:
#
#     "Two people with SAME NAME and SAME EMAIL address clearly are te same
#     person. Why would you NOT merge these??"
#
#     ""John Smith" and "John Smith Jr" should be treated as two different
#     names, surely? ... This is a ridiculously small edge case that if someone
#     with that exact same case had the merge happen they should surely expect
#     it"
#
# The exception is implemented in vendor/cm041/identity_resolver/
# exact_identifier.py (CM051 f1160daf, ratified by the decision above).
#
# So a Person node carrying two DIFFERENT icloud_contact_uid values is an
# over-merge UNLESS that exception covers it. The probe does not take the
# merge's word for it: see "ASK THE JOURNAL" below, where every journalled
# override is re-checked in the graph. Two canonical keys on one node with no
# such cover is the ruleset's own stated violation.
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
STORE_AUTH_REASON="" # when STORE_AUTH!="conf": WHY (absent / unreadable / empty config)
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

# DISTINCT CARDS. The control above counts identifier NODES; two nodes can carry
# one uid value. Fewer than two DISTINCT uids means no Person could possibly hold
# two cards, so a clean violation count examined nothing (v1.0.111 and v1.0.112
# graded PASS on exactly that: 1 uid, 0 merge chances).
_Q_DISTINCT_UIDS="PREFIX p: <${ONTO}>
SELECT (COUNT(DISTINCT ?v) AS ?uidn) WHERE { ?i p:identifierType \"icloud_contact_uid\" ; p:identifierValue ?v }"

# THE SECOND ANTI-VACUITY MEASURE: DID THIS BOX EVER OFFER A CHANCE TO MERGE?
#
# The control above proves the predicate can SEE icloud_contact_uid identifiers.
# It does not prove the box presented the conditions the defect needs. A virgin
# account with forty contacts, all distinct names, no shared phone or email,
# gives the resolver nothing to match on: the RULE 2 guard added in #1543 never
# fires, no node ever carries two cards, and this probe passes having exercised
# nothing.
#
# That matters right now because a fresh-install walk reading 0 is what is meant
# to CLOSE #1543. A zero from a box with no near-duplicates would close it on
# evidence that never touched the code.
#
# So count the Person nodes that share a phone or email identifier VALUE with a
# different Person node. Those are exactly the places resolve() can return a
# match and the guard can be asked to refuse one. "phone" and "email" are the
# literal identifierType strings contact_syncer writes in _update_person_oxigraph
# Part B, alongside "icloud_contact_uid".
#
# Advisory, never a new failure. A box with zero opportunities is a real and
# correct state, not a fault -- but the walk record must say so, or a weak zero
# and a strong zero print identically.
_Q_OPPORTUNITY="PREFIX p: <${ONTO}>
SELECT (COUNT(DISTINCT ?a) AS ?n) WHERE {
  ?a a p:Person ; p:hasIdentifier ?ia .
  ?b a p:Person ; p:hasIdentifier ?ib .
  ?ia p:identifierType ?t ; p:identifierValue ?v .
  ?ib p:identifierType ?t ; p:identifierValue ?v .
  FILTER(?a != ?b)
  FILTER(?t IN (\"phone\", \"email\"))
}"

# NAME TIERS (DMG #27): a merge must not lose the human name. Count live Persons
# whose displayName is a PHONE or an EMAIL and that are the target of a mergedInto
# from a node carrying a HUMAN name. Baseline on a candidate box: ~150 of 787
# merges. Must be 0 after hydration. The denominator is every live merge survivor.
# Shapes mirror identity_resolver/canonical_name.py (phone: 5+ phone characters;
# email: x@y.z); a human name is anything else non-empty.
_NAME_PHONE='^[+()\\-.\\s0-9]{5,}$'
_NAME_EMAIL='^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$'
_Q_NAME_TIER_BAD="PREFIX p: <${ONTO}>
SELECT (COUNT(DISTINCT ?s) AS ?n) WHERE {
  ?s a p:Person ; p:displayName ?sn .
  ?src p:mergedInto ?s ; p:displayName ?m .
  FILTER(REGEX(STR(?sn), \"${_NAME_PHONE}\") || REGEX(STR(?sn), \"${_NAME_EMAIL}\"))
  FILTER(STRLEN(STR(?m)) > 0 && !REGEX(STR(?m), \"${_NAME_PHONE}\") && !REGEX(STR(?m), \"${_NAME_EMAIL}\"))
}"
_Q_NAME_TIER_DENOM="PREFIX p: <${ONTO}>
SELECT (COUNT(DISTINCT ?s) AS ?n) WHERE { ?s a p:Person . ?src p:mergedInto ?s }"

# CLEAN when 0 bad; FAIL when >0; UNMEASURED when either number is not a number
# or the denominator is 0 (nothing was merged, so a zero would be vacuous).
adjudicate_names() {
    case "${1}${2}" in *[!0-9]*|'') echo "UNMEASURED"; return ;; esac
    case "${1}" in ''|*[!0-9]*) echo "UNMEASURED"; return ;; esac
    case "${2}" in ''|*[!0-9]*) echo "UNMEASURED"; return ;; esac
    if [ "$2" -eq 0 ]; then echo "UNMEASURED"; return; fi
    if [ "$1" -gt 0 ]; then echo "FAIL"; else echo "CLEAN"; fi
}

# Resolve the store curl config path ON THE BOX ($HOME expands there) and decide
# whether a usable credential exists. Called once at the top of run_probe.
_store_resolve() {
    STORE_CONF_PATH="$(box_run "printf '%s' \"${STORE_CURL_CONF}\"" | tr -d '\r\n')"
    # Classify the config ON THE BOX so the walk record can name WHY a read is
    # keyless instead of collapsing three causes into one message. The config is
    # written 0600 owner-only (#549/#550), so a probe running as another account
    # gets permission-denied on a file that may be full of headers -- printing
    # that as "carried no header lines" tells a tired human the opposite of true.
    local _state
    _state="$(box_run "if [ ! -e '${STORE_CONF_PATH}' ]; then printf ABSENT; elif [ ! -r '${STORE_CONF_PATH}' ]; then printf UNREADABLE; elif [ \"\$(/usr/bin/grep -c '^header = ' '${STORE_CONF_PATH}' 2>/dev/null)\" -gt 0 ]; then printf HEADERS; else printf EMPTY; fi" | tr -d '\r\n ')"
    case "$_state" in
        HEADERS)    STORE_AUTH="conf"; STORE_AUTH_REASON="" ;;
        ABSENT)     STORE_AUTH="";     STORE_AUTH_REASON="the store curl config ${STORE_CONF_PATH:-<unresolved>} does not exist on the box" ;;
        UNREADABLE) STORE_AUTH="";     STORE_AUTH_REASON="the store curl config ${STORE_CONF_PATH} exists but is not readable by this probe's account -- it is written 0600 owner-only, so a probe running as a different user cannot read a config that may be full of headers; this is NOT evidence the credential is absent" ;;
        *)          STORE_AUTH="";     STORE_AUTH_REASON="the store curl config ${STORE_CONF_PATH} is readable but carries no 'header = ' lines" ;;
    esac
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
                probe_cannot_run "Oxigraph returned HTTP ${_code} on the ${_what} and this run presented NO store credential -- ${STORE_AUTH_REASON:-no usable store credential was resolved}. Store auth is ENFORCED since #550/#1222, so a keyless probe cannot read the graph whether or not the data exists -- nothing about the contact-card invariant was measured."
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

# ── WHICH KEY JOINED THE CARDS (instr119) ───────────────────────────────
#
# v1.0.118 walk 3 FAILED with 59 over-merged nodes and printed three opaque
# digests, so WHY they merged was NOT INSTRUMENTED. For each offending node
# (cap 20) ask the graph for the phone, email and name on the node and on every
# node merged INTO it, and name the key they share: that is the key the
# resolver matched on. Values never leave the box raw: each is normalised and
# printed as <type>:<sha256 prefix>, so two nodes sharing a key show the same
# digest and nobody's number or address is disclosed.
JOIN_CAP="${OSTLER_PROBE_JOIN_CAP:-20}"
_q_join() {
    printf '%s' "PREFIX p: <${ONTO}>
SELECT ?side ?t ?v WHERE {
  { <${1}> p:hasIdentifier ?i . ?i p:identifierType ?t ; p:identifierValue ?v . FILTER(?t IN (\"phone\", \"email\")) BIND(\"self\" AS ?side) }
  UNION { ?s p:mergedInto <${1}> ; p:hasIdentifier ?i . ?i p:identifierType ?t ; p:identifierValue ?v . FILTER(?t IN (\"phone\", \"email\")) BIND(STR(?s) AS ?side) }
  UNION { <${1}> p:displayName ?v . BIND(\"name\" AS ?t) BIND(\"self\" AS ?side) }
  UNION { ?s p:mergedInto <${1}> ; p:displayName ?v . BIND(\"name\" AS ?t) BIND(STR(?s) AS ?side) }
}"
}

_fetch_join() {
    if [ "${SELF_TEST_LOCAL:-0}" -eq 1 ]; then printf '%s' "${FAKE_JOIN_JSON:-}"; return; fi
    # -n: this runs inside the per-node while-read loop (see box_run).
    BOX_RUN_NO_STDIN=1 _ox_curl "$(_q_join "$1")"
}

# explain_join <cards> <sparql-json>: one masked line naming the join key. Pure.
explain_join() {
    printf '%s' "$2" | python3 -c '
import hashlib, json, re, sys
cards = sys.argv[1]
def norm(t, v):
    v = (v or "").strip().lower()
    if t == "phone":
        d = re.sub(r"[^0-9]", "", v)
        return d[-9:] if len(d) >= 7 else d
    return re.sub(r"\s+", " ", v)
def mask(t, v):
    return "%s:%s" % (t, hashlib.sha256(norm(t, v).encode()).hexdigest()[:8])
try:
    rows = json.loads(sys.stdin.read())["results"]["bindings"]
except Exception:
    print("%s cards; join key NOT MEASURED (the graph did not answer)" % cards); sys.exit(0)
selfk, srck = set(), {}
for r in rows:
    side, t, v = r["side"]["value"], r["t"]["value"], r["v"]["value"]
    if not norm(t, v):
        continue
    k = (t, norm(t, v))
    if side == "self":
        selfk.add(k)
    else:
        srck.setdefault(side, set()).add(k)
pool = set(selfk)
for ks in srck.values():
    pool |= ks
shared = set()
for s, ks in srck.items():
    others = set(selfk)
    for s2, ks2 in srck.items():
        if s2 != s:
            others |= ks2
    shared |= (ks & others)
order = {"phone": 0, "email": 1, "name": 2}
def show(ks):
    return ",".join(sorted(("%s:%s" % (t, hashlib.sha256(v.encode()).hexdigest()[:8]) for t, v in ks),
                           key=lambda x: (order.get(x.split(":")[0], 9), x)))
if srck:
    if shared:
        print("%s cards; %d node(s) merged in; joined by %s" % (cards, len(srck), show(shared)))
    else:
        print("%s cards; %d node(s) merged in; NO shared phone, email or name on record (the join key is not in the graph)" % (cards, len(srck)))
else:
    cnt = {}
    for t, _ in selfk:
        cnt[t] = cnt.get(t, 0) + 1
    tally = " ".join("%s x%d" % (t, cnt[t]) for t in sorted(cnt, key=lambda x: order.get(x, 9)))
    print("%s cards; no node merged in (written onto one node at sync time); candidate keys on the node: %s%s" %
          (cards, tally or "none", (" [" + show(selfk) + "]") if selfk else ""))
' "$1" 2>/dev/null || printf '%s cards; join key NOT MEASURED (classifier failed)' "$1"
}

# ── A 2+ CARD NODE CAN BE A DELIBERATE MERGE: ASK THE JOURNAL (#3202) ────
#
# Archie's ruling: the over-merged nodes are probably deliberate #30
# exact-identifier merges, and this probe was blind to that because the merge
# writers move the phone/email OFF the merged node. So a 2+ card node PASSES
# only when, for EVERY extra card, the merge journal (CM051 #3217) holds an
# exact-identifier override row for it that names the KEY KIND and a KEY HASH,
# AND THE GRAPH ITSELF CONFIRMS THE OVERRIDE (v1.0.121, below).
#   FAIL       no journal row, a row with no key / a null hash, or a row whose
#              graph re-check fails
#   CANNOT-RUN the journal exists and cannot be read, the only rows carry
#              hash=null with matched_keys_reason "journal_secret_unavailable",
#              a merge snapshot cannot be read, or a phone key needs type
#              validation and no interpreter with `phonenumbers` exists
#
# THE JOURNAL IS WRITTEN BY THE CODE UNDER TEST (Archie, 2026-10-30), so a
# journalled reason alone never turns a FAIL into a PASS. For every row the
# journal offers as an excuse, this probe re-checks, independently and IN THE
# GRAPH, the three conditions of the RULE 2 exception (see the header):
#   1. NAMES: the keep and discard nodes' displayName are the same full name
#      (2+ tokens) after normalisation. The normalisation is: Unicode NFC,
#      case-folded, whitespace runs collapsed. NOTHING ELSE: punctuation and
#      generational suffixes are KEPT, so "John Smith" != "John Smith Jr" !=
#      "John Smith, Jr" != "John Smith Jnr", and "J. Smith" != "John Smith".
#   2. KEY: the two cards really share the claimed key kind. Which identifier
#      nodes belonged to which card is read from the merge snapshot; the VALUES
#      and the fact that both identifier nodes now sit on the survivor are read
#      from the graph. A claimed kind with no shared value is a FAIL. A shared
#      phone must validate as PERSON-SPECIFIC. This MIRRORS exact_identifier's
#      phone-type set (_PERSONAL_TYPES: MOBILE, FIXED_LINE_OR_MOBILE,
#      PERSONAL_NUMBER, VOIP), and tests/test_rule2_override_is_rechecked_in_the_graph.py
#      fails if the two sets drift. Note the resolver ALLOWS the ambiguous
#      FIXED_LINE_OR_MOBILE (US/CA numbers), so this probe does too; FIXED_LINE
#      and every other type, or an unvalidated number, is REFUSED.
#   3. GUARD: no shared key is held by 3+ distinct normalised names among the
#      live Person nodes (a switchboard, family inbox or shared handset).
# The journal hashes are HMACs keyed by this install's service_token and are
# only ever checked for SHAPE (16 lowercase hex), never compared or printed.
# An ABSENT journal is no rows (FAIL), not an unreadable one. A node whose rows
# carry no reason at all is reported separately as "reason unrecorded" (still a
# FAIL). Output is digests and kinds only, never a name or a value.
#
# A SPLIT PAIR (a recorded "different people" decision) is two Person nodes,
# one card each, so it never reaches this check: the violation query only
# selects ONE node holding 2+ cards.
MERGE_JOURNAL="${OSTLER_MERGE_JOURNAL:-\$HOME/.ostler/import-pipeline/backups/merge_journal/merge_journal.jsonl}"
read -r -d '' JOURNAL_PY <<'PYJOURNAL'
import hashlib, json, os, re, sys, unicodedata
OXI, CONF, JPATH = sys.argv[1:4]
import urllib.request, urllib.error
try:
    import phonenumbers
    PHONE_OK = True
except Exception:
    phonenumbers = None
    PHONE_OK = False
H = {}
try:
    for line in open(CONF, encoding="utf-8"):
        line = line.strip()
        if line.startswith("header") and "=" in line:
            val = line.split("=", 1)[1].strip().strip('"')
            if ":" in val:
                k, v = val.split(":", 1)
                H[k.strip()] = v.strip()
except Exception:
    pass
urllib.request.install_opener(urllib.request.build_opener(urllib.request.ProxyHandler({})))
P = "https://schema.ostler.ai/ontology#"
def sparql(q):
    h = {"Content-Type": "application/sparql-query", "Accept": "application/sparql-results+json"}
    h.update(H)
    return json.load(urllib.request.urlopen(urllib.request.Request(OXI, data=q.encode(), headers=h), timeout=120))["results"]["bindings"]
def fp(u):
    return hashlib.sha256(u.encode("utf-8")).hexdigest()[:10]
HEX16 = re.compile(r"^[0-9a-f]{16}$")
KINDS = ("email", "phone", "linkedin")
# graph identifierType -> journal key kind
GTYPE = {"email": "email", "phone": "phone", "linkedin_url": "linkedin"}
GUARD_MIN_DISTINCT_NAMES = 3
# MIRRORS vendor/cm041/identity_resolver/exact_identifier.py _PERSONAL_TYPES
# (is_usable_phone_key). A parity test fails if these drift.
PERSON_SPECIFIC_PHONE_TYPES = ("MOBILE", "FIXED_LINE_OR_MOBILE", "PERSONAL_NUMBER", "VOIP")

def name_norm(n):
    # NFC, case-folded, whitespace collapsed. Punctuation and suffixes KEPT.
    return " ".join(unicodedata.normalize("NFC", n or "").casefold().split())

def value_norm(kind, v):
    v = (v or "").strip()
    if kind == "email":
        return v.lower()
    if kind == "phone":
        return v.replace(" ", "")
    if kind == "linkedin":
        s = re.split(r"[?#]", v, 1)[0]
        low = s.lower()
        for pre in ("https://", "http://"):
            if low.startswith(pre):
                s, low = s[len(pre):], low[len(pre):]
                break
        if low.startswith("www."):
            s = s[4:]
        i = s.find("/")
        s = (s[:i].lower() + s[i:]) if i >= 0 else s.lower()
        return s.rstrip("/")
    return v

def phone_is_person_specific(e164):
    """True / False, or None when it cannot be judged (no phonenumbers)."""
    if not PHONE_OK:
        return None
    if not e164.startswith("+"):
        return False
    try:
        n = phonenumbers.parse(e164, None)
    except Exception:
        return False
    if not phonenumbers.is_valid_number(n):
        return False
    return phonenumbers.number_type(n) in {getattr(phonenumbers.PhoneNumberType, t)
                                           for t in PERSON_SPECIFIC_PHONE_TYPES}

def row_state(r):
    # One merge row, judged on the journal's own fields only.
    if not str(r.get("override") or "").startswith("exact_identifier:"):
        return "nooverride"
    keys = r.get("matched_keys")
    if not isinstance(keys, list) or not keys:
        return "nokey"
    if all(isinstance(k, dict) and k.get("hash") is None for k in keys) \
            and r.get("matched_keys_reason") == "journal_secret_unavailable":
        return "secret_unavailable"
    for k in keys:
        if not isinstance(k, dict) or k.get("kind") not in KINDS or not HEX16.match(str(k.get("hash") or "")):
            return "nokey"
    return "keyed"

def recheck(r, u, names, ids, holds, snaps, holders):
    """Re-check one keyed override row in the GRAPH. ('ok'|'fail'|'cannot', why)."""
    d, k = r.get("discard") or "", r.get("keep") or ""
    dn, kn = name_norm(names.get(d)), name_norm(names.get(k))
    if not dn or not kn:
        return "fail", "name-not-on-record"
    if dn != kn:
        return "fail", "name-mismatch"
    if len(kn.split()) < 2:
        return "fail", "name-not-a-full-name"
    snap = snaps.get(r.get("id"))
    if snap is None:
        return "fail", "snapshot-absent"
    if snap == "unreadable":
        return "cannot", "snapshot-unreadable"
    on_u = holds.get(u, set())
    def vals(side, kind):
        return {ids[i][1] for i in snap[side] if i in on_u and i in ids and ids[i][0] == kind and ids[i][1]}
    claimed = sorted({str(x.get("kind")) for x in r.get("matched_keys") or [] if isinstance(x, dict)})
    usable, why = 0, []
    for kind in claimed:
        shared = vals("keep", kind) & vals("discard", kind)
        if not shared:
            return "fail", "key-not-shared-in-graph:" + kind
        for v in sorted(shared):
            if len(holders.get((kind, v), ())) >= GUARD_MIN_DISTINCT_NAMES:
                why.append("guarded:" + kind)
                continue
            if kind == "phone":
                m = phone_is_person_specific(v)
                if m is None:
                    return "cannot", "phone-type-validation-unavailable"
                if not m:
                    why.append("phone-not-person-specific")
                    continue
            usable += 1
    if not usable:
        return "fail", ",".join(sorted(set(why))) or "no-usable-shared-key"
    return "ok", "rechecked:" + "+".join(claimed)

def classify(nodes, merged_into, names, rows, ids=None, holds=None, snaps=None, holders=None):
    """nodes: {uri: uids}; merged_into: {uri: uri}; names: {uri: name};
    rows: journal merge rows not undone; ids: {identifier uri: (kind, value)};
    holds: {person uri: {identifier uri}} (graph now); snaps: {merge id:
    {"keep": set, "discard": set} | None | "unreadable"}; holders: {(kind,
    value): {normalised names}} over live Persons.
    Returns [(uri, verdict, uids, detail, unrecorded)]."""
    ids, holds, snaps, holders = ids or {}, holds or {}, snaps or {}, holders or {}
    def final(u, seen=None):
        seen = seen or set()
        while u in merged_into and u not in seen:
            seen.add(u); u = merged_into[u]
        return u
    by = {}
    for r in rows:
        k = r.get("keep")
        if k:
            by.setdefault(final(k), []).append(r)
    out = []
    for u, uids in sorted(nodes.items(), key=lambda x: (-x[1], x[0])):
        extra = uids - 1
        good, cannot, why = set(), set(), []
        recorded = False
        for r in by.get(u, []):
            st = row_state(r)
            kinds = "+".join(sorted({str(k.get("kind")) for k in (r.get("matched_keys") or []) if isinstance(k, dict)})) or "none"
            tag = "%s/%s" % (r.get("strategy") or "?", kinds)
            d = r.get("discard") or ""
            if st == "keyed":
                recorded = True
                res, w = recheck(r, u, names, ids, holds, snaps, holders)
                if res == "ok":
                    good.add(d)
                elif res == "cannot":
                    cannot.add(d)
                why.append("%s(%s)" % ("ok" if res == "ok" else w, tag))
            elif st == "secret_unavailable":
                recorded = True
                cannot.add(d); why.append("hash-null-secret-unavailable(" + tag + ")")
            else:
                why.append(st + "(" + tag + ")")
        if len(good) >= extra:
            v = "PASS"
        elif len(good) + len(cannot - good) >= extra:
            v = "CANNOT"
        else:
            v = "FAIL"
        out.append((u, v, uids, "%d of %d extra card(s) journalled AND re-checked in the graph (same full name, shared key, guard); rows: %s"
                    % (len(good), extra, ",".join(why) or "none"), (v == "FAIL" and not recorded)))
    return out

if __name__ == "__main__":
    try:
        rows_v = sparql("PREFIX p: <" + P + "> SELECT ?person (COUNT(DISTINCT ?v) AS ?uids) WHERE { "
                        "?person a p:Person ; p:hasIdentifier ?i . ?i p:identifierType \"icloud_contact_uid\" ; "
                        "p:identifierValue ?v . } GROUP BY ?person HAVING (COUNT(DISTINCT ?v) > 1)")
        nodes = {b["person"]["value"]: int(b["uids"]["value"]) for b in rows_v}
        merged_into = {b["jfrom"]["value"]: b["jto"]["value"] for b in
                       sparql("SELECT ?jfrom ?jto WHERE { ?jfrom <" + P + "mergedInto> ?jto }")}
        names = {}
        for b in sparql("SELECT ?jname_s ?jname WHERE { ?jname_s <" + P + "displayName> ?jname }"):
            names.setdefault(b["jname_s"]["value"], b["jname"]["value"])
        ids = {}
        for b in sparql("SELECT ?jid ?jt ?jv WHERE { ?jid <" + P + "identifierType> ?jt ; <" + P + "identifierValue> ?jv . "
                        "FILTER(?jt IN (\"email\", \"phone\", \"linkedin_url\")) }"):
            kind = GTYPE.get(b["jt"]["value"])
            if kind:
                ids[b["jid"]["value"]] = (kind, value_norm(kind, b["jv"]["value"]))
        holds = {}
        for b in sparql("SELECT ?jh ?jhid WHERE { ?jh <" + P + "hasIdentifier> ?jhid }"):
            holds.setdefault(b["jh"]["value"], set()).add(b["jhid"]["value"])
        live = {b["jlive"]["value"] for b in sparql("SELECT ?jlive WHERE { ?jlive a <" + P + "Person> }")}
    except Exception as exc:
        print("JERR the graph could not be read for the journal check: " + type(exc).__name__); sys.exit(0)
    holders = {}
    for pu in live:
        nn = name_norm(names.get(pu))
        for i in holds.get(pu, ()):
            if i in ids and nn:
                holders.setdefault(ids[i], set()).add(nn)

    rows, snaps = [], {}
    jdir = os.path.dirname(JPATH)
    if os.path.exists(JPATH):
        try:
            merges, undone = [], set()
            for n, line in enumerate(open(JPATH, encoding="utf-8")):
                line = line.strip()
                if not line:
                    continue
                r = json.loads(line)
                if r.get("kind") == "merge":
                    merges.append(r)
                elif r.get("kind") == "undo":
                    undone.add(r.get("merge_id"))
            rows = [r for r in merges if r.get("id") not in undone]
        except Exception as exc:
            print("JERR the merge journal exists and could not be read: " + type(exc).__name__); sys.exit(0)
        print("JSRC present %d merge row(s)" % len(rows))
    else:
        print("JSRC absent 0 merge row(s)")
    HID = P + "hasIdentifier"
    for r in rows:
        rel = str(r.get("snapshot") or "")
        if not rel or rel.startswith("/") or ".." in rel.split("/"):
            snaps[r.get("id")] = None
            continue
        sp = os.path.join(jdir, rel)
        if not os.path.exists(sp):
            snaps[r.get("id")] = None
            continue
        try:
            s = json.load(open(sp, encoding="utf-8"))
            side = {}
            for nm, uri in (("keep", r.get("keep")), ("discard", r.get("discard"))):
                subj = s["nodes"][uri]["subj"]
                side[nm] = {o[1] for p, o in subj if p == HID and isinstance(o, list) and len(o) > 1}
            snaps[r.get("id")] = side
        except Exception:
            snaps[r.get("id")] = "unreadable"
    print("JPY phonenumbers=%s" % ("yes" if PHONE_OK else "no"))
    res = classify(nodes, merged_into, names, rows, ids, holds, snaps, holders)
    for u, v, uids, d, _unrec in res:
        print("JNODE %s %s %d %s" % (fp(u), v, uids, d))
    print("JSUM %d %d %d %d" % (sum(1 for x in res if x[1] == "PASS"), sum(1 for x in res if x[1] == "FAIL"),
                                sum(1 for x in res if x[1] == "CANNOT"), sum(1 for x in res if x[4])))
PYJOURNAL

# The journal check needs `phonenumbers` to validate a phone key's type.
# The box's bare python3 does not carry it; the install's venv does (install.sh
# pip-installs phonenumbers into OSTLER_VENV for the resolver). So prefer the
# venv interpreter and fall back to python3, where a phone key is CANNOT-RUN.
read_journal_verdict() {
    if [ "${SELF_TEST_LOCAL:-0}" -eq 1 ]; then printf '%s' "${FAKE_JOURNAL_VERDICT:-JERR self-test-unset}"; return; fi
    box_run "VP=\"\${OSTLER_DIR:-\$HOME/.ostler}/.venv/bin/python3\"; [ -x \"\$VP\" ] || VP=python3; \"\$VP\" - '${OXIGRAPH_URL}' '${STORE_CONF_PATH}' \"${MERGE_JOURNAL}\" <<'PYJOURNAL'
${JOURNAL_PY}
PYJOURNAL"
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

    # DENOMINATOR 1: distinct cards. An unmeasured denominator is CANNOT-RUN. It
    # is never replaced by another number: the identifier-node count is an upper
    # bound, and an upper bound lets a 1-uid box through, which is the vacuous
    # PASS this probe exists to refuse.
    local uids
    uids="$(_sparql_scalar "$_Q_DISTINCT_UIDS")"
    case "$uids" in
        ''|*[!0-9]*)
            probe_examined 0 "distinct icloud_contact_uid (NOT MEASURED, query returned '${uids}')"
            probe_cannot_run "the distinct icloud_contact_uid count was not measured (query returned '${uids}'). Without that denominator a clean violation count cannot be told from a vacuous one, and no substitute value is used." ;;
    esac
    if [ "$uids" -lt 2 ]; then
        probe_examined "$uids" "distinct icloud_contact_uid (${control} identifier node(s)); 0 candidate merge pairs examined"
        probe_cannot_run "only ${uids} distinct icloud_contact_uid in the graph (${control} identifier node(s)). With fewer than 2 cards no Person can hold two, so there were 0 merge chances and a clean count would be vacuous. This is CANNOT-RUN, not a pass."
    fi

    local rows
    rows="$(_fetch_violations)"
    _ox_adjudicate "violation query"
    if [ "$rows" = "UNAVAILABLE" ]; then
        probe_examined 0 "Person nodes"
        probe_cannot_run "violation query failed against $OXIGRAPH_URL"
    fi

    local s nodes cards worst _jok="" excused=0
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
        # instr119: the join key per offending node, worst first, capped.
        probe_note "join key per offending node (worst first, at most ${JOIN_CAP}; values masked as type:sha256-prefix):"
        local _u _k _n=0
        while read -r _k _u; do
            [ -n "$_u" ] || continue
            case "$_k" in ''|*[!0-9]*) continue ;; esac
            _n=$((_n + 1)); [ "$_n" -gt "$JOIN_CAP" ] && break
            probe_note "  node $(printf '%s' "$_u" | shasum -a 256 | cut -c1-10): $(explain_join "$_k" "$(_fetch_join "$_u")")"
        done <<< "$(printf '%s\n' "$rows" | sort -k1,1nr)"
        [ "$nodes" -gt "$JOIN_CAP" ] && probe_note "  ... $((nodes - JOIN_CAP)) more node(s) not explained (cap ${JOIN_CAP}, OSTLER_PROBE_JOIN_CAP)"
        # THE JOURNAL DECIDES whether these are violations or deliberate
        # exact-identifier merges (see JOURNAL_PY).
        local jv jsum jp jf jc
        jv="$(read_journal_verdict)"
        case "$jv" in
            JERR\ *) probe_cannot_run "${nodes} Person node(s) carry 2+ Contacts cards and ${jv#JERR } -- whether they are journalled exact-identifier merges was not measured, so no verdict" ;;
            *JSUM\ *) : ;;
            *) probe_cannot_run "${nodes} Person node(s) carry 2+ Contacts cards and the merge-journal check returned no summary ($(printf '%s' "$jv" | head -n1 | cut -c1-100))" ;;
        esac
        probe_note "merge journal: $(printf '%s\n' "$jv" | sed -n 's/^JSRC //p' | head -n1)"
        probe_note "per node, the journal's own strategy/key kind (worst first, at most ${JOIN_CAP}):"
        printf '%s\n' "$jv" | sed -n 's/^JNODE //p' | head -n "$JOIN_CAP" | while IFS= read -r _l; do probe_note "  node ${_l}"; done
        jsum="$(printf '%s\n' "$jv" | sed -n 's/^JSUM //p' | head -n1)"
        set -- $jsum; jp="${1:-0}"; jf="${2:-0}"; jc="${3:-0}"; ju="${4:-0}"
        probe_note "interpreter for the re-check: $(printf '%s\n' "$jv" | sed -n 's/^JPY //p' | head -n1)"
        probe_note "allowed by the exact-identifier override (journalled AND re-checked in the graph): ${jp} of ${nodes}; violations: ${jf} (reason unrecorded: ${ju}; reason recorded but the graph re-check failed: $((jf - ju))); cannot verify: ${jc}"
        if [ "$jf" -gt 0 ]; then
            probe_fail "${jf} Person node(s) each carry 2+ distinct icloud_contact_uid (of ${nodes} such nodes) that the RULE 2 exception does not cover: ${ju} with no journalled override reason, $((jf - ju)) whose journalled reason the graph does not bear out (same full name with suffixes kept, a shared email / person-specific phone / LinkedIn on both cards, fewer than 3 names on the key). RULE 2 of the ratified dedupe ruleset -- different canonical keys MUST NOT merge, except under the 2026-10-30 exact-identifier exception -- is violated in the live graph."
        fi
        if [ "$jc" -gt 0 ]; then
            probe_cannot_run "${jc} of ${nodes} 2+ card node(s) could not be re-checked (null key hashes from journal_secret_unavailable, an unreadable merge snapshot, or a phone key with no phonenumbers to validate its type); ${jp} verified"
        fi
        probe_note "all ${nodes} 2+ card node(s) are journalled exact-identifier merges that the graph re-check bears out; not RULE 2 violations"
        # Every one of these nodes is a merge the resolver DID make and the
        # journal excuses AND the graph re-check bears out: the merge path was
        # exercised, so they count as candidate pairs below even when no
        # unmerged shared-key node is left.
        excused="$jp"
        _jok="${nodes} 2+ card node(s) are exact-identifier merges, journalled and re-checked in the graph; otherwise "
    fi

    # NAME TIERS: a merge must not lose the human name (DMG #27).
    local nbad nden nverdict
    nbad="$(_sparql_scalar "$_Q_NAME_TIER_BAD")"
    nden="$(_sparql_scalar "$_Q_NAME_TIER_DENOM")"
    nverdict="$(adjudicate_names "$nbad" "$nden")"
    case "$nverdict" in
        FAIL)  probe_note "merge survivors with a phone/email displayName beside a human-named merged-in node: ${nbad} of ${nden} merge survivors"
               probe_fail "${nbad} of ${nden} merge survivors are named by a phone number or email while a merged-in node carries a human name: the merge lost the name (name-tier rule, phone < email < human). Must be 0 after hydration." ;;
        CLEAN) probe_note "merge survivors with a phone/email displayName beside a human-named merged-in node: 0 of ${nden}" ;;
        *)     probe_note "name-tier check NOT MEASURED (bad='${nbad}', merge survivors='${nden}'); a zero over no merges proves nothing" ;;
    esac

    # THE ZERO IS REAL. IS IT LOAD-BEARING? Ask whether anything could have
    # merged. DENOMINATOR 2: candidate merge pairs = journal-excused merges
    # (the path ran and the ratified rule produced them) + unmerged nodes that
    # still share a phone or email. Unmeasured and zero are BOTH CANNOT-RUN: a
    # broken query must never score better than an honest zero. (The old
    # "must not redden a healthy box" carve-out is deleted; CANNOT-RUN is not red.)
    local opp verdict
    opp="$(_sparql_scalar "$_Q_OPPORTUNITY")"
    verdict="$(adjudicate_clean "$opp")"
    if [ "$verdict" = "UNMEASURED" ]; then
        probe_note "collision opportunities: NOT MEASURED (query returned '${opp}')"
        probe_cannot_run "${_jok}the candidate merge pair count was not measured (query returned '${opp}'), so a zero violation count cannot be told from a vacuous one. CANNOT-RUN, not a pass."
    fi
    probe_note "collision opportunities: ${opp} Person node(s) share a phone or email with another node"
    probe_note "denominator: ${uids} distinct icloud_contact_uid; candidate merge pairs = ${excused} excused merges + ${opp} unmerged shared-key nodes"
    if [ "$verdict" = "UNEXERCISED" ] && [ "${excused:-0}" -eq 0 ]; then
        probe_cannot_run "no Person node carries more than one icloud_contact_uid, but this box presented ZERO candidate merge pairs (${uids} distinct icloud_contact_uid examined, 0 excused merges, 0 Person nodes sharing a phone or email): the resolver had nothing to match on and the RULE 2 write guard was never asked to refuse. The invariant is UNTESTED, not held. CANNOT-RUN, not a pass; do not close #1543 on this run."
    fi
    probe_pass "${_jok}no Person node carries more than one icloud_contact_uid (${uids} distinct examined), over ${excused} excused merges + ${opp} unmerged shared-key nodes as candidate merge pairs, so the zero was earned, not vacuous"
}

# ADJUDICATE THE STRENGTH OF A CLEAN RESULT. Lifted out of run_probe so the
# self-test can drive it; run_probe's behaviour is unchanged.
#
#   UNMEASURED  the opportunity query gave no number -- the zero stands on the
#               identifier control alone, and the record must say so.
#   UNEXERCISED opportunities == 0. The invariant holds and the guard was never
#               asked to do anything. NOT a fault, and NOT proof of the guard.
#   EARNED      opportunities > 0 and no node over-merged.
adjudicate_clean() {
    case "${1}" in
        ''|*[!0-9]*) echo "UNMEASURED"; return ;;
    esac
    if [ "$1" -eq 0 ]; then echo "UNEXERCISED"; else echo "EARNED"; fi
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

    # 4. A CLEAN GRAPH WITH NOTHING TO MERGE IS NOT PROOF OF THE GUARD.
    #    Three states, and the middle one is the whole point: the invariant
    #    holds and the guard was never exercised. If these ever collapse into
    #    one, a fresh-install walk on a sparse account would close #1543 on
    #    evidence that never reached the code.
    s="$(adjudicate_clean 7)"
    if [ "$s" != "EARNED" ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: 7 collision opportunities adjudicated '$s', expected EARNED. A zero that WAS load-bearing would be reported as weak."
    fi
    s="$(adjudicate_clean 0)"
    if [ "$s" != "UNEXERCISED" ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: 0 collision opportunities adjudicated '$s', expected UNEXERCISED. A vacuous pass would read as proof of the RULE 2 guard."
    fi
    s="$(adjudicate_clean "")"
    if [ "$s" != "UNMEASURED" ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: an unanswered opportunity query adjudicated '$s', expected UNMEASURED. Could-not-look would print as a real zero."
    fi
    s="$(adjudicate_clean "no")"
    if [ "$s" != "UNMEASURED" ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: junk adjudicated '$s', expected UNMEASURED."
    fi

    # 5. The name-tier assertion must be able to FAIL (a phone-named survivor),
    #    pass on a clean count over a real denominator, and refuse to call a zero
    #    over no merges a pass.
    s="$(adjudicate_names 3 150)"
    if [ "$s" != "FAIL" ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: 3 of 150 phone-named survivors adjudicated '$s', expected FAIL."
    fi
    s="$(adjudicate_names 0 150)"
    if [ "$s" != "CLEAN" ]; then
        probe_pass "NEGATIVE CONTROL OVER-FIRED: 0 of 150 adjudicated '$s', expected CLEAN."
    fi
    s="$(adjudicate_names 0 0)"
    if [ "$s" != "UNMEASURED" ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: 0 of 0 adjudicated '$s', expected UNMEASURED (a zero over no merges is vacuous)."
    fi
    s="$(adjudicate_names UNAVAILABLE 150)"
    if [ "$s" != "UNMEASURED" ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: an unreadable count adjudicated '$s', expected UNMEASURED."
    fi

    # 6. instr119: the join key is NAMED, masked, and never printed raw.
    #    Synthetic values only (reserved +44 7700 900xxx, example.com).
    local _j
    _j="$(explain_join 2 '{"results":{"bindings":[
      {"side":{"value":"self"},"t":{"value":"phone"},"v":{"value":"+44 7700 900123"}},
      {"side":{"value":"self"},"t":{"value":"email"},"v":{"value":"one@example.com"}},
      {"side":{"value":"urn:x:src1"},"t":{"value":"phone"},"v":{"value":"07700 900123"}},
      {"side":{"value":"urn:x:src1"},"t":{"value":"email"},"v":{"value":"two@example.com"}}]}}')"
    case "$_j" in
        "2 cards; 1 node(s) merged in; joined by phone:"*) ;;
        *) probe_pass "JOIN CONTROL: a shared phone was not named as the join key: ${_j}" ;;
    esac
    case "$_j" in *900123*|*example.com*) probe_pass "JOIN CONTROL: a raw phone or email reached the output: ${_j}" ;; esac
    _j="$(explain_join 3 '{"results":{"bindings":[
      {"side":{"value":"self"},"t":{"value":"name"},"v":{"value":"Jane Doe"}},
      {"side":{"value":"urn:x:src1"},"t":{"value":"name"},"v":{"value":"jane  doe"}}]}}')"
    case "$_j" in "3 cards; 1 node(s) merged in; joined by name:"*) ;; *) probe_pass "JOIN CONTROL: a shared name was not named as the join key: ${_j}" ;; esac
    _j="$(explain_join 2 '{"results":{"bindings":[
      {"side":{"value":"self"},"t":{"value":"email"},"v":{"value":"a@example.com"}},
      {"side":{"value":"urn:x:src1"},"t":{"value":"email"},"v":{"value":"b@example.com"}}]}}')"
    case "$_j" in *"NO shared phone, email or name"*) ;; *) probe_pass "JOIN CONTROL: two nodes with nothing in common were given a join key: ${_j}" ;; esac
    _j="$(explain_join 2 '{"results":{"bindings":[
      {"side":{"value":"self"},"t":{"value":"phone"},"v":{"value":"+44 7700 900124"}},
      {"side":{"value":"self"},"t":{"value":"phone"},"v":{"value":"+44 7700 900125"}}]}}')"
    case "$_j" in *"no node merged in"*"phone x2"*) ;; *) probe_pass "JOIN CONTROL: a node with no merged-in source did not list its candidate keys: ${_j}" ;; esac
    _j="$(explain_join 2 'garbage')"
    case "$_j" in *"NOT MEASURED"*) ;; *) probe_pass "JOIN CONTROL: an unreadable answer did not say NOT MEASURED: ${_j}" ;; esac

    probe_fail "negative control behaved correctly (counted planted over-merges, passed a clean set, survived malformed rows, and told an earned zero from an unexercised one)"
}

probe_main "$@"
