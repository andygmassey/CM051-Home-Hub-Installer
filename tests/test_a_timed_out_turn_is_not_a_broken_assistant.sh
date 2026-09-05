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
frames() {
    case "$1" in
        grounded)   printf 'FRAME session_start\nFRAME tool_call pwg_preferences\nFRAME tool_result pwg_preferences OK\nFRAME done\n' ;;
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
verdict() {  # verdict <turn1> <turn2> <turn3>  -> PASS | FAIL | CANNOT-RUN
    local h="${WORK}/h.sh" i=1
    : > "${WORK}/answers"
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

printf '\n== %s pass / %s fail / %s total ==\n' "$PASS" "$FAIL" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
