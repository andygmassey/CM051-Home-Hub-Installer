#!/usr/bin/env bash
# probes/freshness_panel_has_dates.sh
# ============================================================================
# QUESTION: does the freshness panel report an actual date for each source, or
#           the string "unknown"?
#
# WHY IT MATTERS. Tasks #349 and #345 and #266 are the same wound seen three
# times. The panel is supposed to tell the customer how current each data
# source is. It first showed future events as "recent" (wrong clock), and after
# that was addressed it began returning "unknown" for Meetings and Contacts --
# because the Oxigraph client is closed before the dashboard queries run.
#
# "UNKNOWN" IS THE PANEL'S VERSION OF A ZERO THAT MEANS "DID NOT LOOK". It
# renders without error. It looks like a considered answer. Nothing about the
# UI distinguishes "this source has never synced" from "the query failed".
#
# The symptom was replaced, not resolved. That is exactly why this needs a
# probe rather than a fix note: a human reads "unknown" as a minor gap, and a
# probe reads it as an unanswered query.
# ============================================================================

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/probe.sh"

PROBE_NAME="freshness_panel_has_dates"
PROBE_QUESTION="does every freshness-panel source report a real date rather than 'unknown'?"

FRESHNESS_URL="${OSTLER_FRESHNESS_URL:-http://127.0.0.1:8089/doctor/api/freshness}"

# ── THE HTTP STATUS IS PART OF THE ANSWER, AND THIS PROBE IGNORED IT ─────
#
# MEASURED on the v1.0.38 box, 2026-08-21:
#
#   http://127.0.0.1:8089/doctor/api/freshness  ->  404  {"detail":"Not Found"}
#
# The old fetch discarded the status line entirely and handed the BODY to the
# adjudicator. `doc.get("sources", doc)` then fell back to the error object
# itself, saw one key -- `detail` -- whose value "Not Found" is not in the
# unknown-set, and concluded *1 source, 0 unknown* -> **PASS**.
#
# So the probe reported "every freshness source reports a real date" about an
# endpoint that does not exist. Reproduced by feeding the live body to the
# shipping adjudicator: `total=1 unknown=0`.
#
# It survived its own negative control because the self-test only ever fed it
# well-formed {"sources": ...} fixtures and never an error body. The
# adjudicator was fine. Nothing ever asked whether a response had arrived.
#
# CANNOT-RUN (2) IS THE CORRECT VERDICT FOR A 404, NOT FAIL (1). The panel is
# not reporting stale dates; it is unreachable, which is a different fact and
# has a different owner. Collapsing them is how "nothing looked" gets filed as
# "nothing found".
#
# `-w '\n%{http_code}'` puts the code on its own final line so the body stays
# byte-exact for the adjudicator.
fetch_freshness_with_code() {
    if [ "${SELF_TEST_LOCAL:-0}" -eq 1 ]; then
        printf '%s\n%s' "${FAKE_FRESHNESS:-}" "${FAKE_FRESHNESS_CODE:-200}"
        return
    fi
    box_run "curl -sS -m 8 -w '\\n%{http_code}' '$FRESHNESS_URL' 2>/dev/null"
}

# Split the combined output: last line is the status, everything before is body.
freshness_code() { printf '%s' "$1" | tail -n 1; }
freshness_body() { printf '%s' "$1" | sed '$d'; }

# Counts, over a freshness payload:
#   $1 = total source entries seen
#   $2 = entries whose value is unknown/null/empty
# Shared by run_probe and self_test so the control exercises the shipping code.
analyse_freshness() {
    printf '%s' "$1" | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
if not raw:
    print("0 0"); sys.exit(0)
try:
    doc = json.loads(raw)
except Exception:
    print("PARSE_ERROR 0"); sys.exit(0)

# Accept either {"sources": {...}} or a bare mapping, because the shape has
# moved once already and a probe that only understands one shape reports a
# false zero on the other.
src = doc.get("sources", doc) if isinstance(doc, dict) else {}
if not isinstance(src, dict):
    print("0 0"); sys.exit(0)

total = 0
unknown = 0
for _k, v in src.items():
    if isinstance(v, dict):
        v = v.get("last_updated", v.get("last_sync", v.get("date")))
    total += 1
    s = ("" if v is None else str(v)).strip().lower()
    if s in ("", "unknown", "none", "null", "never", "n/a"):
        unknown += 1
print(f"{total} {unknown}")
' 2>/dev/null
}

# ── IS THERE ANY FRESHNESS DATA AT ALL? ─────────────────────────────────
#
# A 404 on the panel endpoint is CANNOT-RUN, and that is correct -- but it is
# not ACTIONABLE, because two very different systems produce the identical
# message:
#
#   (a) nothing has ever computed freshness      -> fix the sync
#   (b) it is computed and nothing serves it     -> fix the route
#
# MEASURED on the v1.0.38 box, 2026-08-26. (b) is what is happening:
#
#   ~/.ostler/state/settling_progress.d/  4 files, each carrying started_at
#     and updated_at: calendar, contacts, messages.imessage, messages.whatsapp
#   :8089/openapi.json  57 routes advertised, exactly ONE matches
#     settl|fresh|progress|hydrat -- and it is /api/v1/hydration/status
#     (CONTROL: 7 routes contain "people", so the predicate does find things)
#   :8000  200 text/html for /api/v1/definitely-not-a-real-route-zzz, so its
#     200s on /api/v1/freshness are the SPA catch-all serving index.html, not
#     a freshness payload. A 200 from that port means nothing without a
#     content-type check.
#
# So the dates exist and no HTTP surface exposes them. This helper reports
# that, so the CANNOT-RUN says WHICH system it is looking at rather than
# leaving the reader to guess -- and it never upgrades the verdict, because
# data on disk is still not an answer about the PANEL.
settling_data_on_disk() {
    if [ "${SELF_TEST_LOCAL:-0}" -eq 1 ]; then printf '%s' "${FAKE_DISK:-0 0}"; return; fi
    box_run "python3 - <<'OSTLERDISK'
import glob, json, os
d = os.path.expanduser(\"~/.ostler/state/settling_progress.d\")
files = sorted(glob.glob(os.path.join(d, \"*.json\")))
dated = 0
for f in files:
    try:
        doc = json.load(open(f))
    except Exception:
        continue
    v = doc.get(\"updated_at\") or doc.get(\"started_at\")
    if v and str(v).strip().lower() not in (\"\", \"unknown\", \"none\", \"null\"):
        dated += 1
print(str(len(files)) + \" \" + str(dated))
OSTLERDISK"
}

run_probe() {
    if ! box_reachable; then
        probe_cannot_run "cannot reach box ${OSTLER_BOX_HOST:-(local)} over ssh; freshness panel not read"
    fi

    local raw code body
    raw="$(fetch_freshness_with_code)"
    code="$(freshness_code "$raw")"
    body="$(freshness_body "$raw")"

    # STATUS FIRST. Before any question about what the payload SAYS, settle
    # whether a payload arrived at all. A 404 body is not a freshness panel
    # with one healthy source in it -- that is what this probe used to report.
    case "$code" in
        200|"")
            ;;
        *)
            probe_examined 0 "freshness sources"
            local disk dfiles ddated verdict_extra
            disk="$(settling_data_on_disk)"
            dfiles="${disk%% *}"; ddated="${disk##* }"
            case "${dfiles:-0}" in
                ''|*[!0-9]*) verdict_extra="On-disk state could not be read either, so it is unknown whether any freshness data exists." ;;
                0)           verdict_extra="No settling_progress.d files exist either, so NOTHING has computed freshness: the fix is a sync, not a route." ;;
                *)           verdict_extra="But the data it would serve EXISTS ON DISK: ${dfiles} settling_progress.d file(s), ${ddated} carrying a real timestamp. This is an UNWIRED RENDERER, not an empty system -- the fix is a route, not a sync." ;;
            esac
            probe_cannot_run "$FRESHNESS_URL returned HTTP ${code}, not 200. The panel was never read, so this probe has NO opinion on whether its sources carry real dates. ${verdict_extra} Body: $(printf '%s' "$body" | head -c 120)"
            ;;
    esac

    if [ -z "$body" ]; then
        probe_examined 0 "freshness sources"
        probe_cannot_run "no response from $FRESHNESS_URL -- Doctor may not be running. An empty payload is NOT an empty panel."
    fi

    local counts total unknown
    counts="$(analyse_freshness "$body")"
    total="${counts%% *}"
    unknown="${counts##* }"

    if [ "$total" = "PARSE_ERROR" ]; then
        probe_examined 0 "freshness sources"
        probe_cannot_run "$FRESHNESS_URL returned something that is not JSON; cannot count sources"
    fi

    if [ "${total:-0}" -eq 0 ]; then
        probe_examined 0 "freshness sources"
        probe_cannot_run "freshness payload parsed but names 0 sources -- an installed Hub always tracks several, so this is a shape mismatch, not a clean panel"
    fi

    probe_examined "$total" "freshness sources from $FRESHNESS_URL"
    probe_note "sources reporting a real date: $((total - unknown))"
    probe_note "sources reporting unknown/empty: $unknown"

    if [ "$unknown" -gt 0 ]; then
        probe_fail "$unknown of $total freshness sources report 'unknown' rather than a date (tasks #349, #266). The panel cannot distinguish 'never synced' from 'the query failed'."
    fi

    probe_pass "all $total freshness sources report a real date"
}

self_test() {
    SELF_TEST_LOCAL=1

    # 1. The #349 shape: two sources reporting unknown. MUST be counted.
    local bad='{"sources":{"meetings":"unknown","contacts":null,"email":"2026-08-15T10:00:00Z"}}'
    local c t u
    c="$(analyse_freshness "$bad")"; t="${c%% *}"; u="${c##* }"
    probe_examined "$t" "fixture freshness sources (negative control)"

    if [ "$t" -ne 3 ]; then
        probe_fail "counter saw $t of 3 fixture sources -- the parser is wrong, so no verdict from this probe is trustworthy"
    fi
    if [ "$u" -ne 2 ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: counted $u of 2 planted 'unknown' sources. This probe cannot detect task #349."
    fi

    # 2. A wholly healthy panel must NOT be flagged.
    local good='{"sources":{"meetings":"2026-08-15","contacts":"2026-08-14","email":"2026-08-16"}}'
    c="$(analyse_freshness "$good")"; u="${c##* }"
    if [ "$u" -ne 0 ]; then
        probe_pass "NEGATIVE CONTROL OVER-FIRED: flagged $u sources on a panel where every date is real. It would fail every healthy box."
    fi

    # 3. The nested shape must parse too. A probe that understands only one
    #    payload shape returns a false zero on the other, which is the exact
    #    defect class this whole suite exists to prevent.
    local nested='{"sources":{"meetings":{"last_updated":"unknown"},"email":{"last_updated":"2026-08-16"}}}'
    c="$(analyse_freshness "$nested")"; t="${c%% *}"; u="${c##* }"
    if [ "$t" -ne 2 ] || [ "$u" -ne 1 ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: nested payload shape parsed as total=$t unknown=$u, expected 2 and 1. The probe is blind to one of the two live shapes."
    fi

    # 4. THE FALSE GREEN THAT SHIPPED. This is the limb that was missing, and
    #    its absence is why the probe reported PASS off a 404 on the v1.0.38
    #    box. Every earlier fixture was well-formed, so nothing ever asked
    #    what the adjudicator does with an ERROR body.
    #
    #    Assert the adjudicator STILL mis-reads it -- deliberately. The fix is
    #    not in analyse_freshness (which is only ever handed a body) but in
    #    run_probe checking the HTTP status first. If this limb ever stops
    #    reporting 1/0, the status guard has quietly stopped being the thing
    #    keeping the probe honest, and whoever changed it needs to know.
    local errbody='{"detail":"Not Found"}'
    c="$(analyse_freshness "$errbody")"; t="${c%% *}"; u="${c##* }"
    if [ "$t" != "1" ] || [ "$u" != "0" ]; then
        probe_pass "CONTROL PREMISE MOVED: a 404 error body now adjudicates as total=$t unknown=$u, not 1/0. The status-code guard in run_probe may no longer be the only thing preventing the false green -- re-derive before trusting this probe."
    fi

    # 5. THE THREE NEW DISK BRANCHES. Each is a distinct diagnosis and a
    #    branch with no control is a branch nobody has ever seen run. The
    #    verdict must stay CANNOT-RUN in all three -- data on disk is still
    #    not an answer about the PANEL, and an "actionable" message that
    #    quietly upgrades a CANNOT-RUN to a FAIL would be worse than the
    #    vague one it replaced.
    local out rc
    _disk_case() {
        # _disk_case <label> <FAKE_DISK> <substring the message must contain>
        out="$(SELF_TEST_LOCAL=1 FAKE_FRESHNESS='{"detail":"Not Found"}' \
               FAKE_FRESHNESS_CODE=404 FAKE_DISK="$2" run_probe 2>&1)"
        rc=$?
        if [ "$rc" -ne "$PROBE_EX_CANNOT_RUN" ]; then
            probe_pass "DISK BRANCH [$1] returned exit ${rc}, not CANNOT-RUN (${PROBE_EX_CANNOT_RUN}). Corroborating from disk must never change the verdict about the panel."
        fi
        case "$out" in
            *"$3"*) : ;;
            *) probe_pass "DISK BRANCH [$1] did not say '$3'. The message is the entire value of this branch; without it a 404 is unactionable." ;;
        esac
    }
    _disk_case "data present"    "4 4" "UNWIRED RENDERER"
    _disk_case "no data at all"  "0 0" "the fix is a sync, not a route"
    _disk_case "disk unreadable" "x x" "could not be read either"

    probe_fail "negative control behaved correctly (caught unknowns in both payload shapes, passed a healthy panel, confirmed an error body still needs the HTTP-status guard, and all three disk-corroboration branches report the right diagnosis while staying CANNOT-RUN)"
}

probe_main "$@"
