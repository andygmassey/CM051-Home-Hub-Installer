#!/usr/bin/env bash
# A probe's self-test denominator must be COUNTED, never TYPED (#2120, #2138).
#
# WHY. run_box_walk.sh phase 1 runs every probe with --self-test, and the line
# it prints reaches walks/v1.0.NN.tsv, which is what a person reads to decide
# whether a build is shippable. "negative control behaved correctly on all N
# cases" is a denominator. A typed N is checked by nothing, so being wrong
# costs nothing until somebody relies on it.
#
# MEASURED on origin/main before this test existed: people_stores_reconcile
# declared 32 while FORTY ONE distinct assertions fired, every label unique.
# Wrong by nine, on one of the five BLOCKING probes, and 0 files in tests/ or
# scripts/ named the number.
#
# TWO NON-FIXES, both refused and both named in #2120: typing 41 instead, and
# asserting that the literal equals 41. The second pins a claim to another
# claim and they drift together.
#
# WHAT THIS ASSERTS. For each subject, the declared count and a SECOND,
# independent reading of the same run must agree:
#
#   people_stores_reconcile   declared == outcome lines the run printed
#                             declared == the number in the verdict sentence
#   no_store_port_...         declared == the number in the verdict sentence
#
# The second reading is what catches #2138: an arm added without its tick is
# invisible to the counter and visible to the line count.
#
# Exit 0 all arms pass, 1 any arm fails, 2 a subject could not be run.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBES="${ROOT}/scripts/box_walk_probes/probes"
PASS=0
FAIL=0

ok()  { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '        | %s\n' "$2"; return 0; }
cannot_run() { printf 'CANNOT-RUN: %s\n' "$1" >&2; exit 2; }

# Read the declared denominator out of a run's EXAMINED line.
declared_of() { printf '%s\n' "$1" | sed -n 's/^EXAMINED: \([0-9][0-9]*\) .*/\1/p' | head -1; }
# Read the denominator the verdict sentence quotes.
verdict_of()  {
    # Two verdict shapes are in use, so BOTH are tried and the first hit wins.
    # A reader that silently matches neither returns empty, which every caller
    # treats as a disagreement rather than as agreement.
    local out
    out="$(printf '%s\n' "$1" | sed -n 's/.*behaved correctly on all \([0-9][0-9]*\) cases.*/\1/p' | head -1)"
    [ -n "$out" ] || out="$(printf '%s\n' "$1" | sed -n 's/.*[^0-9]\([0-9][0-9]*\) of [0-9][0-9]* adjudication cases behaved.*/\1/p' | head -1)"
    printf '%s' "$out"
}
# Count the outcome lines the run actually printed. A different instrument.
arms_of()     { printf '%s\n' "$1" | grep -cE '^  (ok|SELF-TEST FAIL) \[' || true; }

run_self_test() {
    local probe="$1"
    [ -x "${PROBES}/${probe}.sh" ] || [ -f "${PROBES}/${probe}.sh" ] || return 1
    bash "${PROBES}/${probe}.sh" --self-test 2>&1
    return 0
}

echo "SUBJECTS: two probes whose denominator is counted at runtime"
echo

echo "ARM 0: THE READERS WORK. A control string every reader must parse."
CONTROL_OUT=$'EXAMINED: 7 synthetic things\n  ok [a]\n  ok [b]\nnegative control behaved correctly on all 7 cases: words'
CONTROL_OUT2=$'EXAMINED: 5 adjudication cases\nVERDICT: FAIL -- words, 5 of 5 adjudication cases behaved, a number counted AT RUNTIME.'
c_d="$(declared_of "$CONTROL_OUT")"; c_v="$(verdict_of "$CONTROL_OUT")"; c_a="$(arms_of "$CONTROL_OUT")"
c_v2="$(verdict_of "$CONTROL_OUT2")"; c_d2="$(declared_of "$CONTROL_OUT2")"
if [ "$c_d" = "7" ] && [ "$c_v" = "7" ] && [ "$c_a" = "2" ] && [ "$c_d2" = "5" ] && [ "$c_v2" = "5" ]; then
    ok "(0) both verdict shapes and all three readers are alive (7/7/2 and 5/5)"
else
    bad "(0) a reader returned nothing on a control it must parse" \
        "shape1 declared='$c_d' verdict='$c_v' arms='$c_a'; shape2 declared='$c_d2' verdict='$c_v2'"
fi

echo
echo "ARM 1: people_stores_reconcile. Three readings of one run must agree."
OUT="$(run_self_test people_stores_reconcile)" || cannot_run "people_stores_reconcile could not be run"
[ -n "$OUT" ] || cannot_run "people_stores_reconcile produced no output at all"
d="$(declared_of "$OUT")"; v="$(verdict_of "$OUT")"; a="$(arms_of "$OUT")"
if [ -z "$d" ]; then
    bad "(1a) no EXAMINED line, so nothing was measured" "$(printf '%s' "$OUT" | head -2)"
elif [ "$d" -lt 2 ]; then
    bad "(1a) declared $d, which is not a denominator" "a zero or one is a broken self-test, not a count"
else
    ok "(1a) declares $d cases"
fi
if [ -n "$d" ] && [ "$d" = "$a" ]; then
    ok "(1b) the counter and the outcome lines agree: $d = $a"
else
    bad "(1b) the counter says $d and the run printed $a outcome lines" \
        "an arm exists that one instrument cannot see (#2138)"
fi
if [ -n "$d" ] && [ "$d" = "$v" ]; then
    ok "(1c) the verdict sentence quotes the same number: $v"
else
    bad "(1c) EXAMINED says $d and the verdict says $v" \
        "two numbers in one record that can disagree is how the typed 32 survived"
fi

echo
echo "ARM 2: no_store_port_is_tcp_reachable. Its verdict must quote its count."
OUT2="$(run_self_test no_store_port_is_tcp_reachable)" || cannot_run "no_store_port could not be run"
[ -n "$OUT2" ] || cannot_run "no_store_port produced no output at all"
d2="$(declared_of "$OUT2")"; v2="$(verdict_of "$OUT2")"
if [ -n "$d2" ] && [ "$d2" -ge 2 ] && [ "$d2" = "$v2" ]; then
    ok "(2) declares $d2 and its verdict quotes $v2"
else
    bad "(2) declared '$d2', verdict quoted '$v2'" "one runtime count must feed both"
fi

echo
echo "ARM 3: neither subject may re-acquire a TYPED denominator."
for f in people_stores_reconcile no_store_port_is_tcp_reachable; do
    n="$(/usr/bin/grep -c 'probe_examined [0-9][0-9]* "synthetic\|probe_examined [0-9][0-9]* "adjudication' "${PROBES}/${f}.sh" || true)"
    # A literal 0 is allowed: it is the NONE-RAN branch, which must print a zero.
    n_nonzero="$(/usr/bin/grep -c 'probe_examined [1-9][0-9]* "synthetic\|probe_examined [1-9][0-9]* "adjudication' "${PROBES}/${f}.sh" || true)"
    if [ "$n_nonzero" = "0" ]; then
        ok "(3) ${f} types no non-zero denominator (${n} literal site(s), all the NONE-RAN zero)"
    else
        bad "(3) ${f} types a denominator again at ${n_nonzero} site(s)" \
            "$(/usr/bin/grep -n 'probe_examined [1-9]' "${PROBES}/${f}.sh" | head -3)"
    fi
done

echo
echo "ARM 4: MUST-MISS. The comparison must reject what it should reject."
BAD1=$'EXAMINED: 32 synthetic things\n  ok [a]\n  ok [b]\nbehaved correctly on all 32 cases'
if [ "$(declared_of "$BAD1")" != "$(arms_of "$BAD1")" ]; then
    ok "(4a) a declared 32 against 2 printed arms IS caught"
else
    bad "(4a) a declared 32 against 2 printed arms was not caught"
fi
BAD2=$'EXAMINED: 41 synthetic things\n  ok [a]\nbehaved correctly on all 32 cases'
if [ "$(declared_of "$BAD2")" != "$(verdict_of "$BAD2")" ]; then
    ok "(4b) an EXAMINED and a verdict that disagree ARE caught"
else
    bad "(4b) an EXAMINED of 41 beside a verdict of 32 was not caught"
fi
NONUM=$'no examined line here at all\n  ok [a]'
if [ -z "$(declared_of "$NONUM")" ]; then
    ok "(4c) output with no EXAMINED line yields an EMPTY reading, not a silent zero"
else
    bad "(4c) output with no EXAMINED line produced a number from nowhere"
fi

echo
echo "=== ${PASS} passed / ${FAIL} failed ==="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
