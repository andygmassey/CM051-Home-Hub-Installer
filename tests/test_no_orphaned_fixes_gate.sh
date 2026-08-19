#!/usr/bin/env bash
#
# test_no_orphaned_fixes_gate.sh
#
# Proves the orphaned-fix gate can actually FAIL. A gate that cannot go red is
# decoration -- and this repo has shipped four of those (the June
# zeroclaw-desktop -> ostler-hub rename left four gates silently SKIPping, one
# of which returned PASS for a target that no longer existed).
#
# Every case here is a real shape from the v1.0.15 walk, 2026-08-06:
#   (a) unmerged remote fix/ branch      -- CM044 7f1dc59, CM051 browsing
#   (b) LOCAL-ONLY branch, never pushed  -- CM051 #632, worktree, parent deleted
#   (c) dirty working tree               -- uncommitted work at cut time
#   (d) a recorded deferral is accepted  -- the escape hatch must work, or
#                                           people will bypass the gate instead
#   (e) clean repo passes                -- no false positives
#
# PR checks need network + gh auth and are exercised on the real repos, not here.
#
# Usage: bash tests/test_no_orphaned_fixes_gate.sh

set -uo pipefail

GATE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/verify_no_orphaned_fixes.sh"
pass=0; fail=0
ok()  { printf '  [PASS] %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; fail=$((fail+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A repo with an origin, so "local-only" is meaningful.
make_repo() {
    local name="$1"
    local up="$TMP/${name}-origin" wt="$TMP/${name}"
    git init -q --bare "$up"
    git init -q "$wt" && git -C "$wt" remote add origin "$up"
    git -C "$wt" config user.email t@t.t; git -C "$wt" config user.name t
    echo base > "$wt/f.txt"
    git -C "$wt" add -A && git -C "$wt" commit -qm base
    git -C "$wt" branch -M main && git -C "$wt" push -q -u origin main
    printf '%s' "$wt"
}

run_gate() {  # $1 = checkout, $2 = deferrals file ("" for none)
    # Inject ONLY the fixture repo and skip PR lookups, so the test is
    # hermetic: no network, no gh auth, no dependence on the real repos.
    # (The first draft did not do this and hung for 10 minutes doing live
    # `git fetch` + `gh pr list` against every real repo. A test that needs
    # the network is a test nobody runs.)
    OSTLER_CUT_DEFERRALS="${2:-/nonexistent}" \
    OSTLER_ORPHAN_GATE_SKIP_PR=1 \
    OSTLER_ORPHAN_GATE_REPOS="CM044|$1|origin/main|" \
        bash "$GATE" 2>&1
}

printf '== test_no_orphaned_fixes_gate ==\n'

# (a) unmerged remote fix/ branch -> RED
R="$(make_repo unmerged)"
git -C "$R" checkout -q -b fix/thing && echo x > "$R/x.txt"
git -C "$R" add -A && git -C "$R" commit -qm "fix: a real fix nobody merged"
git -C "$R" push -q -u origin fix/thing && git -C "$R" checkout -q main
out="$(run_gate "$R")"; rc=$?
if [[ $rc -ne 0 ]] && printf '%s' "$out" | grep -q "fix/thing"; then
    ok "unmerged remote fix/ branch goes RED"
else
    bad "unmerged remote fix/ branch did NOT go red (rc=$rc)"
fi

# (b) LOCAL-ONLY branch -> RED  (the #632 class)
R="$(make_repo localonly)"
git -C "$R" checkout -q -b fix/never-pushed && echo y > "$R/y.txt"
git -C "$R" add -A && git -C "$R" commit -qm "fix: lives on one machine only"
git -C "$R" checkout -q main
out="$(run_gate "$R")"; rc=$?
if [[ $rc -ne 0 ]] && printf '%s' "$out" | grep -q "LOCAL-ONLY"; then
    ok "local-only branch goes RED and is named as LOCAL-ONLY"
else
    bad "local-only branch did NOT go red (rc=$rc) -- this is the #632 shape"
fi

# (c) dirty tree -> RED
R="$(make_repo dirty)"; echo scratch > "$R/uncommitted.txt"
out="$(run_gate "$R")"; rc=$?
if [[ $rc -ne 0 ]] && printf '%s' "$out" | grep -q "working-tree"; then
    ok "dirty working tree goes RED"
else
    bad "dirty working tree did NOT go red (rc=$rc)"
fi

# (d) a recorded deferral is accepted, and still printed
R="$(make_repo deferred)"
git -C "$R" checkout -q -b fix/later && echo z > "$R/z.txt"
git -C "$R" add -A && git -C "$R" commit -qm "fix: deliberately next cut"
git -C "$R" push -q -u origin fix/later && git -C "$R" checkout -q main
DEF="$TMP/deferrals.yaml"
cat > "$DEF" <<'YAML'
deferrals:
  - ref: "CM044:fix/later"
    reason: "lands in v1.0.17, needs a design pass first"
    until_cut: "v1.0.17"
YAML
out="$(run_gate "$R" "$DEF")"; rc=$?
if [[ $rc -eq 0 ]] && printf '%s' "$out" | grep -q "DEFERRED"; then
    ok "recorded deferral passes AND is still printed"
else
    bad "recorded deferral did not pass cleanly (rc=$rc)"
fi

# (e) clean repo -> GREEN (no false positives)
R="$(make_repo clean)"
out="$(run_gate "$R")"; rc=$?
if [[ $rc -eq 0 ]]; then
    ok "clean repo passes (no false positive)"
else
    bad "clean repo wrongly went red (rc=$rc)"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
