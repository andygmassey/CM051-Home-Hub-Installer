#!/usr/bin/env bash
# The iMessage backfill ladder must actually run, and must not race (#770)
# =======================================================================
#
# Andy, 2026-08-16, deciding the product question:
#
#     "It should (eventually) be ALL of iMessage backlog. But we said we'd
#      start with 45 days initially so that the user sees something recent
#      and reasonable on first sight of Ostler."
#
# So 45 days is the FIRST RUNG, not the window. install.sh used to set
# OSTLER_IMESSAGE_BACKFILL_DAYS=45 on every install, and
# resolve_backfill_days() treats any explicit value as an operator pin that
# disables the ladder before it is ever consulted. MEASURED on the v1.0.32 box:
#
#     install.log:851
#       [backfill-ladder] imessage pinned to 45d by
#       OSTLER_IMESSAGE_BACKFILL_DAYS; ladder disabled
#
#     no backfill_horizon_imessage.json anywhere -- consistent, the pinned
#     path returns before persisting
#     45 days -> 33 of 2,130 conversations, permanently
#
# AND WHY THE DWELL IS PART OF THE FIX, NOT A NICETY
#
# The ladder advances once per CALL, so its pace is set by whatever invokes
# extract_all. VERIFIED on the installed box, because `run-source` dispatches
# generically to ingest/<src>/tick.sh and the agent name decides nothing:
#
#     ingest/export-scan/tick.sh   runs ostler-scan-exports. No extract_all.
#     ingest/fda-rerun/tick.sh     calls ostler_fda.extract_all.run_all
#     CONTROL: grep -rl extract_all over ingest/ returns fda-rerun and nothing
#              else, so the single hit is a real population and not a miss.
#
# So the invoker is one-shot today. A pace still matters the moment it recurs:
# install.sh prices arrival at the top rung at ~28,405 conversations x ~1.20 min
# of chained local inference. Controls (6) and (7) are as load-bearing as (1).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$REPO_ROOT/install.sh"
LADDER="$REPO_ROOT/vendor/ostler_fda/backfill_ladder.py"

FAILURES=0
CHECKS=0
fail() { echo "  FAIL  $*" >&2; FAILURES=$((FAILURES + 1)); }
pass() { echo "  PASS  $*"; }
check() {
    CHECKS=$((CHECKS + 1))
    if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$3', got '$2')"; fi
}

[[ -f "$INSTALL" ]] || { echo "CANNOT-RUN: install.sh not found at $INSTALL" >&2; exit 2; }
[[ -f "$LADDER"  ]] || { echo "CANNOT-RUN: vendored backfill_ladder.py not found at $LADDER" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "CANNOT-RUN: python3 not on PATH" >&2; exit 2; }

HARNESS="$(mktemp -d -t ladder-XXXXXX)"
trap 'rm -rf "$HARNESS"' EXIT

echo "test_imessage_ladder_not_pinned.sh"

# The pin predicate, applied to CODE lines only. The comments in install.sh
# deliberately QUOTE the removed line, so a bare substring test would read the
# explanation of the fix as the defect surviving.
pin_count() {
    grep -v '^[[:space:]]*#' "$1" | grep -c 'OSTLER_IMESSAGE_BACKFILL_DAYS:=' || true
}

# (0) CONTROL FIRST. The predicate must FIRE on a pin. Without this, (1)'s zero
#     is indistinguishable from a predicate that can no longer see anything.
#
#     Asserted as a DELTA, not an absolute. An absolute "expect 1" reads as a
#     control failure when the real defect is also present, which buries the
#     signal from (1) under noise from (0). The claim being made is "adding a
#     pin makes the count go up by exactly one", and that holds either way.
cp "$INSTALL" "$HARNESS/pinned.sh"
printf '%s\n' ': "${OSTLER_IMESSAGE_BACKFILL_DAYS:=45}"' >> "$HARNESS/pinned.sh"
check "(0) CONTROL: adding a pin raises the predicate's count by exactly 1" \
      "$(( $(pin_count "$HARNESS/pinned.sh") - $(pin_count "$INSTALL") ))" "1"

# (1) THE DEFECT. install.sh must not default the variable at all.
check "(1) install.sh does NOT default OSTLER_IMESSAGE_BACKFILL_DAYS" "$(pin_count "$INSTALL")" "0"

# (2) set -u SAFETY. install.sh runs under `set -Eeuo pipefail`, so the
#     pass-through of an unset variable must use `:-` or the install aborts.
CHECKS=$((CHECKS + 1))
if grep -q 'OSTLER_IMESSAGE_BACKFILL_DAYS="${OSTLER_IMESSAGE_BACKFILL_DAYS:-}"' "$INSTALL"; then
    pass "(2) the pass-through is set -u safe"
else
    fail "(2) the pass-through would abort under set -u when the var is unset"
fi
CHECKS=$((CHECKS + 1))
if grep -q 'OSTLER_IMESSAGE_BACKFILL_DAYS="${OSTLER_IMESSAGE_BACKFILL_DAYS}"' "$INSTALL"; then
    fail "(2b) the bare unsafe pass-through is still present"
else
    pass "(2b) the bare unsafe pass-through is gone"
fi

# (3) MUST-BE-PRESENT CONTROL. The sibling sources have no ladder, so their
#     defaults must survive. If these vanished the predicate above would be
#     matching far more than intended.
for sib in BROWSER SAFARI WHATSAPP MAIL; do
    CHECKS=$((CHECKS + 1))
    if grep -q "OSTLER_${sib}_BACKFILL_DAYS:=1825" "$INSTALL"; then
        pass "(3) sibling ${sib} still defaults to 1825"
    else
        fail "(3) sibling ${sib} default was disturbed by this change"
    fi
done

# --- the REAL ladder, driven in a sandbox ----------------------------------
run_py() {
    OSTLER_STATE_DIR="$HARNESS/state" \
    PYTHONPATH="$REPO_ROOT/vendor" \
    python3 -c "$1" 2>&1
}

if ! run_py 'import ostler_fda.backfill_ladder' >/dev/null 2>&1; then
    echo "CANNOT-RUN: could not import the vendored backfill_ladder; this test" >&2
    echo "            drives the REAL module and refuses to run against a copy." >&2
    exit 2
fi

# (4) FIRST RUN is 45 days and it PERSISTS. Persistence is what makes the
#     ladder a ladder rather than a constant.
rm -rf "$HARNESS/state"
out="$(run_py '
from ostler_fda.backfill_ladder import resolve_backfill_days
print(resolve_backfill_days("imessage", "OSTLER_IMESSAGE_BACKFILL_DAYS"))')"
check "(4) first run takes the first rung, 45 days" "$out" "45"
CHECKS=$((CHECKS + 1))
if [[ -f "$HARNESS/state/backfill_horizon_imessage.json" ]]; then
    pass "(4b) the horizon was PERSISTED (the pinned path never got this far)"
else
    fail "(4b) no horizon written, so the ladder cannot advance next run"
fi

# (5) THE OPERATOR AFFORDANCE SURVIVES. An explicit value still pins.
rm -rf "$HARNESS/state"
out="$(OSTLER_IMESSAGE_BACKFILL_DAYS=1825 run_py '
from ostler_fda.backfill_ladder import resolve_backfill_days
print(resolve_backfill_days("imessage", "OSTLER_IMESSAGE_BACKFILL_DAYS"))')"
check "(5) an explicit operator value still pins the window" "$out" "1825"

# (6) DWELL HOLDS. Two calls back to back must NOT advance two rungs, or
#     un-pinning would race to the terminal rung within a day.
rm -rf "$HARNESS/state"
out="$(run_py '
from ostler_fda.backfill_ladder import resolve_backfill_days as r
a = r("imessage", "OSTLER_IMESSAGE_BACKFILL_DAYS")
b = r("imessage", "OSTLER_IMESSAGE_BACKFILL_DAYS")
c = r("imessage", "OSTLER_IMESSAGE_BACKFILL_DAYS")
print("%s %s %s" % (a, b, c))')"
check "(6) three calls in one second stay on the first rung" "$out" "45 45 45"

# (7) ...AND IT STILL ADVANCES once the dwell has elapsed. Without this, (6)
#     is satisfied by a ladder that never moves at all.
rm -rf "$HARNESS/state"
out="$(OSTLER_BACKFILL_DWELL_SECONDS=0 run_py '
from ostler_fda.backfill_ladder import resolve_backfill_days as r
print(" ".join(str(r("imessage", "OSTLER_IMESSAGE_BACKFILL_DAYS")) for _ in range(4)))')"
check "(7) with the dwell elapsed it DOES widen" "$out" "45 90 180 365"

# (8) THE TERMINAL RUNG MEANS ALL, not five years. Andy: "ALL of iMessage
#     backlog". A ladder that stops at 1825 truncates anyone who has been
#     messaging for longer than five years.
out="$(run_py '
from ostler_fda.backfill_ladder import DEFAULT_LADDER, next_rung
top = DEFAULT_LADDER[-1]
print("%d %s" % (top, next_rung(top) == top))')"
check "(8) the terminal rung is 36500 days and is terminal" "$out" "36500 True"
CHECKS=$((CHECKS + 1))
if run_py 'from ostler_fda.backfill_ladder import DEFAULT_LADDER
assert DEFAULT_LADDER == sorted(DEFAULT_LADDER), DEFAULT_LADDER' >/dev/null 2>&1; then
    pass "(8b) the ladder is ascending, which next_rung requires"
else
    fail "(8b) the ladder is not ascending; next_rung scans upward and would break"
fi

# (9) THE DWELL MUST NOT BLOCK THE LADDER, AND THE INVOKER MUST NOT STARVE IT.
#
#     ORIGINAL PREMISE, now superseded. TNM measured that com.ostler.fda-rerun
#     was ONE-SHOT (install.sh pinned Year/Month/Day/Hour/Minute into a
#     StartCalendarInterval at install +12h), and it is the ONLY agent whose
#     tick reaches extract_all. So the only advance a customer got without
#     re-running the installer was at +12h, once, ever. My first dwell was
#     86400, which would have BLOCKED even that -- every box stuck on rung 1
#     while the code read like a ladder.
#
#     #714 fixed the one-shot: the plist is now StartInterval, so an advance
#     OPPORTUNITY recurs forever instead of arriving once. This control was
#     deliberately pinned to the SCHEDULE rather than to a number so that it
#     would fail here when that happened, and it did. Re-anchoring rather than
#     relaxing.
#
#     THE INVARIANT IS NOW A RELATIONSHIP, NOT EITHER NUMBER:
#
#         rerun interval  <=  dwell
#
#     so the DWELL governs how fast the ladder climbs, and the invoker is
#     never the bottleneck. Read the two values from their real sources, so
#     moving either one on its own trips this.
rerun_interval="$(grep -oE ': "\$\{OSTLER_FDA_RERUN_INTERVAL_S:=[0-9]+\}"' "$INSTALL" \
                  | grep -oE '[0-9]+' | head -1)"
CHECKS=$((CHECKS + 1))
if [[ -n "$rerun_interval" ]] && [[ "$rerun_interval" -gt 0 ]]; then
    pass "(9) CONTROL: install.sh schedules the rerun on a recurring ${rerun_interval}s interval"
else
    fail "(9) could not read the fda-rerun interval from install.sh; the dwell below is no longer anchored"
fi

# (9a) AND IT MUST NOT HAVE REGRESSED TO A ONE-SHOT. A recurring StartInterval
#      plus a re-pinned calendar date would satisfy (9) while restoring the
#      original defect, so assert the mechanism -- the pinned DATE -- directly.
#      Independent of tests/test_fda_rerun_recurs.sh on purpose: two gates on
#      the same axis, so retiring either one does not leave it unguarded.
CHECKS=$((CHECKS + 1))
if ! grep -qE '^\s+<key>(Year|Month|Day)</key>' "$INSTALL"; then
    pass "(9a) no LaunchAgent pins a calendar DATE, which is what made it one-shot"
else
    fail "(9a) a plist pins Year/Month/Day again; that agent runs once and never more"
fi

dwell="$(run_py 'from ostler_fda.backfill_ladder import DEFAULT_DWELL_SECONDS
print(DEFAULT_DWELL_SECONDS)')"
CHECKS=$((CHECKS + 1))
if [[ -n "$rerun_interval" ]] && [[ "$rerun_interval" -le "$dwell" ]]; then
    pass "(9b) the rerun (${rerun_interval}s) is at least as often as the dwell (${dwell}s), so the dwell governs"
else
    fail "(9b) the rerun (${rerun_interval}s) is rarer than the dwell (${dwell}s); the invoker STARVES the ladder"
fi

echo
echo "=== $((CHECKS - FAILURES)) passed / $FAILURES failed ==="
[[ "$FAILURES" -eq 0 ]]
