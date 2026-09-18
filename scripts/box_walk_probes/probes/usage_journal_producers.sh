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

# "override" when the operator named the file with OSTLER_USAGE_JOURNAL,
# "resolver" when the four branches above chose it on the box. The staging
# refusal below applies to the SECOND only -- see why there.
#
# ⚠️ COMPUTED HERE, NOT INSIDE resolve_journal. `x="$(resolve_journal)"` runs
# the function in a SUBSHELL, so a variable the function assigns is gone by the
# time the caller reads it -- it stays at its initial value and the guard below
# silently never fires. Measured: the first version of this change did exactly
# that, and arm 13 of the self-test is what caught it.
journal_resolved_by() {
    if [ -n "${OSTLER_USAGE_JOURNAL:-}" ]; then
        printf 'override\n'
    else
        printf 'resolver\n'
    fi
}

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

# ---------------------------------------------------------------------------
# A LEFTOVER STAGING TREE IS NOT THE BOX (#1774). Returns 0 when the path lies
# in one, so the caller can REFUSE.
#
# MEASURED, v1.0.74 box: the only costs.jsonl on a fully installed machine was
#     /tmp/ostler-prelaunch-69112/assistant-config/workspace/state/costs.jsonl
# 8481 bytes, a separate inode -- not a symlink or hardlink to the live path.
# The probe resolved it and adjudicated the box against a file the running
# daemon does not write to. That verdict could neither confirm nor deny
# oa_daemon_chat, and it was reported as a FAIL. The v1.0.79 box did the same
# thing with 346 journal lines.
#
# The CAUSE is fixed at the installer: ${HOME}/.ostler/active_workspace.toml
# captures OSTLER_DIR at write time, so it held the staging prefix until
# _ostler_write_workspace_marker was made to run again after the promote
# (install.sh, and tests/test_the_workspace_marker_survives_the_promote.sh
# asserts behaviourally that the promoted marker names a path that EXISTS with
# no staging prefix). This is the OTHER half, and it belongs here rather than
# there: the reader must refuse a staging path whatever wrote it, because the
# marker is not the only way to reach one and a reader that adjudicates a
# stale tree turns it into evidence.
#
# THE PREFIX IS MEASURED, NOT GUESSED: install.sh sets
#     OSTLER_PRELAUNCH_DIR="${OSTLER_PRELAUNCH_DIR:-/tmp/ostler-prelaunch-$$}"
# and the temp roots are refused with it because the OS clears them on boot --
# a journal there can never be the live one, whoever named it.
#
# REFUSED, NEVER FAILED: a staging path means the probe did not find the live
# journal, which is coverage lost. Calling it a FAIL accuses the producers of
# a silence the probe never looked for.
journal_path_is_staging() {
    case "$1" in
        */ostler-prelaunch-*|/tmp/*|/private/tmp/*|/var/folders/*) return 0 ;;
    esac
    return 1
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

# compile_evidence -> "<settling_files> <present|none>"
#
# WHY. The absent-journal branch used to say the absence "is what a box looks
# like BEFORE its first compile". That is an INFERENCE, and this probe never
# checked it. Measured 2026-08-27 on a box where it was false: the wiki footer
# read "Last compiled: 2026-08-26 08:08", settling_progress.d carried
# updated_at 2026-08-27T05:18:04Z across 186,693 messages, and the journal did
# not exist. Nine declared producers, zero records, and the probe handed the
# reader a reason to move on.
#
# A benign explanation for a real absence is worse than no explanation, because
# it is acted on. So the two cases are now distinguished by evidence rather than
# assumed: has this box done work that a producer should have journalled?
#
# Deliberately cheap and read-only -- a file count and an existence check. It is
# not proof that a FULL compile ran, and the verdict text says which signals it
# used so the claim can be argued with rather than merely believed.
compile_evidence() {
    # Default "0 none" -- the FRESH-BOX reading. If the fake is ever unset by
    # accident the probe falls back to CANNOT-RUN, never to a manufactured FAIL.
    if [ "${SELF_TEST_LOCAL:-0}" -eq 1 ] || [ "${USAGE_JOURNAL_PROBE_LOCAL:-0}" -eq 1 ]; then
        printf '%s' "${FAKE_COMPILE_EVIDENCE:-0 none}"; return
    fi
    box_run "python3 - <<'OSTLERUJEV'
import glob, os
d = os.path.expanduser('~/.ostler/state/settling_progress.d')
n = len(glob.glob(os.path.join(d, '*.json')))
w = os.path.expanduser('~/Documents/Ostler/Wiki/index.md')
print(str(n) + ' ' + ('present' if os.path.exists(w) else 'none'))
OSTLERUJEV"
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

    # #1774. The refusal applies to a path THIS PROBE RESOLVED, not to one an
    # operator named with OSTLER_USAGE_JOURNAL. The defect was the resolver
    # silently landing on a leftover staging tree; an explicit --journal-style
    # override is a person saying "adjudicate exactly this file", and refusing
    # that would also make this probe's own fixture arms unrunnable, which is
    # how a guard gets deleted rather than fixed.
    if [ "$(journal_resolved_by)" = "resolver" ] && journal_path_is_staging "$journal_path"; then
        probe_examined 0 "journal records (the resolver landed in a staging tree, so nothing on this box was adjudicated)"
        probe_cannot_run "the journal resolved to ${journal_path} on ${OSTLER_BOX_HOST:-this machine}, which is a STAGING path, not the live tree. The installer stages into /tmp/ostler-prelaunch-<pid> (install.sh OSTLER_PRELAUNCH_DIR) and the OS clears that on boot, so the running daemon does not write there. Adjudicating a box against a leftover staging directory is how a stale tree becomes evidence -- it did exactly that on the v1.0.74 and v1.0.79 boxes. Nothing was measured about any producer. Coverage lost, NOT a pass and NOT a producer failure. Fix the workspace marker (\${HOME}/.ostler/active_workspace.toml) or the daemon's ZEROCLAW_CONFIG_DIR, then re-walk."
    fi

    local raw work
    raw="$(fetch_journal "$journal_path")"
    work="$(mktemp -t ujprobe-XXXXXX)" || probe_cannot_run "mktemp failed on this machine; the journal could not be staged for adjudication"

    case "$raw" in
        ABSENT*)
            rm -f "$work"
            probe_examined 0 "journal records (the file does not exist on the box)"
            _ev="$(compile_evidence)"
            _nset="${_ev%% *}"; _wiki="${_ev##* }"
            case "${_nset}" in ''|*[!0-9]*) _nset=0 ;; esac
            if [ "${_nset}" -gt 0 ] || [ "${_wiki}" = "present" ]; then
                probe_fail "no journal at ${journal_path} on ${OSTLER_BOX_HOST:-this machine}, and this box has demonstrably done the work: ${_nset} settling_progress.d source file(s), compiled wiki ${_wiki}. Every one of the declared producers owed a record and NONE has written one -- the directory they write into does not exist. This is not a fresh box; it is a journal nothing feeds, and the figure a paying customer is shown is compiled from it. Signals used: settling_progress.d file count and the presence of the compiled wiki index; neither proves a FULL compile ran, so argue with them if they are wrong."
            fi
            probe_cannot_run "no journal at ${journal_path} on ${OSTLER_BOX_HOST:-this machine}, and this box shows no sign of having done work yet (${_nset} settling_progress.d file(s), compiled wiki ${_wiki}). With nothing ingested and nothing compiled there is nothing a producer should have written, so this probe has NO opinion. Run a full compile, then re-run."
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

    # ── PER-PRODUCER OPPORTUNITY, DECLARED, NOT PATTERN-MATCHED (#1634) ──
    #
    # THIS USED TO BE A GLOB ON THE GATE'S PROSE. The rc=1 branch matched
    # "VERDICT: FAIL -- 1 of ", "REQUIRED producers wrote nothing" and one
    # producer name, and turned that exact shape into a refusal. Three things
    # were wrong with it and only the third was ever written down: it covered
    # cm044 alone; it read a verdict SENTENCE as an interface, so rewording the
    # gate silently deleted the refusal; and the gate itself still had only TWO
    # states for a zero, so every other producer's "nobody asked it" was
    # reported as "it broke".
    #
    # Opportunity is now DECLARED to the gate with --no-opportunity, which the
    # gate validates against the roster and reports as CANNOT-RUN -- never as a
    # PASS, and never in place of a FAIL on a producer nobody excused. See the
    # gate's own "#1634" section.
    #
    # EVERY SIGNAL BELOW IS ONE THE WALK MEASURED, not one this probe guessed.
    # A signal that is absent or unparseable excuses NOTHING: the producer keeps
    # its FAIL, because unknown is not the same as no-opportunity and the safe
    # direction is the loud one.
    local -a OPP_ARGS
    OPP_ARGS=()
    local excuse_note=""

    # cm044_wiki_compiler: its only writer is the wiki summary backfill, which
    # queues for the one shared Ollama slot. run_box_walk.sh waits for it twice
    # and hands over the wait's final state. cannot-run means the walk WATCHED
    # the backfill not run inside the budget -- a precondition the walk saw
    # unmet is not a measurement of the producer.
    if [ "${OSTLER_WIKI_WAIT_STATE:-}" = "cannot-run" ]; then
        OPP_ARGS[${#OPP_ARGS[@]}]="--no-opportunity"
        OPP_ARGS[${#OPP_ARGS[@]}]="cm044_wiki_compiler"
        excuse_note="${excuse_note} The walk measured that cm044_wiki_compiler had no opportunity: its summary backfill did not converge (${OSTLER_WIKI_WAIT_DETAIL:-no detail})."
    fi

    # oa_daemon_chat: matched on purpose=answering, which the daemon writes when
    # somebody sends it a message. run_box_walk.sh exports the number of
    # questions assistant_answers_grounded actually asked over /ws/chat, which
    # is the opportunity signal for this row and already runs in the same walk.
    # ZERO asked, and provably zero, is no opportunity. Anything else -- a
    # non-number, an empty value, an unset variable -- is UNKNOWN and excuses
    # nothing.
    case "${OSTLER_ASSISTANT_ASKED:-}" in
        ''|*[!0-9]*) : ;;
        0)
            OPP_ARGS[${#OPP_ARGS[@]}]="--no-opportunity"
            OPP_ARGS[${#OPP_ARGS[@]}]="oa_daemon_chat"
            excuse_note="${excuse_note} The walk measured that oa_daemon_chat had no opportunity: assistant_answers_grounded asked the daemon 0 questions over /ws/chat."
            ;;
        *) : ;;
    esac

    [ "${#OPP_ARGS[@]}" -eq 0 ] || probe_note "no-opportunity declared:${excuse_note}"

    local out rc
    out="$(python3 "$GATE" --journal "$work" --roster "$ROSTER" --floor "$FLOOR" ${OPP_ARGS[@]+"${OPP_ARGS[@]}"} 2>&1)"
    rc=$?
    rm -f "$work"
    printf '%s\n' "$out" | sed 's/^/  /'

    case "$rc" in
        0) probe_pass "every required producer in ${ROSTER} wrote into ${journal_path} (${lines} lines read)" ;;
        1) probe_fail "a declared producer wrote NOTHING into ${journal_path}. See the gate output above for which one; the cost panel is short by exactly that producer's work." ;;
        2) probe_cannot_run "the gate could not measure ${journal_path}: see its CANNOT-RUN line above.${excuse_note} Coverage lost, not a pass." ;;
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
    out="$(USAGE_JOURNAL_PROBE_LOCAL=1 FAKE_COMPILE_EVIDENCE="0 none" \
           OSTLER_USAGE_JOURNAL="${TMPDIR:-/tmp}/ujprobe-there-is-no-journal-$$.jsonl" \
           bash "${BASH_SOURCE[0]}" 2>&1)"; rc=$?
    if [ "$rc" -ne 78 ]; then
        printf 'SELF-TEST ARM 3 BROKEN: an absent journal on an UNWORKED box returned rc=%s, expected 78 (CANNOT-RUN)\n' "$rc"
        printf '%s\n' "$out" | sed 's/^/    /'
        fails=$((fails + 1))
    else
        printf 'arm 3 OK: an absent journal on a box that has done nothing is CANNOT-RUN, not five regressions\n'
    fi

    # ARM 4: the same absent journal on a box that HAS done the work is a FAIL.
    #
    # Arm 3 exists so a fresh box does not read as five simultaneous
    # regressions. It does not follow that an absent journal is unmeasurable.
    # When the box has ingested and compiled, every declared producer owed a
    # record and none wrote one -- the denominator comes from the contract, not
    # from the file, so that is a measured zero, not an unanswerable question.
    #
    # Measured 2026-08-27: the old branch called this "what a box looks like
    # BEFORE its first compile" on a box whose wiki footer read "Last compiled:
    # 2026-08-26 08:08" and whose settling state had been updated that morning
    # across 186,693 messages. A benign explanation for a real absence is worse
    # than none, because it gets acted on. See #1141.
    out="$(USAGE_JOURNAL_PROBE_LOCAL=1 FAKE_COMPILE_EVIDENCE="4 present" \
           OSTLER_USAGE_JOURNAL="${TMPDIR:-/tmp}/ujprobe-there-is-no-journal-worked-$$.jsonl" \
           bash "${BASH_SOURCE[0]}" 2>&1)"; rc=$?
    if [ "$rc" -ne 1 ]; then
        printf 'SELF-TEST ARM 4 BROKEN: an absent journal on a WORKED box returned rc=%s, expected 1 (FAIL)\n' "$rc"
        printf '%s\n' "$out" | sed 's/^/    /'
        fails=$((fails + 1))
    else
        printf 'arm 4 OK: an absent journal on a box that HAS worked is FAIL, not a shrug\n'
    fi

    # ARM 6: cm044 rows deleted AND the walk's wait ended cannot-run -> CANNOT-RUN (78),
    # naming the producer and carrying the wait's detail. The walk saw the producer
    # had not run; that is not a measurement of it.
    tmp6="$(mktemp -t ujprobeself-XXXXXX)"
    grep -v 'cm044-compile-' "$fixture" > "$tmp6"
    if [ "$(grep -c . "$tmp6")" -ge "$(grep -c . "$fixture")" ]; then
        printf 'SELF-TEST ARM 6 BROKEN: the cm044 mutation removed nothing\n'; fails=$((fails + 1))
    else
        out="$(USAGE_JOURNAL_PROBE_LOCAL=1 OSTLER_USAGE_JOURNAL="$tmp6" OSTLER_WIKI_WAIT_STATE=cannot-run \
               OSTLER_WIKI_WAIT_DETAIL="fixture: the backfill never got the slot" bash "${BASH_SOURCE[0]}" 2>&1)"; rc=$?
        if [ "$rc" -ne 78 ] || ! grep -q 'never got the slot' <<< "$out"; then
            printf 'SELF-TEST ARM 6 BROKEN: cm044 absent with the wait cannot-run returned rc=%s, expected 78 carrying the wait detail\n' "$rc"
            printf '%s\n' "$out" | sed 's/^/    /'; fails=$((fails + 1))
        else
            printf 'arm 6 OK: cm044 absent when the walk saw its backfill never ran is CANNOT-RUN, with the wait detail\n'
        fi
        # ARM 7 (CONTROL): the SAME journal with the wait converged is still a FAIL naming cm044:
        # the refusal is keyed on the wait state, not on the producer name alone.
        out="$(USAGE_JOURNAL_PROBE_LOCAL=1 OSTLER_USAGE_JOURNAL="$tmp6" OSTLER_WIKI_WAIT_STATE=converged \
               bash "${BASH_SOURCE[0]}" 2>&1)"; rc=$?
        if [ "$rc" -ne 1 ] || ! grep -q 'cm044_wiki_compiler' <<< "$out"; then
            printf 'SELF-TEST ARM 7 BROKEN: cm044 absent with the wait CONVERGED returned rc=%s, expected 1 naming it\n' "$rc"; fails=$((fails + 1))
        else
            printf 'arm 7 OK: cm044 absent after a converged wait is a FAIL, so arm 6 measures the wait state\n'
        fi
    fi
    rm -f "$tmp6"
    # ARM 8 (CONTROL): a DIFFERENT producer absent with the wait cannot-run stays a FAIL:
    # the wait vouches for the wiki producer only.
    tmp8="$(mktemp -t ujprobeself-XXXXXX)"
    grep -v 'ostler-fda-ingest-' "$fixture" > "$tmp8"
    out="$(USAGE_JOURNAL_PROBE_LOCAL=1 OSTLER_USAGE_JOURNAL="$tmp8" OSTLER_WIKI_WAIT_STATE=cannot-run \
           bash "${BASH_SOURCE[0]}" 2>&1)"; rc=$?
    rm -f "$tmp8"
    if [ "$rc" -ne 1 ] || ! grep -q 'cm051_ostler_fda_ingest' <<< "$out"; then
        printf 'SELF-TEST ARM 8 BROKEN: cm051 absent with the wait cannot-run returned rc=%s, expected 1 (the wait vouches only for cm044)\n' "$rc"; fails=$((fails + 1))
    else
        printf 'arm 8 OK: the wait state excuses only the producer it watched\n'
    fi

    # ARM 9 (CONTROL): cm044 AND another producer missing with the wait cannot-run -> FAIL (1):
    # the refusal needs cm044 to be the ONLY missing producer, or a dead producer hides inside it.
    tmp9="$(mktemp -t ujprobeself-XXXXXX)"
    grep -v 'cm044-compile-' "$fixture" | grep -v 'ostler-fda-ingest-' > "$tmp9"
    out="$(USAGE_JOURNAL_PROBE_LOCAL=1 OSTLER_USAGE_JOURNAL="$tmp9" OSTLER_WIKI_WAIT_STATE=cannot-run \
           bash "${BASH_SOURCE[0]}" 2>&1)"; rc=$?
    rm -f "$tmp9"
    if [ "$rc" -ne 1 ] || ! grep -q 'cm051_ostler_fda_ingest' <<< "$out"; then
        printf 'SELF-TEST ARM 9 BROKEN: cm044 plus cm051 missing with the wait cannot-run returned rc=%s, expected 1 naming cm051 (a second dead producer must not hide in the refusal)\n' "$rc"; fails=$((fails + 1))
    else
        printf 'arm 9 OK: with a second producer also missing the refusal does not fire; the dead producer is named as FAIL\n'
    fi

    # ── #1634: "a producer nobody asked" vs "a producer that broke" ──
    #
    # ARM 10: oa_daemon_chat's records deleted AND the walk measured that the
    # daemon was asked NOTHING -> CANNOT-RUN (78) naming it. The daemon writes
    # `answering` when somebody sends it a message; a box nobody talked to
    # produces this reading with the daemon behaving perfectly.
    tmp10="$(mktemp -t ujprobeself-XXXXXX)"
    grep -v '"purpose": "answering"' "$fixture" > "$tmp10"
    if [ "$(grep -c . "$tmp10")" -ge "$(grep -c . "$fixture")" ]; then
        printf 'SELF-TEST ARM 10 BROKEN: the oa_daemon_chat mutation removed nothing\n'; fails=$((fails + 1))
    else
        out="$(USAGE_JOURNAL_PROBE_LOCAL=1 OSTLER_USAGE_JOURNAL="$tmp10" OSTLER_ASSISTANT_ASKED=0 \
               bash "${BASH_SOURCE[0]}" 2>&1)"; rc=$?
        if [ "$rc" -ne 78 ] || ! grep -q 'oa_daemon_chat' <<< "$out"; then
            printf 'SELF-TEST ARM 10 BROKEN: oa_daemon_chat absent after 0 questions returned rc=%s, expected 78 naming it\n' "$rc"
            printf '%s\n' "$out" | sed 's/^/    /'; fails=$((fails + 1))
        else
            printf 'arm 10 OK: a producer NOBODY ASKED is CANNOT-RUN naming it, not an accusation that it broke\n'
        fi

        # ARM 11 (CONTROL): the SAME journal after the daemon WAS asked is still
        # a FAIL. Without this, arm 10 could be satisfied by a probe that
        # refuses whenever oa_daemon_chat is missing, which is the silencer
        # #1634 explicitly is not.
        out="$(USAGE_JOURNAL_PROBE_LOCAL=1 OSTLER_USAGE_JOURNAL="$tmp10" OSTLER_ASSISTANT_ASKED=3 \
               bash "${BASH_SOURCE[0]}" 2>&1)"; rc=$?
        if [ "$rc" -ne 1 ] || ! grep -q 'oa_daemon_chat' <<< "$out"; then
            printf 'SELF-TEST ARM 11 BROKEN: oa_daemon_chat absent after 3 questions returned rc=%s, expected 1 naming it\n' "$rc"
            printf '%s\n' "$out" | sed 's/^/    /'; fails=$((fails + 1))
        else
            printf 'arm 11 OK: the same absence AFTER the daemon was asked is a FAIL, so arm 10 measures the opportunity and not the name\n'
        fi

        # ARM 12 (CONTROL): an UNPARSEABLE opportunity signal excuses nothing.
        # A missing or malformed value is UNKNOWN, and unknown is not
        # no-opportunity. If this arm ever returns 78 the signal has become a
        # way to turn a red off by breaking it.
        out="$(USAGE_JOURNAL_PROBE_LOCAL=1 OSTLER_USAGE_JOURNAL="$tmp10" OSTLER_ASSISTANT_ASKED="unknown" \
               bash "${BASH_SOURCE[0]}" 2>&1)"; rc=$?
        if [ "$rc" -ne 1 ]; then
            printf 'SELF-TEST ARM 12 BROKEN: an unparseable asked-count returned rc=%s, expected 1 (unknown excuses nothing)\n' "$rc"
            printf '%s\n' "$out" | sed 's/^/    /'; fails=$((fails + 1))
        else
            printf 'arm 12 OK: an unparseable opportunity signal excuses nothing; the producer keeps its FAIL\n'
        fi
    fi
    rm -f "$tmp10"

    # ── #1774: a leftover staging tree is not the box ──
    #
    # ARM 13: the RESOLVER lands on the installer's staging tree -> CANNOT-RUN
    # (78) saying STAGING. Measured on the v1.0.74 box: the only costs.jsonl was
    # under /tmp/ostler-prelaunch-69112 and the probe adjudicated the box
    # against it.
    out="$(USAGE_JOURNAL_PROBE_LOCAL=1 FAKE_COMPILE_EVIDENCE="4 present" \
           ZEROCLAW_CONFIG_DIR="/tmp/ostler-prelaunch-99999/assistant-config" \
           bash "${BASH_SOURCE[0]}" 2>&1)"; rc=$?
    if [ "$rc" -ne 78 ] || ! grep -q 'STAGING' <<< "$out"; then
        printf 'SELF-TEST ARM 13 BROKEN: a staging journal path returned rc=%s without refusing as STAGING, expected 78\n' "$rc"
        printf '%s\n' "$out" | sed 's/^/    /'; fails=$((fails + 1))
    else
        printf 'arm 13 OK: a journal path inside the installer staging tree is REFUSED, not adjudicated\n'
    fi

    # ARM 14 (CONTROL): a NON-staging path that is equally absent must NOT be
    # refused for the staging reason. Same resolver branch, same absent file,
    # same faked evidence -- only the path differs. Without it arm 13 would
    # pass for a probe that refuses every resolver result, which measures
    # nothing and would take the live path with it.
    out="$(USAGE_JOURNAL_PROBE_LOCAL=1 FAKE_COMPILE_EVIDENCE="4 present" \
           ZEROCLAW_CONFIG_DIR="${HOME}/.ostler-ujprobe-selftest-not-a-real-tree/assistant-config" \
           bash "${BASH_SOURCE[0]}" 2>&1)"; rc=$?
    if grep -q 'STAGING' <<< "$out"; then
        printf 'SELF-TEST ARM 14 BROKEN: a NON-staging path was refused as STAGING (rc=%s). The guard refuses everything and measures nothing.\n' "$rc"
        printf '%s\n' "$out" | sed 's/^/    /'; fails=$((fails + 1))
    else
        printf 'arm 14 OK: an equally absent NON-staging path is not refused as staging, so arm 13 measures the path\n'
    fi

    # ARM 5: the two must not collapse. If both evidence states give the same
    # verdict the distinction is decorative and the benign message is back.
    if [ "$fails" -eq 0 ]; then
        printf 'arm 5 OK: fresh-box and worked-box absences reach DIFFERENT verdicts (78 vs 1)\n'
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
    probe_examined 14 "self-test arms (complete journal / one producer deleted / absent on a fresh box / absent on a worked box / the two do not collapse / cm044 absent with the wait cannot-run refuses / the same after a converged wait fails / another producer with the wait cannot-run fails / cm044 plus another missing with the wait cannot-run fails / oa_daemon_chat absent after 0 questions refuses / the same after 3 questions fails / an unparseable asked-count fails / a staging journal path is refused / an equally absent non-staging path is not)"
    probe_fail "negative control behaved correctly on all 14 arms: a complete journal PASSes; a deleted producer FAILs and is NAMED; an absent journal on an unworked box is CANNOT-RUN rather than five regressions; the same absence on a box that HAS ingested and compiled is FAIL rather than a shrug; a producer NOBODY ASKED is CANNOT-RUN while the same producer after real traffic still FAILs; an unparseable opportunity signal excuses nothing; and a journal path inside the installer staging tree is REFUSED while an equally absent live path is not"
}

# A path-resolution passthrough, so tests/test_usage_journal_producer_gate.sh
# can pin this shell resolver against the gate's python one. Intercepted before
# probe_main because it is not a verdict and must not be counted as one.
if [ "${1:-}" = "--print-journal-path" ]; then
    resolve_journal
    exit 0
fi

probe_main "$@"
