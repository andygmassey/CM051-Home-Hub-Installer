#!/usr/bin/env bash
# test_orphan_gate_declared_skip_always_counts.sh
#
# A REPO DECLARED IN OSTLER_ORPHAN_GATE_SKIP MUST COUNT AS "NOT CHECKED",
# WHICHEVER OF THE TWO SKIP BRANCHES IT LANDS IN.
#
# check_repo has two places that honour OSTLER_ORPHAN_GATE_SKIP:
#   * the EMPTY-PATH branch      (no checkout path configured at all)
#   * the NOT-A-CHECKOUT branch  (a path is set, git cannot use it)
# The second incremented `unchecked`; the first returned without touching a
# counter. So the same operator act reported two different coverage figures:
#
#     ghost with an EMPTY path        -> "0 NOT CHECKED"
#     ghost with an unresolvable path -> "1 NOT CHECKED"
#
# Everything else about those two runs was identical (0 checked, 0 orphaned,
# 1 warning). The zero is the dangerous one: "0 NOT CHECKED" reads as complete
# coverage, when in fact a repo was declared invisible and nobody looked at it.
# It also fed the --regenerate-expired-baseline refusal, which guards on
# `unchecked -gt 0` -- an all-empty-path run looked like FULL coverage to that
# guard and could have overwritten the baseline from a run that saw nothing.
#
# THE ASSERTION IS ON THE NUMBER, NOT ON A STRING. Grepping for the words
# "NOT CHECKED" would pass on either arm, since both print them; only the
# extracted count separates a false zero from an honest one.
#
# Exit: 0 pass, 1 the invariant is broken, 3 CANNOT-RUN (never a pass).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$HERE/scripts/verify_no_orphaned_fixes.sh"
[ -r "$GATE" ] || { echo "CANNOT-RUN: no gate at $GATE" >&2; exit 3; }

TMP="$(mktemp -d 2>/dev/null || mktemp -d -t orphanskipcount)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

# No gh_repo field, so the open-PR limb never runs and this test needs no
# network and no gh. The repos are deliberately never created: being
# unreachable IS the condition under test.
run() {  # $1 = path field for the ghost, $2 = OSTLER_ORPHAN_GATE_SKIP value
    local bl="$TMP/baseline.$$.$RANDOM"; : > "$bl"
    OSTLER_CUT_DEFERRALS=/nonexistent OSTLER_EXPIRED_BASELINE="$bl" \
    OSTLER_ORPHAN_GATE_SKIP="$2" \
    OSTLER_ORPHAN_GATE_REPOS="ghost|$1|origin/main|" \
        bash "$GATE" 2>&1
}

# `grep -c`, never `| grep -q`: under pipefail a short-circuiting consumer
# SIGPIPEs the producer and the pipeline reports failure ON A MATCH.
has() { [ "$(printf '%s\n' "$2" | grep -cF "$1" || true)" -gt 0 ]; }

# Pull the count out of "== summary: N repo(s) checked, ..., N NOT CHECKED ==".
# Prints nothing if the line is absent, which the callers treat as CANNOT-RUN
# rather than as a zero -- a missing summary and a summary saying zero are not
# the same fact.
notchecked() {
    printf '%s\n' "$1" | sed -n 's/^== summary:.*, \([0-9][0-9]*\) NOT CHECKED ==.*/\1/p' | head -1
}

printf '== test_orphan_gate_declared_skip_always_counts ==\n'

EMPTY_OUT="$(run ""                          "ghost")"
PATH_OUT="$( run "/nonexistent/ghost-checkout" "ghost")"
UNDECL_OUT="$(run ""                         "")"

e="$(notchecked "$EMPTY_OUT")"
p="$(notchecked "$PATH_OUT")"

# (0) CONTROL: the summary line must be parseable on both arms. If it is not,
#     every number below is empty and every comparison would compare "" with
#     "" and PASS. A test whose assertions succeed when the instrument is
#     broken is worth nothing.
if [ -n "$e" ] && [ -n "$p" ]; then
    ok "CONTROL: both arms produced a parseable coverage count (empty=$e, path=$p)"
else
    printf '  CANNOT-RUN: could not read the summary line (empty=%q path=%q).\n' "$e" "$p" >&2
    printf '  Every assertion below would compare two empty strings and pass.\n' >&2
    printf '%s\n' "$EMPTY_OUT" | tail -5 | sed 's/^/      /' >&2
    exit 3
fi

# (1) CONTROL, THE OTHER DIRECTION: an UNDECLARED unreachable repo must still
#     FAIL CLOSED as a RED, not become a silent skip. Without this arm the
#     invariant below could be satisfied by making everything count as skipped,
#     which would gut the gate rather than fix it.
if has "ghost: no checkout path configured" "$UNDECL_OUT" \
   && [ "$(notchecked "$UNDECL_OUT")" = "0" ]; then
    ok "CONTROL: an UNDECLARED unreachable repo is still RED, not a skip"
else
    bad "an undeclared unreachable repo stopped failing closed -- the skip widened"
fi

# (2) THE BUG ITSELF. Declared + empty path must be counted. This arm read 0
#     before the fix.
[ "$e" = "1" ] \
    && ok "declared skip with an EMPTY path counts as 1 NOT CHECKED" \
    || bad "declared skip with an EMPTY path reported ${e} NOT CHECKED, expected 1 (false zero)"

# (3) The sibling branch, pinned so the fix cannot be made by breaking it.
[ "$p" = "1" ] \
    && ok "declared skip with an UNRESOLVABLE path counts as 1 NOT CHECKED" \
    || bad "declared skip with an unresolvable path reported ${p} NOT CHECKED, expected 1"

# (4) THE INVARIANT. One operator act, one coverage figure, however it is
#     spelled. This is the assertion the ticket is actually about: (2) and (3)
#     could each be satisfied by a constant, but they cannot disagree.
[ "$e" = "$p" ] \
    && ok "both spellings of the same declaration report the SAME count ($e)" \
    || bad "same declaration, two coverage figures: empty=${e} vs path=${p}"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
