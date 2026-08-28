#!/usr/bin/env bash
# test_orphan_gate_failed_fetch_is_not_truth.sh
#
# #526 was filed as "prune before the gate, or report an upstream-absent ref as
# CANNOT-VERIFY". MEASURED: the gate ALREADY fetches with --prune, on both the
# token and no-token paths. So on the happy path a branch deleted upstream
# loses its tracking ref and cannot be reported at all, and a stale-ref
# cross-check there would solve a problem the fetch has already solved.
#
# THE HAZARD IS THE FAILURE PATH. When the fetch failed, the gate emitted a
# note() -- a WARN, which by construction cannot fail it -- and then read the
# stale cache anyway and reported its contents as findings. Every remote-branch
# verdict is then derived from refs of unknown age: a branch merged and deleted
# upstream still looks unmerged, and one created since is invisible.
#
# A warn bucket is not a safe bucket. A failed fetch is now CANNOT-VERIFY.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$HERE/scripts/verify_no_orphaned_fixes.sh"
[ -r "$GATE" ] || { echo "CANNOT-RUN: no gate at $GATE" >&2; exit 3; }

TMP="$(mktemp -d 2>/dev/null || mktemp -d -t failedfetch)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
has() { [ "$(printf '%s\n' "$2" | grep -cF "$1" || true)" -gt 0 ]; }

# A repo with a REACHABLE origin and one unmerged fix/ branch.
build_ok() {
    local r="$TMP/ok"; rm -rf "$r" "$r.origin"; mkdir -p "$r.origin" "$r"
    git init -q --bare "$r.origin"; git init -q "$r"
    git -C "$r" remote add origin "$r.origin"
    git -C "$r" config user.email a@example.com; git -C "$r" config user.name a
    echo s > "$r/s.txt"; git -C "$r" add -A; git -C "$r" commit -qm s
    git -C "$r" branch -M main; git -C "$r" push -q -u origin main
    git -C "$r" checkout -q -b fix/real-work main
    echo x > "$r/x.txt"; git -C "$r" add -A; git -C "$r" commit -qm w
    git -C "$r" push -q -u origin fix/real-work; git -C "$r" checkout -q main
    printf '%s' "$r"
}
run() {
    local bl="$TMP/bl.$RANDOM"; : > "$bl"
    OSTLER_CUT_DEFERRALS=/nonexistent OSTLER_EXPIRED_BASELINE="$bl" \
    OSTLER_ORPHAN_GATE_SKIP_PR=1 \
    OSTLER_ORPHAN_GATE_REPOS="DEMO|$1|origin/main|" bash "$GATE" 2>&1
}

printf '== test_orphan_gate_failed_fetch_is_not_truth ==\n'
R="$(build_ok)"

# (0) CONTROL. With a reachable origin the gate must WORK and must find the
#     real branch. If it does not, nothing below distinguishes anything.
out="$(run "$R")"
if has "DEMO:fix/real-work" "$out" && ! has "CANNOT VERIFY" "$out"; then
    ok "CONTROL: reachable origin -> the real unmerged branch is reported, no CANNOT VERIFY"
else
    bad "CONTROL BROKEN: a reachable origin did not behave normally"
    printf '%s\n' "$out" | sed 's/^/      /' | head -20
    printf '\n%d passed, %d failed\n' "$pass" "$fail"; exit 1
fi

# Break ONLY the remote. Same refs, same branch, same everything else -- the
# tracking refs are still in the cache and still look like findings.
git -C "$R" remote set-url origin "$TMP/there-is-no-repo-here"

out="$(run "$R")"; rc=$?

# (1) A failed fetch must be CANNOT-VERIFY.
if has "CANNOT VERIFY" "$out" && has "cache of unknown age" "$out"; then
    ok "a failed fetch is CANNOT-VERIFY and says why"
else
    bad "a failed fetch did not report CANNOT-VERIFY"
fi

# (2) It must NOT be a warn. The old behaviour warned and carried on, and a
#     warn cannot fail the gate -- that is the whole defect.
if [ "$rc" -ne 0 ]; then
    ok "it fails the gate (rc=$rc), rather than warning and continuing"
else
    bad "the gate exited 0 on an unreadable remote -- still a warn bucket"
fi

# (3) And it must NOT go on to report branch findings from the stale cache.
#     This is the arm that catches a fix which reports CANNOT-VERIFY and then
#     keeps going anyway.
if has "DEMO:fix/real-work" "$out"; then
    bad "it still reported a branch finding from refs it could not refresh"
else
    ok "no branch verdicts are derived from the unrefreshed cache"
fi

# (4) The declared escape must be named, or the operator is stuck.
has "OSTLER_ORPHAN_GATE_SKIP" "$out" \
    && ok "the message names the declared-blindness escape" \
    || bad "no escape named; the operator is told a fact and no action"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
