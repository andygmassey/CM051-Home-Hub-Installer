#!/usr/bin/env bash
#
# tests/test_calendar_review_is_one_screen.sh
#
# Drives install.sh's OWN end-of-install calendar block (the region between
# "# ---- 1. Calendar owner/type confirmation ----" and "# ---- 2. Identity")
# under /bin/bash with gui_read stubbed, against a synthetic calendar export
# and a synthetic macOS Calendar.sqlitedb, and measures what the customer is
# asked.
#
# Andy's walk (2026-10-15): the calendars were asked about one at a time, two
# questions each, and system calendars (holidays, birthdays, Siri
# suggestions) were asked about as if they were somebody's diary. The help
# line also read "1 events".
#
# Asserts:
#   1. ONE prompt for the whole list when the customer accepts the defaults,
#      however many calendars there are.
#   2. The screen lists every calendar, ordinary ones and a "set aside" group.
#   3. Holiday, birthday, Siri suggestion and subscribed calendars are set
#      aside from Calendar METADATA (store type, flags, external id), not a
#      title: the holiday fixture has a German title.
#   4. "1 event" / "2 events", never "1 events".
#   5. The written calendars.json excludes the set-aside calendars.
#   6. Answering "no" opens per-calendar questions, so defaults can change.
#
# All names are invented. No real personal data.
# Exit 0 clean, 1 on any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CAL_TEST_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
INSTALL_SH="$REPO_ROOT/install.sh"
STRINGS="$REPO_ROOT/install.sh.strings.en-GB.sh"
CAL_PY="$REPO_ROOT/lib/ostler-confirm-calendars.py"
PY="$(command -v python3)"
# The shipped shell. macOS /bin/bash is 3.2; on Linux CI /bin/bash is newer,
# which is still a strict superset for what this block uses.
BASH_BIN="/bin/bash"

pass=0
fails=0
ok_()   { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
fail_() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
expect() {  # expect <desc> <cmd...>
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then ok_ "$desc"; else fail_ "$desc"; fi
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ostler-calreview.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

printf 'shell under test: %s (%s)\n' "$BASH_BIN" "$("$BASH_BIN" -c 'echo $BASH_VERSION')"

# ── Fixtures ──────────────────────────────────────────────────────────
mkdir -p "$TMP/ostler/imports/fda" "$TMP/diag" \
         "$TMP/fakehome/Library/Group Containers/group.com.apple.calendar"

# Two ordinary calendars (one with exactly 1 event, one with 2), and one
# calendar of each set-aside kind.
cat > "$TMP/ostler/imports/fda/calendar_events.json" <<'JSON'
[
  {"calendar_name": "Personal", "title": "Dentist"},
  {"calendar_name": "Personal", "title": "Pottery class"},
  {"calendar_name": "Sam Patel", "title": "Flight to Lisbon"},
  {"calendar_name": "Feiertage in Deutschland", "title": "Ostermontag"},
  {"calendar_name": "Feiertage in Deutschland", "title": "Neujahr"},
  {"calendar_name": "Geburtstage", "title": "Bob Jones"},
  {"calendar_name": "Found in Natural Language", "title": "Lunch"},
  {"calendar_name": "rowing fixtures", "title": "Regatta"}
]
JSON

# A synthetic Calendar.sqlitedb: the columns the helper reads, with the values
# measured on a real macOS 26 database (see SET_ASIDE table in the helper).
"$PY" - "$TMP/fakehome/Library/Group Containers/group.com.apple.calendar/Calendar.sqlitedb" <<'PYEOF'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE Store (ROWID INTEGER PRIMARY KEY, name TEXT, type INTEGER)")
c.execute("CREATE TABLE Calendar (ROWID INTEGER PRIMARY KEY, store_id INTEGER, title TEXT,"
          " flags INTEGER, external_id TEXT, subcal_url TEXT)")
c.executemany("INSERT INTO Store VALUES (?,?,?)",
              [(1, "iCloud", 2), (2, "subscribed", 4), (3, "Other", 5)])
c.executemany("INSERT INTO Calendar VALUES (?,?,?,?,?,?)", [
    (1, 1, "Personal", 0, "/1/calendars/p", None),
    (2, 1, "Sam Patel", 0, "/1/calendars/wh", None),
    (3, 2, "Feiertage in Deutschland", 6361097, "__HolidayCalendar__", "https://calendars.example.invalid/hol.ics"),
    (4, 3, "Geburtstage", 5, None, None),
    (5, 3, "Found in Natural Language", 524295, None, None),
    (6, 1, "rowing fixtures", 6291465, "/1/calendars/rc", "https://fixtures.example.invalid/rowing.ics"),
])
c.commit()
PYEOF

# ── Harness: the block, verbatim from install.sh ─────────────────────
BLOCK="$TMP/block.sh"
awk '/^    # ---- 1\. Calendar owner\/type confirmation ----$/ {on=1}
     /^    # ---- 2\. Identity collapse/ {on=0}
     on {print}' "$INSTALL_SH" > "$BLOCK"
if [[ ! -s "$BLOCK" ]]; then
    fail_ "calendar block found in install.sh (markers moved?)"
    echo "FAIL: $fails" ; exit 1
fi

run_block() {  # run_block <review answer> <prompt log>
    cat > "$TMP/harness.sh" <<HARNESS
set -eu
source "$STRINGS"
gui_active() { return 0; }
gui_read() {
    # \$1 title \$2 kind \$3 default \$4 help \$5 choices \$6 id
    printf '%s\t%s\n' "\${6:-}" "\$1" >> "$2"
    printf '%s\n---\n' "\${4:-}" >> "$2.help"
    if [[ "\${6:-}" == "calendar_review" ]]; then printf '%s' "$1"; else printf '%s' "\${3:-}"; fi
}
info() { echo "info: \$*"; }
ok()   { echo "ok: \$*"; }
warn() { echo "warn: \$*"; }
OSTLER_DIR="$TMP/ostler"
OSTLER_DIAG_DIR="$TMP/diag"
_confirm_py="$PY"
_confirm_cal_py="$CAL_PY"
_confirm_events="$TMP/ostler/imports/fda/calendar_events.json"
_confirm_owner_name="Jane Doe"
if true; then
$(cat "$BLOCK")
fi
HARNESS
    : > "$2"; : > "$2.help"
    rm -f "$TMP/ostler/calendars.json"
    HOME="$TMP/fakehome" "$BASH_BIN" "$TMP/harness.sh" > "$2.out" 2>&1
}

# ── 1. Accept the defaults ───────────────────────────────────────────
echo "== accept the pre-filled list =="
run_block "y" "$TMP/accept.log"
n_prompts="$(wc -l < "$TMP/accept.log" | tr -d ' ')"
printf '  prompts shown: %s (calendars: 6)\n' "$n_prompts"
sed 's/^/  | /' "$TMP/accept.log.help"
if [[ "$n_prompts" == "1" ]]; then
    ok_ "one screen for six calendars, not one question per calendar"
else
    fail_ "one screen for six calendars (got $n_prompts prompts)"
fi
expect "the one prompt is calendar_review" grep -q '^calendar_review	' "$TMP/accept.log"

HELP="$TMP/accept.log.help"
expect "plural: '1 event' for a one-event calendar" grep -q '(1 event)' "$HELP"
expect "plural: '2 events' for a two-event calendar" grep -q '(2 events)' "$HELP"
expect "plural: never '1 events'" bash -c "! grep -q '1 events' '$HELP'"
expect "screen lists ordinary calendar Personal" grep -q '^Personal: yours, personal' "$HELP"
expect "screen lists a set-aside group" grep -q 'Set aside automatically' "$HELP"
expect "holiday (German title) set aside by metadata" grep -q '^Feiertage in Deutschland: public holidays' "$HELP"
expect "birthday (German title) set aside by metadata" grep -q '^Geburtstage: birthdays' "$HELP"
expect "Siri suggestion set aside" grep -q '^Found in Natural Language: Siri suggestions' "$HELP"
expect "subscribed calendar set aside" grep -q '^rowing fixtures: a calendar you subscribe to' "$HELP"
expect "ordinary calendars listed before the set-aside group" bash -c \
    "awk '/^Personal:/{h=NR} /Set aside automatically/{s=NR} END{exit !(h && s && h<s)}' '$HELP'"

J="$TMP/ostler/calendars.json"
expect "calendars.json written" test -s "$J"
expect "set-aside calendars written include:false with their kind" "$PY" -c "
import json
d = {c['match']: c for c in json.load(open('$J'))['calendars']}
exp = {'Feiertage in Deutschland': 'holiday', 'Geburtstage': 'birthday',
       'Found in Natural Language': 'suggestion', 'rowing fixtures': 'subscribed'}
for m, k in exp.items():
    assert d[m].get('include') is False and d[m].get('set_aside') == k, (m, d[m])
assert 'include' not in d['Personal'] and d['Personal']['type'] == 'personal'
assert d['Sam Patel']['owner'] == 'Sam Patel'
"

# ── 2. Decline: the defaults can still be changed ────────────────────
echo "== 'let me change something' =="
run_block "n" "$TMP/edit.log"
n_owner="$(grep -c '^calendar_owner	' "$TMP/edit.log" || true)"
n_incl="$(grep -c '^calendar_set_aside_include	' "$TMP/edit.log" || true)"
printf '  owner questions: %s, set-aside questions: %s\n' "$n_owner" "$n_incl"
expect "edit path asks whose each ordinary calendar is (2)" test "$n_owner" = "2"
expect "edit path offers each set-aside calendar back (4)" test "$n_incl" = "4"
expect "edit path help says '1 event', not '1 events'" bash -c \
    "grep -q '^1 event, e.g. Flight to Lisbon$' '$TMP/edit.log.help' && ! grep -q '1 events' '$TMP/edit.log.help'"
expect "set-aside stays excluded when the customer keeps the default" "$PY" -c "
import json
d = {c['match']: c for c in json.load(open('$J'))['calendars']}
assert d['Geburtstage'].get('include') is False
"

# ── 3. Nobody there: the REAL gui_read must time out, not block ──────
# Walk-away invariant (tests/test_walkaway_no_phase2_input_leak.sh allowlists
# calendar_review only because of this). Uses lib/progress_emitter.sh's own
# gui_read in GUI mode, reading from a FIFO the "GUI" never writes to.
echo "== nobody answers (real gui_read, GUI mode, 2s timeout) =="
rm -f "$J"
mkfifo "$TMP/gui.fifo"
cat > "$TMP/harness_timeout.sh" <<HARNESS
set -eu
source "$STRINGS"
source "$REPO_ROOT/lib/progress_emitter.sh"
info() { :; }; ok() { echo "ok: \$*"; }; warn() { echo "warn: \$*"; }
exec 7<>"$TMP/gui.fifo"
OSTLER_GUI=1
OSTLER_GUI_FD=7
OSTLER_CALENDAR_REVIEW_TIMEOUT_S=2
OSTLER_DIR="$TMP/ostler"
OSTLER_DIAG_DIR="$TMP/diag"
_confirm_py="$PY"
_confirm_cal_py="$CAL_PY"
_confirm_events="$TMP/ostler/imports/fda/calendar_events.json"
_confirm_owner_name="Jane Doe"
if true; then
$(cat "$BLOCK")
fi
echo "UNATTENDED=\${_confirm_unattended:-0}"
HARNESS
t0="$(date +%s)"
HOME="$TMP/fakehome" "$BASH_BIN" "$TMP/harness_timeout.sh" > "$TMP/timeout.out" 2>&1 &
hpid=$!
# Watchdog: if gui_read ignores the timeout this harness would hang forever.
( sleep 30; kill "$hpid" 2>/dev/null ) &
wpid=$!
wait "$hpid"; hrc=$?
kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null
elapsed=$(( $(date +%s) - t0 ))
printf '  harness rc=%s after %ss\n' "$hrc" "$elapsed"
expect "unanswered calendar screen does not block (finished, rc 0, under 30s)" \
    test "$hrc" = "0" -a "$elapsed" -lt 30
expect "exactly one PROMPT was emitted" test "$(grep -c 'PROMPT' "$TMP/timeout.out")" = "1"
expect "defaults saved when nobody answers" "$PY" -c "
import json
d = {c['match']: c for c in json.load(open('$J'))['calendars']}
assert d['Personal']['type'] == 'personal' and d['Geburtstage'].get('include') is False
"
expect "timeout marks the run unattended (identity prompts skipped)" \
    grep -q '^UNATTENDED=1$' "$TMP/timeout.out"

echo
printf 'passed %s, failed %s\n' "$pass" "$fails"
[[ "$fails" -eq 0 ]] || exit 1
