#!/usr/bin/env bash
# STEP_END status honesty guard (#839)
# ====================================
#
# THE INPUT THIS TEST REPLAYS
#
# A v1.0.36 install on 2026-08-18 finished with:
#
#     #OSTLER DONE status=ok
#     39 of 39 steps
#     40 STEP_END lines, 40 of them status=ok
#
# Two of those steps had been killed by their 90-second cap and moved no
# data at all:
#
#     #OSTLER STEP_END id=hydrate_browsing status=ok elapsed_s=90
#     #OSTLER STEP_END id=hydrate_people   status=ok elapsed_s=90
#
# Their own completion markers under ~/.ostler/state/hydrate/ disagreed
# with the log they were written beside:
#
#     browsing.done  status=error  rc=124  payload=sent=0,skipped=0
#     people.done    status=error  rc=124  payload=sent=0
#
# rc=124 is the `timeout` kill code. elapsed_s=90 is exactly the cap, on
# both. The reviewer grepped the log for ERR- codes, found none, and
# reported a clean install. A timeout emits no ERR- code, so the
# instrument and the defect sat on different surfaces and the instrument
# was green by construction.
#
# WHY THE STATUS COULD NOT HAVE BEEN ANYTHING ELSE
#
# gui_step_end took its status as an argument defaulting to "ok", and all
# three call sites in install.sh passed the literal `ok`. The field was a
# constant. install.sh's own comment above the wiki page-count check said
# so: "install.sh has no path that ends a step in failure (every
# gui_step_end call site passes `ok`)".
#
# WHAT THIS TEST ASSERTS
#
#   A  ORIGINAL FAILING INPUT. A step whose child is killed by a real
#      `timeout` must NOT close status=ok. It closes status=timeout with
#      rc=124, and its .done marker agrees with its log line.
#   B  POSITIVE CONTROL, must be PRESENT. A step whose child exits 0 must
#      still close status=ok. Without this, a "fix" that stamps every step
#      not-ok would pass A. It also proves the marker apparatus is alive,
#      so A's absence assertion cannot pass by the emitter being dead.
#   C  THREE STATES, NEVER TWO. A child that exits 3 closes status=error
#      rc=3, distinct from the timeout state.
#   D  NO REVERSED CONCLUSION. An explicit `gui_step_end ok` after a
#      recorded timeout still must not emit status=ok. A fix a future call
#      site can undo by passing `ok` again is not a fix.
#   E  ONE-LINE TRUTH. The terminal DONE line carries failed_steps=2 after
#      A and C, and failed_steps=0 on a clean run, so a reviewer grepping
#      one line learns the truth and can tell "none failed" apart from
#      "this build does not report it".
#
# The test EXECUTES the real progress() and the real
# _hydrate_sentinel_record_error extracted from install.sh, and sources the
# real lib/progress_emitter.sh. It cannot pass against a copy of the logic.

set -uo pipefail

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

WORK="$(mktemp -d "${TMPDIR:-/tmp}/step-end-honesty.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ── A real timeout, because stock macOS ships none ─────────────────────
#
# install.sh picks its wrapper with `command -v gtimeout` then
# `command -v timeout`, and stock macOS (and the macos-14 CI runner) has
# NEITHER, which is exactly why install.sh carries the empty-wrapper arm.
# To replay the original failing input the test has to supply one. Both
# names are shimmed so the ladder is deterministic whether or not the host
# happens to have coreutils installed.
#
# The shim reproduces the ONE property install.sh depends on: a child
# killed at the cap yields exit code 124. It learns that from a flag the
# killer writes rather than from the child's signal-mangled status, so a
# child that dies of something else is not laundered into a fake timeout.
SHIM_BIN="${WORK}/bin"
mkdir -p "$SHIM_BIN"
cat > "${SHIM_BIN}/timeout" <<'SHIM'
#!/usr/bin/env bash
# Test-only stand-in for coreutils timeout. Not shipped.
dur="$1"; shift
flag="$(mktemp "${TMPDIR:-/tmp}/timeout-fired.XXXXXX")"
rm -f "$flag"
"$@" &
child=$!
( sleep "$dur"; kill -TERM "$child" 2>/dev/null && : > "$flag" ) &
killer=$!
wait "$child"; rc=$?
kill -TERM "$killer" 2>/dev/null
wait "$killer" 2>/dev/null
if [ -f "$flag" ]; then rc=124; fi
rm -f "$flag"
exit "$rc"
SHIM
cp "${SHIM_BIN}/timeout" "${SHIM_BIN}/gtimeout"
chmod +x "${SHIM_BIN}/timeout" "${SHIM_BIN}/gtimeout"
PATH="${SHIM_BIN}:${PATH}"
export PATH

# Prove the shim really produces 124 before any assertion leans on it.
# A probe nobody validated is a probe whose answer nobody should believe.
timeout 1 sleep 5 >/dev/null 2>&1
SHIM_RC=$?
if [ "$SHIM_RC" -ne 124 ]; then
    printf 'FATAL: the timeout shim returned %s, not 124. Every assertion below would be measuring the shim, not install.sh.\n' "$SHIM_RC" >&2
    exit 1
fi
printf 'Harness: the timeout shim kills at the cap and returns 124.\n'

# ── Extract the REAL functions from install.sh ─────────────────────────
extract_fn() {
    # extract_fn <name> <file>   prints the function from its opening
    # line to the first `}` at column 0.
    awk -v fn="$1" '
        $0 ~ "^"fn"\\(\\) \\{" { inside = 1 }
        inside { print }
        inside && /^\}/ { exit }
    ' "$2"
}

extract_fn progress "$INSTALL_SH" > "${WORK}/progress.sh"
extract_fn _hydrate_sentinel_record_error "$INSTALL_SH" > "${WORK}/sentinel_error.sh"
extract_fn _hydrate_sentinel_record "$INSTALL_SH" > "${WORK}/sentinel_ok.sh"

for f in progress sentinel_error sentinel_ok; do
    if [ ! -s "${WORK}/${f}.sh" ]; then
        printf 'FATAL: could not extract %s from install.sh. The test is measuring nothing.\n' "$f" >&2
        exit 1
    fi
    if ! bash -n "${WORK}/${f}.sh"; then
        printf 'FATAL: extracted %s does not parse. Extraction is broken, not the code.\n' "$f" >&2
        exit 1
    fi
done
printf 'Harness: extracted progress + both hydrate sentinel recorders from install.sh.\n\n'

# ── Drive the real chain ───────────────────────────────────────────────
#
# One bash -c so the emitter's step accumulator, the extracted progress()
# and the DONE counter all live in ONE shell, as they do in a real install.
MARKERS="${WORK}/markers.txt"
SENTINELS="${WORK}/hydrate"
mkdir -p "$SENTINELS"

OSTLER_GUI=1 \
_OSTLER_TEST_EMITTER="$EMITTER" \
_OSTLER_TEST_WORK="$WORK" \
_OSTLER_TEST_SENTINELS="$SENTINELS" \
bash <<'DRIVER' 2>"$MARKERS"
set -uo pipefail

# install.sh globals that progress() reads. Values are irrelevant to the
# status field; they only keep the progress bar arithmetic alive.
TOTAL_STEPS=4
CURRENT_STEP=0
PHASE3_START=$(date +%s)
BOLD=""; BLUE=""; NC=""
_HYDRATE_SENTINEL_DIR="${_OSTLER_TEST_SENTINELS}"

# shellcheck source=/dev/null
. "${_OSTLER_TEST_EMITTER}"
# shellcheck source=/dev/null
. "${_OSTLER_TEST_WORK}/progress.sh"
# shellcheck source=/dev/null
. "${_OSTLER_TEST_WORK}/sentinel_error.sh"
# shellcheck source=/dev/null
. "${_OSTLER_TEST_WORK}/sentinel_ok.sh"

# Same wrapper ladder install.sh uses at every hydrate step.
WRAP=""
if command -v gtimeout >/dev/null 2>&1; then
    WRAP="gtimeout 1"
elif command -v timeout >/dev/null 2>&1; then
    WRAP="timeout 1"
fi

# ── B: the positive control runs FIRST ────────────────────────────────
# A step whose child exits 0. If this does not close status=ok, the
# emitter is stamping everything not-ok and A proves nothing.
progress "Setting up conversation memory" "cm048_setup"
$WRAP sleep 0 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] || _hydrate_sentinel_record_error "cm048" "$rc" "control=broken"

# ── A: the original failing input ─────────────────────────────────────
# hydrate_people, killed by its cap, ingesting nothing. The `progress`
# call above closes cm048_setup; this one opens hydrate_people.
progress "Indexing your people for search" "hydrate_people"
$WRAP sleep 30 >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
    _hydrate_sentinel_record_error "people" "$rc" "sent=0"
else
    _hydrate_sentinel_record "people" "sent=0"
fi

# ── C: a non-timeout failure, to prove three states not two ───────────
progress "Hydrating your browsing history" "hydrate_browsing"
$WRAP bash -c 'exit 3' >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
    _hydrate_sentinel_record_error "browsing" "$rc" "sent=0,skipped=0"
fi

# ── D: an explicit `ok` must not overwrite a measurement ──────────────
progress "Compiling your personal wiki (first run)" "wiki_compile"
$WRAP sleep 30 >/dev/null 2>&1
rc=$?
gui_step_record_rc "$rc"
# The literal that WAS the defect, aimed straight at a recorded timeout.
gui_step_end ok

# ── E: the terminal line ──────────────────────────────────────────────
gui_done ok
DRIVER

# ── A clean run, for the failed_steps=0 half of E ──────────────────────
CLEAN_MARKERS="${WORK}/clean.txt"
OSTLER_GUI=1 \
_OSTLER_TEST_EMITTER="$EMITTER" \
_OSTLER_TEST_WORK="$WORK" \
bash <<'CLEAN' 2>"$CLEAN_MARKERS"
set -uo pipefail
TOTAL_STEPS=1
CURRENT_STEP=0
PHASE3_START=$(date +%s)
BOLD=""; BLUE=""; NC=""
# shellcheck source=/dev/null
. "${_OSTLER_TEST_EMITTER}"
# shellcheck source=/dev/null
. "${_OSTLER_TEST_WORK}/progress.sh"
progress "Setting up conversation memory" "cm048_setup"
gui_step_end
gui_done ok
CLEAN

printf 'STEP_END + DONE lines produced by the run under test:\n'
grep -E '#OSTLER.*(STEP_END|DONE)' "$MARKERS" | sed 's/^/    /'
printf '\nAnd from the clean run:\n'
grep -E '#OSTLER.*DONE' "$CLEAN_MARKERS" | sed 's/^/    /'
printf '\n'

# ── Assertions ─────────────────────────────────────────────────────────
#
# step_end_line <id> prints the STEP_END marker for that step id, or
# nothing. Tabs are the field delimiter on the wire.
step_end_line() {
    grep -E "#OSTLER.*STEP_END.*[[:space:]]id=$1([[:space:]]|$)" "$2" | tail -n 1
}

# --- B (control, must be PRESENT and must be ok) -----------------------
B_LINE="$(step_end_line cm048_setup "$MARKERS")"
if [ -z "$B_LINE" ]; then
    fail "B control: no STEP_END for cm048_setup at all. The emitter is dead, so every absence assertion below is worthless."
elif printf '%s' "$B_LINE" | grep -q 'status=ok'; then
    pass "B control: a step whose child exits 0 still closes status=ok"
else
    fail "B control: a clean step did NOT close status=ok, it closed: ${B_LINE}"
fi

# --- A (the original failing input) ------------------------------------
A_LINE="$(step_end_line hydrate_people "$MARKERS")"
if [ -z "$A_LINE" ]; then
    fail "A: no STEP_END for hydrate_people. Nothing was measured."
else
    if printf '%s' "$A_LINE" | grep -q 'status=ok'; then
        fail "A: a step killed by its timeout reported status=ok. This is the v1.0.36 defect: ${A_LINE}"
    else
        pass "A: a step killed by its timeout does NOT report status=ok"
    fi
    if printf '%s' "$A_LINE" | grep -q 'status=timeout'; then
        pass "A: it reports status=timeout, distinct from a plain error"
    else
        fail "A: expected status=timeout, got: ${A_LINE}"
    fi
    if printf '%s' "$A_LINE" | grep -q 'rc=124'; then
        pass "A: it carries rc=124, the code the timeout actually returned"
    else
        fail "A: expected rc=124 on the STEP_END, got: ${A_LINE}"
    fi
fi

# --- A2: the log line and the .done marker must agree ------------------
PEOPLE_DONE="${SENTINELS}/people.done"
if [ ! -f "$PEOPLE_DONE" ]; then
    fail "A2: ${PEOPLE_DONE} was not written, so the two surfaces cannot be compared."
else
    MARKER_RC="$(grep '^rc=' "$PEOPLE_DONE" | head -n 1 | cut -d= -f2)"
    MARKER_STATUS="$(grep '^status=' "$PEOPLE_DONE" | head -n 1 | cut -d= -f2)"
    # COMPARE THE TWO SURFACES TO EACH OTHER, NOT EACH TO A LITERAL.
    #
    # This block used to demand MARKER_STATUS = "error". That was the old
    # contract, and this very change replaces it: a step killed by the timeout
    # now closes status=timeout, which is the whole point of the fix and what
    # assertion A three lines up already checks. So the suite asserted
    # "timeout" and "error" for the same marker and had to fail one of them.
    #
    # The name of this assertion is "the log line and the .done marker must
    # AGREE". Agreement is a relation between the two, so it is now written
    # as one: pull the status out of the STEP_END line and compare it to the
    # marker's. A future rename of the status moves both sides together and
    # this keeps passing, which is correct -- it is not this assertion's job
    # to pin the vocabulary, only to catch the two surfaces drifting apart.
    LOG_STATUS="$(printf '%s' "$A_LINE" | tr '\t' '\n' | grep '^status=' | head -n 1 | cut -d= -f2)"
    LOG_RC="$(printf '%s' "$A_LINE" | tr '\t' '\n' | grep '^rc=' | head -n 1 | cut -d= -f2)"
    if [ -z "$LOG_STATUS" ] || [ -z "$LOG_RC" ]; then
        fail "A2: could not parse status/rc out of the STEP_END line, so the two surfaces were never compared: ${A_LINE}"
    elif [ "$MARKER_STATUS" = "$LOG_STATUS" ] && [ "$MARKER_RC" = "$LOG_RC" ] && [ "$MARKER_RC" = "124" ]; then
        pass "A2: people.done and the STEP_END agree (status=${MARKER_STATUS} rc=${MARKER_RC}), both read from the artefacts"
    else
        fail "A2: the two surfaces DISAGREE -- people.done says status=${MARKER_STATUS} rc=${MARKER_RC}, the log says status=${LOG_STATUS} rc=${LOG_RC}"
    fi
fi

# --- C (three states, never two) ---------------------------------------
C_LINE="$(step_end_line hydrate_browsing "$MARKERS")"
if printf '%s' "$C_LINE" | grep -q 'status=error' \
   && printf '%s' "$C_LINE" | grep -q 'rc=3'; then
    pass "C: a child exiting 3 closes status=error rc=3, not timeout and not ok"
else
    fail "C: expected status=error rc=3, got: ${C_LINE:-<no STEP_END for hydrate_browsing>}"
fi

# --- D (no reversed conclusion) ----------------------------------------
D_LINE="$(step_end_line wiki_compile "$MARKERS")"
if [ -z "$D_LINE" ]; then
    fail "D: no STEP_END for wiki_compile. Nothing was measured."
elif printf '%s' "$D_LINE" | grep -q 'status=ok'; then
    fail "D: an explicit \`gui_step_end ok\` overwrote a recorded timeout: ${D_LINE}"
else
    pass "D: an explicit \`gui_step_end ok\` cannot overwrite a recorded timeout"
fi

# --- E (one-line truth) ------------------------------------------------
DONE_LINE="$(grep -E '#OSTLER.*DONE' "$MARKERS" | tail -n 1)"
if printf '%s' "$DONE_LINE" | grep -q 'failed_steps=3'; then
    pass "E: the DONE line carries failed_steps=3 (hydrate_people, hydrate_browsing, wiki_compile)"
else
    fail "E: expected failed_steps=3 on the DONE line, got: ${DONE_LINE:-<no DONE line>}"
fi

CLEAN_DONE="$(grep -E '#OSTLER.*DONE' "$CLEAN_MARKERS" | tail -n 1)"
if printf '%s' "$CLEAN_DONE" | grep -q 'failed_steps=0'; then
    pass "E: a clean run PRINTS failed_steps=0, so a zero cannot be confused with an unreporting build"
else
    fail "E: expected failed_steps=0 on a clean run, got: ${CLEAN_DONE:-<no DONE line>}"
fi

printf '\n'
if [ "$FAILURES" -eq 0 ]; then
    printf 'PASS: STEP_END status reflects the child exit code (%s)\n' "${INSTALL_SH}"
    exit 0
fi
printf 'FAIL: %s assertion(s) failed against %s + %s\n' "$FAILURES" "$INSTALL_SH" "$EMITTER"
exit 1
