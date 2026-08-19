#!/usr/bin/env bash
#
# tests/test_err_trap_emits_done_fail.sh
#
# Regression test for the CX-454 (task #454) mid-script-death reporting.
#
# What this guards
# ----------------
# When install.sh dies partway through, the GUI must report a real
# failure -- never a masked green "all set" over a half-installed Hub,
# and ideally with the failing STEP + a stable code for support.
#
# VERIFIED bash behaviour this fix is built around (3.2.57, the system
# bash on the customer Mac -- both /bin/bash and PATH):
#   * A `set -u` unbound-variable abort (the most common death shape --
#     CX-18/52/95/98 were all this) does NOT fire the ERR trap and can
#     mask the process exit code to 0.
#   * A genuine command failure (e.g. `false`) under `set -e` DOES fire
#     the ERR trap.
#   * The EXIT trap fires in BOTH cases.
# So the fix uses two handlers:
#   1. ERR trap (_ostler_on_err): the command-failure class, with the
#      precise failing line in the code (ERR-99-INSTALL-ABORT-L<line>).
#   2. EXIT backstop (top of composite_cleanup): the load-bearing net.
#      If a step had started and no terminal DONE marker was emitted, it
#      emits a synthetic DONE-fail naming the step
#      (ERR-99-INSTALL-ABORT-<step>). This is what catches the
#      unbound-var / exit-code-masked class the ERR trap cannot see.
# A single sentinel, OSTLER_DONE_EMITTED (set inside the real gui_done /
# gui_cancelled), guarantees exactly one terminal marker.
#
# Axes:
#   A. Static contract.
#   B1. Command-failure death -> ERR trap emits DONE-fail with a line code.
#   B2. set -u death -> EXIT backstop emits DONE-fail with the step code
#       (and never a masked success), proving the load-bearing path.
#   C. Clean success emits one DONE-ok and the backstop stays silent.
#   D. An exit before any step begins never emits a spurious failure.
#
# Synthetic only. No real names, numbers, paths, or transcripts.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${REPO_ROOT}/install.sh"
EMITTER="${REPO_ROOT}/lib/progress_emitter.sh"

fail_test() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$INSTALL_SCRIPT" ]] || fail_test "install.sh not found at $INSTALL_SCRIPT"
[[ -f "$EMITTER" ]] || fail_test "lib/progress_emitter.sh not found at $EMITTER"

bash -n "$INSTALL_SCRIPT" || fail_test "install.sh fails bash -n parse check"
bash -n "$EMITTER" || fail_test "progress_emitter.sh fails bash -n parse check"
echo "PASS: install.sh + progress_emitter.sh parse"

# ── Axis A: static contract ──────────────────────────────────────
grep -Eq '^set -[A-Za-z]*E[A-Za-z]* |^set -o errtrace' "$INSTALL_SCRIPT" \
    || fail_test "errtrace (set -E / set -o errtrace) not enabled"
echo "PASS: errtrace enabled"

grep -qE '^_ostler_on_err\(\)' "$INSTALL_SCRIPT" || fail_test "_ostler_on_err() not defined"
grep -qE "trap '_ostler_on_err .*' ERR" "$INSTALL_SCRIPT" || fail_test "ERR trap not registered"
echo "PASS: ERR trap defined + registered"

grep -q 'OSTLER_EXIT_BACKSTOP_BEGIN' "$INSTALL_SCRIPT" || fail_test "EXIT backstop block not present in composite_cleanup"
echo "PASS: EXIT backstop present"

# The single terminal sentinel must be set inside the real gui_done AND
# gui_cancelled, or the backstop can false-trigger on success/cancel.
awk '/^gui_done\(\)/{c=1} c{print} /^}/{if(c)c=0}' "$EMITTER" | grep -q 'OSTLER_DONE_EMITTED=1' \
    || fail_test "gui_done does not set OSTLER_DONE_EMITTED"
awk '/^gui_cancelled\(\)/{c=1} c{print} /^}/{if(c)c=0}' "$EMITTER" | grep -q 'OSTLER_DONE_EMITTED=1' \
    || fail_test "gui_cancelled does not set OSTLER_DONE_EMITTED"
echo "PASS: OSTLER_DONE_EMITTED set at both terminal chokepoints"

grep -q 'ERR-99-INSTALL-ABORT' "$INSTALL_SCRIPT" || fail_test "synthetic code ERR-99-INSTALL-ABORT not present"
echo "PASS: synthetic code shape present"

# ── Extract the REAL handlers so the behaviour test cannot drift ──
ERR_HANDLER="$(awk '/OSTLER_ERR_TRAP_BEGIN/{c=1} c{print} /OSTLER_ERR_TRAP_END/{c=0}' "$INSTALL_SCRIPT")"
grep -q '_ostler_on_err' <<<"$ERR_HANDLER" || fail_test "could not extract _ostler_on_err between markers"
BACKSTOP="$(awk '/OSTLER_EXIT_BACKSTOP_BEGIN/{c=1; next} /OSTLER_EXIT_BACKSTOP_END/{c=0} c{print}' "$INSTALL_SCRIPT")"
grep -q 'OSTLER_DONE_EMITTED' <<<"$BACKSTOP" || fail_test "could not extract EXIT backstop between markers"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Shared harness preamble: faithful stubs that mirror the real lib.
PREAMBLE='
gui_log() { :; }
gui_done() {
    local status="${1:-ok}"
    OSTLER_DONE_EMITTED=1
    if [[ -n "${OSTLER_LAST_ERROR_CODE:-}" ]]; then
        printf "DONE status=%s code=%s\n" "$status" "${OSTLER_LAST_ERROR_CODE}" >>"$CAP"
    else
        printf "DONE status=%s\n" "$status" >>"$CAP"
    fi
}
'

run_case() {
    # run_case <name> <CAP> <body...>
    local name="$1" cap="$2"; shift 2
    : >"$cap"
    {
        echo '#!/usr/bin/env bash'
        echo 'set -Eeuo pipefail'
        echo "CAP=\"$cap\""
        echo 'OSTLER_LAST_ERROR_CODE=""'
        echo 'OSTLER_DONE_EMITTED=""'
        echo "$PREAMBLE"
        echo "$ERR_HANDLER"
        # Assemble a composite_cleanup whose body is the REAL backstop.
        echo 'composite_cleanup() {'
        echo "$BACKSTOP"
        echo '  :'
        echo '}'
        echo 'trap composite_cleanup EXIT'
        echo "trap '_ostler_on_err \$? \$LINENO \"\$BASH_COMMAND\"' ERR"
        printf '%s\n' "$@"
    } >"$WORK/harness.sh"
    # errexit is kept OFF for the whole behavioural section (these
    # harnesses deliberately drive failing scripts); do not toggle it
    # here or a later `grep -c` with no match (exit 1) would abort us.
    bash "$WORK/harness.sh" >/dev/null 2>&1 || true
}
set +e  # cases drive failing scripts deliberately

# ── Axis B1: command-failure death -> ERR trap, line code ────────
run_case b1 "$WORK/b1.txt" \
    '__OSTLER_STEP_ID="config_save"' \
    'boom() { false; }' \
    'boom' \
    'printf "REACHED\n" >>"$CAP"'
CAP="$WORK/b1.txt"
[[ "$(grep -c '^DONE ' "$CAP")" == "1" ]] || fail_test "B1: expected one DONE, got:
$(cat "$CAP")"
grep -q '^DONE status=fail ' "$CAP" || fail_test "B1: no DONE status=fail:
$(cat "$CAP")"
grep -qE 'code=ERR-99-INSTALL-ABORT-L[0-9]+' "$CAP" || fail_test "B1: missing line code ERR-99-INSTALL-ABORT-L<line>:
$(cat "$CAP")"
grep -q 'status=ok' "$CAP" && fail_test "B1: a success marker leaked:
$(cat "$CAP")"
echo "PASS: B1 command-failure -> ERR trap emits DONE-fail with line code (no success leak)"

# ── Axis B2: set -u death -> EXIT backstop, step code ────────────
run_case b2 "$WORK/b2.txt" \
    '__OSTLER_STEP_ID="encrypt_db"' \
    'boom() { printf "%s" "${OSTLER_TEST_DEFINITELY_UNSET_VAR}"; }' \
    'boom' \
    'printf "REACHED\n" >>"$CAP"'
CAP="$WORK/b2.txt"
[[ "$(grep -c '^DONE ' "$CAP")" == "1" ]] || fail_test "B2: expected exactly one DONE (the EXIT backstop), got:
$(cat "$CAP")"
grep -q '^DONE status=fail ' "$CAP" || fail_test "B2: backstop did not emit DONE status=fail on a set -u death:
$(cat "$CAP")"
grep -q 'code=ERR-99-INSTALL-ABORT-encrypt_db' "$CAP" || fail_test "B2: backstop did not name the failing step in the code:
$(cat "$CAP")"
grep -q 'status=ok' "$CAP" && fail_test "B2: a masked success marker leaked on a set -u death (the meta-bug):
$(cat "$CAP")"
grep -q 'REACHED' "$CAP" && fail_test "B2: execution continued past the abort"
echo "PASS: B2 set -u death -> EXIT backstop emits DONE-fail with step code (load-bearing path proven on bash $(bash --version | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1))"

# ── Axis C: clean success -> one DONE-ok, backstop silent ────────
run_case c "$WORK/c.txt" \
    '__OSTLER_STEP_ID="health_check"' \
    'gui_done ok'
CAP="$WORK/c.txt"
[[ "$(grep -c '^DONE ' "$CAP")" == "1" ]] || fail_test "C: expected exactly one DONE, got:
$(cat "$CAP")"
grep -q '^DONE status=ok' "$CAP" || fail_test "C: success marker missing:
$(cat "$CAP")"
grep -q 'status=fail' "$CAP" && fail_test "C: backstop spuriously failed a clean success:
$(cat "$CAP")"
echo "PASS: C clean success emits one DONE-ok; backstop stays silent"

# ── Axis D: exit before any step -> no spurious failure ──────────
run_case d "$WORK/d.txt" \
    '__OSTLER_STEP_ID=""' \
    'exit 0'
CAP="$WORK/d.txt"
d_done="$(grep -c '^DONE ' "$CAP" 2>/dev/null)"; d_done="${d_done:-0}"
[[ "$d_done" == "0" ]] || fail_test "D: a pre-step exit emitted a spurious DONE:
$(cat "$CAP")"
echo "PASS: D pre-step exit (no step id) emits no spurious failure marker"

echo "ALL PASS: test_err_trap_emits_done_fail.sh"
