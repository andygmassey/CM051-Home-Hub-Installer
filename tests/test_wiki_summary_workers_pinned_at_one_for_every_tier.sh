#!/usr/bin/env bash
#
# tests/test_wiki_summary_workers_pinned_at_one_for_every_tier.sh
#
# v1.0.121: the wiki-recompile summary-worker cap is PINNED at 1 for every
# tier. Once the LaunchAgent PATH could find sysctl (CM051 #3250), the tier
# read correctly for the first time and the old map (floor 1 / low 2 / high 3)
# would have raised the cap on every supported Mac; no walk has run above 1.
#
# WHAT THIS RUNS. The REAL governor block is cut out of
# wiki-recompile/bin/wiki-recompile-tick.sh (from WIKI_WORKERS_PINNED to its
# closing fi) and run against the REAL tier lib, with sysctl stubbed to a given
# RAM / core count, for 16, 24, 32 and 48 GB, the core demotion (4 cores at
# 16 and 48 GB), and an explicit OSTLER_TIER of floor, low and high. Every case
# must leave WIKI_TIER_WORKERS=1, and the tier must be the one expected (so a
# pin cannot pass by the tier lib silently reading nothing).
#   M  MUTANT: the old tier map restored in a copy of the wrapper; this test
#      re-run against it must exit 1.
# WRAPPER may point at another copy. Exit 0 pass, 1 fail, 2 cannot-run.
# Bash 3.2 portable. Synthetic only.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
WRAPPER="${WRAPPER:-${REPO}/wiki-recompile/bin/wiki-recompile-tick.sh}"
LIB="${REPO}/lib/ostler-resource-tier.sh"
[ -r "$WRAPPER" ] && [ -r "$LIB" ] || { echo "CANNOT-RUN: wrapper or tier lib unreadable"; exit 2; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }
SANDBOX="$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd)/wiki-pin.XXXXXX")" || { echo "CANNOT-RUN: mktemp"; exit 2; }
trap 'rm -rf "$SANDBOX"' EXIT

awk '/^WIKI_WORKERS_PINNED=/{f=1} f{print} f&&/^fi$/{exit}' "$WRAPPER" > "${SANDBOX}/block.sh"
[ -s "${SANDBOX}/block.sh" ] && /usr/bin/grep -q 'WIKI_TIER_WORKERS' "${SANDBOX}/block.sh" \
    || { echo "CANNOT-RUN: governor block not found in $WRAPPER (no WIKI_WORKERS_PINNED)"; exit 2; }

BIN="${SANDBOX}/bin"; mkdir -p "$BIN"
cat > "${BIN}/sysctl" <<'SH'
#!/bin/sh
case "$*" in
    *hw.memsize*) echo $(( ${FAKE_RAM_GB} * 1073741824 )) ;;
    *hw.ncpu*) echo "${FAKE_CORES}" ;;
    *perflevel0.physicalcpu*) echo 4 ;;
    *hw.physicalcpu*) echo "${FAKE_CORES}" ;;
    *vm.loadavg*) echo "{ 0.10 0.10 0.10 }" ;;
    *) exit 1 ;;
esac
SH
chmod +x "${BIN}/sysctl"

run_case() { # label ram cores tier_override expect_tier
    local label="$1" ram="$2" cores="$3" ov="$4" want="$5" out H
    H="${SANDBOX}/h.$$.$RANDOM"; mkdir -p "$H"
    out="$(env -i HOME="$H" PATH="${BIN}:/usr/bin:/bin" FAKE_RAM_GB="$ram" FAKE_CORES="$cores" \
        OSTLER_TIER="$ov" OSTLER_RESOURCE_TIER_LIB="$LIB" /bin/bash -c '
            log() { :; }
            . "$1"
            echo "tier=${OSTLER_TIER:-?} workers=${WIKI_TIER_WORKERS-UNSET}"' _ "${SANDBOX}/block.sh" 2>&1)"
    if [ "$out" = "tier=${want} workers=1" ]; then ok "${label}: ${out}"
    else bad "${label}: expected tier=${want} workers=1, got '${out}'"; fi
}
run_case "16GB / 10 cores"            16 10 ""      low
run_case "24GB / 10 cores"            24 10 ""      low
run_case "32GB / 10 cores"            32 10 ""      high
run_case "48GB / 12 cores"            48 12 ""      high
run_case "16GB / 4 cores (demoted)"   16 4  ""      floor
run_case "48GB / 4 cores (demoted)"   48 4  ""      low
run_case "explicit floor"             16 10 floor   floor
run_case "explicit low"               16 10 low     low
run_case "explicit high"              16 10 high    high

if [ -z "${WIKI_PIN_IN_MUTANT:-}" ]; then
    # MUTANT: restore the old tier map in place of the pin.
    sed 's|^            WIKI_TIER_WORKERS="\$WIKI_WORKERS_PINNED"$|            case "${OSTLER_TIER:-}" in floor) WIKI_TIER_WORKERS=1 ;; low) WIKI_TIER_WORKERS=2 ;; high) WIKI_TIER_WORKERS=3 ;; esac|' "$WRAPPER" > "${SANDBOX}/wrapper.mutant.sh"
    if cmp -s "$WRAPPER" "${SANDBOX}/wrapper.mutant.sh"; then bad "M the mutant did not apply"
    else
        WIKI_PIN_IN_MUTANT=1 WRAPPER="${SANDBOX}/wrapper.mutant.sh" bash "${BASH_SOURCE[0]}" >"${SANDBOX}/mutant.out" 2>&1; mrc=$?
        if [ "$mrc" -eq 1 ]; then ok "M mutant (tier map restored) is RED, rc=1: $(/usr/bin/grep -c FAIL "${SANDBOX}/mutant.out") cases fail"
        else bad "M mutant not caught (rc=${mrc})"; fi
    fi
fi
echo "pass=${PASS} fail=${FAIL}"
[ "$FAIL" -eq 0 ]
