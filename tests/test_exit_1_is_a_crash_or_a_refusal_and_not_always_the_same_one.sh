#!/usr/bin/env bash
# Exit 1 from the merge-consistency repair is TWO facts, and the installer
# used to assert only one of them.
#
# The pass documents EXIT_BROKEN_PREDICATE = 1. Python ALSO exits 1 on any
# uncaught exception. So a module that dies on import is indistinguishable by
# exit code from one that ran its negative control and refused.
#
# MEASURED, walk box 2026-09-18T17:17:56Z, one run, two accounts of it:
#   state file : verdict REFUSED / "the negative control was matched, so the
#                retirement predicate is broken"
#   log        : ImportError: cannot import name
#                'sweep_qdrant_orphans_of_merged_people'
#
# The real cause was a vendor skew (new repair_merge_consistency.py against an
# older batch_resolver.py) and the installer sent every reader to look at a
# SPARQL predicate. A confident diagnosis pointing away from the fault.
#
# This gate drives the SHIPPED branch text out of install.sh against two
# fixture logs and asserts the two verdicts differ.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
[ -f install.sh ] || { echo "CANNOT-RUN: install.sh not found" >&2; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# Extract the `1)` arm of the merge-consistency case, by its own landmarks
# rather than by line number, which rots on the next edit.
awk '/^                1\)$/{on=1} on{print} on && /^                    ;;$/{exit}' \
    install.sh > "$WORK/arm.sh"
# 🔴 THE EXTRACTION GUARD MUST KEY ON SOMETHING BOTH VERSIONS HAVE.
# A first draft checked for 'REFUSING: the negative control', which ONLY the
# fixed arm contains, so running this gate against the unfixed installer
# reported CANNOT-RUN instead of FAIL -- the gate excusing itself on precisely
# the tree it exists to catch. `_mcr_record 1` is present in both.
if ! grep -q '_mcr_record 1' "$WORK/arm.sh"; then
  echo "CANNOT-RUN: could not extract the rc=1 arm from install.sh -- its shape changed" >&2
  exit 2
fi
echo "     EXAMINED: rc=1 arm, $(wc -l < "$WORK/arm.sh" | tr -d ' ') line(s) extracted from install.sh"

# Strip the case-arm wrapper so the body can be sourced directly.
sed -e '1d' -e '$d' "$WORK/arm.sh" > "$WORK/body.sh"

pass=0; fail=0
ok()  { printf '  [PASS] %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; fail=$((fail+1)); }

verdict_for() {   # $1 = log contents; echoes the verdict passed to _mcr_record
  printf '%s\n' "$1" > "$WORK/log.txt"
  bash -c '
    set -uo pipefail
    _MCR_LOG="'"$WORK"'/log.txt"
    _mcr_record() { printf "%s" "$2"; }
    warn() { :; }
    . "'"$WORK"'/body.sh"
  '
}

# --- SUBJECT: a real crash must NOT be reported as the control firing -------
CRASH="Traceback (most recent call last):
  File \"<frozen runpy>\", line 198, in _run_module_as_main
ImportError: cannot import name 'sweep_qdrant_orphans_of_merged_people' from 'identity_resolver.batch_resolver'"
v="$(verdict_for "$CRASH")"
if [ "$v" = "CRASHED" ]; then
  ok "an ImportError at exit 1 is recorded as CRASHED, not as a matched negative control"
else
  bad "an ImportError was recorded as '$v'. The installer is naming a cause it did not observe,"
  bad "  and sending the reader to a SPARQL predicate when the fault is a vendor skew."
fi

# --- CONTROL: a genuine refusal must STILL be reported as REFUSED -----------
# Without this the fix could be "always say CRASHED", which loses the real
# signal the branch was written for.
REFUSAL="merge subjects examined : 56
REFUSING: the negative control https://control.invalid/person/must-never-be-retired was reported by the retirement predicate."
v="$(verdict_for "$REFUSAL")"
if [ "$v" = "REFUSED" ]; then
  ok "CONTROL: a genuine refusal is still recorded as REFUSED"
else
  bad "CONTROL: a genuine refusal was recorded as '$v'; the fix has destroyed the signal it was meant to preserve"
fi

# --- CONTROL: the two inputs must not produce the same verdict -------------
a="$(verdict_for "$CRASH")"; b="$(verdict_for "$REFUSAL")"
if [ "$a" != "$b" ]; then
  ok "CONTROL: the two causes produce DIFFERENT verdicts ($a vs $b), so exit 1 is no longer one fact"
else
  bad "CONTROL: both inputs produced '$a'. This gate cannot tell them apart and neither can the installer."
fi

# --- An empty log must not silently read as a refusal ----------------------
v="$(verdict_for "")"
if [ "$v" = "CRASHED" ]; then
  ok "an empty log at exit 1 fails closed to CRASHED rather than inventing a refusal"
else
  bad "an empty log produced '$v'"
fi

# ---- EXIT 2 IS THE SAME COLLISION, ONE ARM OVER -----------------------------
#
# repair_merge_consistency returns EXIT_CANNOT_RUN from TWO places: :152, the
# graph could not be READ so the Qdrant sweep NEVER RAN; and after :206, where
# the sweep DID run and the vector store reported 0 points. The difference is
# whether the half that closes people_count_agreement executed at all.
#
# The sweep announces itself: "vector points examined" on the success path and
# "reported 0 points" on the zero path, and neither is reachable without
# calling it. The log answers what the exit code cannot.
awk '/^                2\)$/{on=1} on{print} on && /^                    ;;$/{exit}' \
    install.sh > "$WORK/arm2.sh"
if ! grep -q '_mcr_record 2' "$WORK/arm2.sh"; then
  echo "CANNOT-RUN: could not extract the rc=2 arm from install.sh" >&2; exit 2
fi
sed -e '1d' -e '$d' "$WORK/arm2.sh" > "$WORK/body2.sh"

verdict2_for() {
  printf '%s\n' "$1" > "$WORK/log2.txt"
  bash -c '
    set -uo pipefail
    _MCR_LOG="'"$WORK"'/log2.txt"
    _mcr_record() { printf "%s" "$2"; }
    warn() { :; }
    . "'"$WORK"'/body2.sh"
  '
}

RAN="merge subjects examined : 82
vector points examined  : 2611
  orphans of retired    : 32"
NEVER="CANNOT-RUN: the graph at http://localhost:7878 could not be READ (ConnectError)."
ZERO="CANNOT-RUN: the vector store at http://localhost:6333 reported 0 points."

v="$(verdict2_for "$RAN")"
if [ "$v" = "CANNOT-RUN-VECTOR" ]; then
  ok "a log showing the sweep RAN is recorded as CANNOT-RUN-VECTOR, not as a graph failure"
else
  bad "the sweep demonstrably ran and the verdict was '$v'; the vector half's execution"
  bad "  is being reported as a graph read failure."
fi

v="$(verdict2_for "$NEVER")"
if [ "$v" = "CANNOT-RUN-GRAPH" ]; then
  ok "a log showing the graph was unreadable is recorded as CANNOT-RUN-GRAPH"
else
  bad "a graph-read failure was recorded as '$v'"
fi

if [ "$(verdict2_for "$RAN")" != "$(verdict2_for "$NEVER")" ]; then
  ok "CONTROL: the two exit-2 causes produce DIFFERENT verdicts, so exit 2 is no longer one fact"
else
  bad "CONTROL: both exit-2 inputs produced the same verdict; the arm cannot tell them apart"
fi

v="$(verdict2_for "$ZERO")"
if [ "$v" = "CANNOT-RUN-VECTOR" ]; then
  ok "the zero-points path is recognised as the sweep having RUN"
else
  bad "the zero-points path was recorded as '$v'; that line only prints after the sweep is called"
fi

echo
echo "== $pass pass / $fail fail / $((pass+fail)) total =="
[ "$fail" -eq 0 ] || exit 1
exit 0
