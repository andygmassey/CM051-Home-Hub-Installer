#!/usr/bin/env bash
#
# THE STDOUT ACCUMULATOR MUST BE BOUNDED -- PROVEN BY RUNNING IT.
# ==============================================================
#
# WHY A RUNTIME TEST AND NOT A SOURCE-TEXT ONE. Its sibling
# `test_stdout_buffer_is_bounded_without_newlines.sh` asserts a cap is
# declared, consulted, and that the buffer is reassigned. ORM defeated all
# three at once with a decoy any reviewer would wave through -- the whole cap
# body wrapped in `if stdoutBuffer.isEmpty`, which is never true:
#
#     source-text test:  PASS=6 FAIL=0
#     actual buffer:     11,844,000 bytes and climbing
#
# No text predicate holds this line. The property is "the number stops going
# up", and that is a fact about execution.
#
# ── 🔴 THIS TEST'S OWN FIRST VERSION WAS BROKEN, AND INSTRUCTIVELY ────────
#
# It compared the shipped tree against `origin/main`. ORM built a fixture
# whose origin/main WAS the fixed coordinator and executed it:
#
#     FAIL  CONTROL FAILED: origin/main retained only 65464 of 4189696 bytes
#     PASS=5 FAIL=1  EXIT=1
#
# **The control was pinned to a moving ref, and the thing it controlled for
# was the change that moves it.** It would have gone red on main the day it
# merged -- and a test that reds main on merge gets deleted, not fixed.
#
# The replacement is a MUTATION control: the harness takes the tree under
# test, strips the cap statement by brace matching, and runs BOTH. The
# negative case is derived from the same bytes as the positive one, so there
# is no second tree to drift, no ref to move, and no way for the control to
# stop meaning what it meant.
#
# ── WHAT THE HARNESS IS, AND WHY IT IS NOT THIS FILE ─────────────────────
#
# `tests/tools/stdout_bound_harness.sh` (ORM's, adopted rather than rebuilt)
# MEASURES and exits 0 whatever it finds. It deliberately does not judge: a
# tool that also judges gets adopted for its verdict and then trusted for its
# measurement. The judging is here.
#
# It extracts the accumulator by CODE and BRACE MATCHING, never by line
# number -- my own first attempt sliced lines 1490-1538, which works exactly
# until someone adds a line above and it silently compiles a neighbouring
# function.
#
# ── THE DEFECT ───────────────────────────────────────────────────────────
#
# The installer held 4.27 GB after a SUCCESSFUL install. `stdoutBuffer` drains
# only on "\n"; `docker pull` writes layer progress with "\r" and no newline,
# so during a multi-gigabyte pull the drain loop never executes once.
#
# 🔴 NOT A COSMETIC LEAK. That retention drove macOS into memory pressure --
# five JetsamEvent reports on the walk box on 2026-08-23 between 16:13:35 and
# 17:33:51 -- jetsam killed the 4 GB Colima VM, and the wiki and store went
# dark for hours. This buffer is the first link in that chain.
#
# ⚠️ VERSION NOTE, because I got this wrong once and it matters: that walk was
# **v1.0.38**, not v1.0.42. The DMG in the operator's Downloads was 57,818,336
# bytes -- the published v1.0.38 count -- dated two days before v1.0.42 was
# published. The defect is real and measured; the version label was not.
#
# British English throughout.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS="${REPO_ROOT}/tests/tools/stdout_bound_harness.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }

echo
echo "== the stdout accumulator is bounded IN FACT, with a mutation control =="
echo

# ── 0. CANNOT-RUN FIRST, AND IT IS NOT A PASS ─────────────────────────────
if [[ ! -x "$HARNESS" ]]; then
    echo "CANNOT-RUN: ${HARNESS} is not executable." >&2
    echo "  Nothing was measured. This is NOT a pass -- exit 2." >&2
    exit 2
fi
if ! command -v swiftc >/dev/null 2>&1; then
    echo "CANNOT-RUN: swiftc is not on PATH." >&2
    echo "  A runtime test that cannot compile has measured NOTHING." >&2
    echo "  This is NOT a pass -- exit 2. Run this on a macOS runner." >&2
    exit 2
fi
ok "CANNOT-RUN check: harness executable and swiftc present"

OUT="$("$HARNESS" 2>/dev/null)"; HRC=$?
if [[ "$HRC" -ne 0 ]]; then
    echo "CANNOT-RUN: the harness exited ${HRC} (it exits 2 when it cannot extract)." >&2
    echo "  The accumulator or its drain loop moved. NOT a pass -- exit 2." >&2
    exit 2
fi

# Parse the two sections. `sed -n '/from/,/to/p'` rather than grepping the
# whole output: both sections print IDENTICAL key names, and a global grep
# would silently take whichever came first for every assertion.
sec() { sed -n "/^== ${1}/,/^$/p" <<< "$OUT"; }
val() { sed -n "s/^${2}=\([0-9]*\).*/\1/p" <<< "$1" | head -1; }

SHIPPED="$(sec 'SHIPPED')"
MUTANT="$(sec 'MUTANT')"

S_FED="$(val "$SHIPPED" fed_bytes)"
S_PEAK="$(val "$SHIPPED" peak_buffer_bytes)"
S_FINAL="$(val "$SHIPPED" final_buffer_bytes)"
M_FED="$(val "$MUTANT" fed_bytes)"
M_PEAK="$(val "$MUTANT" peak_buffer_bytes)"

printf '        shipped: fed=%s peak=%s final=%s\n' "${S_FED:-?}" "${S_PEAK:-?}" "${S_FINAL:-?}"
printf '        mutant : fed=%s peak=%s\n' "${M_FED:-?}" "${M_PEAK:-?}"

for v in S_FED S_PEAK S_FINAL M_FED M_PEAK; do
    if [[ -z "${!v}" ]]; then
        bad "CANNOT-RUN: could not parse ${v} from the harness output" \
            "the harness changed its output format; this test measured nothing"
        echo "PASS=$PASS FAIL=$FAIL"; exit 2
    fi
done

# ── 1. THE MUTATION CONTROL, FIRST AND IT MUST BLOW UP ────────────────────
# THE ASSERTION THAT MAKES EVERY OTHER ONE MEAN SOMETHING. Strip the cap and
# the buffer must retain essentially everything fed. If it does not, the
# producer is not producing and a bounded reading below is indistinguishable
# from a harness that fed nothing.
if [[ "$M_PEAK" -ge $(( M_FED / 2 )) ]]; then
    ok "CONTROL: cap removed -> retains ${M_PEAK} of ${M_FED} fed. The producer reproduces the defect"
else
    bad "CONTROL FAILED: cap removed and it still only reached ${M_PEAK} of ${M_FED}" \
        "the \\r-only producer is not filling the buffer, so a pass below is vacuous"
    echo "PASS=$PASS FAIL=$FAIL"; exit 1
fi

# ── 2. AND THE TWO CASES MUST BE THE SAME EXPERIMENT ──────────────────────
# Same bytes fed to both, or the comparison is between two different runs and
# the separation below could come from the input rather than from the fix.
if [[ "$S_FED" -eq "$M_FED" ]]; then
    ok "both arms were fed the same ${S_FED} bytes"
else
    bad "the two arms were fed different amounts (${S_FED} vs ${M_FED})" \
        "this is not a controlled comparison"
fi

# ── 3. THE SHIPPED TREE MUST STAY BOUNDED ─────────────────────────────────
# The declared ceiling is read from the source, not repeated here -- a
# hard-coded number drifts the day somebody retunes the cap. Generous
# headroom: the guard fires AFTER an append, so one chunk may legitimately
# overshoot. Unbounded growth is three orders of magnitude away from this.
SRC="${REPO_ROOT}/gui/OstlerInstaller/InstallerCoordinator.swift"
CAP="$(sed -n 's/.*stdoutBufferCapBytes *= *\([0-9]*\) *\* *\([0-9]*\).*/\1*\2/p' "$SRC" | head -1)"
CAP_BYTES=$(( ${CAP:-0} )); [[ "$CAP_BYTES" -gt 0 ]] || CAP_BYTES=$((64 * 1024))
LIMIT=$(( CAP_BYTES * 8 ))

if [[ "$S_PEAK" -le "$LIMIT" ]]; then
    ok "PEAK bounded: ${S_PEAK} <= ${LIMIT} while ${S_FED} bytes were fed"
else
    bad "PEAK UNBOUNDED: ${S_PEAK} after feeding ${S_FED}" \
        "a \\r-only producer must not grow the accumulator past ~${LIMIT}"
fi

if [[ "$S_FINAL" -le "$LIMIT" ]]; then
    ok "FINAL bounded: ${S_FINAL} retained after the stream ends"
else
    bad "FINAL UNBOUNDED: ${S_FINAL} still retained after the stream ends" \
        "this is the 4.27 GB defect -- retention AFTER completion, not a spike"
fi

# ── 4. THE SEPARATION MUST BE UNAMBIGUOUS ─────────────────────────────────
# Guards against a future where both arms drift together and the test keeps
# passing on a ratio nobody looks at. Two orders of magnitude or it is not a
# bound, it is a coincidence.
if [[ "$S_PEAK" -gt 0 && $(( M_PEAK / S_PEAK )) -ge 100 ]]; then
    ok "separation is $(( M_PEAK / S_PEAK ))x between mutant and shipped"
else
    bad "mutant and shipped peaks are within $(( S_PEAK > 0 ? M_PEAK / S_PEAK : 0 ))x" \
        "a bound that is only marginally better than no bound is not a bound"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
