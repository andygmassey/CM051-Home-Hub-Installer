#!/usr/bin/env bash
# scripts/box_walk_probes/run_box_walk.sh
# ============================================================================
# THE BOX WALK RUNNER
#
# Runs every probe against a freshly installed Hub and reports four counts,
# never one. Usage:
#
#   ./run_box_walk.sh                        # run on this machine
#   OSTLER_BOX_HOST=andy@192.168.1.215 ./run_box_walk.sh
#   ./run_box_walk.sh --list                 # what each probe asks
#   ./run_box_walk.sh --only pair_state      # single probe, substring match
#
# WHAT MAKES THIS DIFFERENT FROM A TEST RUNNER
#
# Phase 1 tries to BREAK every probe before trusting any of them. Each probe is
# invoked with --self-test, which runs its body against a known-bad fixture.
# A probe that does not come back FAIL is marked BROKEN and its real result is
# discarded, because a probe that cannot produce a FAIL has not earned a PASS.
#
# This is the direct lesson of the stub that used to be the entire QA estate:
#
#     echo "STUB -- full probe deferred"; exit 0
#
# Under this runner that file is caught in phase 1, not believed in phase 2.
#
# THE HEADLINE IS NEVER "ALL GREEN". It is four numbers. A run with 9 passes
# and 3 CANNOT-RUN measured nine things and did not measure three, and an
# operator who reads that as "green" has been misled by the report, not by the
# box. So CANNOT-RUN is printed in its own block with the missing prerequisite
# named, every time.
#
# EXIT: 0 only when FAIL=0 and BROKEN=0. CANNOT-RUN does not fail the run --
# it is a coverage statement, not a defect -- but it is always shown.
#
# BASH 3.2 (macOS system bash). No associative arrays, no mapfile.
# ============================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE_DIR="$HERE/probes"

EX_CANNOT_RUN=78

ONLY=""
LIST_ONLY=0
SKIP_SELFTEST=0

while [ $# -gt 0 ]; do
    case "$1" in
        --only) ONLY="${2:-}"; shift 2 ;;
        --list) LIST_ONLY=1; shift ;;
        --no-self-test)
            # Present so that a human debugging a single probe can bypass
            # phase 1. It prints a loud banner because a run without the
            # negative controls is exactly the kind of green this suite
            # exists to distrust.
            SKIP_SELFTEST=1; shift ;;
        -h|--help) sed -n '3,40p' "$0"; exit 0 ;;
        *) printf 'unknown argument: %s\n' "$1"; exit 2 ;;
    esac
done

if [ ! -d "$PROBE_DIR" ]; then
    printf 'FATAL: no probe directory at %s\n' "$PROBE_DIR"
    printf 'That is an empty suite, which would otherwise report a perfect score.\n'
    exit 2
fi

# Collect probes. nullglob so a non-matching glob yields nothing rather than a
# literal "*.sh" -- and an explicit count check below, because an empty list
# must be a hard failure and not a clean run.
#
# THIS GLOB IS THE WHOLE SUITE. A probe file that is not in PROBE_DIR does not
# exist as far as a box walk is concerned, however good it is, and nothing
# anywhere prints the names of files it skipped. people_seed_and_retrieval.sh
# spent its whole life one level up on exactly that basis: 735 lines, graded
# exit codes, the only assertion in the estate that semantic people search
# actually works, and eleven probes reported over the top of it every time.
shopt -s nullglob
PROBES=""
for f in "$PROBE_DIR"/*.sh; do
    b="$(basename "$f" .sh)"
    if [ -n "$ONLY" ]; then
        case "$b" in *"$ONLY"*) ;; *) continue ;; esac
    fi
    PROBES="$PROBES $f"
done
shopt -u nullglob

# DETERMINISTIC ORDER, PINNED TO C. A glob sorts by LC_COLLATE, so the order this
# suite executes in has been whatever locale the operator happens to have.
#
# THAT ORDER IS LOAD-BEARING. pairing_recovers_without_a_repair_storm performs a
# REAL pair against :8443 and, on success, persists a bearer token that nothing
# in the tree revokes; pair_state_agreement READS pairing state. Today the reader
# sorts first and sees the box as installed -- but only because "_" precedes "i"
# in the C collation. A locale that ignores punctuation at the primary level
# compares "pairstate" against "pairingrecovers", where "i" precedes "s", and the
# two INVERT. The reader would then be measuring what this suite just did.
#
# Pinned so the order is a property of the filenames and not of the environment.
# tests/test_a_pairing_reader_runs_before_the_pairing_mutator.sh asserts the
# read-before-mutate relation under BOTH C and the runner's own collation.
if [ -n "${PROBES// /}" ]; then
    PROBES="$(printf '%s\n' $PROBES | LC_ALL=C sort | tr '\n' ' ')"
fi

PROBE_COUNT=0
for _ in $PROBES; do PROBE_COUNT=$((PROBE_COUNT + 1)); done

if [ "$PROBE_COUNT" -eq 0 ]; then
    printf 'FATAL: 0 probes matched.\n'
    printf 'An empty suite passes every assertion it does not make. Refusing to report a result.\n'
    exit 2
fi

if [ "$LIST_ONLY" -eq 1 ]; then
    printf 'BOX WALK PROBES (%s)\n\n' "$PROBE_COUNT"
    for p in $PROBES; do
        bash "$p" --describe 2>/dev/null || printf '%s: (no --describe)\n' "$(basename "$p" .sh)"
    done
    exit 0
fi

printf '============================================================\n'
printf 'BOX WALK -- %s probes\n' "$PROBE_COUNT"
if [ -n "${OSTLER_BOX_HOST:-}" ]; then
    printf 'TARGET: %s\n' "$OSTLER_BOX_HOST"
else
    printf 'TARGET: this machine (OSTLER_BOX_HOST unset)\n'
fi
printf '============================================================\n\n'

# -------------------------------------------------------------------------
# PHASE 1 -- negative controls. Try to make every probe fail.
# -------------------------------------------------------------------------
BROKEN_LIST=""
BROKEN=0

if [ "$SKIP_SELFTEST" -eq 1 ]; then
    printf '!! PHASE 1 SKIPPED (--no-self-test).\n'
    printf '!! No probe in this run has demonstrated it can return FAIL.\n'
    printf '!! Treat every PASS below as unverified.\n\n'
else
    printf -- '--- PHASE 1: negative controls (each probe must be able to FAIL) ---\n'
    for p in $PROBES; do
        b="$(basename "$p" .sh)"
        out="$(bash "$p" --self-test 2>&1)"
        rc=$?
        # THE EXIT CODE IS NOT THE ONLY SIGNAL, and reading it alone is how a
        # broken probe passes phase 1.
        #
        # probe_fail() and the contract's own refusals BOTH exit 1. So a probe
        # that reports a verdict without a denominator prints
        #   VERDICT: BROKEN -- <name> reported a verdict without calling
        #   probe_examined.
        # and exits 1, and an rc-only test counts that as "goes red on
        # known-bad input". The framework catches the fault, announces it, and
        # is then overruled by its own caller.
        #
        # Found 2026-08-20 by tripping it while writing fda_tick_can_import:
        # its self_test omitted probe_examined, the contract refused, and this
        # loop was about to award it an ok. Same class as CM051 #897, where the
        # swift namer and counter disagreed and the exit code was believed.
        #
        # No pipe into a short-circuiting consumer here: under pipefail that
        # inverts a successful match (#895). grep -q on a herestring is safe.
        if grep -q 'VERDICT: BROKEN' <<< "$out"; then
            printf '  BROKEN   %s  (self-test exited %s but its own output says BROKEN)\n' "$b" "$rc"
            printf '%s\n' "$out" | sed 's/^/             /'
            BROKEN_LIST="$BROKEN_LIST $b"
            BROKEN=$((BROKEN + 1))
        elif [ "$rc" -eq 1 ]; then
            printf '  ok       %s  (goes red on known-bad input)\n' "$b"
        else
            printf '  BROKEN   %s  (self-test returned %s, expected 1)\n' "$b" "$rc"
            printf '%s\n' "$out" | sed 's/^/             /'
            BROKEN_LIST="$BROKEN_LIST $b"
            BROKEN=$((BROKEN + 1))
        fi
    done
    printf '\n'
fi

# -------------------------------------------------------------------------
# THE GROUNDING SEED, between the controls and the measurements.
#
# assistant_answers_grounded is BLOCKING and its content assertion exists only
# when OSTLER_GATE_KNOWN_PERSON and OSTLER_GATE_EXPECT_FACT are set. Nothing
# set them, so a bare walk ran that probe against an empty graph with no
# fixture and no content assertion. That is the configuration recorded FAILED
# in walks/v1.0.74.tsv; the probe has passed once, on v1.0.75, and only
# because the seed was run by hand first.
#
# HERE, not in ttywalk.sh, because ttywalk does not invoke this runner at all
# (measured: zero references), so a seed wired there would not reach these
# probes. And AFTER phase 1, because the self-tests never touch the box: this
# is the last moment before anything is measured.
#
# SOURCED AT THE POINT OF USE rather than beside PROBE_DIR at the top. Sibling
# tests and workflows cite this file by line number (:42 PROBE_DIR, :44
# EX_CANNOT_RUN, :83 the probe glob) and those three stay true only while
# nothing is inserted above them. A fourth citation, ":201-204 the BROKEN skip"
# in test_walk_record_states_measured_count.sh and cut-manifest.yml, was ALREADY
# WRONG on origin/main before this branch existed: the skip is at :249 there. It
# is prose in both places, nothing executes a line lookup into this file, so it
# is left for its owners rather than fixed under a freeze.
. "$HERE/lib/grounding_seed.sh"
grounding_seed_apply || true

# ── AND THE PREFERENCE SEED, the same discipline on the other write route ──
#
# The seed above puts a PERSON in the graph. Nothing put a PREFERENCE there,
# so an empty preference wiki, an ingest that never ran and a broken write
# route were three faults wearing one face. On v1.0.81 the root cause turned
# out to be the first of those: cm019_setup logged "already set up" with
# elapsed_s=0 and install.log holds no ingest-dir and no "Files processed".
#
# BELOW the grounding seed, not above it, so the line citations at the top of
# this file (:42 PROBE_DIR, :44 EX_CANNOT_RUN, :83 the probe glob) keep their
# line numbers. Nothing executes a line lookup into this file, but three
# places quote those three, and an insertion above them would rot all three
# for no gain.
#
# `|| true` for the same reason the seed above carries it: this step reports
# its own outcome in words, and every path it can fail on is either a named
# CANNOT-RUN or a named FINDING. Neither should abort a walk that has not
# measured anything yet.
. "$HERE/lib/preference_seed.sh"
preference_seed_apply || true

# ── AND THE CONVERSATION SEED, the third write route, and the only one that
#    needs a model call ──
#
# The two seeds above write a PERSON and a PREFERENCE. Nothing had ever put a
# CONVERSATION through the conversation pipeline, and the pipeline is the only
# writer of two things three probes read: the conversations Qdrant collection,
# which the installer pre-creates EMPTY (install.sh:18448) and which
# ingest_coverage scores EMPTY at 0, and the pwg:ConversationTopic nodes that
# /api/v1/topics serves to pwg_topics. Nothing is processed at install time
# (install.sh:19178-19180 checks --help and an import, and that is all), so on
# a cold box those probes measure an empty store and cannot tell that from a
# broken one.
#
# BELOW the two seeds above, so the line citations at the top of this file
# (:42 PROBE_DIR, :44 EX_CANNOT_RUN, :83 the probe glob) keep their line
# numbers, for the reason the block above gives.
#
# IT IS THE SLOWEST STEP IN THE WALK, ON PURPOSE. It makes six sequential model
# calls, measured around 100 s each on a shipped box, and it is bounded at
# OSTLER_CONVO_SEED_BUDGET_S (default 900). That cost buys the only assertion
# in this suite that the conversation pipeline runs at all.
#
# `|| true` for the same reason the two above carry it: it reports its own
# outcome in words, and every path it can fail on is either a named CANNOT-RUN
# or a named FINDING.
. "$HERE/lib/conversation_seed.sh"
conversation_seed_apply || true

# ── AND THE USAGE SEED, on the producer that had nothing to write ──
#
# The two seeds above put CONTENT in front of a probe. This one puts WORK in
# front of one: usage_journal_producers asks whether every declared producer
# has written a record, and on v1.0.81 cm051_ostler_fda_ingest had not, into a
# journal holding 557 parsed rows. Not because the writer is missing -- it is
# vendored and proven by execution -- but because a row is written only on a
# MEASURED embedding call (pwg_ingest.py:65-66), and the one ingest leg with
# guaranteed input on a wiped box was SKIPPED by a surviving hydrate sentinel
# (install.sh:26392-26413 gating :29374).
#
# So the step below runs install.sh:29420-29424 verbatim and counts the
# producer's rows either side of it. It states in its own output, every time,
# that the sweep was run BY HAND, because that converts the probe from "the
# install exercises the ingest" to "the ingest can write when run by hand" and
# the record has to be readable by someone who was not here.
#
# LAST OF THE FOUR, and below the conversation seed in particular: that seed
# makes six sequential model calls under its own budget, and this step reads a
# journal those calls also write into. Counting the before edge after it has
# finished keeps this delta attributable to THIS sweep. The line citations at
# the top of this file (:42 PROBE_DIR, :44 EX_CANNOT_RUN, :83 the probe glob)
# also keep their line numbers only while nothing is inserted above them.
#
# `|| true` for the reason both seeds above carry it: every path this step can
# return 1 on is a named CANNOT-RUN or a named FINDING, and neither should
# abort a walk that has not measured anything yet.
. "$HERE/lib/usage_seed.sh"
usage_seed_apply || true

# ── AND WAIT FOR THE WIKI SUMMARY BACKFILL, so cm044_wiki_compiler has written ──
#
# The four seeds above give the box a person, a preference, a conversation and
# one measured embedding call. usage_journal_producers also needs
# cm044_wiki_compiler to have written, and on the wiped v1.0.82 box it had not:
# the compiler writes a cm044-compile- row only from its summary pass, which
# wiki-recompile-tick.sh:394-451 runs as a DETACHED background backfill. Measured
# at 18:53:06Z on that walk: the install-time tick had launched the backfill at
# 18:48:11Z, wiki-recompile-summaries.log was still 0 bytes, and the probe had
# read the journal at about 18:51Z. Asked too early, the same shape as the two
# count-reading probes below.
#
# And at 19:08Z on the same box, twenty minutes after that launch, the log was
# STILL 0 bytes, no process of ours was alive, both LaunchAgents read "not
# running, runs 1, last exit code 0", and the journal held 290 rows with
# cm044-compile- 0: the backfill was gone and had written nothing while every
# liveness signal read green, because the tick exits 0 for having LAUNCHED it.
#
# So this kickstarts the recompile LaunchAgent (after the seeds, so the compile
# sees what they wrote) and waits, bounded by OSTLER_WIKI_WAIT_BUDGET_S, for
# every sign of life to end: the wrapper pid in
# ~/.ostler/.wiki-recompile-summaries.pid, the summaries log GROWING, the slot
# lock's holder, the processes of this account naming the compiler, and the
# compile container once the wrapper is gone. Never the pid alone, and an empty
# log is never "complete": 0 bytes for the whole wait is the FINDING "the
# backfill wrote nothing", a growing log at the budget is CANNOT-RUN "not
# converged in time", and a finished compile with no row names the producer.
# Then it counts the cm044-compile- rows either side. BELOW the usage seed, so
# the line citations at the top of this file (:42 PROBE_DIR, :44 EX_CANNOT_RUN,
# :83 the probe glob) keep their line numbers, and so the usage seed's own delta
# stays attributable to its sweep.
#
# `|| true` for the reason the seeds carry it: every path this step can return 1
# on is a named CANNOT-RUN or a named FINDING. No forget: the compile is the
# product's own.
. "$HERE/lib/wiki_summaries_wait.sh"
wiki_summaries_wait || true

# ── AND WAIT FOR THE GRAPH TO SETTLE, for the two probes that read counts ──
#
# The install-time converge is SIGKILLed at a flat budget and the catch-up agent
# does not tick for ten minutes, then runs for twenty to forty more. The v1.0.78
# walk measured inside that window: contacts read 1629 during the walk and 1920
# an hour later, on the same box, untouched. people_count_agreement and
# people_stores_reconcile were not wrong about what they saw; they were asked
# too early, and a disagreement measured mid-convergence is not a store defect.
#
# Sourced at the point of use for the same reason as the seed above: sibling
# tests and workflows cite this file by line number.
#
# SOURCED HERE, CALLED LATE. The wait itself is deferred to the moment the first
# gated probe is about to run (see the loop below). It used to be called right
# here, which put a wait of up to 2700 s in front of EVERY probe in phase 2,
# including the twenty-odd that never read a count and cannot be affected by a
# moving graph. On a walk where the graph never settles that is 45 minutes
# charged to probes that did not need it. Deferring also means a filtered run
# that collects neither gated probe waits for nothing at all.
. "$HERE/lib/converge_wait.sh"
_CONVERGE_WAIT_DONE=0

# -------------------------------------------------------------------------
# PHASE 2 -- the real measurements.
# -------------------------------------------------------------------------
printf -- '--- PHASE 2: measurements ---\n'
PASS=0
FAIL=0
CANNOT=0
FAIL_LIST=""
CANNOT_LIST=""

# WHY A PROBE DID NOT RUN, NOT ONLY WHICH ONE DID NOT.
#
# lib/probe.sh's probe_cannot_run() prints
#     VERDICT: CANNOT-RUN -- <the missing prerequisite>
# and its own comment says it MUST name that prerequisite "so the operator can
# fix it rather than guess". The header of THIS file promises the same thing:
# "CANNOT-RUN is printed in its own block with the missing prerequisite named,
# every time". It was not. Only the basename reached CANNOT_LIST, and the
# reason was discarded here.
#
# MEASURED 2026-08-29 on walks/v1.0.50.tsv: 6 probes did not run, and no
# reason for any of them is recoverable -- not from the record, not from the
# summary. Dispositioning those six took a hand audit of four probe sources.
#
# bash 3.2 (macOS system bash) has no associative arrays, so the name/reason
# pairs go to a file rather than a map.
CANNOT_REASONS="$(mktemp)"
# WHY A PROBE FAILED, NOT ONLY WHICH ONE DID. The same defect as the block
# above, on the other verdict class: FAIL_LIST carried basenames and the
# VERDICT line was discarded here, so the summary an operator scrolls to and
# copies named the probe and not the finding. Recovering it costs a whole walk
# -- a published DMG, a box and a reset -- which is what assistant_answers_
# grounded cost across walks 9 and 10, red both times and undiagnosed both
# times.
FAIL_REASONS="$(mktemp)"
trap 'rm -f "$CANNOT_REASONS" "$FAIL_REASONS"' EXIT

# OSTLER_PHASE1_VERDICTS: when set, every verdict the loop below reaches is
# appended there as <probe>\t<PASS|FAIL|CANNOT-RUN|BROKEN>\t<utc>\t<reason>, so
# the cut-manifest replay (verify_cut_manifest.py, box_walk_probe rows) can take
# the verdict measured HERE, against the seed fixture and after each probe's
# negative control, instead of running the script again after the forgets at
# the end of this file. v1.0.89: the replay re-ran assistant_answers_grounded
# after SEED-FORGET OK and read tool_found_nothing on stores it had emptied.
_record_verdict() {
    [ -n "${OSTLER_PHASE1_VERDICTS:-}" ] || return 0
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$(printf '%s' "${3:-}" | tr '\n\t' '  ')" >> "$OSTLER_PHASE1_VERDICTS"
}

for p in $PROBES; do
    b="$(basename "$p" .sh)"

    case " $BROKEN_LIST " in
        *" $b "*)
            printf '\n[%s]\n  SKIPPED -- probe failed its own negative control in phase 1.\n' "$b"
            _record_verdict "$b" BROKEN "failed its own negative control in phase 1"
            continue
            ;;
    esac

    # A COUNT READ MID-CONVERGENCE IS NOT A STORE DEFECT. If the graph never
    # settled, the two probes that read counts cannot measure the thing they
    # exist to measure, so they are CANNOT-RUN with the cause named: never
    # FAIL, never PASS. This is a coverage statement, and it is counted in the
    # same four numbers as every other CANNOT-RUN rather than hidden.
    # THE STATE THIS COMPARES AGAINST MUST BE ONE THE LIB CAN ACTUALLY SET.
    # This read `!= "done"` until Aesop's review of #1849 caught it. converge_
    # wait sets exactly five values -- unrun, skipped, stable, unreadable,
    # unstable (lib/converge_wait.sh:59, 125, 170, 183-184) -- and "done" is
    # not among them: it is the last remnant of the marker-file design that
    # this lib deliberately abandoned. So the comparison was true for every
    # value the lib can produce, and BOTH gated probes were CANNOT-RUN
    # unconditionally, including after a wait that succeeded. The gate did not
    # delay the two probes, it deleted them. The lib's own 21-arm suite could
    # not see it because that suite tests the lib and this line is the wiring,
    # which is why the arms added in test_the_walk_waits_for_converge.sh drive
    # THIS block rather than converge_wait().
    #
    # PASS ONLY ON "stable". Every other value, including unrun, means the
    # graph was not measured to have stopped moving.
    if converge_gates_probe "$b"; then
        # The wait happens once, here, immediately before the first probe that
        # needs it, rather than in front of all of phase 2.
        if [ "$_CONVERGE_WAIT_DONE" -eq 0 ]; then
            printf '\n'
            converge_wait || true
            _CONVERGE_WAIT_DONE=1
        fi
        if [ "$CONVERGE_STATE" != "stable" ]; then
            printf '\n[%s]\n' "$b"
            printf '  VERDICT: CANNOT-RUN -- %s\n' "$CONVERGE_DETAIL" | sed 's/^/  /'
            CANNOT=$((CANNOT + 1)); CANNOT_LIST="$CANNOT_LIST $b"
            printf '%s\t%s\n' "$b" "$CONVERGE_DETAIL" >> "$CANNOT_REASONS"
            _record_verdict "$b" CANNOT-RUN "$CONVERGE_DETAIL"
            continue
        fi
    fi

    printf '\n[%s]\n' "$b"
    out="$(bash "$p" 2>&1)"
    rc=$?
    printf '%s\n' "$out" | sed 's/^/  /'

    if [ "$rc" -eq 0 ]; then
        PASS=$((PASS + 1))
        _record_verdict "$b" PASS ""
    elif [ "$rc" -eq "$EX_CANNOT_RUN" ]; then
        CANNOT=$((CANNOT + 1)); CANNOT_LIST="$CANNOT_LIST $b"
        # Everything from the marker to the END of the probe's output is the
        # reason: probe_cannot_run() prints it last and exits immediately. A
        # reason can span lines ($detail is passed whole by several probes),
        # so this takes the tail rather than one line, then flattens it.
        _why="$(printf '%s\n' "$out" \
                | awk '/^VERDICT: CANNOT-RUN -- /{sub(/^VERDICT: CANNOT-RUN -- /, ""); f=1} f' \
                | tr '\n' ' ' | sed 's/  */ /g; s/ *$//')"
        # An unparseable reason is ANNOUNCED, never left blank. A blank here
        # would read as "no reason was given" when what it means is "this
        # probe exited 78 without going through probe_cannot_run", which is a
        # contract breach and a different problem entirely.
        [ -n "$_why" ] || _why="UNRECORDED -- exited ${EX_CANNOT_RUN} with no 'VERDICT: CANNOT-RUN --' line, so it bypassed probe_cannot_run and named no prerequisite"
        printf '%s\t%s\n' "$b" "$_why" >> "$CANNOT_REASONS"
        _record_verdict "$b" CANNOT-RUN "$_why"
    else
        FAIL=$((FAIL + 1)); FAIL_LIST="$FAIL_LIST $b"
        # Same extraction as CANNOT-RUN above: probe_fail() prints its detail
        # last and exits, and several probes pass a multi-line $detail, so take
        # the tail from the marker and flatten it.
        _why="$(printf '%s\n' "$out" \
                | awk '/^VERDICT: FAIL -- /{sub(/^VERDICT: FAIL -- /, ""); f=1} f' \
                | tr '\n' ' ' | sed 's/  */ /g; s/ *$//')"
        # Blank is ANNOUNCED, never left empty: a probe that exits non-zero
        # without a 'VERDICT: FAIL --' line bypassed probe_fail and asserted
        # nothing, which is a contract breach, not a finding without a reason.
        [ -n "$_why" ] || _why="UNRECORDED -- exited ${rc} with no 'VERDICT: FAIL --' line, so it bypassed probe_fail and named no finding"
        printf '%s\t%s\n' "$b" "$_why" >> "$FAIL_REASONS"
        _record_verdict "$b" FAIL "$_why"
    fi
done

printf '\n'
# Every measurement is taken by here, so removing the synthetic person cannot
# change a verdict in THIS run. It never fails the walk.
grounding_seed_forget || true
preference_seed_forget || true
conversation_seed_forget || true
usage_seed_forget || true

# But post_walk_qa.sh replays probes against this box AFTER this script exits
# (the cut manifest's runtime proofs), and the compiled wiki still counts the
# rows just removed. v1.0.87: graph 1838, vectors 1838, tile 1839, two FAIL
# rows on a box with no defect. Recompile so the replay reads the box the
# probes read. Never fails the walk; see lib/wiki_summaries_wait.sh.
wiki_baseline_resync || true

# -------------------------------------------------------------------------
# REPORT -- four numbers, never one.
# -------------------------------------------------------------------------
printf '\n============================================================\n'
printf 'RESULT\n'
printf '  PASS        %s\n' "$PASS"
printf '  FAIL        %s\n' "$FAIL"
printf '  CANNOT-RUN  %s\n' "$CANNOT"
printf '  BROKEN      %s\n' "$BROKEN"
printf '  ----------------\n'
printf '  of          %s probes\n' "$PROBE_COUNT"
printf '============================================================\n'

if [ -n "$FAIL_LIST" ]; then
    printf '\nFAILED:\n'
    for b in $FAIL_LIST; do printf '  %s\n' "$b"; done

    # A SEPARATE BLOCK, FOR THE SAME TWO REASONS AS THE ONE UNDER NOT MEASURED.
    #
    # post_walk_qa.sh parses the list above with an awk that accepts only
    # `^  [A-Za-z0-9._-]+$` and EXITS on the first line that is not a bare
    # probe name. A reason printed under each name would end that parse at the
    # first one and walks/<version>.tsv would carry a single failed_probe row,
    # silently dropping the rest. The blank line printf'd below terminates the
    # parse before this block starts, and this header does not contain the
    # string section_names() keys on ("FAILED:").
    #
    # CONSOLE ONLY. probe_fail details interpolate ${OSTLER_BOX_HOST}, store
    # URLs, ~/.ostler/... paths and record counts. walks/ is committed to a
    # PUBLIC repo -- which is why box_fp is a hash and why the record carries
    # names and never probe output. These belong in front of the operator
    # running the walk, and nowhere else.
    printf '\nWHAT EACH FAILURE FOUND (console only -- never written to walks/):\n'
    while IFS="$(printf '\t')" read -r _b _why; do
        [ -n "$_b" ] || continue
        printf '  %s\n      %s\n' "$_b" "$_why"
    done < "$FAIL_REASONS"
fi

if [ -n "$CANNOT_LIST" ]; then
    printf '\nNOT MEASURED (prerequisite absent -- this is coverage lost, not a pass):\n'
    for b in $CANNOT_LIST; do printf '  %s\n' "$b"; done

    # A SEPARATE BLOCK, AND THAT IS DELIBERATE -- DO NOT FOLD IT INTO THE ONE
    # ABOVE.
    #
    # post_walk_qa.sh parses the block above with an awk that accepts only
    # `^  [A-Za-z0-9._-]+$` and EXITS on the first line that is not a bare
    # probe name. Printing a reason underneath each name would end that parse
    # at the first one, so walks/<version>.tsv would carry a single
    # not_measured_probe row and silently drop the rest -- the exact blindness
    # this estate exists to prevent, reintroduced by the fix for it. The blank
    # line printf'd below terminates that parse before this block begins, and
    # this header does not contain the string it keys on.
    #
    # CONSOLE ONLY. These strings interpolate ${OSTLER_BOX_HOST}, $LOG_PATH,
    # ~/.ostler/... and in one case raw transport stderr. walks/ is committed
    # to a PUBLIC repo -- which is why box_fp is a hash and why the record
    # carries names and never probe output. Measured across the 90
    # probe_cannot_run call sites in 21 of 21 probes: the reasons are
    # saturated with operator paths and private addresses. They belong in
    # front of the operator running the walk, and nowhere else.
    printf '\nPREREQUISITES THAT WERE ABSENT (console only -- never written to walks/):\n'
    while IFS="$(printf '\t')" read -r _b _why; do
        [ -n "$_b" ] || continue
        printf '  %s\n      %s\n' "$_b" "$_why"
    done < "$CANNOT_REASONS"
fi

if [ -n "$BROKEN_LIST" ]; then
    printf '\nBROKEN (probe could not demonstrate a FAIL, so its result is not trusted):\n'
    for b in $BROKEN_LIST; do printf '  %s\n' "$b"; done
fi

if [ "$FAIL" -eq 0 ] && [ "$BROKEN" -eq 0 ] && [ "$CANNOT" -gt 0 ]; then
    printf '\nNOTE: nothing failed, but %s of %s probes did not run.\n' "$CANNOT" "$PROBE_COUNT"
    printf 'This is NOT a clean box walk. It is a partial one. Fix the prerequisites and re-run.\n'
fi

if [ "$FAIL" -gt 0 ] || [ "$BROKEN" -gt 0 ]; then
    exit 1
fi
exit 0
