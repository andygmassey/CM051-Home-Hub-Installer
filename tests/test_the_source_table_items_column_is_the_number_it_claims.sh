#!/usr/bin/env bash
# =============================================================================
# The Doctor source table's `Items` column must be the number it claims  (#946)
# =============================================================================
#
# WHAT THIS ASSERTS, AND WHOSE EYES IT ASSERTS IT FOR
# ---------------------------------------------------
# Not "the helper returns X". The subject of every assertion below is A CELL IN
# THE RENDERED HTML TABLE a customer reads on the Doctor page, under the heading
# "Where your data came from" and the copy "how much it found". The test drives
# the REAL recorders out of install.sh, writes REAL sentinel files, runs the
# REAL vendored reader AND the REAL vendored renderer, and then reads the cells.
#
# That shape is the point. The producer side of this feature has had a green
# box-walk probe for a long time and the renderer's own docstring says why that
# proves nothing: "The Doctor must serve /api/v1/sources with one honest
# per-source row" is true whether or not a human can ever see a single one.
#
# THE DEFECT IT PINS, measured on origin/main at 9e27307c by this exact harness
# -----------------------------------------------------------------------------
# `_hydrate_payload_count` took the value after the LAST '=' in the payload and
# fell back to a literal 0. Driving the real call sites, the panel printed:
#
#   places, dedupe, privacy_backfill   payload ran=1,rc=0
#       "read in ... 0 items" for three sources that had just succeeded. The
#       0 was the RETURN CODE. The Doctor already declares rc is not a count
#       (diagnostic_rules.py _NON_COUNT_KEYS, "rc=0 is a RETURN CODE meaning
#       success, not a count of zero items"). The reader knew; the writer did
#       not, and the writer is what the panel prints.
#
#   browsing   payload sent=1500,skipped=20
#       "20 items" for a run that delivered 1,500. `skipped` counts rows
#       deliberately NOT ingested.
#
#   people, timeout arm   payload sent=unknown,collection_points=7154
#       the size of the WHOLE collection reported as this run's output, which
#       _hydrate_qdrant_points exists to prevent and says so in prose.
#
# THREE OUTCOMES, THREE EXITS
#   0  every cell says what it means
#   1  a cell states a number the run did not produce
#   2  CANNOT-RUN: the harness could not drive the real code. NOT a pass.
#
# No network, no Qdrant, no live Doctor, no real customer data. Synthetic
# payloads only, copied from the real call sites in install.sh.
# =============================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
INSTALL="${REPO}/install.sh"
WEBUI="${REPO}/vendor/doctor/agent/web_ui.py"

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad()   { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
fatal() { printf 'CANNOT-RUN: %s\n' "$1" >&2; exit 2; }

[ -f "$INSTALL" ] || fatal "no install.sh at ${INSTALL}"
[ -f "$WEBUI" ]   || fatal "no vendored web_ui.py at ${WEBUI}"
command -v python3 >/dev/null 2>&1 || fatal "python3 not on PATH; the reader half cannot run"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/itemscol-XXXXXX")" || fatal "could not make a work dir"
trap 'rm -rf "$WORK"' EXIT
HYDRATE="${WORK}/boxroot/state/hydrate"
mkdir -p "$HYDRATE" || fatal "could not make the hydrate dir"

# ---------------------------------------------------------------------------
# WRITE SIDE: the REAL recorders, extracted rather than retyped. A test that
# retypes the code under test cannot notice the code changing.
# ---------------------------------------------------------------------------
extract() {
    local body
    body="$(sed -n "/^$1() {/,/^}/p" "$INSTALL")"
    [ -n "$body" ] || fatal "$1() not found in install.sh; this test would measure nothing"
    printf '%s\n' "$body"
}
{
    printf 'set -uo pipefail\n'
    printf '_HYDRATE_SENTINEL_DIR=%q\n' "$HYDRATE"
    printf 'gui_step_record_rc() { :; }\n'
    extract _hydrate_payload_count
    extract _hydrate_compute_change
    extract _hydrate_payload_is_all_zero
    extract _hydrate_sentinel_record
    extract _hydrate_sentinel_record_error
    extract _hydrate_sentinel_record_no_data
} > "${WORK}/writer.sh"
bash -n "${WORK}/writer.sh" || fatal "the extracted recorders do not parse"
# shellcheck source=/dev/null
source "${WORK}/writer.sh" || fatal "the extracted recorders would not load"

# The payload shapes below are COPIED FROM THE REAL CALL SITES in install.sh.
# If a call site changes shape, this test should be updated with it; that is a
# deliberate cost, because the shape is the contract the panel renders.
_hydrate_sentinel_record       imessage         "people=6719"                                   # install.sh hydrate_imessage
_hydrate_sentinel_record       browsing         "sent=1500,skipped=20"                          # install.sh hydrate_browsing
_hydrate_sentinel_record       email            "people=430,messages=20114"                     # install.sh hydrate_email
_hydrate_sentinel_record       places           "ran=1,rc=0"                                    # install.sh places sweep
_hydrate_sentinel_record       dedupe           "ran=1,rc=0"                                    # install.sh dedupe sweep
_hydrate_sentinel_record       privacy_backfill "ran=1,rc=0"                                    # install.sh privacy backfill
_hydrate_sentinel_record_error people 124       "sent=unknown,collection_points=7154"           # install.sh people timeout arm
_hydrate_sentinel_record_no_data whatsapp       "no_app"                                        # install.sh whatsapp, looked and found nothing

for s in imessage browsing email places dedupe privacy_backfill people whatsapp; do
    [ -f "${HYDRATE}/${s}.done" ] || fatal "the recorder wrote no sentinel for ${s}; the harness did not drive the writer"
done

# ---------------------------------------------------------------------------
# READ + RENDER SIDE: the REAL vendored reader and the REAL vendored renderer.
# web_ui.py cannot simply be imported (fastapi is not installed on every
# runner), so the two blocks are lifted out of the shipped file and executed.
# Lifting is not copying: the bytes come from the file that ships.
# ---------------------------------------------------------------------------
CELLS="${WORK}/cells.txt"
OSTLER_HOME="${WORK}/boxroot" python3 - "$WEBUI" > "$CELLS" <<'PY'
import html, re, sys
from pathlib import Path

src = Path(sys.argv[1]).read_text(encoding="utf-8")


def block(start_marker, end_marker, what):
    try:
        a = src.index(start_marker)
        b = src.index(end_marker)
    except ValueError:
        print(f"CANNOT-RUN: could not locate {what} in web_ui.py", file=sys.stderr)
        sys.exit(2)
    if b <= a:
        print(f"CANNOT-RUN: {what} markers are out of order in web_ui.py", file=sys.stderr)
        sys.exit(2)
    return src[a:b]


reader = block("_SOURCE_KINDS = {", '@app.get("/api/v1/sources"', "the reader block")
render = block("def render_source_status() -> str:", "def render_dashboard(", "the renderer")

ns = {"html": html}
try:
    exec("from pathlib import Path\nimport os, json\n" + reader, ns)   # noqa: S102
    exec(render, ns)                                                   # noqa: S102
except Exception as exc:                                               # noqa: BLE001
    print(f"CANNOT-RUN: shipped reader/renderer would not execute "
          f"({type(exc).__name__}: {exc})", file=sys.stderr)
    sys.exit(2)

try:
    page = ns["render_source_status"]()
except Exception as exc:                                               # noqa: BLE001
    print(f"CANNOT-RUN: render_source_status() raised "
          f"({type(exc).__name__}: {exc})", file=sys.stderr)
    sys.exit(2)

rows = 0
for tr in re.findall(r"<tr>(.*?)</tr>", page, re.S):
    tds = re.findall(r"<td[^>]*>(.*?)</td>", tr, re.S)
    if len(tds) < 4:
        continue                      # the header row carries <th>, not <td>
    plain = [re.sub(r"<[^>]+>", "", c).strip() for c in tds]
    rows += 1
    # source <TAB> status <TAB> items-cell, exactly as rendered
    print(f"{plain[0]}\t{plain[1]}\t{plain[2]}")

if rows == 0:
    print("CANNOT-RUN: the renderer produced no data rows at all", file=sys.stderr)
    sys.exit(2)
PY
RC=$?
[ "$RC" -eq 2 ] && fatal "the shipped reader/renderer could not be driven (see stderr above)"
[ "$RC" -eq 0 ] || fatal "the render harness exited ${RC}"

# HARNESS CONTROL. A predicate that reads an empty corpus passes everything.
N_ROWS="$(grep -c . "$CELLS" || true)"
[ "${N_ROWS:-0}" -ge 13 ] \
    || fatal "the renderer produced ${N_ROWS} rows, expected every canonical source; the harness is not reading the real panel"

printf '\n== the rendered Items column ==\n'
sed 's/^/  /' "$CELLS"
printf '\n== assertions ==\n'

# `items <source>` echoes the Items cell exactly as the customer sees it.
items() { awk -F'\t' -v s="$1" '$1 == s { print $3 }' "$CELLS"; }
UNKNOWN='&mdash;'     # the renderer's own marker for "no number to show"

# --- A: a payload with no count key must not state a measured zero ----------
for s in places dedupe "privacy backfill"; do
    v="$(items "$s")"
    if [ -z "$v" ]; then
        bad "A  ${s}: no row rendered at all"
    elif [ "$v" = "0" ]; then
        bad "A  ${s}: the panel says '0 items' for payload ran=1,rc=0. That 0 is the RETURN CODE, and the customer reads it as 'ran and found nothing'."
    elif [ "$v" = "$UNKNOWN" ]; then
        ok  "A  ${s}: no count in the payload, so the panel shows unknown rather than a fabricated 0"
    else
        bad "A  ${s}: the panel says '${v}' for payload ran=1,rc=0; nothing in that payload is an item count"
    fi
done

# --- B: the delivered count wins over the skipped count ---------------------
V="$(items browsing)"
case "$V" in
    "1,500") ok  "B  browsing: sent=1500,skipped=20 renders 1,500 (what landed), not the skipped count" ;;
    "20")    bad "B  browsing: renders 20, which is the SKIPPED count. The run delivered 1,500." ;;
    *)       bad "B  browsing: renders '${V}'; expected the delivered count 1,500" ;;
esac

# --- C: the whole store is not this run's output ----------------------------
V="$(items people)"
case "$V" in
    "7,154") bad "C  people: renders 7,154, the size of the WHOLE collection, as the output of a run that measured nothing. _hydrate_qdrant_points exists to keep those apart." ;;
    "$UNKNOWN") ok "C  people: a timed-out run that measured nothing shows unknown, not the collection size" ;;
    *)       bad "C  people: renders '${V}'; a run with sent=unknown has no item count to show" ;;
esac

# --- D: POSITIVE CONTROL. A real count must still reach the page ------------
# This is the control that catches the opposite over-reach, and it is not
# hypothetical: a first draft of the fix put its key list at file scope, the
# extraction-based harnesses lost it, and ALL THIRTEEN rows went blank. A guard
# that only checks for absent numbers would have called that a pass.
V="$(items imessage)"
case "$V" in
    "6,719") ok  "D  positive control: imessage people=6719 still renders 6,719; real counts are not being blanked" ;;
    *)       bad "D  positive control FAILED: imessage renders '${V}', expected 6,719. The count path is broken, so every other assertion here is meaningless." ;;
esac

# --- E: POSITIVE CONTROL. The change stays scoped to non-count keys ---------
# email writes people=N,messages=M and must keep reporting MESSAGES.
# tests/test_email_settling_numerator_is_messages.sh settled that unit after a
# people count in an email-unit fraction shipped as a defect.
V="$(items email)"
case "$V" in
    "20,114") ok  "E  positive control: email keeps its MESSAGE count (20,114); the fix did not repopulate it with people" ;;
    "430")    bad "E  email now renders 430, a PEOPLE count, in a column the settling-numerator decision says is messages" ;;
    *)        bad "E  email renders '${V}'; expected the message count 20,114" ;;
esac

# --- F: POSITIVE CONTROL. A measured zero must still print as zero ----------
# "we looked and there was nothing" and "the payload carried no count" are
# different facts. The fix must not collapse the first into the second.
V="$(items whatsapp)"
case "$V" in
    "0")        ok  "F  positive control: a looked-and-found-nothing source still prints 0, not unknown" ;;
    "$UNKNOWN") bad "F  whatsapp: a MEASURED zero now prints as unknown. The fix has over-reached: 'found nothing' is a real answer." ;;
    *)          bad "F  whatsapp: renders '${V}'; a no_data source has a measured count of 0" ;;
esac

printf '\nCONCLUSION HISTOGRAM\n  PASS : %d\n  FAIL : %d\n  TOTAL: %d\n' \
    "$PASS" "$FAIL" "$((PASS+FAIL))"
[ "$((PASS+FAIL))" -ge 8 ] || fatal "only $((PASS+FAIL)) assertions ran; the harness is not exercising the panel"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
