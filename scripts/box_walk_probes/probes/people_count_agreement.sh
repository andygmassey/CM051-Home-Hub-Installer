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
