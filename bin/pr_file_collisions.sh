#!/usr/bin/env bash
# bin/pr_file_collisions.sh
# ============================================================================
# QUESTION: before I start, is anyone else already editing the files I am about
#           to edit -- and does my branch still merge?
#
# WHY IT EXISTS. On 2026-08-26 two agents independently fixed the SAME
# exit-code polarity on the SAME two probes (#1121 and 9dc12bb3), and
# independently repointed people_count_agreement (#1109 and 98404ea4). Both
# collisions were resolved by hand, after the fact, by the person who noticed
# second. Nothing warned either of us, because nothing was looking.
#
# It also reports STALE CONFLICTS: a branch that merged cleanly when you opened
# it and does not any more, because something landed underneath. Three of mine
# were in that state and I did not know until I checked.
#
# WHAT IT DOES NOT DO. It compares FILE PATHS. Two PRs touching one file may be
# perfectly compatible (two rows appended to a manifest), and two PRs touching
# DIFFERENT files can still conflict semantically -- a rename here and a call
# site there. This narrows where to look. It does not decide anything.
#
# Usage:
#   bin/pr_file_collisions.sh                  # every open PR in this repo
#   bin/pr_file_collisions.sh --pr 1117        # just what #1117 collides with
#   bin/pr_file_collisions.sh --mine           # PRs authored by the gh user
#   bin/pr_file_collisions.sh --self-test      # prove it can report a collision
# ============================================================================
set -uo pipefail

REPO="${OSTLER_COLLISION_REPO:-}"
ONLY_PR=""; MINE=0; SELFTEST=0; LIMIT="${OSTLER_COLLISION_LIMIT:-100}"
while [ $# -gt 0 ]; do
    case "$1" in
        --pr)        ONLY_PR="${2:-}"; shift 2 ;;
        --mine)      MINE=1; shift ;;
        --self-test) SELFTEST=1; shift ;;
        --repo)      REPO="${2:-}"; shift 2 ;;
        -h|--help)   sed -n '2,30p' "$0"; exit 0 ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

# ---------------------------------------------------------------------------
# The collision core, kept separate from every network call so --self-test can
# drive it with a fixture. A checker that has never been shown a collision has
# not earned the right to report "none".
# args: a TSV stream of <file>\t<pr>\t<author> on stdin
# ---------------------------------------------------------------------------
collisions_from_tsv() {
    # `python3 - <<'PY'` would make the HEREDOC python's stdin, so the piped
    # TSV would never arrive and every run would report COLLISIONS: none.
    # The self-test caught exactly that. Stage the script to a file so stdin
    # stays free for the data.
    # `mktemp -t NAME` is BSD-ONLY. GNU mktemp (ubuntu-latest, which is where
    # this workflow runs) rejects it with "too few X's in template", $_cft_py is
    # then EMPTY, `python3 ""` runs the repo directory, and all four self-test
    # arms fail with a __main__ error that names nothing real. One bad mktemp
    # becomes four arm failures and a false cause with a confident face.
    #
    # This exact trap is already documented in this repo at
    # scripts/verify_no_orphaned_fixes.sh:93 -- that gate hit it with
    # `mktemp -t ostler-expired-refs`. It was on this branch while I wrote the
    # bug. Third "measure on the host that runs it" of the night.
    #
    # The GUARD matters as much as the template: without it an mktemp failure
    # is silent and reappears downstream as something else.
    _cft_py="$(mktemp "${TMPDIR:-/tmp}/collisions_py.XXXXXX")"
    [ -n "$_cft_py" ] || { echo "CANNOT-RUN: mktemp failed"; return 78; }
    cat > "$_cft_py" <<'PY'
import sys, collections
rows = [l.rstrip("\n").split("\t") for l in sys.stdin if l.strip()]
by_file = collections.defaultdict(list)
for r in rows:
    if len(r) >= 3:
        by_file[r[0]].append((r[1], r[2]))
prs   = {r[1] for r in rows if len(r) >= 3}
multi = {f: v for f, v in by_file.items() if len({p for p, _ in v}) > 1}
# DENOMINATOR FIRST, always, including when it is zero -- "found nothing" and
# "looked at nothing" print identically otherwise.
print("EXAMINED: %d pull request(s), %d distinct file(s), %d (pr,file) pair(s)"
      % (len(prs), len(by_file), len(rows)))
if not multi:
    print("COLLISIONS: none")
    sys.exit(0)
print("COLLISIONS: %d file(s) touched by more than one open PR" % len(multi))
for f in sorted(multi, key=lambda k: (-len(multi[k]), k)):
    who = " ".join("#%s(%s)" % (p, a) for p, a in sorted(set(multi[f])))
    print("  %s" % f)
    print("      %s" % who)
PY
    python3 "$_cft_py"
    _cft_rc=$?
    rm -f "$_cft_py"
    return $_cft_rc
}

if [ "$SELFTEST" -eq 1 ]; then
    printf 'VERDICT-SELFTEST\n'
    out="$(printf 'a.sh\t1\tale\na.sh\t2\tbob\nb.sh\t1\tale\n' | collisions_from_tsv)"
    printf '%s\n' "$out" | sed 's/^/  /'
    fails=0
    case "$out" in *"COLLISIONS: 1 file"*) ;; *) echo "  SELF-TEST FAIL: did not report the planted collision"; fails=1 ;; esac
    case "$out" in *"a.sh"*) ;; *) echo "  SELF-TEST FAIL: did not name the colliding file"; fails=1 ;; esac
    case "$out" in *"b.sh"*) echo "  SELF-TEST FAIL: reported a file only ONE pr touches"; fails=1 ;; *) ;; esac
    case "$out" in *"EXAMINED: 2 pull request(s), 2 distinct file(s), 3 (pr,file) pair(s)"*) ;; *) echo "  SELF-TEST FAIL: denominator wrong"; fails=1 ;; esac
    # A clean input must report none -- a checker that always finds something is
    # as useless as one that never does.
    clean="$(printf 'a.sh\t1\tale\nb.sh\t2\tbob\n' | collisions_from_tsv)"
    case "$clean" in *"COLLISIONS: none"*) ;; *) echo "  SELF-TEST FAIL: reported a collision on disjoint input"; fails=1 ;; esac
    if [ "$fails" -ne 0 ]; then echo "VERDICT: BROKEN -- self-test failed"; exit 1; fi
    echo "VERDICT: SELF-TEST OK -- planted collision found, disjoint input clean, denominator exact"
    exit 0
fi

command -v gh >/dev/null 2>&1 || { echo "CANNOT-RUN: gh is not on PATH"; exit 78; }
# bash 3.2 (macOS, and the cut host) treats "${arr[@]}" on an EMPTY array as an
# UNBOUND VARIABLE under set -u. The ${arr[@]+...} form is the 3.2-safe idiom.
# Found by running this on the host it ships to, not by reading it.
REPO_ARG=(); [ -n "$REPO" ] && REPO_ARG=(--repo "$REPO")
ra() { printf '%s\n' ${REPO_ARG[@]+"${REPO_ARG[@]}"}; }

me=""
if [ "$MINE" -eq 1 ]; then
    me="$(gh api user --jq .login 2>/dev/null)"
    [ -n "$me" ] || { echo "CANNOT-RUN: could not resolve the gh user for --mine"; exit 78; }
fi

# stderr is CAPTURED, not discarded: the first version sent it to /dev/null and
# then blamed "auth? wrong repo?" for what was actually a shell fault in this
# script. An error message that names the wrong culprit costs more than none.
# Same BSD-only trap as above; same guard, for the same reason.
_err="$(mktemp "${TMPDIR:-/tmp}/prlist_err.XXXXXX")"
[ -n "$_err" ] || { echo "CANNOT-RUN: mktemp failed"; exit 78; }
# The paginated file API needs owner/repo explicitly.
SLUG="${REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)}"
[ -n "$SLUG" ] || { echo "CANNOT-RUN: could not resolve owner/repo for the files API"; exit 78; }

prs="$(gh pr list ${REPO_ARG[@]+"${REPO_ARG[@]}"} --state open --limit "$LIMIT" \
        --json number,author,headRefName -q '.[] | "\(.number)\t\(.author.login)\t\(.headRefName)"' 2>"$_err")"
if [ -z "$prs" ]; then
    echo "CANNOT-RUN: gh pr list returned no rows. stderr follows -- read it before assuming auth:"
    sed 's/^/    /' "$_err" | head -5
    rm -f "$_err"; exit 78
fi
rm -f "$_err"

tsv=""
while IFS=$'\t' read -r n a b; do
    [ -z "$n" ] && continue
    # `gh pr view --json files` SILENTLY CAPS AT 100 FILES. Measured on
    # ostler-assistant#246: --json files reports 100, the paginated REST API
    # reports 617. A 6x under-count with no error and no warning.
    #
    # For a COLLISION checker that is the worst possible failure: files past the
    # cap are invisible, so the tool reports "no collision" on a file two PRs are
    # both editing. A false zero in the one tool whose job is not producing one.
    #
    # CM051's largest open PR is 34 files, so this repo is 66 files from the
    # cliff and the bug would have arrived silently, on some future big PR,
    # looking like a clean result. Archie hit it in oa where PRs are larger.
    #
    # --paginate with --jq is safe HERE because the output is consumed as LINES.
    # (`gh api --paginate` without --slurp emits one JSON DOCUMENT PER PAGE, so
    # anything parsing the concatenation as a single document gets invalid JSON.
    # This does not, and must not start to.)
    files="$(gh api "repos/${SLUG}/pulls/${n}/files?per_page=100" --paginate --jq '.[].filename' 2>/dev/null)"
    # BUILT-IN CONTROL: the capped call is still made, and a disagreement is
    # REPORTED rather than silently preferred. This is the check that would have
    # caught the bug in the first place, so it ships.
    _capped="$(gh pr view "$n" ${REPO_ARG[@]+"${REPO_ARG[@]}"} --json files -q '.files | length' 2>/dev/null)"
    _full="$(printf '%s' "$files" | grep -c . || true)"
    if [ -n "$_capped" ] && [ "$_capped" != "$_full" ]; then
        printf 'NOTE: #%s has %s files; gh --json files reported %s (capped). Using the paginated count.\n' \
               "$n" "$_full" "$_capped" >&2
    fi
    while read -r f; do
        [ -z "$f" ] && continue
        tsv="${tsv}${f}	${n}	${a}
"
    done <<EOF
$files
EOF
done <<EOF
$prs
EOF

printf '%s' "$tsv" | collisions_from_tsv

# ---------------------------------------------------------------------------
# STALE CONFLICT CHECK. The collision list above is about OTHER people. This is
# about time: a branch that merged cleanly when it was opened and does not any
# more. `gh pr view` reports mergeable UNKNOWN until GitHub gets round to it,
# which reads as "fine" -- so compute it locally instead of waiting.
# ---------------------------------------------------------------------------
if git rev-parse --git-dir >/dev/null 2>&1; then
    echo
    base="$(git rev-parse origin/main 2>/dev/null)"
    if [ -z "$base" ]; then
        echo "STALE CHECK: CANNOT-RUN -- no origin/main in this checkout"
    else
        # CONTROL: main against itself must merge clean, or merge-tree is lying
        if ! git merge-tree --write-tree "$base" "$base" >/dev/null 2>&1; then
            echo "STALE CHECK: CANNOT-RUN -- control failed (main does not merge with itself)"
        else
            echo "STALE CHECK vs origin/main ${base:0:8} (control passed):"
            n_ok=0; n_bad=0
            while IFS=$'\t' read -r num auth ref; do
                [ -z "$ref" ] && continue
                [ "$MINE" -eq 1 ] && [ "$auth" != "$me" ] && continue
                [ -n "$ONLY_PR" ] && [ "$num" != "$ONLY_PR" ] && continue
                git fetch origin "$ref" -q 2>/dev/null
                sha="$(git rev-parse "origin/${ref}" 2>/dev/null)"
                [ -z "$sha" ] && { echo "  #${num} CANNOT-RUN (no origin/${ref})"; continue; }
                if git merge-tree --write-tree "$base" "$sha" >/dev/null 2>&1; then
                    n_ok=$((n_ok + 1))
                else
                    n_bad=$((n_bad + 1)); echo "  #${num} CONFLICTS with main  (${ref})"
                fi
            done <<EOF
$prs
EOF
            echo "  clean=${n_ok} conflicting=${n_bad}"
        fi
    fi
fi
