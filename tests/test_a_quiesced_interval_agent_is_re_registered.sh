#!/usr/bin/env bash
# A bootout owes a re-registration, and the sibling gate could not see the debt.
#
# THE DEFECT, MEASURED ON THE WALK BOX 2026-09-18T17:20Z. The install printed
#
#   Quiesced com.ostler.fda-rerun while its program is replaced;
#   it is re-registered below.
#
# and then did not re-register it. Afterwards:
#
#   launchctl print gui/501/com.ostler.fda-rerun  -> rc=113,
#       "Could not find service com.ostler.fda-rerun in domain for user"
#   com.ostler.fda-rerun.plist mtime               2026-09-14 (PRE-install)
#   com.ostler.export-scan        last exit code = 0, runs = 1
#
# WHY ONLY ONE OF THE TWO. export-scan's plist is rewritten and bootstrapped on
# every run, so quiescing it is free. fda-rerun's load is gated on
# _OSTLER_FDA_RERUN_LOAD_PENDING, which is set at exactly ONE site: inside the
# plist-rewrite block, which fires only when the plist is ABSENT, carries the
# legacy StartCalendarInterval, or lacks the homebrew PATH. On an upgrade whose
# plist is already current all three are false, the flag is never set, and the
# bootout is permanent -- the hourly FDA re-run is gone until the next login.
#
# A FRESH INSTALL WAS NEVER AFFECTED (plist absent -> rewrite -> flag set),
# which is exactly why every fresh-install probe stayed green over it.
#
# WHY THIS FILE EXISTS RATHER THAN A LINE IN THE SIBLING GATE. The sibling
# asserts the quiesce is ORDERED correctly and NAMES both labels. Both were
# true throughout. Ordering is not debt. This gate RUNS the function with
# launchctl stubbed and reads the flag it leaves behind, and it carries a
# MUTANT so that a pass means the assertion could have failed.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

FN="_ostler_quiesce_interval_agents"
SRC="install.sh"
[ -f "$SRC" ] || { echo "CANNOT-RUN: $SRC is not a file" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Extract the function by brace depth, not by a line count that rots.
awk -v fn="$FN" '
  index($0, fn "() {") == 1 { on = 1 }
  on {
    print
    n = gsub(/\{/, "{"); m = gsub(/\}/, "}")
    depth += n - m
    if (depth <= 0 && NR > 1) exit
  }
' "$SRC" > "$WORK/fn.sh"

if [ ! -s "$WORK/fn.sh" ]; then
  echo "CANNOT-RUN: could not extract $FN from $SRC -- the definition form changed" >&2
  exit 2
fi
echo "     EXAMINED: $FN, $(wc -l < "$WORK/fn.sh" | tr -d ' ') line(s) extracted from $SRC"

# The harness: launchctl is stubbed so no real job is touched. `print` returning
# 0 means "this label IS loaded", which is the state that creates the debt.
harness() {   # $1 = function file, $2 = launchctl print rc
  HOME="$WORK/home" FDA_RERUN_PLIST="" bash -c '
    set -uo pipefail
    _print_rc="$2"
    launchctl() { case "$1" in print) return "$_print_rc";; bootout) return 0;; *) return 0;; esac; }
    info() { :; }
    export -f launchctl 2>/dev/null || true
    . "$1"
    '"$FN"'
    printf "%s" "${_OSTLER_FDA_RERUN_LOAD_PENDING:-UNSET}"
  ' _ "$1" "$2"
}

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  [PASS] $1"; }
bad() { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }

# ---- THE SUBJECT, FIRST. ----------------------------------------------------
#
# 🔴 ORDER MATTERS HERE, AND GETTING IT WRONG WAS CAUGHT BY RUNNING THIS GATE
# AGAINST THE UNFIXED TREE. The mutant control below used to run first and
# exit 2 when the mutant came out identical to the subject -- which is exactly
# what happens on a tree where the flag line is ABSENT, i.e. the defective one.
# So the gate answered CANNOT-RUN on the very tree it exists to fail. CANNOT-RUN
# is not FAIL: a CI step that only checks for rc=1 would have shipped the defect.
# The subject is therefore judged before any control can short-circuit.
got="$(harness "$WORK/fn.sh" 0)"
if [ "$got" = "1" ]; then
  ok "quiescing a LOADED com.ostler.fda-rerun sets _OSTLER_FDA_RERUN_LOAD_PENDING=1, so the deferred load re-registers it"
else
  bad "the quiesce booted out com.ostler.fda-rerun and left _OSTLER_FDA_RERUN_LOAD_PENDING='$got'."
  bad "  The deferred load is gated on that flag being 1, so the agent is booted out and"
  bad "  never comes back, while the install still prints 'it is re-registered below'."
  bad "  Upgrades only: a fresh install has no plist, so the rewrite sets the flag."
fi

# ---- CONTROL 1: the mutant. Strip the flag line; the flag must go UNSET. -----
# Only meaningful when the subject passed. When the subject has already failed
# the flag line is absent by definition, so a mutant identical to the subject is
# a restatement of the failure, not a reason to stop measuring.
grep -v '_OSTLER_FDA_RERUN_LOAD_PENDING=1' "$WORK/fn.sh" > "$WORK/mutant.sh"
if cmp -s "$WORK/fn.sh" "$WORK/mutant.sh"; then
  if [ "$got" = "1" ]; then
    bad "CONTROL (mutant): the mutant is identical to the subject, yet the subject set the"
    bad "                  flag. Something other than the expected line is setting it and"
    bad "                  this gate is not measuring what it claims."
  else
    echo "  [ -- ] CONTROL (mutant): skipped, the flag line is absent -- which IS the failure above"
  fi
else
  mut="$(harness "$WORK/mutant.sh" 0)"
  if [ "$mut" = "UNSET" ]; then
    ok "CONTROL (mutant): with the flag line removed the flag is UNSET, so this gate can fail"
  else
    bad "CONTROL (mutant): flag came back '$mut' with the setting line removed. The"
    bad "                  harness is not reading what it thinks it is; the verdict above is void."
  fi
fi

# ---- CONTROL 2: an agent that was NOT loaded creates no debt. ---------------
notloaded="$(harness "$WORK/fn.sh" 1)"
if [ "$notloaded" = "UNSET" ]; then
  ok "CONTROL (not loaded): no bootout happened, so no re-registration is owed"
else
  bad "CONTROL (not loaded): flag set to '$notloaded' without any bootout. The quiesce"
  bad "                      would force a load on a box that never had the agent."
fi

# ---- The function must survive `set -e` at top level. -----------------------
if bash -c 'set -euo pipefail
    launchctl() { case "$1" in print) return 1;; *) return 0;; esac; }
    info() { :; }
    . "$1"
    '"$FN"'
  ' _ "$WORK/fn.sh" >/dev/null 2>&1; then
  ok "the function returns 0 when no agent is loaded, so it cannot abort the install under set -e"
else
  bad "$FN returned non-zero with no agent loaded. It is called at top level under"
  bad "  set -e, so this aborts the install outright."
fi

echo
echo "== $PASS pass / $FAIL fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
