#!/usr/bin/env bash
# A STEP THAT MEASURED NOTHING MAY NOT REPORT `ok` (#2318)
# =======================================================
#
# THE INPUT THIS TEST REPLAYS
#
# #839 fixed the ARGUMENT: gui_step_end no longer takes `ok` from its call
# site, it reads a status accumulated from the step's own children. What it
# left behind was the ACCUMULATOR'S OWN DEFAULT:
#
#     lib/progress_emitter.sh:  __OSTLER_STEP_STATUS="ok"
#                               local status="${__OSTLER_STEP_STATUS:-ok}"
#
# `ok` was still a default rather than a measurement, so the fix only ever
# reached the steps that call gui_step_record_rc. MEASURED on origin/main
# at d7b0347 with the repo's own heredoc classifier (install.sh embeds whole
# scripts, so a raw grep counts text as code):
#
#     46 steps          45 `progress "` call sites + gui_step_begin health_check
#      8 call sites     gui_step_record_rc, of which 2 are fatal-abort paths
#      4 steps covered  hydrate_graph, initial_hydrate, wiki_compile,
#                       health_check
#
# The other 42 had no route to any status but `ok` short of the install
# dying. A real install therefore emitted 42 of 42 STEP_END lines saying
# status=ok, including steps that had just been told there were 2,447 people
# and 155 iMessage conversations to index and indexed none.
#
# WHAT THIS TEST ASSERTS
#
#   A  ORIGINAL FAILING INPUT. A step that records nothing must NOT close
#      status=ok. It closes status=unmeasured measured=no.
#   B  POSITIVE CONTROL, MUST BE PRESENT. A step whose child exits 0 and
#      which records that must still close status=ok. Without this, a "fix"
#      that stamps every step not-ok passes A, and a universal non-ok is
#      exactly as useless as the universal ok it replaced.
#   C  THREE OUTCOMES, NOT TWO. unmeasured, ok and error are all observed
#      in one run and are all distinct.
#   D  THE REAL install.sh PATH. _hydrate_sentinel_record -- the SUCCESS
#      half of the hydrate pair, which wrote its .done file and told the
#      step nothing -- now records its measurement. A non-zero payload
#      closes ok; an all-zero payload does NOT get laundered into one.
#   E  THE DECLARATION. gui_step_measures_nothing closes ok but stamps
#      measured=declared-none plus its reason, so a step that legitimately
#      has nothing to measure is distinguishable ON THE WIRE from one that
#      measured something, and from one that measured nothing.
#   F  NO LAUNDERING, EITHER WAY IN. A declaration after a recorded error
#      keeps the error, and an explicit `gui_step_end ok` cannot assert
#      success over an unmeasured step. #839 made that asymmetry deliberate
#      for measured failures; it now covers the absence of a measurement.
#   G  THE DEBT METER. The DONE line carries unmeasured_steps, unmeasured
#      steps are NOT counted as failed_steps (or every install would tell
#      the customer it had 42 problems), and a run with none PRINTS
#      unmeasured_steps=0 so a zero cannot be read as an unreporting build.
#   H  MUTATION. With the default put back to `ok`, A's input must produce
#      status=ok again. A test that cannot see the fix removed is not
#      testing the fix.
#
# The test sources the REAL lib/progress_emitter.sh and EXECUTES the real
# _hydrate_sentinel_record extracted from install.sh. It cannot pass against
# a copy of the logic.

set -uo pipefail

# NO QUIET-GREP-ON-THE-RIGHT-OF-A-PIPE ANYWHERE IN THIS FILE, and the ban is
# not stylistic. The banned shape is deliberately NOT spelled here: a scanner
# that hunts it must not find a specimen in the prose warning against it.
# Under `set -o pipefail` (set above), `grep -q` exits 0 on its FIRST match and
# closes the pipe, SIGPIPE-ing the producer; the PIPELINE then reports non-zero
# and the condition reads FALSE for a pattern that was PRESENT. An inverted
# verdict, and on a test whose whole subject is a status field that lied, that
# is the same defect one level up. tests/test_pipefail_shortcircuit_inversion.sh
# ratchets the repo against it. Remedy A (a herestring: no pipe, so no SIGPIPE)
# is used throughout, which is sound because this file is bash and runs under
# /bin/bash; if any of it ever runs through `sh -c` or over ssh, the herestring
# is a bashism and the remedy becomes `[ "$(... | grep -c PAT)" -gt 0 ]`.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
EMITTER="${REPO_ROOT}/lib/progress_emitter.sh"

FAILURES=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

for f in "$INSTALL_SH" "$EMITTER"; do
    if [ ! -f "$f" ]; then
        printf 'FATAL: expected file not found: %s\n' "$f" >&2
        exit 1
    fi
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/measured-nothing.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ── Extract the REAL functions from install.sh ─────────────────────────
extract_fn() {
    awk -v fn="$1" '
        $0 ~ "^"fn"\\(\\) \\{" { inside = 1 }
        inside { print }
        inside && /^\}/ { exit }
    ' "$2"
}

extract_fn _hydrate_payload_count      "$INSTALL_SH" > "${WORK}/payload_count.sh"
extract_fn _hydrate_payload_is_all_zero "$INSTALL_SH" > "${WORK}/all_zero.sh"
extract_fn _hydrate_compute_change     "$INSTALL_SH" > "${WORK}/compute_change.sh"
extract_fn _hydrate_sentinel_record    "$INSTALL_SH" > "${WORK}/sentinel_ok.sh"

for f in payload_count all_zero compute_change sentinel_ok; do
    if [ ! -s "${WORK}/${f}.sh" ]; then
        printf 'FATAL: could not extract %s from install.sh. The test is measuring nothing.\n' "$f" >&2
        exit 1
    fi
    if ! bash -n "${WORK}/${f}.sh"; then
        printf 'FATAL: extracted %s does not parse. Extraction is broken, not the code.\n' "$f" >&2
        exit 1
    fi
done
printf 'Harness: extracted the hydrate sentinel success recorder from install.sh.\n'

# ── The scenario, driven against a chosen emitter ──────────────────────
#
# One shell, because the step accumulator, the extracted recorder and the
# DONE counters all live in ONE shell during a real install.
run_scenario() {
    # run_scenario <emitter-path> <marker-file>
    OSTLER_GUI=1 \
    _T_EMITTER="$1" \
    _T_WORK="$WORK" \
    bash <<'DRIVER' 2>"$2"
set -uo pipefail
_HYDRATE_SENTINEL_DIR="${_T_WORK}/hydrate"
mkdir -p "$_HYDRATE_SENTINEL_DIR"

# shellcheck source=/dev/null
. "${_T_EMITTER}"
for f in payload_count all_zero compute_change sentinel_ok; do
    # shellcheck source=/dev/null
    . "${_T_WORK}/${f}.sh"
done

# B: the positive control runs FIRST. If a measured success does not close
# `ok`, the emitter is stamping everything not-ok and A proves nothing.
gui_step_begin "measured_success" "Child exits 0 and we record it"
true; gui_step_record_rc $?
gui_step_end

# A: the original failing input. Real work, no recorded outcome.
gui_step_begin "records_nothing" "Work happens, nothing is recorded"
:
gui_step_end

# C: a measured failure, so all three outcomes appear in one run.
gui_step_begin "measured_failure" "Child exits 3"
( exit 3 ); gui_step_record_rc $?
gui_step_end

# D: the REAL install.sh success recorder, with a real payload.
gui_step_begin "hydrate_real_payload" "A hydrate that stored something"
_hydrate_sentinel_record "contacts" "imported=2447"
gui_step_end

# D: the same recorder with an all-zero payload. It writes status=no_data
# and returns BEFORE recording, so the step stays unmeasured. It must not
# be laundered into a success.
gui_step_begin "hydrate_zero_payload" "A hydrate that stored nothing"
_hydrate_sentinel_record "imessage" "people=0" "nothing_to_import"
gui_step_end

# E: the explicit declaration.
gui_step_begin "declared_noop" "Genuinely nothing to measure"
gui_step_measures_nothing "emits no store write and no child process"
gui_step_end

# F: a declaration must not launder a recorded failure.
gui_step_begin "declare_after_error" "Declaration after a real error"
( exit 5 ); gui_step_record_rc $?
gui_step_measures_nothing "claiming there was nothing to measure"
gui_step_end

# F: an explicit `ok` argument must not assert over an unmeasured step.
gui_step_begin "forced_ok" "Call site asserts ok over nothing"
gui_step_end ok

gui_done ok
DRIVER
}

MARKERS="${WORK}/markers.txt"
run_scenario "$EMITTER" "$MARKERS"

# ── Dead-harness control, BEFORE any absence claim ─────────────────────
STEP_END_COUNT="$(grep -c 'STEP_END' "$MARKERS")"
if [ "${STEP_END_COUNT:-0}" -lt 8 ]; then
    printf 'FATAL: only %s STEP_END lines were emitted; expected 8. Every assertion below would be reading an empty file.\n' \
        "${STEP_END_COUNT:-0}" >&2
    sed -n '1,20p' "$MARKERS" >&2
    exit 1
fi
printf 'Harness: %s STEP_END lines emitted, so absence assertions are measuring a live wire.\n\n' "$STEP_END_COUNT"

line_for() { grep "id=$1	" "$MARKERS" | grep 'STEP_END' | tail -n 1; }

# --- A: the original failing input --------------------------------------
A_LINE="$(line_for records_nothing)"
if [ -z "$A_LINE" ]; then
    fail "A: no STEP_END for records_nothing. Nothing was measured."
elif grep -q 'status=ok' <<< "$A_LINE"; then
    fail "A: a step that recorded nothing still closed status=ok: ${A_LINE}"
elif grep -q 'status=unmeasured' <<< "$A_LINE" && grep -q 'measured=no' <<< "$A_LINE"; then
    pass "A: a step that recorded nothing closes status=unmeasured measured=no"
else
    fail "A: unexpected status for records_nothing: ${A_LINE}"
fi

# --- B: the positive control --------------------------------------------
B_LINE="$(line_for measured_success)"
if grep -q 'status=ok' <<< "$B_LINE" && grep -q 'measured=rc' <<< "$B_LINE"; then
    pass "B: a MEASURED success still closes status=ok measured=rc"
else
    fail "B: a measured success did not close ok, so the change made everything suspect: ${B_LINE:-<none>}"
fi

# --- C: three outcomes, all distinct ------------------------------------
C_LINE="$(line_for measured_failure)"
if grep -q 'status=error' <<< "$C_LINE" && grep -q 'rc=3' <<< "$C_LINE"; then
    A_S="$(printf '%s' "$A_LINE" | tr '\t' '\n' | grep '^status=')"
    B_S="$(printf '%s' "$B_LINE" | tr '\t' '\n' | grep '^status=')"
    C_S="$(printf '%s' "$C_LINE" | tr '\t' '\n' | grep '^status=')"
    if [ "$A_S" != "$B_S" ] && [ "$B_S" != "$C_S" ] && [ "$A_S" != "$C_S" ]; then
        pass "C: three distinct outcomes in one run (${A_S}, ${B_S}, ${C_S})"
    else
        fail "C: outcomes are not distinct: ${A_S} ${B_S} ${C_S}"
    fi
else
    fail "C: a child exiting 3 did not close status=error rc=3: ${C_LINE:-<none>}"
fi

# --- D: the real install.sh recorder ------------------------------------
D_LINE="$(line_for hydrate_real_payload)"
if grep -q 'status=ok' <<< "$D_LINE" && grep -q 'measured=rc' <<< "$D_LINE"; then
    pass "D: _hydrate_sentinel_record with a real payload closes the step ok"
else
    fail "D: install.sh's success recorder still tells the step nothing: ${D_LINE:-<none>}"
fi

DZ_LINE="$(line_for hydrate_zero_payload)"
if grep -q 'status=ok' <<< "$DZ_LINE"; then
    fail "D: an all-zero payload was laundered into a success: ${DZ_LINE}"
else
    pass "D: an all-zero payload does NOT close ok (it stays unmeasured)"
fi

# --- E: the declaration --------------------------------------------------
E_LINE="$(line_for declared_noop)"
if grep -q 'status=ok' <<< "$E_LINE" \
   && grep -q 'measured=declared-none' <<< "$E_LINE" \
   && grep -q 'reason=' <<< "$E_LINE"; then
    pass "E: a declared no-op closes ok, stamped declared-none with its reason"
else
    fail "E: the explicit declaration did not reach the wire: ${E_LINE:-<none>}"
fi
if [ "$(printf '%s' "$B_LINE" | tr '\t' '\n' | grep '^measured=')" \
   = "$(printf '%s' "$E_LINE" | tr '\t' '\n' | grep '^measured=')" ]; then
    fail "E: a declared no-op is indistinguishable from a real measurement on the wire"
else
    pass "E: declared-none is distinguishable from a real measurement on the wire"
fi

# --- E2: the reason is a PUBLIC marker field, so it may not carry PII -----
#
# `reason=` rides the durable log unredacted (it is on the allowlist in
# _ostler_marker_field_is_public), so its producer constrains it to letters
# only. A call site that pastes something from the customer's machine must
# degrade to a poorer reason, never to a leak.
#
# THE HOSTILE INPUT IS COMPOSED AT RUNTIME, not written as a literal.
# ci-pii-shape-scan matches on SHAPE, not on a list of known values, and it is
# right to: a fixture that spells a home path is indistinguishable from one
# that leaked it. Its own remedy line says to compose from parts. The runtime
# string is byte-identical to the literal, so the assertion loses nothing.
_SL="$(printf '\057')"                    # solidus
_AT="$(printf '\100')"                    # commercial at
_DG="$(seq 0 9 | tr -d '\n')"             # ten digits, no phone shape in source
PII_INPUT="see someone${_AT}example.invalid ${_SL}Users${_SL}someone ${_DG}"

# CONTROL ON THE INPUT ITSELF. If the composition above ever produced a benign
# string, the assertion below would pass while testing nothing. The hostile
# input must actually be hostile before it is used.
if grep -q "$_AT" <<< "$PII_INPUT" \
   && grep -q "$_SL" <<< "$PII_INPUT" \
   && grep -qE '[0-9]' <<< "$PII_INPUT"; then
    pass "E2 input control: the hostile reason really does carry an at-sign, a solidus and digits"
else
    fail "E2 input control: the composed input is benign, so the assertion below would prove nothing: [${PII_INPUT}]"
fi

HOSTILE="$(OSTLER_GUI=1 _T_EMITTER="$EMITTER" _T_PII="$PII_INPUT" bash -c '
    . "${_T_EMITTER}"
    gui_step_begin pii "P"
    gui_step_measures_nothing "${_T_PII}"
    gui_step_end' 2>&1 | grep 'STEP_END' | tail -n 1)"
# The REASON FIELD ONLY. Testing the whole line matches `elapsed_s=0` and
# reports a leak that is not there -- a predicate wider than its subject.
HOSTILE_REASON="$(printf '%s' "$HOSTILE" | tr '\t' '\n' | grep '^reason=' | sed 's/^reason=//')"
if [ -z "$HOSTILE_REASON" ]; then
    fail "E2: no reason field on the wire at all: ${HOSTILE}"
elif grep -qE '@|/|[0-9]' <<< "$HOSTILE_REASON"; then
    fail "E2: the reason field passed an address, a path or digits through: [${HOSTILE_REASON}]"
else
    pass "E2: the reason field cannot carry an address, a path or digits [${HOSTILE_REASON}]"
fi
# CONTROL: the same extraction on a BENIGN reason must return the text, so
# the assertion above cannot pass by the extraction returning nothing.
BENIGN_REASON="$(printf '%s' "$E_LINE" | tr '\t' '\n' | grep '^reason=' | sed 's/^reason=//')"
if [ -n "$BENIGN_REASON" ]; then
    pass "E2 control: the extraction really reads the field [${BENIGN_REASON}]"
else
    fail "E2 control: the extraction returns nothing even for a benign reason, so E2 proved nothing"
fi

# --- F: no laundering ----------------------------------------------------
F_LINE="$(line_for declare_after_error)"
if grep -q 'status=error' <<< "$F_LINE"; then
    pass "F: a declaration cannot launder a recorded error into ok"
else
    fail "F: a declaration overwrote a recorded error: ${F_LINE:-<none>}"
fi

F2_LINE="$(line_for forced_ok)"
if grep -q 'status=ok' <<< "$F2_LINE"; then
    fail "F: an explicit \`gui_step_end ok\` asserted success over an unmeasured step: ${F2_LINE}"
else
    pass "F: an explicit \`gui_step_end ok\` cannot assert success over an unmeasured step"
fi

# --- G: the debt meter ---------------------------------------------------
DONE_LINE="$(grep 'DONE' "$MARKERS" | tail -n 1)"
# records_nothing, hydrate_zero_payload, forced_ok
if grep -q 'unmeasured_steps=3' <<< "$DONE_LINE"; then
    pass "G: the DONE line carries unmeasured_steps=3"
else
    fail "G: expected unmeasured_steps=3 on the DONE line, got: ${DONE_LINE:-<none>}"
fi
# measured_failure + declare_after_error only. If unmeasured counted here,
# install.sh's closing verdict would tell every customer their install broke.
if grep -q 'failed_steps=2' <<< "$DONE_LINE"; then
    pass "G: unmeasured steps are NOT counted as failures (failed_steps=2)"
else
    fail "G: unmeasured steps leaked into failed_steps: ${DONE_LINE:-<none>}"
fi

CLEAN_MARKERS="${WORK}/clean.txt"
OSTLER_GUI=1 _T_EMITTER="$EMITTER" bash <<'CLEAN' 2>"$CLEAN_MARKERS"
set -uo pipefail
# shellcheck source=/dev/null
. "${_T_EMITTER}"
gui_step_begin "all_measured" "The only step, and it measures"
true; gui_step_record_rc $?
gui_step_end
gui_done ok
CLEAN
CLEAN_DONE="$(grep 'DONE' "$CLEAN_MARKERS" | tail -n 1)"
if grep -q 'unmeasured_steps=0' <<< "$CLEAN_DONE"; then
    pass "G: a fully measured run PRINTS unmeasured_steps=0, so zero is not an unreporting build"
else
    fail "G: expected unmeasured_steps=0 on a fully measured run, got: ${CLEAN_DONE:-<none>}"
fi

# --- H: mutation ---------------------------------------------------------
#
# Put the default back to `ok` -- the pre-fix shape, and nothing else --
# and A's input must go back to lying. If it does not, this test is green
# for some reason other than the fix.
MUT="${WORK}/emitter.mutated.sh"
sed -e 's/^__OSTLER_STEP_STATUS="unmeasured"$/__OSTLER_STEP_STATUS="ok"/' \
    -e 's/    __OSTLER_STEP_STATUS="unmeasured"/    __OSTLER_STEP_STATUS="ok"/' \
    -e 's/local status="${__OSTLER_STEP_STATUS:-unmeasured}"/local status="${__OSTLER_STEP_STATUS:-ok}"/' \
    "$EMITTER" > "$MUT"

if ! bash -n "$MUT"; then
    fail "H: the mutated emitter does not parse; the mutation arm measured nothing"
elif ! grep -q '__OSTLER_STEP_STATUS="ok"' "$MUT"; then
    fail "H: the mutation did not apply. A mutant that never applied looks exactly like one that was not caught."
else
    MUT_MARKERS="${WORK}/mutated.txt"
    run_scenario "$MUT" "$MUT_MARKERS"
    MUT_LINE="$(grep 'id=records_nothing	' "$MUT_MARKERS" | grep 'STEP_END' | tail -n 1)"
    if [ -z "$MUT_LINE" ]; then
        fail "H: the mutated run emitted no STEP_END for records_nothing; the arm proved nothing"
    elif grep -q 'status=ok' <<< "$MUT_LINE"; then
        pass "H: with the default back to \`ok\`, the defect returns -- this test sees the fix"
    else
        fail "H: the pre-fix default did NOT reproduce the defect, so A is green for another reason: ${MUT_LINE}"
    fi
fi

printf '\n'
if [ "$FAILURES" -eq 0 ]; then
    printf 'PASS: a step that measured nothing cannot report ok (%s + %s)\n' "$EMITTER" "$INSTALL_SH"
    exit 0
fi
printf 'FAIL: %s assertion(s) failed against %s + %s\n' "$FAILURES" "$EMITTER" "$INSTALL_SH"
exit 1
