#!/usr/bin/env bash
# scripts/push_cut_tag.sh <version> <sha>
#
# THE ONLY WAY TO PUSH A CUT TAG. Runs the tag-time checklist gate
# (OSTLER_CUT_IN_PROGRESS=1, the mode cut.yml applies on a tag push) against
# a clean worktree at <sha> BEFORE the tag exists, and refuses to push if it
# is red.
#
# Why: v1.0.103 was tagged at 28a5e715 and cut.yml refused it at preflight
# (run 36323818300) on four board rows. A dispatch runs that gate in report
# mode on purpose (a dispatch must be able to build while BLOCKING rows wait
# on its walk), so nothing ran the ship-mode gate until the one tag push a
# version gets was already spent. Running it here first means a refusal costs
# a fix, not a version number.
#
# OSTLER_PRETAG_CHECKER overrides the checker (tests only).
# OSTLER_PRETAG_DRY_RUN=1 prints the push instead of doing it (tests only).
set -euo pipefail

ver="${1:?usage: push_cut_tag.sh <version, e.g. v1.0.104> <sha>}"
sha="${2:?usage: push_cut_tag.sh <version> <sha>}"
case "$ver" in v1.0.*) ;; *) echo "push_cut_tag: '$ver' is not a v1.0.* cut tag" >&2; exit 2 ;; esac

root="$(git rev-parse --show-toplevel)"
full="$(git -C "$root" rev-parse --verify "${sha}^{commit}")" || { echo "push_cut_tag: $sha is not a commit here" >&2; exit 2; }
if git -C "$root" ls-remote --exit-code --tags origin "refs/tags/$ver" >/dev/null 2>&1; then
    echo "push_cut_tag: $ver already exists on origin; a version gets ONE tag push" >&2; exit 2
fi

wt="$(mktemp -d "${TMPDIR:-/tmp}/pretag.XXXXXX")"
cleanup() { git -C "$root" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"; }
trap cleanup EXIT
git -C "$root" worktree add --detach -q "$wt" "$full"

checker="${OSTLER_PRETAG_CHECKER:-python3 tests/test_the_cut_checklist_is_complete.py}"
echo "push_cut_tag: tag-time checklist gate at ${full:0:8} (OSTLER_CUT_IN_PROGRESS=1)"
set +e
( cd "$wt" && OSTLER_CUT_IN_PROGRESS=1 bash -c "$checker" )
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
    echo "push_cut_tag: REFUSED. The gate cut.yml runs on a tag push is red (rc=$rc) at ${full:0:8}; $ver was NOT pushed." >&2
    exit 1
fi

if [ "${OSTLER_PRETAG_DRY_RUN:-0}" = "1" ]; then
    echo "DRY-RUN: git tag $ver $full && git push origin $ver"
    exit 0
fi
git -C "$root" tag "$ver" "$full"
git -C "$root" push origin "$ver"
