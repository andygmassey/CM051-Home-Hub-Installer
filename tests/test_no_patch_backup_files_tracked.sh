#!/bin/bash
# No patch(1) / merge backup file is ever tracked.
#
# CM051 #2937 (v1.0.108 batch 1) committed
# vendor/cm019_preferences/services/enrich/src/models/enrichment.py.orig, 843
# lines, in this PUBLIC repo: patch(1) writes FILE.orig when a hunk applies with
# fuzz or offset, and `git add -A` took it. A backup is a stale copy of shipped
# code that nothing reads, and in a vendored tree it can carry exactly the
# upstream content a graft was written to keep out.
#
# Fails if `git ls-files` lists any *.orig, *.rej, *.porig, *~ or
# *.{BACKUP,BASE,LOCAL,REMOTE}.* (git mergetool leftovers).
#
# Controls, run first in a throwaway repo, so a broken predicate cannot pass:
#   positive  a tracked x.orig and x.rej MUST be found (2 of 2)
#   negative  a tracked file named "origin.txt" and "orig_notes.md" MUST NOT be
#
# Exit: 0 pass, 1 found, 2 cannot-run. Runs under /bin/bash 3.2.

set -u

PATTERN='(\.orig|\.rej|\.porig|~)$|\.(BACKUP|BASE|LOCAL|REMOTE)\.[^/]*$'

find_backups() {
    # $1 = repo dir. Prints offending tracked paths. Exit 2 if git fails.
    local out
    if ! out="$(git -C "$1" ls-files 2>&1)"; then
        echo "CANNOT RUN: git ls-files failed in $1: $out" >&2
        return 2
    fi
    /usr/bin/grep -E "$PATTERN" <<<"$out"
    return 0
}

tmp="$(mktemp -d)" || { echo "CANNOT RUN: mktemp" >&2; exit 2; }
trap 'rm -rf "$tmp"' EXIT
(
    cd "$tmp" && git init -q . && \
    : > a.py.orig && : > b.py.rej && : > origin.txt && : > orig_notes.md && \
    git add a.py.orig b.py.rej origin.txt orig_notes.md
) || { echo "CANNOT RUN: could not build the control repo" >&2; exit 2; }

ctl="$(find_backups "$tmp")"; rc=$?
[ "$rc" = 0 ] || exit 2
n_pos="$(/usr/bin/grep -cE '^(a\.py\.orig|b\.py\.rej)$' <<<"$ctl")"
if [ "$n_pos" != 2 ]; then
    echo "FAIL: positive control found ${n_pos} of 2 planted backups; the predicate is broken" >&2
    exit 1
fi
if /usr/bin/grep -qE '^(origin\.txt|orig_notes\.md)$' <<<"$ctl"; then
    echo "FAIL: negative control flagged a non-backup name; the predicate is too wide" >&2
    exit 1
fi
echo "controls: positive 2 of 2 found, negative 0 of 2 flagged"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
found="$(find_backups "$REPO")"; rc=$?
[ "$rc" = 0 ] || exit 2
total="$(git -C "$REPO" ls-files | wc -l | tr -d ' ')"
if [ -n "$found" ]; then
    echo "FAIL: tracked patch/merge backup file(s), delete them (git rm):" >&2
    printf '  %s\n' $found >&2
    exit 1
fi
echo "PASS: 0 backup files among ${total} tracked files"
exit 0
