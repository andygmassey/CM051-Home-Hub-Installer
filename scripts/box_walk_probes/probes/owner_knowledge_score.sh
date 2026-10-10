#!/usr/bin/env bash
# probes/owner_knowledge_score.sh
# ============================================================================
# QUESTION: how much of the owner's life can the assistant actually answer
#           about, asked the way a customer asks, graded without an LLM judge?
#
# This is the v1.0.108 "so what" gate (Lane 17). The instrument lives in
# scripts/owner_score/ (80 questions against a SYNTHETIC persona, 60 visible /
# 20 held back, deterministic graders, an immutable checksum). This probe runs
# a STRATIFIED SAMPLE of the visible set on the box, because each question is a
# full LLM turn (2-5 minutes on a Mac mini, see assistant_answers_grounded.sh)
# and 60 of them would be hours. The full 80-question score is
# `scripts/owner_score.sh --set all --enforce`, run on the Hub itself.
#
# ADVISORY, NOT BLOCKING, TODAY. scripts/walk_promote_scope.tsv carries it as
# `advisory`: a score under TARGET is a FAIL in the record and is printed at
# every promote, but does not refuse one. To make it the weekly-release gate,
# change that row to `blocking` (the ratchet test allows only that direction)
# and run the full set; see scripts/owner_score/README.md.
#
# WHAT IT NEVER DOES. It prints scores and question ids only (--no-verbatim):
# a reply is the owner's personal data and walk output lands in support
# bundles. It sends nothing off the box: the runner refuses a non-loopback
# gateway.
#
# THE PERSONA. A stock walk box knows nothing about the synthetic owner, so the
# probe puts the persona digest where the owner cheat sheet lives
# (~/.ostler/assistant-config/workspace/CONTEXT.md, which ostler-assistant's
# crates/zeroclaw-runtime/src/agent/prompt.rs injects into every system
# prompt), then RESTORES the file on exit. If the LaunchAgent regenerates
# CONTEXT.md mid-run the persona marker is gone and the probe says CANNOT-RUN
# rather than reporting a low score it did not earn. Set
# OSTLER_OWNER_SCORE_QUESTIONS to a questions file on the box to score the
# owner's real data instead; the persona is then not touched.
#
# ENV
#   OSTLER_OWNER_SCORE_LIMIT      questions to sample (default 8; 0 = all 60 visible)
#   OSTLER_OWNER_SCORE_TARGET     percent (default 70)
#   OSTLER_OWNER_SCORE_QUESTIONS  path ON THE BOX to the owner's own questions file
#   OSTLER_WORKSPACE_DIR          default $HOME/.ostler/assistant-config/workspace
#   OSTLER_PROBE_CHAT_TIMEOUT     per-turn ceiling in seconds (default 420)
#
# Runs under bash 3.2. No associative arrays, no mapfile.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/probe.sh"

PROBE_NAME="owner_knowledge_score"
PROBE_QUESTION="asked the way a customer asks, how many questions about the owner does the assistant answer correctly?"

LIMIT="${OSTLER_OWNER_SCORE_LIMIT:-8}"
TARGET="${OSTLER_OWNER_SCORE_TARGET:-70}"
CUSTOM_Q="${OSTLER_OWNER_SCORE_QUESTIONS:-}"
# The daemon runs with ZEROCLAW_WORKSPACE=${OSTLER_DIR}/assistant-config (install.sh);
# ~/.zeroclaw/workspace does not exist on a v1.0.107 box (walk #17: SWAP_RC=12).
WORKSPACE="${OSTLER_WORKSPACE_DIR:-\$HOME/.ostler/assistant-config/workspace}"
TOKEN_PATH="${OSTLER_PROBE_TOKEN_PATH:-~/.ostler/secrets/zeroclaw_admin_token}"
CHAT_TIMEOUT="${OSTLER_PROBE_CHAT_TIMEOUT:-420}"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../owner_score" && pwd)"
REMOTE_DIR="/tmp/ostler-owner-score-$$"
PERSONA_MARKER="Synthetic owner: Jane Smith"
_PERSONA_LOADED=0

# ── THE ADJUDICATOR ─────────────────────────────────────────────────────────
# adjudicate <runner-transcript-file> -> one line: "<TOKEN> <detail>"
#   MEETS    score at or over TARGET
#   BELOW    score under TARGET
#   TAMPERED the runner refused: the check no longer matches its lock
#   CANNOT   the runner could not ask (no token, gateway down), or printed no score
# A named function over a TRANSCRIPT FILE so --self-test drives the code the
# walk runs. The exit status travels as a final "RC=<n>" line.
adjudicate() {
    _rc="$(sed -n 's/^RC=//p' "$1" | tail -1)"
    _score="$(sed -n 's/^SCORE  \([0-9.]*\)%.*/\1/p' "$1" | head -1)"
    _ck="$(sed -n 's/^CHECK  built-in sha256 //p' "$1" | head -1)"
    case "$_rc" in
        3)  echo "TAMPERED the question set or graders no longer match scripts/owner_score/CHECKSUM.lock" ; return ;;
        78) echo "CANNOT the runner could not ask the assistant (no admin token, or the gateway is down)" ; return ;;
    esac
    if [ -z "$_score" ] || [ "$_rc" != "0" ]; then
        echo "CANNOT the runner exited ${_rc:-?} and printed no score" ; return
    fi
    if awk -v s="$_score" -v t="$TARGET" 'BEGIN{exit !(s+0 >= t+0)}'; then
        echo "MEETS ${_score}% (target ${TARGET}%), check ${_ck}"
    else
        echo "BELOW ${_score}% (target ${TARGET}%), check ${_ck}"
    fi
}

_restore_context() {
    [ "$_PERSONA_LOADED" -eq 1 ] || { [ -n "${_STAGED:-}" ] && box_run "rm -rf ${REMOTE_DIR}" >/dev/null 2>&1; return 0; }
    box_run "bash ${REMOTE_DIR}/context_swap.sh restore \"${WORKSPACE}\"; rm -rf ${REMOTE_DIR}" >/dev/null 2>&1
    _PERSONA_LOADED=0
}

run_probe() {
    box_reachable || probe_cannot_run "cannot reach the box; the assistant was never asked anything"
    box_run "test -f ${TOKEN_PATH}" >/dev/null 2>&1 \
        || probe_cannot_run "no admin token at ${TOKEN_PATH}; cannot authenticate to /ws/chat (coverage lost, NOT a pass)"
    [ -f "$SRC_DIR/owner_score.py" ] || probe_cannot_run "the instrument is missing from the checkout (scripts/owner_score/)"

    # Ship the instrument over stdin (box_run's ssh has no -n, so stdin is the transport).
    tar czf - -C "$SRC_DIR" grading.py owner_score.py questions_visible.jsonl questions_heldout.jsonl \
        CHECKSUM.lock CONTEXT.persona.md context_swap.sh 2>/dev/null \
        | box_run "mkdir -p ${REMOTE_DIR} && tar xzf - -C ${REMOTE_DIR}" >/dev/null 2>&1 \
        || probe_cannot_run "could not stage the owner-score instrument on the box"

    _STAGED=1
    # Signals are trapped as well as EXIT: SIGKILL cannot be, which is why every
    # run starts with `recover`.
    trap '_restore_context' EXIT
    trap '_restore_context; exit 143' TERM
    trap '_restore_context; exit 130' INT
    trap '_restore_context; exit 129' HUP

    # A previous run that was SIGKILLed left the persona in place and the real file
    # in the backup. Put it back before anything else happens.
    _rec="$(box_run "bash ${REMOTE_DIR}/context_swap.sh recover \"${WORKSPACE}\"" 2>&1)"
    [ -n "$_rec" ] && probe_note "$_rec"

    _qarg=""
    if [ -n "$CUSTOM_Q" ]; then
        _qarg="--questions '${CUSTOM_Q}'"
    else
        _kp="$(printf '%q' "${OSTLER_GATE_KNOWN_PERSON:-}")"
        # Marked BEFORE the swap runs: restore is idempotent, and a signal landing
        # between the swap and this assignment must still restore.
        _PERSONA_LOADED=1
        _sw="$(box_run "bash ${REMOTE_DIR}/context_swap.sh swap \"${WORKSPACE}\" ${REMOTE_DIR}/CONTEXT.persona.md ${_kp}; echo SWAP_RC=\$?" 2>&1)"
        case "$(printf '%s\n' "$_sw" | sed -n 's/^SWAP_RC=//p' | tail -1)" in
            0)  : ;;
            10) _PERSONA_LOADED=0; probe_cannot_run "refusing to swap CONTEXT.md: the existing ${WORKSPACE}/CONTEXT.md is not the synthetic seed, so this may be a real owner's box and it was not touched. To score a synthetic persona run the walk on a seeded box (the file names the walk's known person) or declare it with ~/.ostler/state/synthetic-box; to score the owner's real data set OSTLER_OWNER_SCORE_QUESTIONS." ;;
            11) probe_cannot_run "refusing to swap CONTEXT.md: a backup of an earlier run is still in the way (${WORKSPACE}/CONTEXT.md.owner-score-backup) and may be the only copy of the original; restore it by hand" ;;
            *)  probe_cannot_run "could not place the persona digest at ${WORKSPACE}/CONTEXT.md: $(printf '%s' "$_sw" | tr '\n' ' ' | cut -c1-160)" ;;
        esac
    fi
    _limit_arg=""
    [ "$LIMIT" != "0" ] && _limit_arg="--limit ${LIMIT}"

    _tmp="$(mktemp)"
    box_run "cd ${REMOTE_DIR} && python3 -I owner_score.py ${_qarg} ${_limit_arg} --no-verbatim --target ${TARGET} --timeout ${CHAT_TIMEOUT} --token-path '${TOKEN_PATH}' 2>/dev/null; echo RC=\$?" > "$_tmp" 2>&1

    if [ -z "$CUSTOM_Q" ]; then
        # The LaunchAgent that regenerates CONTEXT.md can overwrite the persona mid-run.
        box_run "grep -q '${PERSONA_MARKER}' \"${WORKSPACE}/CONTEXT.md\"" >/dev/null 2>&1 \
            || { _restore_context; probe_cannot_run "the persona digest was overwritten at ${WORKSPACE}/CONTEXT.md during the run (the context LaunchAgent), so the score would not measure the persona"; }
    fi

    sed 's/^/  /' "$_tmp" | grep -v '^  ASKED'
    _asked="$(sed -n 's/^NOTE   SAMPLE of \([0-9]*\) .*/\1/p' "$_tmp" | head -1)"
    [ -n "$_asked" ] || _asked="$(sed -n 's/^SCORE  [0-9.]*%  (\([0-9]*\) questions).*/\1/p' "$_tmp" | head -1)"
    _v="$(adjudicate "$_tmp")"
    rm -f "$_tmp"
    _restore_context
    probe_examined "${_asked:-0}" "owner-knowledge questions asked over /ws/chat (stratified sample of the visible set; the full 80 is scripts/owner_score.sh --set all)"
    case "${_v%% *}" in
        MEETS)    probe_pass "${_v#* }. ADVISORY today: see scripts/walk_promote_scope.tsv." ;;
        BELOW)    probe_fail_or_advisory "${_v#* }. Scope row says advisory: reported at every promote, not counted as a walk FAIL, does not refuse one." ;;
        TAMPERED) probe_fail "${_v#* }. Nothing was scored." ;;
        *)        probe_cannot_run "${_v#* }" ;;
    esac
}

# ── NEGATIVE CONTROLS ───────────────────────────────────────────────────────
self_test() {
    local f r fail=0
    f="$(mktemp)"; TARGET=70

    printf 'CHECK  built-in sha256 abc\nSCORE  42.5%%  (8 questions)\nRC=0\n' > "$f"
    r="$(adjudicate "$f")"; [ "${r%% *}" = "BELOW" ] || { fail=1; probe_note "control: 42.5% against 70 adjudicated '${r%% *}', not BELOW"; }

    printf 'SCORE  71.0%%  (8 questions)\nRC=0\n' > "$f"
    r="$(adjudicate "$f")"; [ "${r%% *}" = "MEETS" ] || { fail=1; probe_note "control: 71.0% adjudicated '${r%% *}', not MEETS"; }

    printf 'SCORE  70.0%%  (8 questions)\nRC=0\n' > "$f"
    r="$(adjudicate "$f")"; [ "${r%% *}" = "MEETS" ] || { fail=1; probe_note "control: exactly the target adjudicated '${r%% *}', not MEETS"; }

    printf 'CHECK  CHECK CHANGED, refusing to score.\nRC=3\n' > "$f"
    r="$(adjudicate "$f")"; [ "${r%% *}" = "TAMPERED" ] || { fail=1; probe_note "control: a changed check adjudicated '${r%% *}', not TAMPERED"; }

    printf 'CANNOT-RUN: no token\nRC=78\n' > "$f"
    r="$(adjudicate "$f")"; [ "${r%% *}" = "CANNOT" ] || { fail=1; probe_note "control: rc 78 adjudicated '${r%% *}', not CANNOT"; }

    # THE ONE THAT MATTERS: no score line must never read as a pass or as 0%.
    printf 'RC=0\n' > "$f"
    r="$(adjudicate "$f")"; [ "${r%% *}" = "CANNOT" ] || { fail=1; probe_note "control: ABSENCE of a score adjudicated '${r%% *}', not CANNOT"; }
    printf 'SCORE  99.0%%  (8 questions)\nRC=1\n' > "$f"
    r="$(adjudicate "$f")"; [ "${r%% *}" = "CANNOT" ] || { fail=1; probe_note "control: a score with a non-zero exit adjudicated '${r%% *}', not CANNOT"; }
    rm -f "$f"

    probe_examined 7 "of 7 adjudication controls (below, meets, exactly target, tampered, cannot-run, no score, score with bad exit)"
    if [ "$fail" -ne 0 ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: adjudicate() misclassified a control, so a verdict from this probe would prove nothing"
    fi
    probe_fail "control fired: BELOW, MEETS, exact-target, TAMPERED, CANNOT, no-score and bad-exit are each classified"
}

probe_main "$@"
