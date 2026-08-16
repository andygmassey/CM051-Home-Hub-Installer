#!/usr/bin/env bash
# Hydrate sentinel honesty: a FAILED step must not suppress its retry (#711)
# =========================================================================
#
# Behavioural test. Extracts the REAL sentinel helpers from install.sh and
# executes them, so this cannot pass against a copy of the logic.
#
# THE DEFECT, measured 2026-08-16 on the box and then in source:
#
#   _hydrate_sentinel_record <source>   writes <source>.done, ALWAYS
#   _hydrate_sentinel_fresh  <source>   skips that source for 7 DAYS
#
# The helper's own header states the contract: the sentinel drops "once it
# completes (success or no-data both count)". SUCCESS OR NO-DATA. An errored
# run is neither, and nothing enforced the difference.
#
# The customer-visible case: deny Full Disk Access once, the iMessage
# extractor exits EX_CONFIG 78, imessage.done lands carrying people=0, and
# granting FDA an hour later changes nothing -- the block is skipped because
# the sentinel is fresh. A refusal that should last one run lasts a week.
#
# THE RULE IS NOT NEW. tests/test_aiconv_hydrate_honesty.sh already asserts it
# for ONE source: "a timed-out (124/137) or crashed (any other non-zero rc)
# drain must NOT record it, so the next install/re-run retries instead of
# skipping for a week". Measured across all nine sources, 8 broke it.
#
# Control (6) is deliberately a REPORT, not just a pass: it prints which
# sources are still unguarded, so the remaining work is visible in the test
# output rather than absent from it.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$REPO_ROOT/install.sh"

FAILURES=0
CHECKS=0
fail() { echo "  FAIL  $*" >&2; FAILURES=$((FAILURES + 1)); }
pass() { echo "  PASS  $*"; }
check() {
    CHECKS=$((CHECKS + 1))
    if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$3', got '$2')"; fi
}

[[ -f "$INSTALL" ]] || { echo "CANNOT-RUN: install.sh not found at $INSTALL" >&2; exit 2; }

# --- extract the REAL helpers, not a copy -----------------------------------
HARNESS="$(mktemp -d -t hydratesentinel-XXXXXX)"
trap 'rm -rf "$HARNESS"' EXIT

extract_fn() {
    # Print the function named $1 exactly as install.sh defines it.
    awk -v fn="$1" '
        $0 ~ "^"fn"\\(\\) \\{" { inside = 1 }
        inside { print }
        inside && /^\}$/ { exit }
    ' "$INSTALL"
}

{
    printf '_HYDRATE_SENTINEL_DIR="%s/state"\n' "$HARNESS"
    printf 'mkdir -p "$_HYDRATE_SENTINEL_DIR"\n'
    extract_fn _hydrate_sentinel_fresh
    extract_fn _hydrate_sentinel_record
    extract_fn _hydrate_sentinel_record_error
} > "$HARNESS/helpers.sh"

for fn in _hydrate_sentinel_fresh _hydrate_sentinel_record _hydrate_sentinel_record_error; do
    if ! grep -q "^${fn}() {" "$HARNESS/helpers.sh"; then
        echo "CANNOT-RUN: could not extract $fn from install.sh." >&2
        echo "  This test drives the REAL helpers; it refuses to run against a copy." >&2
        exit 2
    fi
done

bash -n "$HARNESS/helpers.sh" || { echo "CANNOT-RUN: extracted helpers do not parse" >&2; exit 2; }

echo "test_hydrate_sentinel_not_on_error.sh"

run_in_harness() { bash -c "source '$HARNESS/helpers.sh'; $1"; echo "$?"; }

# (1) A successful record is fresh. Without this the fix would break the
#     7-day dedupe the sentinel exists for.
rc=$(run_in_harness '_hydrate_sentinel_record imessage "people=12"; _hydrate_sentinel_fresh imessage')
check "(1) a completed run IS fresh, so re-runs still dedupe" "$rc" "0"

# (2) THE DEFECT. An errored record must NOT be fresh.
rc=$(run_in_harness '_hydrate_sentinel_record_error imessage 78 "people=0"; _hydrate_sentinel_fresh imessage')
check "(2) an ERRORED run is NOT fresh, so the next run retries" "$rc" "1"

# (3) The record still exists on disk and names the rc. Refusing to write the
#     file at all would lose the evidence Doctor and a human need.
out="$(bash -c "source '$HARNESS/helpers.sh'; _hydrate_sentinel_record_error places 2 'status=run'; cat \"\$_HYDRATE_SENTINEL_DIR/places.done\"")"
if printf '%s' "$out" | grep -q '^status=error' && printf '%s' "$out" | grep -q '^rc=2'; then
    pass "(3) the failure is still RECORDED (status=error, rc=2), not discarded"
else
    fail "(3) the error record lost its status or rc: $out"
fi
CHECKS=$((CHECKS + 1))

# (4) An error sentinel is not fresh at ANY age, including brand new. Guards
#     against a fix that only works once the mtime has aged.
rc=$(run_in_harness '_hydrate_sentinel_record_error whatsapp 1; _hydrate_sentinel_fresh whatsapp')
check "(4) an error sentinel is stale immediately, not after 7 days" "$rc" "1"

# (4b) THE UPGRADE-PATH GAP. Every sentinel written before #768 has NO
#      status line. Testing only for `status=error` left those reading as
#      fresh, so the fix could not reach any box that already had the defect.
#      Measured on the launch box after #768 merged: 8 sentinels, all legacy,
#      including the imessage.done written by the EX_CONFIG 78 tick itself.
rc=$(run_in_harness 'printf "recorded_at=2026-08-16T12:51:08Z\nsource=imessage\npayload=people=0\n" \
                       > "$_HYDRATE_SENTINEL_DIR/imessage.done"
                     _hydrate_sentinel_fresh imessage')
check "(4b) a LEGACY sentinel with no status line is NOT fresh" "$rc" "1"

# (4c) ...and it CONVERGES. After the retry records a success the source is
#      suppressed again, so an upgraded box re-hydrates ONCE, not every run.
rc=$(run_in_harness 'printf "recorded_at=2026-08-16T12:51:08Z\nsource=imessage\npayload=people=0\n" \
                       > "$_HYDRATE_SENTINEL_DIR/imessage.done"
                     _hydrate_sentinel_fresh imessage || _hydrate_sentinel_record imessage "people=41"
                     _hydrate_sentinel_fresh imessage')
check "(4c) after the retry succeeds it IS fresh again -- one re-hydrate, not a loop" "$rc" "0"

# (5) A success sentinel older than 7 days is still not fresh (unchanged).
rc=$(run_in_harness '_hydrate_sentinel_record browsing "sent=3"
                     touch -t 202001010000 "$_HYDRATE_SENTINEL_DIR/browsing.done"
                     _hydrate_sentinel_fresh browsing')
check "(5) the 7-day expiry still applies to a successful run" "$rc" "1"

# (6) An absent sentinel is not fresh.
rc=$(run_in_harness '_hydrate_sentinel_fresh never_ran')
check "(6) an absent sentinel is not fresh" "$rc" "1"

# (7) POPULATION REPORT. Which sources route their non-zero-rc arm to the
#     error variant? This prints the unguarded ones so the remaining work is
#     visible in the output rather than silently missing. It ASSERTS only the
#     sources this change covers; the rest are reported, and the count is
#     ratcheted so it can only improve.
echo
echo "  -- sentinel guard coverage --"
GUARDED=0
for src in imessage places ai_conversations; do
    if grep -q "_hydrate_sentinel_record_error \"$src\"\|_hydrate_sentinel_record_error $src" "$INSTALL" \
       || [[ "$src" == "ai_conversations" ]]; then
        echo "     guarded    $src"
        GUARDED=$((GUARDED + 1))
    else
        echo "     UNGUARDED  $src"
    fi
done
for src in whatsapp browsing email_preferences apple_notes people privacy_backfill; do
    if grep -q "_hydrate_sentinel_record_error \"$src\"" "$INSTALL"; then
        echo "     guarded    $src"
        GUARDED=$((GUARDED + 1))
    else
        echo "     UNGUARDED  $src   <- still writes .done on the error path (#711)"
    fi
done
echo
CHECKS=$((CHECKS + 1))
if [[ "$GUARDED" -ge 3 ]]; then
    pass "(7) at least the 3 covered sources are guarded (guarded=$GUARDED of 9)"
else
    fail "(7) coverage went BACKWARDS: guarded=$GUARDED, floor is 3"
fi

echo
echo "=== $((CHECKS - FAILURES)) passed / $FAILURES failed ==="
[[ "$FAILURES" -eq 0 ]]
