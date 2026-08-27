#!/usr/bin/env bash
# probes/usage_journal_producers.sh
# ============================================================================
# QUESTION: after a full compile on this box, has EVERY producer the
#           usage-journal contract declares written a record into the journal?
#
# WHY THIS PROBE EXISTS
# ---------------------
# The local usage figure the product shows a paying customer is compiled from
# <workspace_dir>/state/costs.jsonl, appended to by four repos and the daemon.
# A producer that stops writing is INVISIBLE there: the panel just shows a
# smaller number, which reads as a quiet month rather than a broken pipeline.
#
# The contract's own gate paragraph asks for "at least one `enriching` record
# and at least one `ingesting` record". Three repos owe `enriching`. So one of
# them writing satisfies that predicate forever while the other two are dark --
# a GOLDEN CASE, and a golden case cannot give a denominator. Nine producers
# with one writing passes it every time.
#
# So this probe asserts the roster, not the kinds. The denominator is declared
# in scripts/usage_journal_producers.tsv and its size is pinned separately in
# scripts/usage_journal_producer_floor.tsv, so shrinking the roster to get a
# green takes two edits in one change.
#
# WHAT THIS PROBE IS AND IS NOT
# -----------------------------
# It is the BOX half. It resolves the journal on the box the way the daemon
# does, brings the file back, and hands it to the real gate --
# scripts/verify_usage_journal_producers.py -- which is the same program CI
# drives over fixtures in tests/test_usage_journal_producer_gate.sh. One
# adjudicator, two callers: a box result and a CI result cannot disagree about
# what "present" means.
#
# ⚠️ RUN IT AFTER A FULL COMPILE. Before the first compile the journal is
# absent or empty, and this probe returns CANNOT-RUN for that -- which is
# coverage lost, not a pass, and is counted separately in the walk record.
#
# THREE OUTCOMES, and the gate's three codes map onto the framework's three:
#
#     gate 0  -> PASS         every required producer wrote
#     gate 1  -> FAIL         records exist and a required producer has none
#     gate 2  -> CANNOT-RUN   no journal, empty journal, or a shrunken roster
#
# THE PATH IS RESOLVED ON THE BOX, NEVER HARDCODED. The four branches below
# mirror zeroclaw-config/src/schema.rs::resolve_runtime_config_dirs. They are
# in shell rather than reusing the gate's python because on a remote walk the
# env that decides the answer is the BOX's, and the box has no repo checkout.
# tests/test_usage_journal_producer_gate.sh arm 12 pins this shell resolver
# against the gate's python one on all four branches, so the two cannot drift
# in silence -- MEASURE ON THE HOST THAT RUNS IT.
#
# macOS bash 3.2.57 + BSD userland.
# ============================================================================

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/probe.sh"

PROBE_NAME="usage_journal_producers"
PROBE_QUESTION="has every declared usage-journal producer written a record, or is the cost panel quietly short?"

PROBE_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
GATE="${PROBE_REPO_ROOT}/scripts/verify_usage_journal_producers.py"
ROSTER="${PROBE_REPO_ROOT}/scripts/usage_journal_producers.tsv"
FLOOR="${PROBE_REPO_ROOT}/scripts/usage_journal_producer_floor.tsv"

# The resolver, as one shell program. Quoted heredoc: nothing is expanded HERE,
# it is expanded on the box, which is the only place the answer is true.
read -r -d '' REMOTE_RESOLVER <<'REMOTE_EOF'
if [ -n "${ZEROCLAW_CONFIG_DIR:-}" ]; then
    ws="${ZEROCLAW_CONFIG_DIR}/workspace"
else
    we="${OSTLER_WORKSPACE:-}"
    [ -n "$we" ] || we="${ZEROCLAW_WORKSPACE:-}"
    if [ -n "$we" ]; then
        case "$we" in "~"/*) we="${HOME}${we#\~}" ;; esac
        if [ -f "${we}/config.toml" ]; then
            ws="${we}/workspace"
        elif [ -f "$(dirname "$we")/.zeroclaw/config.toml" ]; then
            ws="$we"
        elif [ "$(basename "$we")" = "workspace" ]; then
            ws="$we"
        else
            ws="${we}/workspace"
        fi
    else
        cfg="${HOME}/.ostler"
        raw=""
        if [ -f "${cfg}/active_workspace.toml" ]; then
            raw="$(sed -n 's/^[[:space:]]*config_dir[[:space:]]*=[[:space:]]*//p' "${cfg}/active_workspace.toml" | head -1 | tr -d '"'"'" | sed 's/[[:space:]]*$//')"
        fi
        if [ -n "$raw" ]; then
            case "$raw" in
                "~"/*) ws="${HOME}${raw#\~}/workspace" ;;
                /*)    ws="${raw}/workspace" ;;
                *)     ws="${cfg}/${raw}/workspace" ;;
            esac
        else
            ws="${cfg}/workspace"
        fi
    fi
fi
printf '%s/state/costs.jsonl\n' "$ws"
REMOTE_EOF

resolve_journal() {
    if [ -n "${OSTLER_USAGE_JOURNAL:-}" ]; then
        printf '%s\n' "${OSTLER_USAGE_JOURNAL}"
        return 0
    fi
    if [ "${USAGE_JOURNAL_PROBE_LOCAL:-0}" -eq 1 ]; then
        bash -c "$REMOTE_RESOLVER"
        return $?
    fi
    box_run "$REMOTE_RESOLVER"
}

# Fetch the journal. Prints "ABSENT" or the file contents after a "PRESENT"
# marker line, so an unreadable file and an empty one stay distinguishable --
# `cat` of a missing file through box_run's stderr suppression would otherwise
# come back as the empty string, exactly like a journal nobody has written to.
fetch_journal() {
    local path="$1"
    local cmd
    cmd="if [ -f \"${path}\" ]; then printf 'PRESENT\\n'; cat \"${path}\"; else printf 'ABSENT\\n'; fi"
    if [ "${USAGE_JOURNAL_PROBE_LOCAL:-0}" -eq 1 ]; then
        bash -c "$cmd"
    else
        box_run "$cmd"
    fi
}

run_probe() {
    [ -f "$GATE" ] || probe_cannot_run "the gate is missing at ${GATE}. Nothing adjudicated this box; that is coverage lost, not a pass."
    command -v python3 >/dev/null 2>&1 \
        || probe_cannot_run "no python3 on this machine, so ${GATE} could not be executed. Nothing was measured."

    box_reachable || probe_cannot_run "box ${OSTLER_BOX_HOST:-<local>} is not reachable over ssh. Nothing was inspected; this is not a pass."

    local journal_path
    journal_path="$(resolve_journal)"
    if [ -z "$journal_path" ]; then
        probe_cannot_run "could not resolve the journal path on ${OSTLER_BOX_HOST:-this machine}. The resolver returned nothing, so no file was even named."
    fi
    probe_note "journal on box : ${journal_path}"

    local raw work
    raw="$(fetch_journal "$journal_path")"
    work="$(mktemp -t ujprobe-XXXXXX)" || probe_cannot_run "mktemp failed on this machine; the journal could not be staged for adjudication"

    case "$raw" in
        ABSENT*)
            rm -f "$work"
            probe_examined 0 "journal records (the file does not exist on the box)"
            probe_cannot_run "no journal at ${journal_path} on ${OSTLER_BOX_HOST:-this machine}. No producer has ever written there, which is what a box looks like BEFORE its first compile. Run a full compile, then re-run this probe."
            ;;
        PRESENT*)
            printf '%s\n' "$raw" | sed '1d' > "$work"
            ;;
        *)
            rm -f "$work"
            probe_cannot_run "the journal reader returned neither PRESENT nor ABSENT for ${journal_path}. The probe did not establish whether the file exists, so it has measured nothing."
            ;;
    esac

    local lines
    lines="$(grep -c . "$work")"
    probe_examined "${lines:-0}" "journal lines read from ${journal_path}"

    local out rc
    out="$(python3 "$GATE" --journal "$work" --roster "$ROSTER" --floor "$FLOOR" 2>&1)"
    rc=$?
    rm -f "$work"
    printf '%s\n' "$out" | sed 's/^/  /'

    case "$rc" in
        0) probe_pass "every required producer in ${ROSTER} wrote into ${journal_path} (${lines} lines read)" ;;
        1) probe_fail "a declared producer wrote NOTHING into ${journal_path}. See the gate output above for which one; the cost panel is short by exactly that producer's work." ;;
        2) probe_cannot_run "the gate could not measure ${journal_path}: see its CANNOT-RUN line above. Coverage lost, not a pass." ;;
        *) probe_fail "the gate exited ${rc}, which is not one of its three declared codes (0/1/2). An unrecognised code from an adjudicator is not a verdict." ;;
    esac
}

# ---------------------------------------------------------------------------
# NEGATIVE CONTROL. Three arms, one per outcome, driven through the SAME
# adjudicator the live run uses -- so a change that breaks the real path breaks
# the control too. A probe that only ever passes is decoration.
# ---------------------------------------------------------------------------
self_test() {
    local fixture="${PROBE_REPO_ROOT}/tests/fixtures/usage_journal/costs_full.jsonl"
    local rc out fails=0 tmp

    if [ ! -f "$fixture" ]; then
        probe_examined 0 "self-test arms (the fixture journal is missing)"
        probe_pass "SELF-TEST BROKEN: no fixture at ${fixture}, so this probe has not demonstrated it can return FAIL and its real result must not be trusted."
    fi

    # ARM 1: a complete journal -> PASS (0). Without this the probe could
    # satisfy arms 2 and 3 by failing unconditionally.
    out="$(USAGE_JOURNAL_PROBE_LOCAL=1 OSTLER_USAGE_JOURNAL="$fixture" \
           bash "${BASH_SOURCE[0]}" 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'SELF-TEST ARM 1 BROKEN: a complete journal returned rc=%s, expected 0\n' "$rc"
        printf '%s\n' "$out" | sed 's/^/    /'
        fails=$((fails + 1))
    else
        printf 'arm 1 OK: a complete journal PASSes\n'
    fi

    # ARM 2: one producer's records deleted -> FAIL (1), naming it.
    tmp="$(mktemp -t ujprobeself-XXXXXX)"
    grep -v 'ostler-fda-ingest-' "$fixture" > "$tmp"
    if [ "$(grep -c . "$tmp")" -ge "$(grep -c . "$fixture")" ]; then
        printf 'SELF-TEST ARM 2 BROKEN: the mutation removed nothing, so this arm tested nothing\n'
        fails=$((fails + 1))
    else
        out="$(USAGE_JOURNAL_PROBE_LOCAL=1 OSTLER_USAGE_JOURNAL="$tmp" \
               bash "${BASH_SOURCE[0]}" 2>&1)"; rc=$?
        if [ "$rc" -ne 1 ] || ! grep -q 'cm051_ostler_fda_ingest' <<< "$out"; then
            printf 'SELF-TEST ARM 2 BROKEN: a deleted producer returned rc=%s without naming it\n' "$rc"
            printf '%s\n' "$out" | sed 's/^/    /'
            fails=$((fails + 1))
        else
            printf 'arm 2 OK: a producer with no records returns FAIL naming cm051_ostler_fda_ingest\n'
        fi
    fi
    rm -f "$tmp"

    # ARM 3: no journal at all -> CANNOT-RUN (78), never PASS and never FAIL.
    # This is the arm the whole framework exists for: a box that has not
    # compiled yet must not look like five simultaneous regressions, and must
    # not look like a clean bill of health either.
    out="$(USAGE_JOURNAL_PROBE_LOCAL=1 \
           OSTLER_USAGE_JOURNAL="${TMPDIR:-/tmp}/ujprobe-there-is-no-journal-$$.jsonl" \
           bash "${BASH_SOURCE[0]}" 2>&1)"; rc=$?
    if [ "$rc" -ne 78 ]; then
        printf 'SELF-TEST ARM 3 BROKEN: an absent journal returned rc=%s, expected 78 (CANNOT-RUN)\n' "$rc"
        printf '%s\n' "$out" | sed 's/^/    /'
        fails=$((fails + 1))
    else
        printf 'arm 3 OK: an absent journal is CANNOT-RUN, not a pass and not five regressions\n'
    fi

    # The convention is INVERTED here and it is deliberate: `--self-test` must
    # come back FAIL (rc 1) when the negative control behaved CORRECTLY, since
    # that is what proves this probe can go red. ingest_coverage.sh exited 0 on
    # success for its whole life, so run_box_walk marked it BROKEN and
    # DISCARDED its real measurement on every walk it was ever part of.
    if [ "$fails" -gt 0 ]; then
        probe_examined "$fails" "self-test arm(s) that did NOT behave as required"
        probe_pass "SELF-TEST BROKEN: ${fails} arm(s) failed. This probe cannot demonstrate a FAIL, so its real result must not be trusted."
    fi
    probe_examined 3 "synthetic journals (negative control: complete / one producer deleted / absent)"
    probe_fail "negative control behaved correctly on all 3 arms (complete PASSes; a deleted producer FAILs and is named; an absent journal is CANNOT-RUN, not a pass)"
}

# A path-resolution passthrough, so tests/test_usage_journal_producer_gate.sh
# can pin this shell resolver against the gate's python one. Intercepted before
# probe_main because it is not a verdict and must not be counted as one.
if [ "${1:-}" = "--print-journal-path" ]; then
    resolve_journal
    exit 0
fi

probe_main "$@"
