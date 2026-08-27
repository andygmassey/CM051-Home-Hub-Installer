#!/usr/bin/env bash
# test_orphan_gate_pr_skip_is_per_label.sh
#
# OSTLER_ORPHAN_GATE_SKIP_PR used to be a global boolean while its sibling on
# the checkout axis, OSTLER_ORPHAN_GATE_SKIP, took a comma list of labels. So
# "skip the daemon" was expressible on one axis and not the other, and the only
# way to clear the daemon's cross-org CANNOT VERIFY was to silence the open-PR
# limb for EVERY repo -- including the one being cut FROM. #1166.
#
# This test pins the per-label grammar, and pins it IN BOTH DIRECTIONS: naming
# one label must skip that label AND LEAVE THE OTHERS RUNNING. A test that only
# asserted "the named one is skipped" would still pass if the flag silenced
# everything, which is the exact bug.
#
# HOW A "THE LIMB RAN" ASSERTION IS MADE WITHOUT A NETWORK
# Each fixture repo is given a gh_repo that cannot exist. If the limb runs, the
# listing FAILS and the gate prints "CANNOT VERIFY -- listing open PRs". If the
# limb is skipped, it prints "PR check SKIPPED". Those two strings are the
# discriminator, and neither can be produced by the other path.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$HERE/scripts/verify_no_orphaned_fixes.sh"
[ -r "$GATE" ] || { echo "CANNOT-RUN: no gate at $GATE" >&2; exit 3; }
command -v gh >/dev/null 2>&1 || { echo "CANNOT-RUN: gh absent, the open-PR limb cannot be exercised at all -- this is not a pass" >&2; exit 3; }

TMP="$(mktemp -d 2>/dev/null || mktemp -d -t orphanprskip)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

make_repo() {   # $1 = name -> prints path
    local r="$TMP/$1"
    mkdir -p "$r.origin" "$r"
    git init -q --bare "$r.origin"
    git init -q "$r" && git -C "$r" remote add origin "$r.origin"
    git -C "$r" config user.email a@example.com
    git -C "$r" config user.name  a
    echo seed > "$r/seed.txt"
    git -C "$r" add -A && git -C "$r" commit -qm seed
    git -C "$r" branch -M main && git -C "$r" push -q -u origin main
    printf '%s' "$r"
}

A="$(make_repo aaa)"; B="$(make_repo bbb)"
# Two labels, each with a gh_repo that cannot resolve, so the limb is observable.
REPOS="AAA|$A|origin/main|andygmassey/zzz-no-such-repo-aaa;BBB|$B|origin/main|andygmassey/zzz-no-such-repo-bbb"

run() {  # $1 = value for OSTLER_ORPHAN_GATE_SKIP_PR ("" = unset)
    local bl="$TMP/baseline.$$.$RANDOM"; : > "$bl"
    if [ -z "$1" ]; then
        OSTLER_CUT_DEFERRALS=/nonexistent OSTLER_EXPIRED_BASELINE="$bl" \
        OSTLER_ORPHAN_GATE_REPOS="$REPOS" bash "$GATE" 2>&1
    else
        OSTLER_CUT_DEFERRALS=/nonexistent OSTLER_EXPIRED_BASELINE="$bl" \
        OSTLER_ORPHAN_GATE_SKIP_PR="$1" \
        OSTLER_ORPHAN_GATE_REPOS="$REPOS" bash "$GATE" 2>&1
    fi
}
# `grep -c`, never `| grep -q`: under pipefail a short-circuiting consumer
# SIGPIPEs the producer and the pipeline reports failure ON A MATCH.
has() { [ "$(printf '%s\n' "$2" | grep -cF "$1" || true)" -gt 0 ]; }

printf '== test_orphan_gate_pr_skip_is_per_label ==\n'

# (0) CONTROL: with nothing set, BOTH limbs must run. If this arm does not
#     produce two CANNOT VERIFYs the fixtures are wrong and every verdict
#     below is meaningless.
out="$(run "")"
if has "AAA: CANNOT VERIFY" "$out" && has "BBB: CANNOT VERIFY" "$out"; then
    ok "CONTROL: unset -> both open-PR limbs RUN"
else
    bad "CONTROL BROKEN: unset did not run both limbs -- nothing below is readable"
    printf '%s\n' "$out" | sed 's/^/      /' | head -20
    printf '\n%d passed, %d failed\n' "$pass" "$fail"; exit 1
fi

# (1) THE POINT OF THE TICKET: naming one label skips ONLY that label.
out="$(run "AAA")"
has "AAA: PR check SKIPPED" "$out" \
    && ok "naming AAA skips AAA" \
    || bad "naming AAA did not skip AAA"
has "BBB: CANNOT VERIFY" "$out" \
    && ok "naming AAA leaves BBB's limb RUNNING (the bug this pins)" \
    || bad "naming AAA also silenced BBB -- the flag is still global"

# (2) The other direction, so the match is on the label and not on position.
out="$(run "BBB")"
has "BBB: PR check SKIPPED" "$out" \
    && ok "naming BBB skips BBB" \
    || bad "naming BBB did not skip BBB"
has "AAA: CANNOT VERIFY" "$out" \
    && ok "naming BBB leaves AAA's limb RUNNING" \
    || bad "naming BBB also silenced AAA"

# (3) A comma list names several.
out="$(run "AAA,BBB")"
if has "AAA: PR check SKIPPED" "$out" && has "BBB: PR check SKIPPED" "$out"; then
    ok "a comma list skips every label it names"
else
    bad "a comma list did not skip both named labels"
fi

# (4) A label that matches NOTHING must not silence anything. This is the arm
#     that catches a substring match, e.g. a naive *"$label"* test.
out="$(run "CCC")"
if has "AAA: CANNOT VERIFY" "$out" && has "BBB: CANNOT VERIFY" "$out"; then
    ok "an unmatched label silences nothing"
else
    bad "an unmatched label silenced a limb -- the match is too loose"
fi

# (5) The legacy blanket still works, AND now says so. It stays supported
#     because tests and habits depend on it; what changed is that it names
#     what it silenced instead of doing it quietly.
out="$(run "1")"
if has "AAA: PR check SKIPPED" "$out" && has "BBB: PR check SKIPPED" "$out"; then
    ok "legacy blanket =1 still skips every repo"
else
    bad "legacy blanket =1 stopped working -- that breaks callers that rely on it"
fi
has "BLANKET" "$out" \
    && ok "the blanket ANNOUNCES itself rather than silencing quietly" \
    || bad "the blanket is silent -- an operator cannot see what they blinded"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
