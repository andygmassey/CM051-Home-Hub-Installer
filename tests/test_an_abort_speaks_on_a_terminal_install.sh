#!/usr/bin/env bash
# An abort must SAY SO on a terminal install (#561)
# ================================================
#
# THE INPUT THIS TEST REPLAYS
#
# The v1.0.50 box walk, 2026-08-29. install.sh reached 24%, entered the
# #1208 port preflight, and exited rc=1 having printed NOTHING: no [fail],
# no ERR- code, no diagnostic of any kind, on the pty transcript and in
# ~/.ostler/logs/install.log alike. On the documented `curl | bash` path a
# customer watches the progress bar stop and is told nothing whatsoever.
#
# THE MECHANISM, MEASURED AT SOURCE
#
# install.sh has exactly three abort paths, and progress_emitter.sh's own
# gui_done() comment enumerates them:
#
#     fail()            gui_done fail    prints on a TTY (install.sh fail())
#     _ostler_on_err()  gui_done fail    WAS SILENT
#     EXIT backstop     gui_done fail    WAS SILENT
#
# The latter two spoke ONLY through gui_log and gui_done, and both are hard
# no-ops whenever OSTLER_GUI != 1 -- gui_emit() and gui_log() in
# lib/progress_emitter.sh each open with
#
#     [[ "${OSTLER_GUI:-0}" != "1" ]] && return 0
#
# and gui_done reaches nothing but gui_emit. Where the emitter is absent
# from disk entirely, install.sh's TTY sourcing arm redefines the same three
# as literal `{ :; }`. Both arms converge on silence. install.sh runs under
# `set -euo pipefail`, so ANY unhandled non-zero exit after that point took
# the ERR trap and died mute.
#
# WHAT THIS TEST ASSERTS
#
#   A1  ORIGINAL FAILING INPUT, ERR-trap arm. A command failure under
#       `set -e` with OSTLER_GUI UNSET must put a diagnostic naming
#       ERR-99-INSTALL-ABORT on the terminal.
#   A2  ORIGINAL FAILING INPUT, set -u arm. A `set -u` death must do the
#       same, via whichever of the two handlers catches it.
#   B   NEGATIVE CONTROL, GUI UNCHANGED. With OSTLER_GUI=1 the new TTY
#       lines must NOT fire. The GUI's single source of truth is the DONE
#       marker, and duplicating it on stderr is a regression there.
#   C   MUTATION. With the fix stripped back out of the lifted blocks, A1
#       must FAIL. Without this the test could be passing on bash's own
#       noise rather than on our diagnostic.
#   D   HARNESS CONTROL, INDEPENDENT OF gui_active. A plain `>&2` write
#       from the child must reach the captured file. A1/A2 and this control
#       must not be able to fail for the same reason: A1/A2 go through
#       `gui_active ||`, this one does not, so a broken gui_active cannot
#       silence both and read as a clean result.
#
# ASSERT ON THE CODE STRING, NEVER ON "stderr is non-empty". A `set -u`
# death makes bash itself write "unbound variable" to stderr, so an
# emptiness test would pass in A2 with the fix entirely absent. Only
# ERR-99-INSTALL-ABORT is ours.
#
# The handlers are lifted from install.sh at run time and the emitter is
# sourced from lib/, so this cannot pass against a copy of either.
#
# Three outcomes, three exit codes: 0 pass, 1 fail, 2 CANNOT-RUN. A check
# that could not run has not passed.
#
# Synthetic only. No real names, paths or transcripts.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
EMITTER="${REPO_ROOT}/lib/progress_emitter.sh"

PASS=0; FAIL=0; CANT=0
pass() { printf '  PASS         %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL         %s\n' "$1"; FAIL=$((FAIL + 1)); }
cant() { printf '  [CANNOT-RUN] %s\n' "$1"; CANT=$((CANT + 1)); }

finish() {
    printf '\n  passed=%s failed=%s cannot-run=%s\n' "$PASS" "$FAIL" "$CANT"
    [ "$FAIL" -eq 0 ] || { printf 'FAIL: an abort can still be silent on a terminal install.\n'; exit 1; }
    [ "$CANT" -eq 0 ] || { printf 'CANNOT-RUN: this examined less than it claims. Not a clean result.\n'; exit 2; }
    printf 'PASS: every abort path speaks on a terminal install (%s + %s)\n' "$INSTALL_SH" "$EMITTER"
    exit 0
}

for f in "$INSTALL_SH" "$EMITTER"; do
    if [ ! -f "$f" ]; then
        cant "expected file not found: $f"
        finish
    fi
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/abort-speaks.XXXXXX")" || { cant "mktemp failed"; finish; }
trap 'rm -rf "$WORK"' EXIT

# ── Lift the REAL abort machinery out of install.sh ────────────────────
#
# Same sentinel-bounded extraction tests/test_an_abort_inside_a_step_is_counted.sh
# uses. HARD BOUNDED: a range that runs away takes the whole rest of the
# installer with it, and the arms below then "pass" while executing
# thousands of unrelated lines. That has happened. A lift longer than the
# bound is CANNOT-RUN, never a pass.
LIFT_MAX=140

ERR_HANDLER="$(awk '/OSTLER_ERR_TRAP_BEGIN/{c=1} c{print} /OSTLER_ERR_TRAP_END/{c=0}' "$INSTALL_SH")"
BACKSTOP="$(awk '/OSTLER_EXIT_BACKSTOP_BEGIN/{c=1; next} /OSTLER_EXIT_BACKSTOP_END/{c=0} c{print}' "$INSTALL_SH")"

printf '%s\n' "$ERR_HANDLER" > "${WORK}/err_handler.sh"
printf '%s\n' "$BACKSTOP"    > "${WORK}/backstop.sh"

for f in err_handler backstop; do
    if [ ! -s "${WORK}/${f}.sh" ]; then
        cant "could not lift ${f} from install.sh -- the sentinels moved or vanished. This test is measuring nothing."
        finish
    fi
    n="$(wc -l < "${WORK}/${f}.sh" | tr -d ' ')"
    if [ "$n" -gt "$LIFT_MAX" ]; then
        cant "the ${f} lift took ${n} lines (bound ${LIFT_MAX}). The range ran away; any verdict from it would be about the wrong code."
        finish
    fi
    printf '  lifted %-12s %s lines\n' "$f" "$n"
done

if ! grep -q '_ostler_on_err' "${WORK}/err_handler.sh"; then
    cant "the lifted ERR handler does not contain _ostler_on_err."
    finish
fi
if ! grep -q 'OSTLER_DONE_EMITTED' "${WORK}/backstop.sh"; then
    cant "the lifted EXIT backstop does not read OSTLER_DONE_EMITTED."
    finish
fi

# ── The mutant: the fix stripped back out, nothing else changed ────────
#
# Drops each `gui_active || printf` statement INCLUDING its backslash
# continuations. Anything less precise would also delete the gui_log /
# gui_done calls and the mutant would then differ from the original defect
# in more than one way, which is not a mutation, it is a rewrite.
strip_fix() {
    awk '
        /gui_active \|\| printf/ { skipping = 1 }
        skipping {
            if ($0 !~ /\\[[:space:]]*$/) { skipping = 0 }
            next
        }
        { print }
    ' "$1"
}
strip_fix "${WORK}/err_handler.sh" > "${WORK}/err_handler_mutant.sh"
strip_fix "${WORK}/backstop.sh"    > "${WORK}/backstop_mutant.sh"

# The mutation has to actually remove something, or arm C proves nothing.
if ! diff -q "${WORK}/err_handler.sh" "${WORK}/err_handler_mutant.sh" >/dev/null 2>&1; then
    :
else
    cant "the mutation removed NOTHING from the ERR handler, so arm C cannot discriminate. Either the fix is absent or the stripper no longer matches it."
    finish
fi
if ! bash -n "${WORK}/err_handler_mutant.sh" 2>/dev/null; then
    cant "the mutant ERR handler does not parse -- the stripper cut too much, so a red from arm C would be about the stripper."
    finish
fi

# ── One case = one real bash process, real emitter, real handlers ──────
run_case() {
    # run_case <name> <gui:0|1> <variant:real|mutant> <body-line>...
    local name="$1" gui="$2" variant="$3"; shift 3
    local script="${WORK}/${name}.sh"
    local eh="${WORK}/err_handler.sh" bs="${WORK}/backstop.sh"
    if [ "$variant" = "mutant" ]; then
        eh="${WORK}/err_handler_mutant.sh"; bs="${WORK}/backstop_mutant.sh"
    fi
    {
        echo '#!/usr/bin/env bash'
        echo 'set -Eeuo pipefail'
        # RED/NC are DELIBERATELY LEFT UNDEFINED. install.sh defines them,
        # but the fix guards them as ${RED:-} and this is where that guard
        # is proved: an unbound colour var under set -u would abort the
        # handler before it could speak, silencing the report in exactly
        # the arm meant to observe it.
        echo 'OSTLER_LAST_ERROR_CODE=""'
        echo 'OSTLER_DONE_EMITTED=""'
        echo ". \"${EMITTER}\""
        cat "$eh"
        echo ''
        echo 'composite_cleanup() {'
        cat "$bs"
        echo '  :'
        echo '}'
        echo 'trap composite_cleanup EXIT'
        # D: independent of gui_active, so a broken gui_active cannot
        # silence this line and the subject line together.
        echo 'printf "CONTROL-STDERR-REACHES-THE-FILE\n" >&2'
        echo 'gui_step_begin "graph_databases" "Starting your knowledge graph databases"'
        printf '%s\n' "$@"
    } > "$script"
    if ! bash -n "$script" 2>"${WORK}/${name}.parse"; then
        cant "${name}: the assembled harness does not parse: $(head -1 "${WORK}/${name}.parse")"
        return 1
    fi
    if [ "$gui" = "1" ]; then
        OSTLER_GUI=1 bash "$script" >"${WORK}/${name}.out" 2>"${WORK}/${name}.err"
    else
        env -u OSTLER_GUI bash "$script" >"${WORK}/${name}.out" 2>"${WORK}/${name}.err"
    fi
    return 0
}

OURS='ERR-99-INSTALL-ABORT'

# ── A1: ERR-trap arm, TTY. The original failing input. ─────────────────
if run_case a1 0 real 'boom() { return 1; }' 'boom'; then
    if ! grep -q 'CONTROL-STDERR-REACHES-THE-FILE' "${WORK}/a1.err"; then
        cant "D: the harness cannot observe the child's stderr at all, so a zero in A1/A2 would mean nothing."
    else
        pass "D control: a plain >&2 write from the child reaches the captured file"
        if grep -q "$OURS" "${WORK}/a1.err"; then
            pass "A1: a set -e command failure on a TTY names $(grep -o "${OURS}[A-Za-z0-9-]*" "${WORK}/a1.err" | head -1)"
        else
            fail "A1: a set -e command failure on a TTY printed no ${OURS} diagnostic. This is the #561 defect: the installer died and said nothing."
        fi
    fi
fi

# ── A2: set -u arm, TTY ────────────────────────────────────────────────
if run_case a2 0 real 'boom() { printf "%s" "${OSTLER_TEST_DEFINITELY_UNSET_VAR}"; }' 'boom'; then
    if grep -q "$OURS" "${WORK}/a2.err"; then
        pass "A2: a set -u death on a TTY names ${OURS}"
    else
        fail "A2: a set -u death on a TTY printed no ${OURS} diagnostic. bash's own 'unbound variable' line is NOT our report."
    fi
fi

# ── B: negative control. The GUI must be unchanged. ────────────────────
if run_case b 1 real 'boom() { return 1; }' 'boom'; then
    if grep -q '\[fail\]' "${WORK}/b.err"; then
        fail "B: with OSTLER_GUI=1 the TTY line fired anyway. The GUI keys on the DONE marker; a duplicate on stderr is a regression there."
    else
        pass "B control: with OSTLER_GUI=1 the TTY line stays silent, GUI behaviour unchanged"
    fi
    if grep -q '#OSTLER' "${WORK}/b.err"; then
        pass "B control: the GUI still receives its DONE marker, so B is not passing because the emitter is dead"
    else
        cant "B: no #OSTLER marker under OSTLER_GUI=1 -- the emitter is not wired in this harness, so B's silence proves nothing."
    fi
fi

# ── C: mutation. Strip the fix, A1 must go red. ────────────────────────
if run_case c 0 mutant 'boom() { return 1; }' 'boom'; then
    if grep -q "$OURS" "${WORK}/c.err"; then
        fail "C mutation: with the fix stripped out, the TTY diagnostic appeared anyway. This test is not measuring the fix."
    else
        pass "C mutation: with the fix stripped out the abort goes silent again, so A1 is accusing the real defect"
    fi
fi

printf '\nWhat each arm put on the terminal:\n'
for c in a1 a2 b c; do
    printf '  [%s]\n' "$c"
    if [ -s "${WORK}/${c}.err" ]; then
        sed 's/^/      /' "${WORK}/${c}.err" | head -6
    else
        printf '      <nothing at all>\n'
    fi
done

finish
