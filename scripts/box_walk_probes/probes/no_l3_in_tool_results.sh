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
# WALK_WRITES: seeds two conversations on the box. Refuses unless
# OSTLER_NO_L3_ALLOW_WRITE=1 is set, the same gate the other writing probes use
# (hub_screens_render_for_a_customer.sh OSTLER_SCREENS_ALLOW_WRITE).
# TEARDOWN: after the reads, each seeded id is forgotten with the harness's own
# forget statements (conversation_seed.sh forget step, run under /bin/sh). Before
# and after counts are reported, and a non-zero count before the delete is the
# positive control. Residue after the delete is CANNOT-RUN. Needs
# OSTLER_NO_L3_OWNER_ID (the box's owner id, from the walker's environment).
#
# WHAT IT MEASURES: the Hub's loopback routes (CM041 ical-server.py, :8090),
# so a FAIL is a CM041 source defect, not an oa #716 defect. The one exception
# is pwg_knowledge_search: no Hub route exists for notes, so the probe replays
# the tool's own Qdrant request (fail-closed filter included) and measures that
# request, not oa #716 code.
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
    # A FAILING fake box run must come out CANNOT-RUN (exit 78), never PASS or
    # FAIL. Run in a subshell so probe_cannot_run's exit stays contained.
    ( box_reachable() { return 0; }
      box_run() { echo "fake box: seed exploded" >&2; return 1; }
      OSTLER_NO_L3_OWNER_ID=selftest OSTLER_NO_L3_ALLOW_WRITE=1 run_probe ) >/dev/null 2>&1
    local fake_rc=$?
    probe_examined 1 "failing fake box run"
    [ "${fake_rc}" -eq 78 ] || {
        probe_pass "SELF-TEST BROKEN: a failing box run came back rc=${fake_rc}, not CANNOT-RUN (78)"
    }
    # An empty capture (box run ok, no output) must also be CANNOT-RUN.
    ( box_reachable() { return 0; }
      box_run() { return 0; }
      OSTLER_NO_L3_OWNER_ID=selftest OSTLER_NO_L3_ALLOW_WRITE=1 run_probe ) >/dev/null 2>&1
    fake_rc=$?
    [ "${fake_rc}" -eq 78 ] || {
        probe_pass "SELF-TEST BROKEN: an empty capture came back rc=${fake_rc}, not CANNOT-RUN (78)"
    }
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
 "teardown": {"l3": {"parsed": true, "before_qdrant": 2, "before_graph": 3, "after_qdrant": 0, "after_graph": 0},
              "l2": {"parsed": true, "before_qdrant": 2, "before_graph": 3, "after_qdrant": 0, "after_graph": 0}},
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
    # WALK_WRITES gate: this probe writes two conversations to the box. Refuse
    # on a read-only walk rather than write silently.
    [ "${OSTLER_NO_L3_ALLOW_WRITE:-0}" = "1" ] \
        || probe_cannot_run "WALK_WRITES probe refused on a read-only walk: set OSTLER_NO_L3_ALLOW_WRITE=1 to seed two synthetic conversations"
    # The teardown needs the box's owner id, read from the walker's environment
    # and passed to the box. It is never written into this repo.
    [ -n "${OSTLER_NO_L3_OWNER_ID:-}" ] \
        || probe_cannot_run "OSTLER_NO_L3_OWNER_ID is unset; the teardown needs the box owner id"
    box_reachable || probe_cannot_run "cannot reach the box; nothing was seeded or read"
    local remote cap
    remote="/tmp/ostler-probe-no-l3-$$.py"
    _no_l3_box_capture "printf %s '$(base64 < "${_BOXSCRIPT}" | tr -d '\n')' | base64 -d > ${remote}" "" \
        || probe_cannot_run "could not stage the seed and reader on the box"
    cap="$(mktemp)"
    trap 'rm -f "${cap}"' EXIT
    _no_l3_box_capture "OSTLER_NO_L3_OWNER_ID='${OSTLER_NO_L3_OWNER_ID}' /usr/bin/python3 ${remote}; rm -f ${remote}" "${cap}" \
        || probe_cannot_run "the box-side seed and reader failed; its stderr is above"
    _no_l3_capture_ok "${cap}" \
        || probe_cannot_run "the box-side seed and reader returned an empty or non-JSON capture (see the stderr above)"
    decide "${cap}"
}

# THE ONLY WAY A BOX RUN IS CAPTURED. stderr is kept in a file and printed on
# failure, never discarded: a failed seed or teardown must read as a failure,
# not as an empty capture. Returns the box command's exit status.
_no_l3_box_capture() {
    local cmd="$1" out="$2" errf rc
    errf="$(mktemp)"
    if [ -n "${out}" ]; then
        box_run "${cmd}" > "${out}" 2> "${errf}"
    else
        box_run "${cmd}" > /dev/null 2> "${errf}"
    fi
    rc=$?
    if [ "${rc}" -ne 0 ]; then
        echo "box run failed rc=${rc}; stderr:" >&2
        sed 's/^/  | /' "${errf}" >&2
    fi
    rm -f "${errf}"
    return "${rc}"
}

# A capture is usable only if it is non-empty JSON.
_no_l3_capture_ok() {
    [ -s "$1" ] && python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$1"
}

probe_main "$@"
