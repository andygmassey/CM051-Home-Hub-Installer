#!/usr/bin/env bash
#
# test_resource_tier_governor.sh
#
# Tests for the adaptive first-run resource governor (v1.0.3). The
# governor scales the background enrichment storm to the hardware tier so
# the interactive surfaces (chat, dashboard, Doctor, wiki) stay responsive
# on the 16GB floor. It proves:
#
#   1. The tier detector maps RAM + cores to a tier + concurrency cap +
#      defer flag + loadavg ceiling. FLOOR=1, LOW(16GB)=2, HIGH(32GB+)=4.
#   2. Detection failure falls back to the CONSERVATIVE (floor) cap, never
#      the unbounded storm.
#   3. A non-essential tick DEFERS when the per-core load is over the
#      tier ceiling, and PROCEEDS once load drops.
#   4. All four conversation feeds carry the governor gate and treat
#      themselves as non-essential.
#   5. The wiki recompile tick scales WIKI_LLM_WORKERS to the tier but is
#      NOT load-deferred (it is essential).
#   6. The embedded copy of the lib in install.sh has not drifted from the
#      canonical lib/ostler-resource-tier.sh (CI drift guard).
#   7. install.sh installs the lib and makes OLLAMA_NUM_PARALLEL tier-driven.
#
# British English throughout.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO_ROOT/lib/ostler-resource-tier.sh"
INSTALL_SH="$REPO_ROOT/install.sh"
FAILED=0

failure() { echo "FAIL: $*" >&2; FAILED=1; }
pass() { echo "ok: $*"; }

[ -f "$LIB" ] || { echo "FAIL: missing $LIB" >&2; exit 1; }
bash -n "$LIB" || failure "lib has a bash syntax error"

# --------------------------------------------------------------------
# Section 1 -- tier detection. Pin RAM/cores via sysctl-shim PATH so the
# test is deterministic on any host. The detector reads `sysctl -n
# hw.memsize` / `hw.ncpu` / `hw.perflevel0.physicalcpu`, so a shim that
# answers those keys controls the tier.
# --------------------------------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# sysctl shim. FAKE_MEMSIZE / FAKE_NCPU / FAKE_PERF control the hardware;
# FAKE_LOADAVG controls vm.loadavg. Unknown keys delegate to the real
# sysctl so anything else still works.
cat > "$TMP/bin/sysctl" <<'SHIM'
#!/bin/bash
# If a FAKE_* var is SET (even to empty) we answer authoritatively: a
# non-empty value is echoed and a set-but-empty value simulates a FAILED
# sysctl (echo nothing, non-zero). Only an UNSET FAKE var delegates to the
# real sysctl. This lets the detection-failure case pin "sysctl returns
# nothing" deterministically on any host.
key="$2"   # invoked as: sysctl -n <key>
answer() {  # answer <fake-set?> <fake-value>
    if [ "$1" = "set" ]; then
        [ -n "$2" ] && { echo "$2"; exit 0; }
        exit 1   # set-but-empty: simulate sysctl failure
    fi
}
case "$key" in
    hw.memsize)                answer "${FAKE_MEMSIZE+set}" "${FAKE_MEMSIZE:-}" ;;
    hw.ncpu)                   answer "${FAKE_NCPU+set}"    "${FAKE_NCPU:-}" ;;
    hw.perflevel0.physicalcpu) answer "${FAKE_PERF+set}"    "${FAKE_PERF:-}" ;;
    hw.physicalcpu)            answer "${FAKE_PHYS+set}"    "${FAKE_PHYS:-}" ;;
    vm.loadavg)                if [ -n "${FAKE_LOADAVG+x}" ]; then [ -n "$FAKE_LOADAVG" ] && { echo "{ $FAKE_LOADAVG }"; exit 0; }; exit 1; fi ;;
esac
exec /usr/sbin/sysctl "$@" 2>/dev/null || exec sysctl "$@"
SHIM
chmod +x "$TMP/bin/sysctl"

# detect_tier <memsize_bytes> <ncpu> <perf> -> prints OSTLER_TIER etc.
detect_with() {
    local mem="$1" ncpu="$2" perf="$3"
    env PATH="$TMP/bin:$PATH" \
        FAKE_MEMSIZE="$mem" FAKE_NCPU="$ncpu" FAKE_PERF="$perf" \
        bash "$LIB"
}

# 64GB / 16 cores / 12 P-cores -> high, concurrency 4, defer 0.
out="$(detect_with $((64*1073741824)) 16 12)"
echo "$out" | grep -q '^OSTLER_TIER=high$'             || failure "64GB should be HIGH tier, got: $out"
echo "$out" | grep -q '^OSTLER_ENRICH_CONCURRENCY=4$'  || failure "HIGH should cap concurrency 4"
echo "$out" | grep -q '^OSTLER_DEFER_NONESSENTIAL=0$'  || failure "HIGH should not defer"
[ "$FAILED" -eq 0 ] && pass "64GB/16-core -> HIGH (concurrency 4, no defer)"

out="$(detect_with $((16*1073741824)) 10 8)"
echo "$out" | grep -q '^OSTLER_TIER=low$'              || failure "16GB/8P should be LOW tier, got: $out"
echo "$out" | grep -q '^OSTLER_ENRICH_CONCURRENCY=2$'  || failure "LOW should cap concurrency 2"
echo "$out" | grep -q '^OSTLER_DEFER_NONESSENTIAL=1$'  || failure "LOW should defer non-essential"
[ "$FAILED" -eq 0 ] && pass "16GB/8-P-core -> LOW (concurrency 2, defer)"

# 8GB / 8 cores / 4 P-cores -> floor (sub-16 RAM): concurrency 1, defer 1.
out="$(detect_with $((8*1073741824)) 8 4)"
echo "$out" | grep -q '^OSTLER_TIER=floor$'            || failure "8GB should be FLOOR tier, got: $out"
echo "$out" | grep -q '^OSTLER_ENRICH_CONCURRENCY=1$'  || failure "FLOOR should cap concurrency 1"
echo "$out" | grep -q '^OSTLER_DEFER_NONESSENTIAL=1$'  || failure "FLOOR should defer non-essential"
[ "$FAILED" -eq 0 ] && pass "8GB -> FLOOR (concurrency 1, defer)"

# --------------------------------------------------------------------
# Section 1b -- THE BASE M-SERIES MATRIX.
#
# Every base Apple Silicon chip has exactly FOUR performance cores: M1,
# M2 and M3 are 4P+4E (8 total), the base M4 is 4P+6E (10 total). Measured
# on a Mac16,10 / Apple M4 / 16GB: hw.perflevel0.physicalcpu = 4,
# hw.perflevel1.physicalcpu = 6, hw.ncpu = 10.
#
# The old core-count override tested P-CORES against <=4, and its own
# comment said it was there to catch "an 8GB Air, were the 16GB prereq
# ever lowered" -- a machine that "somehow reports plenty of RAM". On
# Apple Silicon that test cannot discriminate, because the modal customer
# machine satisfies it. Measured against the unfixed lib: a 16GB base M4
# landed on FLOOR (OLLAMA_NUM_PARALLEL=1) and a 32GB base M4 could reach
# no higher than LOW, so NO base M-series Mac could ever reach HIGH at any
# RAM size. The RAM ladder was being silently overridden on the commonest
# hardware we ship to.
#
# It now tests TOTAL cores, which is what actually tracks "this machine
# cannot do concurrent work": every Apple Silicon Mac has at least 8, and
# a 2-core or 4-core Intel Mac or a pinched VM still trips it.
#
# These cases are asserted TOGETHER on purpose. The suite previously had a
# 16GB case and a 4-P-core case but never both in one fixture, so the one
# configuration most customers run was the one it never exercised.
# --------------------------------------------------------------------

# 16GB base M4 (4P + 6E). THE MODAL CUSTOMER MACHINE.
out="$(detect_with $((16*1073741824)) 10 4)"
echo "$out" | grep -q '^OSTLER_TIER=low$'              || failure "16GB base M4 (4P/10 total) must be LOW, not floor -- the RAM ladder must not be overridden by P-core count, got: $out"
echo "$out" | grep -q '^OSTLER_ENRICH_CONCURRENCY=2$'  || failure "16GB base M4 must get concurrency 2"
[ "$FAILED" -eq 0 ] && pass "16GB base M4 (4 P-cores, 10 total) -> LOW, not FLOOR"

# 24GB base M4. The RAM step must be visible, not flattened to the floor.
out="$(detect_with $((24*1073741824)) 10 4)"
echo "$out" | grep -q '^OSTLER_TIER=low$'              || failure "24GB base M4 must be LOW, got: $out"
[ "$FAILED" -eq 0 ] && pass "24GB base M4 -> LOW"

# 16GB base M1/M2/M3 (4P + 4E, 8 total).
out="$(detect_with $((16*1073741824)) 8 4)"
echo "$out" | grep -q '^OSTLER_TIER=low$'              || failure "16GB base M1/M2/M3 (4P/8 total) must be LOW, got: $out"
[ "$FAILED" -eq 0 ] && pass "16GB base M1/M2/M3 (4 P-cores, 8 total) -> LOW"

# 32GB base M4 must reach HIGH. Under the old rule no base M-series chip
# could reach HIGH at ANY RAM size, which is the sharpest form of the bug.
out="$(detect_with $((32*1073741824)) 10 4)"
echo "$out" | grep -q '^OSTLER_TIER=high$'             || failure "32GB base M4 must reach HIGH -- under the P-core rule no base M-series could reach HIGH at any RAM size, got: $out"
echo "$out" | grep -q '^OSTLER_ENRICH_CONCURRENCY=4$'  || failure "32GB base M4 must get concurrency 4"
[ "$FAILED" -eq 0 ] && pass "32GB base M4 -> HIGH (a base chip can reach the top tier)"

# THE OVERRIDE MUST STILL FIRE where it was meant to. A genuinely
# core-starved machine with plenty of RAM is still demoted one step. This
# is the control that stops the fix from being "delete the override".
out="$(detect_with $((32*1073741824)) 4 4)"
echo "$out" | grep -q '^OSTLER_TIER=low$'              || failure "32GB but only 4 TOTAL cores must still demote HIGH->LOW, got: $out"
[ "$FAILED" -eq 0 ] && pass "32GB with 4 TOTAL cores still demotes HIGH -> LOW (the override still works)"

out="$(detect_with $((16*1073741824)) 2 2)"
echo "$out" | grep -q '^OSTLER_TIER=floor$'            || failure "16GB but only 2 TOTAL cores must demote LOW->FLOOR, got: $out"
[ "$FAILED" -eq 0 ] && pass "16GB with 2 TOTAL cores demotes LOW -> FLOOR (the override still works)"

# Detection failure (sysctl returns nothing) -> conservative FLOOR.
out="$(detect_with "" "" "")"
echo "$out" | grep -q '^OSTLER_TIER=floor$'            || failure "detection failure must fall back to FLOOR, got: $out"
echo "$out" | grep -q '^OSTLER_ENRICH_CONCURRENCY=1$'  || failure "detection-failure fallback must cap to the conservative 1"
[ "$FAILED" -eq 0 ] && pass "detection failure -> conservative FLOOR (never the unbounded storm)"

# Operator/test override pins the tier.
out="$(env PATH="$TMP/bin:$PATH" FAKE_MEMSIZE=$((64*1073741824)) FAKE_NCPU=16 FAKE_PERF=12 OSTLER_TIER=floor bash "$LIB")"
echo "$out" | grep -q '^OSTLER_TIER=floor$'            || failure "OSTLER_TIER override must win, got: $out"
[ "$FAILED" -eq 0 ] && pass "OSTLER_TIER override pins the tier"

# --------------------------------------------------------------------
# Section 2 -- the non-essential defer decision under load.
# --------------------------------------------------------------------
defer_returns() {
    # defer_returns <ceiling> <cores> <loadavg> -> echoes "defer" or "proceed"
    local cap="$1" cores="$2" load="$3"
    env PATH="$TMP/bin:$PATH" FAKE_LOADAVG="$load 0 0" bash -c '
        . "'"$LIB"'"
        OSTLER_DEFER_NONESSENTIAL=1
        OSTLER_LOADAVG_CEILING='"$cap"'
        OSTLER_CPU_CORES='"$cores"'
        if ostler_resource_tier_should_defer_nonessential; then echo defer; else echo proceed; fi
    '
}

# Load 20 over 8 cores = 2.5 per-core, ceiling 1.5 -> DEFER.
got="$(defer_returns 1.5 8 20.0)"
[ "$got" = "defer" ] || failure "high load (2.5/core > 1.5) should DEFER, got '$got'"
[ "$got" = "defer" ] && pass "non-essential tick defers when per-core load exceeds the tier ceiling"

# Load 4 over 8 cores = 0.5 per-core, ceiling 1.5 -> PROCEED.
got="$(defer_returns 1.5 8 4.0)"
[ "$got" = "proceed" ] || failure "low load (0.5/core < 1.5) should PROCEED, got '$got'"
[ "$got" = "proceed" ] && pass "non-essential tick proceeds once load drops below the ceiling"

# Unreadable load + defer flag -> conservative DEFER (fail-safe).
got="$(env PATH="$TMP/bin:$PATH" bash -c '
    . "'"$LIB"'"
    OSTLER_DEFER_NONESSENTIAL=1
    OSTLER_LOADAVG_CEILING=1.5
    OSTLER_CPU_CORES=0
    if ostler_resource_tier_should_defer_nonessential; then echo defer; else echo proceed; fi
')"
[ "$got" = "defer" ] || failure "unreadable load + defer flag should DEFER, got '$got'"
[ "$got" = "defer" ] && pass "unreadable load falls back to the defer flag (conservative)"

# HIGH tier (defer flag 0) + unreadable load -> PROCEED (no needless defer).
got="$(env PATH="$TMP/bin:$PATH" bash -c '
    . "'"$LIB"'"
    OSTLER_DEFER_NONESSENTIAL=0
    OSTLER_LOADAVG_CEILING=3.0
    OSTLER_CPU_CORES=0
    if ostler_resource_tier_should_defer_nonessential; then echo defer; else echo proceed; fi
')"
[ "$got" = "proceed" ] || failure "HIGH tier with unreadable load should PROCEED, got '$got'"
[ "$got" = "proceed" ] && pass "HIGH tier proceeds even when load is unreadable"

# --------------------------------------------------------------------
# Section 3 -- the four conversation feeds carry the governor gate.
# --------------------------------------------------------------------
for w in whatsapp email imessage spoken; do
    f="$REPO_ROOT/vendor/${w}_source/bin/${w}-bundle-tick.sh"
    [ -f "$f" ] || { failure "$w: wrapper missing"; continue; }
    grep -q "Adaptive resource governor" "$f" \
        || failure "$w: missing the governor block"
    grep -q "ostler_resource_tier_should_defer_nonessential" "$f" \
        || failure "$w: must call the non-essential defer check"
    grep -q "OSTLER_RESOURCE_GOVERNOR" "$f" \
        || failure "$w: must honour the OSTLER_RESOURCE_GOVERNOR kill switch"
    grep -q "ostler-resource-tier.sh" "$f" \
        || failure "$w: must source the tier lib"
    # The governor must compose with the single-flight lock + off-peak gate.
    grep -q "ingest-ollama.lock.d" "$f" \
        || failure "$w: governor must not remove the single-flight lock"
    grep -q "OSTLER_INGEST_OFFPEAK_ONLY" "$f" \
        || failure "$w: governor must not remove the off-peak gate"
    bash -n "$f" || failure "$w: bash syntax error"
done
[ "$FAILED" -eq 0 ] && pass "all four feeds carry the governor + keep the lock + off-peak gates"

# --------------------------------------------------------------------
# Section 4 -- the wiki recompile tick scales workers, is NOT deferred.
# --------------------------------------------------------------------
WIKI="$REPO_ROOT/wiki-recompile/bin/wiki-recompile-tick.sh"
[ -f "$WIKI" ] || failure "wiki-recompile-tick.sh missing"
grep -q "Adaptive resource governor" "$WIKI" \
    || failure "wiki tick: missing the governor block"
grep -q "WIKI_TIER_WORKERS" "$WIKI" \
    || failure "wiki tick: must derive a tier-capped worker count"
grep -q 'WIKI_LLM_WORKERS=' "$WIKI" \
    || failure "wiki tick: must pass WIKI_LLM_WORKERS to the compile container"
# Wiki recompile is ESSENTIAL: it must NOT load-defer like the feeds.
if grep -q "ostler_resource_tier_should_defer_nonessential" "$WIKI"; then
    failure "wiki tick: must NOT call the non-essential defer check (it is essential)"
fi
bash -n "$WIKI" || failure "wiki tick: bash syntax error"
[ "$FAILED" -eq 0 ] && pass "wiki recompile scales workers to the tier and is never load-deferred"

# --------------------------------------------------------------------
# Section 5 -- install.sh wiring + embedded-copy drift guard.
# --------------------------------------------------------------------
grep -q 'ostler-resource-tier.sh' "$INSTALL_SH" \
    || failure "install.sh must install the tier lib"
grep -q 'OSTLER_RESOURCE_TIER_EOF' "$INSTALL_SH" \
    || failure "install.sh must embed the lib as a quoted heredoc"
grep -q '<string>${OSTLER_NUM_PARALLEL}</string>' "$INSTALL_SH" \
    || failure "install.sh must make OLLAMA_NUM_PARALLEL tier-driven"

# Drift guard: extract the embedded heredoc body and diff it against the
# canonical lib. They must be byte-identical (minus the heredoc markers).
EMBED="$(awk '/<<.OSTLER_RESOURCE_TIER_EOF.$/{f=1;next} /^OSTLER_RESOURCE_TIER_EOF$/{f=0} f' "$INSTALL_SH")"
if [ "$EMBED" = "$(cat "$LIB")" ]; then
    pass "embedded install.sh copy matches the canonical lib (no drift)"
else
    failure "embedded install.sh copy of the tier lib has DRIFTED from $LIB -- re-embed it"
fi

# --------------------------------------------------------------------
if [ "$FAILED" -eq 0 ]; then
    echo "ALL RESOURCE-TIER GOVERNOR TESTS PASSED"
    exit 0
fi
echo "RESOURCE-TIER GOVERNOR TESTS FAILED" >&2
exit 1
