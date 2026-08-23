#!/usr/bin/env bash
#
# test_installer_output_buffer_is_bounded.sh
#
# THE DEFECT THIS PINS, MEASURED 2026-08-23 ON REAL HARDWARE
# ---------------------------------------------------------
# v1.0.42 upgrade walk, Mac mini. macOS raised "your system has run out of
# application memory" with:
#
#     Ostler Installer   (paused)   4.27 GB     <-- AFTER a successful install
#
# InstallerCoordinator accumulated subprocess output into a bare Swift String
# and drained it ONLY at "\n". Output with no "\n" -- `\r`-delimited progress
# redraws, which is what docker, brew, pip and ollama all emit -- accumulated
# one retained byte per byte received, without bound, and was never cleared,
# not even when the subprocess exited.
#
# Measured through a real Pipe + readabilityHandler against the pre-fix
# parser, verbatim:
#
#     cr,  5 MiB  ->  lines_parsed=0        retained  5,246,000 chars
#     cr, 20 MiB  ->  lines_parsed=0        retained 20,984,000 chars
#     lf, 20 MiB  ->  lines_parsed=344,000  retained          0   <-- CONTROL
#
# 4x the input, 4x the retention. Linear, 1:1, permanent.
#
# REFUTED, so nobody re-chases it: the log buffer. `logLines` is capped at
# 5,000 entries. A few MB, never the 4 GB.
#
# HOW THIS GATE CANNOT SILENTLY PASS
# ----------------------------------
# Control (1) drives the PRE-FIX parser -- transcribed verbatim into
# tests/helpers/output_buffer_driver.swift -- through the identical driver and
# REQUIRES it to retain the bytes. If the pre-fix parser ever reads as bounded,
# this harness cannot see the defect it exists for, and the whole run fails
# rather than reporting green. Every "0" below has a partner that must be
# non-zero.
#
# EXIT CODES   0 all controls pass   1 a control failed   2 CANNOT-RUN

set -uo pipefail

REPO_ROOT="${1:-}"
if [[ -z "$REPO_ROOT" ]]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

SRC="${REPO_ROOT}/gui/OstlerInstaller/OutputLineBuffer.swift"
DRIVER_SRC="${REPO_ROOT}/tests/helpers/output_buffer_driver.swift"
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
[[ -f "$DRIVER_SRC" ]] || cannot_run "driver not found at ${DRIVER_SRC}"
[[ -f "$COORD" ]]      || cannot_run "InstallerCoordinator.swift not found at ${COORD}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ostler-outbuf.XXXXXX")" || cannot_run "mktemp -d failed"
trap 'rm -rf "$WORK"' EXIT

BIN="${WORK}/driver"
# swiftc only allows top-level statements in a file literally called
# main.swift when more than one file is compiled, so the driver is staged
# under that name rather than carrying it in the repo (where `main.swift`
# would be a meaningless filename next to the tests it serves).
cp "$DRIVER_SRC" "${WORK}/main.swift" || cannot_run "could not stage the driver"
if ! swiftc -O -swift-version 5 -o "$BIN" "$SRC" "${WORK}/main.swift" >"${WORK}/build.log" 2>&1; then
    echo "--- build log ---" >&2
    cat "${WORK}/build.log" >&2
    cannot_run "driver failed to compile"
fi

# field <output> <key>  -> value
field() { sed -n "s/^$2=//p" <<<"$1"; }

MIB=8
BOUND=$(( (1 << 20) + 65536 ))   # maxBufferBytes + one 64 KiB chunk

# ── CONTROL 1: the PRE-FIX parser must RED on the same input ─────────
# Without this, a green "fixed" result is indistinguishable from a driver
# that never fed anything.
legacy_cr="$("$BIN" legacy cr "$MIB" 2>&1)" || failure "legacy/cr driver exited non-zero: ${legacy_cr}"
legacy_retained="$(field "$legacy_cr" retained_bytes)"
legacy_lines="$(field "$legacy_cr" lines)"
legacy_fed="$(field "$legacy_cr" fed_bytes)"
if [[ -z "${legacy_retained:-}" || -z "${legacy_fed:-}" ]]; then
    failure "legacy/cr produced no parseable output: ${legacy_cr}"
elif (( legacy_retained < legacy_fed / 2 )); then
    failure "CONTROL BROKEN: the pre-fix parser retained ${legacy_retained} of ${legacy_fed} fed bytes. It is supposed to retain nearly all of them. This harness can no longer detect the defect it exists for, so no result below can be trusted."
else
    pass "control: pre-fix parser retains ${legacy_retained} of ${legacy_fed} bytes and parses ${legacy_lines} lines -- the defect is reproducible here"
fi

# ── CONTROL 2: the pre-fix parser IS fine on \n input ────────────────
# The other side of the zero. If legacy also retained on "\n" the harness
# would be measuring itself, not the terminator handling.
legacy_lf="$("$BIN" legacy lf "$MIB" 2>&1)" || failure "legacy/lf driver exited non-zero"
legacy_lf_retained="$(field "$legacy_lf" retained_bytes)"
legacy_lf_lines="$(field "$legacy_lf" lines)"
if [[ "${legacy_lf_retained:-x}" == "0" ]] && (( ${legacy_lf_lines:-0} > 0 )); then
    pass "control: pre-fix parser on \\n input retains 0 and parses ${legacy_lf_lines} lines -- the retention above is the terminator, not the harness"
else
    failure "CONTROL BROKEN: pre-fix parser on \\n input retained ${legacy_lf_retained} / parsed ${legacy_lf_lines}. Expected 0 retained and a non-zero line count."
fi

# ── CONTROL 3: the pre-fix parser ALSO reds on CRLF ─────────────────
# In Swift "\r\n" is ONE Character, equal to neither "\r" nor "\n", so
# `firstIndex(of: "\n")` never found it. CRLF was a second unbounded path,
# not a variant of the first. Recorded here because it was found by this
# gate going red on the fix, not by reading the code.
legacy_crlf="$("$BIN" legacy crlf "$MIB" 2>&1)" || failure "legacy/crlf driver exited non-zero"
legacy_crlf_retained="$(field "$legacy_crlf" retained_bytes)"
legacy_crlf_fed="$(field "$legacy_crlf" fed_bytes)"
if (( ${legacy_crlf_retained:-0} >= ${legacy_crlf_fed:-1} / 2 )); then
    pass "control: pre-fix parser retains ${legacy_crlf_retained} of ${legacy_crlf_fed} CRLF bytes -- CRLF was a second unbounded path"
else
    failure "CONTROL BROKEN: pre-fix parser on CRLF retained only ${legacy_crlf_retained} of ${legacy_crlf_fed}; the CRLF assertions below prove nothing"
fi

# ── 1. the shipping parser is BOUNDED on \r-only input ───────────────
fixed_cr="$("$BIN" fixed cr "$MIB" 2>&1)" || failure "fixed/cr driver exited non-zero: ${fixed_cr}"
fixed_retained="$(field "$fixed_cr" retained_bytes)"
fixed_lines="$(field "$fixed_cr" lines)"
if [[ -z "${fixed_retained:-}" ]]; then
    failure "fixed/cr produced no parseable output: ${fixed_cr}"
elif (( fixed_retained > BOUND )); then
    failure "fixed/cr retained ${fixed_retained} bytes, over the ${BOUND}-byte bound"
else
    pass "fixed/cr retains ${fixed_retained} bytes (bound ${BOUND}) after ${MIB} MiB"
fi
# and it PARSES the progress rather than swallowing it
if (( ${fixed_lines:-0} > 0 )); then
    pass "fixed/cr parsed ${fixed_lines} lines -- \\r-delimited progress reaches the log instead of accumulating"
else
    failure "fixed/cr parsed 0 lines: \\r is still not a terminator"
fi

# ── 2. unterminated run: the bound holds when there is NO terminator ─
fixed_long="$("$BIN" fixed longline "$MIB" 2>&1)" || failure "fixed/longline driver exited non-zero"
long_retained="$(field "$fixed_long" retained_bytes)"
long_dropped="$(field "$fixed_long" dropped)"
if (( ${long_retained:-999999999} <= BOUND )); then
    pass "fixed/longline retains ${long_retained} bytes after ${MIB} MiB with no terminator at all (bound ${BOUND})"
else
    failure "fixed/longline retained ${long_retained} bytes, over the ${BOUND}-byte bound"
fi
if (( ${long_dropped:-0} > 0 )); then
    pass "fixed/longline recorded ${long_dropped} dropped bytes -- the discard is counted, not silent"
else
    failure "fixed/longline recorded 0 dropped bytes after ${MIB} MiB with no terminator. Either the bound never fired (it retained everything) or it fired silently. Both are defects."
fi

# ── 3. \n behaviour is unchanged (no regression on the normal path) ──
fixed_lf="$("$BIN" fixed lf "$MIB" 2>&1)" || failure "fixed/lf driver exited non-zero"
if [[ "$(field "$fixed_lf" retained_bytes)" == "0" ]] \
   && [[ "$(field "$fixed_lf" lines)" == "$(field "$legacy_lf" lines)" ]]; then
    pass "fixed/lf parses the same $(field "$fixed_lf" lines) lines as the pre-fix parser and retains 0"
else
    failure "fixed/lf diverges from the pre-fix parser on the normal path: fixed=$(field "$fixed_lf" lines)/$(field "$fixed_lf" retained_bytes) legacy=$(field "$legacy_lf" lines)/$(field "$legacy_lf" retained_bytes)"
fi

# ── 4. CRLF is ONE terminator, not two ──────────────────────────────
fixed_crlf="$("$BIN" fixed crlf "$MIB" 2>&1)" || failure "fixed/crlf driver exited non-zero"
crlf_lines="$(field "$fixed_crlf" lines)"
lf_lines="$(field "$fixed_lf" lines)"
if (( ${crlf_lines:-0} > 0 )) && (( crlf_lines <= lf_lines )); then
    pass "fixed/crlf yields ${crlf_lines} lines for the same payload count (\\r\\n collapses to one terminator)"
else
    failure "fixed/crlf yielded ${crlf_lines} lines against ${lf_lines} for \\n -- CRLF is being counted twice"
fi

# ── 5. a single over-long line is truncated before the caller sees it ─
# The lower bound is load-bearing: `longest_line=0` means no line was ever
# handed on, which passes a "<= cap" test while measuring nothing.
long_line="$(field "$fixed_cr" longest_line)"
if (( ${long_line:-0} == 0 )); then
    failure "longest_line is 0 -- no line reached the caller at all, so the per-line cap was never exercised"
elif (( long_line <= 65536 + 128 )); then
    pass "longest line handed on is ${long_line} bytes, non-zero and under the cap -- the per-line cap holds"
else
    failure "a ${long_line}-byte line reached the caller; logLines is bounded by COUNT not size, so this is the second leak path"
fi

# ── 6. the coordinator must not reintroduce the raw pattern ─────────
# Comment-stripped: a comment quoting the old loop (this file's own header
# does exactly that) must not satisfy or trip the check.
COORD_CODE="${WORK}/coord.swift"
sed 's|//.*||' "$COORD" > "$COORD_CODE"

if grep -q 'stdoutBuffer = OutputLineBuffer()' "$COORD_CODE"; then
    pass "InstallerCoordinator holds an OutputLineBuffer, not a bare String"
else
    failure "InstallerCoordinator no longer declares stdoutBuffer as an OutputLineBuffer"
fi
if grep -q 'stdoutBuffer\.firstIndex(of: "\\n")' "$COORD_CODE"; then
    failure "the unbounded firstIndex(of:\"\\\\n\") drain loop is back in InstallerCoordinator"
else
    pass "the unbounded firstIndex(of:\"\\\\n\") drain loop is absent from InstallerCoordinator code"
fi
if grep -q 'stdoutBuffer\.reset()' "$COORD_CODE"; then
    pass "the accumulator is reset on subprocess termination"
else
    failure "nothing calls stdoutBuffer.reset() -- retained bytes would outlive the install again"
fi

# ── 7. anti-vacuity for control 6: doctor a copy, require RED ────────
# Without this, greps 6 could be passing because the file moved or the
# pattern is unmatchable, not because the code is right.
DOCTORED="${WORK}/doctored.swift"
printf 'let x = 1\nwhile let nlIdx = stdoutBuffer.firstIndex(of: "\\n") { }\n' > "$DOCTORED"
if grep -q 'stdoutBuffer\.firstIndex(of: "\\n")' "$DOCTORED"; then
    pass "anti-vacuity: the drain-loop predicate matches a doctored file, so its absence above is a measurement"
else
    failure "anti-vacuity: the drain-loop predicate does not match even a file that contains it -- check 6 proves nothing"
fi

echo
echo "=== ${PASS} passed / ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
