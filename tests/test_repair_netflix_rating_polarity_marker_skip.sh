#!/bin/bash
# repair_netflix_rating_polarity one-time-upgrade-step marker guard
# (walk #6 candidate #10, coordinator decision: wire it, same shape as
# repair_lid_as_phone -- abort-safe, with a test).
#
# Same pattern as tests/test_repair_lid_as_phone_marker_skip.sh: extracts
# the ACTUAL install.sh block (not a hand-copied paraphrase -- a paraphrase
# would go green forever even if the real block drifted) and runs it in an
# isolated sandbox with a stub python3 standing in for
# scripts/repair_netflix_rating_polarity.py. The stub's only job is to
# prove whether it was invoked: it touches a sentinel file and exits 0.
#
# Three arms:
#   1. No marker present -> the stub MUST be invoked (sentinel appears) and
#      the marker MUST be written afterwards.
#   2. Marker already present -> the stub MUST NOT be invoked (sentinel
#      absent) and the pre-existing marker content is left untouched.
#   3. The repair step must not abort the install on failure: no marker, a
#      logged warning, and the next upgrade retries. install.sh runs under
#      `set -euo pipefail` -- a `VAR="$(failing_cmd)"` capture is a SIMPLE
#      COMMAND under bash's own rules, so a naive capture aborts the WHOLE
#      INSTALL right there. This arm runs the block under REAL `set -e`
#      with a stub that exits 1, and proves install.sh keeps running past
#      the block (a sentinel placed AFTER the block in the runner is
#      reached), no marker is written, and a warning is logged.
#
# A control proves the extraction itself is non-empty and contains the
# commands this test depends on, so a silent extraction failure cannot read
# as "both arms passed because nothing ran in either one."

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="${REPO_ROOT}/install.sh"

PASS=0
FAIL=0
ok()  { echo "  [pass] $*"; PASS=$((PASS+1)); }
bad() { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }

[ -f "$INSTALL" ] || { echo "CANNOT-RUN: no $INSTALL"; exit 2; }

# Extract the block between its own start and end comments, verbatim.
BLOCK="$(awk '
    /^# One-time repair: the Netflix thumbs-value polarity bug/ {f=1}
    f {print}
    f && /^# Apple Notes knowledge hydration/ {exit}
' "$INSTALL")"
# Drop the trailing "# Apple Notes..." line the exit condition also printed.
BLOCK="$(printf '%s\n' "$BLOCK" | sed '$ d')"

echo "== control: the extraction is non-empty and carries what this test exercises =="
if [ -z "$BLOCK" ]; then
    echo "CANNOT-RUN: the block extraction found nothing -- install.sh's comment anchors moved; this test examined no code" >&2
    exit 2
fi
if grep -q 'repair_netflix_rating_polarity_v1.done' <<< "$BLOCK" \
   && grep -q 'repair_netflix_rating_polarity.py' <<< "$BLOCK"; then
    ok "(0) extraction contains both the marker filename and the script invocation"
else
    bad "(0) extraction is missing the marker filename or the script invocation -- see BLOCK below"
    printf '%s\n' "$BLOCK"
    exit 1
fi

RUNNER="$(mktemp)"
{
    echo '#!/bin/bash'
    echo 'set -uo pipefail'
    echo 'ok()   { :; }'
    echo 'warn() { echo "WARN: $*" >&2; }'
    printf '%s\n' "$BLOCK"
} > "$RUNNER"

run_block() {
    # $1 = sandbox OSTLER_DIR, $2 = PIPELINE_DIR, $3 = SCRIPT_DIR
    OSTLER_DIR="$1" PIPELINE_DIR="$2" SCRIPT_DIR="$3" QDRANT_URL="http://localhost:6333" \
        bash "$RUNNER"
}

mk_sandbox() {
    local dir; dir="$(mktemp -d)"
    mkdir -p "$dir/ostler/state" "$dir/ostler/logs" \
             "$dir/pipeline/.venv/bin" "$dir/script/scripts"
    : > "$dir/script/scripts/repair_netflix_rating_polarity.py"
    cat > "$dir/pipeline/.venv/bin/python3" <<STUB
#!/bin/bash
echo "invoked" > "$dir/sentinel"
echo 'collection      : preferences @ http://localhost:6333
points total    : 0
candidates found: 0 (wrong label, not yet repaired)
  to reclassify : 0
  to delete     : 0 (Thumbs Value=0, not rated)

Nothing to do.'
exit 0
STUB
    chmod +x "$dir/pipeline/.venv/bin/python3"
    printf '%s\n' "$dir"
}

echo "== arm 1: no marker present -> the step runs =="
S1="$(mk_sandbox)"
run_block "$S1/ostler" "$S1/pipeline" "$S1/script" >/dev/null 2>&1
if [ -f "$S1/sentinel" ]; then
    ok "(1a) the stub was invoked when no marker was present"
else
    bad "(1a) the stub was NOT invoked with no marker present -- the step never runs at all"
fi
if [ -f "$S1/ostler/state/repair_netflix_rating_polarity_v1.done" ]; then
    ok "(1b) the marker was written after a successful run"
else
    bad "(1b) no marker was written after a successful (exit 0) run"
fi
rm -rf "$S1"

echo "== arm 2: marker already present -> the step is SKIPPED =="
S2="$(mk_sandbox)"
mkdir -p "$S2/ostler/state"
printf 'ran_at\t2026-01-01T00:00:00Z\ncandidates found: 0\n' > "$S2/ostler/state/repair_netflix_rating_polarity_v1.done"
BEFORE="$(cat "$S2/ostler/state/repair_netflix_rating_polarity_v1.done")"
run_block "$S2/ostler" "$S2/pipeline" "$S2/script" >/dev/null 2>&1
if [ ! -f "$S2/sentinel" ]; then
    ok "(2a) the stub was NOT invoked when the marker already existed"
else
    bad "(2a) the stub WAS invoked despite an existing marker"
fi
AFTER="$(cat "$S2/ostler/state/repair_netflix_rating_polarity_v1.done")"
if [ "$BEFORE" = "$AFTER" ]; then
    ok "(2b) the pre-existing marker content was left untouched"
else
    bad "(2b) the pre-existing marker content was overwritten"
fi
rm -rf "$S2"

rm -f "$RUNNER"

echo "== arm 3: repair script fails -> install.sh does not abort =="
# install.sh itself runs under `set -euo pipefail`. Arms 1/2's RUNNER only
# has `set -uo pipefail`, which would NOT reproduce the abort this arm
# exists to catch. RUNNER3 restores the real `-e` condition and adds a
# sentinel AFTER the block, so "did install.sh keep going" is a file on
# disk, not an inference from the runner's own exit code.
RUNNER3="$(mktemp)"
{
    echo '#!/bin/bash'
    echo 'set -euo pipefail'
    echo 'ok()   { :; }'
    echo 'warn() { echo "WARN: $*" >&2; }'
    printf '%s\n' "$BLOCK"
    echo 'echo reached > "$OSTLER_DIR/reached_end"'
} > "$RUNNER3"

mk_sandbox_failing() {
    local dir; dir="$(mktemp -d)"
    mkdir -p "$dir/ostler/state" "$dir/ostler/logs" \
             "$dir/pipeline/.venv/bin" "$dir/script/scripts"
    : > "$dir/script/scripts/repair_netflix_rating_polarity.py"
    cat > "$dir/pipeline/.venv/bin/python3" <<STUB
#!/bin/bash
echo "invoked" > "$dir/sentinel"
echo "boom: simulated repair failure" >&2
exit 1
STUB
    chmod +x "$dir/pipeline/.venv/bin/python3"
    printf '%s\n' "$dir"
}

S3="$(mk_sandbox_failing)"
STDERR3="$(mktemp)"
OSTLER_DIR="$S3/ostler" PIPELINE_DIR="$S3/pipeline" SCRIPT_DIR="$S3/script" QDRANT_URL="http://localhost:6333" \
    bash "$RUNNER3" >/dev/null 2>"$STDERR3"
RUNNER3_RC=$?

if [ -f "$S3/sentinel" ]; then
    ok "(3a) the stub WAS invoked (it really ran, and really failed)"
else
    bad "(3a) the stub was never invoked -- this arm proves nothing"
fi
if [ "$RUNNER3_RC" -eq 0 ] && [ -f "$S3/ostler/reached_end" ]; then
    ok "(3b) install.sh continued past the block after the repair failed (did not abort)"
else
    bad "(3b) install.sh aborted when the repair failed (runner rc=$RUNNER3_RC, reached_end present=$([ -f "$S3/ostler/reached_end" ] && echo yes || echo no))"
fi
if [ -f "$S3/ostler/state/repair_netflix_rating_polarity_v1.done" ]; then
    bad "(3c) a marker was written despite the repair failing -- the next upgrade would wrongly skip the retry"
else
    ok "(3c) no marker was written after a failed run, so the next upgrade retries"
fi
if grep -q '^WARN:' "$STDERR3"; then
    ok "(3d) a warning was logged for the failed repair"
else
    bad "(3d) no warning was logged -- a failed repair must not fail silently"
fi
rm -rf "$S3"
rm -f "$STDERR3" "$RUNNER3"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
