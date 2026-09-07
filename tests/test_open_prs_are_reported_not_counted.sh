#!/usr/bin/env bash
#
# test_open_prs_are_reported_not_counted.sh -- an OPEN PR is reported, not counted.
#
# =============================================================================
# WHY THIS EXISTS
# =============================================================================
# On 2026-09-07 the v1.0.74 tag was pushed four times (07:53, 08:02, 08:55,
# 09:10Z) and every cut.yml run died in the same step: `make check-orphans`,
# rc=2, "work exists that is NOT in what you are about to ship". Its RED list
# was eight OPEN PRs and zero orphaned branches. The gate's arm 1 reddened
# every open PR by design, so the only way past it was to merge every open PR
# -- which is how two new gates reached main under the launch directive's
# item 2 freeze, on the same afternoon.
#
# Launch directive item 4 (Andy, 2026-09-07): the cut is made from a frozen
# branch and "open PRs on main do not block it. A second push means the cut
# machinery is the bug." This test pins the fix for that bug, and -- because
# the fix is a LOOSENING -- it pins the half that must not loosen with it.
#
# =============================================================================
# THE FOUR ARMS, AND A MUTANT FOR EACH PROPERTY
# =============================================================================
#   1  SUBJECT     an undeferred open PR  -> GREEN, one [open] row naming it,
#                  zero [RED] rows, and the verdict sentence says so.
#   2  MUST-MISS   the same branch with NO PR -> still RED, naming the branch.
#                  This is the control that proves the loosening did not blind
#                  the gate. Arm 1 alone would pass against a gate that reports
#                  nothing at all.
#   3  DEFERRAL    a deferred open PR -> DEFERRED row, no [open] row, GREEN.
#                  The deferral lookup must keep running, because it is what
#                  records the ref as CONSULTED for the reachability sweep.
#   4  DRAFT       a draft open PR -> the [open] row says DRAFT, GREEN.
#                  Drafts are listed loudest and counted the same: not at all.
#
#   M1  count it again      open_prs++ becomes red++    -> arm 1 must fail
#   M2  skip the deferral   report_open_pr never asks   -> arm 3 must fail
#   M3  blind the branch    maybe_orphan_branch says ok -> arm 2 must fail
#
# Each mutant is proved to have LANDED (exactly one changed line, by diff)
# before its verdict is read. A mutation that did not apply returns the green
# you were hoping for, and that is CANNOT-RUN, not a pass.
#
# Hermetic: `gh` is a stub answering from GH_STUB_OPEN, the repo is a
# throwaway with a real bare origin, and the gate runs with an injected repo
# set, so nothing on this machine or on GitHub can influence the result.
#
# Exit: 0 all arms behaved and every mutant was killed
#       1 an arm failed or a mutant survived
#       2 could not run (no gate, no git, no python3, a mutant did not land)
# =============================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
GATE="$REPO_ROOT/scripts/verify_no_orphaned_fixes.sh"

for need in git python3 diff sed; do
    command -v "$need" >/dev/null 2>&1 || { echo "CANNOT-RUN: $need not on PATH" >&2; exit 2; }
done
[[ -f "$GATE" ]] || { echo "CANNOT-RUN: no gate at $GATE" >&2; exit 2; }

pass=0; fail=0; cannot=0
LAST_OUT=""
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Stub gh. `pr list --state open` answers with GH_STUB_OPEN verbatim, which is
# the list the gate's arm 1 sweeps. `pr list --head <branch> --state all` (how
# the branch arm escalates a non-ancestor) answers OPEN when GH_STUB_OPEN names
# a PR and empty when it does not, so the branch arm and the PR arm see the
# same world.
# ---------------------------------------------------------------------------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "auth" ]]; then echo "stub-token"; exit 0; fi
if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
    echo '{"number":'"${3}"',"state":"OPEN","mergedAt":null}'; exit 0
fi
if [[ "${1:-}" == "pr" && "${2:-}" == "list" ]]; then
    for a in "$@"; do
        if [[ "$a" == "open" ]]; then printf '%s\n' "${GH_STUB_OPEN:-[]}"; exit 0; fi
    done
    if [[ -n "${GH_STUB_OPEN:-}" && "${GH_STUB_OPEN}" != "[]" ]]; then
        echo '[{"number":902,"state":"OPEN","mergedAt":null}]'
    else
        echo '[]'
    fi
    exit 0
fi
exit 0
STUB
chmod +x "$TMP/bin/gh"

OPEN_902='[{"number":902,"title":"under review","headRefName":"fix/has-an-open-pr","isDraft":false}]'
DRAFT_902='[{"number":902,"title":"still a draft","headRefName":"fix/has-an-open-pr","isDraft":true}]'
NO_PR='[]'

EMPTY_DEF="$TMP/empty-deferrals.yaml"; : > "$EMPTY_DEF"
DEF_902="$TMP/deferrals-902.yaml"
cat > "$DEF_902" <<'YAML'
deferrals:
  - ref: "T:#902"
    reason: "held for this test, and the reason is the point"
    until_cut: "v9.9.9"
YAML
: > "$TMP/expired-baseline.txt"

# ---------------------------------------------------------------------------
# One throwaway repo: main, plus a pushed, unmerged fix/ branch. Whether that
# branch has a PR is decided per arm by GH_STUB_OPEN, not by the repo.
# ---------------------------------------------------------------------------
D="$TMP/repo"
git init -q --bare "$D.origin"
git init -q -b main "$D"
git -C "$D" config user.email t@example.invalid
git -C "$D" config user.name  Test
git -C "$D" config commit.gpgsign false
echo one > "$D/f"; git -C "$D" add f; git -C "$D" commit -qm "base"
git -C "$D" remote add origin "$D.origin"
git -C "$D" push -q origin main
git -C "$D" checkout -qb fix/has-an-open-pr
echo "in review" > "$D/o.txt"; git -C "$D" add o.txt
git -C "$D" commit -qm "fix: under review"
git -C "$D" push -q origin fix/has-an-open-pr
git -C "$D" checkout -q main

run_gate() {   # $1 gate path, $2 deferrals file, $3 open-PR json
    PATH="$TMP/bin:$PATH" \
    GH_STUB_OPEN="$3" \
    OSTLER_CUT_DEFERRALS="$2" \
    OSTLER_EXPIRED_BASELINE="$TMP/expired-baseline.txt" \
    OSTLER_ORPHAN_GATE_REPOS="T|${D}|origin/main|acme/thing" \
        bash "$1" 2>&1
}

count() {   # $1 fixed string, $2 text -> how many lines contain it
    printf '%s\n' "$2" | grep -cF -- "$1"
}

# Each arm returns 0 when the gate behaved and 1 when it did not, and leaves
# the gate's output in LAST_OUT so a failure can print it. Written as
# functions so the same predicate runs against the real gate and each mutant.
arm1() {   # subject: undeferred open PR -> GREEN, reported once, not counted
    local out rc
    out="$(run_gate "$1" "$EMPTY_DEF" "$OPEN_902")"; rc=$?; LAST_OUT="$out"
    [[ "$rc" -eq 0 ]] || return 1
    [[ "$(count '[open] T:#902' "$out")" -eq 1 ]] || return 1
    [[ "$(count '[RED]' "$out")" -eq 0 ]] || return 1
    [[ "$(count 'OPEN PRs: 1 reported above, NOT counted' "$out")" -eq 1 ]] || return 1
    [[ "$(count 'reported once, by the PR check' "$out")" -eq 1 ]] || return 1
    return 0
}
arm2() {   # must-miss control: same branch, NO PR -> RED, naming the branch
    local out rc
    out="$(run_gate "$1" "$EMPTY_DEF" "$NO_PR")"; rc=$?; LAST_OUT="$out"
    [[ "$rc" -eq 1 ]] || return 1
    [[ "$(count '[RED]  T:fix/has-an-open-pr' "$out")" -eq 1 ]] || return 1
    [[ "$(count '[open]' "$out")" -eq 0 ]] || return 1
    return 0
}
arm3() {   # deferred open PR -> DEFERRED row, no [open] row, GREEN
    local out rc
    out="$(run_gate "$1" "$DEF_902" "$OPEN_902")"; rc=$?; LAST_OUT="$out"
    [[ "$rc" -eq 0 ]] || return 1
    [[ "$(count 'DEFERRED  T:#902' "$out")" -ge 1 ]] || return 1
    [[ "$(count '[open]' "$out")" -eq 0 ]] || return 1
    [[ "$(count '[RED]' "$out")" -eq 0 ]] || return 1
    return 0
}
arm4() {   # draft open PR -> the [open] row says DRAFT, and it is GREEN
    local out rc
    out="$(run_gate "$1" "$EMPTY_DEF" "$DRAFT_902")"; rc=$?; LAST_OUT="$out"
    [[ "$rc" -eq 0 ]] || return 1
    [[ "$(count '[open] T:#902' "$out")" -eq 1 ]] || return 1
    [[ "$(count 'OPEN **DRAFT** PR' "$out")" -eq 1 ]] || return 1
    [[ "$(count '[RED]' "$out")" -eq 0 ]] || return 1
    return 0
}

report() {   # $1 name, $2 rc of the arm
    if [[ "$2" -eq 0 ]]; then
        printf '  [pass] %s\n' "$1"; pass=$((pass + 1))
    else
        printf '  [FAIL] %s\n' "$1"; fail=$((fail + 1))
        printf '%s\n' "$LAST_OUT" | sed 's/^/         | /' | head -40
    fi
}

echo "== an OPEN PR is reported, not counted (launch directive item 4) =="
echo "-- the real gate: $GATE"
arm1 "$GATE"; report "1 subject: open PR -> GREEN, one [open] row, zero RED, verdict sentence" $?
arm2 "$GATE"; report "2 must-miss: same branch, no PR -> still RED, naming the branch" $?
arm3 "$GATE"; report "3 deferral: deferred open PR -> DEFERRED, no [open] row, GREEN" $?
arm4 "$GATE"; report "4 draft: draft open PR -> [open] row says DRAFT, GREEN" $?

# ---------------------------------------------------------------------------
# Mutants. Each is a copy of the gate with ONE line changed, proved landed by
# diff before the arm runs against it. A mutant the named arm still passes
# against has SURVIVED, and the arm was never load-bearing.
# ---------------------------------------------------------------------------
mutate() {   # $1 name, $2 sed expression -> prints the mutant gate path, rc 2 if it did not land
    local dir="$TMP/mut-$1" changed
    mkdir -p "$dir/scripts" "$dir/tests"
    sed -e "$2" "$GATE" > "$dir/scripts/verify_no_orphaned_fixes.sh"
    changed="$(diff "$GATE" "$dir/scripts/verify_no_orphaned_fixes.sh" | grep -c '^>')"
    if [[ "$changed" -ne 1 ]]; then
        printf '  [CANNOT-RUN] mutant %s did not land: %s changed line(s), wanted 1\n' "$1" "$changed" >&2
        return 2
    fi
    printf '%s' "$dir/scripts/verify_no_orphaned_fixes.sh"
}

kill_check() {   # $1 mutant name, $2 arm fn, $3 mutant gate path
    if "$2" "$3"; then
        printf '  [FAIL] mutant %s SURVIVED: %s still passes against the mutated gate\n' "$1" "$2"
        fail=$((fail + 1))
        printf '%s\n' "$LAST_OUT" | sed 's/^/         | /' | head -40
    else
        printf '  [pass] mutant %s killed by %s\n' "$1" "$2"; pass=$((pass + 1))
    fi
}

# mutate() runs inside a command substitution, so a counter it moved would
# move in a SUBSHELL and the parent would still read zero -- which is exactly
# how this file's own first draft printed two CANNOT-RUN lines and then
# "0 cannot-run" in its summary. The rc crosses the substitution; the counter
# is moved HERE, in the shell that reads it at exit.
run_mutant() {   # $1 mutant name, $2 arm fn, $3 sed expression
    local m mrc
    m="$(mutate "$1" "$3")"; mrc=$?
    if [[ "$mrc" -eq 0 ]]; then
        kill_check "$1" "$2" "$m"
    else
        cannot=$((cannot + 1))
    fi
}

echo "-- mutants, one per property"
# The single quotes are the point: `\$` must reach sed as a literal dollar so
# it matches the gate's `$((...))` text. Double quotes would expand it here.
# shellcheck disable=SC2016
run_mutant M1-count-it-again      arm1 's/open_prs=\$((open_prs + 1))/red=\$((red + 1))/'
# shellcheck disable=SC2016
run_mutant M2-skip-the-deferral   arm3 '/^report_open_pr() {/,/^}/ s/if is_deferred "\$ref"; then/if false; then/'
# shellcheck disable=SC2016
run_mutant M3-blind-the-branch-arm arm2 '/^maybe_orphan_branch() {/,/^}/ s/^    bad "\${ref}"$/    ok "${ref}"/'

echo ""
echo "== ${pass} passed, ${fail} failed, ${cannot} cannot-run =="
[[ "$cannot" -eq 0 ]] || exit 2
[[ "$fail" -eq 0 ]] || exit 1
exit 0
