#!/bin/bash
# repair_lid_as_phone one-time-upgrade-step marker guard (CM051 #2543)
# ====================================================================
#
# Archie, 2026-10-01: wired as a ONE-TIME UPGRADE STEP guarded by a marker
# file, same pattern as state/email_reclassify_v3.done -- "a test that the
# step is skipped when the marker exists."
#
# This extracts the actual install.sh block (not a hand-copied paraphrase of
# it -- a paraphrase would go green forever even if install.sh's real block
# drifted) and RUNS it in an isolated sandbox with a stub python3 standing in
# for identity_resolver.repair_lid_as_phone. The stub's only job is to prove
# whether it was invoked: it touches a sentinel file and exits 0.
#
# Three arms:
#   1. No marker present -> the stub MUST be invoked (sentinel appears) and
#      the marker MUST be written afterwards.
#   2. Marker already present -> the stub MUST NOT be invoked (sentinel
#      absent) and the pre-existing marker content is left untouched.
#   3. Archie, 2026-10-01: "The #2581 install step must not abort the
#      install on failure: no marker, a logged warning, and the next
#      upgrade retries." install.sh runs under `set -euo pipefail`
#      (verified: active, unbroken, from line 31631 to this block) --
#      `VAR="$(failing_cmd)"` is a SIMPLE COMMAND under bash's own rules,
#      so a naive capture aborts the WHOLE INSTALL right there. This arm
#      runs the block under REAL `set -e` with a stub that exits 1, and
#      proves install.sh keeps running past the block (a sentinel placed
#      AFTER the block in the runner is reached), no marker is written,
#      and a warning is logged.
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
#
# Walk #6 candidate #10: the end anchor was "# Apple Notes knowledge
# hydration" until a NEW one-time-repair block (Netflix rating-polarity)
# was inserted between this block and Apple Notes. That insertion made
# this extraction swallow the new block too -- arm 3 then failed for a
# reason that had nothing to do with the LID repair: the swallowed
# block's own `${SCRIPT_DIR}` reference is unbound in this test's
# sandbox (which never sets it), and `set -u` turned that into an abort
# BEFORE the "reached_end" sentinel, misread as "install.sh aborted when
# the repair failed". The end anchor now names the actual next section
# (whatever it is today), not a section two blocks away that happened to
# be adjacent when this test was written.
BLOCK="$(awk '
    /^# One-time repair: a WhatsApp LID written as a "phone" identifier/ {f=1}
    f {print}
    f && /^# One-time repair: the Netflix thumbs-value polarity bug/ {exit}
' "$INSTALL")"
# Drop the trailing "# One-time repair: the Netflix..." line the exit
# condition also printed.
BLOCK="$(printf '%s\n' "$BLOCK" | sed '$ d')"

echo "== control: the extraction is non-empty and carries what this test exercises =="
if [ -z "$BLOCK" ]; then
    echo "CANNOT-RUN: the block extraction found nothing -- install.sh's comment anchors moved; this test examined no code" >&2
    exit 2
fi
# herestring, not `printf ... | grep -q`: under `set -o pipefail` (this file
# sets it two lines above `cd`... see the `set -uo pipefail` near the top),
# `grep -q` can exit the instant it matches, SIGPIPE-ing printf before it
# finishes writing a large $BLOCK, and pipefail then reports the PIPELINE's
# status as printf's broken-pipe failure instead of grep's real (successful)
# match -- inverting a present marker into a reported absence. This file is
# bash-shebanged and run only via `bash tests/...`, never shipped over
# box_run's ssh branch, so the herestring is safe here (see
# tests/test_pipefail_shortcircuit_inversion.sh for the portable `grep -c`
# alternative where a POSIX shell is in play).
if grep -q 'repair_lid_as_phone_v1.done' <<< "$BLOCK" \
   && grep -q 'identity_resolver.repair_lid_as_phone' <<< "$BLOCK"; then
    ok "(0) extraction contains both the marker filename and the module invocation"
else
    bad "(0) extraction is missing the marker filename or the module invocation -- see BLOCK below"
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
    # $1 = sandbox OSTLER_DIR, $2 = PIPELINE_DIR
    OSTLER_DIR="$1" PIPELINE_DIR="$2" OXIGRAPH_URL="http://localhost:7878" \
        bash "$RUNNER"
}

mk_sandbox() {
    local dir; dir="$(mktemp -d)"
    mkdir -p "$dir/ostler/state" "$dir/ostler/logs" "$dir/pipeline/identity_resolver" "$dir/pipeline/.venv/bin"
    : > "$dir/pipeline/identity_resolver/repair_lid_as_phone.py"
    cat > "$dir/pipeline/.venv/bin/python3" <<STUB
#!/bin/bash
echo "invoked" > "$dir/sentinel"
echo 'LID written as phone (CM051 #2543), apply=True
  phone identifiers examined (total)        : 0
    Pass A1, CM041 bridge signature          : 0
    Pass A2, ostler_fda signature             : 0
  demoted/retyped                           : 0
  displayName renamed to WhatsApp contact   : 0'
exit 0
STUB
    chmod +x "$dir/pipeline/.venv/bin/python3"
    printf '%s\n' "$dir"
}

echo "== arm 1: no marker present -> the step runs =="
S1="$(mk_sandbox)"
run_block "$S1/ostler" "$S1/pipeline" >/dev/null 2>&1
if [ -f "$S1/sentinel" ]; then
    ok "(1a) the stub was invoked when no marker was present"
else
    bad "(1a) the stub was NOT invoked with no marker present -- the step never runs at all"
fi
if [ -f "$S1/ostler/state/repair_lid_as_phone_v1.done" ]; then
    ok "(1b) the marker was written after a successful run"
else
    bad "(1b) no marker was written after a successful (exit 0) run"
fi
rm -rf "$S1"

echo "== arm 2: marker already present -> the step is SKIPPED =="
S2="$(mk_sandbox)"
mkdir -p "$S2/ostler/state"
printf 'ran_at\t2026-01-01T00:00:00Z\nPASS A1 examined 0, demoted 0\n' > "$S2/ostler/state/repair_lid_as_phone_v1.done"
BEFORE="$(cat "$S2/ostler/state/repair_lid_as_phone_v1.done")"
run_block "$S2/ostler" "$S2/pipeline" >/dev/null 2>&1
if [ ! -f "$S2/sentinel" ]; then
    ok "(2a) the stub was NOT invoked when the marker already existed"
else
    bad "(2a) the stub WAS invoked despite an existing marker -- this is the defect Archie's instruction exists to prevent"
fi
AFTER="$(cat "$S2/ostler/state/repair_lid_as_phone_v1.done")"
if [ "$BEFORE" = "$AFTER" ]; then
    ok "(2b) the pre-existing marker content was left untouched"
else
    bad "(2b) the pre-existing marker content was overwritten"
fi
rm -rf "$S2"

rm -f "$RUNNER"

echo "== arm 3: repair script fails -> install.sh does not abort =="
# install.sh itself runs under `set -euo pipefail` (verified: `set -e` at
# line 31631, nothing turns it off before this block). Arms 1/2's RUNNER
# only has `set -uo pipefail`, which would NOT reproduce the abort this
# arm exists to catch -- a VAR="$(failing_cmd)" capture aborts a script
# under `-e` but not under `-u`/`-o pipefail` alone. RUNNER3 restores the
# real `-e` condition and adds a sentinel AFTER the block, so "did
# install.sh keep going" is a file on disk, not an inference from the
# runner's own exit code (which a trap or `|| true` elsewhere could mask).
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
    mkdir -p "$dir/ostler/state" "$dir/ostler/logs" "$dir/pipeline/identity_resolver" "$dir/pipeline/.venv/bin"
    : > "$dir/pipeline/identity_resolver/repair_lid_as_phone.py"
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
OSTLER_DIR="$S3/ostler" PIPELINE_DIR="$S3/pipeline" OXIGRAPH_URL="http://localhost:7878" \
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
    bad "(3b) install.sh aborted when the repair failed (runner rc=$RUNNER3_RC, reached_end present=$([ -f "$S3/ostler/reached_end" ] && echo yes || echo no)) -- this is exactly the failure Archie's instruction exists to prevent"
fi
if [ -f "$S3/ostler/state/repair_lid_as_phone_v1.done" ]; then
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
