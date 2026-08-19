#!/usr/bin/env bash
#
# orphan_gate_selftest.sh -- prove verify_no_orphaned_fixes.sh still FIRES.
#
# =============================================================================
# WHY THIS EXISTS
# =============================================================================
# On 2026-08-11 the orphan gate produced six false REDs and blocked the v1.0.19
# cut. The fix replaced `merge-base --is-ancestor` with PR merge state. That
# fix is a LOOSENING: it teaches the gate to stay quiet in cases where it used
# to shout. A loosened gate that has only ever been observed going quiet is
# indistinguishable from a gate that no longer works.
#
# So the acceptance bar for that change is not "the false positives went away".
# It is BOTH halves:
#
#     the six false REDs go quiet   AND   a genuine orphan still goes RED
#
# This script is the second half, and it is hermetic: `gh` is stubbed, so every
# branch of branch_landed() is exercised without a network call and without
# depending on the live state of any GitHub repo.
#
# Run:  scripts/orphan_gate_selftest.sh
# Exit: 0 = all cases behaved, 1 = at least one case did not
# =============================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="${HERE}/verify_no_orphaned_fixes.sh"
[[ -x "$GATE" || -f "$GATE" ]] || { echo "no gate at $GATE"; exit 2; }

pass=0; fail=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# A stub `gh`. It answers from GH_STUB_MODE, so the test controls exactly what
# GitHub is deemed to have said. A REAL gh here would make this test depend on
# live repo state, which is the thing that made the original defect invisible.
# ---------------------------------------------------------------------------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
# $1 = auth | pr
if [[ "${1:-}" == "auth" ]]; then echo "stub-token"; exit 0; fi
# `pr view <n>` is how a prN MIRROR is resolved -- by number, because the
# mirror's name is not a head ref GitHub has ever heard of. It answers from
# GH_STUB_PR_MODE when set so a case can make `pr view` and `pr list`
# disagree; that is what proves the mirror limb uses the number, not the name.
if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
    case "${GH_STUB_PR_MODE:-${GH_STUB_MODE:-none}}" in
        merged) echo '{"number":'"${3}"',"state":"MERGED","mergedAt":"2026-08-10T00:00:00Z"}' ;;
        open)   echo '{"number":'"${3}"',"state":"OPEN","mergedAt":null}' ;;
        closed) echo '{"number":'"${3}"',"state":"CLOSED","mergedAt":null}' ;;
        none)   echo '{"number":'"${3}"',"state":"CLOSED","mergedAt":null}' ;;
        boom)   echo "HTTP 502: server error" >&2; exit 1 ;;
    esac
    exit 0
fi
if [[ "${1:-}" == "pr" && "${2:-}" == "list" ]]; then
    # The section-1 sweep asks for --state open and a different --json field
    # set (it needs headRefName + isDraft). Only GH_STUB_MODE=open has an open
    # PR to report; every other mode returns nothing to that sweep so the
    # branch checks are what the case is actually measuring.
    for a in "$@"; do
        if [[ "$a" == "open" ]]; then
            if [[ "${GH_STUB_MODE:-none}" == "open" ]]; then
                echo '[{"number":902,"title":"under review","headRefName":"fix/has-an-open-pr","isDraft":false}]'
            else
                echo '[]'
            fi
            exit 0
        fi
    done
    case "${GH_STUB_MODE:-none}" in
        merged) echo '[{"number":901,"state":"MERGED","mergedAt":"2026-08-10T00:00:00Z"}]' ;;
        open)   echo '[{"number":902,"state":"OPEN","mergedAt":null}]' ;;
        closed) echo '[{"number":903,"state":"CLOSED","mergedAt":null}]' ;;
        none)   echo '[]' ;;
        boom)   echo "HTTP 502: server error" >&2; exit 1 ;;
    esac
    exit 0
fi
exit 0
STUB
chmod +x "$TMP/bin/gh"

# ---------------------------------------------------------------------------
# A throwaway repo. `origin` is a second local repo so remote-tracking refs are
# real rather than simulated.
# ---------------------------------------------------------------------------
build_repo() {
    local d="$TMP/$1"; rm -rf "$d" "$d.origin"
    git init -q --bare "$d.origin"
    git init -q -b main "$d"
    git -C "$d" config user.email t@example.invalid
    git -C "$d" config user.name  Test
    git -C "$d" config commit.gpgsign false
    echo one > "$d/f"; git -C "$d" add f; git -C "$d" commit -qm "base"
    git -C "$d" remote add origin "$d.origin"
    git -C "$d" push -q origin main
    printf '%s' "$d"
}

# Assert on the gate's own output. Injected repo set = one repo, so nothing
# on this machine can influence the result.
run_gate() {   # $1 repo dir, $2 gh repo label ("" to disable gh), $3 stub mode
    local d="$1" ghr="$2" mode="$3"
    PATH="$TMP/bin:$PATH" \
    GH_STUB_MODE="$mode" \
    OSTLER_CUT_DEFERRALS="$TMP/empty-deferrals.yaml" \
    OSTLER_ORPHAN_GATE_REPOS="T|${d}|origin/main|${ghr}" \
        bash "$GATE" 2>&1
}

check() {   # $1 name, $2 expect(RED|GREEN), $3 output, $4 rc, $5 must-contain
    local name="$1" expect="$2" out="$3" rc="$4" needle="${5:-}"
    local got="GREEN"; [[ "$rc" -ne 0 ]] && got="RED"
    local why=""
    [[ "$got" == "$expect" ]] || why="expected $expect, got $got (rc=$rc)"
    if [[ -z "$why" && -n "$needle" ]] && ! printf '%s' "$out" | grep -q "$needle"; then
        why="output did not contain '$needle'"
    fi
    if [[ -z "$why" ]]; then
        printf '  [pass] %s\n' "$name"; pass=$((pass + 1))
    else
        printf '  [FAIL] %s -- %s\n' "$name" "$why"; fail=$((fail + 1))
        printf '%s\n' "$out" | sed 's/^/         | /' | head -25
    fi
}

: > "$TMP/empty-deferrals.yaml"

echo "== orphan-gate self-test =="
echo ""
echo "-- the gate must still FIRE (these are the cases it exists for)"

# 1. A genuine orphan: local-only branch, real content, no PR anywhere.
#    This is the #632 class the gate was built for. If this ever goes quiet,
#    the gate is dead.
d="$(build_repo genuine)"
git -C "$d" checkout -qb fix/genuinely-orphaned
echo "a real fix nobody merged" > "$d/fix.txt"
git -C "$d" add fix.txt; git -C "$d" commit -qm "fix: real work, never merged"
git -C "$d" checkout -q main
out="$(run_gate "$d" "acme/thing" none)"; rc=$?
check "local-only branch, no PR at all -> RED" RED "$out" "$rc" "fix/genuinely-orphaned"

# 2. Closed-unmerged PR and NO replacement commit -- abandoned work, still RED.
out="$(run_gate "$d" "acme/thing" closed)"; rc=$?
check "closed-unmerged PR, no replacement -> RED" RED "$out" "$rc" "fix/genuinely-orphaned"

# 3. gh itself fails. An unanswerable question must NEVER read as landed.
out="$(run_gate "$d" "acme/thing" boom)"; rc=$?
check "gh failure -> RED (fails closed)" RED "$out" "$rc" "fix/genuinely-orphaned"

# 4. No gh repo configured at all -- same rule.
out="$(run_gate "$d" "" none)"; rc=$?
check "no gh repo configured -> RED (fails closed)" RED "$out" "$rc" "fix/genuinely-orphaned"

# 5. A remote fix/ branch with commits not on main and no merged PR.
d2="$(build_repo remotebranch)"
git -C "$d2" checkout -qb fix/pushed-but-unmerged
echo "pushed, never merged" > "$d2/p.txt"
git -C "$d2" add p.txt; git -C "$d2" commit -qm "fix: pushed but unmerged"
git -C "$d2" push -q origin fix/pushed-but-unmerged
git -C "$d2" checkout -q main
out="$(run_gate "$d2" "acme/thing" none)"; rc=$?
check "remote fix/ branch, no merged PR -> RED" RED "$out" "$rc" "fix/pushed-but-unmerged"

# 6. Dirty tree.
d3="$(build_repo dirty)"
echo scratch > "$d3/untracked.txt"
out="$(run_gate "$d3" "acme/thing" none)"; rc=$?
check "dirty working tree -> RED" RED "$out" "$rc" "working-tree"

echo ""
echo "-- the gate must go QUIET (these are the 2026-08-11 false positives)"

# 7. THE HEADLINE CASE. Local branch, remote deleted at merge, PR merged.
#    Under the old ancestry predicate this was reported as "LOCAL-ONLY branch,
#    never pushed ... One rm -rf from gone" -- for work that had shipped.
d4="$(build_repo merged)"
git -C "$d4" checkout -qb archie/squash-merged
echo "content that landed via squash" > "$d4/s.txt"
git -C "$d4" add s.txt; git -C "$d4" commit -qm "feat: landed as a squash commit"
git -C "$d4" checkout -q main
# Simulate the squash: same content on main, DIFFERENT commit. Ancestry now
# fails forever, exactly as it does on the real repo.
echo "content that landed via squash" > "$d4/s.txt"
git -C "$d4" add s.txt; git -C "$d4" commit -qm "feat: landed as a squash commit (#901)"
git -C "$d4" push -q origin main
git -C "$d4" fetch -q origin
out="$(run_gate "$d4" "acme/thing" merged)"; rc=$?
check "local branch whose PR was SQUASH-merged -> GREEN" GREEN "$out" "$rc" "landed -- PR #901 merged"

# 7b. The control that makes 7 mean something: identical repo, identical
#     branch, gh says the PR is NOT merged. If this does not go RED then case 7
#     passed because the gate stopped looking, not because it understood.
out="$(run_gate "$d4" "acme/thing" none)"; rc=$?
check "  control: same branch, no merged PR -> RED" RED "$out" "$rc" "archie/squash-merged"

# 8. Replacement merge: PR closed unmerged, main carries "(replaces #903)".
d5="$(build_repo replaced)"
git -C "$d5" checkout -qb fix/superseded
echo "v1" > "$d5/r.txt"; git -C "$d5" add r.txt
git -C "$d5" commit -qm "fix: first attempt"
git -C "$d5" push -q origin fix/superseded
git -C "$d5" checkout -q main
echo "v2" > "$d5/r.txt"; git -C "$d5" add r.txt
git -C "$d5" commit -qm "fix: better second attempt (replaces #903) (#904)"
git -C "$d5" push -q origin main
git -C "$d5" fetch -q origin
out="$(run_gate "$d5" "acme/thing" closed)"; rc=$?
check "closed PR replaced on main -> GREEN" GREEN "$out" "$rc" "replaced on the shipping ref"

# 8b. Control: the replacement text names a DIFFERENT PR number, so it must not
#     match. This is what stops "replaces #9" swallowing #903.
d6="$(build_repo replaced_wrong)"
git -C "$d6" checkout -qb fix/superseded
echo "v1" > "$d6/r.txt"; git -C "$d6" add r.txt
git -C "$d6" commit -qm "fix: first attempt"
git -C "$d6" push -q origin fix/superseded
git -C "$d6" checkout -q main
echo "v2" > "$d6/r.txt"; git -C "$d6" add r.txt
git -C "$d6" commit -qm "fix: unrelated (replaces #9031) (#905)"
git -C "$d6" push -q origin main
git -C "$d6" fetch -q origin
out="$(run_gate "$d6" "acme/thing" closed)"; rc=$?
check "  control: 'replaces #9031' must not satisfy #903 -> RED" RED "$out" "$rc" "fix/superseded"

# 9. An OPEN PR is reported ONCE, by the PR sweep, not twice.
d7="$(build_repo doublereport)"
git -C "$d7" checkout -qb fix/has-an-open-pr
echo "in review" > "$d7/o.txt"; git -C "$d7" add o.txt
git -C "$d7" commit -qm "fix: under review"
git -C "$d7" push -q origin fix/has-an-open-pr
git -C "$d7" checkout -q main
out="$(run_gate "$d7" "acme/thing" open)"; rc=$?
check "open PR: branch row defers to the PR row" RED "$out" "$rc" "reported once, by the PR check"
# The point of case 9 is the COUNT. Before this change the same work was
# reported twice -- once as CM044:fix/v1018-d014a-person-summary-prompt and
# again as CM044:#179 -- which inflated "15 orphaned" and made the RED list
# read worse than the truth. One piece of work, one row.
n_red="$(printf '%s\n' "$out" | grep -c '\[RED\]')"
if [[ "$n_red" == "1" ]] && printf '%s' "$out" | grep -q 'T:#902'; then
    printf '  [pass]   and exactly one RED row, from the PR sweep\n'; pass=$((pass + 1))
else
    printf '  [FAIL]   expected exactly 1 RED row naming #902, got %s\n' "$n_red"; fail=$((fail + 1))
    printf '%s\n' "$out" | grep -E '\[RED\]|\[ok\]' | sed 's/^/         | /'
fi

# 10. A branch that is a genuine ancestor needs no network call and is quiet.
d8="$(build_repo ancestor)"
git -C "$d8" checkout -qb feat/actually-merged
echo "merged properly" > "$d8/m.txt"; git -C "$d8" add m.txt
git -C "$d8" commit -qm "feat: merged with a merge commit"
git -C "$d8" checkout -q main
git -C "$d8" merge -q --no-ff -m "merge" feat/actually-merged
git -C "$d8" push -q origin main
git -C "$d8" fetch -q origin
out="$(run_gate "$d8" "acme/thing" boom)"; rc=$?
check "true ancestor -> GREEN without calling gh" GREEN "$out" "$rc" "ancestors of the shipping ref"

# 11. REMOTE-ONLY branch that IS an ancestor -- no local ref of that name.
#     This case exists because the first draft of the rewrite failed it: the
#     branch NAME was passed where a resolvable REV was needed, merge-base
#     could not resolve "fix/foo", and four merged CM051 branches went RED.
#     `boom` makes gh explode, so this can only pass on the ancestry path.
d9="$(build_repo remoteonly)"
git -C "$d9" checkout -qb feat/remote-only-ancestor
echo "landed long ago" > "$d9/ra.txt"; git -C "$d9" add ra.txt
git -C "$d9" commit -qm "feat: landed long ago"
git -C "$d9" push -q origin feat/remote-only-ancestor
git -C "$d9" checkout -q main
git -C "$d9" merge -q --no-ff -m "merge" feat/remote-only-ancestor
git -C "$d9" push -q origin main
git -C "$d9" branch -q -D feat/remote-only-ancestor   # local ref gone; origin's remains
git -C "$d9" fetch -q origin
out="$(run_gate "$d9" "acme/thing" boom)"; rc=$?
check "remote-only branch that IS an ancestor -> GREEN" GREEN "$out" "$rc" "ancestors of the shipping ref"

echo ""
echo "-- prN mirrors of refs/pull/N (the 2026-08-15 false positives)"

# A helper that runs the gate with `pr view` and `pr list` answering
# SEPARATELY. If the mirror limb were still asking by NAME it would read the
# `pr list` answer, so making the two disagree is what gives these cases teeth.
run_gate_pr() {   # $1 dir, $2 ghrepo, $3 list-mode, $4 view-mode, $5 deferrals
    local d="$1" ghr="$2" mode="$3" vmode="$4" def="${5:-$TMP/empty-deferrals.yaml}"
    PATH="$TMP/bin:$PATH" \
    GH_STUB_MODE="$mode" \
    GH_STUB_PR_MODE="$vmode" \
    OSTLER_CUT_DEFERRALS="$def" \
    OSTLER_ORPHAN_GATE_REPOS="T|${d}|origin/main|${ghr}" \
        bash "$GATE" 2>&1
}

# Build a repo carrying a `pr632` mirror: a local-only branch, named for a PR
# number, whose name is NOT any head ref the remote knows. This is exactly the
# shape `git fetch origin 'refs/pull/*/head:refs/heads/pr*'` leaves behind.
build_mirror_repo() {
    local d; d="$(build_repo "$1")"
    git -C "$d" checkout -qb pr632
    echo "content of PR 632" > "$d/m.txt"
    git -C "$d" add m.txt; git -C "$d" commit -qm "feat: the work in PR 632"
    git -C "$d" checkout -q main
    printf '%s' "$d"
}

# 12. THE HEADLINE CASE. `pr list --head pr632` can never match (mode none),
#     but PR #632 itself is MERGED. Before this change all 105 CM051 mirrors
#     went RED here. It must resolve by NUMBER and go quiet.
d10="$(build_mirror_repo mirror_merged)"
out="$(run_gate_pr "$d10" "acme/thing" none merged)"; rc=$?
check "prN mirror whose PR is MERGED -> GREEN" GREEN "$out" "$rc" "landed -- PR #632 merged"

# 12b. THE CONTROL THAT MAKES 12 MEAN SOMETHING. Same repo, same mirror, but
#      PR #632 is CLOSED-unmerged and nothing on main replaces it. If this
#      does not go RED then case 12 passed because the gate stopped looking at
#      prN branches altogether -- which would be a blanket silence, not a fix.
out="$(run_gate_pr "$d10" "acme/thing" none closed)"; rc=$?
check "  control: same mirror, PR CLOSED-unmerged -> RED" RED "$out" "$rc" "T:#632"

# 12c. The KEY the RED is filed under must be the `#N` form, because that is
#      what cut-deferrals.yaml has always used. Filing it as `T:pr632` is the
#      second half of the 2026-08-15 defect: 67 `#N` deferral rows existed and
#      not one could ever be consulted.
printf 'deferrals:\n  - ref: "T:#632"\n    reason: "deliberately not this cut"\n' \
    > "$TMP/mirror-deferrals.yaml"
out="$(run_gate_pr "$d10" "acme/thing" none closed "$TMP/mirror-deferrals.yaml")"; rc=$?
check "  a 'T:#632' deferral silences the pr632 mirror" GREEN "$out" "$rc" "DEFERRED  T:#632"

# 12d. `prNmerge` is refs/pull/N/merge, GitHub's ephemeral merge preview. Same
#      normalisation, same number.
d11="$(build_repo mirror_merge_variant)"
git -C "$d11" checkout -qb pr632merge
echo "merge preview" > "$d11/mm.txt"
git -C "$d11" add mm.txt; git -C "$d11" commit -qm "merge preview commit"
git -C "$d11" checkout -q main
out="$(run_gate_pr "$d11" "acme/thing" none merged)"; rc=$?
check "prNmerge mirror resolves by the same number -> GREEN" GREEN "$out" "$rc" "landed -- PR #632 merged"

# 12e. A NON-mirror local-only branch must be unaffected: it still resolves by
#      NAME. `pr list` says nothing (none) while `pr view` says merged; if the
#      normalisation leaked onto ordinary branches this would wrongly go green.
d12="$(build_repo not_a_mirror)"
git -C "$d12" checkout -qb fix/printer-queue
echo "not a mirror" > "$d12/n.txt"
git -C "$d12" add n.txt; git -C "$d12" commit -qm "fix: unrelated work"
git -C "$d12" checkout -q main
out="$(run_gate_pr "$d12" "acme/thing" none merged)"; rc=$?
check "  control: 'fix/printer-queue' is not a mirror, still RED" RED "$out" "$rc" "fix/printer-queue"

# 12f. A branch merely CONTAINING 'pr' + digits is not a mirror either. This is
#      what stops the regex eating `fix/pr-review-123` or `archie/pr404-copy`.
d13="$(build_repo near_miss)"
git -C "$d13" checkout -qb archie/pr404-copy
echo "near miss" > "$d13/nm.txt"
git -C "$d13" add nm.txt; git -C "$d13" commit -qm "chore: near miss name"
git -C "$d13" checkout -q main
out="$(run_gate_pr "$d13" "acme/thing" none merged)"; rc=$?
check "  control: 'archie/pr404-copy' is not a mirror, still RED" RED "$out" "$rc" "archie/pr404-copy"

echo ""
echo "== ${pass} passed, ${fail} failed =="
[[ "$fail" -eq 0 ]] || exit 1
exit 0
