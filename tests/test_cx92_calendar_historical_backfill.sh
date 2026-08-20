#!/usr/bin/env bash
#
# tests/test_cx92_calendar_historical_backfill.sh
#
# CX-92 / board #554: the install-time calendar backfill must be
# MULTI-YEAR, and it must stay that way.
#
# WHAT THE FAILURE LOOKED LIKE (DMG #48f, must never recur):
#
#     "Backfilling your calendar for the last 90 days"
#     "No calendar events in the last 90 days."
#
# and a wiki Events page that stayed empty on a Mac with years of
# iCloud and Google meetings in it. CX-106 had narrowed the
# install-time window to 90 days and deferred the rest to
# com.ostler.fda-rerun.
#
# WHAT THAT DEFERRAL DELIVERS TODAY, measured against the vendor pin on
# main (9cf567be) rather than assumed:
#
#   BACKWARD  reaches five years, but SLOWLY. #714 made the agent
#             recur hourly and HR015 #417 (already vendored) gave
#             calendar a 365 -> 730 -> 1825 ladder with a 6h dwell, so
#             1825 lands around install + 12h.
#   FORWARD   never moves. `future_days=30` is still a literal in the
#             vendored twin and upstream alike.
#
# #554 asks for the Events page to populate within ~5 minutes of
# install completing. Half a day later is the wrong answer to "is this
# thing working", and it is not what the installer's own message said.
#
# ── WHY THIS FILE EXISTS SEPARATELY FROM test_cx101_calendar_hydrate_path.sh
#
# That file asserts the calendar block "uses a documented env var for
# since_days" and deliberately accepts either name. It is a WIRING
# test and it passes at 90 days, at 1825, and at 1. It cannot catch a
# renarrowing, which is exactly the regression #554 is about. This
# file asserts the VALUES.
#
# ── THE TWO WAYS A GUARD LIKE THIS LIES, AND WHAT IS DONE ABOUT THEM
#
#   1. MATCHING A COMMENT. This block is now heavily commented and the
#      comments name the variables, the numbers 90 and 1825, and the
#      words "future_days". A bare grep would pass on the prose alone
#      with the code reverted. So every assertion below runs against
#      CODE_ONLY -- the block with comment lines and blank lines
#      stripped -- and Control A proves the stripping actually removes
#      something.
#
#   2. A DEFAULT THAT IS SET BUT NOT USED. Asserting the assignment
#      says nothing about what reaches extract_events. So the value
#      assertions and the plumbing assertions are separate, and the
#      plumbing ones require the variable to appear INSIDE the
#      extract_events( ... ) call.
#
# Controls are RUN, not asserted. See the PR body for the red/green
# transcript against the pre-fix install.sh.

set -euo pipefail

# 🔴 NO `printf ... | grep -q` ANYWHERE IN THIS FILE. `grep -q` exits on its
# first match and SIGPIPEs the writer, so under `set -o pipefail` the pipeline
# can report FAILURE on a needle that IS PRESENT -- a guard that inverts its own
# verdict. tests/test_pipefail_shortcircuit_inversion.sh ratchets on this
# construct and caught this file on its first CI run; every condition here is a
# herestring instead.
#
# 🔴 EVERY grep-BASED CAPTURE BELOW ENDS IN `|| true`, AND THAT IS LOAD-BEARING.
# Under `set -euo pipefail` a grep that matches NOTHING fails the pipeline and
# aborts the script on the spot. The first version of this file lacked those,
# and the red control caught it: against the pre-fix install.sh it reported the
# window and heartbeat failures, then died at the first non-matching capture
# and NEVER RAN axes 5 and 6. It still exited 1, so it still looked like a
# working guard. A test that stops early on the failing input is reporting a
# prefix of the truth, and the exit code hides it.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${OSTLER_TEST_INSTALL_SH:-${REPO_ROOT}/install.sh}"
STRINGS_SH="${OSTLER_TEST_STRINGS_SH:-${REPO_ROOT}/install.sh.strings.en-GB.sh}"
FAILED=0

# The floor the task sets: 5 years back, 1 year forward.
MIN_BACK_DAYS=1825
MIN_FORWARD_DAYS=365

failure() {
    echo "FAIL: $*" >&2
    FAILED=1
}

if [[ ! -f "$INSTALL_SH" ]]; then
    echo "FATAL: install.sh not found at $INSTALL_SH" >&2
    exit 2
fi

# ── --self-test: prove each control CAN go red ───────────────────────
#
# A control that has never been observed failing is not evidence that it can
# fail. This mode reinstates each half of the CX-92 defect in a COPY of
# install.sh (and of the strings catalogue) and requires the suite to go RED
# against it -- then requires the UNMUTATED copy to go GREEN, so that it is
# the mutation and not the copying that moved the verdict.
#
# It re-invokes this same file through OSTLER_TEST_INSTALL_SH /
# OSTLER_TEST_STRINGS_SH, so the predicate under test is the real one and not
# a paraphrase of it that could drift.
if [[ "${1:-}" == "--self-test" ]]; then
    ST_FAILED=0
    ST_DIR="$(mktemp -d)"
    trap 'rm -rf "$ST_DIR"' EXIT
    ST_SELF="${BASH_SOURCE[0]}"

    _st_run() {  # $1 = install.sh path, $2 = strings path
        OSTLER_TEST_INSTALL_SH="$1" OSTLER_TEST_STRINGS_SH="$2" \
            bash "$ST_SELF" >/dev/null 2>&1
    }

    _st_expect_red() {  # $1 = label, $2 = install.sh, $3 = strings
        if _st_run "$2" "$3"; then
            echo "SELF-TEST FAIL: $1 -- suite PASSED against a reinstated defect" >&2
            ST_FAILED=1
        else
            echo "  red as required: $1"
        fi
    }

    _st_mutation_landed() {  # $1 = label, $2 = before, $3 = after
        if cmp -s "$2" "$3"; then
            echo "SELF-TEST FAIL: $1 changed nothing -- the mutation missed its target" >&2
            ST_FAILED=1
        fi
    }

    cp "$INSTALL_SH" "${ST_DIR}/clean.sh"
    cp "$STRINGS_SH" "${ST_DIR}/clean.strings.sh"

    # BASELINE FIRST. If the untouched copies do not pass, every "red" below
    # is uninterpretable: it would be the copy failing, not the defect.
    if _st_run "${ST_DIR}/clean.sh" "${ST_DIR}/clean.strings.sh"; then
        echo "  green as required: unmutated copy"
    else
        echo "SELF-TEST FAIL: the UNMUTATED copy does not pass -- every red below is uninterpretable" >&2
        ST_FAILED=1
    fi

    # M1: renarrow the backward window to the CX-92 value.
    sed 's/OSTLER_HYDRATE_CALENDAR_DAYS:-1825/OSTLER_HYDRATE_CALENDAR_DAYS:-90/' \
        "${ST_DIR}/clean.sh" > "${ST_DIR}/m1.sh"
    _st_mutation_landed "M1" "${ST_DIR}/clean.sh" "${ST_DIR}/m1.sh"
    _st_expect_red "M1 backward window back to 90d" \
        "${ST_DIR}/m1.sh" "${ST_DIR}/clean.strings.sh"

    # M2: restore the literal forward window.
    sed 's/future_days=${OSTLER_HYDRATE_CALENDAR_FUTURE_DAYS}/future_days=30/' \
        "${ST_DIR}/clean.sh" > "${ST_DIR}/m2.sh"
    _st_mutation_landed "M2" "${ST_DIR}/clean.sh" "${ST_DIR}/m2.sh"
    _st_expect_red "M2 forward window back to a literal 30" \
        "${ST_DIR}/m2.sh" "${ST_DIR}/clean.strings.sh"

    # M3: remove the heartbeat, so a multi-year ingest reads as a hang again.
    sed '/_hydrate_heartbeat_start "\$MSG_HYDRATE_CALENDAR_HEARTBEAT"/d' \
        "${ST_DIR}/clean.sh" > "${ST_DIR}/m3.sh"
    _st_mutation_landed "M3" "${ST_DIR}/clean.sh" "${ST_DIR}/m3.sh"
    _st_expect_red "M3 heartbeat removed" \
        "${ST_DIR}/m3.sh" "${ST_DIR}/clean.strings.sh"

    # M4: put the 90-day promise back in the sentence the customer reads.
    sed 's/^MSG_HYDRATE_CALENDAR_STARTED=.*/MSG_HYDRATE_CALENDAR_STARTED="Loading your last 90 days of calendar"/' \
        "${ST_DIR}/clean.strings.sh" > "${ST_DIR}/m4.strings.sh"
    _st_mutation_landed "M4" "${ST_DIR}/clean.strings.sh" "${ST_DIR}/m4.strings.sh"
    _st_expect_red "M4 customer string promises 90 days again" \
        "${ST_DIR}/clean.sh" "${ST_DIR}/m4.strings.sh"

    # M5: THE COMMENT TRAP, and the reason this file strips comments at all.
    # Leave the M1 defect in place and inject a COMMENT naming every variable
    # and value the assertions look for. A guard that matched prose would go
    # GREEN here. That is the single most likely way this file rots into
    # decoration, and it is the exact failure the estate hit elsewhere.
    {
        echo '# OSTLER_HYDRATE_CALENDAR_DAYS="${OSTLER_HYDRATE_CALENDAR_DAYS:-1825}"'
        echo '# OSTLER_HYDRATE_CALENDAR_FUTURE_DAYS="${OSTLER_HYDRATE_CALENDAR_FUTURE_DAYS:-365}"'
        echo '# events = extract_events(since_days=${OSTLER_HYDRATE_CALENDAR_DAYS}, future_days=${OSTLER_HYDRATE_CALENDAR_FUTURE_DAYS})'
        echo '# _hydrate_heartbeat_start "$MSG_HYDRATE_CALENDAR_HEARTBEAT"'
        echo '# _hydrate_heartbeat_stop'
    } > "${ST_DIR}/prose.txt"
    awk -v prose="${ST_DIR}/prose.txt" '
        /^# Calendar hydration/ {
            print
            while ((getline line < prose) > 0) print line
            close(prose)
            next
        }
        { print }
    ' "${ST_DIR}/m1.sh" > "${ST_DIR}/m5.sh"
    _st_mutation_landed "M5" "${ST_DIR}/m1.sh" "${ST_DIR}/m5.sh"
    _st_expect_red "M5 defect present but a comment names every token" \
        "${ST_DIR}/m5.sh" "${ST_DIR}/clean.strings.sh"

    if (( ST_FAILED == 0 )); then
        echo "PASS: tests/test_cx92_calendar_historical_backfill.sh --self-test"
        exit 0
    fi
    echo "FAILED: tests/test_cx92_calendar_historical_backfill.sh --self-test" >&2
    exit 1
fi

# ── Carve the Calendar hydration block ───────────────────────────────
# Bounded by STRUCTURE (its own header to the next hydration header),
# never by a line count, so the slice cannot silently drift as the file
# grows.
CAL_HEADER_LINE="$(grep -n '^# Calendar hydration' "$INSTALL_SH" | head -1 | cut -d: -f1 || true)"
if [[ -z "$CAL_HEADER_LINE" ]]; then
    echo "FATAL: could not locate '# Calendar hydration' block header" >&2
    exit 2
fi
NEXT_HEADER_LINE="$(awk -v start="$CAL_HEADER_LINE" '
    NR > start && /^# (Email|WhatsApp|Browser|iMessage) hydration/ { print NR; exit }
' "$INSTALL_SH")"
if [[ -z "$NEXT_HEADER_LINE" ]]; then
    echo "FATAL: could not locate end of Calendar hydration block" >&2
    exit 2
fi

CAL_BLOCK="$(sed -n "${CAL_HEADER_LINE},${NEXT_HEADER_LINE}p" "$INSTALL_SH")"

# CODE_ONLY: comment lines and blanks removed. Everything below reads
# this, never CAL_BLOCK.
CODE_ONLY="$(grep -vE '^[[:space:]]*(#|$)' <<< "$CAL_BLOCK" || true)"

# ── Control A: the comment stripper actually strips ──────────────────
# If CODE_ONLY were ever identical to CAL_BLOCK, every "in CODE" claim
# below would silently become a claim about prose. This is the guard on
# the guard.
if [[ "$CODE_ONLY" == "$CAL_BLOCK" ]]; then
    failure "CONTROL A: comment stripping removed nothing -- assertions below would be matching comments"
fi
if ! grep -qE '^[[:space:]]*#' <<< "$CAL_BLOCK"; then
    failure "CONTROL A: the carved block contains no comment lines at all -- the carve is wrong"
fi

# ── Control B: the carve caught the right region, both ends ──────────
if ! grep -q 'extract_events(' <<< "$CODE_ONLY"; then
    failure "CONTROL B: carved block has no extract_events( call -- the slice missed the calendar extract"
fi
if grep -q 'pwg-email-ingest' <<< "$CODE_ONLY"; then
    failure "CONTROL B: carved block reaches into the email hydrate -- the slice runs past its end"
fi

# ── Axis 1: the BACKWARD window default is multi-year ────────────────
BACK_DEFAULT="$(
    printf '%s\n' "$CODE_ONLY" \
    | sed -n 's/^OSTLER_HYDRATE_CALENDAR_DAYS="\${OSTLER_HYDRATE_CALENDAR_DAYS:-\([0-9]\{1,\}\)}"$/\1/p' \
    | head -1
)"
if [[ -z "$BACK_DEFAULT" ]]; then
    failure "no OSTLER_HYDRATE_CALENDAR_DAYS default assignment found in CODE (comments do not count)"
elif (( BACK_DEFAULT < MIN_BACK_DAYS )); then
    failure "install-time calendar backfill default is ${BACK_DEFAULT}d; #554 requires at least ${MIN_BACK_DAYS}d (5 years). 90 here is the exact CX-92 regression."
fi

# ── Axis 2: the FORWARD window default is at least a year ────────────
FWD_DEFAULT="$(
    printf '%s\n' "$CODE_ONLY" \
    | sed -n 's/^OSTLER_HYDRATE_CALENDAR_FUTURE_DAYS="\${OSTLER_HYDRATE_CALENDAR_FUTURE_DAYS:-\([0-9]\{1,\}\)}"$/\1/p' \
    | head -1
)"
if [[ -z "$FWD_DEFAULT" ]]; then
    failure "no OSTLER_HYDRATE_CALENDAR_FUTURE_DAYS default assignment found in CODE -- the forward window is still a literal"
elif (( FWD_DEFAULT < MIN_FORWARD_DAYS )); then
    failure "install-time calendar forward window default is ${FWD_DEFAULT}d; #554 requires at least ${MIN_FORWARD_DAYS}d (1 year)"
fi

# ── Axis 3: both windows are PLUMBED, not merely declared ────────────
# The whole point of #554 is that the value must be controllable at
# install time. A default that is set and then not passed is the same
# defect wearing a variable's name. Require each var inside the
# extract_events( ... ) call itself.
EXTRACT_CALL="$(grep -E 'extract_events\(' <<< "$CODE_ONLY" | head -1 || true)"
if [[ -z "$EXTRACT_CALL" ]]; then
    failure "no extract_events( call in CODE"
else
    if ! grep -qE 'since_days=\$\{OSTLER_HYDRATE_CALENDAR_DAYS\}' <<< "$EXTRACT_CALL"; then
        failure "extract_events does not receive OSTLER_HYDRATE_CALENDAR_DAYS as since_days: ${EXTRACT_CALL}"
    fi
    if ! grep -qE 'future_days=\$\{OSTLER_HYDRATE_CALENDAR_FUTURE_DAYS\}' <<< "$EXTRACT_CALL"; then
        failure "extract_events does not receive OSTLER_HYDRATE_CALENDAR_FUTURE_DAYS as future_days: ${EXTRACT_CALL}"
    fi
    # The literal that #554 is about. Belt to Axis 2's braces: it fails
    # even if someone adds the variable and leaves the literal winning.
    if grep -qE 'future_days=[0-9]' <<< "$EXTRACT_CALL"; then
        failure "extract_events still passes a LITERAL future_days: ${EXTRACT_CALL}"
    fi
    if grep -qE 'since_days=[0-9]' <<< "$EXTRACT_CALL"; then
        failure "extract_events still passes a LITERAL since_days: ${EXTRACT_CALL}"
    fi
fi

# ── Axis 4: a wide window must not read as a hang ────────────────────
# The measured cost of a multi-year window is not the sqlite read
# (0.020s at 1825d on a 15,926-row store) but the Oxigraph ingest,
# which opens a fresh connection per SPARQL statement and issues
# thousands of them with nothing on screen. CX-106 answered that by
# narrowing the window, which cost the customer their history. The
# heartbeat is what makes the wide window survivable, so it is part of
# the contract, not a nicety.
if ! grep -q '_hydrate_heartbeat_start' <<< "$CODE_ONLY"; then
    failure "Calendar hydration block starts no heartbeat -- a multi-year ingest would look like a hung installer"
fi
if ! grep -q '_hydrate_heartbeat_stop' <<< "$CODE_ONLY"; then
    failure "Calendar hydration block never stops its heartbeat -- the ticker would outlive the step"
fi
# Ordering: start before the extract, stop after the ingest. A ticker
# that stops before the slow half is decoration.
HB_START_LN="$(grep -n '_hydrate_heartbeat_start' <<< "$CODE_ONLY" | head -1 | cut -d: -f1 || true)"
HB_STOP_LN="$(grep -n '_hydrate_heartbeat_stop' <<< "$CODE_ONLY" | head -1 | cut -d: -f1 || true)"
INGEST_LN="$(grep -n 'ingest_calendar(' <<< "$CODE_ONLY" | head -1 | cut -d: -f1 || true)"
EXTRACT_LN="$(grep -n 'extract_events(' <<< "$CODE_ONLY" | head -1 | cut -d: -f1 || true)"
if [[ -n "$HB_START_LN" && -n "$HB_STOP_LN" && -n "$INGEST_LN" && -n "$EXTRACT_LN" ]]; then
    if (( HB_START_LN > EXTRACT_LN )); then
        failure "heartbeat starts AFTER the extract (${HB_START_LN} > ${EXTRACT_LN})"
    fi
    if (( HB_STOP_LN < INGEST_LN )); then
        failure "heartbeat stops BEFORE the Oxigraph ingest (${HB_STOP_LN} < ${INGEST_LN}) -- it would cover only the fast half"
    fi
fi

# ── Axis 5: the installer must not still SAY 90 days ─────────────────
# The bug report is a quote of the installer's own words. A window that
# widened while the message kept promising 90 days would be a second
# defect, not a fix, and it is the surface the customer actually reads.
if [[ -f "$STRINGS_SH" ]]; then
    CAL_STARTED="$(grep -E '^MSG_HYDRATE_CALENDAR_STARTED=' "$STRINGS_SH" | head -1 || true)"
    if [[ -z "$CAL_STARTED" ]]; then
        failure "MSG_HYDRATE_CALENDAR_STARTED not found in ${STRINGS_SH}"
    elif grep -qE '90 days|90-day' <<< "$CAL_STARTED"; then
        failure "MSG_HYDRATE_CALENDAR_STARTED still promises 90 days: ${CAL_STARTED}"
    fi
    if ! grep -qE '^MSG_HYDRATE_CALENDAR_HEARTBEAT=' "$STRINGS_SH"; then
        failure "MSG_HYDRATE_CALENDAR_HEARTBEAT not defined -- the heartbeat would print an empty line and silently no-op"
    fi
else
    failure "strings catalogue not found at ${STRINGS_SH}"
fi

# ── Axis 6: the block still parses ───────────────────────────────────
# Cheap whole-file syntax check. A heredoc edit is the classic way to
# break an installer in a manner no grep-based test would notice.
if ! bash -n "$INSTALL_SH" 2>/dev/null; then
    failure "install.sh does not parse (bash -n) after this change"
fi

if (( FAILED == 0 )); then
    echo "PASS: tests/test_cx92_calendar_historical_backfill.sh"
    exit 0
else
    echo "FAILED: tests/test_cx92_calendar_historical_backfill.sh" >&2
    exit 1
fi
