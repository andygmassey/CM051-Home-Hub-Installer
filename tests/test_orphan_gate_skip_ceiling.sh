#!/usr/bin/env bash
# ============================================================================
# THE ORPHAN-GATE SKIP SET HAS A CEILING, AND IT IS LOAD-BEARING (task #611)
#
# scripts/verify_no_orphaned_fixes.sh honours OSTLER_ORPHAN_GATE_SKIP, and the
# cut path declares five labels (CM044,CM041,CM059,CM031,daemon), leaving CM051
# as the only repo examined. NOTHING pinned that set: a sixth label could be
# added and the gate still exit 0, walking coverage down to a floor of one repo,
# every step green, because only `checked == 0` fails closed (exit 3).
#
# The fix is a committed ceiling LIST (tests/orphan_gate_skip_ceiling.txt) that
# bounds the ACTUAL skips (unchecked_labels, the repos genuinely NOT CHECKED --
# both skip branches populate it, #1365) as a MAXIMUM. This test drives the REAL
# gate hermetically, via OSTLER_ORPHAN_GATE_REPOS (its own injection point), so
# it exercises the gate's exit, not a copy of the logic.
#
# THE ACCEPTANCE CRITERIA, as stated in the #611 dispatch:
#   RED   a skip NOT on the ceiling -> gate exits non-zero AND names the label
#   GREEN skipping FEWER than the ceiling -> exit 0 (an equality check would fail
#         this arm; a ceiling must not)
#   LOAD-BEARING revert the comparison in a COPY of the gate and the RED case
#         stops firing -- proving the RED assertion depends on the real check,
#         not on something incidental (the #1365 lesson: a test that passes
#         against a broken gate proves nothing).
#
# Exit: 0 all hold | 1 a criterion failed | 2 CANNOT RUN
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="${HERE}/../scripts/verify_no_orphaned_fixes.sh"
[[ -r "$GATE" ]] || { echo "CANNOT RUN: gate not readable at ${GATE}" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "CANNOT RUN: git absent" >&2; exit 2; }

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }
finish(){ printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ] || exit 1; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/orphan-ceiling-XXXXXX")" || { echo "CANNOT RUN: mktemp" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT

# ---- a clean resolved repo: only main, no orphan branch, so the gate finds
#      nothing wrong and reaches the unchecked>0 verdict where the ceiling lives.
RESOLVED="$TMP/resolved"
git init -q --bare "$RESOLVED.origin"
git init -q -b main "$RESOLVED"
git -C "$RESOLVED" config user.email t@example.invalid
git -C "$RESOLVED" config user.name Test
git -C "$RESOLVED" config commit.gpgsign false
echo base > "$RESOLVED/f"; git -C "$RESOLVED" add f; git -C "$RESOLVED" commit -qm base
git -C "$RESOLVED" remote add origin "$RESOLVED.origin"; git -C "$RESOLVED" push -q origin main
: > "$TMP/empty-deferrals.yaml"
: > "$TMP/empty-expired-baseline.txt"

# run_gate <gate> <repos> <skip-csv> <ceiling-file>  -> stdout is output; sets RC
run_gate() {
    local gate="$1" repos="$2" skip="$3" ceiling="$4"
    OSTLER_ORPHAN_GATE_REPOS="$repos" \
    OSTLER_ORPHAN_GATE_SKIP="$skip" \
    OSTLER_ORPHAN_SKIP_CEILING="$ceiling" \
    OSTLER_CUT_DEFERRALS="$TMP/empty-deferrals.yaml" \
    OSTLER_EXPIRED_BASELINE="$TMP/empty-expired-baseline.txt" \
        bash "$gate" 2>&1
}

# empty ghlabel (4th field) disables PR checks -> no network, no gh stub needed.
REPOS_RED="RESOLVED|${RESOLVED}|origin/main|;SKIPA||origin/main|;SKIPB||origin/main|"
REPOS_GREEN="RESOLVED|${RESOLVED}|origin/main|;SKIPA||origin/main|"

# ── PREMISE: the resolved-only run with no skips is GREEN, so the harness can
#    reach a clean verdict at all (a broken harness that always reds would make
#    every arm below vacuous). ────────────────────────────────────────────────
printf 'SKIPA\nSKIPB\n' > "$TMP/ceiling_full.txt"
out="$(run_gate "$GATE" "RESOLVED|${RESOLVED}|origin/main|" "" "$TMP/ceiling_full.txt")"; RC=$?
if [ "$RC" -eq 0 ]; then
    ok "premise: a resolved repo with no skips is GREEN (harness reaches a clean verdict, rc=0)"
else
    bad "PREMISE BROKEN: the harness cannot even produce a clean GREEN (rc=$RC). Every arm below would be meaningless."
    printf '%s\n' "$out" | sed 's/^/    | /' | head -20
    finish
fi

# ── RED ARM: a skip the ceiling does not name -> non-zero AND names it. ──────
printf 'SKIPA\n' > "$TMP/ceiling_only_a.txt"
out="$(run_gate "$GATE" "$REPOS_RED" "SKIPA,SKIPB" "$TMP/ceiling_only_a.txt")"; RC=$?
if [ "$RC" -ne 0 ]; then
    ok "RED: a skip (SKIPB) not on the ceiling makes the gate exit non-zero (rc=$RC)"
else
    bad "RED ARM FAILED: SKIPB is skipped and NOT on the ceiling, yet the gate exited 0. The ceiling does not bound the skip set."
fi
if grep -q 'SKIPB' <<< "$out"; then
    ok "RED: the over-ceiling label SKIPB is NAMED in the failure"
else
    bad "RED ARM: the gate failed but did not NAME SKIPB -- a ceiling failure that does not say which label is not actionable."
    printf '%s\n' "$out" | grep -i ceiling | sed 's/^/    | /' | head
fi

# ── GREEN ARM: skipping FEWER than the ceiling stays exit 0. ─────────────────
# ceiling permits {SKIPA, SKIPB}; only SKIPA is actually skipped. An EQUALITY
# check would red this (skipped != ceiling); a ceiling must not.
out="$(run_gate "$GATE" "$REPOS_GREEN" "SKIPA" "$TMP/ceiling_full.txt")"; RC=$?
if [ "$RC" -eq 0 ]; then
    ok "GREEN: skipping FEWER (SKIPA) than the ceiling ({SKIPA,SKIPB}) stays exit 0"
else
    bad "GREEN ARM FAILED (rc=$RC): skipping fewer than the ceiling reddened. This is an EQUALITY check masquerading as a ceiling."
    printf '%s\n' "$out" | sed 's/^/    | /' | head -20
fi

# ── LOAD-BEARING: revert the comparison in a COPY and the RED case stops firing.
# Neuter the ceiling branch so it can never fire, then re-run the RED input. If
# the gate STILL reds, the RED arm was measuring something other than the check.
MUT="$TMP/gate_mutant.sh"
# turn `if [[ -n "$_skip_over" ]]; then` into an always-false guard.
sed 's/if \[\[ -n "\$_skip_over" \]\]; then/if [[ -n "" ]]; then/' "$GATE" > "$MUT"
if ! grep -q 'if \[\[ -n "" \]\]; then' "$MUT"; then
    bad "MUTATION SETUP FAILED: could not neuter the ceiling comparison in the copy (the anchor moved). Cannot prove load-bearing."
else
    out="$(run_gate "$MUT" "$REPOS_RED" "SKIPA,SKIPB" "$TMP/ceiling_only_a.txt")"; RC=$?
    if [ "$RC" -eq 0 ]; then
        ok "LOAD-BEARING: with the ceiling comparison reverted, the RED input NO LONGER reds (rc=0) -- so the RED arm depends on the real check, not on something incidental"
    else
        bad "NOT LOAD-BEARING: the mutant with the comparison neutered STILL reddened (rc=$RC) on the RED input. The RED arm is passing for the wrong reason."
        printf '%s\n' "$out" | grep -i 'ceiling\|SKIPB' | sed 's/^/    | /' | head
    fi
fi

finish
