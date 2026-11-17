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
# THE L0/L3 WINDOW (timeline, reply-debt, brief): see lib/no_l3_box.py's header
# for each route. Each path prints its own line with its L2 control state; a path
# whose L2 control is silent, or that was not read, is CANNOT-RUN.
#
# WALK_WRITES: seeds two conversations, a fixture person with L2/L0/L3 facts and
# todos, and (temporarily) an email reply-debt snapshot on the box. Refuses unless
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
_PATHS_REPORT="${_HERE}/lib/no_l3_paths.py"
# Everything the box script imports, staged together (tar, gzip, base64).
_BOXFILES="no_l3_box.py no_l3_graph_seed.py no_l3_preflight.sh assistant_chat.py wow_moments.py smart_prefs.py"
# The decision writer (CM041 meeting_syncer/decision_extractor.py, stdlib + httpx) is
# staged from the vendored tree, not copied into lib/: the box runs the shipped code.
_DECISION_WRITER="${_HERE}/../../vendor/cm041/meeting_syncer/decision_extractor.py"   # _HERE = scripts/box_walk_probes

# ONE decision, shared by run_probe and self_test: judge a capture file.
decide() {
    local cap="$1" out rep rc rrc n
    # ALL THREE PATHS, each with its L2 control state (the judge stops at the
    # first failing path), then the judge, then the fixture-teardown gate.
    rep="$(python3 "${_PATHS_REPORT}" report "${cap}")"; rrc=$?
    printf '%s\n' "${rep}"
    out="$(python3 "${_JUDGE}" judge "${cap}")"; rc=$?
    printf '%s\n' "${out}"
    n="$(printf '%s\n%s\n' "${out}" "${rep}" | grep -cE '^  (ok|FAIL|CANNOT|path) ')"
    probe_examined "${n}" "tool responses, path lines and seed/control lines"
    [ "${n}" -gt 0 ] || probe_cannot_run "the judge printed nothing; a silent probe is not a pass"
    case "${rc}" in
        0)  [ "${rrc}" -eq 0 ] || probe_cannot_run "the judge saw no leak but the fixture teardown was not proven (see the CANNOT line above); a leak-free read of an unmeasured box is not a pass"
            probe_pass "no L0/L3 marker on the timeline, reply-debt and brief paths or in any of the seven tool responses, the L2 control surfaced, and the fixture is torn down (see the denominator above)" ;;
        78) probe_cannot_run "a path was not captured, a seed did not complete, or the L2 control did not surface (see the CANNOT line above)" ;;
        *)  probe_fail "an L0 or L3 marker reached an outbound path (see the FAIL lines above)" ;;
    esac
}

self_test() {
    # A FAILING fake box run must come out CANNOT-RUN (exit 78), never PASS or
    # FAIL. Run in a subshell so probe_cannot_run's exit stays contained.
    ( box_reachable() { return 0; }
      box_run() { echo "fake box: seed exploded" >&2; return 1; }
      EXPECTED_ICAL_SHA256=$(printf 'a%.0s' $(seq 64)) OSTLER_NO_L3_OWNER_ID=selftest OSTLER_NO_L3_ALLOW_WRITE=1 run_probe ) >/dev/null 2>&1
    local fake_rc=$?
    probe_examined 1 "failing fake box run"
    [ "${fake_rc}" -eq 78 ] || {
        _st_broken "a failing box run came back rc=${fake_rc}, not CANNOT-RUN (78)"
    }
    # A box that DISCONNECTS mid-run (stage ok, launch ok, first poll ALIVE, then
    # every ssh fails) must come out CANNOT-RUN with the residue line, and the
    # staging dir must never be removed while the pid could still be alive.
    local log out2
    log="$(mktemp)"
    out2="$( box_reachable() { return 0; }
      box_run() {
          printf '%s\n' "$1" >> "${log}"
          case "$1" in
              *no_l3_preflight*) printf 'PF_RUNNING=1\nPF_SHA=%s\nPF_START_EPOCH=2000\nPF_START_ISO=2026-11-17T01:00:00Z\nPF_MTIME_EPOCH=1000\nPF_MTIME_ISO=2026-11-16T10:00:00Z\n' "$(printf 'a%.0s' $(seq 64))"; return 0 ;;
              *OSTLER_OXIGRAPH_URL*) echo AMBIENT=0; return 0 ;;
              *"mkdir -p"*) return 0 ;;
              *nohup*) echo 4242; return 0 ;;
              *"kill -0"*) if grep -q ALIVEONCE "${log}"; then return 255; fi; echo ALIVEONCE >> "${log}"; echo ALIVE; return 0 ;;
              *) return 255 ;;
          esac
      }
      OSTLER_NO_L3_POLL_S=0 OSTLER_NO_L3_POLL_FAILS=3 EXPECTED_ICAL_SHA256=$(printf 'a%.0s' $(seq 64)) OSTLER_NO_L3_OWNER_ID=selftest OSTLER_NO_L3_ALLOW_WRITE=1 run_probe 2>&1 )"
    fake_rc=$?
    probe_examined 1 "mid-run disconnect"
    [ "${fake_rc}" -eq 78 ] || {
        rm -f "${log}"
        _st_broken "a mid-run disconnect came back rc=${fake_rc}, not CANNOT-RUN (78)"
    }
    printf '%s' "${out2}" | grep -q 'TEARDOWN NOT OBSERVED, residue unknown' || {
        rm -f "${log}"
        _st_broken "a mid-run disconnect did not print the residue-unknown line"
    }
    printf '%s' "${out2}" | grep -q '4242' || {
        rm -f "${log}"
        _st_broken "the residue line did not carry the pid"
    }
    if grep -q 'rm -rf' "${log}"; then
        rm -f "${log}"
        _st_broken "the staging dir was removed while the pid could still be alive"
    fi
    grep -q 'caffeinate -dimsu' "${log}" || {
        rm -f "${log}"
        _st_broken "the box run was not launched under caffeinate"
    }
    rm -f "${log}"
    # An empty capture (box run ok, no output) must also be CANNOT-RUN.
    ( box_reachable() { return 0; }
      box_run() { return 0; }
      EXPECTED_ICAL_SHA256=$(printf 'a%.0s' $(seq 64)) OSTLER_NO_L3_OWNER_ID=selftest OSTLER_NO_L3_ALLOW_WRITE=1 run_probe ) >/dev/null 2>&1
    fake_rc=$?
    [ "${fake_rc}" -eq 78 ] || {
        _st_broken "an empty capture came back rc=${fake_rc}, not CANNOT-RUN (78)"
    }
    python3 "${_PATHS_REPORT}" --self-test >/dev/null 2>&1 || {
        probe_examined 5 "path-report cases"
        _st_broken "the per-path report put a known case on the wrong line"
    }
    python3 "${_BOXSCRIPT}" --self-test >/dev/null 2>&1 || {
        probe_examined 5 "box-script cases"
        _st_broken "the box script's path classifier or snapshot shape is wrong"
    }
    python3 "${_JUDGE}" --self-test >/dev/null 2>&1 || {
        probe_examined 5 "judge cases"
        _st_broken "the judge put a known case on the wrong verdict"
    }
    # A leak-free capture whose fixture teardown was NOT proven (no graph rows
    # counted, directory not restored) must be CANNOT-RUN, never PASS.
    local capc
    capc="$(mktemp)"
    cat > "${capc}" <<'JSON'
{"markers": {"l3": "ZEPHYR-SELFTEST", "l2": "QUARTZ-SELFTEST", "l0": "ZETA-SELFTEST"},
 "seeds": {"l3": {"cli_rc": 0, "bundle": "present"}, "l2": {"cli_rc": 0, "bundle": "present"}},
 "paths": {"timeline": {"status": "captured", "control": true, "text": "QUARTZ-SELFTEST", "reply_text": "QUARTZ-SELFTEST", "api_text": "{\"events\": [{\"conversation_id\": \"ostler-walk-QUARTZ-SELFTEST\", \"privacy_level\": \"L2\"}, {\"conversation_id\": \"ostler-walk-ZETA-SELFTEST\", \"privacy_level\": \"L0\"}]}"},
           "brief_catchup": {"status": "captured", "control": true, "text": "QUARTZ-SELFTEST"},
           "reply_debt": {"status": "captured", "control": true, "text": "QUARTZ-SELFTEST"}},
 "fixture": {"disk_before": 3, "disk_after": 1, "graph_before": 9, "graph_after": 3, "stamp_after": 3, "control_known_live": 50,
             "reply_debt": {"restored": false}},
 "teardown": {"l3": {"parsed": true, "before_qdrant": 0, "before_graph": 0, "after_qdrant": 0, "after_graph": 0, "files_before": 4, "files_after": 0},
              "l2": {"parsed": true, "before_qdrant": 2, "before_graph": 3, "after_qdrant": 0, "after_graph": 0}},
 "tools": {"pwg_topics": {"status": 200, "text": "{\"topics\":[{\"label\":\"QUARTZ-SELFTEST\"}]}"}}}
JSON
    ( decide "${capc}" ) >/dev/null 2>&1; fake_rc=$?
    rm -f "${capc}"
    probe_examined 1 "clean read, unproven teardown"
    [ "${fake_rc}" -eq 78 ] || {
        _st_broken "a leak-free read with residue came back rc=${fake_rc}, not CANNOT-RUN (78)"
    }
    # SUITE CONTRACT (lib/probe.sh, run_box_walk.sh phase 1): the default --self-test
    # must END on the known-bad capture and exit 1. Every fixture check above held,
    # so finish with the negative control: decide() must FAIL it (rc 1). If decide()
    # passes it (rc 0) the runner reads "returned 0, expected 1" and marks BROKEN.
    printf 'self-test: every fixture check held; now the negative control (rc 1 required)\n'
    negative_control
}

# A broken fixture check. The runner greps "VERDICT: BROKEN" whatever the rc, and
# rc 2 is never the 1 that phase 1 counts as "goes red on known-bad input".
_st_broken() {
    printf 'VERDICT: BROKEN -- %s self-test: %s\n' "${PROBE_NAME}" "$1"
    exit 2
}

# THE NEGATIVE CONTROL, its own invocation. A known-bad capture (an L3 marker in a
# tool response) run through the SAME decide() run_probe uses. decide must FAIL it:
# probe_fail prints the FAIL verdict and exits 1. This function never returns:
# rc 1 with the FAIL line means the control held; rc 0 means decide() passed a
# known-bad capture, i.e. the control is broken and the wiring step must fail.
negative_control() {
    local cap
    cap="$(mktemp)"
    cat > "${cap}" <<'JSON'
{"markers": {"l3": "ZEPHYR-SELFTEST", "l2": "QUARTZ-SELFTEST", "l0": "ZETA-SELFTEST"},
 "seeds": {"l3": {"cli_rc": 0, "bundle": "present"}, "l2": {"cli_rc": 0, "bundle": "present"}},
 "paths": {"timeline": {"status": "captured", "text": "L2 only", "reply_text": "QUARTZ-SELFTEST", "api_text": "{\"events\": [{\"conversation_id\": \"ostler-walk-QUARTZ-SELFTEST\", \"privacy_level\": \"L2\"}, {\"conversation_id\": \"ostler-walk-ZETA-SELFTEST\", \"privacy_level\": \"L0\"}]}"},
           "brief_catchup": {"status": "captured", "text": "L2 only"},
           "reply_debt": {"status": "captured", "text": "L2 only"}},
 "teardown": {"l3": {"parsed": true, "before_qdrant": 0, "before_graph": 0, "after_qdrant": 0, "after_graph": 0, "files_before": 4, "files_after": 0},
              "l2": {"parsed": true, "before_qdrant": 2, "before_graph": 3, "after_qdrant": 0, "after_graph": 0}},
 "tools": {"pwg_commitments": {"status": 200, "text": "{\"commitments\":[{\"action\":\"ZEPHYR-SELFTEST\"}]}"},
           "pwg_topics": {"status": 200, "text": "{\"topics\":[{\"label\":\"QUARTZ-SELFTEST\"}]}"}}}
JSON
    probe_examined 1 "known-bad capture"
    decide "${cap}"
    rm -f "${cap}"
    printf 'VERDICT: BROKEN -- negative control returned without a verdict\n'
    exit 2
}

# THE STORE THE SEED WRITES TO. The walker's NO_L3_SEED_OXIGRAPH_URL is forwarded to the
# box; if it is unset and the BOX has OSTLER_OXIGRAPH_URL set, refuse: an ambient store
# setting must never choose where the seed writes. Only the box's answer AMBIENT=0|1 is
# read, never its environment. Sets NO_L3_SEED_FORWARD. Calls probe_cannot_run on refusal,
# so it must run in the current shell, not in $(...).
_no_l3_resolve_seed_url() {
    NO_L3_SEED_FORWARD=""
    if [ -n "${NO_L3_SEED_OXIGRAPH_URL:-}" ]; then
        [[ "${NO_L3_SEED_OXIGRAPH_URL}" =~ ^http://(127\.0\.0\.1|localhost|\[::1\]):[0-9]{1,5}$ ]] \
            || probe_cannot_run "NO_L3_SEED_OXIGRAPH_URL is not a loopback URL (http://127.0.0.1, http://localhost or http://[::1] with a port); refusing to pass it to the box"
        NO_L3_SEED_FORWARD="${NO_L3_SEED_OXIGRAPH_URL}"
        return 0
    fi
    local amb
    amb="$(box_run 'if [ -n "${OSTLER_OXIGRAPH_URL:-}" ]; then echo AMBIENT=1; else echo AMBIENT=0; fi')" \
        || probe_cannot_run "could not read the box's store setting; nothing was seeded"
    case "${amb}" in
        *AMBIENT=1*) probe_cannot_run "the box has OSTLER_OXIGRAPH_URL set and NO_L3_SEED_OXIGRAPH_URL is unset on the walker: refusing, so an ambient store setting cannot choose where the seed writes" ;;
        *AMBIENT=0*) return 0 ;;
        *) probe_cannot_run "unexpected answer from the box about its store setting: ${amb}" ;;
    esac
}

# PREFLIGHT. Before any seed: the RUNNING ical-server must be the build the walker
# pinned, and must have started AFTER its file was last written (a process that started
# earlier loaded an older copy). EXPECTED_ICAL_SHA256 is required (full 64 hex); unset is
# CANNOT-RUN. The box reports the running service (lib/no_l3_preflight.sh); this function
# judges it. _no_l3_preflight_decide prints the verdict line (rc 0) or the refusal (rc 1).
_no_l3_preflight_decide() {  # expected running obs_sha start_epoch start_iso mtime_epoch mtime_iso
    local expected="$1" running="$2" sha="$3" se="$4" si="$5" me="$6" mi="$7"
    if [ -z "${expected}" ]; then
        echo "preflight unset: EXPECTED_ICAL_SHA256 is not set; refusing to run against an unpinned ical-server"; return 1
    fi
    if ! [[ "${expected}" =~ ^[0-9a-f]{64}$ ]]; then
        echo "preflight unset: EXPECTED_ICAL_SHA256 is not a full 64-character lowercase sha256"; return 1
    fi
    if [ "${running}" != 1 ]; then
        echo "preflight: the ical-server (com.ostler.ical-server) is not running on the box; nothing was seeded"; return 1
    fi
    if [ "${sha}" != "${expected}" ]; then
        echo "preflight: running ical-server sha256 differs from EXPECTED. running=${sha} expected=${expected} pid_start=${si} file_mtime=${mi}"; return 1
    fi
    if [ -z "${se}" ] || [ "${se}" -lt "${me}" ]; then
        echo "preflight: the ical-server process started BEFORE its file was last written (it loaded an older copy). running=${sha} expected=${expected} pid_start=${si} file_mtime=${mi}"; return 1
    fi
    printf 'preflight ical-server running=%s expected=%s pid_start=%s file_mtime=%s OK\n' \
        "${sha:0:16}" "${expected:0:16}" "${si}" "${mi}"
    return 0
}

# Read the PF_ lines the box printed (lib/no_l3_preflight.sh), then judge them.
_no_l3_preflight() {  # remote
    local remote="$1" pf running sha se si me mi res
    [ -n "${EXPECTED_ICAL_SHA256:-}" ] \
        || probe_cannot_run "preflight unset: EXPECTED_ICAL_SHA256 is required; the walk does not run against an unpinned ical-server"
    pf="$(box_run "sh ${remote}/no_l3_preflight.sh")" \
        || probe_cannot_run "preflight: could not read the running ical-server on the box; nothing was seeded"
    get() { printf '%s\n' "${pf}" | sed -n "s/^PF_$1=//p" | head -1; }
    running="$(get RUNNING)"; sha="$(get SHA)"; se="$(get START_EPOCH)"; si="$(get START_ISO)"
    me="$(get MTIME_EPOCH)"; mi="$(get MTIME_ISO)"
    res="$(_no_l3_preflight_decide "${EXPECTED_ICAL_SHA256}" "${running}" "${sha}" "${se}" "${si}" "${me}" "${mi}")" \
        || probe_cannot_run "${res}"
    printf '%s\n' "${res}"
}

# Cases for the preflight decision (no box). rc 0 only if every case held.
preflight_test() {
    local fails=0 E="$(printf 'a%.0s' $(seq 64))" OTHER="$(printf 'b%.0s' $(seq 64))"
    check() {  # name, want-rc, args...
        local name="$1" want="$2"; shift 2
        local out rc
        out="$(_no_l3_preflight_decide "$@")"; rc=$?
        if [ "${rc}" -eq "${want}" ]; then printf '  held   %-46s rc=%s\n' "${name}" "${rc}"
        else printf '  FAILED %-46s wanted rc=%s got rc=%s: %s\n' "${name}" "${want}" "${rc}" "${out}"; fails=$((fails + 1)); fi
    }
    check "matching sha, started after mtime -> OK" 0 "${E}" 1 "${E}" 2000 "2026-11-17T01:00:00Z" 1000 "2026-11-16T10:00:00Z"
    check "mismatching sha -> refused" 1 "${E}" 1 "${OTHER}" 2000 "2026-11-17T01:00:00Z" 1000 "2026-11-16T10:00:00Z"
    check "process started before the file mtime -> refused" 1 "${E}" 1 "${E}" 900 "2026-11-16T09:00:00Z" 1000 "2026-11-16T10:00:00Z"
    check "unset expectation -> refused" 1 "" 1 "${E}" 2000 "x" 1000 "y"
    check "malformed expectation (not 64 hex) -> refused" 1 "abc" 1 "abc" 2000 "x" 1000 "y"
    check "service not running -> refused" 1 "${E}" 0 "" "" "" 1000 "y"
    # The box-side collector, run here against a REAL live process and a stubbed launchctl
    # (the service's pid and ProgramArguments are the stub's; sha, start time and mtime are
    # read from the real process and file).
    local d spid out want_sha
    d="$(mktemp -d)"; printf 'print("stub")\n' > "${d}/ical-server.py"
    sleep 60 & spid=$!
    cat > "${d}/launchctl" <<LC
#!/bin/sh
printf 'gui/501/com.ostler.ical-server = {\n\tpid = %s\n\targuments = {\n\t\t/usr/bin/python3\n\t\t%s/ical-server.py\n\t}\n}\n' "${spid}" "${d}"
LC
    chmod +x "${d}/launchctl"
    out="$(PATH="${d}:${PATH}" sh "${_HERE}/lib/no_l3_preflight.sh")"
    kill "${spid}" 2>/dev/null; wait "${spid}" 2>/dev/null
    want_sha="$(shasum -a 256 "${d}/ical-server.py" | awk '{print $1}')"
    if printf '%s\n' "${out}" | grep -qx "PF_RUNNING=1" \
        && printf '%s\n' "${out}" | grep -qx "PF_SHA=${want_sha}" \
        && printf '%s\n' "${out}" | grep -qE '^PF_START_EPOCH=[0-9]+$' \
        && printf '%s\n' "${out}" | grep -qE '^PF_MTIME_EPOCH=[0-9]+$'; then
        echo "  held   collector reads a live process: running, sha, start and mtime"
    else
        echo "  FAILED collector output: ${out}"; fails=$((fails + 1))
    fi
    rm -rf "${d}"

    if [ "${fails}" -eq 0 ]; then echo "preflight: every case held"; exit 0; fi
    echo "preflight: ${fails} case(s) FAILED"; exit 1
}

# The env prefix the box launch carries (empty when nothing is forwarded). No exit here.
_no_l3_seed_prefix() {
    if [ -n "${NO_L3_SEED_FORWARD:-}" ]; then
        printf "NO_L3_SEED_OXIGRAPH_URL='%s' " "${NO_L3_SEED_FORWARD}"
    fi
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
    _no_l3_resolve_seed_url
    local remote cap tarball pid
    remote="/tmp/ostler-probe-no-l3-$$"
    [ -f "${_DECISION_WRITER}" ] || probe_cannot_run "the shipped decision writer is not in the tree (${_DECISION_WRITER}); the decision arm cannot seed"
    # shellcheck disable=SC2086
    tarball="$(tar czf - -C "${_HERE}/lib" ${_BOXFILES} -C "$(dirname "${_DECISION_WRITER}")" decision_extractor.py | base64 | tr -d '\n')"
    _no_l3_box_capture "mkdir -p ${remote} && printf %s '${tarball}' | base64 -d | tar xzf - -C ${remote}" "" \
        || probe_cannot_run "could not stage the seed and reader on the box"
    _no_l3_preflight "${remote}"
    cap="$(mktemp)"
    trap 'rm -f "${cap}"' EXIT
    # DETACHED AND AWAKE. The run takes up to an hour and waits for an email tick
    # on the box; an ssh that is the run's parent dies with the connection and
    # orphans the teardown (run 5, 2026-11-16: ssh rc 255, box slept). So the run
    # is launched under nohup + caffeinate (a process, no pmset or system setting)
    # with its own output files, its pid is recorded, and this side only POLLS.
    pid="$(box_run "cd ${remote} && OSTLER_NO_L3_OWNER_ID='${OSTLER_NO_L3_OWNER_ID}' $(_no_l3_seed_prefix)nohup caffeinate -dimsu /usr/bin/python3 ${remote}/no_l3_box.py > ${remote}/capture.json 2> ${remote}/stderr.txt < /dev/null & echo \$! | tee ${remote}/pid")"
    pid="$(printf '%s' "${pid}" | tr -dc '0-9')"
    [ -n "${pid}" ] || probe_cannot_run "could not launch the detached box run (no pid came back); staging left in ${remote} on the box"
    probe_note "box run detached: pid ${pid}, dir ${remote} (kept until the pid has exited)"
    _no_l3_poll "${remote}" "${pid}" || probe_cannot_run "TEARDOWN NOT OBSERVED, residue unknown: lost the box (polling gave up); the run may still be going or may have left rows. Check on the box: dir ${remote}, pid ${pid}"
    # The pid has EXITED (observed). Only now is it safe to read and remove.
    box_run "cat ${remote}/capture.json" > "${cap}" 2>/dev/null \
        || probe_cannot_run "the run exited but its capture could not be fetched; dir ${remote} kept on the box"
    _no_l3_box_stderr "${remote}"
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

# Poll until the detached pid has EXITED. Each poll is one short ssh; a failed poll
# is retried, never read as "finished". Returns 0 only when the box answered DEAD.
# Gives up (return 1) after OSTLER_NO_L3_POLL_FAILS consecutive failed polls, or
# after OSTLER_NO_L3_POLL_MAX_S in total. The staging dir is NOT touched here.
_no_l3_poll() {
    local remote="$1" pid="$2" out fails=0 start now
    local every="${OSTLER_NO_L3_POLL_S:-15}" maxfails="${OSTLER_NO_L3_POLL_FAILS:-40}" maxs="${OSTLER_NO_L3_POLL_MAX_S:-9000}"
    start="$(date +%s)"
    while :; do
        if out="$(box_run "kill -0 ${pid} 2>/dev/null && echo ALIVE || echo DEAD")" && [ -n "${out}" ]; then
            fails=0
            case "${out}" in
                *DEAD*) return 0 ;;
            esac
        else
            fails=$((fails + 1))
            [ "${fails}" -lt "${maxfails}" ] || return 1
        fi
        now="$(date +%s)"
        [ $((now - start)) -lt "${maxs}" ] || return 1
        sleep "${every}"
    done
}

# Print the box script's stderr (never discarded) and remove the staging dir.
_no_l3_box_stderr() {
    local errf
    errf="$(mktemp)"
    box_run "cat $1/stderr.txt; rm -rf $1" > "${errf}" 2>/dev/null
    if [ -s "${errf}" ]; then
        echo "box stderr:" >&2
        sed 's/^/  | /' "${errf}" >&2
    fi
    rm -f "${errf}"
}

# A capture is usable only if it is non-empty JSON.
_no_l3_capture_ok() {
    [ -s "$1" ] && python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$1"
}

# Cases for the seed-URL resolver. Each runs in a subshell with a fake box_run that
# answers AMBIENT=0|1 (or junk). Prints one line per case; rc 0 only if every case held.
seed_url_test() {
    local fails=0 rc out
    check() {  # name, walker, answer, want-substring-or-"CANNOT"
        local name="$1" walker="$2" answer="$3" want="$4" got rc
        got="$( (
            box_run() { echo "${answer}"; }
            if [ "${walker}" = "UNSET" ]; then unset NO_L3_SEED_OXIGRAPH_URL; else NO_L3_SEED_OXIGRAPH_URL="${walker}"; fi
            _no_l3_resolve_seed_url
            printf 'OK:%s' "$(_no_l3_seed_prefix)"
        ) 2>/dev/null )"; rc=$?
        if [ "${want}" = "CANNOT" ]; then
            if [ "${rc}" -eq 78 ]; then printf '  held   %-40s CANNOT-RUN (rc 78)\n' "${name}"
            else printf '  FAILED %-40s wanted CANNOT-RUN, got rc %s %s\n' "${name}" "${rc}" "${got}"; fails=$((fails + 1)); fi
        else
            case "${got}" in
                *"${want}"*) printf '  held   %-40s %s\n' "${name}" "${got}" ;;
                *) printf '  FAILED %-40s wanted %s, got rc %s %s\n' "${name}" "${want}" "${rc}" "${got}"; fails=$((fails + 1)) ;;
            esac
        fi
    }
    check "unset walker, box has no ambient store" UNSET "AMBIENT=0" "OK:"
    check "unset walker, box HAS ambient store" UNSET "AMBIENT=1" "CANNOT"
    check "unset walker, box answer is junk" UNSET "WHAT" "CANNOT"
    check "walker set, loopback url forwarded" "http://127.0.0.1:7878" "AMBIENT=1" "NO_L3_SEED_OXIGRAPH_URL='http://127.0.0.1:7878'"
    check "walker set to a non-loopback url" "http://example.com:7878" "AMBIENT=0" "CANNOT"
    check "walker set to localhost, forwarded" "http://localhost:7878" "AMBIENT=1" "NO_L3_SEED_OXIGRAPH_URL='http://localhost:7878'"
    check "walker set to ::1, forwarded" "http://[::1]:7878" "AMBIENT=0" "NO_L3_SEED_OXIGRAPH_URL='http://[::1]:7878'"
    check "localhost as a prefix of a remote host" "http://localhost.example.com:7878" "AMBIENT=0" "CANNOT"
    check "::2 is not loopback" "http://[::2]:7878" "AMBIENT=0" "CANNOT"
    check "https on loopback is refused" "https://127.0.0.1:7878" "AMBIENT=0" "CANNOT"
    check "walker set to a quote-injection url" "http://127.0.0.1:7878';rm" "AMBIENT=0" "CANNOT"
    if [ "${fails}" -eq 0 ]; then
        echo "seed-url resolver: every case held"
        exit 0
    fi
    echo "seed-url resolver: ${fails} case(s) FAILED"
    exit 1
}

if [ "${1:-}" = "--negative-control" ]; then
    negative_control
fi
if [ "${1:-}" = "--seed-url-test" ]; then
    seed_url_test
fi
if [ "${1:-}" = "--preflight-test" ]; then
    preflight_test
fi
probe_main "$@"
