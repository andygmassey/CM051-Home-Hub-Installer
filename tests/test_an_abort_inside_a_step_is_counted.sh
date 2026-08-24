#!/usr/bin/env bash
# The terminal tally must account for the step the run died in (#873)
# ===================================================================
#
# THE INPUT THIS TEST REPLAYS
#
# A v1.0.43 run terminated with a line of this shape:
#
#     #OSTLER DONE status=fail failed_steps=0
#
# The run aborted INSIDE a step. `status=fail` and `failed_steps=0` cannot
# both be describing the same run: a run that failed had at least one step
# that did not do its job, and here it was the one that was open when the
# script died. A support engineer greps that one line -- which is exactly
# what #839 built it for -- and learns that nothing failed.
#
# WHY #839 DID NOT COVER THIS, WHICH IS THE INTERESTING PART
#
# #839 made the per-step STEP_END honest: gui_step_end reads the status
# accumulated from the step's own children, and it is the ONLY place that
# increments __OSTLER_FAILED_STEPS. That is correct for every step that is
# CLOSED. An abort never closes its step:
#
#     fail()            install.sh   gui_done fail   <- no gui_step_end
#     _ostler_on_err()  install.sh   gui_done fail   <- no gui_step_end
#     EXIT backstop     install.sh   gui_done fail   <- no gui_step_end
#
# so the counter the DONE line reads is still at whatever the CLOSED steps
# left it at, which on an early abort is zero.
#
# The two guards that should have met here sat on different surfaces and
# neither could see the seam:
#
#   * tests/test_step_end_does_not_report_a_timed_out_step_as_ok.sh drives
#     the real counter, but every one of its steps is closed by progress()
#     or gui_step_end. It never aborts.
#   * tests/test_err_trap_emits_done_fail.sh drives all three abort paths,
#     but STUBS gui_done in its own PREAMBLE, so the real counter -- and
#     therefore failed_steps -- is not present in that harness at all.
#
# This test is the intersection: REAL abort paths extracted from
# install.sh, driving the REAL lib/progress_emitter.sh.
#
# WHAT THIS TEST ASSERTS
#
#   A1  ORIGINAL FAILING INPUT, ERR-trap arm. A command failure under
#       `set -e` with a step open must produce a DONE that names a non-zero
#       failed_steps, and a STEP_END for the step that died.
#   A2  ORIGINAL FAILING INPUT, EXIT-backstop arm. Same, for the `set -u`
#       death that skips the ERR trap on bash 3.2.
#   A3  ORIGINAL FAILING INPUT, explicit-fail arm. Same, for
#       fail_with_code, which is how an anticipated failure exits.
#   B   POSITIVE CONTROL, MUST BE PRESENT. A clean run still ends
#       `status=ok failed_steps=0`. Without this, a "fix" that stamps
#       failed_steps=1 unconditionally passes A1-A3, and the zero would
#       stop meaning anything. It also proves the emitter is alive, so the
#       A assertions are not passing against a dead wire.
#   C   NO INCOHERENT STEP_END. The STEP_END the abort produces must not
#       carry a non-ok status with rc=0 -- "it failed with exit code
#       success" is the same class of nonsense one level down.
#   D   NO SPURIOUS FAILURE. A terminal marker emitted with NO step open
#       (a pre-step exit, a cancel) must not invent a failed step.
#
# The abort handlers and fail() are extracted from install.sh at run time
# and the emitter is sourced from lib/, so this cannot pass against a copy
# of either.
#
# Synthetic only. No real names, paths or transcripts.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
EMITTER="${REPO_ROOT}/lib/progress_emitter.sh"

FAILURES=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
fatal() { printf 'FATAL: %s\n' "$1" >&2; exit 1; }

for f in "$INSTALL_SH" "$EMITTER"; do
    [ -f "$f" ] || fatal "expected file not found: $f"
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/abort-tally.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ── Extract the REAL abort machinery from install.sh ───────────────────
#
# Whitespace-tolerant: install.sh writes `fail()  {` with two spaces, and
# an extractor that demands one silently returns nothing -- which would
# make every assertion below a measurement of the extractor.
extract_fn() {
    awk -v fn="$1" '
        $0 ~ "^"fn"\\(\\)[[:space:]]*\\{" { inside = 1 }
        inside { print }
        inside && /^\}/ { exit }
    ' "$2"
}

extract_fn fail            "$INSTALL_SH" > "${WORK}/fail.sh"
extract_fn fail_with_code  "$INSTALL_SH" > "${WORK}/fail_with_code.sh"
extract_fn progress        "$INSTALL_SH" > "${WORK}/progress.sh"

ERR_HANDLER="$(awk '/OSTLER_ERR_TRAP_BEGIN/{c=1} c{print} /OSTLER_ERR_TRAP_END/{c=0}' "$INSTALL_SH")"
BACKSTOP="$(awk '/OSTLER_EXIT_BACKSTOP_BEGIN/{c=1; next} /OSTLER_EXIT_BACKSTOP_END/{c=0} c{print}' "$INSTALL_SH")"

# Trailing newline matters: `cat`-ing a file that does not end in one
# glues the next assembled line onto the last extracted one and the
# harness stops parsing, which reads as "the code is broken" when it is
# the extractor that is.
printf '%s\n' "$ERR_HANDLER" > "${WORK}/err_handler.sh"
printf '%s\n' "$BACKSTOP"    > "${WORK}/backstop.sh"

for f in fail fail_with_code progress err_handler backstop; do
    [ -s "${WORK}/${f}.sh" ] || fatal "could not extract ${f} from install.sh. The test is measuring nothing."
done
grep -q '_ostler_on_err' "${WORK}/err_handler.sh" || fatal "the extracted ERR handler does not contain _ostler_on_err."
grep -q 'OSTLER_DONE_EMITTED' "${WORK}/backstop.sh" || fatal "the extracted EXIT backstop does not read OSTLER_DONE_EMITTED."
bash -n "${WORK}/fail.sh" || fatal "extracted fail() does not parse. Extraction is broken, not the code."
bash -n "${WORK}/progress.sh" || fatal "extracted progress() does not parse."
printf 'Harness: extracted fail, fail_with_code, progress, the ERR trap and the EXIT backstop from install.sh.\n\n'

# ── One case = one real bash process, real emitter, real handlers ──────
#
# Markers go to stderr because OSTLER_MARKER_FD is deliberately left unset
# (gui_emit's documented fallback), so stderr IS the wire here.
run_case() {
    # run_case <name> <body-line>...
    local name="$1"; shift
    local script="${WORK}/${name}.sh"
    {
        echo '#!/usr/bin/env bash'
        echo 'set -Eeuo pipefail'
        # install.sh globals the extracted code reads.
        echo 'RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; DIM=""; NC=""'
        echo 'TOTAL_STEPS=4'
        echo 'CURRENT_STEP=0'
        echo 'PHASE3_START=$(date +%s)'
        echo 'OSTLER_LAST_ERROR_CODE=""'
        echo 'OSTLER_DONE_EMITTED=""'
        echo 'OSTLER_PRELAUNCH_PROMOTED="true"'
        echo ". \"${EMITTER}\""
        echo ". \"${WORK}/progress.sh\""
        echo ". \"${WORK}/fail.sh\""
        echo ". \"${WORK}/fail_with_code.sh\""
        cat "${WORK}/err_handler.sh"
        echo ''
        echo 'composite_cleanup() {'
        cat "${WORK}/backstop.sh"
        echo '  :'
        echo '}'
        echo 'trap composite_cleanup EXIT'
        echo "trap '_ostler_on_err \$? \$LINENO \"\$BASH_COMMAND\"' ERR"
        printf '%s\n' "$@"
    } > "$script"
    bash -n "$script" || fatal "${name}: the assembled harness does not parse."
    OSTLER_GUI=1 bash "$script" >/dev/null 2>"${WORK}/${name}.markers" || true
}

marker() {
    # marker <case> <EVENT>  -- last matching marker line
    grep -E "#OSTLER.*[[:space:]]$2([[:space:]]|$)" "${WORK}/${1}.markers" | tail -n 1
}
field() {
    # field <line> <key>
    printf '%s' "$1" | tr '\t' '\n' | grep "^$2=" | head -n 1 | cut -d= -f2
}

# ── B: the positive control runs FIRST ─────────────────────────────────
# A clean run. If this does not end failed_steps=0, the counter is being
# stamped and A1-A3 prove nothing.
run_case b \
    'progress "Setting up conversation memory" "cm048_setup"' \
    'true' \
    'gui_step_end' \
    'gui_done ok'

B_DONE="$(marker b DONE)"
if [ -z "$B_DONE" ]; then
    fail "B control: no DONE marker at all. The emitter is dead, so every assertion below is worthless."
elif [ "$(field "$B_DONE" failed_steps)" = "0" ] && [ "$(field "$B_DONE" status)" = "ok" ]; then
    pass "B control: a clean run still ends status=ok failed_steps=0"
else
    fail "B control: a clean run did not end status=ok failed_steps=0, it ended: ${B_DONE}"
fi

# ── A1: ERR-trap arm -- a command failure under set -e, step open ──────
#
# The child returns 42, not 1. gui_step_end falls back to rc=1 when no rc
# was recorded, so a fixture that fails with 1 cannot tell a MEASURED code
# from the CONVENTION and would score identically against a fix that
# threaded nothing. 42 is a code only the real
# `gui_step_record_rc "$exit_code"` in _ostler_on_err can produce.
run_case a1 \
    'progress "Encrypting your databases" "encrypt_db"' \
    'boom() { return 42; }' \
    'boom' \
    'gui_done ok'

# ── A2: EXIT-backstop arm -- a set -u death, step open ─────────────────
run_case a2 \
    'progress "Indexing your people for search" "hydrate_people"' \
    'boom() { printf "%s" "${OSTLER_TEST_DEFINITELY_UNSET_VAR}"; }' \
    'boom' \
    'gui_done ok'

# ── A3: explicit-fail arm -- fail_with_code, step open ─────────────────
run_case a3 \
    'progress "Starting the Doctor" "doctor_setup"' \
    'fail_with_code "ERR-17-DOCTOR-TESTONLY" "synthetic failure"'

for case_name in a1 a2 a3; do
    case "$case_name" in
        a1) label="A1 ERR trap";        step="encrypt_db"     ;;
        a2) label="A2 EXIT backstop";   step="hydrate_people" ;;
        a3) label="A3 explicit fail";   step="doctor_setup"   ;;
    esac

    D_LINE="$(marker "$case_name" DONE)"
    if [ -z "$D_LINE" ]; then
        fail "${label}: no DONE marker was emitted at all."
        continue
    fi

    D_STATUS="$(field "$D_LINE" status)"
    D_COUNT="$(field "$D_LINE" failed_steps)"

    if [ "$D_STATUS" != "fail" ]; then
        fail "${label}: expected status=fail on the terminal line, got: ${D_LINE}"
    fi
    if [ -z "$D_COUNT" ]; then
        fail "${label}: the DONE line carries no failed_steps field at all: ${D_LINE}"
    elif [ "$D_COUNT" = "0" ]; then
        fail "${label}: DONE status=fail failed_steps=0 -- the run aborted inside step '${step}' and the tally says nothing failed. This is the #873 defect: ${D_LINE}"
    else
        pass "${label}: DONE status=fail carries failed_steps=${D_COUNT}, not 0"
    fi

    # The step that died must be NAMED, not just counted. A number with no
    # step id is barely more use to support than a zero.
    S_LINE="$(grep -E "#OSTLER.*STEP_END.*[[:space:]]id=${step}([[:space:]]|$)" "${WORK}/${case_name}.markers" | tail -n 1)"
    if [ -z "$S_LINE" ]; then
        fail "${label}: no STEP_END for '${step}', so the terminal report never names the step the run died in."
    else
        S_STATUS="$(field "$S_LINE" status)"
        S_RC="$(field "$S_LINE" rc)"
        if [ "$S_STATUS" = "ok" ]; then
            fail "${label}: the step the run died in closed status=ok: ${S_LINE}"
        else
            pass "${label}: the step the run died in is named and closed status=${S_STATUS}"
        fi
        # --- C: no incoherent STEP_END --------------------------------
        if [ "$S_STATUS" != "ok" ] && { [ -z "$S_RC" ] || [ "$S_RC" = "0" ]; }; then
            fail "C/${label}: STEP_END says status=${S_STATUS} with rc=${S_RC:-<absent>} -- a failure whose exit code is success: ${S_LINE}"
        else
            pass "C/${label}: the STEP_END carries a non-zero rc (${S_RC}) alongside status=${S_STATUS}"
        fi

        # --- A1 only: the rc must be MEASURED, not the fallback --------
        if [ "$case_name" = "a1" ]; then
            if [ "$S_RC" = "42" ]; then
                pass "A1: the rc on the STEP_END is 42, the code the child actually returned -- so it was threaded, not defaulted"
            else
                fail "A1: expected rc=42 (the child's real code) on the STEP_END, got rc=${S_RC:-<absent>}. rc=1 here would mean the fallback fired and nothing was measured: ${S_LINE}"
            fi
        fi
    fi
done

# ── D: no spurious failure when nothing was open ───────────────────────
# A terminal fail with NO step open is a real, distinct state (the run died
# before any step began). It must not be laundered into an invented step.
run_case d \
    'gui_done fail'

D_DONE="$(marker d DONE)"
D_STEPEND="$(grep -cE '#OSTLER.*STEP_END' "${WORK}/d.markers")"
if [ "$(field "$D_DONE" failed_steps)" = "0" ] && [ "$D_STEPEND" = "0" ]; then
    pass "D: a terminal fail with no step open invents neither a STEP_END nor a count"
else
    fail "D: a terminal fail with no step open produced ${D_STEPEND} STEP_END line(s) and: ${D_DONE}"
fi

printf '\nMarkers produced by each case:\n'
for case_name in b a1 a2 a3 d; do
    printf '  [%s]\n' "$case_name"
    grep -E '#OSTLER.*(STEP_END|DONE)' "${WORK}/${case_name}.markers" | sed 's/^/      /'
done

printf '\n'
if [ "$FAILURES" -eq 0 ]; then
    printf 'PASS: an abort inside a step is counted by the terminal tally (%s + %s)\n' "$INSTALL_SH" "$EMITTER"
    exit 0
fi
printf 'FAIL: %s assertion(s) failed against %s + %s\n' "$FAILURES" "$INSTALL_SH" "$EMITTER"
exit 1
