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

# Split the combined output: last line is the status, everything before is body.

# Counts, over a freshness payload:
#   $1 = total source entries seen
#   $2 = entries whose value is unknown/null/empty
# Shared by run_probe and self_test so the control exercises the shipping code.

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

# ── THE SURFACE MOVED, AND THIS PROBE WAS WAITING ON ONE THAT NEVER SHIPS ──
#
# MEASURED 2026-08-27 on the live box: the API at :8089 serves 57 routes and
# NONE of them is /doctor/api/freshness. /doctor/api/status, /health,
# /diagnostics and /history all 200 and all carry system diagnostics --
# containers, models, services, disk -- not a per-source date.
#
# So the old CANNOT-RUN was correct about the 404 and wrong about what it
# implied. It read as "the route is not up yet". The route is not coming. A row
# that can only ever return CANNOT-RUN never clears and never says why.
#
# THE PANEL THE CUSTOMER ACTUALLY SEES is compiled markdown, in the wiki:
#
#   ~/Documents/Ostler/Wiki/index.md
#     ## Data freshness
#     | Meetings      | <span class="pw-status pw-status--ok">26 August 2026</span> |
#     | Contact       | <span class="pw-status pw-status--ok">26 August 2026</span> |
#     | Wiki compiled | <span class="pw-status pw-status--ok">26 August 2026</span> |
#
# THREE ROWS. THE BOX INGESTS FOUR FILES ACROSS THREE KEYS:
#
#   ~/.ostler/state/settling_progress.d/
#     calendar.json           key=calendar   updated 2026-08-27T05:18:05Z
#     contacts.json           key=contacts   updated 2026-08-25T08:10:29Z
#     messages.imessage.json  key=messages   updated 2026-08-27T05:18:04Z   28538 records
#     messages.whatsapp.json  key=messages   updated 2026-08-27T05:18:04Z  158155 records
#
# `messages` has no row. 186,693 records, the largest source on the box by two
# orders of magnitude, and the panel that reports currency does not mention it.
#
# WHICH IS WHY THE PREDICATE IS COVERAGE, NOT FORMAT. "Does every row carry a
# real date" PASSES on this box today -- all three present rows are dated. It
# would pass while the biggest source is invisible. The header above already
# warns that "unknown" is the panel's version of a zero meaning "did not look";
# AN ABSENT ROW IS A ZERO THAT DOES NOT EVEN PRINT.
#
# WHY THIS STILL CANNOT-RUNs TODAY, AND WHY THAT IS NOT THE SAME CANNOT-RUN.
# Identifying a row needs the source KEY. The panel renders only a LOCALISED
# label (`_locale.term("source_" + key)`), so matching English words here would
# be a predicate scoped to one locale, silently returning "absent" on a box that
# ships another. CM044 #227 adds the per-source table; CM044 #259 asks it to
# carry `data-source="<key>"`, which is the unlocalised key already in hand at
# that line. The moment either lands, this probe gives a real verdict.
# Until then it names its blocker and reports what it CAN see, which is a
# different act from waiting on a phantom route.
#
# Deliberately NOT done: reverse-mapping locale terms back to keys. That is the
# convention-scoped predicate this codebase has been bitten by before, and it
# would fail CLOSED into a false pass -- an unmatched label reads as "no such
# source", which is indistinguishable from "covered".
panel_and_ingest() {
    if [ "${SELF_TEST_LOCAL:-0}" -eq 1 ]; then printf '%s' "${FAKE_PANEL:-}"; return; fi
    box_run "python3 - <<'OSTLERPANEL'
import glob, json, os

state = os.path.expanduser('~/.ostler/state/settling_progress.d')
files = sorted(glob.glob(os.path.join(state, '*.json')))
keys, dated = set(), 0
for f in files:
    try:
        doc = json.load(open(f))
    except Exception:
        continue
    k = doc.get('key')
    if k:
        keys.add(str(k))
    v = doc.get('updated_at') or doc.get('started_at')
    if v and str(v).strip().lower() not in ('', 'unknown', 'none', 'null'):
        dated += 1

wiki = os.path.expanduser('~/Documents/Ostler/Wiki/index.md')
found = os.path.exists(wiki)
text = ''
if found:
    try:
        text = open(wiki, encoding='utf-8', errors='replace').read()
    except Exception:
        found = False

# Machine-readable rows. No regex: single string ops only, so nothing here
# depends on shell or python escaping surviving three levels of quoting.
pairs = []
for seg in text.split('<tr ')[1:]:
    seg = seg.split('</tr>')[0]
    cls = seg.split('class=\"', 1)[1].split('\"', 1)[0] if 'class=\"' in seg else ''
    if 'pwg-source' not in cls:
        continue
    if 'data-source=\"' not in seg:
        continue
    key = seg.split('data-source=\"', 1)[1].split('\"', 1)[0]
    status = ''
    for tok in cls.split():
        if tok.startswith('pwg-source--'):
            status = tok[len('pwg-source--'):]
    pairs.append(key + ':' + (status or 'nostatus'))

# The legacy table, counted locale-independently via its status class.
legacy = len([l for l in text.splitlines()
              if l.startswith('|') and 'pw-status--' in l])

print('PANEL_FOUND=' + ('1' if found else '0'))
print('INGEST_FILES=' + str(len(files)))
print('INGEST_DATED=' + str(dated))
print('INGEST_KEYS=' + ','.join(sorted(keys)))
print('DS_ROWS=' + ','.join(pairs))
print('LEGACY_ROWS=' + str(legacy))
OSTLERPANEL"
}

field() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }
run_probe() {
    if ! box_reachable; then
        probe_cannot_run "cannot reach box ${OSTLER_BOX_HOST:-(local)} over ssh; freshness panel not read"
    fi

    local raw found ifiles idated ikeys dsrows legacy
    raw="$(panel_and_ingest)"

    if [ -z "$raw" ]; then
        probe_examined 0 "freshness sources"
        probe_cannot_run "the panel collector returned nothing at all. That is the collector failing, not an empty panel -- an empty answer and a broken reader print identically and this probe refuses to call it either way."
    fi

    found="$(field "$raw" PANEL_FOUND)"
    ifiles="$(field "$raw" INGEST_FILES)"
    idated="$(field "$raw" INGEST_DATED)"
    ikeys="$(field "$raw" INGEST_KEYS)"
    dsrows="$(field "$raw" DS_ROWS)"
    legacy="$(field "$raw" LEGACY_ROWS)"

    case "${ifiles:-x}" in ''|*[!0-9]*)
        probe_examined 0 "freshness sources"
        probe_cannot_run "could not read ~/.ostler/state/settling_progress.d, so the set of sources this box ingests is unknown. Without a denominator there is nothing to check coverage against."
    ;; esac

    if [ "$found" != "1" ]; then
        probe_examined 0 "freshness sources"
        probe_cannot_run "the compiled wiki index (~/Documents/Ostler/Wiki/index.md) is not present, so the panel the customer reads was never opened. ${ifiles} settling_progress.d file(s) exist, ${idated} carrying a real timestamp -- the data is there, the rendered panel is not."
    fi

    if [ "${ifiles}" = "0" ]; then
        probe_examined 0 "freshness sources"
        probe_cannot_run "no settling_progress.d files exist, so NOTHING on this box has computed freshness. There is no coverage question to answer yet: the fix is a sync, not a panel."
    fi

    # ── The per-source table with machine-readable keys is the only surface
    # that can answer the question. Its absence is reported as a NAMED blocker,
    # never as a pass, and never by guessing at localised labels.
    if [ -z "$dsrows" ]; then
        probe_examined 0 "identifiable freshness rows"
        probe_note "sources this box ingests: ${ikeys:-(none)} (${ifiles} file(s), ${idated} timestamped)"
        probe_note "legacy '## Data freshness' rows visible: ${legacy:-0} (counted by status class, not by label, so this holds in any locale)"
        probe_cannot_run "the panel carries no row with a machine-readable data-source key, so no row can be attributed to a source. This probe has NO opinion on coverage. Blocked on CM044 #227 (per-source freshness table) and CM044 #259 (emit data-source on the row). NOT a phantom route: the legacy table renders ${legacy:-0} row(s) right now and this box ingests ${ifiles} file(s) across keys [${ikeys:-none}] -- the numbers are visible, the attribution is not."
    fi

    # ── Coverage. Every ingested key must have a row, and that row must carry
    # a state that means a date was actually established.
    local missing="" bad="" nrows=0 k st
    local IFS_SAVE="$IFS"
    IFS=','
    for k in ${ikeys}; do
        [ -n "$k" ] || continue
        st=""
        local pair
        for pair in ${dsrows}; do
            case "$pair" in "${k}:"*) st="${pair#*:}" ;; esac
        done
        if [ -z "$st" ]; then
            missing="${missing}${missing:+ }${k}"
        else
            case "$st" in
                never|unknown|nostatus) bad="${bad}${bad:+ }${k}(${st})" ;;
            esac
        fi
    done
    for pair in ${dsrows}; do [ -n "$pair" ] && nrows=$((nrows + 1)); done
    IFS="$IFS_SAVE"

    probe_examined "$nrows" "identifiable freshness rows against ${ifiles} ingested source file(s)"
    probe_note "sources ingested: ${ikeys}"
    probe_note "rows on the panel: ${dsrows}"

    if [ -n "$missing" ]; then
        probe_fail "the freshness panel has NO ROW for: ${missing}. An absent row is not a neutral omission -- the customer is shown a currency report that silently excludes a source they are relying on. Ingested keys [${ikeys}] vs panel rows [${dsrows}]."
    fi
    if [ -n "$bad" ]; then
        probe_fail "row(s) present but carrying no established date: ${bad}. 'never' and 'unknown' are the panel's way of saying it did not look, and they render as though they were an answer (tasks #349, #266)."
    fi
    probe_pass "every ingested source [${ikeys}] has a freshness row with an established date"
}
# ── SELF-TEST ────────────────────────────────────────────────────────────
# Convention: this exits FAIL when healthy. A self-test that exits 0 is
# reporting that one of its own controls did not behave, which is the only
# thing worse than a failing probe -- a probe that cannot go red.
#
# The case that matters most is CASE 2. The panel on the live box today has
# three dated rows and is missing `messages`. A format-checking probe passes
# that. This asserts it FAILS, so the predicate is proved to be coverage.
_F8_OK=0
_f8_case() {
    local label="$1" payload="$2" want="$3"
    local out rc got
    out="$(SELF_TEST_LOCAL=1 FAKE_PANEL="$payload" run_probe 2>&1)"; rc=$?
    case "$rc" in
        0)  got=PASS ;;
        1)  got=FAIL ;;
        78) got=CANNOT-RUN ;;
        *)  got="rc${rc}" ;;
    esac
    if [ "$got" != "$want" ]; then
        probe_pass "NEGATIVE CONTROL MISFIRED on [${label}]: expected ${want}, got ${got}. No verdict from this probe is trustworthy until that is understood. Output: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
    fi
    _F8_OK=$((_F8_OK + 1))
}

self_test() {
    SELF_TEST_LOCAL=1
    # ONE literal, used by the announcement AND the drift check AND the
    # message. Three copies of a number is three chances to disagree.
    _F8_DECLARED=9
    probe_examined "$_F8_DECLARED" "synthetic panel/ingest fixtures (negative control)"

    local healthy missing never_state nostatus norows nopanel noingest unreadable

    healthy="$(printf '%s\n' 'PANEL_FOUND=1' 'INGEST_FILES=4' 'INGEST_DATED=4' \
        'INGEST_KEYS=calendar,contacts,messages' \
        'DS_ROWS=calendar:ok,contacts:ok,messages:ok' 'LEGACY_ROWS=3')"

    # The live box, once #227/#259 land and messages is STILL not rendered.
    missing="$(printf '%s\n' 'PANEL_FOUND=1' 'INGEST_FILES=4' 'INGEST_DATED=4' \
        'INGEST_KEYS=calendar,contacts,messages' \
        'DS_ROWS=calendar:ok,contacts:ok' 'LEGACY_ROWS=3')"

    never_state="$(printf '%s\n' 'PANEL_FOUND=1' 'INGEST_FILES=4' 'INGEST_DATED=4' \
        'INGEST_KEYS=calendar,contacts,messages' \
        'DS_ROWS=calendar:ok,contacts:ok,messages:never' 'LEGACY_ROWS=3')"

    nostatus="$(printf '%s\n' 'PANEL_FOUND=1' 'INGEST_FILES=4' 'INGEST_DATED=4' \
        'INGEST_KEYS=calendar,contacts,messages' \
        'DS_ROWS=calendar:ok,contacts:ok,messages:nostatus' 'LEGACY_ROWS=3')"

    # TODAY. Legacy table renders, nothing is attributable.
    norows="$(printf '%s\n' 'PANEL_FOUND=1' 'INGEST_FILES=4' 'INGEST_DATED=4' \
        'INGEST_KEYS=calendar,contacts,messages' 'DS_ROWS=' 'LEGACY_ROWS=3')"

    nopanel="$(printf '%s\n' 'PANEL_FOUND=0' 'INGEST_FILES=4' 'INGEST_DATED=4' \
        'INGEST_KEYS=calendar,contacts,messages' 'DS_ROWS=' 'LEGACY_ROWS=0')"

    noingest="$(printf '%s\n' 'PANEL_FOUND=1' 'INGEST_FILES=0' 'INGEST_DATED=0' \
        'INGEST_KEYS=' 'DS_ROWS=' 'LEGACY_ROWS=0')"

    unreadable="$(printf '%s\n' 'PANEL_FOUND=1' 'INGEST_FILES=' 'INGEST_DATED=' \
        'INGEST_KEYS=' 'DS_ROWS=' 'LEGACY_ROWS=0')"

    _f8_case "every source covered and dated"          "$healthy"     PASS
    _f8_case "messages ingested but ABSENT from panel" "$missing"     FAIL
    _f8_case "messages row present but state=never"    "$never_state" FAIL
    _f8_case "row present with no status class"        "$nostatus"    FAIL
    _f8_case "no attributable rows (today's box)"      "$norows"      CANNOT-RUN
    _f8_case "compiled wiki index absent"              "$nopanel"     CANNOT-RUN
    _f8_case "nothing has computed freshness"          "$noingest"    CANNOT-RUN
    _f8_case "settling dir unreadable"                 "$unreadable"  CANNOT-RUN
    _f8_case "collector returned nothing"              ""             CANNOT-RUN

    # A control that cannot tell the healthy fixture from the broken one proves
    # nothing, however many cases it ran. Assert the two differ in VERDICT, not
    # merely that each matched its own expectation.
    local h m hrc mrc
    h="$(SELF_TEST_LOCAL=1 FAKE_PANEL="$healthy" run_probe 2>&1)"; hrc=$?
    m="$(SELF_TEST_LOCAL=1 FAKE_PANEL="$missing" run_probe 2>&1)"; mrc=$?
    if [ "$hrc" = "$mrc" ]; then
        probe_pass "CONTROL IS BLIND: the covered fixture and the one missing an entire source both exit ${hrc}. The coverage predicate is not discriminating and this probe would pass the very defect it exists to catch."
    fi

    # The denominator printed at the top is a literal, and _F8_OK is what
    # actually ran. If someone adds a case and forgets the literal, EXAMINED
    # would under-report the work -- a denominator that drifts is exactly the
    # thing this suite exists to stop, and it must not be this file that does it.
    if [ "$_F8_OK" != "$_F8_DECLARED" ]; then
        probe_pass "DENOMINATOR DRIFTED: EXAMINED announced ${_F8_DECLARED} cases, ${_F8_OK} ran. Fix the literal in self_test before trusting any count this probe prints."
    fi

    probe_fail "negative control behaved correctly on all ${_F8_OK} cases: absent source, undated row, unattributable panel, missing index and dead collector each drive their own verdict, and covered-vs-missing exit differently (${hrc} vs ${mrc})"
}

probe_main "$@"
