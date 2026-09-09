#!/usr/bin/env bash
# tests/test_the_merge_budget_scales_with_the_address_book.sh
# ============================================================================
# THE DEFECT, measured on the v1.0.79 box. The install-time contact merge ran
# under a FLAT 300 s cap and was killed at exactly that:
#
#     state/dedupe-converge.killed
#       killed_at_utc=2026-09-08T21:34:13Z
#       waited_s=300  budget_s=300  signal=SIGTERM then SIGKILL
#
# converge_kill_is_recorded has FAILED on that ever since. A flat cap cannot be
# right for a fixpoint loop whose cost grows with the address book: 300 s is
# generous for 200 contacts and impossible for 2000.
#
# K IS MEASURED, AND THIS TEST PINS THE MEASUREMENT. From the same box's
# catch-up log, running the identical converge to its round cap:
#     Loaded 1822 active person nodes    05:44:15
#     Converge hit max_rounds=10         05:59:33
# 919 s for 1822 persons = 0.504 s per person; ~908 s for a book of 1800. The
# brief requires at least a 1.5x margin over that, so budget(1800) >= 1362 s.
# K = 0.7 s/person gives 1490 s, a margin of 1.64x.
#
# THE BASELINE IS A DELIBERATE DEVIATION FROM THE BRIEF'S FORMULA, and this
# test is where it is visible. The brief said clamp(300 + persons*K, 300, 1800)
# AND that persons=100 must give 300. No K > 0 satisfies both: 300 + 100K > 300.
# The implementation subtracts a baseline of 100 so both stated acceptance
# cases hold, and both are asserted below as the brief wrote them.
#
# NO PIPE INTO grep -q: it SIGPIPEs the producer and under pipefail reports
# failure for a pattern it found. Counted form only.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SRC="$REPO/install.sh"

PASS=0
FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  [FAIL] %s\n' "$1"; shift; [ $# -gt 0 ] && printf '%s\n' "$*" | sed 's/^/         /'; FAIL=$((FAIL + 1)); }

[ -r "$SRC" ] || { printf 'CANNOT-RUN: no install.sh at %s\n' "$SRC"; exit 78; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

printf 'THE MERGE BUDGET SCALES WITH THE ADDRESS BOOK\n\n'

# ---------------------------------------------------------------------------
# Extract the derivation from the SHIPPED file, from the K constants to the
# budget assignment. The person-count call is NOT included: it is stubbed, so
# these arms test the arithmetic rather than the network.
# ---------------------------------------------------------------------------
region="$(awk '
    /^    _DEDUPE_K_NUM=/ { f = 1 }
    f { print }
    f && /^    _DEDUPE_BUDGET_S=/ { exit }
' "$SRC")"

n="$(printf '%s\n' "$region" | grep -c .)"
if [ "$n" -lt 8 ] || [ "$n" -gt 30 ]; then
    bad "extracted ${n} lines for the budget derivation, implausible; refusing to eval" \
        "the anchors moved, so this suite measures nothing until they are fixed"
    printf '\n== %s pass / %s fail ==\n' "$PASS" "$FAIL"
    exit 78
fi
ok "extracted the budget derivation from the shipped install.sh (${n} lines)"

derive() { # $1 = persons ("" = unreadable), $2 = optional env override, $3 = region
    (
        set +u
        _DEDUPE_PERSONS="$1"
        [ -n "$2" ] && OSTLER_DEDUPE_INSTALL_BUDGET_S="$2"
        eval "$3"
        printf '%s\n' "$_DEDUPE_BUDGET_S"
    )
}

# ---------------------------------------------------------------------------
# THE TWO ACCEPTANCE CASES, exactly as the brief states them.
# ---------------------------------------------------------------------------
b100="$(derive 100 "" "$region")"
[ "$b100" = "300" ] \
    && ok "persons=100 gives exactly 300 (the brief's first case, and why the baseline exists)" \
    || bad "persons=100 gave ${b100}, expected 300"

b1800="$(derive 1800 "" "$region")"
if [ "$b1800" -ge 1200 ] && [ "$b1800" -le 1800 ]; then
    ok "persons=1800 gives ${b1800}, inside the brief's [1200, 1800]"
else
    bad "persons=1800 gave ${b1800}, outside [1200, 1800]"
fi

# ---------------------------------------------------------------------------
# THE MARGIN THE BRIEF ASKED FOR, asserted rather than asserted-in-a-comment.
# 1822 persons took 919 s measured, so a book of 1800 takes about 908 s.
# ---------------------------------------------------------------------------
MEASURED_1800=908
if [ "$((b1800 * 100 / MEASURED_1800))" -ge 150 ]; then
    ok "and that is a margin of $((b1800 * 100 / MEASURED_1800))% over the measured ${MEASURED_1800}s, at or above the 1.5x required"
else
    bad "margin is only $((b1800 * 100 / MEASURED_1800))% of the measured ${MEASURED_1800}s, below the 1.5x required"
fi

# ---------------------------------------------------------------------------
# The clamps, at both ends, and the unreadable case.
# ---------------------------------------------------------------------------
b_small="$(derive 5 "" "$region")"
[ "$b_small" = "300" ] \
    && ok "a tiny book still gets the 300s floor, never less" \
    || bad "a tiny book gave ${b_small}"

b_huge="$(derive 99999 "" "$region")"
[ "$b_huge" = "1800" ] \
    && ok "an enormous book is capped at 1800s, so the install cannot hang for ever" \
    || bad "a huge book gave ${b_huge}, expected the 1800 cap"

b_unread="$(derive "" "" "$region")"
[ "$b_unread" = "300" ] \
    && ok "an UNREADABLE person count takes the floor, so a graph we could not ask never buys a longer install" \
    || bad "an unreadable count gave ${b_unread}, expected 300"

b_junk="$(derive "not-a-number" "" "$region")"
[ "$b_junk" = "300" ] \
    && ok "and a non-numeric count does the same rather than doing arithmetic on it" \
    || bad "a non-numeric count gave ${b_junk}"

# ---------------------------------------------------------------------------
# The env override must still win: the walk harness and support rely on it.
# ---------------------------------------------------------------------------
b_over="$(derive 1800 45 "$region")"
[ "$b_over" = "45" ] \
    && ok "OSTLER_DEDUPE_INSTALL_BUDGET_S still wins over the derivation" \
    || bad "the override gave ${b_over}, expected 45"

# ---------------------------------------------------------------------------
# MONOTONIC: a bigger book never gets a smaller budget. Integer truncation is
# the obvious way to break this without noticing.
# ---------------------------------------------------------------------------
prev=0; mono=1
for pcount in 100 200 500 1000 1500 1800 2000 5000; do
    v="$(derive "$pcount" "" "$region")"
    [ "$v" -lt "$prev" ] && mono=0
    prev="$v"
done
[ "$mono" -eq 1 ] \
    && ok "the budget is monotonic in the person count across 100..5000" \
    || bad "a larger book received a smaller budget"

# ---------------------------------------------------------------------------
# MUST-FAIL: the old flat constant. Restore it and the acceptance cases must
# stop holding, or the arms above are proving nothing about the change.
# ---------------------------------------------------------------------------
flat='_DEDUPE_BUDGET_S="${OSTLER_DEDUPE_INSTALL_BUDGET_S:-300}"'
b_flat="$( set +u; eval "$flat"; printf '%s\n' "$_DEDUPE_BUDGET_S" )"
if [ "$b_flat" = "300" ]; then
    ok "the old flat constant still yields 300 for any book (the mutant is real)"
    if [ "$b_flat" -ge 1200 ]; then
        bad "MUST-FAIL: the flat constant satisfied the 1800-person case; the arms above prove nothing"
    else
        ok "MUST-FAIL: the flat constant gives 300 at 1800 persons, failing [1200,1800], which is the defect"
    fi
    if [ "$((b_flat * 100 / MEASURED_1800))" -ge 150 ]; then
        bad "MUST-FAIL: the flat constant met the margin; the margin arm proves nothing"
    else
        ok "and it is only $((b_flat * 100 / MEASURED_1800))% of the measured time, which is why the pass was killed at 300s"
    fi
else
    bad "the flat constant did not reproduce; the must-fail arms cannot mean anything"
fi

# ---------------------------------------------------------------------------
# The kill and its marker must SURVIVE. The fix is that the kill does not fire
# on a real book, not that it stops being recorded.
# ---------------------------------------------------------------------------
[ "$(grep -c 'signal=SIGTERM then SIGKILL' "$SRC")" -gt 0 ] \
    && ok "the killed marker still records the signal, so an exceeded budget still leaves evidence" \
    || bad "the killed marker lost its signal line"
[ "$(grep -c 'persons=%s' "$SRC")" -gt 0 ] \
    && ok "and the marker now carries the person count beside the budget it failed to meet" \
    || bad "the marker records a budget with none of the inputs that produced it"

# ===========================================================================
# THE READER ITSELF, RUN FOR REAL, UNDER THE FILE'S OWN errexit AND ERR TRAP.
#
# Everything above stubs _DEDUPE_PERSONS and tests the arithmetic. That is why
# none of it could see the defect Archie found: the reader was never invoked by
# any arm (grep -c python3 on this file was 0, against 12 hits for budget), and
# a driver that stubs the function cannot fail on how the function is written.
#
# THE DEFECT. The parse arm ran /usr/bin/python3. On a stock Mac with no
# Command Line Tools that is an Apple STUB which fires the CLT dialog and
# returns non-zero -- install.sh says so itself at :1983 and picks a bundled
# interpreter for the licence verifier for exactly that reason. Under
# `set -Eeuo pipefail` and the ERR trap the consequence was not a missing count
# but an ABORTED INSTALL: stub exits non-zero, pipefail fails the pipeline, it
# is the function's last command so the function returns non-zero, the bare
# assignment carries that status, the trap fires. A budget optimisation would
# have stopped the install on every customer Mac without developer tools.
#
# So these arms run the SHIPPED function with a stub interpreter, under the
# same shell options and an ERR trap that records if it fires.
# ===========================================================================
printf '\n-- the reader, run for real under errexit + ERR trap --\n'

fn_src="$(awk '
    /^_ostler_dedupe_person_count\(\) \{$/ { f = 1 }
    f { print }
    f && /^\}$/ { exit }
' "$SRC")"

fn_lines="$(printf '%s\n' "$fn_src" | grep -c .)"
if [ "$fn_lines" -lt 8 ] || [ "$fn_lines" -gt 60 ]; then
    bad "extracted ${fn_lines} lines for the reader, implausible; the arms below would measure nothing"
else
    ok "extracted the shipped reader (${fn_lines} lines)"

    [ "$(printf '%s\n' "$fn_src" | grep -vE '^[[:space:]]*#' | grep -c '/usr/bin/python3')" -eq 0 ] \
        && ok "no CODE line in the reader calls /usr/bin/python3 (the stub that aborts a stock Mac)" \
        || bad "the reader still calls /usr/bin/python3 on a code line"

    # Drive it. $1 = what the fake interpreter does, $2 = label
    drive_reader() {
        local py_body="$1"
        local dir; dir="$(mktemp -d)"
        mkdir -p "$dir/.venv/bin" "$dir/bin"
        printf '#!/bin/sh\n%s\n' "$py_body" > "$dir/.venv/bin/python3"
        chmod +x "$dir/.venv/bin/python3"
        # A curl that answers with a well-formed body, so the ONLY variable
        # under test is the interpreter.
        printf '#!/bin/sh\nprintf %s "{\\"results\\":{\\"bindings\\":[{\\"n\\":{\\"value\\":\\"1822\\"}}]}}"\n' "" \
            > "$dir/bin/curl"
        chmod +x "$dir/bin/curl"
        (
            PATH="$dir/bin:$PATH"; export PATH
            PIPELINE_DIR="$dir"
            set -Eeuo pipefail
            trap 'printf "TRAP_FIRED\n"' ERR
            eval "$fn_src"
            _DEDUPE_PERSONS="$(_ostler_dedupe_person_count)"
            printf 'COUNT=[%s] RC=%s\n' "$_DEDUPE_PERSONS" "$?"
        ) 2>/dev/null
        rm -rf "$dir"
    }

    # ARM: the CLT stub. Exits non-zero, prints nothing, exactly as the Apple
    # stub does after firing its dialog.
    out_stub="$(drive_reader 'exit 1')"
    if [ "$(printf '%s\n' "$out_stub" | grep -c 'TRAP_FIRED')" -eq 0 ]; then
        ok "a non-zero interpreter does NOT fire the ERR trap, so the install does not abort"
    else
        bad "the ERR trap fired: this is the aborted-install defect" "$out_stub"
    fi
    [ "$(printf '%s\n' "$out_stub" | grep -c 'COUNT=\[\]')" -gt 0 ] \
        && ok "and it yields an empty count, which the derivation turns into the 300s floor" \
        || bad "a failing interpreter did not yield an empty count" "$out_stub"

    # ARM: a working interpreter still reads the number.
    out_ok="$(drive_reader 'cat >/dev/null; printf "1822\n"')"
    [ "$(printf '%s\n' "$out_ok" | grep -c 'COUNT=\[1822\]')" -gt 0 ] \
        && ok "a working interpreter still returns the count (1822), so the guard did not blind the reader" \
        || bad "the working case no longer reads a count" "$out_ok"
    [ "$(printf '%s\n' "$out_ok" | grep -c 'TRAP_FIRED')" -eq 0 ] \
        && ok "and the working case fires no trap either" \
        || bad "the trap fired on the working case" "$out_ok"

    # MUST-FAIL: put the unguarded stub interpreter back and the trap MUST fire.
    # Without this the arms above would pass on a shell where errexit was not
    # actually in force, which is the way this class of test lies.
    mut_fn="$(printf '%s\n' "$fn_src" | sed 's|"$PIPELINE_DIR/.venv/bin/python3"|/usr/bin/false|; s|'"'"' 2>/dev/null \|\| true$|'"'"' 2>/dev/null|')"
    if [ "$(printf '%s\n' "$mut_fn" | grep -c '/usr/bin/false')" -eq 0 ]; then
        bad "the mutation did not land; the must-fail arm proves nothing"
    else
        ok "the mutation landed (unguarded, failing interpreter restored)"
        out_mut="$( fn_src="$mut_fn" drive_reader 'exit 1' )"
        if [ "$(printf '%s\n' "$out_mut" | grep -c 'TRAP_FIRED')" -gt 0 ]; then
            ok "MUST-FAIL: unguarded, the ERR trap DOES fire, which is the aborted install on a stock Mac"
        else
            bad "MUST-FAIL: no trap even unguarded; errexit is not in force and the arms above are hollow" "$out_mut"
        fi
    fi
fi

printf '\n== %s pass / %s fail / %s total ==\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
