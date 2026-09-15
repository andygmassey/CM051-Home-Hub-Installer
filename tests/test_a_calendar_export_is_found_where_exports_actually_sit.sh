#!/usr/bin/env bash
# THE CALENDAR SCAN MUST FIND THE EXPORTS CUSTOMERS ACTUALLY HAVE.
#
# Andy ruled on 2026-09-12: "change the installer, not the box". A customer
# who has done the work of requesting an export should not have to re-arrange
# their Downloads folder to match a number the installer picked.
#
# THE DEFECT, measured 2026-09-16 on origin/main. The calendar arm read
#
#     find "$search_dir" -maxdepth 3 -name "*.ics" -size +1k | head -3
#
# and both halves lost real data, silently.
#
#   DEPTH. Nobody ships calendars at depth 3:
#       ~/Downloads/takeout-<stamp>/Takeout/Calendar/<name>.ics       4
#       ~/Downloads/your_facebook_activity/events/<...>/<name>.ics    4-5
#   The Facebook arm four lines above it in the same loop had already been
#   taken to maxdepth 5 for exactly this reason (CX-126). The calendar arm was
#   never given the same treatment, so two detectors reading the same folders
#   disagreed about how deep an export can be.
#
#   THE FILE CAP. `head -3` is worse than the depth because it is silent AND
#   order-dependent. A customer with four calendars lost one, and which one
#   depended on the order the filesystem happened to return.
#
# WHAT THIS TEST DOES. It extracts the REAL find predicate from install.sh and
# runs it against a tree built to the shapes above. It does not assert the
# flags: a predicate can carry -maxdepth 6 and still miss, and a number in a
# source file is not a file on a customer's disk.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${REPO}/install.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

[ -f "$SUBJECT" ] || { echo "CANNOT-RUN: no install.sh at ${SUBJECT}" >&2; exit 2; }
WORK="$(mktemp -d)" || { echo "CANNOT-RUN: no working directory" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# --- extract the REAL predicate, by content ----------------------------------
# From the process-substitution line that feeds the calendar loop. Taken as a
# multi-line block because the predicate is continued across several lines.
PRED="${WORK}/pred.sh"
awk '
    /done < <\(find "\$search_dir" -maxdepth 6 -xdev/ { f = 1 }
    f { print; if ($0 ~ /-print 2>\/dev\/null \|\| true\)$/) exit }
' "$SUBJECT" > "$PRED"

if ! /usr/bin/grep -q "name '\*.ics'" "$PRED"; then
    echo "CANNOT-RUN: could not extract the calendar find predicate from ${SUBJECT}." >&2
    echo "  Scanning nothing must not read as a passing test." >&2
    exit 2
fi

# Turn `done < <(find ... )` into a runnable `find ... `.
RUNNER="${WORK}/runner.sh"
{
    printf 'search_dir="$1"\n'
    # The line is indented inside the per-folder loop, so the anchor has to
    # allow for that. Without the [[:space:]]* the substitution silently does
    # nothing and the harness runs `done < <(...)` on its own, which is a
    # parse error rather than a wrong answer -- caught by the bash -n below.
    /usr/bin/sed -e 's|^[[:space:]]*done < <(|(|' "$PRED"
} > "$RUNNER"
if ! bash -n "$RUNNER" 2>/dev/null; then
    echo "CANNOT-RUN: the extracted predicate does not parse; the extraction is wrong." >&2
    /usr/bin/sed 's|^|    |' "$RUNNER" >&2
    exit 2
fi

_ics() { # make a >1k .ics so -size +1k keeps it
    mkdir -p "$(dirname "$1")"
    {
        printf 'BEGIN:VCALENDAR\nVERSION:2.0\n'
        i=0; while [ "$i" -lt 60 ]; do
            printf 'BEGIN:VEVENT\nSUMMARY:synthetic fixture event %s\nEND:VEVENT\n' "$i"
            i=$((i+1))
        done
        printf 'END:VCALENDAR\n'
    } > "$1"
}

_run() { bash "$RUNNER" "$1" 2>&1; }
_count() { _run "$1" | /usr/bin/grep -c . || true; }

printf 'A CALENDAR EXPORT IS FOUND WHERE EXPORTS ACTUALLY SIT\n\n'

# --- the tree, built to the shapes real exports have -------------------------
DL="${WORK}/Downloads"
_ics "${DL}/loose.ics"                                                  # depth 1
_ics "${DL}/takeout-20260912T101500Z-1-001/Takeout/Calendar/Home.ics"   # depth 4
_ics "${DL}/takeout-20260912T101500Z-1-001/Takeout/Calendar/Work.ics"   # depth 4
_ics "${DL}/takeout-20260912T101500Z-1-001/Takeout/Calendar/Family.ics" # depth 4
_ics "${DL}/your_facebook_activity/events/calendar/your_events.ics"     # depth 4
_ics "${DL}/archive/exports/google/Takeout/Calendar/Old.ics"            # depth 6

echo "-- 0. CONTROL: the predicate finds the shallow file the OLD one also found --"
# If this misses, the extraction or the harness is broken and every arm below
# is measuring the harness rather than the fix.
if _run "$DL" | /usr/bin/grep -q 'loose.ics'; then
    ok "the depth-1 file is found, so the predicate runs and the fixture is readable"
else
    echo "CANNOT-RUN: the predicate found nothing at all, not even at depth 1." >&2
    exit 2
fi

echo "-- 1. THE MEASURED DEFECT: exports below depth 3 are found --"
MISSED=""
for want in "Takeout/Calendar/Home.ics" "your_facebook_activity/events/calendar/your_events.ics" \
            "archive/exports/google/Takeout/Calendar/Old.ics"; do
    _run "$DL" | /usr/bin/grep -q "$want" || MISSED="${MISSED} ${want}"
done
if [ -z "$MISSED" ]; then
    ok "Google Takeout (depth 4), Facebook (depth 4) and a nested archive (depth 6) are all found"
else
    bad "still unread:${MISSED}"
fi

echo "-- 2. THE FILE CAP IS GONE: a customer with more than three calendars --"
N="$(_count "$DL")"
if [ "${N:-0}" -eq 6 ]; then
    ok "all 6 calendars are reported (the old cap returned at most 3)"
else
    bad "found ${N} of 6 calendars; something is still capping or still missing"
fi

echo "-- 3. STILL BOUNDED: the scan does not walk into package bundles --"
# A .app or a photo library can hold tens of thousands of files and can never
# hold a customer's diary. An .ics inside one is also not theirs to import.
_ics "${DL}/Some App.app/Contents/Resources/sample.ics"
_ics "${DL}/Photos.photoslibrary/resources/derivatives/stray.ics"
_ics "${DL}/project/node_modules/some-pkg/fixtures/test.ics"
AFTER="$(_count "$DL")"
if [ "${AFTER:-0}" -eq 6 ]; then
    ok "3 files planted inside an .app, a photo library and node_modules are all skipped"
else
    bad "the scan descended into a pruned bundle: count went from 6 to ${AFTER}"
fi

echo "-- and it is still bounded by DEPTH, so a pathological tree cannot run away --"
_ics "${DL}/a/b/c/d/e/f/g/way-too-deep.ics"
DEEP="$(_count "$DL")"
if [ "${DEEP:-0}" -eq 6 ]; then
    ok "a file at depth 8 is not reached: the descent is still capped, just at a useful depth"
else
    bad "depth bound is not holding: count went from 6 to ${DEEP}"
fi

echo "-- 4. the size filter still discriminates --"
mkdir -p "${DL}/tiny"
printf 'BEGIN:VCALENDAR\nEND:VCALENDAR\n' > "${DL}/tiny/empty.ics"
if _run "$DL" | /usr/bin/grep -q 'empty.ics'; then
    bad "an empty stub .ics was reported as a calendar export"
else
    ok "a sub-1k stub is still filtered out, so the count is not inflated by empties"
fi

echo "-- 5. MUTATION: restore -maxdepth 3 and head -3, and arms 1 and 2 MUST fail --"
MUT="${WORK}/runner_mutant.sh"
{
    printf 'search_dir="$1"\n'
    printf 'find "$search_dir" -maxdepth 3 -name "*.ics" -size +1k 2>/dev/null | head -3 || true\n'
} > "$MUT"
MUT_OUT="$(bash "$MUT" "$DL" 2>&1)"
MUT_N="$(printf '%s\n' "$MUT_OUT" | /usr/bin/grep -c . || true)"
if [ "${MUT_N:-0}" -gt 3 ]; then
    bad "MUTATION DID NOT APPLY: the old predicate returned ${MUT_N}, so it is not the old predicate"
else
    ok "the mutant really carries the old predicate (at most 3 results, got ${MUT_N})"
    if printf '%s' "$MUT_OUT" | /usr/bin/grep -q 'your_facebook_activity'; then
        bad "the old predicate found the depth-4 Facebook export; arm 1 is not testing the depth"
    else
        ok "MUST-FAIL: the old predicate cannot see the depth-4 export, so the depth change is load-bearing"
    fi
    if [ "${MUT_N:-0}" -lt 6 ]; then
        ok "MUST-FAIL: the old predicate returns ${MUT_N} of 6, so the cap removal is load-bearing"
    else
        bad "the old predicate returned all 6; arm 2 is not testing the cap"
    fi
fi

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
