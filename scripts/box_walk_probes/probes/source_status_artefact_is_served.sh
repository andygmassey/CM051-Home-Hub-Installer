#!/usr/bin/env bash
# probes/source_status_artefact_is_served.sh
# ============================================================================
# QUESTION: does the Doctor serve the source-status artefact at
#           GET /api/v1/sources -- one honest per-source row for every canonical
#           source -- so the panel, this probe and the walk all READ one record
#           instead of each re-deriving ingest state from the stores?
#
# WHY THIS PROBE READS THE ARTEFACT AND NOT THE STORES (G5, and E4's finding).
# The pre-existing ingest_coverage probe asks the Qdrant collections directly
# "how many points does each store hold". That is store-consistency, and its own
# header records the hole: THREE STORES AGREEING ON ZERO PASSES IT. Two empty
# stores that agree cannot be told from two sources that both landed nothing,
# because a point count has no per-source identity and no notion of "this
# recorder exists but has not fired". /api/v1/sources does: it is built from the
# hydrate `.done` sentinels install.sh writes, one typed row per source, and a
# source that never ran is `not_run`, not an omission. So this probe reads that
# record and adjudicates whether the RECORD is served and usable -- the thing
# the panel and the walk both depend on being true.
#
# WHAT IT DOES AND DOES NOT DECIDE. At T+0 (a fresh install) most sources have
# landed nothing yet, so `not_run` is the honest and expected state; a low
# landed count is NOT a fail. What fails is the RECORD being absent, incomplete
# (a source dropped) or unusable (a row with no status). Whether a source that
# SHOULD keep updating actually does is the T+1h question (C8), read from the
# same artefact's last_update_at on a later pass.
#
# THE TRAP, taken from probes/freshness_panel_has_dates.sh, which was fooled by
# exactly this: a 404 on the route returns {"detail":"Not Found"}, and an
# adjudicator that does doc.get("sources", doc) reads the error object AS the
# source set and concludes a clean PASS about a route that does not exist. This
# adjudicator refuses anything that is not a JSON object carrying a "sources"
# LIST, and reports that as CANNOT-RUN (the record could not be read), never as
# a pass.
# ============================================================================

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/probe.sh"

PROBE_NAME="source_status_artefact_is_served"
PROBE_QUESTION="does GET /api/v1/sources serve one honest per-source row for every canonical source?"

DOCTOR_URL="${OSTLER_DOCTOR_URL:-http://127.0.0.1:8089}"

# classify: reads a /api/v1/sources response body on stdin, prints ONE line:
#   PASS <landed> landed / <n> sources (<notrun> not_run)
#   FAIL <reason>
#   CANNOT_RUN <reason>
# The adjudication is a pure function of the body, so self_test can drive it
# with synthetic bodies without a live box.
classify() {
    local body
    body="$(cat)"
    OSTLER_SOURCES_BODY="$body" python3 <<'PY'
import os, sys, json
CANON = 13  # the canonical source set _SOURCE_KINDS serves; a re-vendor can only grow it
raw = os.environ.get("OSTLER_SOURCES_BODY", "")
try:
    doc = json.loads(raw)
except Exception:
    print("CANNOT_RUN response is not JSON -- the endpoint is absent or returned an error body, not the artefact")
    sys.exit(0)
# A 404 body {"detail": "Not Found"} is a dict but has no sources LIST. Refuse it
# rather than reading the error object as the source set.
if not isinstance(doc, dict) or not isinstance(doc.get("sources"), list):
    print("CANNOT_RUN no `sources` list in the response -- a 404/error body where the artefact should be")
    sys.exit(0)
rows = doc["sources"]
if len(rows) < CANON:
    print(f"FAIL only {len(rows)} rows, expected at least {CANON} canonical sources -- a source was dropped from the record")
    sys.exit(0)
no_status = [r.get("source", "?") for r in rows if not isinstance(r, dict) or "status" not in r]
if no_status:
    print(f"FAIL {len(no_status)} row(s) carry no status ({no_status[:5]}) -- the record is not usable per-source")
    sys.exit(0)
landed = sum(1 for r in rows if r.get("status") == "ok" and (r.get("item_count") or 0) > 0)
notrun = sum(1 for r in rows if r.get("status") == "not_run")
print(f"PASS {landed} landed / {len(rows)} sources ({notrun} not_run) -- artefact served and per-source honest")
PY
}

run_probe() {
    probe_examined 1 "GET ${DOCTOR_URL}/api/v1/sources on the box"

    if ! box_reachable; then
        probe_cannot_run "the box (${OSTLER_BOX_HOST:-local}) is not reachable, so the Doctor could not be queried"
    fi

    local body verdict token detail
    body="$(box_run "curl -s --noproxy '*' --max-time 5 '${DOCTOR_URL}/api/v1/sources'")"
    verdict="$(printf '%s' "$body" | classify)"
    token="${verdict%% *}"
    detail="${verdict#* }"

    case "$token" in
        PASS)       probe_pass "/api/v1/sources: ${detail}" ;;
        FAIL)       probe_fail "/api/v1/sources served but unusable: ${detail}" ;;
        CANNOT_RUN) probe_cannot_run "/api/v1/sources could not be read: ${detail}" ;;
        *)          probe_fail "adjudicator returned an unrecognised token: ${verdict}" ;;
    esac
}

# NEGATIVE CONTROL. Drives the adjudicator against bodies that are known-bad (or
# known-good) by construction. Exits probe_fail (rc 1) when every case is judged
# correctly -- that is the healthy result the runner expects; a probe_pass (rc 0)
# here means a control did NOT fire and the probe is blind to its defect.
self_test() {
    probe_examined 5 "synthetic /api/v1/sources bodies (negative control)"

    # 13 honest rows, each with a status -> must PASS
    local good='{"sources": ['
    local i
    for i in $(seq 1 13); do good="${good}{\"source\":\"s$i\",\"status\":\"not_run\",\"item_count\":null},"; done
    good="${good%,}]}"
    case "$(printf '%s' "$good" | classify)" in
        PASS*) : ;;
        *) probe_pass "NEGATIVE CONTROL OVER-FIRED: a valid 13-row artefact was not adjudicated PASS. This probe would red a healthy Hub." ;;
    esac

    # a 404 error body -> must be CANNOT_RUN, never PASS (the freshness-panel trap)
    case "$(printf '%s' '{"detail":"Not Found"}' | classify)" in
        CANNOT_RUN*) : ;;
        *) probe_pass "NEGATIVE CONTROL DID NOT FIRE: a 404 error body was read as the artefact instead of CANNOT-RUN. This is the exact freshness_panel_has_dates defect." ;;
    esac

    # not JSON at all -> CANNOT_RUN
    case "$(printf '%s' 'curl: (7) could not connect' | classify)" in
        CANNOT_RUN*) : ;;
        *) probe_pass "NEGATIVE CONTROL DID NOT FIRE: a non-JSON transport error was not adjudicated CANNOT-RUN." ;;
    esac

    # 12 rows (a source dropped) -> must FAIL
    local short='{"sources": ['
    for i in $(seq 1 12); do short="${short}{\"source\":\"s$i\",\"status\":\"ok\",\"item_count\":3},"; done
    short="${short%,}]}"
    case "$(printf '%s' "$short" | classify)" in
        FAIL*) : ;;
        *) probe_pass "NEGATIVE CONTROL DID NOT FIRE: 12 rows (a source dropped from the record) was not adjudicated FAIL." ;;
    esac

    # 13 rows but one carries no status -> must FAIL (unusable per-source)
    local nostatus='{"sources": [{"source":"s1"},'
    for i in $(seq 2 13); do nostatus="${nostatus}{\"source\":\"s$i\",\"status\":\"ok\",\"item_count\":1},"; done
    nostatus="${nostatus%,}]}"
    case "$(printf '%s' "$nostatus" | classify)" in
        FAIL*) : ;;
        *) probe_pass "NEGATIVE CONTROL DID NOT FIRE: a row with no status was not adjudicated FAIL." ;;
    esac

    probe_fail "negative control behaved correctly on all 5 bodies (valid 13-row passes; 404 body, transport error, dropped-source and status-less row all refuse)"
}

probe_main "$@"
