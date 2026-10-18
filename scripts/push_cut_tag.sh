#!/usr/bin/env bash
# scripts/push_cut_tag.sh <version> <sha>
#
# THE ONLY WAY TO PUSH A CUT TAG. Before the tag exists it REHEARSES the tag
# run: pushes branch rehearse/<version> at <sha> and dispatches cut.yml on it.
# cut.yml runs its OWN preflight job in tag mode for that ref and skips every
# build/ship job. The tag is pushed only if that run, at the SAME SHA,
# concluded success -- read from the run's API `conclusion`, never a log grep.
#
# Why the rehearsal is the tag run's own code and not a local copy: v1.0.103
# and v1.0.104 each spent their one tag push on a preflight refusal. The first
# version of this script re-ran one gate locally; it passed v1.0.104 while the
# tag run's "BOM rows must be in the pinned tree" step refused it. A copy of a
# gate drifts; the job itself cannot.
#
# Tests only: OSTLER_PRETAG_REHEARSE=<cmd> replaces the dispatch and must print
# "<conclusion> <headSha> <run_url>"; OSTLER_PRETAG_DRY_RUN=1 prints the push.
set -euo pipefail

ver="${1:?usage: push_cut_tag.sh <version, e.g. v1.0.105> <sha>}"
sha="${2:?usage: push_cut_tag.sh <version> <sha>}"
case "$ver" in v1.0.*) ;; *) echo "push_cut_tag: '$ver' is not a v1.0.* cut tag" >&2; exit 2 ;; esac
REPO_SLUG="${OSTLER_REPO_SLUG:-andygmassey/CM051-Home-Hub-Installer}"

root="$(git rev-parse --show-toplevel)"
full="$(git -C "$root" rev-parse --verify "${sha}^{commit}")" || { echo "push_cut_tag: $sha is not a commit here" >&2; exit 2; }
if [ -z "${OSTLER_PRETAG_REHEARSE:-}" ] && git -C "$root" ls-remote --exit-code --tags origin "refs/tags/$ver" >/dev/null 2>&1; then
    echo "push_cut_tag: $ver already exists on origin; a version gets ONE tag push" >&2; exit 2
fi

rehearse() {
    local br="rehearse/$ver" since id="" s i
    since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    git -C "$root" push -q --force origin "${full}:refs/heads/${br}"
    trap 'git -C "$root" push -q origin ":refs/heads/'"$br"'" >/dev/null 2>&1 || true' EXIT
    gh workflow run cut.yml --repo "$REPO_SLUG" --ref "$br" >/dev/null
    for i in $(seq 1 40); do
        id="$(gh api "repos/$REPO_SLUG/actions/workflows/cut.yml/runs?event=workflow_dispatch&branch=$br&head_sha=$full&created=>=$since" \
              -q '.workflow_runs | sort_by(.created_at) | last | .id // empty')"
        [ -n "$id" ] && break; sleep 15
    done
    [ -n "$id" ] || { echo "CANNOT-RUN - no-run-found"; return 0; }
    for i in $(seq 1 240); do
        s="$(gh api "repos/$REPO_SLUG/actions/runs/$id" -q '.status')"
        [ "$s" = completed ] && break; sleep 30
    done
    gh api "repos/$REPO_SLUG/actions/runs/$id" -q '"\(.conclusion // "none") \(.head_sha) \(.html_url)"'
}

echo "push_cut_tag: rehearsing the tag run for $ver at ${full:0:8}"
if [ -n "${OSTLER_PRETAG_REHEARSE:-}" ]; then out="$(bash -c "$OSTLER_PRETAG_REHEARSE")"; else out="$(rehearse)"; fi
read -r conclusion run_sha run_url <<<"$out"
echo "push_cut_tag: rehearsal conclusion=$conclusion sha=${run_sha:0:8} $run_url"
if [ "$run_sha" != "$full" ]; then
    echo "push_cut_tag: REFUSED. The rehearsal ran at ${run_sha:-nothing}, not ${full:0:8}; $ver was NOT pushed." >&2; exit 1
fi
if [ "$conclusion" != "success" ]; then
    echo "push_cut_tag: REFUSED. The tag run's own preflight concluded '$conclusion' at ${full:0:8}; $ver was NOT pushed." >&2; exit 1
fi
if [ "${OSTLER_PRETAG_DRY_RUN:-0}" = "1" ]; then
    echo "DRY-RUN: git tag $ver $full && git push origin $ver"; exit 0
fi
git -C "$root" tag "$ver" "$full"
git -C "$root" push origin "$ver"
