#!/usr/bin/env bash
# scripts/box_walk_probes/probes/no_l3_in_tool_results.sh
# ============================================================================
# QUESTION: once a synthetic L3 conversation is processed by the SHIPPED
# writer, does NONE of the seven pwg_* tools return anything derived from it,
# while an L2 twin processed the same way DOES come back (the control)?
#
# THE WRITER (read, not assumed)
#   vendor/cm048_pipeline/src/privacy.py:26-29   an explicit metadata
#       privacy_level wins over inference, so "L3" is accepted as stated.
#   processor.py:240-258   an L3 conversation skips the gist sinks; the
#       episodic bundle (step 09) still lands, and its todos carry the level
#       (ingest.py:601, :861-872).
#   So the seed IS an L3 route. Nothing here is a stub.
#
# THE SEVEN TOOLS, each via the loopback route it calls (crates/zeroclaw-tools):
#   pwg_decisions, pwg_topics, pwg_commitments, pwg_preferences,
#   pwg_overview (hydration/status + preferences), pwg_derived_preferences,
#   pwg_knowledge_search (embed + Qdrant points/search with the fail-closed
#   filter, exactly as the tool sends it).
#
# WHAT IT DOES ON THE BOX. Seeds one L3 conversation and one L2 twin with
# synthetic markers (reserved words, no real names), waits for each step-09
# bundle, reads the seven tools, judges the capture. It WRITES two conversations
# to the box (cleanup is not offered: the writer has no forget route for a
# conversation, so the rows persist under ostler-walk-l3-* / ostler-walk-l2-*).
#
# VERDICTS. PASS only when the L3 marker is absent from every tool response AND
# the L2 twin marker surfaced in at least one. A seed that did not complete, or a
# silent L2 control, is CANNOT_RUN (78), never PASS.
#
# WHAT A FAIL MEANS: an L3 conversation's content reaches a tool result, so it
# can reach the model. On 132 this is expected to FAIL on the commitments tool:
# the Hub returns L3 rows labelled, not dropped (CM041 ical-server.py ~6338-6470).
# The oa boundary filter (ostler-assistant PR #716) drops them on the oa side;
# the Hub-side fix belongs to CM041.
#
# WALK_READ_ONLY: no. This probe seeds two conversations. It is a seeding probe.
# ============================================================================
set -u
. "$(dirname "$0")/../lib/probe.sh"

PROBE_NAME="no_l3_in_tool_results"
PROBE_QUESTION="does an L3 conversation's content reach any pwg_* tool result, with the L2 twin surfacing as the positive control?"

_HERE="$(cd "$(dirname "$0")/.." && pwd)"
_JUDGE="${_HERE}/lib/no_l3_probe.py"
_BOXSCRIPT="${_HERE}/lib/no_l3_box.py"

# ONE decision, shared by run_probe and self_test: judge a capture file.
decide() {
    local cap="$1" out rc n
    out="$(python3 "${_JUDGE}" judge "${cap}")"; rc=$?
    printf '%s\n' "${out}"
    n="$(printf '%s\n' "${out}" | grep -cE '^  (ok|FAIL|CANNOT) ')"
    probe_examined "${n}" "tool responses and seed/control lines"
    [ "${n}" -gt 0 ] || probe_cannot_run "the judge printed nothing; a silent probe is not a pass"
    case "${rc}" in
        0)  probe_pass "no L3 marker in any of the seven tool responses and the L2 twin surfaced (see the denominator above)" ;;
        78) probe_cannot_run "the seed did not complete or the L2 control did not surface (see the CANNOT line above)" ;;
        *)  probe_fail "an L3 marker reached a tool result (see the FAIL line above)" ;;
    esac
}

self_test() {
    python3 "${_JUDGE}" --self-test >/dev/null 2>&1 || {
        probe_examined 5 "judge cases"
        probe_pass "SELF-TEST BROKEN: the judge put a known case on the wrong verdict"
    }
    # Known-bad capture through the SAME decide() run_probe uses: the L3 marker
    # is in the commitments response. Must come back FAIL.
    local cap rc
    cap="$(mktemp)"
    cat > "${cap}" <<'JSON'
{"markers": {"l3": "ZEPHYR-SELFTEST", "l2": "QUARTZ-SELFTEST"},
 "seeds": {"l3": {"cli_rc": 0, "bundle": "present"}, "l2": {"cli_rc": 0, "bundle": "present"}},
 "tools": {"pwg_commitments": {"status": 200, "text": "{\"commitments\":[{\"action\":\"ZEPHYR-SELFTEST\"}]}"},
           "pwg_topics": {"status": 200, "text": "{\"topics\":[{\"label\":\"QUARTZ-SELFTEST\"}]}"}}}
JSON
    ( decide "${cap}" ) >/dev/null; rc=$?
    rm -f "${cap}"
    probe_examined 1 "known-bad capture"
    [ "${rc}" -eq 1 ] && probe_fail "negative control behaved: an L3 marker in a tool response was FAIL, and the judge's own cases landed on their verdicts"
    probe_pass "SELF-TEST BROKEN: the known-bad capture came back rc=${rc}, not FAIL"
}

run_probe() {
    box_reachable || probe_cannot_run "cannot reach the box; nothing was seeded or read"
    local remote cap
    remote="/tmp/ostler-probe-no-l3-$$.py"
    box_run "printf %s '$(base64 < "${_BOXSCRIPT}" | tr -d '\n')' | base64 -d > ${remote}" >/dev/null 2>&1 \
        || probe_cannot_run "could not stage the seed and reader on the box"
    cap="$(mktemp)"
    box_run "/usr/bin/python3 ${remote}; rm -f ${remote}" > "${cap}" 2>/dev/null
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${cap}" 2>/dev/null \
        || { rm -f "${cap}"; probe_cannot_run "the box-side seed and reader returned no capture"; }
    trap 'rm -f "${cap}"' EXIT
    decide "${cap}"
}

probe_main "$@"
