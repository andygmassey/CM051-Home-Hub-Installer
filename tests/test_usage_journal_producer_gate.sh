#!/usr/bin/env bash
# ============================================================================
# test_usage_journal_producer_gate.sh -- the mutation harness for the
# usage-journal producer gate. THE GATE IS NOT BELIEVED UNTIL IT HAS BEEN
# WATCHED GOING RED.
# ============================================================================
#
# WHAT IS UNDER TEST
#
#   scripts/verify_usage_journal_producers.py   the gate
#   scripts/usage_journal_producers.tsv         the roster (the denominator)
#   scripts/usage_journal_producer_floor.tsv    the pinned floor (anti-vacuity)
#   tests/fixtures/usage_journal/costs_full.jsonl
#                                               a synthetic journal carrying one
#                                               record from every REQUIRED
#                                               producer. Entirely constructed:
#                                               reserved-style uuids, no name,
#                                               no address, no real session.
#
# WHY A MUTATION HARNESS AND NOT AN ASSERTION SUITE
#
# A gate that has only ever been run over a healthy input has demonstrated
# nothing. Four release tags in this estate burnt on gates that had never been
# observed to produce a FAIL: a grep inside a container that never started, a
# test that skipped on a runner with no docker and reported SUCCESS, a function
# that returned 127 and was inverted into "refuse everything". Every one of them
# passed its own happy path.
#
# So every arm below MUTATES the input and requires a SPECIFIC exit code back.
# Arms 2, 2b and 3 are the ones that matter: they delete a producer's records
# from a journal that is otherwise complete, and require the gate to name the
# producer that went dark.
#
# THE ARM THAT IS THE WHOLE POINT
#
# Arm 3 is the golden case the gate exists to refuse: a journal holding ONLY
# CM044's records. It satisfies "at least one `enriching` record and at least
# one `ingesting` record"... no, it does not even satisfy that -- so arm 3b
# hands it a journal with one `enriching` and one `ingesting` record and FOUR
# dark producers, which passes the contract's own weaker predicate and must
# still be REFUSED here. A ">= 1 of each kind" gate is green on that input
# forever.
#
# THREE OUTCOMES, THREE CODES -- and the third is the one that gets collapsed
#
#   0  PASS
#   1  FAIL        records exist and a required producer has none
#   2  CANNOT-RUN  no journal, an empty journal, or a roster shrunk below its
#                  pinned floor. Nothing was measured. Not a pass, not a fail.
#
# This harness's OWN exit codes follow the same convention: 0 all arms behaved,
# 1 an arm did not, 2 the harness could not run.
#
# bash 3.2 compatible: macOS ships 3.2.57 and this also runs on ubuntu in CI.
# ============================================================================

set -uo pipefail

REPO_ROOT="${1:-}"
if [ -z "$REPO_ROOT" ]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

GATE="${REPO_ROOT}/scripts/verify_usage_journal_producers.py"
ROSTER="${REPO_ROOT}/scripts/usage_journal_producers.tsv"
FLOOR="${REPO_ROOT}/scripts/usage_journal_producer_floor.tsv"
FIXTURE="${REPO_ROOT}/tests/fixtures/usage_journal/costs_full.jsonl"

PASS=0
FAIL=0
pass()    { printf '  [pass] %s\n' "$1"; PASS=$((PASS + 1)); }
failure() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
cannot_run() { printf 'CANNOT-RUN: %s\n' "$*" >&2; exit 2; }

for f in "$GATE" "$ROSTER" "$FLOOR" "$FIXTURE"; do
    [ -f "$f" ] || cannot_run "missing $f. This harness drives the REAL gate over the REAL roster and refuses to run against a copy."
done
command -v python3 >/dev/null 2>&1 || cannot_run "no python3 on PATH; the gate could not be executed and nothing was measured"

echo "test_usage_journal_producer_gate.sh"
echo "gate    : ${GATE}"
echo "roster  : ${ROSTER}"
echo "fixture : ${FIXTURE}"
echo

W="$(mktemp -d -t ujpgate-XXXXXX)" || cannot_run "mktemp -d failed"
trap 'rm -rf "$W"' EXIT

# run_gate <journal> [roster] [floor]  -> sets RC and OUT
run_gate() {
    local journal="$1"
    local roster="${2:-$ROSTER}"
    local floor="${3:-$FLOOR}"
    OUT="$(python3 "$GATE" --journal "$journal" --roster "$roster" --floor "$floor" 2>&1)"
    RC=$?
}

# ---------------------------------------------------------------------------
# APPARATUS CONTROL, FIRST. A fixture that does not actually carry every
# required producer would make arm 1 pass for the wrong reason, and every
# deletion arm below would be deleting nothing.
#
# This is a CONTROL THAT MUST BE NON-ZERO: it counts the records the fixture
# holds and the required rows the roster declares, and refuses to continue if
# either is zero or if they disagree. "The fixture was complete" and "the
# predicate matched nothing so everything looked absent" must not print the
# same.
# ---------------------------------------------------------------------------
FIXTURE_LINES="$(/usr/bin/grep -c . "$FIXTURE")"
[ "${FIXTURE_LINES:-0}" -gt 0 ] || cannot_run "the fixture journal is empty; every arm would measure nothing"

REQUIRED_IDS="$(/usr/bin/grep -v '^#' "$ROSTER" | /usr/bin/grep -c '	required	')"
[ "${REQUIRED_IDS:-0}" -gt 0 ] || cannot_run "the roster declares no required producers; the gate would pass over nothing"
echo "  denominator: ${REQUIRED_IDS} required producers declared, ${FIXTURE_LINES} fixture records"
echo

# ---------------------------------------------------------------------------
# ARM 1: the complete journal must PASS (rc 0), and must report a NON-ZERO
# record count for every required producer by name. Without the second half,
# arm 1 could be satisfied by a gate whose matcher never fires and whose
# missing-list is therefore also empty.
# ---------------------------------------------------------------------------
run_gate "$FIXTURE"
if [ "$RC" -ne 0 ]; then
    failure "(1) the complete journal did not PASS: rc=${RC}"
    printf '%s\n' "$OUT" | sed 's/^/         /'
else
    MISCOUNTED=""
    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        row="$(printf '%s\n' "$OUT" | /usr/bin/grep -E "^${pid} " )"
        n="$(printf '%s' "$row" | awk '{print $NF}')"
        case "${n:-}" in
            ''|*[!0-9]*) MISCOUNTED="${MISCOUNTED} ${pid}=<no row>" ;;
            0)           MISCOUNTED="${MISCOUNTED} ${pid}=0" ;;
        esac
    done <<EOF
$(/usr/bin/grep -v '^#' "$ROSTER" | /usr/bin/grep '	required	' | cut -f1)
EOF
    if [ -n "$MISCOUNTED" ]; then
        failure "(1) PASS was reported but these required producers matched no record:${MISCOUNTED}. A gate whose matcher never fires has an empty missing-list too."
    else
        pass "(1) the complete journal PASSes, and every one of the ${REQUIRED_IDS} required producers matched at least one record"
    fi
fi

# ---------------------------------------------------------------------------
# ARM 2: DELETE ONE PRODUCER'S RECORDS. Must be rc 1 and must NAME it.
# Run for two DIFFERENT producers, matched by the two DIFFERENT match kinds,
# so the red cannot be an artefact of one roster row or one matcher.
# ---------------------------------------------------------------------------
delete_and_expect_fail() {
    # delete_and_expect_fail <arm-label> <grep-pattern-to-remove> <producer_id>
    local label="$1" pattern="$2" pid="$3"
    local jf="${W}/${pid}.jsonl"
    /usr/bin/grep -v "$pattern" "$FIXTURE" > "$jf"
    local before after
    before="$(/usr/bin/grep -c . "$FIXTURE")"
    after="$(/usr/bin/grep -c . "$jf")"
    # THE MUTATION MUST ACTUALLY HAVE HAPPENED. A grep that removed nothing
    # would leave a complete journal, the gate would correctly PASS, and this
    # arm would report a broken gate. Wrong subject, confident verdict.
    if [ "$after" -ge "$before" ]; then
        failure "(${label}) MUTATION DID NOT APPLY: pattern '${pattern}' removed 0 of ${before} lines, so nothing was deleted and this arm tested nothing"
        return
    fi
    run_gate "$jf"
    if [ "$RC" -ne 1 ]; then
        failure "(${label}) deleting ${pid}'s records returned rc=${RC}, expected 1 (FAIL). $( [ "$RC" -eq 0 ] && printf 'A missing producer scored as a pass.' )"
        printf '%s\n' "$OUT" | sed 's/^/         /'
        return
    fi
    if ! printf '%s\n' "$OUT" | /usr/bin/grep -q "MISSING  ${pid}"; then
        failure "(${label}) rc=1 but the output does not NAME ${pid}. A red that does not say what went dark is a red nobody can act on."
        printf '%s\n' "$OUT" | sed 's/^/         /'
        return
    fi
    pass "(${label}) deleting ${pid}'s records (${before} -> ${after} lines) returns FAIL naming it"
}

delete_and_expect_fail 2  'cm048-extract'      cm048_conversation_extract
delete_and_expect_fail 2b '"purpose": "answering"' oa_daemon_chat

# ---------------------------------------------------------------------------
# ARM 3: THE GOLDEN CASE THIS GATE EXISTS TO REFUSE.
#
# 3a: only CM044 wrote. Four required producers dark.
# 3b: one `enriching` record and one `ingesting` record -- which SATISFIES the
#     contract's own weaker gate paragraph verbatim -- and THREE required
#     producers still dark. This is the input that separates a per-producer
#     predicate from a per-kind one, and it is the reason this row exists.
# ---------------------------------------------------------------------------
/usr/bin/grep 'cm044-compile-' "$FIXTURE" > "${W}/only_cm044.jsonl"
run_gate "${W}/only_cm044.jsonl"
if [ "$RC" -eq 1 ]; then
    pass "(3a) a journal holding ONLY CM044's records is a FAIL, not a pass"
else
    failure "(3a) only-CM044 returned rc=${RC}, expected 1"
fi

/usr/bin/grep -E 'cm044-compile-|ostler-fda-ingest-' "$FIXTURE" > "${W}/one_of_each_kind.jsonl"
KINDS_LINES="$(/usr/bin/grep -c . "${W}/one_of_each_kind.jsonl")"
if [ "${KINDS_LINES:-0}" -lt 2 ]; then
    failure "(3b) the >=1-of-each-kind journal has ${KINDS_LINES} lines; it cannot carry both an enriching and an ingesting record, so this arm tests nothing"
else
    run_gate "${W}/one_of_each_kind.jsonl"
    if [ "$RC" -eq 1 ] \
       && printf '%s\n' "$OUT" | /usr/bin/grep -q 'MISSING  cm048_conversation_extract' \
       && printf '%s\n' "$OUT" | /usr/bin/grep -q 'MISSING  cm041_identity_resolution'; then
        pass "(3b) a journal with one enriching + one ingesting record -- which passes the contract's own '>= 1 of each kind' wording -- is REFUSED, naming the three dark producers"
    else
        failure "(3b) the >=1-of-each-kind journal returned rc=${RC} without naming both dark enriching producers. That predicate is a golden case and must not pass."
        printf '%s\n' "$OUT" | sed 's/^/         /'
    fi
fi

# ---------------------------------------------------------------------------
# ARM 4: NO JOURNAL AT ALL -> rc 2, CANNOT-RUN. Never 1, never 0.
#
# This is the distinction the whole row turns on. An absent journal means no
# producer has ever written, which is what a box looks like before its first
# compile. Reporting that as FAIL trains an operator to ignore a red that fires
# before they have done the thing being measured; reporting it as PASS is
# worse. It gets its own code.
# ---------------------------------------------------------------------------
ABSENT="${W}/there_is_no_journal_here.jsonl"
[ -e "$ABSENT" ] && cannot_run "the 'absent' path exists, so arm 4 would not test absence"
run_gate "$ABSENT"
if [ "$RC" -eq 2 ] && printf '%s\n' "$OUT" | /usr/bin/grep -q 'CANNOT-RUN'; then
    pass "(4) an ABSENT journal is CANNOT-RUN (rc 2), not FAIL and not PASS"
else
    failure "(4) an absent journal returned rc=${RC}, expected 2. CANNOT-RUN collapsed into $( [ "$RC" -eq 0 ] && echo PASS || echo FAIL )."
    printf '%s\n' "$OUT" | sed 's/^/         /'
fi

# ---------------------------------------------------------------------------
# ARM 5: an EMPTY journal -> rc 2. The file exists, so a naive `-f` check would
# proceed and then find every producer absent, which would read as five
# regressions on a box that has simply not compiled yet.
# ---------------------------------------------------------------------------
: > "${W}/empty.jsonl"
run_gate "${W}/empty.jsonl"
if [ "$RC" -eq 2 ]; then
    pass "(5) an EMPTY journal is CANNOT-RUN (rc 2), not five simultaneous producer regressions"
else
    failure "(5) an empty journal returned rc=${RC}, expected 2"
    printf '%s\n' "$OUT" | sed 's/^/         /'
fi

# ---------------------------------------------------------------------------
# ARM 6: a journal whose every line is unparseable -> rc 2. Zero records
# parsed is zero evidence about any producer, and it must not be reported as
# five absences.
# ---------------------------------------------------------------------------
printf 'not json\n{"truncated": \n' > "${W}/garbage.jsonl"
run_gate "${W}/garbage.jsonl"
if [ "$RC" -eq 2 ]; then
    pass "(6) a journal where nothing parses is CANNOT-RUN (rc 2): zero records is zero evidence"
else
    failure "(6) an unparseable journal returned rc=${RC}, expected 2"
    printf '%s\n' "$OUT" | sed 's/^/         /'
fi

# ---------------------------------------------------------------------------
# ARM 7: ANTI-VACUITY. A gate that inspects nothing is green in exactly the way
# a gate that inspects everything is. Shrink the roster to ONE producer, leave
# the pinned floor alone, and hand it the complete journal: the gate must
# REFUSE (rc 2) rather than report a pass over a denominator of one.
#
# Note the shape of the mutation: the journal is COMPLETE, so a gate that only
# looked at the journal would return 0 here. The red has to come from the floor.
# ---------------------------------------------------------------------------
/usr/bin/grep '^cm044_wiki_compiler	' "$ROSTER" > "${W}/roster_shrunk.tsv"
SHRUNK_ROWS="$(/usr/bin/grep -c . "${W}/roster_shrunk.tsv")"
if [ "${SHRUNK_ROWS:-0}" -ne 1 ]; then
    failure "(7) the shrunk roster has ${SHRUNK_ROWS} rows, expected 1; the mutation did not apply and this arm tests nothing"
else
    run_gate "$FIXTURE" "${W}/roster_shrunk.tsv"
    if [ "$RC" -eq 2 ] && printf '%s\n' "$OUT" | /usr/bin/grep -q 'SHRUNK BELOW ITS PINNED FLOOR'; then
        pass "(7) ANTI-VACUITY: a roster cut from ${REQUIRED_IDS} required rows to 1, over a COMPLETE journal, is refused as CANNOT-RUN"
    else
        failure "(7) ANTI-VACUITY BROKEN: a one-row roster over a complete journal returned rc=${RC}. Deleting the dark producers would turn this gate green in one edit."
        printf '%s\n' "$OUT" | sed 's/^/         /'
    fi
fi

# ---------------------------------------------------------------------------
# ARM 8: the pinned floor itself goes missing -> rc 2. Without it the roster is
# unconstrained, so a gate that carried on would be measuring whatever the
# roster happened to say that day.
# ---------------------------------------------------------------------------
run_gate "$FIXTURE" "$ROSTER" "${W}/there_is_no_floor_file.tsv"
if [ "$RC" -eq 2 ]; then
    pass "(8) an absent pinned floor is CANNOT-RUN (rc 2): an unconstrained roster is not a denominator"
else
    failure "(8) an absent floor file returned rc=${RC}, expected 2"
    printf '%s\n' "$OUT" | sed 's/^/         /'
fi

# ---------------------------------------------------------------------------
# ARM 9: an UNKNOWN purpose string must be loud. The daemon REJECTS an unknown
# purpose rather than coercing it, so `"enrichment"` is not `"enriching"` and
# those records are lost on the read side -- the panel's total goes quietly
# short, which is the same flattering-direction error this gate is for.
# ---------------------------------------------------------------------------
sed 's/"purpose": "enriching"/"purpose": "enrichment"/' "$FIXTURE" > "${W}/typo.jsonl"
if ! /usr/bin/grep -q '"enrichment"' "${W}/typo.jsonl"; then
    failure "(9) the typo mutation did not apply; this arm tests nothing"
else
    run_gate "${W}/typo.jsonl"
    if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | /usr/bin/grep -q "enrichment"; then
        pass "(9) a purpose the contract does not define is a FAIL naming the string"
    else
        failure "(9) an unknown purpose returned rc=${RC}, expected 1 naming it"
        printf '%s\n' "$OUT" | sed 's/^/         /'
    fi
fi

# ---------------------------------------------------------------------------
# ARM 10: a DORMANT producer that starts writing is a NOTE, not a fault. The
# contract declares oa `noticing` and says in the same breath that it "has none
# today". A gate that demanded it would demand a record that cannot exist, and
# a gate that can never pass gets switched off.
#
# This is also the arm that stops arms 2-9 from being satisfied by a gate that
# fails unconditionally.
# ---------------------------------------------------------------------------
cp "$FIXTURE" "${W}/with_dormant.jsonl"
printf '%s\n' '{"id": "e5b02a48-1f93-4c7d-b6e0-8a24d1f70c95", "session_id": "6f28e1b4-0a37-4d92-8b15-3c7f9e0a2d64", "usage": {"model": "gemma4:e2b", "input_tokens": 430, "output_tokens": 97, "total_tokens": 527, "cost_usd": 0.0, "timestamp": "2026-08-25T10:15:44Z", "purpose": "noticing"}}' >> "${W}/with_dormant.jsonl"
run_gate "${W}/with_dormant.jsonl"
if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | /usr/bin/grep -q 'dormant producer is now writing'; then
    pass "(10) a dormant producer that starts writing PASSes with a note to promote it, rather than failing"
else
    failure "(10) a writing dormant producer returned rc=${RC}, expected 0 with a promotion note"
    printf '%s\n' "$OUT" | sed 's/^/         /'
fi

# ---------------------------------------------------------------------------
# ARM 11: THE PATH RESOLVER. The journal path is resolved, never hardcoded --
# `~/.ostler/assistant-config/workspace/state/costs.jsonl` is right on a
# customer install and nowhere else. A reader pointed at a directory the
# producers do not write to finds an absent file, and CANNOT-RUN forever is
# how a gate ends up dark without ever being deleted.
#
# Each of the four branches is pinned against the table in the contract.
# ---------------------------------------------------------------------------
resolved_with() {
    # resolved_with <env assignments...> -- prints the resolved path
    env "$@" python3 "$GATE" --print-journal-path 2>&1
}
FAKE_HOME="${W}/home"
mkdir -p "${FAKE_HOME}/.ostler"

R1="$(resolved_with "HOME=${FAKE_HOME}" "ZEROCLAW_CONFIG_DIR=${W}/cfg")"
R2="$(resolved_with "HOME=${FAKE_HOME}" "OSTLER_WORKSPACE=${W}/ws/workspace")"
R4="$(resolved_with "HOME=${FAKE_HOME}")"
# Branch 2's subtle arm: a CONFIG dir handed to a WORKSPACE variable. The
# daemon sees the config.toml beside it and appends `workspace`. Getting this
# wrong writes the journal to a directory nothing reads.
mkdir -p "${W}/assistant-config"
: > "${W}/assistant-config/config.toml"
R2B="$(resolved_with "HOME=${FAKE_HOME}" "ZEROCLAW_WORKSPACE=${W}/assistant-config")"
# Branch 3: the ~/.ostler/active_workspace.toml marker. Exercised with a
# SEPARATE fake home, so writing the marker cannot change what branch 4 (the
# no-marker default) resolves to -- a control that destroys the surface the
# next control measures is not a control.
MARKER_HOME="${W}/home_with_marker"
mkdir -p "${MARKER_HOME}/.ostler"
printf 'config_dir = "%s/elsewhere"\n' "$W" > "${MARKER_HOME}/.ostler/active_workspace.toml"
R3="$(resolved_with "HOME=${MARKER_HOME}")"

RESOLVER_BAD=""
[ "$R1"  = "${W}/cfg/workspace/state/costs.jsonl" ]                  || RESOLVER_BAD="${RESOLVER_BAD} branch1(ZEROCLAW_CONFIG_DIR)=${R1}"
[ "$R2"  = "${W}/ws/workspace/state/costs.jsonl" ]                   || RESOLVER_BAD="${RESOLVER_BAD} branch2(dir-named-workspace,used-as-is)=${R2}"
[ "$R2B" = "${W}/assistant-config/workspace/state/costs.jsonl" ]     || RESOLVER_BAD="${RESOLVER_BAD} branch2b(config-dir,append-workspace)=${R2B}"
[ "$R3"  = "${W}/elsewhere/workspace/state/costs.jsonl" ]            || RESOLVER_BAD="${RESOLVER_BAD} branch3(active_workspace.toml-marker)=${R3}"
[ "$R4"  = "${FAKE_HOME}/.ostler/workspace/state/costs.jsonl" ]      || RESOLVER_BAD="${RESOLVER_BAD} branch4(default)=${R4}"
# CONTROL: branch 3 and branch 4 must NOT resolve to the same place. If the
# marker were being ignored they would both land on <home>/.ostler/workspace
# and every equality above could still hold for the wrong reason.
[ "$R3" != "$R4" ] || RESOLVER_BAD="${RESOLVER_BAD} branch3==branch4(the marker was ignored)"
if [ -z "$RESOLVER_BAD" ]; then
    pass "(11) all FIVE journal-path arms resolve as the contract documents -- the two env branches, the config-dir-in-a-workspace-variable arm the installer actually uses, the active_workspace.toml marker, and the default"
else
    failure "(11) the resolver disagrees with the contract:${RESOLVER_BAD}"
fi

# ---------------------------------------------------------------------------
# ARM 12: TWO RESOLVERS, ONE ANSWER.
#
# The box-walk probe resolves the journal path in SHELL, because on a remote
# walk the env that decides the answer belongs to the box and the box has no
# repo checkout. The gate resolves it in PYTHON. Two implementations of one
# rule drift, and the drift is silent in the worst direction: the reader finds
# an absent file and reports CANNOT-RUN forever while the producers write
# happily somewhere else. So they are pinned against each other here, on the
# same host, over the same four branches.
#
# If the probe is absent this arm goes RED rather than skipping. "The resolvers
# agree" and "there was only one resolver to ask" must not print the same.
# ---------------------------------------------------------------------------
PROBE="${REPO_ROOT}/scripts/box_walk_probes/probes/usage_journal_producers.sh"
if [ ! -f "$PROBE" ]; then
    failure "(12) the box-walk probe is missing at ${PROBE}, so the shell resolver was not compared against the gate's. Nothing on a real box invokes this gate."
else
    shell_resolved_with() {
        env "$@" USAGE_JOURNAL_PROBE_LOCAL=1 bash "$PROBE" --print-journal-path 2>&1
    }
    S1="$(shell_resolved_with "HOME=${FAKE_HOME}" "ZEROCLAW_CONFIG_DIR=${W}/cfg")"
    S2="$(shell_resolved_with "HOME=${FAKE_HOME}" "OSTLER_WORKSPACE=${W}/ws/workspace")"
    S2B="$(shell_resolved_with "HOME=${FAKE_HOME}" "ZEROCLAW_WORKSPACE=${W}/assistant-config")"
    S3="$(shell_resolved_with "HOME=${MARKER_HOME}")"
    S4="$(shell_resolved_with "HOME=${FAKE_HOME}")"
    DRIFT=""
    [ "$S1"  = "$R1"  ] || DRIFT="${DRIFT} branch1(shell=${S1} python=${R1})"
    [ "$S2"  = "$R2"  ] || DRIFT="${DRIFT} branch2(shell=${S2} python=${R2})"
    [ "$S2B" = "$R2B" ] || DRIFT="${DRIFT} branch2b(shell=${S2B} python=${R2B})"
    [ "$S3"  = "$R3"  ] || DRIFT="${DRIFT} branch3(shell=${S3} python=${R3})"
    [ "$S4"  = "$R4"  ] || DRIFT="${DRIFT} branch4(shell=${S4} python=${R4})"
    if [ -z "$DRIFT" ]; then
        pass "(12) the probe's shell resolver and the gate's python resolver agree on all five arms, marker branch included"
    else
        failure "(12) THE TWO RESOLVERS DISAGREE:${DRIFT}. A reader and a writer pointed at different files measure nothing."
    fi
fi

# ---------------------------------------------------------------------------
# ARM 13: THE PROBE'S OWN NEGATIVE CONTROL MUST FIRE.
#
# #713/#719 in this repo: every box_walk_probe manifest row returned SKIP for
# its entire life, and nothing invoked run_box_walk.sh at all. A probe that has
# never demonstrated a FAIL is indistinguishable from `echo TODO; exit 0`, and
# run_box_walk's phase 1 discards any probe whose --self-test does not come
# back rc 1 with no "VERDICT: BROKEN" in its output. Both conditions are
# checked here, because the runner checks both -- reading the exit code alone
# is how a probe that reported a verdict with no denominator once passed
# phase 1.
# ---------------------------------------------------------------------------
if [ -f "$PROBE" ]; then
    ST_OUT="$(bash "$PROBE" --self-test 2>&1)"; ST_RC=$?
    if [ "$ST_RC" -eq 1 ] && ! printf '%s\n' "$ST_OUT" | /usr/bin/grep -q 'VERDICT: BROKEN'; then
        pass "(13) the box-walk probe's negative control fires: --self-test exits 1 with no BROKEN verdict, so run_box_walk phase 1 will trust its measurement"
    else
        failure "(13) the probe's --self-test exited ${ST_RC}$(printf '%s\n' "$ST_OUT" | /usr/bin/grep -q 'VERDICT: BROKEN' && printf ' and printed VERDICT: BROKEN'). run_box_walk would mark it BROKEN and DISCARD its result on every walk."
        printf '%s\n' "$ST_OUT" | sed 's/^/         /'
    fi
fi

echo
echo "=== ${PASS} passed / ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
