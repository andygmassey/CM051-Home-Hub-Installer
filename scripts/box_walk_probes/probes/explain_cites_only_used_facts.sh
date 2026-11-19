#!/usr/bin/env bash
# explain_cites_only_used_facts -- asks one seeded question, then "Why did you say that?" on the same
# /ws/chat connection. PASS only when the explanation cites no L3 fact and no L2 fact the answer
# did not use. Needs [agent] explain_answers = true on the box; the probe never flips it (CANNOT).
#
# Box side: lib/explain_chat.py explain-box grades ON the box; only verdicts and fact-presence
# booleans leave it, never reply prose or tool output. Judge: lib/explain_chat.py judge.
# Inputs (Mac env, forwarded to the box run): OSTLER_PROBE_SEED_FACTS_FILE (TSV: L2|L3<TAB>phrase,
# on the box), OSTLER_PROBE_QUESTION (the seeded question). Either unset is CANNOT, never PASS.
# --self-test runs the judge over canned captures (L3 leak red, unused L2 red, clean green).
set -u
. "$(dirname "$0")/../lib/probe.sh"

PROBE_NAME="explain_cites_only_used_facts"
PROBE_QUESTION="when the assistant explains an answer, does the explanation cite only facts the answer used, and never a fact above the destination's level (no L3)?"

_HERE="$(cd "$(dirname "$0")/.." && pwd)"

self_test() {
    probe_examined 5 "canned captures"
    if python3 "${_HERE}/lib/explain_chat.py" --self-test; then
        probe_pass "self-test: the L3 leak, the unused L2 fact and the missing explanation all went red"
    fi
    probe_fail "SELF-TEST BROKEN: the judge let a known-bad explanation through"
}

run_probe() {
    box_reachable || probe_cannot_run "cannot reach the box; nothing was asked"
    [ -n "${OSTLER_PROBE_SEED_FACTS_FILE:-}" ] || probe_cannot_run "OSTLER_PROBE_SEED_FACTS_FILE is unset; no seed to grade against"
    [ -n "${OSTLER_PROBE_QUESTION:-}" ] || probe_cannot_run "OSTLER_PROBE_QUESTION is unset"
    local remote cap rc out n
    remote="/tmp/ostler-probe-explain-$$"
    box_run "mkdir -p ${remote}" >/dev/null 2>&1 || probe_cannot_run "could not make a staging directory on the box"
    box_run "printf %s '$(base64 < "${_HERE}/lib/explain_chat.py" | tr -d '\n')' | base64 -d > ${remote}/explain_chat.py" >/dev/null 2>&1 \
        || probe_cannot_run "could not stage explain_chat.py on the box"
    cap="$(mktemp)"
    box_run "OSTLER_PROBE_SEED_FACTS_FILE='${OSTLER_PROBE_SEED_FACTS_FILE}' OSTLER_PROBE_QUESTION='${OSTLER_PROBE_QUESTION}' python3 ${remote}/explain_chat.py explain-box; rm -rf ${remote}" > "${cap}" 2>/dev/null
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${cap}" 2>/dev/null \
        || { rm -f "${cap}"; probe_cannot_run "the box-side half returned no capture"; }
    out="$(python3 "${_HERE}/lib/explain_chat.py" judge "${cap}")"; rc=$?
    rm -f "${cap}"
    printf '%s\n' "${out}"
    n="$(printf '%s\n' "${out}" | grep -cE '^  (ok|FAIL|CANNOT) ')"
    probe_examined "${n}" "checks"
    [ "${n}" -gt 0 ] || probe_fail "the judge printed nothing; a silent probe is not a pass"
    case "${rc}" in
        0)  probe_pass "the explanation cites only the facts the answer used, and no L3 fact" ;;
        78) probe_cannot_run "see the CANNOT line above" ;;
        *)  probe_fail "see the FAIL lines above" ;;
    esac
}

probe_main "$@"
