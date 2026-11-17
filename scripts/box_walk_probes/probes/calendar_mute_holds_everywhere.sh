#!/usr/bin/env bash
# calendar_mute_holds_everywhere -- when the owner mutes one LISTED calendar, do
# its events vanish from every Hub surface, and does an unmuted calendar's event
# stay? (backlog T2, cut v1.0.134)
#
# WALK_WRITES: two synthetic pwg:Meeting nodes and one synthetic person in Oxigraph, and one exclude_calendar owner instruction that mutes a REAL listed calendar for the length of the run; teardown deletes the seeded nodes (before>0, after=0) and cancels the instruction.
#
# Product under test:
#   CM041 #266 (fix/t2-calendar-id-rules, head 3a60cb0a0, DRAFT):
#     GET  /api/v1/calendars            assistant_api/ical-server.py:11325, :5380
#     POST /api/v1/owner-instructions   assistant_api/ical-server.py:12037, :5386
#           exclude_calendar, value = a listed UUID          :5407-5418
#     POST /api/v1/owner-instructions/cancel                  :12048, :5518
#     GET  /api/v1/calendar/muted-ids                         :11333, :5504
#   Surfaces (assistant_api/ical-server.py):
#     calendar          GET /calendar?days=7                   :10950
#     calendar_today    GET /calendar/today                    :10959
#     meeting_upcoming  GET /api/v1/meeting/upcoming           :11169 -> :8563
#     timeline          GET /api/v1/timeline                   :11193 -> :8937
#     person_timeline   GET /api/v1/people/timeline?uri=       :11412 -> :6550
#     meeting_prep      NO HTTP ROUTE (meeting_syncer/brief.py, reached only
#                       in-process from :8625). Reported NOT INSTRUMENTED.
#   Judge: lib/calendar_mute.py (surfaces, verdict rules, self-test cases).
#
# WHAT IT CAN AND CANNOT SEE. The graph surfaces (timeline, person_timeline) are
# seeded: two synthetic pwg:Meeting nodes and one synthetic person are written
# into Oxigraph, one on the listed muted calendar and one on a listed control
# calendar. The feed surfaces (calendar, calendar_today, meeting_upcoming) read
# the live iCloud/Google feed (ICAL_SCRIPT, ical-server.py:147), and this probe
# has NO seam to put a synthetic event into that feed. So those surfaces read
# their state with the rule off and on, but their control is absent by
# construction and they grade CANNOT-RUN, with the reason named. That is the
# honest outcome, not a pass. A PASS needs a feed seam or a product-side fixture
# hook, and that is a product change, not a probe change.
#
# WRITES (the walk box, synthetic data only):
#   1. Reads GET /api/v1/calendars and takes the first two listed UUIDs. The
#      UUID of the MUTED calendar is a REAL calendar on the box. The mute is
#      active for the length of the probe only.
#   2. Seeds, into Oxigraph (OSTLER_PROBE_OXIGRAPH_BASE, default
#      http://127.0.0.1:7878): one person <https://ostler.example/person/TAG>,
#      and two pwg:Meeting nodes under https://ostler.example/meeting/TAG-*.
#      Names are fixed-marker strings; ids are the two UUIDs. ostler.example is
#      a reserved example domain.
#   3. POST /api/v1/owner-instructions exclude_calendar with the muted UUID,
#      source_turn "walk134-calmute-TAG". The probe cancels it ONLY if that POST
#      returned created=true. A rule that already held is left alone and the
#      probe says CANNOT-RUN.
#   TEARDOWN (trap EXIT, every path): cancels the rule it created, deletes every
#   triple whose subject is a seeded node, measures the count before and after
#   (before must be > 0, after must be 0), and removes its staging directory.
#   The bodies of the Hub responses never leave the box: only http codes and
#   booleans come back, through lib/calendar_mute.py on the box.
#
# Exit: 0 PASS, 1 FAIL (a muted event is present on a surface with the rule on),
# 78 CANNOT-RUN (any surface blind, not measured, or the box cannot be seeded).
# Reach the box only through box_run / box_run_v.
set -u
. "$(dirname "$0")/../lib/probe.sh"

PROBE_NAME="calendar_mute_holds_everywhere"
PROBE_QUESTION="when the owner mutes one listed calendar, is its event absent from calendar, calendar today, meeting upcoming, the timeline, the person timeline and meeting prep, while an unmuted calendar's event stays (positive control)?"

_HERE="$(cd "$(dirname "$0")/.." && pwd)"
_LIB="${_HERE}/lib/calendar_mute.py"
_PWG="https://schema.ostler.ai/ontology#"
HUB_BASE="${OSTLER_PROBE_CAL_BASE:-http://127.0.0.1:8089}"
OXI_BASE="${OSTLER_PROBE_OXIGRAPH_BASE:-http://127.0.0.1:7878}"
TAG="walk134-calmute-$$-$(date -u +%H%M%S)"
REMOTE="/tmp/ostler-probe-calmute-$$"
PERSON_URI="https://ostler.example/person/${TAG}"
MEET_MUTED="https://ostler.example/meeting/${TAG}-muted"
MEET_CONTROL="https://ostler.example/meeting/${TAG}-control"
MARK_MUTED="walk134-mute-muted-${TAG}"
MARK_CONTROL="walk134-mute-control-${TAG}"
TODAY="$(date -u +%Y-%m-%d)"

SEEDED=0
RULE_CREATED=0
RULE_ID=""
TEARDOWN_DONE=0
MUTED_UUID=""
CONTROL_UUID=""

# ---------------------------------------------------------------------------
# Remote plumbing. Every call runs ON the box via box_run; the token is read on
# the box and never reaches the driver.
# ---------------------------------------------------------------------------
_stage_lib() {
    local b64
    b64="$(base64 < "${_LIB}" | tr -d '\n')"
    box_run "mkdir -p ${REMOTE} && printf %s '${b64}' | base64 -d > ${REMOTE}/calendar_mute.py" >/dev/null 2>&1
}

# _hub_get <path> <lib-mode-args...> : GET on the box, judged on the box.
_hub_get() {
    local path="$1"; shift
    box_run "T=\$(cat \"\$HOME/.ostler/secrets/service_token\" 2>/dev/null); curl -s -m 20 -w '\n%{http_code}' -H \"X-Ostler-Service: \$T\" '${HUB_BASE}${path}' | python3 ${REMOTE}/calendar_mute.py $*"
}

# _hub_post <path> <json-body>: POST on the box, returns the raw body+code to
# the driver. The body is ours (synthetic ids and a fixed turn tag), so it may
# be shown; the response is parsed on the box by 'instr' below.
_hub_post_instr() {
    local path="$1" body="$2" b64
    b64="$(printf '%s' "$body" | base64 | tr -d '\n')"
    box_run "T=\$(cat \"\$HOME/.ostler/secrets/service_token\" 2>/dev/null); printf %s '${b64}' | base64 -d | curl -s -m 20 -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' -H \"X-Ostler-Service: \$T\" --data-binary @- '${HUB_BASE}${path}' | python3 ${REMOTE}/calendar_mute.py instr"
}

# _oxi_update <sparql> : SPARQL UPDATE on the box. Prints the http code only.
_oxi_update() {
    local b64
    b64="$(printf '%s' "$1" | base64 | tr -d '\n')"
    box_run "printf %s '${b64}' | base64 -d | curl -s -m 30 -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/sparql-update' --data-binary @- '${OXI_BASE}/update'"
}

# _oxi_count <entity-uris...> : count of triples whose subject is one of them.
_oxi_count() {
    local vals="" u sparql b64
    for u in "$@"; do vals="${vals} <${u}>"; done
    sparql="SELECT (COUNT(*) AS ?n) WHERE { VALUES ?s {${vals} } ?s ?p ?o . }"
    b64="$(printf '%s' "$sparql" | base64 | tr -d '\n')"
    box_run "printf %s '${b64}' | base64 -d | curl -s -m 30 -X POST -H 'Content-Type: application/sparql-query' -H 'Accept: application/sparql-results+json' --data-binary @- '${OXI_BASE}/query' | python3 ${REMOTE}/calendar_mute.py count"
}

_seed_sparql() {
    cat <<EOF
PREFIX pwg: <${_PWG}>
INSERT DATA {
  <${PERSON_URI}> a pwg:Person ; pwg:displayName "${TAG} contact" .
  <${MEET_MUTED}> a pwg:Meeting ; pwg:meetingSummary "${MARK_MUTED}" ;
      pwg:meetingDate "${TODAY}" ; pwg:meetingAttendee <${PERSON_URI}> ;
      pwg:meetingCalendarId "${MUTED_UUID}" ; pwg:privacyLevel "L1" .
  <${MEET_CONTROL}> a pwg:Meeting ; pwg:meetingSummary "${MARK_CONTROL}" ;
      pwg:meetingDate "${TODAY}" ; pwg:meetingAttendee <${PERSON_URI}> ;
      pwg:meetingCalendarId "${CONTROL_UUID}" ; pwg:privacyLevel "L1" .
}
EOF
}

# ---------------------------------------------------------------------------
# TEARDOWN. Runs on every exit once seeding has begun (trap EXIT).
# ---------------------------------------------------------------------------
_calmute_teardown() {
    [ "${TEARDOWN_DONE}" -eq 1 ] && return 0
    TEARDOWN_DONE=1
    if [ "${RULE_CREATED}" -eq 1 ] && [ -n "${RULE_ID}" ]; then
        local out
        out="$(box_run "T=\$(cat \"\$HOME/.ostler/secrets/service_token\" 2>/dev/null); printf '{\"id\": %s}' '${RULE_ID}' | curl -s -m 20 -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' -H \"X-Ostler-Service: \$T\" --data-binary @- '${HUB_BASE}/api/v1/owner-instructions/cancel' | tail -n 1")"
        printf 'TEARDOWN owner instruction %s cancelled, http %s\n' "${RULE_ID}" "${out:-?}"
    fi
    if [ "${SEEDED}" -eq 1 ]; then
        local before after
        before="$(_oxi_count "${PERSON_URI}" "${MEET_MUTED}" "${MEET_CONTROL}")"
        _oxi_update "DELETE WHERE { <${PERSON_URI}> ?p ?o . }" >/dev/null
        _oxi_update "DELETE WHERE { <${MEET_MUTED}> ?p ?o . }" >/dev/null
        _oxi_update "DELETE WHERE { <${MEET_CONTROL}> ?p ?o . }" >/dev/null
        after="$(_oxi_count "${PERSON_URI}" "${MEET_MUTED}" "${MEET_CONTROL}")"
        printf 'TEARDOWN seed triples before=%s after=%s\n' "${before:-?}" "${after:-?}"
    fi
    box_run "rm -rf ${REMOTE}" >/dev/null 2>&1
    return 0
}

# ---------------------------------------------------------------------------
self_test() {
    local out rc n
    out="$(python3 -I "${_LIB}" --self-test 2>&1)"; rc=$?
    printf '%s\n' "${out}"
    if [ "${rc}" -ne 0 ]; then
        printf 'VERDICT: BROKEN -- %s: the judge lib failed its own cases (rc %s); the probe is not trusted\n' "${PROBE_NAME}" "${rc}"
        exit "${PROBE_EX_FAIL}"
    fi
    n="$(printf '%s\n' "${out}" | sed -n 's/^CASES //p')"
    probe_examined "${n:-0}" "judge cases (one per surface leak, blind and absent-control shape)"
    out="$(python3 -I "${_LIB}" judge --fixture leak_timeline 2>&1)"; rc=$?
    printf '%s\n' "${out}"
    if [ "${rc}" -ne "${PROBE_EX_FAIL}" ]; then
        printf 'VERDICT: BROKEN -- %s: the known-bad capture (a muted event on the timeline) did not come back FAIL (rc %s)\n' "${PROBE_NAME}" "${rc}"
        exit "${PROBE_EX_FAIL}"
    fi
    probe_fail "negative control behaved: a muted event present on the timeline with the rule on is FAIL by the surface's own assertion"
}

run_probe() {
    box_reachable || probe_cannot_run "cannot reach the box; no calendar surface was read"
    box_run "[ -r \"\$HOME/.ostler/secrets/service_token\" ]" >/dev/null 2>&1 \
        || probe_cannot_run "no service token readable on the box at ~/.ostler/secrets/service_token; the Hub answers 401 without it"

    _stage_lib || probe_cannot_run "could not stage lib/calendar_mute.py on the box"
    trap _calmute_teardown EXIT

    # 1. The listing. 404 is the pre-134 build; 503 is degraded (no calendars.json).
    local pick
    pick="$(_hub_get /api/v1/calendars pick)"
    local p_http p_deg p_listed p_reason
    p_http="$(printf '%s' "${pick}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["http"])' 2>/dev/null)"
    if [ "${p_http}" = "404" ]; then
        probe_cannot_run "GET /api/v1/calendars answered 404: this Hub predates CM041 #266 (T2), so the mute has no listing route to name a calendar by. Not a pass."
    fi
    p_deg="$(printf '%s' "${pick}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["degraded"])' 2>/dev/null)"
    p_listed="$(printf '%s' "${pick}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["listed"])' 2>/dev/null)"
    p_reason="$(printf '%s' "${pick}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("reason",""))' 2>/dev/null)"
    if [ "${p_deg}" = "True" ] || [ -z "${p_listed}" ]; then
        probe_cannot_run "GET /api/v1/calendars is degraded (http ${p_http:-?}, reason '${p_reason:-unreadable}'): the FDA extract calendars.json is absent or unreadable, so no calendar can be muted by UUID"
    fi
    if [ "${p_listed}" -lt 2 ]; then
        probe_cannot_run "GET /api/v1/calendars lists ${p_listed} calendar(s); the probe needs 2 (one to mute, one control)"
    fi
    MUTED_UUID="$(printf '%s' "${pick}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["muted_uuid"])')"
    CONTROL_UUID="$(printf '%s' "${pick}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["control_uuid"])')"

    # 2. Seed the graph side. Teardown is armed from here on.
    SEEDED=1
    local w
    w="$(_oxi_update "$(_seed_sparql)")"
    [ "${w}" = "204" ] || [ "${w}" = "200" ] || probe_cannot_run "the seed did not land in Oxigraph (http ${w:-none}); the graph surfaces cannot be measured"

    # 3. Rule OFF arm: each surface must show both synthetic events, or it is blind.
    local tmp
    tmp="$(mktemp)"
    _measure_arm off "${tmp}"

    # 4. The mute.
    local body post
    body="{\"kind\": \"exclude_calendar\", \"value\": \"${MUTED_UUID}\", \"source_turn\": \"${TAG}\"}"
    post="$(_hub_post_instr /api/v1/owner-instructions "${body}")"
    local created
    created="$(printf '%s' "${post}" | python3 -c 'import sys; print(sys.stdin.read().strip())')"
    case "${created}" in
        created=True*) RULE_CREATED=1; RULE_ID="${created#created=True id=}"; RULE_ID="${RULE_ID%% *}" ;;
        created=False*) rm -f "${tmp}"; probe_cannot_run "the muted calendar already carries an active owner rule (POST returned created=false). The probe will not cancel a rule it did not create, so the mute is not measured on this box." ;;
        *) rm -f "${tmp}"; probe_cannot_run "POST /api/v1/owner-instructions did not create the mute: ${created:-no answer}" ;;
    esac

    # 5. Rule ON arm.
    _measure_arm on "${tmp}"

    # 6. Judge. Only booleans and http codes are read here.
    local jout jrc
    jout="$(python3 -I "${_LIB}" judge "${tmp}")"; jrc=$?
    rm -f "${tmp}"
    printf '%s\n' "${jout}"
    _calmute_teardown
    probe_examined 6 "surfaces (calendar, calendar_today, meeting_upcoming, timeline, person_timeline, meeting_prep) x 2 arms (rule off, rule on); 5 read, 1 not instrumented"
    case "${jrc}" in
        0)  probe_pass "a muted calendar's synthetic event is absent on every surface with the rule on, and the control event stays on every surface" ;;
        1)  probe_fail "a muted calendar's event is still present on at least one surface with the rule on (see the FAIL line above)" ;;
        *)  probe_cannot_run "the mute could not be proven on every surface (see the CANNOT lines above): the feed surfaces have no seam to carry a synthetic event, and meeting_prep has no HTTP route" ;;
    esac
}

# _measure_arm <off|on> <outfile> : one JSON line per surface, judged on the box.
_measure_arm() {
    local arm="$1" out="$2" line
    local mm="${MARK_MUTED}" mc="${MARK_CONTROL}"
    _hub_get "/calendar?days=7" observe --surface calendar --seam feed --marker-muted "${mm}" --marker-control "${mc}" >> "${out}.${arm}"
    _hub_get "/calendar/today" observe --surface calendar_today --seam feed --marker-muted "${mm}" --marker-control "${mc}" >> "${out}.${arm}"
    _hub_get "/api/v1/meeting/upcoming?within_minutes=1440" observe --surface meeting_upcoming --seam feed --marker-muted "${mm}" --marker-control "${mc}" >> "${out}.${arm}"
    _hub_get "/api/v1/timeline?days=7&past_days=730&limit=200" observe --surface timeline --seam graph --marker-muted "${mm}" --marker-control "${mc}" >> "${out}.${arm}"
    _hub_get "/api/v1/people/timeline?uri=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "${PERSON_URI}")&limit=50" observe --surface person_timeline --seam graph --marker-muted "${mm}" --marker-control "${mc}" >> "${out}.${arm}"
    printf '{"surface": "meeting_prep", "not_instrumented": "no HTTP route: the pre-meeting brief is reached only in-process (ical-server.py:8625, meeting_syncer/brief.py)"}\n' >> "${out}.${arm}"
    # Tag each line with its arm and merge into the one JSONL the judge reads.
    python3 -c 'import json,sys
arm=sys.argv[1]
for raw in open(sys.argv[2]):
    raw=raw.strip()
    if not raw: continue
    d=json.loads(raw)
    if "arm" in d: d["arm"]=arm
    print(json.dumps(d, sort_keys=True))' "${arm}" "${out}.${arm}" >> "${out}"
    rm -f "${out}.${arm}"
}

probe_main "$@"
