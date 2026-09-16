#!/usr/bin/env bash
# scripts/tests/test_a_probes_self_test_must_drive_its_own_decision.sh
# ============================================================================
# A NEGATIVE CONTROL THAT TESTS A COPY OF THE REAL LOGIC IS NOT A CONTROL.
#
# daemon_is_listening.sh and the_recovery_key_reached_the_customer.sh each
# used to define their own local decision function inside self_test (`classify`
# and `_decide`) and drive fixtures through THAT. run_probe's real adjudication
# was a separately written chain of conditionals reaching probe_pass /
# probe_fail / probe_cannot_run directly, and it never called either function.
# So a regression that flipped the real chain -- turning a FAIL into a PASS --
# left the self-test output byte identical, because the negative control never
# executed the mutated code.
#
# These are the two worst incidents in this suite's history: v1.0.31 shipped
# with every prerequisite green and the product never started for any
# customer (the deserialise-config shape daemon_is_listening.sh exists to
# catch), and the v1.0.68 walk left a customer permanently locked out of their
# own encrypted data because a recovery key was minted and never disclosed.
# The controls written to prevent recurrence could not detect a regression in
# themselves.
#
# THE FIX. Both probes now define the decision as ONE function
# (_daemon_classify, _decide) declared once, above run_probe. run_probe calls
# it to adjudicate a live box; self_test calls the SAME function with
# synthetic readings. A mutation to the function breaks both in the same edit.
#
# THIS TEST proves that coupling by MUTATING THE REAL DECISION LOGIC in a
# throwaway copy of each probe -- the exact regression named above, turning a
# named FAIL into a PASS -- and requiring the probe's own --self-test to go
# BROKEN. It does not re-implement either probe's predicate; it drives the
# real file, unmodified except for the one mutated line, exactly as
# run_box_walk.sh's phase 1 would.
#
# THE ANCHOR MUST MATCH EXACTLY ONCE. If a refactor moves or renames the
# mutated line, this test must not silently mutate nothing (or something
# else); it CANNOT-RUNs instead, per the rule that a search which comes back
# empty is not a pass.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${HERE}/.." && pwd)"
PROBE_DIR="${SCRIPTS_DIR}/box_walk_probes/probes"
LIB="${SCRIPTS_DIR}/box_walk_probes/lib/probe.sh"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1" >&2; }
cant() { printf 'CANNOT-RUN: %s\n' "$1" >&2; exit 2; }

[ -r "$LIB" ] || cant "cannot read ${LIB}"

WORK="$(mktemp -d)" || cant "no working directory"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "${WORK}/probes" "${WORK}/lib" || cant "could not stage working dirs"
cp "$LIB" "${WORK}/lib/probe.sh" || cant "could not stage ${LIB}"

# is_ok_per_runner -- THE EXACT PREDICATE run_box_walk.sh's phase 1 applies
# (run_box_walk.sh:168-179): rc==1 and no 'VERDICT: BROKEN' line means the
# runner counts the self-test as "ok, goes red on known-bad input". Anything
# else the runner marks BROKEN and discards the probe's real result. Using
# the runner's own predicate here, not a re-derived one, is what makes this
# guard's verdict mean what the runner would actually do.
is_ok_per_runner() {
    local rc="$1" out="$2"
    [ "$rc" -eq 1 ] || return 1
    printf '%s\n' "$out" | grep -q 'VERDICT: BROKEN' && return 1
    return 0
}

# check_probe <basename> <anchor-literal> <mutated-literal>
#
# Copies the REAL, CURRENT probe file, confirms its self-test is healthy
# unmutated, mutates exactly the one line naming <anchor-literal> to
# <mutated-literal> -- a literal bash substring replace, no regex escaping
# to get wrong -- and requires the mutated self-test to be BROKEN per the
# runner's own predicate.
check_probe() {
    local base="$1" anchor="$2" mutant="$3"
    local src="${PROBE_DIR}/${base}"
    local copy="${WORK}/probes/${base}"

    [ -r "$src" ] || { bad "${base}: cannot read ${src}"; return; }
    cp "$src" "$copy" || { bad "${base}: could not stage a copy"; return; }

    local out rc
    out="$(bash "$copy" --self-test 2>&1)"; rc=$?
    if is_ok_per_runner "$rc" "$out"; then
        ok "${base}: unmutated self-test is ok (rc=${rc}, no BROKEN) -- baseline sane"
    else
        bad "${base}: unmutated self-test is NOT ok (rc=${rc}). The probe is broken before any mutation; the arm below would prove nothing."
        printf '%s\n' "$out" | sed 's/^/           | /' >&2
        return
    fi

    local n
    n="$(grep -cF "$anchor" "$copy")"
    if [ "${n:-0}" -ne 1 ]; then
        bad "${base}: anchor '${anchor}' appears ${n:-0} time(s), expected exactly 1 -- refusing to mutate on an ambiguous or absent target (a refactor likely moved the decision line; update this test's anchor)"
        return
    fi

    # Literal bash substring replace -- no sed delimiter escaping, no regex
    # metacharacters to misinterpret. Both anchors used by this file contain
    # none of bash's glob-special characters (*, ?, [, ]), which is what makes
    # ${content//anchor/mutant} safe as a LITERAL replace here.
    local content mutated
    content="$(cat "$copy")"
    mutated="${content//${anchor}/${mutant}}"
    printf '%s\n' "$mutated" > "$copy" || cant "could not write the mutated copy of ${base}"

    /bin/bash -n "$copy" || { bad "${base}: the mutated copy does not even parse -- the anchor replacement broke the file's syntax"; return; }

    out="$(bash "$copy" --self-test 2>&1)"; rc=$?
    if is_ok_per_runner "$rc" "$out"; then
        bad "${base}: MUTATED the real decision logic ('${anchor}' -> '${mutant}') and the self-test is STILL ok (rc=${rc}). The negative control never touched the mutated code -- it is testing a copy, not the real path."
        printf '%s\n' "$out" | sed 's/^/           | /' >&2
    else
        ok "${base}: mutating the real decision logic broke the self-test (rc=${rc}, runner would mark BROKEN) -- the negative control drives the same code the probe actually runs"
    fi
}

echo "== daemon_is_listening.sh: mutating the real v1.0.31 FAIL arm to PASS =="
# _daemon_classify's case arm for the exact v1.0.31 shape (a daemon that
# cannot deserialise the config the installer wrote it). This is the named
# incident: every prerequisite green, the product never started for any
# customer. Turning its FAIL into a PASS recreates it exactly.
check_probe "daemon_is_listening.sh" \
    'echo FAIL-V1031 ;;' \
    'echo PASS ;;'

echo "== the_recovery_key_reached_the_customer.sh: mutating the minted-and-missed FAIL to PASS =="
# _decide's terminal fallback, reached only when a key was minted by THIS run
# and no disclosure marker was found. This is the named incident: a customer
# permanently locked out of their own encrypted data. Turning its FAIL into a
# PASS recreates it exactly.
check_probe "the_recovery_key_reached_the_customer.sh" \
    "printf 'fail-minted-not-disclosed'" \
    "printf 'pass-disclosed'"

echo ""
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "${FAIL}" -eq 0 ]
