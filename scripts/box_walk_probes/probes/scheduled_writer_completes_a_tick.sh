#!/usr/bin/env bash
# scripts/box_walk_probes/probes/scheduled_writer_completes_a_tick.sh
# ============================================================================
# DOES THE RECURRING GRAPH WRITER ACTUALLY COMPLETE A TICK?
#
# THE DEFECT (#851, measured on a live published v1.0.38 box, .228, 2026-08-22):
#
#   fda-rerun   runs=18   last exit status = 1
#
# Exactly two scheduled agents write the graph. email-ingest works. fda-rerun
# has died on every fire since first install. So on a real customer box the
# graph STOPPED GROWING, while the product said "still loading in the
# background" -- and the background was dead.
#
# WHY THIS IS A DIFFERENT QUESTION FROM fda_tick_can_import.sh
#
# That probe asks whether the tick's modules LOAD. This one asks whether the
# tick RUNS TO COMPLETION. They came apart in practice: an import fix can land
# and the agent still die later in its run, and a launchd job can be loaded,
# scheduled and completely inert. Import success is a floor. Completion is the
# thing the customer is promised.
#
# WHAT IT ASSERTS, AND WHAT IT DELIBERATELY DOES NOT
#
# ASSERTS: the writer's last recorded exit status is 0.
#
# DOES NOT ASSERT that the graph GREW. A tick with nothing new to ingest
# legitimately writes nothing, so "triples went up" is not a property a healthy
# box must have, and a probe that demanded it would go red on correct
# behaviour. The observed delta is REPORTED as a note because it is useful, and
# it is not adjudicated. Asserting a thing that is merely usually true is how a
# suite trains people to ignore it.
#
# THE DENOMINATOR IS THE POINT
#
# "No agent is failing" and "no agent was found" print identically. So the
# adjudicator returns NODATA -- never HEALTHY -- when the enumeration is empty,
# and the probe reports CANNOT-RUN. This is the exact shape that has burnt this
# estate repeatedly: a matcher pinned to the wrong label prefix returns zero
# and reads as a clean bill of health. The label is DERIVED here by matching
# 'ostler' anywhere in the label, not by hardcoding a prefix -- the live box
# carries BOTH com.ostler.* and com.creativemachines.ostler.* labels, and a
# probe written against either one alone is silently blind to the other.
#
# BASH 3.2. No mapfile, no associative arrays, no ${var,,}.
# ============================================================================

set -uo pipefail

PROBE_NAME="scheduled_writer_completes_a_tick"
PROBE_QUESTION="does the recurring graph writer complete a tick with exit 0?"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/probe.sh
. "${HERE}/../lib/probe.sh"

# The writer under test. Matched case-insensitively as a SUBSTRING of the
# launchd label, so a rename from com.ostler.* to com.creativemachines.ostler.*
# (which has already happened once in this estate) does not silently blind it.
WRITER_MATCH="fda-rerun"

# ---------------------------------------------------------------------------
# THE ADJUDICATOR, factored so the negative control drives the SAME code.
#
#   adjudicate <launchctl-list-text>  ->  NODATA | HEALTHY | BROKEN <label> <status>
#
# Input is the raw `launchctl list` body: "<pid>\t<status>\t<label>".
# A pid of '-' means not currently running, which is normal for an interval
# job between fires and is NOT a failure. The STATUS column is the verdict.
# ---------------------------------------------------------------------------
adjudicate() {
    _adj_in="$1"
    _adj_hit=0
    _adj_bad=""

    # No subshell-swallowing pipe: read from a here-string so the counters
    # survive. (A `| while read` loop increments in a subshell and every
    # count comes back zero -- a false clean.)
    while IFS= read -r _adj_line; do
        [ -z "$_adj_line" ] && continue
        _adj_label="$(printf '%s\n' "$_adj_line" | awk '{print $3}')"
        _adj_stat="$(printf '%s\n' "$_adj_line" | awk '{print $2}')"
        [ -z "$_adj_label" ] && continue

        # Case-insensitive substring match, bash 3.2 safe (no ${var,,}).
        _adj_lc="$(printf '%s\n' "$_adj_label" | tr 'A-Z' 'a-z')"
        case "$_adj_lc" in
            *"$WRITER_MATCH"*) ;;
            *) continue ;;
        esac

        _adj_hit=$((_adj_hit + 1))
        # A non-numeric status is not a pass. Treat anything that is not
        # exactly 0 as a failure, and say what it was.
        if [ "$_adj_stat" != "0" ]; then
            _adj_bad="${_adj_label} ${_adj_stat}"
        fi
    done <<EOF
$_adj_in
EOF

    if [ "$_adj_hit" -eq 0 ]; then
        # NEVER "HEALTHY". Nothing was examined.
        echo "NODATA"
        return 0
    fi
    if [ -n "$_adj_bad" ]; then
        echo "BROKEN ${_adj_bad}"
        return 0
    fi
    echo "HEALTHY"
}

# Total ostler-owned scheduled jobs, used as the population control. If the
# writer matcher finds nothing BUT this finds nothing either, the fault is the
# enumeration, not the box -- and those two cases must not report the same.
count_ostler_agents() {
    printf '%s\n' "$1" | awk '{print tolower($3)}' | grep -c 'ostler' || true
}

read_triples() {
    box_run 'curl -s --noproxy "*" --max-time 10 -H "Content-Type: application/sparql-query" -H "Accept: application/sparql-results+json" --data-binary "SELECT (COUNT(*) AS ?n) WHERE { ?s ?p ?o }" http://127.0.0.1:7878/query 2>/dev/null' \
        | grep -o '"value":"[0-9]*"' | head -1 | grep -o '[0-9]*' || true
}

run_probe() {
    if ! box_reachable; then
        probe_cannot_run "the box at '${OSTLER_BOX_HOST:-this machine}' did not answer, so no launchd state could be read. Not a pass."
    fi

    LIST="$(box_run 'launchctl list 2>/dev/null')"
    if [ -z "$LIST" ]; then
        probe_cannot_run "'launchctl list' returned nothing on ${OSTLER_BOX_HOST:-this machine}. The agent table could not be read at all, which is not the same as no agent failing."
    fi

    TOTAL_OSTLER="$(count_ostler_agents "$LIST")"
    if [ "$TOTAL_OSTLER" -eq 0 ]; then
        probe_cannot_run "no launchd label on the box contains 'ostler' at all. Either nothing is installed, or this probe's matcher is looking at the wrong thing. Refusing to call that healthy."
    fi
    probe_note "ostler-owned scheduled jobs found: ${TOTAL_OSTLER}"

    T0="$(read_triples)"
    [ -n "$T0" ] && probe_note "triples before tick: ${T0}" \
                 || probe_note "triples before tick: (store did not answer; delta will not be reported)"

    VERDICT="$(adjudicate "$LIST")"

    probe_examined "$TOTAL_OSTLER" "scheduled ostler job(s), of which the ones matching '${WRITER_MATCH}' are adjudicated"

    case "$VERDICT" in
        NODATA)
            probe_cannot_run "${TOTAL_OSTLER} ostler jobs are scheduled but NONE has a label containing '${WRITER_MATCH}'. The recurring graph writer is not installed under the name this probe knows. That is a finding, but it is not a measurement of its exit status."
            ;;
        BROKEN*)
            _lbl="$(printf '%s\n' "$VERDICT" | awk '{print $2}')"
            _st="$(printf '%s\n' "$VERDICT" | awk '{print $3}')"
            probe_note "failing writer: ${_lbl} last exit status ${_st}"
            probe_fail "the recurring graph writer '${_lbl}' last exited ${_st}, not 0, on ${OSTLER_BOX_HOST:-this machine}. Nothing but email tops the graph up, so it has stopped growing while the product tells the customer loading continues in the background."
            ;;
        HEALTHY)
            T1="$(read_triples)"
            if [ -n "$T0" ] && [ -n "$T1" ]; then
                probe_note "triples after: ${T1} (delta $((T1 - T0)) -- REPORTED, NOT ASSERTED: a tick with nothing new to ingest correctly writes nothing)"
            fi
            probe_pass "the recurring graph writer matching '${WRITER_MATCH}' last exited 0, among ${TOTAL_OSTLER} scheduled ostler jobs on ${OSTLER_BOX_HOST:-this machine}"
            ;;
        *)
            probe_fail "adjudicator returned an unrecognised verdict '${VERDICT}'. A probe that cannot classify its own reading must not report a pass."
            ;;
    esac
}

# ---------------------------------------------------------------------------
# NEGATIVE CONTROL. Must come back FAIL, per the probe contract.
#
# Drives the REAL adjudicator against synthetic launchctl tables, so it is
# deterministic with or without a box. Three readings, because the failure
# this probe exists to prevent is not "misses a broken agent" -- it is
# "reports healthy when it examined nothing".
# ---------------------------------------------------------------------------
self_test() {
    _healthy="$(printf -- '-\t0\tcom.ostler.fda-rerun\n99\t0\tcom.creativemachines.ostler.email-ingest\n')"
    _broken="$(printf -- '-\t1\tcom.ostler.fda-rerun\n99\t0\tcom.creativemachines.ostler.email-ingest\n')"
    _renamed="$(printf -- '-\t1\tcom.creativemachines.ostler.FDA-Rerun\n')"
    _empty="$(printf -- '99\t0\tcom.apple.something\n')"

    # 1. A healthy table must adjudicate HEALTHY. If this reads broken, the
    #    probe reds every good box and its FAILs mean nothing.
    if [ "$(adjudicate "$_healthy")" != "HEALTHY" ]; then
        probe_examined 1 "synthetic reading (negative control)"
        probe_pass "NEGATIVE CONTROL OVER-FIRED: a table with every agent at exit 0 was adjudicated '$(adjudicate "$_healthy")'. This probe would fail a healthy box."
    fi

    # 2. The real defect shape: fda-rerun at exit 1.
    case "$(adjudicate "$_broken")" in
        BROKEN*) ;;
        *)
            probe_examined 2 "synthetic readings (negative control)"
            probe_pass "NEGATIVE CONTROL DID NOT FIRE: fda-rerun at exit status 1 was adjudicated '$(adjudicate "$_broken")'. This probe cannot detect the defect it exists for."
            ;;
    esac

    # 3. THE ONE THAT MATTERS. A table with no matching writer must be NODATA,
    #    never HEALTHY. An empty enumeration reading as a pass is the exact
    #    fault this whole framework was built after.
    if [ "$(adjudicate "$_empty")" != "NODATA" ]; then
        probe_examined 3 "synthetic readings (negative control)"
        probe_pass "NEGATIVE CONTROL FAILED ON THE IMPORTANT LIMB: a table containing NO ostler writer was adjudicated '$(adjudicate "$_empty")' rather than NODATA. 'nothing failing' and 'nothing found' would be indistinguishable."
    fi

    # 4. Case/prefix drift must not blind it -- the estate has already renamed
    #    these labels once.
    case "$(adjudicate "$_renamed")" in
        BROKEN*) ;;
        *)
            probe_examined 4 "synthetic readings (negative control)"
            probe_pass "NEGATIVE CONTROL FAILED: a broken writer under a RENAMED, differently-cased label was adjudicated '$(adjudicate "$_renamed")'. A relabel would silently disarm this probe."
            ;;
    esac

    probe_examined 4 "synthetic launchd tables (negative control)"
    probe_fail "negative control behaved correctly on 4 readings (healthy adjudicates healthy; a writer at exit 1 adjudicates broken; a table with no writer adjudicates NODATA rather than healthy; and a renamed, recased label is still caught)"
}

probe_main "$@"
