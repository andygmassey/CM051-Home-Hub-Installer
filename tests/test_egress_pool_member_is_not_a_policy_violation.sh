#!/usr/bin/env bash
#
# test_egress_pool_member_is_not_a_policy_violation.sh -- #1143.
#
# PROVED-RED-BY: this file, mutation 1 (the pool arm removed).
#
# THE DEFECT, MEASURED ON A LIVE BOX 2026-08-27. no_unexpected_egress returned
#
#     VERDICT: FAIL -- 3 attributable connection(s) to destinations outside the
#       declared boundary.
#         tailscale -> 192.200.0.111:443
#         tailscale -> 199.165.136.100:443
#         tailscale -> 205.147.105.30:443
#
# and 192.200.0.111 resolves to controlplane.tailscale.com and
# login.tailscale.com, ledger rows 30 and 54. It is DECLARED. The probe missed
# it because the host is a rotating pool: consecutive lookups in that session
# returned .101 .102 .103 .104, then .111, then .114, so the slice taken in the
# same call as the socket read did not contain the member the socket was held
# to. Sampling both halves together is necessary and not sufficient.
#
# A ROTATING POOL MEANS THE COMPARISON COULD NOT BE MADE. That is CANNOT-RUN.
# It is not a host being undeclared and must never print as one: a walk that
# FAILs on declared infrastructure trains its reader to discount every FAIL the
# probe makes, including the one address in that same run that deserved it.
#
# WHAT THIS ASSERTS, in both directions, because an arm that cleared everything
# would also clear the real finding:
#   * a pool member of a declared host  -> pool       (CANNOT-RUN)
#   * an address in no declared pool    -> undeclared (still FAILs)
# The second is the negative control.
#
# 🔴 THE NEGATIVE CONTROL MOVED ON 2026-09-18, AND THE REASON MATTERS MORE THAN
# THE ADDRESS. It used to be 199.165.136.100, the real unattributed address from
# the same measurement. That address has since been EXPLAINED -- Ostler's own
# tailscaled holding a control connection on an address Tailscale's dial plan
# handed out, which DNS deliberately does not publish -- and 199.165.136.0/24 is
# now a declared CIDR row in the ledger. So it is no longer undeclared and
# cannot serve as the control.
#
# It is replaced by 203.0.113.45, from TEST-NET-3 (RFC 5737), which is reserved
# for documentation and can never be a real destination. That is a BETTER
# control than the address it replaces: it cannot be explained later, so this
# assertion cannot quietly stop testing anything the way the last one did.
#
# The pool assertion's subject moved for the same reason. 192.200.0.111 is now
# inside a declared network, so it classifies `network` and no longer exercises
# the pool arm at all. The pool arm is now driven by 20.205.243.170, a member of
# api.github.com's pool, which is in no declared CIDR.
#
# British English throughout; " -- " not em-dashes.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE="$HERE/scripts/box_walk_probes/probes/no_unexpected_egress.sh"
[ -r "$PROBE" ] || { echo "CANNOT-RUN: no probe at $PROBE" >&2; exit 2; }

TMP="$(mktemp -d -t egresspool_XXXXXX)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { printf '  ok    %s\n' "$1"; PASS=$((PASS + 1)); }
no() { printf '  FAIL  %s\n' "$1"; printf '%s\n' "${2:-}" | sed 's/^/        | /'; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# THE RECORDED MAP. Shaped exactly as load_declared_map emits it. The declared
# host resolved to two pool members in this run; the socket below is held to a
# third that the run did not see, which is the whole of #1143.
# ---------------------------------------------------------------------------
cat > "$TMP/map.tsv" <<'EOF'
HOST	controlplane.tailscale.com	192.200.0.104
HOST	controlplane.tailscale.com	192.200.0.102
HOST	login.tailscale.com	192.200.0.102
HOST	api.github.com	20.205.243.166
DERP	derp20c.tailscale.com	205.147.105.30
EOF

# A map with the SAME hosts and NO relay map, to drive the DERP-unavailable arm.
grep -v '^DERP	' "$TMP/map.tsv" > "$TMP/map-noderp.tsv"

# A map whose apparatus is broken.
{ echo "STATUS	the box resolved NONE of the declared hosts"; cat "$TMP/map.tsv"; } > "$TMP/map-broken.tsv"

cat > "$TMP/addrs.txt" <<'EOF'
192.200.0.104
192.200.0.111
20.205.243.170
205.147.105.30
199.165.136.100
203.0.113.45
EOF

# Reads a bucket for one address out of a --classify-declared run.
bucket_of() {   # bucket_of <output-file> <ip>
    awk -F'\t' -v ip="$2" '$2 == ip {print $1; exit}' "$1"
}

classify() {    # classify <probe> <map> <addrs> <outfile> -- prints rc
    bash "$1" --classify-declared "$2" "$3" > "$4" 2>"${4}.err"
    echo $?
}

echo "test_egress_pool_member_is_not_a_policy_violation"
echo

# ---------------------------------------------------------------------------
# 0. CONTROL, BEFORE ANY VERDICT. The mode must run and must classify every
#    address handed to it. Without this, every bucket read below could be the
#    empty string and each assertion would be comparing nothing to nothing.
# ---------------------------------------------------------------------------
rc="$(classify "$PROBE" "$TMP/map.tsv" "$TMP/addrs.txt" "$TMP/out")"
n_in="$(grep -c . "$TMP/addrs.txt")"
n_out="$(grep -c . "$TMP/out" || true)"
if [ "$rc" != 0 ]; then
    no "(0) CONTROL FAILED: --classify-declared exited ${rc}; nothing below would be meaningful" "$(cat "$TMP/out" "$TMP/out.err" 2>/dev/null)"
    echo; echo "=== ${PASS} passed / ${FAIL} failed ==="; exit 1
elif [ "$n_out" != "$n_in" ]; then
    no "(0) CONTROL FAILED: ${n_in} addresses in, ${n_out} classified out" "$(cat "$TMP/out")"
    echo; echo "=== ${PASS} passed / ${FAIL} failed ==="; exit 1
else
    ok "(0) CONTROL: the classifier ran and returned a bucket for all ${n_in} addresses"
fi

# ---------------------------------------------------------------------------
# 1. POSITIVE CONTROL for the declared arm. An address the map holds EXACTLY
#    must come back declared, or a "pool" verdict below would prove nothing --
#    it could just mean nothing ever matches.
# ---------------------------------------------------------------------------
b="$(bucket_of "$TMP/out" 192.200.0.104)"
[ "$b" = declared ] \
    && ok "(1) CONTROL: an exactly-resolved declared address -> declared" \
    || no "(1) CONTROL FAILED: 192.200.0.104 is in the map and came back '${b}'" "$(cat "$TMP/out")"

# ---------------------------------------------------------------------------
# 2. THE DEFECT. The pool member the run's own lookup did not return.
#
#    THE SUBJECT MOVED 2026-09-18. It was 192.200.0.111, the real address from
#    #1143, but that address now sits inside a declared CIDR and classifies
#    `network` before the pool arm is ever reached -- so it would have gone on
#    passing this assertion while testing a different arm entirely. It is
#    replaced by 20.205.243.170, a member of api.github.com's pool, which is in
#    no declared network and therefore still exercises the pool arm. Assertion
#    (9) covers the address that moved.
# ---------------------------------------------------------------------------
b="$(bucket_of "$TMP/out" 20.205.243.170)"
if [ "$b" = pool ]; then
    ok "(2) 20.205.243.170, a member of api.github.com's pool that this run did not resolve -> pool (CANNOT-RUN), not a violation"
elif [ "$b" = undeclared ]; then
    no "(2) #1143 IS BACK: a pool member of a DECLARED host classified as undeclared, which makes the probe FAIL a walk on declared infrastructure" "$(cat "$TMP/out")"
else
    no "(2) 20.205.243.170 classified '${b}', expected pool" "$(cat "$TMP/out")"
fi

# ---------------------------------------------------------------------------
# 3. THE NEGATIVE CONTROL, and it is the load-bearing one. Neither the pool arm
#    nor the network arm may be a rubber stamp. 203.0.113.45 is TEST-NET-3
#    (RFC 5737), reserved for documentation: it shares a /24 with nothing any
#    declared host resolved to, sits in no declared CIDR, and can never become
#    a real destination that someone later explains away.
# ---------------------------------------------------------------------------
b="$(bucket_of "$TMP/out" 203.0.113.45)"
[ "$b" = undeclared ] \
    && ok "(3) NEGATIVE CONTROL: 203.0.113.45, in no declared pool and no declared network -> undeclared, so the probe can still accuse" \
    || no "(3) NEGATIVE CONTROL FAILED: an address in no declared pool and no declared network classified '${b}'. An arm clears everything and the probe can no longer fail" "$(cat "$TMP/out")"

# ---------------------------------------------------------------------------
# 4. The live relay map still attributes. Guards against the pool arm being
#    inserted ahead of the DERP leg and swallowing it.
# ---------------------------------------------------------------------------
b="$(bucket_of "$TMP/out" 205.147.105.30)"
[ "$b" = declared ] \
    && ok "(4) a live DERP relay address -> declared" \
    || no "(4) a DERP node in the map classified '${b}'" "$(cat "$TMP/out")"

# ---------------------------------------------------------------------------
# 5. CANNOT-RUN stays CANNOT-RUN. With no relay map, an address in no declared
#    pool is UNCHECKED, not undeclared: "not a relay" was never established.
# ---------------------------------------------------------------------------
rc="$(classify "$PROBE" "$TMP/map-noderp.tsv" "$TMP/addrs.txt" "$TMP/out2")"
if [ "$rc" != 0 ]; then
    no "(5) classifier exited ${rc} on the no-relay map" "$(cat "$TMP/out2" "$TMP/out2.err" 2>/dev/null)"
else
    b="$(bucket_of "$TMP/out2" 203.0.113.45)"
    [ "$b" = unchecked ] \
        && ok "(5) with the DERP map unavailable, an unmatched address -> unchecked, not undeclared" \
        || no "(5) with no relay map, 203.0.113.45 classified '${b}', expected unchecked" "$(cat "$TMP/out2")"
    b="$(bucket_of "$TMP/out2" 20.205.243.170)"
    [ "$b" = pool ] \
        && ok "(5b) the pool arm is decided before the relay map is consulted, so it survives a missing DERP map" \
        || no "(5b) with no relay map, the pool member classified '${b}', expected pool" "$(cat "$TMP/out2")"
    b="$(bucket_of "$TMP/out2" 199.165.136.100)"
    [ "$b" = network ] \
        && ok "(5c) the network arm is also decided before the relay map, so a declared CIDR survives a missing DERP map" \
        || no "(5c) with no relay map, the declared-network address classified '${b}', expected network" "$(cat "$TMP/out2")"
fi

# ---------------------------------------------------------------------------
# 6. A BROKEN APPARATUS OUTRANKS EVERYTHING. If the ledger could not be
#    consulted, no address may be called declared, pool or undeclared.
# ---------------------------------------------------------------------------
rc="$(classify "$PROBE" "$TMP/map-broken.tsv" "$TMP/addrs.txt" "$TMP/out3")"
if [ "$rc" != 0 ]; then
    no "(6) classifier exited ${rc} on the broken-apparatus map" "$(cat "$TMP/out3" "$TMP/out3.err" 2>/dev/null)"
else
    other="$(awk -F'\t' '$1 != "unchecked"' "$TMP/out3" | grep -c . || true)"
    [ "${other:-0}" -eq 0 ] \
        && ok "(6) a ledger that could not be consulted makes every address unchecked, with no verdict borrowed from a half-read map" \
        || no "(6) ${other} address(es) got a verdict while the ledger was unreadable" "$(cat "$TMP/out3")"
fi

# ---------------------------------------------------------------------------
# 7. ZERO DENOMINATOR REFUSAL. A map claiming to be healthy with no HOST row
#    would classify every address against an empty set, which reads as a clean
#    comparison and is not one.
# ---------------------------------------------------------------------------
: > "$TMP/map-empty.tsv"
rc="$(classify "$PROBE" "$TMP/map-empty.tsv" "$TMP/addrs.txt" "$TMP/out4")"
[ "$rc" = 2 ] \
    && ok "(7) an empty declared map is refused (rc=2), not classified against silently" \
    || no "(7) an empty declared map returned rc=${rc}, expected 2" "$(cat "$TMP/out4" "$TMP/out4.err" 2>/dev/null)"

# ---------------------------------------------------------------------------
# 8. THE NETWORK ARM ATTRIBUTES AN ADDRESS NO NAME COULD REACH. Added
#    2026-09-18 with the arm itself. 199.165.136.100 is Ostler's own tailscaled
#    holding a control connection on an address Tailscale's dial plan handed
#    out; DNS does not publish it and it is in neither DERP map, so no
#    hostname can ever resolve to it. The ledger declares the network instead.
# ---------------------------------------------------------------------------
b="$(bucket_of "$TMP/out" 199.165.136.100)"
[ "$b" = network ] \
    && ok "(8) an address inside a DECLARED CIDR that no name resolved to -> network, not undeclared" \
    || no "(8) 199.165.136.100 classified '${b}', expected network. Either the CIDR rows are missing from the ledger or the arm is not wired" "$(cat "$TMP/out")"

# ---------------------------------------------------------------------------
# 9. A NAME STILL BEATS A NETWORK, AND THE ORDER IS THE POINT. 192.200.0.104 is
#    both a resolved declared host AND inside a declared CIDR. If the network
#    arm ran first it would swallow the stronger attribution and every
#    Tailscale destination would print as "owner attributed, service not" even
#    when the service was known. That would be a real loss of information
#    dressed as a pass.
# ---------------------------------------------------------------------------
b="$(bucket_of "$TMP/out" 192.200.0.104)"
[ "$b" = declared ] \
    && ok "(9) an address that BOTH resolves from a declared host and sits in a declared CIDR -> declared, so the stronger attribution wins" \
    || no "(9) 192.200.0.104 classified '${b}', expected declared. The network arm has been moved ahead of the name arm and is hiding known services" "$(cat "$TMP/out")"

# ===========================================================================
# MUTATION TESTING, BOTH DIRECTIONS.
#
# A test that passes against the fixed file proves only that the file and the
# test agree today. These two prove the assertions above are load-bearing: one
# reintroduces the defect and must go RED, the other blinds the arm the other
# way and must also go RED. If either mutant passes, this file is decoration.
# ===========================================================================
echo
echo "  -- mutation --"

# MUTATION 1: REINTRODUCE #1143. Delete the pool arm from bucket_for_ip, which
# is exactly the state main was in when the live box reported the FAIL.
python3 - "$PROBE" "$TMP/mutant-nopool.sh" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
arm = """    if pool="$(pool_attribution_for "$ip")"; then
        printf 'pool\\t%s\\n' "$pool"
        return 0
    fi
"""
if arm not in src:
    sys.stderr.write("MUTATION 1 DID NOT APPLY: the pool arm is not where this test expects it\n")
    raise SystemExit(3)
open(sys.argv[2], "w").write(src.replace(arm, "", 1))
PY
m1_built=$?

# 🔴 A MUTANT THAT DID NOT APPLY LOOKS EXACTLY LIKE ONE THAT WAS NOT CAUGHT.
# The builder exits 3 rather than writing an unchanged copy, and that is
# checked here before its verdict is read.
if [ "$m1_built" != 0 ]; then
    no "(M1) the mutant could not be built, so nothing was mutation-tested" "re-point this test at bucket_for_ip"
else
    rc="$(classify "$TMP/mutant-nopool.sh" "$TMP/map.tsv" "$TMP/addrs.txt" "$TMP/m1")"
    if [ "$rc" != 0 ]; then
        no "(M1) the mutant did not run (rc=${rc})" "$(cat "$TMP/m1" "$TMP/m1.err" 2>/dev/null)"
    else
        b="$(bucket_of "$TMP/m1" 20.205.243.170)"
        [ "$b" = undeclared ] \
            && ok "(M1) RED ON THE DEFECT: with the pool arm removed, the declared pool member is classified '${b}' again -- assertion (2) is load-bearing" \
            || no "(M1) MUTANT SURVIVED: removing the pool arm still classified 20.205.243.170 as '${b}', so assertion (2) proves nothing" "$(cat "$TMP/m1")"
    fi
fi

# MUTATION 2: BLIND IT THE OTHER WAY. Make the pool arm a rubber stamp that
# claims every address belongs to a declared pool. A probe that can never
# accuse is worse than one that over-accuses, and only assertion (3) can see
# it.
python3 - "$PROBE" "$TMP/mutant-stamp.sh" <<'PY'
import sys
src = open(sys.argv[1]).read()
needle = """    pfx="$(_v4_24_prefix "$ip")"
    [ -n "$pfx" ] || return 1
"""
if needle not in src:
    sys.stderr.write("MUTATION 2 DID NOT APPLY: pool_attribution_for is not where this test expects it\n")
    raise SystemExit(3)
stamp = """    printf 'EVERYTHING\\t1\\n'; return 0
"""
open(sys.argv[2], "w").write(src.replace(needle, stamp, 1))
PY
m2_built=$?

if [ "$m2_built" != 0 ]; then
    no "(M2) the mutant could not be built, so the rubber-stamp direction was not tested" "re-point this test at pool_attribution_for"
else
    rc="$(classify "$TMP/mutant-stamp.sh" "$TMP/map.tsv" "$TMP/addrs.txt" "$TMP/m2")"
    if [ "$rc" != 0 ]; then
        no "(M2) the mutant did not run (rc=${rc})" "$(cat "$TMP/m2" "$TMP/m2.err" 2>/dev/null)"
    else
        b="$(bucket_of "$TMP/m2" 203.0.113.45)"
        [ "$b" = pool ] \
            && ok "(M2) REFUSES WHEN BLINDED: a pool arm that clears everything turns the genuinely undeclared address into '${b}', and assertion (3) catches it" \
            || no "(M2) MUTANT SURVIVED: a rubber-stamp pool arm still left 203.0.113.45 as '${b}', so assertion (3) proves nothing" "$(cat "$TMP/m2")"
    fi
fi

# MUTATION 3: BLIND THE NETWORK ARM. Make network_attribution_for claim every
# address belongs to a declared network. This is the arm added on 2026-09-18
# and it is the one with the most room to become a rubber stamp, because a CIDR
# is a wider claim than a name by construction. If assertion (3) cannot see
# this, the arm could be widened to 0.0.0.0/0 and nothing would notice.
python3 - "$PROBE" "$TMP/mutant-net.sh" <<'PY'
import sys
src = open(sys.argv[1]).read()
needle = """    local ip="$1" cidr purpose
    [ -n "${DECLARED_CIDRS:-}" ] || return 1
"""
if needle not in src:
    sys.stderr.write("MUTATION 3 DID NOT APPLY: network_attribution_for is not where this test expects it\n")
    raise SystemExit(3)
stamp = """    printf 'EVERYTHING/0\\tstamped\\n'; return 0
"""
open(sys.argv[2], "w").write(src.replace(needle, stamp, 1))
PY
m3_built=$?

if [ "$m3_built" != 0 ]; then
    no "(M3) the mutant could not be built, so the network arm's rubber-stamp direction was not tested" "re-point this test at network_attribution_for"
else
    rc="$(classify "$TMP/mutant-net.sh" "$TMP/map.tsv" "$TMP/addrs.txt" "$TMP/m3")"
    if [ "$rc" != 0 ]; then
        no "(M3) the mutant did not run (rc=${rc})" "$(cat "$TMP/m3" "$TMP/m3.err" 2>/dev/null)"
    else
        b="$(bucket_of "$TMP/m3" 203.0.113.45)"
        [ "$b" = network ] \
            && ok "(M3) REFUSES WHEN BLINDED: a network arm that claims every address turns the genuinely undeclared one into '${b}', and assertion (3) catches it" \
            || no "(M3) MUTANT SURVIVED: a rubber-stamp network arm still left 203.0.113.45 as '${b}', so assertions (3) and (8) prove nothing" "$(cat "$TMP/m3")"
    fi
fi

echo
echo "=== ${PASS} passed / ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
