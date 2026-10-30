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
# 🔴 THIS PROBE ASKED A ROUTE NOBODY EVER WROTE (fixed 2026-08-26).
# It pointed at /doctor/api/people/count. MEASURED on the live box:
#
#   /doctor/api/people/count   -> 404
#   /doctor/api/freshness      -> 404      (sibling probe, same class)
#   /doctor/api/health         -> 200      <- POSITIVE CONTROL: the predicate
#                                             works, so those 404s are real
#                                             absences, not a broken probe
#
# The route is absent from the SHIPPING doctor, not merely from this box: the
# vendored vendor/doctor/agent/web_ui.py contains ZERO occurrences of "people/
# count", and the box's copy is BYTE-IDENTICAL to the vendored one (sha256
# 9a160ada279338b3 both sides). So the box is not stale -- the route never
# existed in any build. A repo-wide search finds 0 hits in HR015's doctor/ or
# CM051's vendor/doctor either; control "doctor/api/status" = 3 hits in those
# same files. So this arm reported "doctor UNAVAILABLE" for its whole life and
# the walk read that as "the surfaces could not be compared" rather than "the
# probe is asking for a route nobody wrote".
#
# WHY THE PUBLIC HYDRATION ROUTE, NOT /api/v1/people. Both answer and both
# report the same number (7284 on the box measured). The difference is what
# happens when auth is broken:
#
#     GET /api/v1/hydration/status   200 unauthenticated  <- public by design
#     GET /api/v1/people             401 unauthenticated  <- CONTROL: auth IS
#                                                            enforced generally
#
# On 2026-08-26 a rotated service token left EVERY authenticated /api/v1 route
# 401ing for a day. A count probe that needs a token goes UNAVAILABLE in exactly
# the situation where you most need to know whether the stores agree, and that
# silence is indistinguishable from "the endpoint is missing". The public route
# keeps measuring through an auth outage, and there is no token to plumb into a
# walk log. "Public by design" is not an observation about one box: the shipping
# ical-server hardcodes it at vendor/cm041/assistant_api/ical-server.py:225,
#     _PUBLIC_GET_PATHS = {"/health", "/api/v1/hydration/status"}
# so the exemption travels with the payload.
#
# WHY :8089 AND NOT :8090, given both answer with contacts=7284. They are not
# two rival Doctors; that reading was wrong. install.sh ships ONE Doctor on
# :8089 that PROXIES /api/v1/* to the loopback-only ical-server on :8090
# (DOCTOR_PROXY_PATHS + DOCTOR_GATEWAY_URL in the com.ostler.doctor plist),
# attaching the #200 PWG_SERVICE_TOKEN on the forwarded hop. Both hops are
# real and both are guarded -- vendor/cm041/assistant_api/test_vendor_import.sh
# asserts the ical-server carries the handler AND that install.sh lists the path
# in DOCTOR_PROXY_PATHS.
#
# :8089 is the surface THE CUSTOMER READS. install.sh sets HUB_HOST to
# http://localhost:8089; the app and the browser reach Ostler through the
# Doctor, which is why MSG_WARN_DOCTOR_NOT_RESPONDING says data and pairing may
# be unavailable when it is down. Measuring :8090 direct would step around the
# Doctor and report cheerful agreement while the customer's People page is
# blank. A probe should fail where the customer fails.
DOCTOR_PEOPLE_URL="${OSTLER_DOCTOR_PEOPLE_URL:-http://127.0.0.1:8089/api/v1/hydration/status}"
TOLERANCE_PCT="${OSTLER_PEOPLE_TOLERANCE_PCT:-2}"
# THE ABSOLUTE CAP (Aesop, 2026-09-07, from Track B's Studio run). A percentage
# alone scales the blindness with the store: 2% of 2939 is 58, which hid 25
# orphan vectors. So the allowance is min(pct of the larger count, CAP), and
# both halves are printed so the arithmetic is visible at every n -- at n < 50
# the percentage rounds to 0 and the verdict must say so rather than let an
# integer division pass for a decision. The cap must stay above the mid-ingest
# drift the self-test allows (4 on 6376) and below the smallest real orphan
# set measured (14 on Archie's v1.0.74 walk, 25 on the Studio).
TOLERANCE_CAP="${OSTLER_PEOPLE_TOLERANCE_CAP:-5}"

# STORE CREDENTIAL for the OXIGRAPH surface only (the Doctor surface at :8089 is
# a different auth and is left untouched). Oxigraph 401s to a keyless request on
# every enforce-ON install (#550/#1222); count_oxigraph used to read that 401 as
# UNAVAILABLE, which then adjudicated as INSUFFICIENT ("1 of 2 surfaces
# readable") -- true but silent about WHY. It now presents the install's -K
# config (STORE_CONF_PATH, $HOME-expanded on the box, never the literal
# STORE_CURL_CONF -- that is the #1284 bug) and names the auth/transport reason.
STORE_CURL_CONF="${OSTLER_PROBE_STORE_CURL_CONF:-\$HOME/.ostler/secrets/store-curl.conf}"
STORE_CONF_PATH=""
STORE_AUTH=""
STORE_AUTH_REASON="" # when STORE_AUTH!="conf": WHY (absent / unreadable / empty config)
_OX_CODE_FILE=""

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

# Query Oxigraph with the store credential; record the HTTP code in
# $_OX_CODE_FILE for the MAIN shell to adjudicate (this runs inside $()); echo
# the body. STORE_CONF_PATH is already $HOME-expanded so single-quoting the -K
# path is safe (the #1284 correction).
_ox_curl() {
    local _q="$1" _k="" _out
    [ "$STORE_AUTH" = "conf" ] && _k="-K '${STORE_CONF_PATH}'"
    _out="$(box_run "curl -sS --noproxy '*' -m 10 -G ${_k} '$OXIGRAPH_URL' --data-urlencode 'query=${_q}' -H 'Accept: application/sparql-results+json' -w '\n%{http_code}'")"
    printf '%s\n' "$_out" | tail -n1 > "$_OX_CODE_FILE" 2>/dev/null
    printf '%s' "$_out" | sed '$d'
}

# Adjudicate the oxigraph transport/auth outcome. MAIN shell only (it exits).
_ox_adjudicate() {
    local _what="$1" _code
    _code="$(cat "$_OX_CODE_FILE" 2>/dev/null | tr -d '\r\n ')"
    case "$_code" in
        401|403)
            probe_examined 0 "people-count surfaces"
            if [ "$STORE_AUTH" = "conf" ]; then
                probe_fail "Oxigraph returned HTTP ${_code} on the ${_what} WITH the install's store credential presented (-K, ${STORE_CONF_PATH}). A key the store refuses is a real fault, not a missing probe credential."
            else
                probe_cannot_run "Oxigraph returned HTTP ${_code} on the ${_what} and this run presented NO store credential -- ${STORE_AUTH_REASON:-no usable store credential was resolved}. Store auth is ENFORCED since #550/#1222, so a keyless probe cannot read the count whether or not people exist -- the count was not measured."
            fi
            ;;
        000|'')
            probe_examined 0 "people-count surfaces"
            probe_cannot_run "no HTTP response from ${OXIGRAPH_URL} on the ${_what} -- curl reported no status at all (refused, timed out, proxied, or a bad argument): a TRANSPORT failure, not a result. Nothing was measured."
            ;;
    esac
}

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
    out="$(_ox_curl "$q")"
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
import json,sys
# NOTE: there is deliberately NO regex fallback here any more.
# It used to end with re.search(r"\d+", raw) on unparseable input. Against the
# hydration payload that is actively dangerous: the phases array also carries
# {"key":"graph","count":293461}, so "the first number in the blob" can hand
# back a KNOWLEDGE-GRAPH TRIPLE COUNT dressed up as a count of people, and the
# adjudicator would compare it to Oxigraph and scream about a 286,000-person
# disagreement. A number scraped from arbitrary text is not a measurement.
# Unparseable input is UNAVAILABLE. That is the honest third state.
PEOPLE_PHASE = "contacts"
raw = sys.stdin.read().strip()
if not raw:
    print("UNAVAILABLE"); sys.exit(0)
try:
    # PARSE ONLY -- the shape-walking lives below, deliberately once.
    #
    # Two branches of this file each grew a phases[] reader, and the merge that
    # brought them together made the duplication visible. The rejected one sat
    # INSIDE this try block, above the one below, and had two faults the lower
    # one does not:
    #   - its flat-shape arm used `isinstance(d[k], int)`, and in Python
    #     isinstance(True, int) is True, so {"count": true} printed the string
    #     "True" as a count of people;
    #   - its UNAVAILABLE arm did not exit, so an unrecognised payload printed
    #     UNAVAILABLE and then FELL THROUGH into the reader below, emitting two
    #     lines for one measurement.
    # NOTE: no apostrophes anywhere in this block. The whole script body is
    # passed to python3 -c inside a SINGLE-QUOTED shell string, so one typed
    # apostrophe closes it and bash -n dies on the next parenthesis. Measured:
    # the word "callers" written with an apostrophe broke this file once.
    # Two lines fail the calling shell numeric guard, case $x in *[!0-9]*), so the
    # visible symptom would have been a permanent UNAVAILABLE -- a probe that
    # cannot answer, wearing the face of a surface that cannot be read.
    d = json.loads(raw)
except Exception:
    print("UNAVAILABLE"); sys.exit(0)
if not isinstance(d, dict):
    print("UNAVAILABLE"); sys.exit(0)
# Shape A: the live Doctor -- /api/v1/hydration/status, phases[key=contacts].
for ph in d.get("phases", []) or []:
    if isinstance(ph, dict) and ph.get("key") == PEOPLE_PHASE:
        n = ph.get("count")
        # A phase that has not run yet reports state=pending with NO count.
        # Absent count is UNAVAILABLE, never 0 -- "not counted yet" and
        # "counted, found none" are different facts.
        if isinstance(n, int) and not isinstance(n, bool):
            print(n); sys.exit(0)
        print("UNAVAILABLE"); sys.exit(0)
# Shape B: a flat {"count": N} object, kept so the self-test fixtures and any
# future dedicated endpoint still work.
for k in ("count", "people", "total", "people_count"):
    v = d.get(k)
    if isinstance(v, int) and not isinstance(v, bool):
        print(v); sys.exit(0)
print("UNAVAILABLE")
' 2>/dev/null || printf 'UNAVAILABLE'
}

# ── WHICH PEOPLE MAKE THE GAP (instr119) ─────────────────────────────────
#
# v1.0.118 walk 3: oxigraph=8905 doctor=8247, and nothing said who the 658 were.
# The doctor number is the Qdrant `people` points_count (ical-server.py
# _wiki_people_count), and the only writer of that collection,
# ostler_fda.pwg_ingest._load_people_from_oxigraph, selects
# "?uri a pwg:Person ; pwg:displayName ?d" with NO pwg:mergedInto. So split the
# oxigraph Person count into the three populations that query treats
# differently: named (indexable), unnamed stub (no displayName, never indexed)
# and merged (has mergedInto, pruned by design). OUTPUT ONLY: no verdict reads
# it, and an unreadable breakdown says NOT MEASURED rather than zero.
_Q_BREAKDOWN='PREFIX p: <https://schema.ostler.ai/ontology#>
SELECT (COUNT(DISTINCT ?n) AS ?named) (COUNT(DISTINCT ?u) AS ?unnamed) (COUNT(DISTINCT ?m) AS ?merged) WHERE {
  { ?n a p:Person ; p:displayName ?d . FILTER NOT EXISTS { ?n p:mergedInto ?x } }
  UNION { ?u a p:Person . FILTER NOT EXISTS { ?u p:displayName ?d2 } FILTER NOT EXISTS { ?u p:mergedInto ?x2 } }
  UNION { ?m a p:Person ; p:mergedInto ?x3 }
}'
count_oxigraph_breakdown() {
    if [ "${SELF_TEST_LOCAL:-0}" -eq 1 ]; then printf '%s' "${FAKE_OXI_BREAKDOWN:-UNAVAILABLE}"; return; fi
    _ox_curl "$_Q_BREAKDOWN" | python3 -c '
import json,sys
raw=sys.stdin.read().strip()
try:
    b=json.loads(raw)["results"]["bindings"][0]
    print(int(b["named"]["value"]), int(b["unnamed"]["value"]), int(b["merged"]["value"]))
except Exception:
    print("UNAVAILABLE")
' 2>/dev/null || printf 'UNAVAILABLE'
}

# note_breakdown "<named> <unnamed> <merged>" <oxi> <doc>: pure, prints only.
note_breakdown() {
    local bd="$1" oxi="$2" doc="$3" nm un mg
    set -- $bd
    nm="${1:-}"; un="${2:-}"; mg="${3:-}"
    case "${nm}${un}${mg}" in
        ''|*[!0-9]*) probe_note "breakdown by category : NOT MEASURED (oxigraph answered '${bd}')"; return 0 ;;
    esac
    probe_note "breakdown by category (oxigraph pwg:Person ${oxi} vs doctor ${doc} = Qdrant people points):"
    probe_note "  named, not merged (what the vector writer indexes): ${nm}"
    probe_note "  unnamed stub (no pwg:displayName, never indexed)  : ${un}"
    probe_note "  merged (pwg:mergedInto, pruned by design)         : ${mg}"
    case "$doc" in
        ''|*[!0-9]*) probe_note "  doctor minus indexable named                       : NOT MEASURED (doctor ${doc})" ;;
        *)           probe_note "  doctor minus indexable named                       : $((doc - nm))  (0 = the gap is exactly the unindexed categories)" ;;
    esac
    case "$oxi" in
        ''|*[!0-9]*) : ;;
        *) [ "$((nm + un + mg))" -ne "$oxi" ] && probe_note "  categories sum to $((nm + un + mg)), not ${oxi}: the remainder is typed foaf:Person only, or the graph moved between reads" ;;
    esac
    return 0
}

# ── THE VERDICT COMPARES WHAT A CUSTOMER CAN SEE, ON BOTH SIDES (#3202) ──
#
# v1.0.118 box: oxigraph 8273 vs doctor 8260, a gap of exactly 13 unnamed stubs.
# Stubs MAY exist: they are join anchors that a later name overwrites upward.
# The raw oxigraph count includes them; the doctor number (Qdrant `people`
# points) cannot, because the vector writer selects only named persons. So the
# two raw numbers were never the same population, and that difference, not a
# store defect, was being graded.
#
# Both sides now go through the ONE locked predicate, IMPORTED from the shipped
# people_rules.py (install.sh lays it in ~/.ostler/services/shared/; Ref #664
# locks it across surfaces) -- never copied here. Per node and per point:
# _best_display_name (SHARED RULE B) then _is_nameless_name (SHARED RULE A,
# has_card from the Contacts-card uid, handles from phones and emails). The
# verdict compares the two VISIBLE counts; the stubs are printed beside them.
# If the rules cannot be imported, nothing is compared: CANNOT-RUN, never a
# fallback to the raw numbers.
PEOPLE_RULES_DIR="${OSTLER_PEOPLE_RULES_DIR:-\$HOME/.ostler/services/shared}"
QDRANT_URL="${OSTLER_QDRANT_URL:-http://127.0.0.1:6333}"
QDRANT_COLLECTION="${OSTLER_QDRANT_PEOPLE_COLLECTION:-people}"
read -r -d '' VISIBLE_PY <<'PYVISIBLE'
import json, os, sys
OXI, QD, COLL, CONF, RULES = sys.argv[1:6]
try:
    sys.path.insert(0, RULES)
    from people_rules import is_countable_person
except Exception as exc:
    print("NORULES could not import is_countable_person from people_rules.py in " + RULES + ": " + type(exc).__name__)
    sys.exit(0)
import urllib.request, urllib.error
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
def post(url, data, ctype):
    h = {"Content-Type": ctype, "Accept": "application/sparql-results+json"}
    h.update(H)
    return json.load(urllib.request.urlopen(urllib.request.Request(url, data=data, headers=h), timeout=120))
P = "https://schema.ostler.ai/ontology#"
Q = ("SELECT ?p ?m ?dn ?gn ?fn ?t ?v WHERE { ?p a <" + P + "Person> . "
     "OPTIONAL { ?p <" + P + "mergedInto> ?m } "
     "OPTIONAL { ?p <" + P + "displayName> ?dn } OPTIONAL { ?p <" + P + "givenName> ?gn } "
     "OPTIONAL { ?p <" + P + "familyName> ?fn } "
     "OPTIONAL { ?p <" + P + "hasIdentifier> ?i . ?i <" + P + "identifierType> ?t ; <" + P + "identifierValue> ?v } }")
def judge(dn, gn, fn, phones, emails, card, merged=False):
    # people_rules.is_countable_person: the ONE definition of a person for
    # counting, also applied by the Doctor to Qdrant (ical-server
    # _wiki_people_count). Returns (hidden, stub).
    ok = is_countable_person(dn, gn, fn, list(emails), list(phones), has_card=bool(card), merged=merged)
    return (not ok), not (dn or gn or fn)
try:
    nodes = {}
    for b in post(OXI, Q.encode(), "application/sparql-query")["results"]["bindings"]:
        n = nodes.setdefault(b["p"]["value"], {"dn": "", "gn": "", "fn": "", "ph": set(), "em": set(), "card": False, "m": False})
        if "m" in b: n["m"] = True
        for k in ("dn", "gn", "fn"):
            if k in b and not n[k]:
                n[k] = b[k]["value"]
        t = b.get("t", {}).get("value"); v = b.get("v", {}).get("value", "")
        if t == "phone": n["ph"].add(v)
        elif t == "email": n["em"].add(v)
        elif t == "icloud_contact_uid" and v.strip(): n["card"] = True
    vo = so = ho = 0
    merged_nodes = sum(1 for n in nodes.values() if n["m"])
    countable_uris = set()
    for u, n in nodes.items():
        if n["m"]:
            continue
        hidden, stub = judge(n["dn"], n["gn"], n["fn"], n["ph"], n["em"], n["card"])
        if not hidden:
            vo += 1; countable_uris.add(u)
        elif stub: so += 1
        else: ho += 1
    vq = hq = tq = 0; nxt = None; qd_uris = set(); with_uri = 0
    while True:
        body = {"limit": 1000, "with_payload": ["display_name", "given_name", "family_name", "emails", "phones", "icloud_uid", "person_uri"], "with_vector": False}
        if nxt is not None:
            body["offset"] = nxt
        h = {"Content-Type": "application/json"}; h.update(H)
        r = json.load(urllib.request.urlopen(urllib.request.Request(QD + "/collections/" + COLL + "/points/scroll",
                      data=json.dumps(body).encode(), headers=h), timeout=60))["result"]
        for pt in r["points"]:
            pl = pt.get("payload") or {}
            tq += 1
            if pl.get("person_uri"):
                qd_uris.add(pl["person_uri"]); with_uri += 1
            hidden, _ = judge(pl.get("display_name"), pl.get("given_name"), pl.get("family_name"),
                              pl.get("phones") or [], pl.get("emails") or [], (pl.get("icloud_uid") or "").strip())
            if hidden: hq += 1
            else: vq += 1
        nxt = r.get("next_page_offset")
        if nxt is None:
            break
    # THE EMBED QUEUE, observed rather than inferred: the customer-visible graph
    # people with no vector point yet. Nameless and merged-away people are not in
    # it (they never get a vector by design). "-" when the vector points carry no
    # person_uri at all, because then nothing can be joined and "0 waiting" would
    # be a manufactured clean answer.
    if tq and not with_uri:
        aw = "-"
    else:
        aw = str(len(countable_uris - qd_uris))
    # The people_index writer own completion marker, and the box clock it is
    # compared with (the marker is stamped on the box, so skew is impossible).
    ist, iep = "-", "-"
    try:
        import calendar, time as _t
        kv = {}
        for line in open(os.path.expanduser("~/.ostler/state/source_activity/people_index.tsv"), encoding="utf-8"):
            if "=" in line:
                k, v = line.rstrip("\n").split("=", 1); kv[k] = v
        ist = kv.get("last_status", "-") or "-"
        ls = kv.get("last_success_at", "")
        iep = str(calendar.timegm(_t.strptime(ls, "%Y-%m-%dT%H:%M:%SZ"))) if ls else "-"
    except Exception:
        pass
    import time as _t2
    print("OK %d %d %d %d %d %d %d %d %s %s %s %d" % (vo, so, ho, len(nodes) - merged_nodes, vq, hq, tq, merged_nodes, aw, ist, iep, int(_t2.time())))
except urllib.error.HTTPError as exc:
    print("CANNOTRUN HTTP %d from %s" % (exc.code, exc.geturl() if hasattr(exc, "geturl") else "a store"))
except Exception as exc:
    print("CANNOTRUN " + type(exc).__name__ + " " + str(exc)[:120])
PYVISIBLE

read_visible() {
    if [ "${SELF_TEST_LOCAL:-0}" -eq 1 ]; then printf '%s' "${FAKE_VISIBLE:-CANNOTRUN self-test-unset}"; return; fi
    box_run "python3 - '${OXIGRAPH_URL}' '${QDRANT_URL}' '${QDRANT_COLLECTION}' '${STORE_CONF_PATH}' \"${PEOPLE_RULES_DIR}\" <<'PYVISIBLE'
${VISIBLE_PY}
PYVISIBLE"
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

    local diff hi cap
    cap="${4:-${TOLERANCE_CAP:-5}}"
    if [ "$a" -ge "$b" ]; then diff=$((a - b)); hi="$a"; else diff=$((b - a)); hi="$b"; fi
    local pct_allowed=$(( hi * tol / 100 ))
    local allowed="$pct_allowed"
    [ "$allowed" -gt "$cap" ] && allowed="$cap"
    # The arithmetic is PRINTED, both halves, so a 0 at small n reads as
    # "2% of 1 = 0" and not as an unexplained refusal, and a 58 at large n
    # reads as "capped to 5" and not as a tolerance that quietly grew.
    local arith
    arith="$(printf 'allowed = min(%s%% of %s = %s, cap %s) = %s' "$tol" "$hi" "$pct_allowed" "$cap" "$allowed")"

    if [ "$diff" -gt "$allowed" ]; then
        # A DISAGREE that the OLD arithmetic would have passed says so in the
        # verdict itself, because that sentence travels with the walk record to
        # whoever reads two adjacent records (Archie, 2026-09-07): v1.0.74
        # recorded 2008 vs 2018 as PASS under 2% alone (allowance 40); under
        # the cap it is FAIL on identical data. That is the cap working, not a
        # product regression, and it must not be bisected as one.
        if [ "$diff" -le "$pct_allowed" ]; then
            printf 'DISAGREE oxigraph=%s doctor=%s differ by %s, above the allowance (%s). NOTE: this gap passed under the pre-2026-09-07 rule (%s%% alone, allowance %s); the cap of %s landed in CM051 #1799 and a walk before it would have read PASS on the same data. Not a v1.0.75 regression to bisect.' "$a" "$b" "$diff" "$arith" "$tol" "$pct_allowed" "$cap"
            return
        fi
        printf 'DISAGREE oxigraph=%s doctor=%s differ by %s, above the allowance (%s)' "$a" "$b" "$diff" "$arith"
        return
    fi
    printf 'AGREE oxigraph=%s doctor=%s differ by %s, within the allowance (%s)' "$a" "$b" "$diff" "$arith"
}

# ── THE CONVERGE WINDOW, AND WHY THIS PROBE MUST NOT MEASURE INSIDE IT ──────
#
# MEASURED 2026-09-08 on the v1.0.75 walk box, and this probe's FAIL on that
# walk was entirely an artefact of it:
#
#   03:25:09Z  dedupe-converge SIGKILLed at its budget      (.killed written)
#   03:29-03:45  post_walk_qa runs -> oxigraph=1838 doctor=1859, FAIL by 21
#   03:49:25Z  the catch-up agent finishes                  (.done written)
#   05:27Z     6 paired samples, 20s apart: 1882 = 1882, ZERO drift
#
# The 300s install budget is DELIBERATE (install.sh, OSTLER_DEDUPE_INSTALL_BUDGET_S):
# the critical path lands the obvious merges and hands COMPLETION to the
# ostler-dedupe-catchup LaunchAgent so the customer does not wait ~25 minutes.
# So a box in this window is behaving exactly as designed, and the two surfaces
# are a moving target rather than a disagreement -- hydration writes reach the
# Doctor's counter before the RDF is committed. Both counts ROSE to a common
# value (oxigraph +44, doctor +23); un-merged duplicates converging would have
# made them FALL, which is how we know this is lag and not lost merges.
#
# A probe that reports FAIL on a correctly-behaving box is not a defect
# detector, it is noise that trains people to ignore it. So: wait for the
# catch-up, bounded, then measure. If the wait expires the honest verdict is
# CANNOT-RUN -- the counts were never comparable, which is not the same as
# their disagreeing.
#
# WHY BOTH MARKERS ARE READ, not just .done. Absence of .done alone cannot
# distinguish "the catch-up is still running" from "the converge never ran at
# all" (no identity_resolver on this box) from "it completed in-band before
# these markers existed". Only .killed present AND .done absent is the
# in-flight window. Every other combination measures immediately, so this
# cannot become a blanket delay that hides a real disagreement.
CONVERGE_WAIT_S="${OSTLER_PEOPLE_CONVERGE_WAIT_S:-1800}"
# How long to keep re-reading both surfaces waiting for a repeated pair, and
# the gap between reads. Deliberately short by comparison with the converge
# wait: this is settling, not catching up.
STABILITY_WAIT_S="${OSTLER_PEOPLE_STABILITY_WAIT_S:-300}"
STABILITY_STEP_S="${OSTLER_PEOPLE_STABILITY_STEP_S:-20}"
# How many CONSECUTIVE identical pairs before adjudicating. 2 was measurably
# not enough: a real plateau held for four reads 25s apart and then moved.
STABILITY_RUNS="${OSTLER_PEOPLE_STABILITY_RUNS:-3}"
CONVERGE_STATE_DIR="${OSTLER_PROBE_STATE_DIR:-\$HOME/.ostler/state}"

# THE CLASSIFIER IS A PURE FUNCTION so the self-test can drive the REAL
# decision instead of a fixture that just echoes the answer it wants. It takes
# the two markers' MTIMES in epoch seconds, 0 meaning absent, and echoes
# DONE | INFLIGHT | NOMARKER.
#
# WHY MTIME AND NOT MERE EXISTENCE. A box that was killed and then caught up
# carries BOTH markers for ever, so "killed wins" would make every later walk on
# that box wait out the whole budget and then refuse on perfectly settled counts.
# The first draft therefore let .done win by existence alone -- and that is
# correct ONLY while something guarantees a stale .done cannot sit beside a fresh
# .killed. Today something does: install.sh clears BOTH markers with one rm -f at
# the start of every converge (verified at install.sh:28723; .done is touched on
# in-band success at 28768, .killed written on kill at 28825). But that is a
# CROSS-FILE INVARIANT the probe would be silently relying on and never naming,
# and if a future install.sh dropped or moved that rm, this probe would quietly
# go back to measuring a moving target with nothing to catch it.
#
# Worse, the invariant is not even wholly install.sh's to keep: the catch-up
# LaunchAgent writes .done from its OWN script (the DONE_MARKER at :26731), so a
# catch-up still alive from a previous cycle can touch .done AFTER a new converge
# has cleared it. Existence cannot tell that apart from a settled box.
#
# Comparing mtimes removes the dependency entirely: a .done OLDER than .killed is
# stale by construction, whoever wrote it and whenever the markers were last
# cleared. Aesop found the existence version's exposure on review; this closes it
# rather than documenting it.
_converge_classify() {
    local _done="$1" _killed="$2"
    # "COULD NOT LOOK" IS NOT "NOTHING THERE". An unreadable mtime pair used to
    # classify NOMARKER, which measures immediately -- so a box that happened to
    # be mid-catch-up at that instant would be sampled as a moving target on the
    # strength of a failed read. Absent markers are 0 0, which IS numeric and
    # still classifies NOMARKER; only a malformed read reaches UNREADABLE.
    # (Aesop, on review of the mtime version.)
    case "$_done$_killed" in ''|*[!0-9]*) printf 'UNREADABLE'; return ;; esac
    # No .done at all: in flight if a kill is recorded, otherwise no converge here.
    if [ "$_done" -eq 0 ]; then
        [ "$_killed" -gt 0 ] && printf 'INFLIGHT' || printf 'NOMARKER'
        return
    fi
    # .done exists. It only means "settled" if it is not older than the kill it
    # is meant to have followed. Equal mtimes settle: a same-second catch-up is
    # the ordinary case on a fast box, and refusing there would reintroduce the
    # stall this function exists to avoid.
    if [ "$_killed" -gt 0 ] && [ "$_done" -lt "$_killed" ]; then printf 'INFLIGHT'; return; fi
    printf 'DONE'
}

# Sets _CONVERGE_RESULT to SETTLED | NOT_IN_WINDOW | EXPIRED <waited>.
#
# IT DOES NOT ECHO ITS RESULT, and that is not a style choice. probe_note writes
# to STDOUT, so wrapping this in $( ) captured every note into the return value
# and made the first word of the "token" the first word of a note -- the EXPIRED
# branch then never matched and the probe measured a moving target anyway, which
# is the very thing this function exists to prevent. Caught on the box, not in
# review: the self-test could not see it because SELF_TEST never reaches here.
_await_converge() {
    _CONVERGE_RESULT=""
    local _st _waited=0 _step=15 _bits
    # ONE round trip reads both markers; the poll below only re-reads .done.
    # ONE round trip reads both mtimes (0 = absent). stat -f %m is BSD, which is
    # what the box runs; a missing file yields 0 rather than an empty field, so
    # the classifier always gets two integers or the read is declared failed.
    _bits="$(box_run "for f in dedupe-converge.done dedupe-converge.killed; do /usr/bin/stat -f %m \"${CONVERGE_STATE_DIR}/\$f\" 2>/dev/null || printf 0; printf ' '; done" | tr -d '\r\n' )"
    # A round trip that answers nothing is not "no markers": say so and measure
    # anyway, rather than inventing a settled box out of a failed read.
    set -- $_bits
    if [ "$#" -ne 2 ]; then
        _CONVERGE_RESULT="UNREADABLE ${_bits:-<empty>}"; return
    fi
    _st="$(_converge_classify "$1" "$2")"
    if [ "$_st" = "UNREADABLE" ]; then _CONVERGE_RESULT="UNREADABLE $1 $2"; return; fi
    case "$_st" in
        DONE|NOMARKER) _CONVERGE_RESULT='NOT_IN_WINDOW'; return ;;
    esac
    probe_note "dedupe-converge was killed at its budget and the catch-up has not finished; waiting up to ${CONVERGE_WAIT_S}s before measuring (counts inside this window are provisional by design)"
    while [ "$_waited" -lt "$CONVERGE_WAIT_S" ]; do
        sleep "$_step"
        _waited=$((_waited + _step))
        _bits="$(box_run "for f in dedupe-converge.done dedupe-converge.killed; do /usr/bin/stat -f %m \"${CONVERGE_STATE_DIR}/\$f\" 2>/dev/null || printf 0; printf ' '; done" | tr -d '\r\n' )"
        set -- $_bits
        if [ "$#" -eq 2 ] && [ "$(_converge_classify "$1" "$2")" = "DONE" ]; then
            probe_note "catch-up finished after ${_waited}s of waiting; counts are now final"
            _CONVERGE_RESULT='SETTLED'; return
        fi
    done
    _CONVERGE_RESULT="EXPIRED ${_waited}"
}

# ── DO NOT READ WHILE THE EMBED QUEUE IS NON-EMPTY (v1.0.121 trial) ─────────
#
# MEASURED on the v1.0.121 trial: oxigraph 8937 vs Doctor 8837, a gap of 100.
# One Person reached oxigraph at 15:35:15Z and Qdrant at 15:45:18Z, TEN MINUTES
# later. That was embed lag during live ingest, not a lost vector. The
# stability check above cannot see it: it asks whether the counts have stopped
# MOVING for a minute or so, and a queue that drains in ten minutes looks
# perfectly still for the first nine.
#
# So ask the queue, do not sample the numbers. There is no embed-queue length in
# the product (searched: no spool, backlog or pending-embed counter anywhere in
# vendor/ or install.sh), so the queue is OBSERVED, and the signal is NAMED:
#
#   PEOPLE_INDEX_DRAINED  =  the customer-visible graph people that have no
#                            vector point yet (the "awaiting-embed set", from
#                            VISIBLE_PY, counted by the same people_rules
#                            predicate on the graph side) is EMPTY,
#       or, when it is not empty,
#   PEOPLE_INDEX_RAN      =  the vector writer's OWN completion marker
#                            (~/.ostler/state/source_activity/people_index.tsv,
#                            last_status=ok and last_success_at STRICTLY LATER
#                            than the moment this probe first saw those people
#                            waiting, with the hourly tick idle at that moment)
#                            says a run that began after they were seen has
#                            finished and they are STILL without a vector.
#                            That is not lag. It is a drop, and it is graded.
#
# Anything else is WAIT, bounded by OSTLER_PEOPLE_EMBED_DRAIN_WAIT_S (default
# 2700 s, 45 minutes). No signal inside the bound is CANNOT-RUN: the counts
# were never comparable. The tolerance and the cap are NOT touched; this
# changes WHEN the stores are read, never what counts as agreement.
#
# People with no name never get a vector by design. They are outside the
# awaiting-embed set (the predicate hides them) and outside both counts: the
# graph side counts with people_rules.is_countable_person, and the Doctor
# counts Qdrant points with the same function (ical-server _wiki_people_count,
# #3245), so the two sides exclude the same people and neither can lag on one.
EMBED_DRAIN_WAIT_S="${OSTLER_PEOPLE_EMBED_DRAIN_WAIT_S:-2700}"
EMBED_DRAIN_STEP_S="${OSTLER_PEOPLE_EMBED_DRAIN_STEP_S:-30}"

# THE CLASSIFIER IS A PURE FUNCTION so the self-test drives the real decision.
# _embed_drain_classify <awaiting> <index_status> <index_success_epoch> <first_seen_epoch>
# echoes DRAINED_EMPTY | DRAINED_BY_RUN | WAIT | UNMEASURED.
_embed_drain_classify() {
    local aw="$1" ist="$2" iep="$3" t0="$4"
    # "-" or junk is "could not look", never "nothing waiting".
    case "$aw" in ''|*[!0-9]*) printf 'UNMEASURED'; return ;; esac
    if [ "$aw" -eq 0 ]; then printf 'DRAINED_EMPTY'; return; fi
    case "$iep$t0" in ''|*[!0-9]*) printf 'WAIT'; return ;; esac
    if [ "$ist" = "ok" ] && [ "$iep" -gt "$t0" ]; then printf 'DRAINED_BY_RUN'; return; fi
    printf 'WAIT'
}

# Sets _DRAIN_RESULT to one of
#   DRAINED_EMPTY <waited> | DRAINED_BY_RUN <waited> <awaiting> <index_epoch>
#   EXPIRED <waited> <awaiting> <status> <index_epoch> <first_seen>
#   UNREADABLE <detail>
# It does not echo (see _await_converge: probe_note writes to stdout).
_await_embed_drain() {
    _DRAIN_RESULT=""
    local waited=0 t0="" prev_aw="" vis aw ist iep nowe cls tick label
    label="${OSTLER_INGEST_TICK_LABEL:-com.ostler.fda-rerun}"
    while :; do
        tick="$(_probe_tick_state "$label")"
        _PROBE_TICK_FAKE_CURSOR=$((_PROBE_TICK_FAKE_CURSOR + 1))
        case "$tick" in
            UNREADABLE*) _DRAIN_RESULT="UNREADABLE the state of ${label} could not be read (${tick#UNREADABLE })"; return ;;
        esac
        if [ "$tick" = "running" ]; then
            # The writer is mid-run: nothing seen now is a sighting.
            t0=""; prev_aw=""
        else
            vis="$(read_visible)"
            case "$vis" in
                OK\ *) : ;;
                *) _DRAIN_RESULT="UNREADABLE the customer-visible read did not complete: ${vis:-<empty answer>}"; return ;;
            esac
            set -- ${vis#OK }
            aw="${9:-}"; ist="${10:-}"; iep="${11:-}"; nowe="${12:-}"
            # Seen waiting for the first time, or MORE people waiting than at
            # the last look: the clock restarts, because a run that began
            # before the newcomers existed cannot have embedded them.
            if [ -n "$aw" ] && [ "$aw" != "-" ] && [ "$aw" -gt 0 ] 2>/dev/null; then
                if [ -z "$t0" ] || { [ -n "$prev_aw" ] && [ "$aw" -gt "$prev_aw" ]; }; then t0="$nowe"; fi
            fi
            prev_aw="$aw"
            cls="$(_embed_drain_classify "$aw" "$ist" "$iep" "$t0")"
            case "$cls" in
                DRAINED_EMPTY)  _DRAIN_RESULT="DRAINED_EMPTY ${waited}"; return ;;
                DRAINED_BY_RUN) _DRAIN_RESULT="DRAINED_BY_RUN ${waited} ${aw} ${iep}"; return ;;
                UNMEASURED)     _DRAIN_RESULT="UNREADABLE the awaiting-embed set could not be measured (the vector points carry no person_uri, or the read answered '${aw:-<empty>}')"; return ;;
            esac
        fi
        if [ "$waited" -ge "$EMBED_DRAIN_WAIT_S" ]; then
            _DRAIN_RESULT="EXPIRED ${waited} ${aw:--} ${ist:--} ${iep:--} ${t0:--} tick=${tick%% *}"
            return
        fi
        [ "$waited" -eq 0 ] && probe_note "embed queue: ${aw:-?} customer-visible graph people have no vector yet (hourly tick: ${tick%% *}); holding the reads until people_index has run or the queue is empty (budget ${EMBED_DRAIN_WAIT_S}s)"
        sleep "$EMBED_DRAIN_STEP_S"
        waited=$((waited + EMBED_DRAIN_STEP_S))
    done
}

# Re-read both surfaces until a full pair repeats STABILITY_RUNS times, bounded
# by STABILITY_WAIT_S. Sets oxi doc _pair _prev_pair _runs _stable _swaited and
# _STABILITY_WINDOW in the caller (run_probe declares them local).
_await_stable_pair() {
    _prev_pair=""; _runs=0; _stable=0; _swaited=0
    while :; do
        oxi="$(count_oxigraph)"
        doc="$(count_doctor)"
        _pair="${oxi}/${doc}"
        if [ "$_pair" = "$_prev_pair" ]; then
            _runs=$((_runs + 1))
            [ "$_runs" -ge "$STABILITY_RUNS" ] && { _stable=1; break; }
        else
            [ -n "$_prev_pair" ] && probe_note "counts moved ${_prev_pair} -> ${_pair} after ${_swaited}s; the graph is still being written"
            _runs=0
        fi
        [ "$_swaited" -ge "$STABILITY_WAIT_S" ] && break
        _prev_pair="$_pair"
        sleep "$STABILITY_STEP_S"
        _swaited=$((_swaited + STABILITY_STEP_S))
    done
    _STABILITY_WINDOW="$(( _runs * STABILITY_STEP_S ))"
}

run_probe() {
    if ! box_reachable; then
        probe_cannot_run "cannot reach box ${OSTLER_BOX_HOST:-(local)} over ssh; no counts read"
    fi

    # Do not adjudicate a moving target. See the block above.
    local _cw _cw_token
    _await_converge; _cw="$_CONVERGE_RESULT"; _cw_token="${_cw%% *}"
    if [ "$_cw_token" = "UNREADABLE" ]; then
        probe_examined 0 "people-count surfaces"
        probe_cannot_run "could not read the dedupe-converge marker mtimes on the box (got '${_cw#* }'), so this run cannot tell a settled graph from one still being merged by the catch-up. Counts inside that window are provisional by design, and a failed look is not evidence there is nothing to wait for."
    fi
    if [ "$_cw_token" = "EXPIRED" ]; then
        probe_examined 0 "people-count surfaces"
        probe_cannot_run "the install-time dedupe-converge was killed at its budget and its catch-up had still not written dedupe-converge.done after ${_cw#* }s of waiting. People counts inside that window are PROVISIONAL BY DESIGN -- the Doctor's counter leads the RDF commit -- so the two surfaces were never comparable. That is a probe that could not measure, NOT two surfaces that disagree, and it must not be recorded as either a pass or a defect."
    fi

    _OX_CODE_FILE="$(mktemp 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/pca_ox_code.$$")"
    _store_resolve

    # ── .done IS NOT "THE GRAPH HAS STOPPED CHANGING" ───────────────────────
    #
    # MEASURED ON THE v1.0.76 WALK, and it is a defect in the wait added above
    # rather than in the box. The converge markers said settled -- .done at
    # 09:24:22Z, newer than .killed at 08:59:56Z -- so the classifier correctly
    # returned DONE and this probe measured immediately, exactly as designed.
    # It read oxigraph=1870 doctor=1883 and called a 13 disagreement.
    #
    # Twenty minutes later the same box read oxigraph=1894, with the mergedInto
    # tombstone count up from 13 to 24. THE GRAPH WAS STILL BEING WRITTEN. The
    # 13 was never a settled quantity, and a verdict computed on it is a verdict
    # about an instant, not about the box.
    #
    # dedupe-converge.done means THE DEDUPE CATCH-UP FINISHED. Hydration
    # continues past it. So the marker is a proxy for the property we care
    # about, and it is the wrong proxy.
    #
    # SO STOP USING A PROXY. The property is "the counts have stopped moving",
    # and that is directly observable: read both surfaces twice, and only
    # adjudicate when a full pair repeats. A moving graph produces a different
    # pair and buys another round, bounded. On expiry this is CANNOT-RUN --
    # counts that never settled were never comparable, which is not the same as
    # counts that disagree.
    #
    # The .done wait above is KEPT rather than replaced. It is still the right
    # thing to wait for before starting to sample: it avoids burning the
    # stability budget during a catch-up that is guaranteed to be moving.
    # TWO CONSECUTIVE READS WAS NOT ENOUGH, AND I HAVE THE COUNTEREXAMPLE.
    # On 2026-09-08 this box sat at oxigraph=1894 doctor=1883 across FOUR reads
    # 25s apart -- a plateau, not a settled graph. Minutes later the doctor
    # caught up to 1894 and the surfaces agreed exactly. A 2-read check would
    # have called that plateau stable and reported a disagreement that did not
    # exist. I reported it as one, three times, before measuring again.
    #
    # SO THIS CANNOT BE PROVED, ONLY BOUNDED. Sampling cannot demonstrate that a
    # graph has stopped changing; it can only say the counts did not move across
    # a stated window. The verdict therefore CARRIES THAT WINDOW, so a reader
    # judges the claim with its own limits attached rather than reading
    # "disagree" as settled fact. Neither marker helps: dedupe-converge.done had
    # fired, and hydration reported contacts state=done, while the count was
    # still moving through both.
    # ─── DO NOT GRADE THE STORES WHILE THE INGEST TICK IS MINTING ──────────
    # The hourly com.ostler.fda-rerun moves the graph and the vector store apart
    # by design between its legs. v1.0.89 read the difference and called it a
    # disagreement. Hold, then read; a tick that will not stop is CANNOT-RUN,
    # never a pass, and so is a state that could not be read at all.
    box_wait_ingest_quiet
    case $? in
        0) : ;;
        1) probe_cannot_run "$PROBE_TICK_DETAIL" ;;
        2) probe_cannot_run "$PROBE_TICK_DETAIL" ;;
    esac

    local oxi doc _prev_pair="" _pair _runs=0 _stable=0 _swaited=0
    _await_stable_pair
    if [ "$_stable" -ne 1 ]; then
        probe_examined 0 "people-count surfaces"
        probe_cannot_run "the two counts never stopped moving within ${_swaited}s (last two readings ${_prev_pair} then ${_pair}). A verdict computed while the graph is still being written describes an instant, not the box -- dedupe-converge.done had already fired, which is why this probe waits for STABILITY and not for that marker."
    fi
    probe_note "counts held at ${_pair} across ${STABILITY_RUNS} consecutive reads spanning ${_STABILITY_WINDOW}s -- a bound, not a proof that writing stopped"

    # Name the oxigraph auth/transport reason BEFORE the count comparison, so a
    # keyless 401 reads as "enforced, no key, not measured" and not as a vague
    # "1 of 2 surfaces readable". Exits on 000/401.
    _ox_adjudicate "oxigraph people count"
    # The embed queue must be drained before ANY customer-visible read. Held
    # AFTER the auth/transport adjudication above, so a refused store still
    # reports its own reason and not a wait.
    local _dr _dr_token
    _await_embed_drain; _dr="$_DRAIN_RESULT"; _dr_token="${_dr%% *}"
    case "$_dr_token" in
        DRAINED_EMPTY)  probe_note "embed queue: EMPTY (every customer-visible graph person has a vector) after ${_dr#* }s of waiting; reading now" ;;
        DRAINED_BY_RUN) set -- ${_dr#* }
                        probe_note "embed queue: ${2} customer-visible graph people STILL have no vector although people_index completed a run (last_success_at epoch ${3}) that began after they were first seen. That is not embed lag; it is read and graded as measured." ;;
        EXPIRED)        set -- ${_dr#* }
                        probe_examined 0 "people-count surfaces"
                        probe_cannot_run "the embed queue never drained within ${1}s: ${2} customer-visible graph people still had no vector, people_index.tsv said last_status=${3} last_success_at(epoch)=${4}, first seen waiting at epoch ${5}, hourly tick ${6#tick=}. NO DRAIN SIGNAL ARRIVED, so the graph and the vector store were never comparable. Embed lag (a Person reached the graph ten minutes before its vector on the v1.0.121 trial) is not a disagreement and must not be recorded as one. The tolerance and the cap were not touched." ;;
        *)              probe_examined 0 "people-count surfaces"
                        probe_cannot_run "the embed queue could not be observed: ${_dr#* }. Without a drain signal the stores cannot be compared; nothing was measured." ;;
    esac
    # The drain can take minutes: the pair read before it is stale. Re-establish
    # a stable pair, and say if it moved.
    local _pre_pair="$_pair"
    _await_stable_pair
    if [ "$_stable" -ne 1 ]; then
        probe_examined 0 "people-count surfaces"
        probe_cannot_run "the embed queue drained but the two counts then never stopped moving within ${_swaited}s (last two readings ${_prev_pair} then ${_pair}). A verdict computed while the graph is still being written describes an instant, not the box."
    fi
    [ "$_pair" = "$_pre_pair" ] || probe_note "counts moved ${_pre_pair} -> ${_pair} while the embed queue drained; the later, stable pair is the one graded"
    probe_note "oxigraph SPARQL count : $oxi"
    probe_note "doctor api count      : $doc"
    case "$oxi" in ''|*[!0-9]*) : ;; *) note_breakdown "$(count_oxigraph_breakdown)" "$oxi" "$doc" ;; esac

    local readable=0
    for v in "$oxi" "$doc"; do [ "$v" != "UNAVAILABLE" ] && readable=$((readable + 1)); done
    probe_examined "$readable" "of 2 people-count surfaces readable"

    # ── WHY, NOT JUST WHETHER (CM041 #162) ───────────────────────────
    #
    # This probe could always say the two counts disagree and never say
    # what caused it, and that gap is why it was carried walk after walk
    # as a number rather than as a defect. Root-caused 2026-09-18: two
    # merge paths disagreed, one retired the discard's Person type and
    # the other did not, and neither deleted the vector point. The
    # install now runs a repair and records its OUTCOME, not just its
    # log, at ~/.ostler/state/merge_consistency_repair.tsv.
    #
    # THE ABSENT FILE IS ITSELF AN ANSWER, and it is spelled out rather
    # than left blank: it means this box was installed by a build that
    # predates the repair, which is a different fact from a repair that
    # ran and could not read a store. Read with no branch for absence,
    # those two print identically.
    local _MCR_FILE _MCR_SUFFIX _mcr_raw _mcr_verdict _mcr_reason _mcr_at
    _MCR_FILE=".ostler/state/merge_consistency_repair.tsv"
    _mcr_raw="$(box_run "cat \"\$HOME/${_MCR_FILE}\" 2>/dev/null" 2>/dev/null || true)"
    if [ -z "$_mcr_raw" ]; then
        _MCR_SUFFIX=" MERGE-CONSISTENCY REPAIR: no record at ~/${_MCR_FILE}, so this box was installed by a build that predates it (CM041 #162). That is not evidence the repair failed, it is evidence it was never offered."
    else
        _mcr_verdict="$(printf '%s\n' "$_mcr_raw" | awk -F'\t' '$1=="verdict" {print $2; exit}')"
        _mcr_reason="$(printf '%s\n' "$_mcr_raw" | awk -F'\t' '$1=="reason" {print $2; exit}')"
        _mcr_at="$(printf '%s\n' "$_mcr_raw" | awk -F'\t' '$1=="ran_at" {print $2; exit}')"
        _MCR_SUFFIX=" MERGE-CONSISTENCY REPAIR: ${_mcr_verdict:-UNREADABLE} at ${_mcr_at:-an unrecorded time} -- ${_mcr_reason:-the record carried no reason}."
    fi
    probe_note "merge-consistency repair:${_MCR_SUFFIX}"

    # The verdict: CUSTOMER-VISIBLE counts, both sides through the one imported
    # predicate (see VISIBLE_PY). The raw pair above is the stability
    # instrument and stays printed; it is no longer what is graded.
    local vis vo so ho no vq hq tq mo
    vis="$(read_visible)"
    case "$vis" in
        OK\ *) : ;;
        NORULES\ *) probe_cannot_run "${vis#NORULES } -- the customer-visible counts cannot be taken without the shipped predicate, and the raw counts are not the same population (stubs), so nothing is compared" ;;
        *) probe_cannot_run "the customer-visible count read did not complete: ${vis:-<empty answer>}" ;;
    esac
    set -- ${vis#OK }
    vo="$1"; so="$2"; ho="$3"; no="$4"; vq="$5"; hq="$6"; tq="$7"; mo="${8:-0}"
    probe_note "customer-visible (people_rules.is_countable_person, imported; named and not merged away): oxigraph ${vo} of ${no} unmerged nodes (${mo} merged-away Person nodes excluded), qdrant ${vq} of ${tq} points; stubs=${so} (unnamed join anchors, allowed), hidden by the predicate: oxigraph ${ho}, qdrant ${hq}"

    # v1.0.121: the GRAPH side (counted here) against the DOCTOR's number,
    # which now applies the same definition to Qdrant (ical-server
    # _wiki_people_count). Each store is counted by its own reader; the
    # probe's own Qdrant scroll (${vq}) is printed as a cross-check only.
    [ "$vq" = "$doc" ] || probe_note "  note: the probe's own Qdrant count (${vq}) differs from the doctor api count (${doc})"
    local r token detail
    r="$(adjudicate_counts "$vo" "$doc" "$TOLERANCE_PCT")"
    token="${r%% *}"; detail="${r#* }; customer-visible, stubs=${so}"

    case "$token" in
        DISAGREE)     probe_fail "people counts disagree: $detail (task #273).${_MCR_SUFFIX} A count is the simplest claim the product makes. STABILITY: the pair held for ${_STABILITY_WINDOW}s across ${STABILITY_RUNS} reads -- that BOUNDS the motion, it does not prove writing stopped, and a plateau of exactly this shape once produced a disagreement that vanished minutes later." ;;
        INSUFFICIENT) probe_cannot_run "$detail" ;;
        *)            probe_pass "$detail" ;;
    esac
}

self_test() {
    SELF_TEST_LOCAL=1
    probe_examined 25 "synthetic count pairs, converge-marker mtime combinations and embed-drain classifications (negative control)"
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

    # THE CAP. The Studio, 2026-09-07: 2939 vs 2914 is 25 orphan vectors and
    # 2% of 2939 is 58, so the percentage alone read it as AGREE.
    r="$(adjudicate_counts 2939 2914 2)"
    if [ "${r%% *}" != "DISAGREE" ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: 25 orphans on 2939 adjudicated as '${r%% *}'. The percentage hides them and the cap did not bind."
    fi
    # SMALL n, HONESTLY. On a one-person seed, 1 vs 0 is the doctor losing the
    # only person there is; the allowance is 0 and the verdict must say why.
    r="$(adjudicate_counts 1 0 2)"
    if [ "${r%% *}" != "DISAGREE" ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: 1 vs 0 adjudicated as '${r%% *}'."
    fi
    case "$r" in *"2% of 1 = 0, cap 5) = 0"*) ;; *) probe_pass "the small-n verdict does not show its arithmetic: ${r}" ;; esac
    # THE v1.0.74 PAIR, which passed under 2% alone and fails under the cap:
    # the verdict must carry the provenance sentence so two adjacent walk
    # records explain themselves. And a gap the OLD rule would ALSO have
    # failed must NOT carry it, or the sentence becomes wallpaper.
    r="$(adjudicate_counts 2008 2018 2)"
    case "$r" in DISAGREE*"landed in CM051 #1799"*) ;; *) probe_pass "NEGATIVE CONTROL DID NOT FIRE: 2008 vs 2018 (v1.0.74, passed under 2% alone) did not carry the cap-provenance sentence: ${r}" ;; esac
    r="$(adjudicate_counts 6376 6755 2)"
    case "$r" in *"landed in CM051 #1799"*) probe_pass "the provenance sentence appeared on a gap the old rule also failed (379 on 6755): ${r}" ;; esac
    # THE CONVERGE CLASSIFIER, all four marker combinations, driving the real
    # function. The one that matters is done=1 killed=1: a box that was killed
    # and later caught up must classify DONE, or every later walk on that box
    # waits out the whole budget and then reports CANNOT-RUN on settled counts.
    local c
    c="$(_converge_classify 200 100)"; [ "$c" = "DONE" ]     || probe_pass "CONVERGE CONTROL: .done NEWER than .killed classified '${c}', not DONE. A caught-up box would stall every future walk."
    c="$(_converge_classify 0 100)";   [ "$c" = "INFLIGHT" ] || probe_pass "CONVERGE CONTROL: .done absent with a kill recorded classified '${c}', not INFLIGHT. This is the exact v1.0.75 window and it must be waited out."
    c="$(_converge_classify 200 0)";   [ "$c" = "DONE" ]     || probe_pass "CONVERGE CONTROL: .done alone classified '${c}', not DONE."
    c="$(_converge_classify 0 0)";     [ "$c" = "NOMARKER" ] || probe_pass "CONVERGE CONTROL: no markers classified '${c}', not NOMARKER. A box with no converge at all must measure immediately, not wait."
    # THE STALE .done, which an EXISTENCE test cannot see and which this probe
    # would otherwise rely on install.sh:28723 to make impossible. A .done left
    # by a previous cycle, or touched late by a catch-up agent from one, is
    # OLDER than the current kill and must NOT read as settled.
    c="$(_converge_classify 100 200)"; [ "$c" = "INFLIGHT" ] || probe_pass "CONVERGE CONTROL: a .done OLDER than .killed classified '${c}', not INFLIGHT. That is a stale marker read as a settled box, and it puts the probe back on a moving target."
    # A same-second catch-up must settle, not stall.
    c="$(_converge_classify 100 100)"; [ "$c" = "DONE" ]     || probe_pass "CONVERGE CONTROL: equal mtimes classified '${c}', not DONE. A fast box would be made to wait out the whole budget."
    # A read that came back as junk must not be dressed up as an answer.
    c="$(_converge_classify x y)";     [ "$c" = "UNREADABLE" ] || probe_pass "CONVERGE CONTROL: a non-numeric mtime pair classified '${c}', not UNREADABLE. A failed look would be measuring as though nothing needed waiting for."
    c="$(_converge_classify '' '')";   [ "$c" = "UNREADABLE" ] || probe_pass "CONVERGE CONTROL: an empty mtime pair classified '${c}', not UNREADABLE."
    # AND THE DISCRIMINATOR: absent markers really are 0 0, which must stay
    # NOMARKER. If UNREADABLE swallowed that too, every box without a converge
    # would refuse instead of measuring.
    c="$(_converge_classify 0 0)";     [ "$c" = "NOMARKER" ]   || probe_pass "CONVERGE CONTROL: absent markers (0 0) classified '${c}', not NOMARKER. UNREADABLE must not swallow the legitimate no-converge box."
    # MUST-BE-NON-ZERO CONTROL: exactly two of the seven are INFLIGHT. If the
    # classifier ever returned a constant, most asserts above would still pass;
    # this counts the population instead.
    local _inflight=0
    for pair in "200 100" "0 100" "200 0" "0 0" "100 200" "100 100" "x y" "z z"; do
        [ "$(_converge_classify $pair)" = "INFLIGHT" ] && _inflight=$((_inflight + 1))
    done
    [ "$_inflight" -eq 2 ] || probe_pass "CONVERGE CONTROL: ${_inflight} of 8 mtime combinations classified INFLIGHT, want exactly 2. A classifier that answers the same thing everywhere proves nothing."

    # THE EMBED-DRAIN CLASSIFIER (v1.0.121 trial: a Person reached the graph ten
    # minutes before its vector). Driving the real function, not an echo.
    local d
    d="$(_embed_drain_classify 0 ok 100 "")";   [ "$d" = "DRAINED_EMPTY" ]  || probe_pass "DRAIN CONTROL: an empty awaiting set classified '${d}', not DRAINED_EMPTY."
    d="$(_embed_drain_classify 3 ok 100 200)";  [ "$d" = "WAIT" ]           || probe_pass "DRAIN CONTROL: people waiting and the last index run OLDER than the sighting classified '${d}', not WAIT. A stale marker would be read as a drain, and the probe would grade embed lag as a disagreement."
    d="$(_embed_drain_classify 3 ok 200 200)";  [ "$d" = "WAIT" ]           || probe_pass "DRAIN CONTROL: a marker EQUAL to the sighting second classified '${d}', not WAIT (strictly later is required)."
    d="$(_embed_drain_classify 3 ok 300 200)";  [ "$d" = "DRAINED_BY_RUN" ] || probe_pass "DRAIN CONTROL: people waiting and an ok index run AFTER the sighting classified '${d}', not DRAINED_BY_RUN. A dropped vector would wait out the bound instead of failing."
    d="$(_embed_drain_classify 3 error 300 200)"; [ "$d" = "WAIT" ]         || probe_pass "DRAIN CONTROL: a FAILED index run classified '${d}', not WAIT. A run that errored drained nothing."
    d="$(_embed_drain_classify - ok 300 200)";  [ "$d" = "UNMEASURED" ]     || probe_pass "DRAIN CONTROL: an unmeasurable awaiting set ('-') classified '${d}', not UNMEASURED. Could-not-look must never read as nothing-waiting."
    d="$(_embed_drain_classify 3 ok - 200)";    [ "$d" = "WAIT" ]           || probe_pass "DRAIN CONTROL: people waiting and NO marker classified '${d}', not WAIT."

    # instr119: the category breakdown is printed with the doctor gap, and an
    # unreadable one says NOT MEASURED. Output only, no verdict reads it.
    local _bd
    _bd="$(note_breakdown "8247 645 13" 8905 8247)"
    case "$_bd" in *"named, not merged (what the vector writer indexes): 8247"*"unnamed stub"*": 645"*"merged (pwg:mergedInto, pruned by design)         : 13"*"doctor minus indexable named                       : 0 "*) ;;
        *) probe_pass "BREAKDOWN CONTROL: the category split did not print as expected: ${_bd}" ;; esac
    _bd="$(note_breakdown "UNAVAILABLE" 8905 8247)"
    case "$_bd" in *"NOT MEASURED"*) ;; *) probe_pass "BREAKDOWN CONTROL: an unreadable breakdown did not say NOT MEASURED: ${_bd}" ;; esac
    _bd="$(note_breakdown "8000 600 13" 8905 8247)"
    case "$_bd" in *"categories sum to 8613, not 8905"*) ;; *) probe_pass "BREAKDOWN CONTROL: a split that does not sum to the total was not flagged: ${_bd}" ;; esac

    probe_fail "negative control behaved correctly on all 8 pairs and all 8 converge-marker mtime combinations (exactly 2 of 8 are the in-flight window, including a STALE .done that an existence test cannot see) (real spread caught, drift allowed, double-zero and single-surface both refused, the cap catches 25 orphans a percentage hides, 1 vs 0 says its allowance is 0 and why, the v1.0.74 pair carries the cap-provenance sentence, and a gap the old rule also failed does not)"
}

probe_main "$@"
