#!/usr/bin/env bash
#
# A TURN THAT NEVER COMPLETED IS NOT AN ASSISTANT THAT CANNOT ANSWER.
#
# assistant_answers_grounded is BLOCKING and its subject is the product's core
# promise. Until this change EVERY non-`grounded` verdict was a probe_fail --
# including `incomplete`, which means the turn timed out or died mid-stream, and
# `fatal`, which means the client never started.
#
# So a clock produced the sentence "N of M questions did not reach the customer's
# own data": a claim about the SHIPPED ARTEFACT, on the one probe that refuses a
# promote for the product's core promise.
#
# And the ceiling made it likely rather than theoretical. The probe's own runtime
# note records "2-5 MINUTES per turn" on a Mac mini under first-run ingest load,
# while the default ceiling was 240s -- FOUR minutes, inside the measured normal
# range.
#
# Same class as the pairing probe's non-answer, fixed hours earlier in this same
# suite: a refusal and a non-answer are different findings and only one is about
# the product.
#
# THIS DRIVES THE REAL run_probe. The probe's own self-test can only reach
# adjudicate_turn and classify_verdict; the PRECEDENCE that turns those into a
# verdict lives in the loop, which needs a box. A stubbed box_run gives it one.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECT="${ROOT}/scripts/box_walk_probes/probes/assistant_answers_grounded.sh"
[ -f "$SUBJECT" ] || { printf 'CANNOT-RUN: no probe at %s\n' "$SUBJECT" >&2; exit 2; }
grep -q '^run_probe() {' "$SUBJECT" || { printf 'CANNOT-RUN: no run_probe in the probe\n' >&2; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

WORK="$(mktemp -d)" || { printf 'CANNOT-RUN: no working directory\n' >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# Frame streams, one per turn shape. These are the same shapes the probe's own
# fixtures use, so the two cannot drift apart silently.
#
# ⚠️ `grounded` READS THREE STORES, and that is required rather than generous.
# Since #1125 each battery question declares the stores whose data could hold
# its answer, so ONE canned stream is fed to a question about the customer's
# tastes AND to a question about the people they contacted. A single-tool
# stream grounds at one position and scores wrong_store at another, which
# would make this file's healthy-battery control CANNOT-RUN and take every arm
# below with it. Reading overview, preferences and people covers the clauses
# the battery declares, without this file having to know the mapping -- which
# it must not, or it would stop being a control and start being a copy.
#
# THIS FILE IS NOT THE MAPPING'S GUARD. That is
# scripts/tests/test_grounded_probe_names_the_store_and_refuses_a_blind_turn.sh.
# Here the mapping is background: the subject is timeout precedence.
frames() {
    case "$1" in
        grounded)   printf 'FRAME session_start\nFRAME tool_call pwg_overview\nFRAME tool_result pwg_overview OK\nFRAME tool_call pwg_preferences\nFRAME tool_result pwg_preferences OK\nFRAME tool_call pwg_people\nFRAME tool_result pwg_people OK\nFRAME done\n' ;;
        incomplete) printf 'FRAME session_start\nFRAME tool_call pwg_topics\nFRAME timeout\n' ;;
        fatal)      printf 'PROBE_FATAL connection refused\n' ;;
        notool)     printf 'FRAME session_start\nFRAME chunk_reset\nFRAME done\n' ;;
        toolerr)    printf 'FRAME session_start\nFRAME tool_call pwg_preferences\nFRAME tool_result pwg_preferences ERR\nFRAME done\n' ;;
    esac
}

# TAKE THE WHOLE FILE, minus the two lines that would fight the harness: the
# `. lib/probe.sh` source (which would replace the stubs) and the trailing
# probe_main (which would run it). A unit is not its file -- extracting run_probe
# alone would leave classify_verdict undefined and every arm would measure that.
# THE BATTERY SIZE IS DERIVED FROM THE SUBJECT, NOT DECLARED HERE.
#
# 🔴 THIS HARNESS USED TO HARD-CODE THREE TURNS, and when the battery grew to
# four the fourth turn got no synthetic answer, the control arm never reached
# PASS, and this file refused at its first arm having measured nothing. The
# refusal message was literally correct -- "the harness is wrong, not the
# probe" -- and it named its own defect while nobody could see it, because the
# CI rollup renders any non-zero as "failure" and a CANNOT-RUN (exit 2) is
# indistinguishable from a FAIL (exit 1) in that list.
#
# A test whose harness encodes the SHAPE of its subject cannot survive the
# subject changing, which is the same family as a fixture encoding the flag
# rather than the property. So the count is read from _questions() in the
# SUBJECT, and callers supply only the turns they care about; the remainder are
# padded HEALTHY so an arm about turn 2 stays an arm about turn 2 when a turn 4
# appears. cat at the consumption site uses 2>/dev/null, so a missing answer
# file is silently EMPTY rather than an error, which is exactly why this failed
# quietly instead of loudly.
_battery_size() {
    sed -n '/^_questions()/,/^}/p' "$SUBJECT" \
        | sed -n '/<<QEOF/,/^QEOF/p' \
        | grep -c "$(printf '\t')"
}

verdict() {  # verdict <turn...>  -> PASS | FAIL | CANNOT-RUN
    local h="${WORK}/h.sh" i=1
    local _n _last
    _n="$(_battery_size)"
    # VALIDATE THE READ, NEVER DEFAULT IT. An empty or non-numeric answer here
    # used to fall through `${_n:-0}` to zero, which skips the padding, returns
    # the ORIGINAL symptom, and reports it as "the harness is wrong" without
    # naming the cause. A CANNOT-RUN that does not say what it could not read
    # is the failure this whole file exists to argue against, so it names the
    # file and the value it actually got.
    case "$_n" in
        ''|*[!0-9]*)
            printf 'CANNOT-RUN: could not read the battery size from %s (got %s); refusing rather than assuming a size\n' \
                "$SUBJECT" "${_n:-<empty>}" >&2
            exit 2
            ;;
    esac
    [ "$_n" -ge 1 ] || {
        printf 'CANNOT-RUN: %s declares a battery of %s questions; nothing to measure\n' "$SUBJECT" "$_n" >&2
        exit 2
    }
    : > "${WORK}/answers"
    set -- "$@"
    _last="${@: -1}"
    while [ "$#" -lt "${_n:-0}" ]; do set -- "$@" "$_last"; done
    for t in "$@"; do frames "$t" >> "${WORK}/answers.$i"; i=$((i+1)); done
    cat > "$h" <<HDR
set -uo pipefail
PROBE_EX_PASS=0; PROBE_EX_FAIL=1; PROBE_EX_CANNOT_RUN=2
probe_examined() { :; }
probe_note()     { :; }
probe_pass()       { printf 'PASS\n';       exit 0; }
probe_fail()       { printf 'FAIL\n';       exit 1; }
probe_cannot_run() { printf 'CANNOT-RUN\n'; exit 2; }
box_reachable() { return 0; }
# THE COUNTER IS A FILE, NOT A VARIABLE. box_run is called inside a redirection
# in the probe, and a shell variable incremented there would not survive.
_N_F="${WORK}/n"; : > "\$_N_F"
box_run() {
  case "\$1" in
    *base64*|*"rm -f"*) return 0 ;;
    *python3*)
      printf 'x' >> "\$_N_F"
      _i=\$(wc -c < "\$_N_F" | tr -d ' ')
      cat "${WORK}/answers.\$_i" 2>/dev/null
      return 0 ;;
    *) return 0 ;;
  esac
}
HDR
    grep -v -e '^\. "' -e '^source ' -e '^probe_main ' "$SUBJECT" >> "$h"
    printf 'run_probe\n' >> "$h"
    bash "$h" 2>/dev/null | tail -1
    rm -f "${WORK}"/answers.*
}

# CONTROL FIRST. If a healthy battery does not pass, every arm below is measuring
# the harness rather than the precedence.
case "$(verdict grounded grounded grounded)" in
    PASS) ok "CONTROL: three grounded turns PASS, so the harness reaches the real verdict" ;;
    *)    printf 'CANNOT-RUN: a healthy battery produced %s; the harness is wrong, not the probe.\n' "$(verdict grounded grounded grounded)" >&2; exit 2 ;;
esac

# THE FIX. A timeout is a clock, not a product failure.
case "$(verdict grounded incomplete grounded)" in
    CANNOT-RUN) ok "one turn that never completed -> CANNOT-RUN, not a claim about the assistant" ;;
    FAIL)       bad "a TIMEOUT is still reported as the assistant failing to reach the customer's data. That is a product claim asserted on a clock, on a blocking probe." ;;
    *)          bad "one incomplete turn produced '$(verdict grounded incomplete grounded)'" ;;
esac
case "$(verdict fatal fatal fatal)" in
    CANNOT-RUN) ok "a client that never started -> CANNOT-RUN" ;;
    *)          bad "three fatal turns produced '$(verdict fatal fatal fatal)', not CANNOT-RUN" ;;
esac

# AND THE FALSE GREEN THE FIX COULD HAVE BOUGHT. A real defect must still fail.
case "$(verdict grounded notool grounded)" in
    FAIL) ok "CONTROL: a turn that COMPLETED without touching the graph still FAILS" ;;
    *)    bad "no_tool_call produced '$(verdict grounded notool grounded)' -- the probe can no longer detect the #854 shape" ;;
esac
case "$(verdict grounded toolerr grounded)" in
    FAIL) ok "CONTROL: a tool error still FAILS (the #855 shape)" ;;
    *)    bad "tool_error produced '$(verdict grounded toolerr grounded)'" ;;
esac

# PRECEDENCE. A proven defect outranks lost coverage: if one turn completed and
# missed the graph, that is a finding whether or not another timed out.
case "$(verdict notool incomplete grounded)" in
    FAIL) ok "PRECEDENCE: a defect beside a timeout is still a FAIL, not downgraded to CANNOT-RUN" ;;
    *)    bad "a defect alongside a timeout produced '$(verdict notool incomplete grounded)' -- lost coverage is masking a real finding" ;;
esac

# THE CEILING. The probe's own runtime note records 2-5 minutes per turn; a
# default below that top end makes the timeout arm fire on healthy boxes.
CEIL="$(grep -o 'OSTLER_PROBE_CHAT_TIMEOUT:-[0-9]*' "$SUBJECT" | head -1 | sed 's/.*-//')"
if [ -n "$CEIL" ] && [ "$CEIL" -ge 300 ]; then
    ok "the per-turn ceiling is ${CEIL}s, above the 5-minute top of the range this probe itself measured"
else
    bad "the per-turn ceiling is ${CEIL:-unset}s, inside or below the 2-5 minute range the probe's own runtime note records. Healthy turns would time out."
fi

# ── A tool_error THAT NAMES NO TOOL ─────────────────────────────────────────
# The verdict word says retrieval failed. The transcript line it was decided
# from carries the tool name, and the detail discarded it, so an operator read
# "[tool_error]" and had to reopen the raw transcript for the only actionable
# fact in the turn. Driven through the REAL _offending_tool, extracted from the
# probe exactly as the harness above extracts run_probe.
_H="${WORK}/nameharness"
{
    printf '#!/bin/bash\n'
    grep -v -e '^\. "' -e '^source ' -e '^probe_main ' "$SUBJECT"
    cat <<'TAIL'
_d="$(mktemp -d)"
printf 'FRAME session_start\nFRAME tool_call pwg_topics\nFRAME tool_result pwg_topics ERR\nFRAME done\n'       > "$_d/err"
printf 'FRAME session_start\nFRAME tool_call pwg_people\nFRAME tool_result pwg_people EMPTY\nFRAME done\n'     > "$_d/empty"
printf 'FRAME session_start\nFRAME chunk_reset\nFRAME done\n'                                                  > "$_d/notool"
printf 'FRAME session_start\nFRAME tool_call memory_recall\nFRAME tool_result memory_recall ERR\nFRAME done\n' > "$_d/nonpwg"
printf 'ERR=[%s]\n'    "$(_offending_tool "$_d/err" tool_error)"
printf 'EMPTY=[%s]\n'  "$(_offending_tool "$_d/empty" tool_found_nothing)"
printf 'NOTOOL=[%s]\n' "$(_offending_tool "$_d/notool" no_tool_call)"
printf 'NONPWG=[%s]\n' "$(_offending_tool "$_d/nonpwg" tool_error)"
rm -rf "$_d"
TAIL
} > "$_H"
_OUT="$(bash "$_H" 2>/dev/null)"

if ! grep -q '^ERR=' <<< "$_OUT"; then
    printf 'CANNOT-RUN: the name harness produced no ERR line; _offending_tool was never reached.\n' >&2
    exit 2
fi
case "$_OUT" in
    *"ERR=[pwg_topics]"*) ok "a tool_error NAMES the tool that errored (pwg_topics), so the detail is actionable" ;;
    *)                    bad "a tool_error named no tool: $(printf '%s' "$_OUT" | grep '^ERR=')" ;;
esac
case "$_OUT" in
    *"EMPTY=[pwg_people]"*) ok "success-shaped emptiness also names its tool (pwg_people)" ;;
    *)                      bad "tool_found_nothing named no tool: $(printf '%s' "$_OUT" | grep '^EMPTY=')" ;;
esac
# MUST-MISS. A verdict decided by no tool result must yield NO name, or the
# detail would attach a subject to a turn where nothing was retrieved at all.
case "$_OUT" in
    *"NOTOOL=[]"*) ok "MUST-MISS: a verdict with no tool result yields no name" ;;
    *)             bad "no_tool_call was given a tool name: $(printf '%s' "$_OUT" | grep '^NOTOOL=')" ;;
esac
# CONTROL. memory_recall is the CHAT's own memory, not the customer's graph.
# Naming it as the failing graph tool is the exact confusion the memory_only
# verdict exists to prevent.
case "$_OUT" in
    *"NONPWG=[]"*) ok "CONTROL: a non-pwg tool is never named as the failing graph tool" ;;
    *)             bad "a non-pwg tool was named as the failing graph tool: $(printf '%s' "$_OUT" | grep '^NONPWG=')" ;;
esac

# ── A RECOVERED TURN IS NOT A FAILED ONE (#1597) ────────────────────────────
# The adjudicator used to grep the WHOLE transcript for any pwg ERR, so a turn
# that errored, recovered and answered correctly scored as a product failure on
# a BLOCKING probe. The product is BUILT to recover: person_query's error text
# is deliberately worded to make the model call pwg_overview and try again --
# that was the #854 fix. The fix and the gate worked against each other.
_R="${WORK}/recoverharness"
{
    printf '#!/bin/bash\n'
    grep -v -e '^\. "' -e '^source ' -e '^probe_main ' "$SUBJECT"
    cat <<'TAIL'
_d="$(mktemp -d)"
# THE PERSON CLAUSE, the store set question 3 and the seeded turn declare
# (#1125). adjudicate_turn takes it as a second argument and REFUSES with
# no_expected_tools when it is absent, which is deliberate: a turn graded
# against no store set has not been graded.
_PERSON='pwg_people pwg_person_timeline'
# ⚠️ THE FULL RECOVERY, extended in the #1125 lift. person_query's error text
# asks for two things -- call pwg_overview, THEN call the person tool again --
# and this fixture used to stop after the first. That made its only successful
# read an INVENTORY COUNT, on a question about who the customer has been in
# contact with, and it scored grounded because some pwg tool returned OK. It
# was the #1125 blindness sitting inside the control meant to prove the probe
# could see. The half recovery is now asserted separately, below.
printf 'FRAME session_start
FRAME tool_call pwg_person_timeline
FRAME tool_result pwg_person_timeline ERR
FRAME tool_call pwg_overview
FRAME tool_result pwg_overview OK
FRAME tool_call pwg_person_timeline
FRAME tool_result pwg_person_timeline OK
FRAME done
' > "$_d/recovered"
printf 'FRAME session_start
FRAME tool_call pwg_person_timeline
FRAME tool_result pwg_person_timeline ERR
FRAME tool_call pwg_overview
FRAME tool_result pwg_overview OK
FRAME done
' > "$_d/recovered_half"
printf 'FRAME session_start
FRAME tool_call pwg_person_timeline
FRAME tool_result pwg_person_timeline ERR
FRAME tool_call pwg_topics
FRAME tool_result pwg_topics ERR
FRAME done
'    > "$_d/twoerrs"
printf 'FRAME session_start
FRAME tool_call pwg_preferences
FRAME tool_result pwg_preferences ERR
FRAME done
'                                                                          > "$_d/onlyerr"
printf 'FRAME session_start
FRAME tool_call pwg_person_timeline
FRAME tool_result pwg_person_timeline EMPTY
FRAME done
'                                                                > "$_d/onlyempty"
printf 'RECOVERED=%s
' "$(adjudicate_turn "$_d/recovered" "$_PERSON")"
printf 'HALFRECOVERED=%s
' "$(adjudicate_turn "$_d/recovered_half" "$_PERSON")"
printf 'TWOERRS=%s
'   "$(adjudicate_turn "$_d/twoerrs" "$_PERSON")"
printf 'ONLYERR=%s
'   "$(adjudicate_turn "$_d/onlyerr" 'pwg_preferences')"
printf 'ONLYEMPTY=%s
' "$(adjudicate_turn "$_d/onlyempty" "$_PERSON")"
printf 'NOSET=%s
'     "$(adjudicate_turn "$_d/recovered")"
rm -rf "$_d"
TAIL
} > "$_R"
_ROUT="$(bash "$_R" 2>/dev/null)"

if ! grep -q '^RECOVERED=' <<< "$_ROUT"; then
    printf 'CANNOT-RUN: the recovery harness produced no verdict; adjudicate_turn was never reached.\n' >&2
    exit 2
fi
case "$_ROUT" in
    *"RECOVERED=grounded"*) ok "a turn that errored and then READ THE STORE THAT HOLDS THE ANSWER scores grounded, not a product failure" ;;
    *)                      bad "a recovered turn still scores $(printf '%s' "$_ROUT" | grep '^RECOVERED=' | cut -d= -f2); the #854 retry fix and this blocking gate fight each other" ;;
esac
# THE HALF RECOVERY (#1125). person_query's error text asks the model to call
# pwg_overview and then call the person tool AGAIN. A turn that does the first
# and not the second hands the customer a COUNT when they asked who they have
# been in contact with. It is not recovered, and the old adjudicator called it
# grounded because some pwg tool returned OK.
case "$_ROUT" in
    *"HALFRECOVERED=tool_error"*) ok "MUST-MISS: a turn that errored and then read only the INVENTORY is tool_error, not grounded" ;;
    *)                            bad "a half recovery scored $(printf '%s' "$_ROUT" | grep '^HALFRECOVERED=' | cut -d= -f2); an inventory count is being accepted as the customer's contacts" ;;
esac
# MUST-MISS. Recovery is decided by a SUCCESSFUL read, not by a second attempt.
case "$_ROUT" in
    *"TWOERRS=tool_error"*) ok "MUST-MISS: two failed reads in a row are still tool_error" ;;
    *)                      bad "two consecutive errors scored $(printf '%s' "$_ROUT" | grep '^TWOERRS=' | cut -d= -f2); the reorder made the probe unable to fail" ;;
esac
case "$_ROUT" in
    *"ONLYERR=tool_error"*) ok "MUST-MISS: an error with no recovery is still tool_error" ;;
    *)                      bad "a lone error scored $(printf '%s' "$_ROUT" | grep '^ONLYERR=' | cut -d= -f2)" ;;
esac
# CONTROL. Success-shaped emptiness must NOT be promoted to grounded by this
# change: EMPTY is not an error, and it is still not retrieval.
case "$_ROUT" in
    *"ONLYEMPTY=tool_found_nothing"*) ok "CONTROL: a graph tool that found nothing is still not retrieval" ;;
    *)                                bad "an EMPTY-only turn scored $(printf '%s' "$_ROUT" | grep '^ONLYEMPTY=' | cut -d= -f2); the #810 shape has been promoted to a pass" ;;
esac
# THE INSTRUMENT REFUSES. Called with NO store set -- the shape every caller in
# this file had before #1125 -- adjudicate_turn must decline to grade rather
# than fall back to grading loosely. classify_verdict routes no_expected_tools
# to unmeasured, so a probe whose battery lost its map reports CANNOT-RUN and
# never a pass.
case "$_ROUT" in
    *"NOSET=no_expected_tools"*) ok "CONTROL: with no store set the adjudicator REFUSES rather than grading on a prefix" ;;
    *)                           bad "a turn graded with no store set returned $(printf '%s' "$_ROUT" | grep '^NOSET=' | cut -d= -f2); an unmapped question is being given a verdict" ;;
esac

printf '\n== %s pass / %s fail / %s total ==\n' "$PASS" "$FAIL" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
