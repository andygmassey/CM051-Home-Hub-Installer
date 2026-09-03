#!/usr/bin/env bash
# A LaunchAgent refusal must say WHY, WHERE SOMEONE READS IT, and say whether
# the question was answerable at all.
#
# ── THE TWO DEFECTS, BOTH MEASURED AT SOURCE 2026-09-04 ──────────────────────
#
# 1. THE REASON WAS WRITTEN SOMEWHERE NOBODY LOOKS.
#    _ostler_launchagent_note_refusal appended the cause to
#    ${LOGS_DIR}/launchagent-load.log and nowhere else. Measured, by name,
#    on both collectors:
#        grep -c launchagent-load scripts/ttywalk.sh    -> 0
#        grep -c launchagent-load scripts/walk_drive.py -> 0
#    So the customer-visible line was "Doctor not loaded" with no cause, and
#    the cause sat in a file no walk has ever read. Diagnosing the Mini 16
#    Doctor failure therefore cost a SECOND full 21-minute install, and the
#    answer had been sitting on the box the whole time.
#
# 2. "THIS AGENT IS BROKEN" AND "NO AGENT CAN LOAD" PRINTED IDENTICALLY.
#    `gui/<uid>` exists only while that user has a window-server session. An
#    install driven over ssh with nobody logged in at the GUI has no such
#    domain, and then all 14 load sites fail at once for a reason that has
#    nothing to do with any plist. Nothing anywhere in install.sh probed the
#    DOMAIN -- measured: 6 `launchctl print gui/<uid>/...` call sites, every
#    one of them LABEL-scoped, zero domain-scoped.
#
#    That is the instrument being reported as the subject, which is exactly
#    the failure that cost three separate diagnoses in one night. A domain we
#    cannot reach is CANNOT-RUN. CANNOT-RUN is not a product failure and it
#    is not a pass.
#
# ── WHAT THIS FILE GRADES ───────────────────────────────────────────────────
# The PROPERTY, not the spelling. Arms B/C require the two states to produce
# DIFFERENT text, so a refusal that says the same thing both ways fails even
# if every word is present. Arm F is the negative control: a mutant that keeps
# the file write and drops the transcript write MUST fail arm B, or this file
# is certifying nothing.
#
# rc=2 means the harness could not set itself up. That is not a pass.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${REPO_ROOT}/install.sh"

cannot() { echo "CANNOT-RUN [$1]: $2" >&2; exit 2; }
[ -f "$SRC" ] || cannot "no-install-sh" "$SRC not found -- nothing was checked."

PASS=0; FAIL=0
ok()  { printf 'ok   %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf 'FAIL %s\n' "$*" >&2; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d 2>/dev/null || mktemp -d -t ostler-refusal)"
# `mktemp -d -t NAME` with no X's is BSD-only; GNU refuses it and leaves the
# variable EMPTY, which would make every path below land in /. Hence the ||.
[ -n "$WORK" ] && [ -d "$WORK" ] || cannot "no-tmpdir" "could not create a work dir."
trap 'rm -rf "$WORK"' EXIT

# ── extract the two functions, so the test runs the REAL code ───────────────
# Both close with a `}` in column 1, which is what bounds the awk ranges.
extract() {
    awk '/^_ostler_gui_domain_reachable\(\) \{$/,/^\}$/' "$SRC"
    awk '/^_ostler_launchagent_note_refusal\(\)/,/^\}$/'  "$SRC"
}
extract > "${WORK}/lib.sh"

# ── PREMISE vs DEFECT: which absence is which ───────────────────────────────
#
# These two absences are NOT the same and must not grade the same way.
#
#   note_refusal absent          -> CANNOT-RUN. There is no subject; this file
#                                   cannot say anything about anything.
#   gui_domain_reachable absent  -> FAIL. That IS defect 2. The discriminator
#                                   not existing is the whole finding, so
#                                   grading it CANNOT-RUN would let the
#                                   original defect report as unmeasurable
#                                   rather than as broken.
#
# Written the other way round first, this file reported rc=2 against real
# pre-fix code and demonstrated nothing. An absent mechanism is a failure,
# not an inability to measure.
grep -q '^_ostler_launchagent_note_refusal' "${WORK}/lib.sh" \
    || cannot "premise" "_ostler_launchagent_note_refusal did not extract from install.sh; there is no subject to grade."
ok "premise: the refusal function extracted from install.sh ($(wc -l < "${WORK}/lib.sh" | tr -d ' ') lines)"

HAVE_DOMAIN=1
if ! grep -q '^_ostler_gui_domain_reachable' "${WORK}/lib.sh"; then
    HAVE_DOMAIN=0
    bad "there is NO gui-domain probe at all, so 'this agent is broken' and \
'no agent can load in this session' are indistinguishable by construction. \
This is defect 2, not an unmeasurable condition."
fi

# ── the harness: run note_refusal with launchctl and warn under our control ──
# $1 = domain probe rc (0 reachable, 1 unreachable), $2 = lib to source.
# Prints everything warn() was handed.
#
# ⚠️ THE STUBS MUST CAPTURE THE SCRIPT'S ARGS INTO NAMED VARIABLES FIRST.
# Written as `launchctl() { return "$1"; }` this harness reported the product
# broken: inside a FUNCTION, $1 is the FUNCTION's argument, so the stub read
# `print` (from `launchctl print gui/<uid>`) as its return code and the probe
# failed unconditionally. Two arms went red against correct code. The
# instrument was the defect -- again -- so the capture is not tidiness.
run_refusal() {
    local _rc="$1" _lib="$2"
    env -u _OSTLER_GUI_DOMAIN_STATE LOGS_DIR="${WORK}/logs" bash -c '
        set -uo pipefail
        _WANT_RC="$1"; _LIB="$2"
        source "$_LIB"
        launchctl() { return "$_WANT_RC"; }   # the domain probe, under control
        warn() { printf "WARN %s\n" "$*"; }   # the transcript, captured
        _ostler_launchagent_note_refusal \
            "com.ostler.doctor" \
            "not registered in gui/501 after bootstrap+load" \
            "Bootstrap failed: 5: Input/output error"
    ' _ "$_rc" "$_lib" 2>&1
}

# ── A. the reason reaches the transcript at all ─────────────────────────────
OUT_UNREACH="$(run_refusal 1 "${WORK}/lib.sh")"
if grep -q 'not registered in gui/501' <<< \"$OUT_UNREACH\"; then
    ok "the refusal REASON reaches warn (the transcript a walk captures)"
else
    bad "the reason never reached warn. THE DEFECT: it goes only to \
\${LOGS_DIR}/launchagent-load.log, which 0 of 2 collectors read."
fi

# ── B. domain UNREACHABLE is named as such ──────────────────────────────────
if grep -q 'IS NOT REACHABLE' <<< \"$OUT_UNREACH\"; then
    ok "domain unreachable is NAMED, not reported as an agent defect"
else
    bad "an unreachable gui domain read like a broken agent. Every 'not \
loaded' warning in an ssh-driven run would then be a false accusation."
fi

# ── C. domain REACHABLE says something DIFFERENT ────────────────────────────
# This is the arm that makes B mean anything: a scope line that is constant
# across both states discriminates nothing.
OUT_REACH="$(run_refusal 0 "${WORK}/lib.sh")"
if grep -q 'IS NOT REACHABLE' <<< \"$OUT_REACH\"; then
    bad "a REACHABLE domain still printed the unreachable text -- the probe \
is not consulted, or its sense is inverted."
elif [ "$OUT_REACH" = "$OUT_UNREACH" ]; then
    bad "reachable and unreachable produced BYTE-IDENTICAL output. The \
discriminator does not discriminate."
else
    ok "reachable and unreachable produce DIFFERENT text (the discriminator works)"
fi

# ── D. launchd's own words survive ──────────────────────────────────────────
# `2>/dev/null` on this stderr is what hid the cause in the first place.
if grep -q 'Bootstrap failed: 5' <<< \"$OUT_UNREACH\"; then
    ok "launchd's own stderr reaches the transcript"
else
    bad "launchd's stderr was dropped. That text IS the diagnosis; discarding \
it is what cost a second full install."
fi

# ── E. the durable file is still written (the fix must not remove evidence) ──
if [ -s "${WORK}/logs/launchagent-load.log" ]; then
    ok "the durable ${WORK##*/}/logs/launchagent-load.log is still written"
else
    bad "the side-file write was lost. Adding a transcript line must not \
remove the durable record."
fi

# ── F. NEGATIVE CONTROL ─────────────────────────────────────────────────────
# The pre-fix shape: keep the file write, drop every warn. Arm B MUST fail
# against it. Without this arm, a note_refusal that printed nothing at all
# could still pass A-E by accident of grep matching some other line.
sed -e 's/^    warn /    : /' -e 's/^            \[\[ -n "\$_l" \]\] && warn /            [[ -n "$_l" ]] \&\& : /' \
    "${WORK}/lib.sh" > "${WORK}/mutant.sh"
if ! grep -q '^    warn ' "${WORK}/mutant.sh"; then
    MUT="$(run_refusal 1 "${WORK}/mutant.sh")"
    if grep -q 'IS NOT REACHABLE' <<< \"$MUT\"; then
        bad "CONTROL: the mutant with every warn removed STILL passed arm B. \
This file grades nothing."
    else
        ok "CONTROL: a mutant that writes only the side file FAILS arm B"
    fi
else
    bad "CONTROL: the mutation did not take (warn lines still present), so \
the control proves nothing. Check the sed against the current indentation."
fi

# ── G. the domain is probed ONCE per run, not once per agent ────────────────
# 14 call sites; a probe per site is 14 launchctl invocations for one answer.
PROBES="$(env -u _OSTLER_GUI_DOMAIN_STATE LOGS_DIR="${WORK}/logs2" bash -c '
    set -uo pipefail
    _LIB="$1"; _TALLY="$2"
    source "$_LIB"
    launchctl() { echo probe >> "$_TALLY"; return 1; }
    warn() { :; }
    _ostler_launchagent_note_refusal a "r" ""
    _ostler_launchagent_note_refusal b "r" ""
    _ostler_launchagent_note_refusal c "r" ""
' _ "${WORK}/lib.sh" "${WORK}/probes" >/dev/null 2>&1; wc -l < "${WORK}/probes" 2>/dev/null | tr -d ' ')"
if [ "${PROBES:-0}" = "1" ]; then
    ok "the gui-domain probe runs ONCE across 3 refusals (cached)"
else
    bad "the domain was probed ${PROBES:-0} times across 3 refusals; expected 1. \
An uncached probe is 14 launchctl calls per install for one unchanging answer."
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
printf 'A LAUNCHAGENT REFUSAL SAYS WHY, WHERE IT IS READ, AND WHETHER IT COULD BE ANSWERED\n'
