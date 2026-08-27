#!/usr/bin/env bash
# tests/test_enrich_kickstart_cannot_block_ingest.sh
# ============================================================================
# NO launchctl kickstart IN install.sh MAY BLOCK ITS CALLER.
#
# This file used to scope exactly ONE call site (com.ostler.enrich). That was
# too narrow, and the narrowness rested on a claim I never measured.
#
# ── WHAT WAS MEASURED, AND WHAT IT KILLED ──────────────────────────────────
#
# 2026-08-26 on a real box (macmini16, 16 GiB, macOS 26.5.2, arm64) the whole
# export-scan ingest chain had been wedged for 23h56m on 40 MILLISECONDS of
# total CPU:
#
#   ostler-assistant run-source export-scan   23:55:30  0:00.02
#   └ tick.sh                                 23:55:30  0:00.00
#     └ ostler-scan-exports                   23:55:30  0:00.01
#       └ ostler-import ~/Downloads           23:55:30  0:00.01
#         └ launchctl kickstart …enrich       23:50:30  0:00.00   <- the leaf
#
# Zero files written under ~/.ostler in ten minutes. Nothing ingested all day,
# while the product told the customer loading continues in the background.
#
# ROOT CAUSE: com.ostler.enrich pointed at ~/.ostler/bin/ostler-enrich-tick,
# which does not exist. launchd cannot spawn an absent program, so:
#     state = spawn scheduled | last exit code = 78: EX_CONFIG
#     properties = penalty box | inferred program | managed LWCR
# and kickstart waits on a spawn that is being deferred.
#
# I then asserted the OTHER call sites were safe because they pass -k, and
# wrote that into this file. IT WAS NEVER MEASURED. When I measured it:
#
#   CONTROL   kickstart     healthy agent      returned  (7s,  rc=0)
#   CONTROL   kickstart -k  healthy agent      returned  (21s, rc=0)
#   SUBJECT   kickstart     penalty-boxed      BLOCKED   (killed at 90s)
#   SUBJECT   kickstart -k  penalty-boxed      BLOCKED   (killed at 90s)
#
# -k IS NOT A DISCRIMINATOR. The experiment is committed at
# scripts/box_walk_probes/experiments/kickstart_k_blocks_on_penalty_box.sh --
# run it rather than trusting this comment.
#
# So the assertion is now a PROPERTY OVER THE WHOLE POPULATION, not a spot
# check on one line: every code call site must either go through _ks_bounded,
# or be explicitly classified below with a reason.
#
# ── WHY THE GUARDS THAT WERE THERE DID NOT WORK ────────────────────────────
#   `launchctl print … >/dev/null` proves the label is LOADED. A loaded job
#   pointing at an absent program passes it.
#   `|| true` covers a non-zero EXIT. The failure is a HANG -- no exit at all.
#   `>/dev/null 2>&1` made the whole thing invisible.
#   `timeout` does not exist on macOS, so a bound must be explicit.
#
# This test does NOT invoke launchctl. A test needing a penalty-boxed job to
# exist would be unrunnable on CI, and CANNOT-RUN is not PASS.
#
# 🔴 HERESTRINGS, NOT `printf | grep -q`. Under `set -o pipefail` that pipe is
# a RACE: grep -q exits on match, printf takes SIGPIPE, and the pipeline can
# report FAILURE for a needle that IS present (CM051 #895). Six of them were
# in this very file and the repo's own ratchet caught them.
#
# 🔴 NO bash-4 BUILTINS. install.sh runs under /bin/bash, which is 3.2 on every
# Mac. `mapfile` there is "command not found", and with `set -uo pipefail` and
# no `set -e` the run CONTINUES -- printing passes for the arms it reached
# while the rest silently never execute.
#
# Run: bash tests/test_enrich_kickstart_cannot_block_ingest.sh
# ============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
FAILURES=0
fail() { printf '  FAIL  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
pass() { printf '  ok    %s\n' "$1"; }

[ -r "$INSTALL_SH" ] || { echo "CANNOT-RUN: no readable $INSTALL_SH"; exit 2; }

# ── THE CLASSIFIED EXCEPTIONS ──────────────────────────────────────────────
# A raw `launchctl kickstart` is allowed ONLY at a line listed here, and only
# with a reason. This is a ratchet: a new site is a FAIL until someone decides
# which it is. "Bounded" is the default; an exception must be argued.
#
# tailscaled: its EXIT CODE IS LOAD-BEARING --
#     elif launchctl kickstart -k "…tailscaled"; then ok … else warn …
# It chooses a customer-visible message. Backgrounding it makes the condition
# always-true and reports "Tailscale started" for a daemon that never started.
# Lying to the customer is worse than stalling them. It needs a three-state
# bounded variant (started / failed / timed-out, timeout joining the warn
# branch), which is tracked separately -- NOT a blind background.
ALLOWED_RAW=" com.creativemachines.ostler.tailscaled "

# ── ARM 1: _ks_bounded must EXIST and be correctly shaped. Everything below
# ── depends on it, so if it is wrong the rest of this file proves nothing.
if ! grep -q '^_ks_bounded() {' "$INSTALL_SH"; then
    echo "CANNOT-RUN: _ks_bounded is not defined in install.sh. Every site below"
    echo "  routes through it; without it this test asserts nothing. Not a pass."
    exit 2
fi
HELPER_LINE=$(grep -n '^_ks_bounded() {' "$INSTALL_SH" | head -1 | cut -d: -f1)
HELPER=$(sed -n "${HELPER_LINE},$((HELPER_LINE + 22))p" "$INSTALL_SH")

# 🔴 COUNT BOTH BRANCHES. DO NOT ASK "IS ANY LINE BACKGROUNDED".
# _ks_bounded has TWO kickstart lines -- the -k branch and the bare branch.
# The first version of this arm was `grep -q 'launchctl kickstart .*&$'`, i.e.
# "does SOME line end in &". Mutation-proved GREEN with the bare branch's `&`
# removed: the -k branch's `&` satisfied it and the arm never saw the defect.
# An existential check over a population of two is half a check.
HK_TOTAL=$(grep -cE '^[[:space:]]*launchctl kickstart ' <<< "$HELPER" || true)
HK_BG=$(grep -cE '^[[:space:]]*launchctl kickstart .*&[[:space:]]*$' <<< "$HELPER" || true)
if [ "${HK_TOTAL:-0}" -lt 2 ]; then
    fail "_ks_bounded has ${HK_TOTAL:-0} kickstart line(s); expected 2 (-k branch + bare branch)."
    printf '        If the branches were collapsed, re-point this arm rather than dropping it.\n'
elif [ "${HK_BG:-0}" -eq "${HK_TOTAL:-0}" ]; then
    pass "_ks_bounded backgrounds ALL ${HK_TOTAL} kickstart branches (not just one)"
else
    fail "_ks_bounded backgrounds only ${HK_BG}/${HK_TOTAL} kickstart branches."
    printf '        The un-backgrounded branch blocks its caller exactly as the original\n'
    printf '        defect did. Both -k and bare block on a penalty-boxed job (measured).\n'
fi
if grep -q 'sleep 10' <<< "$HELPER" && grep -q 'kill -TERM' <<< "$HELPER"; then
    pass "_ks_bounded carries an explicit sleep+kill watchdog (no 'timeout' on macOS)"
else
    fail "_ks_bounded has no watchdog: a wedged kickstart lingers indefinitely"
fi
if grep -qE '^[[:space:]]*\)[[:space:]]*>/dev/null 2>&1 &[[:space:]]*$' <<< "$HELPER"; then
    pass "_ks_bounded backgrounds its enclosing subshell too (an inner wait cannot block)"
else
    fail "_ks_bounded's subshell is not backgrounded -- the inner wait still blocks"
fi

# ── ARM 2: EVERY code call site is bounded, or classified.
# ── Comments are excluded: a denominator that counts its own documentation is
# ── not a denominator. This file's header alone quotes the string many times.
RAW_ALL=$(grep -c 'launchctl kickstart' "$INSTALL_SH" || true)
SITES=$(grep -nE '^[[:space:]]*(elif[[:space:]]+)?launchctl kickstart' "$INSTALL_SH" || true)
BOUNDED=$(grep -cE '^[[:space:]]*_ks_bounded ' "$INSTALL_SH" || true)

RAW_N=0
while IFS= read -r _line; do
    [ -n "$_line" ] || continue
    _no=${_line%%:*}
    # The two lines INSIDE _ks_bounded are the implementation, not call sites.
    if [ "$_no" -gt "$HELPER_LINE" ] && [ "$_no" -lt $((HELPER_LINE + 22)) ]; then
        continue
    fi
    RAW_N=$((RAW_N + 1))
    _hit=""
    for _a in $ALLOWED_RAW; do
        case "$_line" in *"$_a"*) _hit="$_a" ;; esac
    done
    if [ -n "$_hit" ]; then
        pass "install.sh:${_no} raw kickstart is CLASSIFIED (${_hit}) -- exit code is load-bearing"
    else
        fail "install.sh:${_no} calls launchctl kickstart RAW and is not classified."
        printf '        -k does NOT make it safe (measured: blocks at 90s on a penalty-boxed\n'
        printf '        job, healthy controls returned in 7s/21s). Route it through _ks_bounded,\n'
        printf '        or add it to ALLOWED_RAW with the reason its exit code must be read.\n'
    fi
done <<< "$SITES"

printf '\nEXAMINED: %s bounded call site(s) via _ks_bounded, %s raw call site(s), %s classified.\n' \
    "${BOUNDED:-0}" "$RAW_N" "$(printf '%s' "$ALLOWED_RAW" | wc -w | tr -d ' ')"
printf '          (%s raw grep matches in the file; the rest are comments.)\n' "${RAW_ALL:-0}"

# ── ARM 3: THE CONTROL. If _ks_bounded is used nowhere, arms 1-2 are vacuous:
# ── zero raw sites and zero bounded sites would sail through.
if [ "${BOUNDED:-0}" -ge 4 ]; then
    pass "CONTROL: ${BOUNDED} sites actually route through _ks_bounded (not a vacuous pass)"
else
    fail "CONTROL FAILED: only ${BOUNDED:-0} site(s) use _ks_bounded. Either the helper"
    printf '        is unused -- making this whole test vacuous -- or the call sites were\n'
    printf '        reverted to raw kickstart under a name this test cannot see.\n'
fi

# ── ARM 4: the enrich site specifically. It is the one that was MEASURED
# ── wedged, so name it and keep it named.
if grep -qE '^[[:space:]]*_ks_bounded "gui/\$\(id -u\)/com\.ostler\.enrich"' "$INSTALL_SH"; then
    pass "the measured deadlock site (com.ostler.enrich) is bounded"
else
    fail "com.ostler.enrich is no longer bounded -- this is the site measured at"
    printf '        23h56m elapsed on 40ms of CPU. Do not un-bound it.\n'
fi

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "PASS -- no launchctl kickstart in install.sh can block its caller,"
    echo "        and every raw call site is classified with a reason."
    exit 0
fi
echo "FAIL -- $FAILURES assertion(s) failed."
exit 1
