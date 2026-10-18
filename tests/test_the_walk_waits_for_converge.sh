#!/usr/bin/env bash
# tests/test_the_walk_waits_for_converge.sh
# ============================================================================
# THE DEFECT, measured on the v1.0.78 walk. The install-time dedupe converge is
# SIGKILLed at a flat budget and the catch-up LaunchAgent that finishes the job
# does not tick for ten minutes, then runs for twenty to forty more. The walk
# measured inside that window: contacts read 1629 during the walk and 1920 an
# hour later on the same untouched box. people_count_agreement and
# people_stores_reconcile were not wrong about what they saw; they were asked
# too early, and a count disagreement measured mid-convergence is not a store
# defect.
#
# WHY THE GATE IS NOT THE .done MARKER, which was the first design and was
# wrong. The converge log writes, in the same second, "RULE 2 refused 34 of 34
# planned merge(s)", "hit max_rounds=10 without a fixpoint" and "converge
# completed cleanly; marking done". The marker means the PROCESS EXITED, never
# that the graph converged, so gating on it would have released both probes on
# exactly the evidence they already had: a declared state accepted in place of a
# measured one.
#
# WHAT IS UNDER TEST: lib/converge_wait.sh waits for two INDEPENDENT stores
# (oxigraph COUNT of pwg:Person, qdrant points_count of `people`) to stop
# changing across N readings, and if they never do, BOTH probes are CANNOT-RUN
# with the last readings and the killed marker quoted. Never FAIL, never PASS.
#
# THE ARM THAT MATTERS MOST is "stable but disagreeing". Whether the two stores
# AGREE is people_stores_reconcile's question. A gate that required agreement
# could only release that probe when its answer was already yes, so the probe
# could never fail and the walk would be scoring a fixture instead of a store.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
LIB="$REPO/scripts/box_walk_probes/lib/converge_wait.sh"
RUNNER="$REPO/scripts/box_walk_probes/run_box_walk.sh"

PASS=0
FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  [FAIL] %s\n' "$1"; shift; [ $# -gt 0 ] && printf '%s\n' "$*" | sed 's/^/         /'; FAIL=$((FAIL + 1)); }
ok_or() { if [ "$1" -eq 0 ]; then ok "$2"; else bad "$2" "${3:-}"; fi; }

[ -r "$LIB" ]    || { printf 'CANNOT-RUN: no lib at %s\n' "$LIB"; exit 78; }
[ -r "$RUNNER" ] || { printf 'CANNOT-RUN: no runner at %s\n' "$RUNNER"; exit 78; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

printf 'THE WALK WAITS FOR THE STORES TO STOP MOVING\n\n'

# Drive converge_wait with a scripted sequence of readings, one per line.
# _cw_read_pair is replaced, so nothing here touches a network or a box.
drive() { # $1 = file of readings, $2... = env assignments
    local seq="$1"; shift
    ( set +u
      env "$@" OSTLER_BOX_HOST= OSTLER_STABILITY_INTERVAL_S=0 \
          QA_SEQ="$seq" QA_N="$WORK/n" \
          bash -c '
            . "$1"
            printf "0" > "$QA_N"
            _cw_read_pair() {
                local i; i=$(cat "$QA_N"); i=$((i + 1)); printf "%s" "$i" > "$QA_N"
                sed -n "${i}p" "$QA_SEQ"
            }
            converge_wait >/dev/null 2>&1
            printf "STATE=%s\nDETAIL=%s\n" "$CONVERGE_STATE" "$CONVERGE_DETAIL"
          ' _ "$LIB" )
}

# ---------------------------------------------------------------------------
printf -- '-- 1. wired into the runner, gating exactly the two count-reading probes --\n'
# ---------------------------------------------------------------------------
# THESE TWO ARMS ONCE PINNED A POSITION AND NOW PIN THE PROPERTY. They read
# `^converge_wait ||` at the top level and required it to sit above the loop,
# which described the FIRST design: one wait in front of all of phase 2. That
# put a budget of up to 2700 s ahead of every probe on the walk, including the
# twenty-odd that never read a count (Aesop, review of #1849, criterion 5). The
# call is now made lazily inside the loop, so an arm that insists on the old
# POSITION would block the fix while claiming to protect the behaviour. What
# actually has to hold is unchanged: the lib is sourced, the wait is called,
# and the call happens before any gated probe is executed. Position is an
# implementation detail; ordering is the requirement.
src_line="$(grep -n 'lib/converge_wait.sh' "$RUNNER" | head -1 | cut -d: -f1)"
call_line="$(grep -n 'converge_wait ||' "$RUNNER" | head -1 | cut -d: -f1)"
gate_line="$(grep -n 'converge_gates_probe "\$b"' "$RUNNER" | head -1 | cut -d: -f1)"
loop_line="$(grep -n '^    out="$(bash "$p" 2>&1)"' "$RUNNER" | head -1 | cut -d: -f1)"

[ -n "$src_line" ] && [ -n "$call_line" ] && [ -n "$gate_line" ]
ok_or $? "the runner sources the lib, calls converge_wait, and gates in the loop" \
    "source=$src_line call=$call_line gate=$gate_line"
# The wait must be reached before a probe is EXECUTED. It now sits inside the
# gate block, so it is above the execution line and below the gate line, and
# the behavioural arms further down prove it actually fires (WAITS=1) rather
# than merely appearing in the right place.
[ -n "$call_line" ] && [ -n "$loop_line" ] && [ -n "$gate_line" ] \
    && [ "$call_line" -lt "$loop_line" ] && [ "$call_line" -gt "$gate_line" ]
ok_or $? "the wait is reached inside the gate and before any probe is executed" \
    "gate=$gate_line call=$call_line exec=$loop_line"
[ -n "$gate_line" ] && [ -n "$loop_line" ] && [ "$gate_line" -lt "$loop_line" ]
ok_or $? "the gate is checked before the probe is executed" "gate=$gate_line loop=$loop_line"

( set +u; . "$LIB"
  converge_gates_probe people_count_agreement && converge_gates_probe people_stores_reconcile \
    && ! converge_gates_probe assistant_answers_grounded && ! converge_gates_probe daemon_is_listening )
ok_or $? "it gates people_count_agreement and people_stores_reconcile, and nothing else"

# ---------------------------------------------------------------------------
printf -- '\n-- 2. it waits for MEASURED stability, not for a marker --\n'
# ---------------------------------------------------------------------------
# ASSERT THE BEHAVIOUR, NOT THE WORD, and this is the SECOND time this file has
# made that mistake: the budget arm below already had it, and this arm fired on
# the lib's own header explaining WHY .done is not a gate. Grepping for a bare
# name punishes the documentation that makes the design legible. What matters is
# that no LIVE line reads the marker, so that is what is checked.
done_ref() { grep -nE '^[^#]*dedupe-converge\.done' "$1"; }
if [ "$(done_ref "$LIB" | grep -c .)" -gt 0 ]; then
    bad "a LIVE line in the lib reads the .done marker" "$(done_ref "$LIB")"
else
    ok "no live line reads .done as a gate (the header may explain why, and does)"
fi
printf 'x=$HOME/.ostler/state/dedupe-converge.done\n' > "$WORK/donecanary.sh"
if [ "$(done_ref "$WORK/donecanary.sh" | grep -c .)" -gt 0 ]; then
    ok "CONTROL: the .done predicate does detect a real live reference"
else
    bad "CONTROL FAILED: the .done predicate is blind, so the arm above proves nothing"
fi
[ "$(grep -c 'points_count' "$LIB")" -gt 0 ] && grep -q 'COUNT(DISTINCT ?p)' "$LIB"
ok_or $? "it reads qdrant points_count AND an oxigraph SPARQL COUNT, two independent stores"

printf '1920 1920\n1920 1920\n1920 1920\n' > "$WORK/stable"
out="$(drive "$WORK/stable" OSTLER_STABILITY_READS=3 OSTLER_CONVERGE_WAIT_S=60)"
[ "$(printf '%s\n' "$out" | grep -c 'STATE=stable')" -gt 0 ]
ok_or $? "three identical readings reach STATE=stable" "$out"

printf '1900 1900\n1910 1910\n1920 1920\n1920 1920\n1920 1920\n' > "$WORK/late"
out2="$(drive "$WORK/late" OSTLER_STABILITY_READS=3 OSTLER_CONVERGE_WAIT_S=60)"
[ "$(printf '%s\n' "$out2" | grep -c 'STATE=stable')" -gt 0 ]
ok_or $? "a graph that settles late still reaches stable once it holds" "$out2"

# ---------------------------------------------------------------------------
printf -- '\n-- 3. STABILITY, NOT AGREEMENT: the probe must keep its question --\n'
# ---------------------------------------------------------------------------
# The two stores hold steady at DIFFERENT values. That is precisely the state
# people_stores_reconcile exists to FAIL on, so the gate must release it.
printf '1920 1629\n1920 1629\n1920 1629\n' > "$WORK/disagree"
out3="$(drive "$WORK/disagree" OSTLER_STABILITY_READS=3 OSTLER_CONVERGE_WAIT_S=60)"
[ "$(printf '%s\n' "$out3" | grep -c 'STATE=stable')" -gt 0 ]
ok_or $? "stores that hold steady while DISAGREEING are stable, so the reconcile probe still runs and can still fail" "$out3"

# ---------------------------------------------------------------------------
printf -- '\n-- 4. never settling is CANNOT-RUN, and names what it saw --\n'
# ---------------------------------------------------------------------------
printf '1900 1900\n1910 1910\n1920 1920\n1930 1930\n1940 1940\n' > "$WORK/moving"
out4="$(drive "$WORK/moving" OSTLER_STABILITY_READS=3 OSTLER_CONVERGE_WAIT_S=4)"
[ "$(printf '%s\n' "$out4" | grep -c 'STATE=unstable')" -gt 0 ]
ok_or $? "a graph that keeps moving ends STATE=unstable" "$out4"
[ "$(printf '%s\n' "$out4" | grep -ci 'still moving')" -gt 0 ]
ok_or $? "and the reason says the graph was still moving" "$out4"
[ "$(printf '%s\n' "$out4" | grep -ci 'not a store defect')" -gt 0 ]
ok_or $? "and says plainly that a mid-convergence count is not a store defect" "$out4"

# An unreadable store must never accumulate into stability, however many times
# it repeats: "x x" three times is not a settled graph, it is a blind one.
printf 'x x\nx x\nx x\nx x\n' > "$WORK/blind"
out5="$(drive "$WORK/blind" OSTLER_STABILITY_READS=3 OSTLER_CONVERGE_WAIT_S=4)"
[ "$(printf '%s\n' "$out5" | grep -c 'STATE=unreadable')" -gt 0 ]
ok_or $? "a store that cannot be read never counts as stable, however often it repeats" "$out5"

# ---------------------------------------------------------------------------
printf -- '\n-- 5. it never invents a budget, and never scores a pass --\n'
# ---------------------------------------------------------------------------
budget_assign() { grep -nE '^[^#]*OSTLER_DEDUPE_INSTALL_BUDGET_S=' "$1"; }
budget_assign "$LIB" >/dev/null && bad "the lib ASSIGNS a product budget" "$(budget_assign "$LIB")" \
    || ok "the lib never assigns OSTLER_DEDUPE_INSTALL_BUDGET_S"
budget_assign "$RUNNER" >/dev/null && bad "the runner ASSIGNS a product budget" \
    || ok "and neither does the runner"
printf 'OSTLER_DEDUPE_INSTALL_BUDGET_S=1\n' > "$WORK/canary.sh"
budget_assign "$WORK/canary.sh" >/dev/null
ok_or $? "CONTROL: the budget predicate does detect a real assignment"

gated="$(awk '/converge_gates_probe "\$b"/{f=1} f{print} f&&/^    fi$/{exit}' "$RUNNER")"
[ "$(printf '%s\n' "$gated" | grep -c 'CANNOT=\$((CANNOT + 1))')" -gt 0 ]
ok_or $? "the gated branch increments CANNOT" "$gated"
if [ "$(printf '%s\n' "$gated" | grep -cE 'PASS=\$\(\(PASS|FAIL=\$\(\(FAIL')" -gt 0 ]; then
    bad "the gated branch touches PASS or FAIL" "$gated"
else
    ok "and touches neither PASS nor FAIL"
fi

# ---------------------------------------------------------------------------
printf -- '\n-- 6. MUST-FAIL: a pair that never stabilises must not be called stable --\n'
# ---------------------------------------------------------------------------
# Mutate the streak test so any reading satisfies it. The moving fixture above
# must then be reported stable, which is the defect this whole file exists to
# prevent. If that did NOT happen, arm 4 would be proving nothing.
mutant="$WORK/mutant.sh"
sed 's/if \[ "\$same" -ge "\$need" \]; then/if [ 1 -eq 1 ]; then/' "$LIB" > "$mutant"
if grep -q 'if \[ 1 -eq 1 \]; then' "$mutant"; then
    ok "the mutation landed (the streak requirement forced true)"
    out_m="$( set +u
      env OSTLER_BOX_HOST= OSTLER_STABILITY_INTERVAL_S=0 OSTLER_STABILITY_READS=3 \
          OSTLER_CONVERGE_WAIT_S=4 QA_SEQ="$WORK/moving" QA_N="$WORK/nm" \
          bash -c '
            . "$1"
            printf "0" > "$QA_N"
            _cw_read_pair() { local i; i=$(cat "$QA_N"); i=$((i+1)); printf "%s" "$i" > "$QA_N"; sed -n "${i}p" "$QA_SEQ"; }
            converge_wait >/dev/null 2>&1
            printf "STATE=%s\n" "$CONVERGE_STATE"
          ' _ "$mutant" )"
    if [ "$(printf '%s\n' "$out_m" | grep -c 'STATE=stable')" -gt 0 ]; then
        ok "MUST-FAIL: the mutant calls a moving graph stable, so arm 4 is a real assertion"
    else
        bad "the mutant did NOT call the moving graph stable; arm 4 proves nothing" "$out_m"
    fi
else
    bad "the mutation did not land; the arm below would prove nothing"
fi

# ===========================================================================
# THE WIRING, NOT THE LIB. Everything above this line drives converge_wait()
# and every one of those arms passed while the two probes it exists to protect
# were being deleted from the walk.
#
# WHAT WAS WRONG, found by Aesop reviewing #1849 and reproduced here.
# run_box_walk.sh gated the probes on
#     converge_gates_probe "$b" && [ "$CONVERGE_STATE" != "done" ]
# and converge_wait sets exactly five values: unrun, skipped, stable,
# unreadable, unstable. "done" is not one of them -- it is the last remnant of
# the dedupe-converge.done design this lib deliberately abandoned. So the
# comparison was true for EVERY value the lib can produce, and both gated
# probes were CANNOT-RUN unconditionally, including after a wait that
# succeeded. Not delayed. Deleted.
#
# THE SUITE COULD NOT SEE IT BECAUSE IT WAS AIMED ONE FILE AWAY. A lib with a
# perfect 21-arm suite, wired through a line no arm executed. So these arms
# extract the gate region from the SHIPPED run_box_walk.sh and run it, with
# converge_wait stubbed to whatever state is under test.
# ===========================================================================
printf '\n--- THE WIRING IN run_box_walk.sh, NOT THE LIB ---\n'

WALK="$REPO/scripts/box_walk_probes/run_box_walk.sh"
if [ ! -r "$WALK" ]; then
    bad "CANNOT-RUN: no run_box_walk.sh at $WALK; the wiring arms measure nothing"
else

gate="$(awk '/^    if converge_gates_probe "\$b"; then$/ {f = 1} f {print} f && /^    fi$/ {exit}' "$WALK")"
g_lines="$(printf '%s\n' "$gate" | grep -c .)"
if [ "$g_lines" -lt 8 ] || [ "$g_lines" -gt 40 ]; then
    bad "extracted ${g_lines} lines for the gate region, implausible; refusing to eval" \
        "the anchor moved, so every wiring arm below would measure nothing"
else
ok "extracted the converge gate from the shipped run_box_walk.sh (${g_lines} lines)"

# -------------------------------------------------------------------------
# THE GENERAL FORM OF THE DEFECT, asserted directly: the literal this gate
# compares CONVERGE_STATE against must be a value converge_wait can actually
# ASSIGN. This arm fails on "done", on a typo, and on any future state the lib
# renames out from under the wiring. It is the one that would have caught it.
# -------------------------------------------------------------------------
want="$(printf '%s\n' "$gate" | sed -n 's/.*\[ "\$CONVERGE_STATE" != "\([a-z]*\)" \].*/\1/p' | head -1)"
if [ -z "$want" ]; then
    bad "could not read the state literal out of the gate; the arm below cannot run"
else
    settable="$(grep -o 'CONVERGE_STATE="[a-z]*"' "$LIB" | sed 's/.*="\(.*\)"/\1/' | sort -u)"
    if [ "$(printf '%s\n' "$settable" | grep -c "^${want}\$")" -gt 0 ]; then
        ok "the gate compares against \"${want}\", which converge_wait can actually set"
    else
        bad "the gate compares against \"${want}\", which converge_wait NEVER sets" \
            "assignable states: $(printf '%s' "$settable" | tr '\n' ' ')" \
            "so the comparison is true for every reachable value and both probes are deleted, not gated"
    fi
    # MUST-MISS control on that same predicate: "done" must be rejected by it.
    # Without this, a predicate that accepted anything would look identical.
    if [ "$(printf '%s\n' "$settable" | grep -c '^done$')" -eq 0 ]; then
        ok "control: \"done\" is NOT an assignable state, which is why the old gate was vacuous"
    else
        bad "\"done\" IS assignable now, so the arm above no longer discriminates"
    fi
fi

# -------------------------------------------------------------------------
# Drive the region. converge_wait is stubbed; converge_gates_probe is the real
# one, sourced from the lib, so the probe NAMES are the shipped ones.
# -------------------------------------------------------------------------
drive_gate() { # $1 = region  $2 = state the stubbed wait sets  $3 = probe list
    (
        set +u
        _WANT="$2"
        . "$LIB"
        converge_wait() { WAITS=$((WAITS + 1)); CONVERGE_STATE="$_WANT"; return 0; }
        CONVERGE_DETAIL="stubbed detail"
        CANNOT=0; CANNOT_LIST=""; WAITS=0; RAN=""
        _CONVERGE_WAIT_DONE=0
        CANNOT_REASONS="$WORK/reasons.$$"; : > "$CANNOT_REASONS"
        for b in $3; do
            eval "$1"
            RAN="$RAN $b"
        done
        printf 'RAN=[%s] WAITS=%s CANNOT=%s REASONS=%s\n' \
            "$RAN" "$WAITS" "$CANNOT" "$(grep -c . "$CANNOT_REASONS")"
        rm -f "$CANNOT_REASONS"
    ) 2>&1 | tail -1
}

# THE HARNESS ITSELF NEEDS A CONTROL. `continue` has to propagate out of the
# eval into the enclosing for loop or every "did not run" arm below would pass
# for the wrong reason -- a harness that can never run a probe would look
# exactly like a gate that always blocks one.
h_skip="$(drive_gate 'if true; then continue; fi' stable 'a b')"
h_run="$(drive_gate 'if false; then continue; fi' stable 'a b')"
[ "$(printf '%s\n' "$h_skip" | grep -c 'RAN=\[\]')" -gt 0 ] \
    && ok "harness control: continue inside the eval DOES skip the enclosing loop body" \
    || bad "harness control failed: continue did not propagate, so no arm below means anything" "$h_skip"
[ "$(printf '%s\n' "$h_run" | grep -c 'RAN=\[ a b\]')" -gt 0 ] \
    && ok "harness control: without a continue, both names reach the body" \
    || bad "harness control failed: the loop body never ran at all" "$h_run"

GATED="people_count_agreement people_stores_reconcile"

# ARM: a stable graph lets both gated probes THROUGH. This is the one the
# shipped bug broke, and it is the whole point of the change.
o_stable="$(drive_gate "$gate" stable "$GATED")"
if [ "$(printf '%s\n' "$o_stable" | grep -c 'RAN=\[ people_count_agreement people_stores_reconcile\]')" -gt 0 ]; then
    ok "STABLE: both gated probes are INVOKED, which is what #1849 exists to do"
else
    bad "STABLE: a gated probe did not run even though the graph settled" "$o_stable"
fi
[ "$(printf '%s\n' "$o_stable" | grep -c 'CANNOT=0')" -gt 0 ] \
    && ok "and neither is counted CANNOT-RUN" \
    || bad "a probe was counted CANNOT-RUN on a stable graph" "$o_stable"

# ARM: the wait is performed ONCE, not once per gated probe.
[ "$(printf '%s\n' "$o_stable" | grep -c 'WAITS=1')" -gt 0 ] \
    && ok "the wait runs exactly once, not once per gated probe" \
    || bad "the wait did not run exactly once" "$o_stable"

# ARM (criterion 5): a run that collects NO gated probe waits for NOTHING.
# Before this change converge_wait was called before all of phase 2, so every
# probe on the walk carried a budget of up to 2700 s it could not use.
o_none="$(drive_gate "$gate" stable "no_store_port_is_tcp_reachable assistant_answers_grounded")"
[ "$(printf '%s\n' "$o_none" | grep -c 'WAITS=0')" -gt 0 ] \
    && ok "no gated probe collected means no wait at all, so ungated probes are not charged for it" \
    || bad "the wait ran for a probe set containing no gated probe" "$o_none"
[ "$(printf '%s\n' "$o_none" | grep -c 'RAN=\[ no_store_port_is_tcp_reachable assistant_answers_grounded\]')" -gt 0 ] \
    && ok "and both ungated probes ran" \
    || bad "an ungated probe was blocked by the converge gate" "$o_none"

# ARM: an unstable graph still blocks, with the reason recorded. The gate must
# not have been loosened into a no-op by the fix.
o_unstable="$(drive_gate "$gate" unstable "$GATED")"
[ "$(printf '%s\n' "$o_unstable" | grep -c 'RAN=\[\]')" -gt 0 ] \
    && ok "UNSTABLE: both gated probes are held, so the fix did not turn the gate into a no-op" \
    || bad "a gated probe ran on a graph that never settled" "$o_unstable"
[ "$(printf '%s\n' "$o_unstable" | grep -c 'CANNOT=2 REASONS=2')" -gt 0 ] \
    && ok "and both are counted CANNOT-RUN with a reason written, never FAIL and never PASS" \
    || bad "the CANNOT-RUN count or the recorded reasons are wrong" "$o_unstable"

# -------------------------------------------------------------------------
# MUST-FAIL: put "done" back. This is the shipped defect, restored on purpose.
# If the stable arm above still passed against it, that arm would be proving
# nothing about the comparison.
# -------------------------------------------------------------------------
if [ "$(printf '%s\n' "$gate" | grep -c '"\$CONVERGE_STATE" != "stable"')" -eq 0 ]; then
    bad "the line the mutation targets is not in the gate; the must-fail arm cannot mean anything"
else
    mut_gate="$(printf '%s\n' "$gate" | sed 's/"\$CONVERGE_STATE" != "stable"/"$CONVERGE_STATE" != "done"/')"
    if [ "$(printf '%s\n' "$mut_gate" | grep -c '"\$CONVERGE_STATE" != "done"')" -eq 0 ]; then
        bad "the mutation did not land; the must-fail arm below would prove nothing"
    else
        ok "the mutation landed (the gate compares against \"done\" again)"
        o_mut="$(drive_gate "$mut_gate" stable "$GATED")"
        if [ "$(printf '%s\n' "$o_mut" | grep -c 'RAN=\[\]')" -gt 0 ]; then
            ok "MUST-FAIL: with \"done\" restored both probes vanish on a STABLE graph, which is the shipped defect"
        else
            bad "MUST-FAIL: the \"done\" gate still let the probes through; the stable arm proves nothing" "$o_mut"
        fi
    fi
fi

fi
fi

printf '\n== %s pass / %s fail / %s total ==\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
