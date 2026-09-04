#!/usr/bin/env bash
# A COMPLETION TALLY THAT CONTRADICTS THE LOG IS NOT A PASS.
#
# WHY THIS EXISTS. CONFIRMED 2026-09-04 21:10Z by instrumenting the real
# shipped test: `set -E` propagates the ERR trap INTO a command substitution's
# subshell. That subshell emits a TERMINAL marker and increments its own copy
# of __OSTLER_FAILED_STEPS, then dies -- and the counter dies with it:
#
#     pid=55691  subshell=1   DONE status=fail  failed_steps=1
#     pid=55691  subshell=0   DONE status=ok    failed_steps=0
#
# Same pid, different $BASH_SUBSHELL.
#
# THE VARIABLE DIES WITH THE SUBSHELL. THE LOG LINE DOES NOT. A STEP_END
# written from inside that subshell is already on the marker wire and stays
# there. So a run can end carrying BOTH a `status=error` step in its log AND
# `failed_steps=0` in the marker this driver grades -- and adjudicate() graded
# the tally alone and returned PASS.
#
# This is the #839 collapse arriving from a direction the earlier fix did not
# cover. Run 3 (2026-09-03) was a driver reading too FEW FIELDS. This is a
# field that was CORRECT WHEN WRITTEN and then LOST. Both end as a green walk
# over a step the product itself recorded as failed.
#
# THE DISCRIMINATOR IS RETRY vs LOST COUNTER, and this driver cannot always
# tell them apart -- so it does not pretend to:
#     every errored step later closed ok .... CANNOT-RUN (looks like a retry)
#     any errored step never closed ok ...... FAIL       (a measured failure)
#     tally 0 and no errored steps .......... PASS       (the only PASS)
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DRIVER="${REPO}/scripts/walk_drive.py"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

[ -f "$DRIVER" ] || { echo "CANNOT-RUN: no walk_drive.py at ${DRIVER}" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "CANNOT-RUN: no python3" >&2; exit 2; }
WORK="$(mktemp -d)" || { echo "CANNOT-RUN: no working directory" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# Echoes "<code> <headline>". HOME is read at import time, so each case gets
# its own home.
_adjudicate() {
    local body="$1" h; h="$(mktemp -d "${WORK}/home.XXXXXX")"
    printf '%b\n' "$body" > "${h}/pty.log"
    HOME="$h" python3 - "$DRIVER" "${h}/pty.log" <<'PY' 2>/dev/null
import sys, importlib.util
spec = importlib.util.spec_from_file_location("wd", sys.argv[1])
wd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wd)
code, headline, _d = wd.adjudicate(sys.argv[2], 0, True)
print("%d %s" % (code, headline))
PY
}

DONE_OK='#OSTLER\tDONE\tstatus=ok\tfailed_steps=0\terrors=0'
ERR_STEP='#OSTLER\tSTEP_END\tid=hydrate_graph\tstatus=error\telapsed_s=3'
OK_STEP='#OSTLER\tSTEP_END\tid=hydrate_graph\tstatus=ok\telapsed_s=9'

echo "── the control first: a genuinely clean run must still PASS ──"
r="$(_adjudicate "#OSTLER\tSTEP_END\tid=homebrew\tstatus=ok\n${DONE_OK}")"
case "$r" in
    0\ *) ok "a clean run still PASSes -- the reconciliation does not block good walks" ;;
    "")   echo "CANNOT-RUN: adjudicate() produced no output; the driver could not be imported." >&2; exit 2 ;;
    *)    bad "a CLEAN run returned '${r}'. The fix has broken the only path to PASS, which is worse than the defect." ;;
esac

echo "── the measured defect ──"
r="$(_adjudicate "${ERR_STEP}\n${DONE_OK}")"
case "$r" in
    1\ *) ok "tally=0 with an errored step that never closed ok is FAIL" ;;
    0\ *) bad "PASSED a run whose log records status=error while the marker says failed_steps=0. This is the subshell-lost-counter case and it is exactly what the walk exists to catch." ;;
    *)    bad "expected FAIL, got '${r}'" ;;
esac

echo "── retry is not the same finding, and must not be dressed as one ──"
r="$(_adjudicate "${ERR_STEP}\n${OK_STEP}\n${DONE_OK}")"
case "$r" in
    2\ *) ok "an errored step that LATER closed ok is CANNOT-RUN, not FAIL" ;;
    1\ *) bad "called a retry a product FAILURE. A harness that cannot tell a retry from a lost counter must say so, not accuse." ;;
    0\ *) bad "PASSED a run containing status=error on the strength of a later ok" ;;
    *)    bad "expected CANNOT-RUN, got '${r}'" ;;
esac

echo "── the pre-existing behaviour must be untouched ──"
r="$(_adjudicate "${ERR_STEP}\n#OSTLER\tDONE\tstatus=ok\tfailed_steps=1\terrors=0")"
case "$r" in
    1\ *) ok "a NON-ZERO tally is still FAIL, by the older path (#839, run 3)" ;;
    *)    bad "the #839 path regressed: got '${r}'" ;;
esac

r="$(_adjudicate "#OSTLER\tDONE\tstatus=ok")"
case "$r" in
    2\ *) ok "a marker with NO tally is still CANNOT-RUN -- an absent field is not a zero" ;;
    *)    bad "the missing-tally path regressed: got '${r}'" ;;
esac

echo "── two errored steps, one retried: the honest half still fails ──"
r="$(_adjudicate "${ERR_STEP}\n${OK_STEP}\n#OSTLER\tSTEP_END\tid=initial_hydrate\tstatus=error\n${DONE_OK}")"
case "$r" in
    1\ *) ok "a mix of retried and never-closed errored steps is FAIL, not CANNOT-RUN" ;;
    2\ *) bad "let a never-closed failure hide behind a sibling that retried" ;;
    *)    bad "expected FAIL, got '${r}'" ;;
esac

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
