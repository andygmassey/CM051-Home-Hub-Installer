#!/usr/bin/env bash
# provenance_gate.sh must not pipe `git show` into `grep -q`.
#
# THE DEFECT. provenance_gate.sh runs under `set -uo pipefail`. `grep -q` exits
# on its FIRST match. When the blob is larger than the pipe buffer, git is still
# writing when grep goes away, takes SIGPIPE and exits 141, and pipefail makes
# the pipeline non-zero ON A MATCH. The `if` then reads false and the gate
# announces STALE DAEMON SOURCE about a marker that IS PRESENT.
#
# That is a FABRICATED CUT BLOCKER, and this repo has a history of those.
#
# It was latent when found: scripts/required_fixes.tsv had 4 data rows, 3
# wiki-compiler and 1 wiki-site, and ZERO daemon rows, so nothing reached the
# branch. It goes live the moment someone adds a daemon row naming a large
# source file, which is exactly what gating a daemon fix looks like.
#
# WHAT THIS TEST DOES. It builds its own git repo with a blob big enough to
# fill the pipe and a marker on line 1, then:
#   1. proves the fixture ACTUALLY triggers the race, by running the OLD shape
#      and requiring it to invert. Without this the test could pass on a blob
#      too small to trigger anything and prove nothing.
#   2. requires the file-based shape to return 0 on the SAME fixture.
#   3. requires the piped shape to be absent from the daemon-src read site.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$REPO_ROOT/scripts/provenance_gate.sh"
FAILED=0

fail() { echo "FAIL [$1]: $2" >&2; FAILED=1; }
pass() { echo "PASS: $1"; }

if [[ ! -f "$GATE" ]]; then
    echo "FAIL [gate-missing]: $GATE not found -- nothing was checked. NOT a pass." >&2
    exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---- fixture: a real git repo with a large blob, marker on line 1 ----------
MARKER='OSTLER_FIXTURE_MARKER_ON_LINE_ONE'
BLOB="$WORK/repo/big.rs"
mkdir -p "$WORK/repo"
{
    echo "$MARKER"
    i=0
    while [[ $i -lt 30000 ]]; do
        echo "// filler line $i to push this blob past the pipe buffer"
        i=$((i + 1))
    done
} > "$BLOB"

BLOB_BYTES=$(wc -c < "$BLOB" | tr -d ' ')
if [[ "$BLOB_BYTES" -lt 200000 ]]; then
    fail "fixture-too-small" "blob is only $BLOB_BYTES bytes; it must comfortably exceed the pipe buffer or the race cannot occur"
fi

git -C "$WORK/repo" init -q
git -C "$WORK/repo" config user.email fixture@example.com
git -C "$WORK/repo" config user.name Fixture
git -C "$WORK/repo" add big.rs
git -C "$WORK/repo" commit -qm fixture
SHA=$(git -C "$WORK/repo" rev-parse HEAD)

# ---- 1. the fixture must actually trigger the race ------------------------
# If this does NOT invert, the fixture is not exercising the defect and every
# assertion below is vacuous.
OLD_RC=$( set -uo pipefail
          git -C "$WORK/repo" show "$SHA:big.rs" 2>/dev/null | grep -qE -- "$MARKER"
          echo $? )
if [[ "$OLD_RC" == "0" ]]; then
    fail "fixture-does-not-race" "the OLD piped shape returned 0 on this fixture, so it does not reproduce the defect and the rest of this test proves nothing (blob=$BLOB_BYTES bytes)"
else
    pass "fixture reproduces the race: piped shape returns $OLD_RC on a marker that IS present"
fi

# ---- 2. the same lookup, done without a pipe, must succeed ----------------
TMP_BLOB="$WORK/blob.out"
NEW_RC=$( set -uo pipefail
          git -C "$WORK/repo" show "$SHA:big.rs" > "$TMP_BLOB" 2>/dev/null
          grep -qE -- "$MARKER" "$TMP_BLOB"
          echo $? )
if [[ "$NEW_RC" != "0" ]]; then
    fail "file-shape-broken" "reading to a file then grepping returned $NEW_RC; it must be 0 because the marker is on line 1"
else
    pass "file-based read returns 0 on the same fixture"
fi

# ---- 3. a genuinely absent marker must still be an honest no-match --------
ABSENT_RC=$( set -uo pipefail
             grep -qE -- "OSTLER_FIXTURE_MARKER_THAT_IS_NOT_THERE" "$TMP_BLOB"
             echo $? )
if [[ "$ABSENT_RC" != "1" ]]; then
    fail "absent-marker" "an absent marker returned $ABSENT_RC; it must be 1, or the fix has made every check pass"
else
    pass "absent marker still returns 1 (the fix did not blind the check)"
fi

# ---- 4. the gate must not carry the piped shape at the daemon read site ---
if grep -qE 'git -C "\$dir" show "\$\{tag_sha\}:\$\{mpath\}"[^|]*\| *grep -q' "$GATE"; then
    fail "shape-present" "provenance_gate.sh still pipes git show into grep -q at the daemon-src read site"
else
    pass "provenance_gate.sh does not pipe git show into grep -q"
fi

if [[ "$FAILED" -ne 0 ]]; then
    exit 1
fi
echo
echo "ALL PROVENANCE GATE MARKER-READ TESTS PASSED"
