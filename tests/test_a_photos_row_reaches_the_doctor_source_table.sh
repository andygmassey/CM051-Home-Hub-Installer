#!/usr/bin/env bash
# Row #1587. A CUSTOMER MUST BE ABLE TO SEE THAT PHOTOS AND REMINDERS RAN.
#
# THE SUBJECT OF EVERY ASSERTION HERE IS A PERSON LOOKING AT A TABLE. Not a
# string in install.sh, not a name in a list. This runs the WRITER (install.sh's
# own recorders, extracted at run time) and then the READER (the vendored
# Doctor's own read_source_status, executed from the shipped file) and asserts
# that a row for Photos and a row for Reminders come out the other end with the
# counts the extractor reported.
#
# WHAT WAS WRONG. The Doctor source table is built from the hydrate sentinels.
# install.sh declared 13 sentinel sources and neither photos nor reminders was
# among them, and no recorder call site named either, so neither could appear in
# that table AT ALL. Meanwhile vendor/ostler_fda/photos_metadata.py,
# vendor/ostler_fda/reminders.py, vendor/cm041/contact_syncer/backfill_photos.py
# and vendor/cm048_pipeline/src/reminders_push.py all ship. A customer could
# enable them, have them run, and never see them on the one surface built to
# tell them what ran.
#
# THREE STATES: 0 pass, 1 fail, 2 cannot-run. CANNOT-RUN exits non-zero and is
# never reported as a pass.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${REPO}/install.sh"
WEBUI="${REPO}/vendor/doctor/agent/web_ui.py"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
cant() { printf 'CANNOT-RUN: %s\n' "$1" >&2; exit 2; }

[ -r "$SUBJECT" ] || cant "install.sh not readable at ${SUBJECT}"
[ -r "$WEBUI" ]   || cant "vendored web_ui.py not readable at ${WEBUI}"
grep -q 'def read_source_status' "$WEBUI" || cant "read_source_status() is absent; the reader half is gone"
command -v python3 >/dev/null 2>&1 || cant "no python3; the extract summary cannot be parsed"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/src1587-XXXXXX")" || cant "mktemp"
trap 'rm -rf "$WORK"' EXIT

# ── EXTRACT THE REAL WRITER ──────────────────────────────────────────────
extract_fn() {
    local body; body="$(sed -n "/^$1() {/,/^}/p" "$SUBJECT")"
    [ -n "$body" ] || cant "$1() not found in install.sh"
    printf '%s\n' "$body"
}
SURFACE_BLOCK="$(awk '
  /^_fda_summary="\$\{OSTLER_DIR\}\/imports\/fda\/extraction_summary\.json"$/ { f=1 }
  f { print }
  f && /^      _fda_reminders_outcome _fda_reminders_detail$/ { exit }' "$SUBJECT")"
sb_lines="$(printf '%s\n' "$SURFACE_BLOCK" | grep -c . || true)"
printf 'EXAMINED: %s lines of the FDA source-surfacing block, extracted from %s\n' "$sb_lines" "$SUBJECT"
# 🔴 AN ABSENT BLOCK IS A FAIL, NOT A CANNOT-RUN, and the difference was
# measured: reverting install.sh to its pre-fix state extracts 0 lines, and a
# refusal there would report "could not look" about the exact state this file
# exists to catch. install.sh being unreadable IS a cannot-run and is handled
# at the top. A readable install.sh with no surfacing block is a measurement,
# and the answer below is that the customer has no Photos row.
#
# The block is replaced with a no-op so every arm still runs against the real
# reader, which is what turns "the writer is missing" into the consumer-side
# consequence rather than a note about a file.
if [ "${sb_lines:-0}" -lt 25 ]; then
    bad "install.sh carries no FDA source-surfacing block (${sb_lines} lines extracted). Nothing writes a photos or reminders sentinel."
    SURFACE_BLOCK=":"
fi

WRITER="${WORK}/writer.sh"
{
    printf '%s\n' 'gui_step_record_rc() { :; }'
    extract_fn _hydrate_payload_count
    extract_fn _hydrate_payload_is_all_zero
    extract_fn _hydrate_compute_change
    extract_fn _hydrate_sentinel_record
    extract_fn _hydrate_sentinel_record_error
    extract_fn _hydrate_sentinel_record_no_data
    extract_fn _hydrate_sentinel_record_cannot_run
} > "$WRITER"

# ── THE HARNESS ──────────────────────────────────────────────────────────
# $1 the extraction_summary.json body ("" = the file is absent entirely)
# $2 the surfacing block to run (the real one, or a mutant)
# Prints the sentinel directory it produced, on the last line.
run_install_half() {
    local summary="$1" block="$2"
    local d; d="$(mktemp -d "${WORK}/run-XXXXXX")"
    mkdir -p "${d}/ostler/imports/fda" "${d}/ostler/state/hydrate" "${d}/diag"
    [ -n "$summary" ] && printf '%s' "$summary" > "${d}/ostler/imports/fda/extraction_summary.json"
    {
        printf '%s\n' 'set -uo pipefail'
        printf 'OSTLER_DIR=%q\n' "${d}/ostler"
        printf 'OSTLER_DIAG_DIR=%q\n' "${d}/diag"
        printf '_HYDRATE_SENTINEL_DIR=%q\n' "${d}/ostler/state/hydrate"
        printf 'OSTLER_PYTHON=%q\n' "$(command -v python3)"
        cat "$WRITER"
        printf '%s\n' "$block"
    } > "${d}/run.sh"
    bash "${d}/run.sh" >"${d}/run.out" 2>&1
    printf '%s\n' "${d}/ostler/state/hydrate"
}

# ── THE REAL READER, EXECUTED FROM THE SHIPPED FILE ──────────────────────
# Sliced out rather than imported: web_ui.py builds a FastAPI app at module
# scope, which is not installable here, and a re-implementation of the reader
# would prove only that this test agrees with itself.
read_rows() {
    python3 - "$WEBUI" "$1" <<'PY'
import sys
from pathlib import Path
src = open(sys.argv[1]).read()
try:
    start = src.index("_SOURCE_KINDS = {")
    end = src.index('@app.get("/api/v1/sources"')
except ValueError:
    print("READER_CANNOT_RUN")
    raise SystemExit(0)
ns = {}
exec("from pathlib import Path\nimport os\n" + src[start:end], ns)
for r in ns["read_source_status"](Path(sys.argv[2]), Path(sys.argv[2]) / "_no_activity"):
    print("%s|%s|%s|%s" % (r["source"], r["status"], r["item_count"], r["detail"]))
PY
}

SUMMARY_OK='{"sources": {
  "photos":    {"status": "ok", "faces_enabled": false, "recognised_people": 0, "photo_events": 12},
  "reminders": {"status": "ok", "total_reminders": 7, "pending": 3, "completed": 4},
  "calendar":  {"status": "ok", "events": 40}
}}'

echo
echo "== the customer opens the source table and Photos is on it =="
H="$(run_install_half "$SUMMARY_OK" "$SURFACE_BLOCK" | tail -1)"
ROWS="$(read_rows "$H")"
printf '%s' "$ROWS" | grep -q '^READER_CANNOT_RUN$' && cant "could not slice the reader out of web_ui.py"
N_ROWS="$(printf '%s\n' "$ROWS" | grep -c . || true)"
echo "  EXAMINED: ${N_ROWS} row(s) returned by the shipped reader"
[ "${N_ROWS:-0}" -ge 10 ] || cant "the reader returned ${N_ROWS} rows; it is not being driven"

printf '%s\n' "$ROWS" | grep -q '^photos|' \
  && ok  "(1) a Photos row EXISTS in the table the customer reads" \
  || bad "(1) there is still no Photos row: $(printf '%s\n' "$ROWS" | cut -d'|' -f1 | tr '\n' ' ')"
printf '%s\n' "$ROWS" | grep -q '^photos|ok|12|' \
  && ok  "(2) and it says ok with the 12 photo events the extractor reported" \
  || bad "(2) the Photos row does not carry the extractor's count: $(printf '%s\n' "$ROWS" | grep '^photos|')"
printf '%s\n' "$ROWS" | grep -q '^reminders|ok|7|' \
  && ok  "(3) a Reminders row says ok with the 7 reminders the extractor reported" \
  || bad "(3) the Reminders row is wrong or absent: $(printf '%s\n' "$ROWS" | grep '^reminders|')"

# POSITIVE CONTROL, SAME SHAPE, SAME CORPUS. calendar is a source that already
# worked before this change. If it were absent too, arms 1 to 3 would be
# measuring a broken reader rather than a fixed writer.
printf '%s\n' "$ROWS" | grep -q '^calendar|' \
  && ok  "(4) POSITIVE CONTROL: the known-good calendar row is in the same output, so the reader is live" \
  || bad "(4) CONTROL BROKEN: even calendar has no row; this is a reader failure, not a Photos one"

echo
echo "== the rows a customer must NOT be given =="
H2="$(run_install_half '{"sources": {"photos": {"status": "disabled_by_user"}, "reminders": {"status": "disabled_by_user"}}}' "$SURFACE_BLOCK" | tail -1)"
R2="$(read_rows "$H2")"
printf '%s\n' "$R2" | grep -q '^photos|not_run|' \
  && ok  "(5) a customer who turned Photos OFF gets not_run, not a fabricated ok" \
  || bad "(5) a source the customer declined was reported as something else: $(printf '%s\n' "$R2" | grep '^photos|')"
[ ! -f "${H2}/photos.done" ] \
  && ok  "(6) NEGATIVE CONTROL: no sentinel is written when the customer declined, so arms 1 to 3 measured a real write" \
  || bad "(6) a sentinel was written unconditionally, so arms 1 to 3 prove nothing about the summary being read"

H3="$(run_install_half '{"sources": {"photos": {"status": "no_fda"}, "reminders": {"status": "not_found"}}}' "$SURFACE_BLOCK" | tail -1)"
R3="$(read_rows "$H3")"
printf '%s\n' "$R3" | grep -q '^photos|cannot_run|' \
  && ok  "(7) Full Disk Access refused reads as cannot_run, not as \"looked and found nothing\"" \
  || bad "(7) a permission refusal was reported as data: $(printf '%s\n' "$R3" | grep '^photos|')"
printf '%s\n' "$R3" | grep -q '^reminders|no_data|' \
  && ok  "(8) no Reminders database on this Mac reads as no_data, which is a healthy outcome" \
  || bad "(8) an absent database was reported as a failure: $(printf '%s\n' "$R3" | grep '^reminders|')"

H4="$(run_install_half '' "$SURFACE_BLOCK" | tail -1)"
R4="$(read_rows "$H4")"
printf '%s\n' "$R4" | grep -q '^photos|cannot_run|' \
  && ok  "(9) an extract that never produced a summary reads as cannot_run, so the row still exists and says so" \
  || bad "(9) a crashed extract left the customer with no honest row: $(printf '%s\n' "$R4" | grep '^photos|')"

echo
echo "== MUTATIONS: each must PROVE IT APPLIED before its assertion is scored =="

# M1: the pre-fix world for the READER. Remove photos from _SOURCE_KINDS and
# re-run the SAME sentinels through it.
MUT_WEBUI="${WORK}/web_ui_mutant.py"
sed 's/^    "photos": "source",$//' "$WEBUI" > "$MUT_WEBUI"
if cmp -s "$WEBUI" "$MUT_WEBUI"; then
    bad "(M1) MUTANT DID NOT APPLY. The photos entry was not found in _SOURCE_KINDS"
else
    ok "(M1a) mutant applied: _SOURCE_KINDS no longer carries photos"
    SAVED="$WEBUI"; WEBUI="$MUT_WEBUI"
    RM="$(read_rows "$H")"
    WEBUI="$SAVED"
    printf '%s\n' "$RM" | grep -q '^photos|' \
      && bad "(M1b) the row appeared without the reader entry, so arm (1) is not measuring the reader" \
      || ok  "(M1b) PRE-FIX READER IS CAUGHT: with no _SOURCE_KINDS entry there is no Photos row, whatever the writer wrote"
fi

# M2: the pre-fix world for the WRITER. Remove the photos recorder dispatch.
M2="$(printf '%s\n' "$SURFACE_BLOCK" | awk '
  /^case "\$_fda_photos_outcome" in$/ { drop=1 }
  drop && /^esac$/ { drop=0; next }
  !drop { print }')"
if [ "$M2" = "$SURFACE_BLOCK" ]; then
    bad "(M2) MUTANT DID NOT APPLY. The photos dispatch was not found in the surfacing block"
else
    ok "(M2a) mutant applied: the photos dispatch is gone ($(printf '%s\n' "$SURFACE_BLOCK" | grep -c .) lines to $(printf '%s\n' "$M2" | grep -c .))"
    HM="$(run_install_half "$SUMMARY_OK" "$M2" | tail -1)"
    RM2="$(read_rows "$HM")"
    printf '%s\n' "$RM2" | grep -q '^photos|ok|' \
      && bad "(M2b) the row still said ok with no writer, so arm (2) is not measuring the writer" \
      || ok  "(M2b) PRE-FIX WRITER IS CAUGHT: with no recorder the Photos row can only say not_run"
    printf '%s\n' "$RM2" | grep -q '^reminders|ok|7|' \
      && ok  "(M2c) and Reminders is unaffected, so the mutation was surgical rather than a blanket break" \
      || bad "(M2c) removing the photos dispatch also broke reminders; M2b proves less than it appears to"
fi

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
