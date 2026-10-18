#!/usr/bin/env bash
#
# test_egress_declared_host_resolution.sh -- #1143.
#
# no_unexpected_egress is graded BLOCKING (walk_promote_scope.tsv) and the cut
# manifest requires it to PASS. Two defects in its declared-host resolver both
# pointed the same way: towards accusing the product of egress it never made.
#
#   1. ONE LOOKUP, de-duplicated only within that single response. A rotating
#      DNS pool answers differently next time, so a host WE DECLARED can fail
#      to match and be reported as unexpected egress.
#
#   2. A SWALLOWED FAILURE. A bare except-Exception-pass meant a host that
#      FAILED TO RESOLVE contributed nothing and vanished from the declared
#      set, indistinguishable from one that resolved to nothing.
#
# WHY THIS FILE EXISTS AT ALL. The probe already had two good controls: one
# plants a real loopback socket and fails if the sampler misses it, the other
# asserts an established connection is classified inside the boundary. Both
# prove the SAMPLER and the CLASSIFIER. NEITHER touches the declared-attribution
# arm, which is why both defects lived in a well-controlled probe. A suite can
# have excellent controls and none pointed at the limb that is wrong.
#
# Every arm here drives the REAL code through the probe's own seams, never a
# restatement of it, and the two MUTATION arms prove the assertions can fail.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="$HERE/../box_walk_probes/probes/no_unexpected_egress.sh"
[ -r "$PROBE" ] || { echo "FAIL: no probe at $PROBE"; exit 99; }

PASS=0; FAIL=0
TMP="$(mktemp -d -t egressres_XXXXXX)"
# A MUTANT MUST LIVE WHERE THE REAL PROBE LIVES. The probe sources
# ../lib/probe.sh by a path relative to itself, so a copy in /tmp dies before
# it reaches the code under test -- and a mutant that DIED looks exactly like
# a mutant that was CAUGHT. The first version of this file made that mistake
# and scored a pass for it. A leading dot keeps these out of the *.sh glob
# that run_box_walk.sh calls the whole suite.
MUTDIR="$(cd "$(dirname "$PROBE")" && pwd)"
MUT_A="$MUTDIR/.mutant_a_$$.sh"
MUT_B="$MUTDIR/.mutant_b_$$.sh"
trap 'rm -rf "$TMP" "$MUT_A" "$MUT_B"' EXIT
ok() { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
no() { printf '  FAIL  %s\n' "$1"; printf '%s\n' "${2:-}" | sed 's/^/        | /'; FAIL=$((FAIL+1)); }

# A name reserved by RFC 2606 precisely so it can never resolve. Not a typo,
# and not a domain anyone can register out from under this test.
UNRESOLVABLE="definitely-not-a-real-host.invalid"

echo "test_egress_declared_host_resolution"
echo

# ---------------------------------------------------------------------------
# 1. POSITIVE CONTROL. localhost resolves with no DNS server at all, so this
#    arm works on an offline runner and proves the reader is alive. Without
#    it, every "no HOSTFAIL" assertion below could pass on a resolver that
#    silently produced nothing.
# ---------------------------------------------------------------------------
out="$(bash "$PROBE" --resolve-declared localhost 2>"$TMP/err")"
h="$(grep -c "^HOST	localhost	" <<< "$out" || true)"
f="$(grep -c "^HOSTFAIL" <<< "$out" || true)"
if [ "$h" -lt 1 ]; then no "localhost produced no HOST row" "$out$(cat "$TMP/err")"
elif [ "$f" -ne 0 ]; then no "localhost produced a HOSTFAIL row" "$out"
else ok "positive control: localhost resolves and is reported (HOST rows: $h)"; fi

# ---------------------------------------------------------------------------
# 2. THE DEFECT. A host that cannot resolve must be NAMED, not swallowed.
#    Before the fix this produced complete silence, and silence here is what
#    turned a declared host into an undeclared one.
# ---------------------------------------------------------------------------
out="$(bash "$PROBE" --resolve-declared "$UNRESOLVABLE" 2>"$TMP/err")"
if ! grep -q "^HOSTFAIL	${UNRESOLVABLE}	" <<< "$out"; then
    no "an unresolvable declared host was not reported as HOSTFAIL" "$out$(cat "$TMP/err")"
else ok "an unresolvable declared host is named in a HOSTFAIL row"; fi

# ---------------------------------------------------------------------------
# 3. ONE FAILURE MUST NOT TAKE OUT THE REST. A mixed list has to keep the
#    good answer AND name the bad one. Losing the good one would trip the
#    probe's existing all-empty guard and mask this defect behind that.
# ---------------------------------------------------------------------------
out="$(bash "$PROBE" --resolve-declared localhost "$UNRESOLVABLE" 2>"$TMP/err")"
g="$(grep -c "^HOST	localhost	" <<< "$out" || true)"
b="$(grep -c "^HOSTFAIL	${UNRESOLVABLE}	" <<< "$out" || true)"
if [ "$g" -lt 1 ] || [ "$b" -ne 1 ]; then
    no "mixed list: expected localhost resolved and the invalid host named (got HOST=$g HOSTFAIL=$b)" "$out"
else ok "a failed lookup is isolated: the resolvable host still resolves"; fi

# ---------------------------------------------------------------------------
# 4. BOUNDED. A probe that becomes a timeout reports nothing, which is the
#    same outcome as the bug by a slower route. With the deadline already
#    spent the resolver must return at once AND still report the host rather
#    than going quiet.
# ---------------------------------------------------------------------------
start="$(date +%s)"
out="$(OSTLER_EGRESS_RESOLVE_DEADLINE_S=0 bash "$PROBE" --resolve-declared "$UNRESOLVABLE" 2>"$TMP/err")"
elapsed=$(( $(date +%s) - start ))
if ! grep -q "^HOSTFAIL	${UNRESOLVABLE}	" <<< "$out"; then
    no "a spent deadline produced silence instead of a HOSTFAIL row" "$out"
elif [ "$elapsed" -gt 5 ]; then
    no "a spent deadline still took ${elapsed}s; the bound is not doing anything"
else ok "the deadline bounds the work (${elapsed}s) and still reports the host"; fi

# ---------------------------------------------------------------------------
# 5. THE ROUTING DECISION, all four combinations, through the real function.
#    The third case is the one that keeps this fix honest: an unresolved host
#    with NOTHING undeclared changed no verdict, so it must NOT convert a
#    clean run into CANNOT-RUN. A fix that made every slow-DNS box unreadable
#    would trade one false verdict for another.
# ---------------------------------------------------------------------------
check_kind() {
    local u="$1" r="$2" want="$3" got
    got="$(bash "$PROBE" --verdict-kind "$u" "$r" 2>&1)"
    if [ "$got" != "$want" ]; then
        no "verdict-kind undeclared=$u unresolved=$r wanted $want, got $got"
    else ok "verdict-kind undeclared=$u unresolved=$r -> $want"; fi
}
check_kind 1 1 cannot_run_unresolved
check_kind 1 0 fail_undeclared
check_kind 0 1 no_undeclared
check_kind 0 0 no_undeclared

# ---------------------------------------------------------------------------
# 6. MUTATION A -- the reporting arm. Strip the HOSTFAIL emission and arm 2
#    MUST go red. Without this, arm 2 could be passing for some reason other
#    than the code being right.
# ---------------------------------------------------------------------------
sed 's/^        print("HOSTFAIL.*$/        pass/' "$PROBE" > "$MUT_A"
if ! grep -q '^        pass$' "$MUT_A"; then
    no "MUTATION A did not apply; a mutant that did not apply looks exactly like one that was not caught"
else
    out="$(bash "$MUT_A" --resolve-declared localhost "$UNRESOLVABLE" 2>&1)"
    # THE MUTANT MUST STILL RUN. Without this the arm scores a pass whenever
    # the mutant merely fails to start, which is the trap this file already
    # fell into once.
    if ! grep -q "^HOST	localhost	" <<< "$out"; then
        no "MUTATION A did not execute (no HOST row at all), so it proves nothing" "$out"
    elif grep -q "^HOSTFAIL" <<< "$out"; then
        no "MUTATION A applied and ran, but a HOSTFAIL row still appeared" "$out"
    else ok "MUTATION A: mutant ran, HOSTFAIL emission removed, arm 2 goes red as it must"; fi
fi

# ---------------------------------------------------------------------------
# 7. MUTATION B -- the routing arm. Drop the unresolved condition, restoring
#    the pre-fix behaviour, and the 1/1 case MUST fall back to fail_undeclared.
#    That is the false accusation this whole change exists to stop, reproduced
#    on demand.
# ---------------------------------------------------------------------------
sed 's/^    if \[ "\$undeclared" -gt 0 \] \&\& \[ "\$unresolved" -gt 0 \]; then$/    if [ "$undeclared" -gt 0 ] \&\& [ 0 -gt 0 ]; then/' "$PROBE" > "$MUT_B"
if ! grep -q '\[ 0 -gt 0 \]' "$MUT_B"; then
    no "MUTATION B did not apply; not scored as a survivor"
else
    # Control first: the mutant must answer the UNCHANGED case correctly,
    # which proves it ran and that only the guarded branch moved.
    ctl="$(bash "$MUT_B" --verdict-kind 0 0 2>&1)"
    got="$(bash "$MUT_B" --verdict-kind 1 1 2>&1)"
    if [ "$ctl" != "no_undeclared" ]; then
        no "MUTATION B did not execute cleanly (0/0 gave $ctl), so it proves nothing"
    elif [ "$got" != "fail_undeclared" ]; then
        no "MUTATION B applied but 1/1 did not revert to fail_undeclared (got $got)"
    else ok "MUTATION B: with the unresolved guard removed, 1/1 reverts to the false FAIL"; fi
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
