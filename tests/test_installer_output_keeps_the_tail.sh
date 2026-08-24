#!/usr/bin/env bash
#
# tests/test_installer_output_keeps_the_tail.sh
#
# v1042-D002 RESIDUAL: the bound was fixed and the diagnostic was still lost.
#
# The 4.27 GB fix (CM051 #993) bounded the accumulator and parsed "\r", and
# tests/test_installer_output_buffer_is_bounded.sh proves it. Then the walk
# registry recorded what it did NOT fix, driven against the merged code:
#
#     1.3 MB with no terminator, then "ERROR: no space left on device\n"
#     -> one line of 65,571 bytes that does not contain the error text
#
# Both notices attached to that line were honest -- bytes truncated, bytes
# dropped -- and the diagnostic was gone anyway. An accurate report of a loss
# is not a substitute for not losing it.
#
# THREE DEFECTS, all in the same family, all measured on 19bd9a09:
#
#   a. `finish()` kept `prefix(maxLineBytes)`. A failing producer names its
#      failure LAST, so the half that was kept was the half that says nothing.
#      This is v1018-D032 in a new file: captured output keeps the head when a
#      hang needs the tail.
#
#   b. `String.prefix(_:)` counts CHARACTERS. On non-ASCII output the "64 KiB"
#      line bound returned 4x that many bytes: 4,128 against a claimed 1,024 in
#      the `wide` case below. ASCII progress output hid it.
#
#   c. The retained partial line was deleted UNREAD at teardown.
#      InstallerCoordinator.handleTermination called stdoutBuffer.reset() and
#      nothing else, so on a hang -- where by definition no terminator ever
#      arrives -- the producer's last words were guaranteed to be discarded.
#
# EVERY ASSERTION RUNS AGAINST BOTH BUILDS. The `headonly` arm of the driver
# carries the pre-fix `finish` and `enforceBound` transcribed verbatim, and the
# controls require it to FAIL where `fixed` passes. Three of the four cases
# discriminate. The fourth, `bound_then_err`, does NOT, and is labelled as a
# no-regression check rather than dressed up as a proof: when the error arrives
# on its own terminated line after the bound has fired, both builds keep it.
#
# Exit 0 all pass / 1 a check failed / 2 could not run.

set -uo pipefail

REPO_ROOT="${1:-}"
if [[ -z "$REPO_ROOT" ]]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

SRC="${REPO_ROOT}/gui/OstlerInstaller/OutputLineBuffer.swift"
DRIVER_SRC="${REPO_ROOT}/tests/helpers/output_buffer_tail_driver.swift"
COORD="${REPO_ROOT}/gui/OstlerInstaller/InstallerCoordinator.swift"

PASS=0
FAIL=0
cannot_run() {
    echo "CANNOT-RUN: $*" >&2
    echo "  Nothing was checked. This is not a passing gate." >&2
    exit 2
}
pass()    { printf '  [pass] %s\n' "$1"; PASS=$((PASS + 1)); }
failure() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

command -v swiftc >/dev/null 2>&1 || cannot_run "swiftc not on PATH (macOS runner with the Swift toolchain required)"
[[ -f "$SRC" ]]        || cannot_run "OutputLineBuffer.swift not found at ${SRC}"
[[ -f "$DRIVER_SRC" ]] || cannot_run "tail driver not found at ${DRIVER_SRC}"
[[ -f "$COORD" ]]      || cannot_run "InstallerCoordinator.swift not found at ${COORD}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ostler-outtail.XXXXXX")" || cannot_run "mktemp -d failed"
trap 'rm -rf "$WORK"' EXIT

BIN="${WORK}/driver"
cp "$DRIVER_SRC" "${WORK}/main.swift" || cannot_run "could not stage the driver"
if ! swiftc -O -swift-version 5 -o "$BIN" "$SRC" "${WORK}/main.swift" >"${WORK}/build.log" 2>&1; then
    echo "--- build log ---" >&2
    cat "${WORK}/build.log" >&2
    cannot_run "driver failed to compile"
fi

field() { sed -n "s/^$2=//p" <<<"$1"; }

run_case() {
    local out
    out="$("$BIN" "$1" "$2" 2>&1)" || cannot_run "driver $1/$2 exited non-zero: ${out}"
    printf '%s' "$out"
}

# ── a. the measured residual: the error text must survive truncation ──
fx="$(run_case fixed longline_err)"
ho="$(run_case headonly longline_err)"
fx_has="$(field "$fx" contains_error)"
ho_has="$(field "$ho" contains_error)"

if [[ "$ho_has" == "false" ]]; then
    pass "CONTROL: the pre-fix truncation loses the error text ($(field "$ho" line_bytes) bytes, none of them the diagnostic)"
else
    cannot_run "the pre-fix arm KEPT the error text. Either the driver fed the wrong shape or the transcription drifted; a green 'fixed' result below would mean nothing."
fi

if [[ "$fx_has" == "true" ]]; then
    pass "an over-long line keeps its TAIL: the error text survives in $(field "$fx" line_bytes) bytes"
else
    failure "an over-long line still loses the error text. finish() is keeping the head; v1042-D002's residual is back."
fi

if [[ "$(field "$fx" notice)" == "true" ]]; then
    pass "the truncation is still announced, so the gap is explicit as well as survivable"
else
    failure "the line carries no truncation notice: bytes vanished silently"
fi

# ── b. the bound is in BYTES, not characters ─────────────────────────
# maxLineBytes is 1024 in this case. head + tail + the marker text is the
# budget; 4x the bound is the pre-fix answer and is not within any budget.
fx_w="$(run_case fixed wide)"
ho_w="$(run_case headonly wide)"
fx_wb="$(field "$fx_w" line_bytes)"
ho_wb="$(field "$ho_w" line_bytes)"
WIDE_CEILING=1200          # 1024 + room for the marker sentence

if (( ${ho_wb:-0} > 2048 )); then
    pass "CONTROL: the pre-fix line bound returns ${ho_wb} bytes against a claimed 1024 -- it counted characters"
else
    cannot_run "the pre-fix arm respected the byte bound (${ho_wb}). The 'wide' input is not exercising the character/byte confusion, so the check below proves nothing."
fi

if (( ${fx_wb:-999999} <= WIDE_CEILING )); then
    pass "non-ASCII output is bounded in BYTES: ${fx_wb} against a 1024-byte line limit"
else
    failure "non-ASCII output produced ${fx_wb} bytes against a 1024-byte limit: the truncation is counting characters again"
fi

# ── c. the hang: nothing is ever terminated, teardown is the only exit ─
fx_h="$(run_case fixed hang)"
ho_h="$(run_case headonly hang)"

if [[ "$(field "$ho_h" lines)" == "0" ]]; then
    pass "CONTROL: the pre-fix teardown emitted 0 lines and discarded $(field "$ho_h" dropped) bytes unread"
else
    cannot_run "the pre-fix arm emitted a line on the hang case. It models reset()-without-flush and must emit nothing; the check below proves nothing."
fi

if [[ "$(field "$fx_h" lines)" == "1" ]] && [[ "$(field "$fx_h" contains_error)" == "true" ]]; then
    pass "a subprocess that never terminates its last line still reports it, error text included"
else
    failure "flush() lost the unterminated tail on the hang case: lines=$(field "$fx_h" lines) contains_error=$(field "$fx_h" contains_error)"
fi

# The flush has to be CALLED, not merely to exist. A method nothing invokes is
# the same defect one level up.
if grep -q 'stdoutBuffer.flush()' "$COORD"; then
    pass "InstallerCoordinator calls stdoutBuffer.flush()"
else
    failure "OutputLineBuffer.flush() exists but InstallerCoordinator never calls it, so the tail is still deleted unread at teardown"
fi

if awk '/stdoutBuffer.flush\(\)/{f=NR} /stdoutBuffer.reset\(\)/{r=NR} END{exit !(f && r && f < r)}' "$COORD"; then
    pass "the flush happens BEFORE the reset that would delete the buffer"
else
    failure "stdoutBuffer.flush() does not precede stdoutBuffer.reset() in InstallerCoordinator: the reset wins and the tail is lost anyway"
fi

# ── d. no regression on the path that already worked ─────────────────
# NOT a discriminating control: both builds keep the error here, because it
# arrives on its own terminated line after the bound has fired. Recorded as a
# no-regression check so nobody later reads it as proof of the fix.
fx_b="$(run_case fixed bound_then_err)"
if [[ "$(field "$fx_b" contains_error)" == "true" ]] \
   && (( $(field "$fx_b" dropped) > 0 )) \
   && [[ "$(field "$fx_b" notice)" == "true" ]]; then
    pass "NO-REGRESSION (does not discriminate): a terminated error line after the bound still arrives, annotated, with $(field "$fx_b" dropped) bytes recorded as dropped"
else
    failure "the bound-then-error path regressed: contains_error=$(field "$fx_b" contains_error) dropped=$(field "$fx_b" dropped) notice=$(field "$fx_b" notice)"
fi

echo
printf 'output tail: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
exit 0
