#!/usr/bin/env bash
# tests/test_no_probe_shadows_the_dispatcher.sh
# ============================================================================
# A PROBE THAT REDEFINES probe_main NEVER RUNS ITS OWN NEGATIVE CONTROL.
#
# lib/probe.sh:338 defines probe_main() as THE DISPATCHER: it reads $1 and
# sends --self-test to self_test, --describe to the declared question, and
# anything else to run_probe. Every probe sources that library and ends with
# `probe_main "$@"`.
#
# WHAT HAPPENED. assistant_grounds_the_opening_turn.sh defined its measurement
# body as `probe_main()` -- AFTER sourcing the library, so the later definition
# won -- and then called `probe_main "$@"`. The flag was never read. Phase 1 of
# run_box_walk.sh ran the real measurement with the gate variables unset by
# design, the body's first guard called probe_cannot_run, and the process
# exited 78 = PROBE_EX_CANNOT_RUN. The runner (run_box_walk.sh:178) reported
#   BROKEN  assistant_grounds_the_opening_turn (self-test returned 78, expected 1)
# and then SKIPPED its phase 2 (run_box_walk.sh:445-451), so the probe has
# never produced a verdict on any walk. Recorded on walks/v1.0.100.tsv twice:
# once as broken_probe, once as not_measured_probe.
#
# NOTHING CAUGHT IT. The probe was collected, it parsed, it was listed in the
# manifest and it had a real body; the only thing wrong was a name. That is a
# whole-suite hazard with a one-line test, so it gets one.
#
# WHAT IS ASSERTED, over every collected probe:
#   1. it does NOT define probe_main()      (the dispatcher is the library's)
#   2. it DOES define run_probe()           (or --self-test cannot dispatch past it)
#   3. it DOES define self_test()           (or it has no negative control)
#   4. it ends with `probe_main "$@"`       (or nothing dispatches at all)
#
# AND A CONTROL, because a scan that cannot fail proves nothing: a synthetic
# copy that shadows the dispatcher must be reported, and a behavioural arm
# proves the flag is actually read rather than merely present in the text --
# --describe must exit 0 and print the question, which a shadowed dispatcher
# cannot do.
#
# NO PIPE INTO grep -q: it SIGPIPEs its producer and under pipefail reports
# failure for a pattern it found. Counted form only, and never `grep -c || echo`.
#
# BASH 3.2. macOS ships it and the box runs it. No associative arrays.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
PROBE_DIR="$REPO/scripts/box_walk_probes/probes"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1" >&2; }

[ -d "$PROBE_DIR" ] || { printf '  [CANNOT-RUN] no %s\n' "$PROBE_DIR" >&2; exit 2; }

printf 'test_no_probe_shadows_the_dispatcher\n'

# THE DENOMINATOR IS PRINTED AND FLOORED. An empty glob would otherwise walk
# zero probes and report a clean sweep, which is the zero-denominator shape
# this whole suite exists to refuse.
N=0
for f in "$PROBE_DIR"/*.sh; do [ -f "$f" ] && N=$((N+1)); done
printf '  examined: %s probe(s) in %s\n' "$N" "${PROBE_DIR#"$REPO"/}"
if [ "$N" -lt 10 ]; then
    bad "only ${N} probes found; under 10 means the glob missed the directory and NOTHING was checked"
    printf '\n== %s pass / %s fail ==\n' "$PASS" "$FAIL"
    exit 1
fi

# _violations <file> -> prints one reason per line, nothing when the file is clean.
# The one decision, so the control below drives exactly what the sweep does.
_violations() {
    _v_f="$1"
    if [ "$(grep -c '^probe_main() {' "$_v_f")" -gt 0 ]; then
        printf 'redefines probe_main(), which SHADOWS the dispatcher in lib/probe.sh -- --self-test and --describe would run the measurement body instead\n'
    fi
    if [ "$(grep -c '^run_probe() {' "$_v_f")" -eq 0 ]; then
        printf 'defines no run_probe(), so the dispatcher has nothing to dispatch a real run to\n'
    fi
    if [ "$(grep -c '^self_test() {' "$_v_f")" -eq 0 ]; then
        printf 'defines no self_test(), so it has no negative control and has not earned a PASS\n'
    fi
    if [ "$(grep -cF 'probe_main "$@"' "$_v_f")" -eq 0 ]; then
        printf 'never calls probe_main "$@", so nothing dispatches at all\n'
    fi
}

BAD=0
for f in "$PROBE_DIR"/*.sh; do
    [ -f "$f" ] || continue
    b="$(basename "$f")"
    _out="$(_violations "$f")"
    if [ -n "$_out" ]; then
        BAD=$((BAD+1))
        while IFS= read -r line; do
            [ -n "$line" ] && bad "${b}: ${line}"
        done <<EOF
$_out
EOF
    fi
done
[ "$BAD" -eq 0 ] && ok "all ${N} probes leave probe_main to the library and define run_probe + self_test"

# ── CONTROL 1: the scan must report a planted violation ─────────────────────
TMP="$(mktemp -d)" || { printf '  [CANNOT-RUN] no temp dir\n' >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT
printf '%s\n' \
    '#!/usr/bin/env bash' \
    '. ../lib/probe.sh' \
    'self_test() { probe_fail "x"; }' \
    'probe_main() { probe_pass "y"; }' \
    'probe_main "$@"' > "$TMP/shadowing_probe.sh"
if [ "$(_violations "$TMP/shadowing_probe.sh" | grep -c 'SHADOWS the dispatcher')" -gt 0 ]; then
    ok "CONTROL: a planted probe that redefines probe_main IS reported (and it also has no run_probe)"
else
    bad "CONTROL FAILED: a planted probe that redefines probe_main was reported CLEAN -- this scan discriminates nothing"
fi

# ── CONTROL 2: a clean synthetic file must NOT be reported ──────────────────
# Without this the scan could be failing everything, and control 1 would still
# read green.
printf '%s\n' \
    '#!/usr/bin/env bash' \
    '. ../lib/probe.sh' \
    'run_probe() { probe_examined 1 "thing"; probe_pass "ok"; }' \
    'self_test() { probe_examined 1 "arm"; probe_fail "control behaved"; }' \
    'probe_main "$@"' > "$TMP/clean_probe.sh"
if [ -z "$(_violations "$TMP/clean_probe.sh")" ]; then
    ok "CONTROL: a correctly shaped probe is NOT reported, so the scan is not failing everything"
else
    bad "CONTROL FAILED: a correctly shaped probe was reported as a violation"
fi

# ── BEHAVIOURAL ARM: the flag must actually be READ ─────────────────────────
# Text can be right while behaviour is wrong. --describe exits 0 and prints the
# probe's declared question ONLY when the library dispatcher is the one running.
# A shadowed dispatcher runs the measurement instead, which is exactly how this
# defect presented: --describe answered "VERDICT: CANNOT-RUN" and exited 78.
DESC_OK=0; DESC_N=0
for f in "$PROBE_DIR"/*.sh; do
    [ -f "$f" ] || continue
    DESC_N=$((DESC_N+1))
    _d="$(bash "$f" --describe 2>&1)"; _rc=$?
    if [ "$_rc" -eq 0 ] && [ "$(printf '%s' "$_d" | grep -c '^VERDICT: ')" -eq 0 ]; then
        DESC_OK=$((DESC_OK+1))
    else
        bad "$(basename "$f") --describe exited ${_rc} and said: $(printf '%s' "$_d" | head -1)"
    fi
done
[ "$DESC_OK" -eq "$DESC_N" ] && ok "all ${DESC_N} probes answer --describe with rc 0 and no verdict, so the dispatcher is reading the flag"

printf '\n== %s pass / %s fail / %s probes examined ==\n' "$PASS" "$FAIL" "$N"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
