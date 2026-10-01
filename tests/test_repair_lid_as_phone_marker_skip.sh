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
# Two arms:
#   1. No marker present -> the stub MUST be invoked (sentinel appears) and
#      the marker MUST be written afterwards.
#   2. Marker already present -> the stub MUST NOT be invoked (sentinel
#      absent) and the pre-existing marker content is left untouched.
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
    /^# One-time repair: a WhatsApp LID written as a "phone" identifier/ {f=1}
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
if printf '%s\n' "$BLOCK" | grep -q 'repair_lid_as_phone_v1.done' \
   && printf '%s\n' "$BLOCK" | grep -q 'identity_resolver.repair_lid_as_phone'; then
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

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
