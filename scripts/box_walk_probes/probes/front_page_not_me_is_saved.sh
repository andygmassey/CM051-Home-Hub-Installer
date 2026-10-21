#!/usr/bin/env bash
# probes/front_page_not_me_is_saved.sh
# ============================================================================
# QUESTION: when the Hub app taps "Not me" on a Front Page card, is it SAVED,
#           i.e. still there after a reload?
#
# WHY (CM051 #2470). On the v1.0.105 walk a card marked Not me came back on the
# next visit: the Hub posted nothing, and the route refused the app's own origin
# (tauri://localhost). Both are fixed, and no walk probe ever exercised the path,
# so a regression would have shipped as quietly as the original. The existing
# unit test (tests/test_the_hub_app_can_record_card_feedback.py) asks the origin
# predicate only; it never POSTs and never reads a store back.
#
# WHAT IT DOES, ON THE BOX: POST /api/v1/editor/feedback exactly as the app does
# (Origin tauri://localhost, {card_id, action:"drop", interest_id}), then re-read
# ~/.ostler/editor/interest_corrections.json and card_states.json from disk.
# The response body is NOT the evidence. A second POST from a foreign web origin
# is the control on the origin gate: refused (403), writes nothing.
# Synthetic ids only, removed again before the probe ends.
#
# NOT COVERED (NOT INSTRUMENTED here): the Hub's own Tauri webview rendering the
# retry text, and the next hourly Front Page compile dropping a REAL card. Those
# need the console walk.
# ============================================================================
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/probe.sh"

PROBE_NAME="front_page_not_me_is_saved"
PROBE_QUESTION="does a Not me tap from the Hub app's origin land in interest_corrections.json and card_states.json and survive a reload?"

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCTOR_URL="${OSTLER_DOCTOR_URL:-http://127.0.0.1:8089}"
EDITOR_DIR="${OSTLER_EDITOR_DIR:-~/.ostler/editor}"

run_probe() {
    box_reachable || probe_cannot_run "the box (${OSTLER_BOX_HOST:-local}) is not reachable, so no tap was sent"
    local remote result verdict token detail
    remote="/tmp/ostler-probe-front-page-not-me-$$.py"
    box_run "printf %s '$(base64 < "${_HERE}/lib/front_page_not_me.py" | tr -d '\n')' | base64 -d > ${remote}" >/dev/null 2>&1 \
        || probe_cannot_run "could not stage the Not-me driver on the box"
    result="$(box_run "python3 ${remote} drive '${DOCTOR_URL}' '${EDITOR_DIR}'; rm -f ${remote}")"
    probe_examined 1 "Not me tap (POST, then re-read of both stores) against ${DOCTOR_URL}"
    verdict="$(printf '%s' "${result}" | python3 "${_HERE}/lib/front_page_not_me.py" judge)"
    token="${verdict%% *}"; detail="${verdict#* }"
    case "${token}" in
        PASS)       probe_pass "${detail}" ;;
        FAIL)       probe_fail "${detail}" ;;
        CANNOT_RUN) probe_cannot_run "${detail}" ;;
        *)          probe_fail "judge returned an unrecognised token: ${verdict}" ;;
    esac
}

# NEGATIVE CONTROL: known-bad results must each be judged FAIL, the known-good
# one PASS. Exits probe_fail (the healthy result); probe_pass means a control
# did not fire.
self_test() {
    probe_examined 7 "synthetic Not-me results (negative control)"
    local j="${_HERE}/lib/front_page_not_me.py" good bad
    good='{"post_status":200,"post_body":"{\"status\":\"recorded\"}","foreign_status":403,"corrections_state":"ok","states_state":"ok","corrections_has_interest":true,"card_state":{"state":"dismissed_forever"},"foreign_leaked":false,"cleaned":true}'
    judge() { printf '%s' "$1" | python3 "$j" judge; }
    case "$(judge "${good}")" in PASS*) : ;; *) probe_pass "NEGATIVE CONTROL OVER-FIRED: a fully saved Not me was not PASS" ;; esac
    # fake no-persist server: says recorded, writes nothing
    bad="${good/\"corrections_has_interest\":true/\"corrections_has_interest\":false}"
    case "$(judge "${bad}")" in FAIL*) : ;; *) probe_pass "NEGATIVE CONTROL DID NOT FIRE: 'recorded' with nothing in the store (fake no-persist server) was not FAIL" ;; esac
    bad="${good/\"corrections_state\":\"ok\"/\"corrections_state\":\"absent\"}"
    case "$(judge "${bad}")" in FAIL*) : ;; *) probe_pass "NEGATIVE CONTROL DID NOT FIRE: an absent interest_corrections.json was not FAIL" ;; esac
    bad="${good/\{\"state\":\"dismissed_forever\"\}/null}"
    case "$(judge "${bad}")" in FAIL*) : ;; *) probe_pass "NEGATIVE CONTROL DID NOT FIRE: no card_states.json entry was not FAIL" ;; esac
    bad="${good/\"post_status\":200/\"post_status\":403}"
    case "$(judge "${bad}")" in FAIL*) : ;; *) probe_pass "NEGATIVE CONTROL DID NOT FIRE: the app origin refused (403) was not FAIL" ;; esac
    bad="${good/\"foreign_status\":403/\"foreign_status\":200}"
    case "$(judge "${bad}")" in FAIL*) : ;; *) probe_pass "NEGATIVE CONTROL DID NOT FIRE: a foreign origin accepted was not FAIL" ;; esac
    bad="${good/\"post_status\":200/\"post_status\":0}"
    case "$(judge "${bad}")" in CANNOT_RUN*) : ;; *) probe_pass "NEGATIVE CONTROL DID NOT FIRE: an unreachable Doctor was not CANNOT-RUN" ;; esac
    probe_fail "negative control behaved correctly on all 7 results (saved passes; no-persist, absent store, no card state, app origin refused, open origin all FAIL; no answer is CANNOT-RUN)"
}

probe_main "$@"
