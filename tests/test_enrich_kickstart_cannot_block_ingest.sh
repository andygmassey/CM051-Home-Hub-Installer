#!/usr/bin/env bash
# tests/test_enrich_kickstart_cannot_block_ingest.sh
# ============================================================================
# A FIRE-AND-FORGET KICKSTART MUST NOT BE ABLE TO WEDGE THE INGEST CHAIN.
#
# MEASURED 2026-08-26 on a real box (macmini16, 16 GiB) during the v1.0.47
# walk. The entire export-scan ingest chain had been wedged for 23h56m on
# 40 milliseconds of total CPU:
#
#   ostler-assistant run-source export-scan   23:55:30  0:00.02
#   └ tick.sh                                 23:55:30  0:00.00
#     └ ostler-scan-exports                   23:55:30  0:00.01
#       └ ostler-import ~/Downloads           23:55:30  0:00.01
#         └ launchctl kickstart …enrich       23:50:30  0:00.00   <- the leaf
#
# Zero files written under ~/.ostler in ten minutes. Nothing ingested all day,
# while the product tells the customer loading continues in the background.
#
# ROOT CAUSE. launchctl print reported, for com.ostler.enrich:
#     state           = spawn scheduled
#     last exit code  = 78: EX_CONFIG
#     properties      = penalty box | inferred program | managed LWCR
# Its program, ~/.ostler/bin/ostler-enrich-tick, DOES NOT EXIST on that box --
# an orphan LaunchAgent left behind when the enrichment agent was gated off.
# launchd cannot spawn it, penalty-boxes it, and a plain `kickstart` waits for
# a spawn that is being deferred.
#
# THE GUARD THAT WAS THERE DID NOT COVER THE FAILURE THAT HAPPENED:
#   `launchctl print … >/dev/null` proves the label is LOADED. A loaded job
#   pointing at an absent program passes it.
#   `|| true` covers a non-zero EXIT. The failure is a HANG.
#   `>/dev/null 2>&1` made the whole thing invisible.
#
# This test asserts the call is structurally incapable of blocking its caller.
# It does NOT invoke launchctl -- a test that needs a penalty-boxed job to
# exist would be unrunnable on CI, and CANNOT-RUN is not PASS.
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

# ── Locate the enrich kickstart. Anchored on the label, so it cannot drift
# ── onto one of the other kickstart call sites (there are several, and the
# ── others are legitimately synchronous `-k` restarts).
LINE_NO=$(grep -n 'launchctl kickstart "gui/\$(id -u)/com\.ostler\.enrich"' "$INSTALL_SH" | head -1 | cut -d: -f1)
if [ -z "$LINE_NO" ]; then
    echo "CANNOT-RUN: no enrich kickstart found in install.sh. It has moved or gone --"
    echo "  re-point this test rather than deleting it. The deadlock it guards is real."
    exit 2
fi
printf 'EXAMINED: enrich kickstart at install.sh:%s\n' "$LINE_NO"

# The surrounding block: enough to see the backgrounding and the watchdog.
BLOCK=$(sed -n "$((LINE_NO - 2)),$((LINE_NO + 8))p" "$INSTALL_SH")
# The kickstart LINE ITSELF, for the end-of-line assertions below.
KS_LINE=$(sed -n "${LINE_NO}p" "$INSTALL_SH")

# 🔴 HERESTRINGS, NOT `printf | grep -q`.
#
# This file's assertions were originally `printf '%s\n' "$X" | grep -q PAT`.
# Under `set -o pipefail` that construct is a RACE: grep -q exits the moment it
# matches, printf takes SIGPIPE, and the pipeline can report FAILURE for a
# needle that IS present. It passes on short input and fails under load, which
# is the worst possible failure mode for a gate. CM051 #895 is the same bug, and
# the repo carries a ratchet (tests/pipefail_shortcircuit_baseline.txt) that
# caught these six -- on this very PR, in a file whose sibling probe's comment
# already warned about exactly this.
#
# `grep -q PAT <<< "$X"` has no pipeline and therefore no race.

# 🔴 MATCH ON END-OF-LINE, NEVER ON "[^&]*&".
# The first draft of this test used `launchctl kickstart …[^&]*&` to look for a
# job-control ampersand, and `…[^&]*\|\| true` to look for the weak guard.
# BOTH gave FALSE PASSES on the un-fixed code, because the line contains
# `2>&1` -- the `&` inside the redirection satisfied the first pattern and
# blocked the second. The mutation run is what exposed it: two arms reported
# ok on code that had the defect. A job-control `&` is the LAST character of
# the command, so anchor there.

# ── ARM 1: the kickstart must be BACKGROUNDED. This is the whole defect --
# ── a synchronous call is what let a penalty-boxed job wedge the chain.
if grep -qE '&[[:space:]]*$' <<< "$KS_LINE"; then
    pass "the kickstart is backgrounded (&) -- the caller cannot wait on it"
else
    fail "the enrich kickstart is NOT backgrounded. A penalty-boxed job wedges"
    printf '        the entire ingest chain; measured at 23h56m on 40ms of CPU.\n'
fi

# ── ARM 2: the enclosing block must ALSO be backgrounded, or a `wait` inside
# ── it still blocks the import.
if grep -qE '^[[:space:]]*\)[[:space:]]*>/dev/null 2>&1 &[[:space:]]*$' <<< "$BLOCK"; then
    pass "the enclosing subshell is backgrounded too"
else
    fail "the subshell around the kickstart is not backgrounded -- an inner wait would still block"
fi

# ── ARM 3: there must be a WATCHDOG. Backgrounding stops the deadlock; without
# ── a bound, a wedged kickstart lingers for a day, which is how this was found.
# ── `timeout` does not exist on macOS, so the watchdog must be explicit.
if grep -q 'sleep 10' <<< "$BLOCK" && grep -q 'kill -TERM' <<< "$BLOCK"; then
    pass "a sleep+kill watchdog bounds the kickstart"
else
    fail "no watchdog: a wedged kickstart would linger indefinitely (no 'timeout' on macOS)"
fi

# ── ARM 4: THE CONTROL. `|| true` must NOT be the only guard. If someone
# ── reverts to a bare synchronous call with `|| true`, arms 1-3 fail, but
# ── state plainly WHY that guard is insufficient so the next reader does not
# ── re-add it thinking it is enough.
if grep -qE '\|\|[[:space:]]+true[[:space:]]*$' <<< "$KS_LINE"; then
    fail "the call is guarded ONLY by '|| true', which covers an EXIT CODE."
    printf '        The measured failure was a HANG. || true is blind to it.\n'
else
    pass "CONTROL: not relying on '|| true' alone to survive a wedged job"
fi

# ── ARM 5: the OTHER kickstart call sites are legitimately synchronous `-k`
# ── restarts. Prove this test is scoped, and print the denominator, so a
# ── future reader knows what was NOT being asserted.
OTHERS=$(grep -c 'launchctl kickstart' "$INSTALL_SH" || true)
printf 'EXAMINED: %s launchctl kickstart call(s) in install.sh; this test scopes ONE (com.ostler.enrich).\n' "${OTHERS:-0}"
printf '  The others use -k and are deliberate synchronous restarts, not fire-and-forget.\n'

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "PASS -- the enrich kickstart cannot block the ingest chain."
    exit 0
fi
echo "FAIL -- $FAILURES assertion(s) failed."
exit 1
