#!/usr/bin/env bash
# Apple apps are warmed by ONE rule, and the rerun catches up (#2351).
#
# Notes, Mail and Messages were each found cold on the same walk box on
# 2026-09-24, and each for a variant of the same reason: the installer asked a
# question the store could not answer (does the FILE exist?), and it quit the
# apps it opened after ten seconds, stopping the sync it had just started.
# ============================================================================
#
# THE DEFECT, measured on a walk box 2026-09-24. NoteStore.sqlite had existed
# since July with 0 rows in ZICNOTEDATA, because Notes had never been opened
# and iCloud only fills the store while Notes runs. install.sh's pre-launch
# gate asked "does NoteStore.sqlite exist?", got yes, and never opened Notes.
# Every extract then read 0 notes. The only step that embeds notes into
# apple_notes_knowledge is the install-time hydrate leg, so the 0 was final.
# Opened once by hand, the same store held 412 notes.
#
# WHAT THIS PROVES, by EXECUTING the shipped code against synthetic stores:
#   A. _store_populated_notes (install.sh) answers on ROWS, not file presence,
#      and the pre-launch gate uses it and leaves Notes running.
#   B. the ostler-fda wrapper: _ostler_app_warm_rerun opens an empty store's
#      app at most once a dwell and records the sidecar without dropping other
#      keys; _ostler_notes_refresh embeds when the extract changes and retries
#      a failed embed; an unreadable store is CANNOT-RUN.
#   C. the SAME rule for every app, executed from the lib install.sh embeds:
#      Mail and Messages are opened when not running even with a full store,
#      an empty store is opened, a populated store of an app that need not
#      keep running is left alone, and the embedded lib has not drifted.
#
# `open` and ostler-knowledge are shims that RECORD their calls. Nothing here
# opens an app or touches a real store. Synthetic data only.
#
# EXIT CODES   0 all pass   1 a check failed   2 CANNOT-RUN
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${1:-${REPO_ROOT}/install.sh}"
PASS=0; FAIL=0
ok()   { printf '  [PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  [FAIL] %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
cannot_run() { echo "CANNOT-RUN: $1" >&2; exit 2; }

command -v sqlite3 >/dev/null 2>&1 || cannot_run "sqlite3 not on PATH"
command -v python3 >/dev/null 2>&1 || cannot_run "python3 not on PATH"
[[ -f "$INSTALL_SH" ]] || cannot_run "no install.sh at $INSTALL_SH"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── extract a top-level bash function by name ──────────────────────────────
extract_fn() {  # <file> <name>
    awk -v n="$2" '
        $0 ~ "^" n "\\(\\) \\{" { f = 1 }
        f { print }
        f && /^}$/ { exit }
    ' "$1"
}

# The ostler-fda wrapper exactly as install.sh writes it.
awk '
    index($0, "bin/ostler-fda\" <<'"'"'FDAEOF'"'"'") { f = 1; next }
    f && $0 == "FDAEOF" { exit }
    f { print }
' "$INSTALL_SH" > "${WORK}/ostler-fda"
[[ -s "${WORK}/ostler-fda" ]] || cannot_run "could not extract the ostler-fda wrapper from install.sh"

make_store() {  # <path> <rows>
    mkdir -p "$(dirname "$1")"; rm -f "$1"
    sqlite3 "$1" "CREATE TABLE ZICNOTEDATA (Z_PK INTEGER PRIMARY KEY, ZDATA BLOB);"
    local i=0
    while (( i < $2 )); do
        sqlite3 "$1" "INSERT INTO ZICNOTEDATA (ZDATA) VALUES (x'00');"
        i=$((i + 1))
    done
}

echo "A. install.sh: the populated probe and the pre-launch gate"
extract_fn "$INSTALL_SH" _store_populated_notes > "${WORK}/probe.sh"
if [[ ! -s "${WORK}/probe.sh" ]]; then
    bad "install.sh defines _store_populated_notes"
else
    ok "install.sh defines _store_populated_notes"
    STORE_A="${WORK}/homeA/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"
    run_probe() { HOME="${WORK}/homeA" bash -c ". '${WORK}/probe.sh'; _store_populated_notes"; }
    check "no store file -> not populated" '! run_probe'
    make_store "$STORE_A" 0
    check "store file with 0 note rows -> NOT populated (the measured defect)" '! run_probe'
    make_store "$STORE_A" 3
    check "store with note rows -> populated" 'run_probe'
fi
WARM_BLOCK="$(awk '/# #2351: ONE rule for every app/,/MSG_OK_APP_DATABASES_ALREADY_PRESENT_SKIPPING_PRE/' "$INSTALL_SH")"
check "the pre-launch gate no longer decides Notes on file presence" \
    '! grep -q "NoteStore.sqlite \]\] && APPS_TO_OPEN" "$INSTALL_SH" && ! grep -q "APPS_TO_OPEN+=(\"Notes\")" "$INSTALL_SH"'
check "the pre-launch gate asks the shared lib, for all six sources" \
    '[[ "$WARM_BLOCK" == *"ostler_warm_needs_open"* && "$WARM_BLOCK" == *"calendar apple_mail contacts reminders apple_notes imessage"* ]]'
check "the pre-launch quit loop skips keep-running apps and empty stores" \
    '[[ "$WARM_BLOCK" == *"ostler_warm_keep_running \"\$_warm_src\" && continue"* && "$WARM_BLOCK" == *"\"\$_warm_rows\" -gt 0 ]] || continue"* ]]'
# The warm-up lib exactly as install.sh embeds it, and the canonical copy.
awk '
    index($0, "<<'"'"'OSTLER_APP_WARMUP_EOF'"'"'") { f = 1; next }
    f && $0 == "OSTLER_APP_WARMUP_EOF" { exit }
    f { print }
' "$INSTALL_SH" > "${WORK}/warmup.sh"
[[ -s "${WORK}/warmup.sh" ]] || cannot_run "could not extract the embedded ostler-app-warmup.sh from install.sh"
check "the embedded warm-up lib has not drifted from lib/ostler-app-warmup.sh" \
    'cmp -s "${WORK}/warmup.sh" "${REPO_ROOT}/lib/ostler-app-warmup.sh"'

# Shims that RECORD. `open` logs its args; `pgrep -x <App>` succeeds only for
# apps listed in $PGREP_RUNNING. Nothing real is opened or queried.
BIN="${WORK}/shim"; mkdir -p "$BIN"
OPENLOG="${WORK}/open.log"; KLOG="${WORK}/knowledge.log"
printf '#!/bin/sh\necho "$*" >> "%s"\n' "$OPENLOG" > "${BIN}/open"
cat > "${BIN}/pgrep" <<'EOF'
#!/bin/sh
app="$2"
case ",${PGREP_RUNNING:-}," in *",$app,"*) exit 0 ;; esac
exit 1
EOF
cat > "${WORK}/ostler-knowledge" <<EOF
#!/bin/sh
echo "\$1 \$*" >> "$KLOG"
[ "\${KNOWLEDGE_FAIL:-0}" = "1" ] && [ "\$1" = "embed" ] && exit 1
exit 0
EOF
chmod +x "${BIN}/open" "${BIN}/pgrep" "${WORK}/ostler-knowledge"

echo "B. ostler-fda: the rerun warm-up and the Notes embed"
extract_fn "${WORK}/ostler-fda" _ostler_notes_refresh > "${WORK}/refresh.sh"
extract_fn "${WORK}/ostler-fda" _ostler_app_warm_rerun > "${WORK}/warm.sh"
if [[ ! -s "${WORK}/refresh.sh" || ! -s "${WORK}/warm.sh" ]]; then
    bad "the ostler-fda wrapper defines _ostler_app_warm_rerun and _ostler_notes_refresh"
else
    ok "the ostler-fda wrapper defines _ostler_app_warm_rerun and _ostler_notes_refresh"
    check "the wrapper runs both after the ingest and exits with both rcs" \
        'grep -q "^_ostler_app_warm_rerun || true" "${WORK}/ostler-fda" && grep -q "^_ostler_notes_refresh || _notes_rc=" "${WORK}/ostler-fda" && grep -q "^\" || _fda_rc=" "${WORK}/ostler-fda"'

    H="${WORK}/homeB"
    STORE_B="${H}/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"
    SIG="${H}/.ostler/state/pipeline_signals.json"
    JSON="${H}/.ostler/imports/fda/apple_notes.json"
    mkdir -p "$(dirname "$SIG")" "$(dirname "$JSON")" "${H}/.ostler/lib"
    cp "${WORK}/warmup.sh" "${H}/.ostler/lib/ostler-app-warmup.sh"

    refresh() {
        : > "$OPENLOG"; : > "$KLOG"
        HOME="$H" PATH="${BIN}:${PATH}" OSTLER_DIR="${H}/.ostler" OSTLER_PYTHON="$(command -v python3)" \
        OSTLER_KNOWLEDGE_BIN="${WORK}/ostler-knowledge" \
            bash -c "set -euo pipefail; . '${WORK}/warm.sh'; . '${WORK}/refresh.sh'; _ostler_app_warm_rerun; _ostler_notes_refresh" >"${WORK}/refresh.out" 2>&1
    }
    sig() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]))' "$SIG" "$1" 2>/dev/null; }

    printf '{"mail_has_fetched": true, "install_completed_ts": 1}\n' > "$SIG"
    make_store "$STORE_B" 0
    refresh; rc=$?
    check "empty store: the step succeeds" '[[ $rc -eq 0 ]]'
    check "empty store: Notes is opened hidden" 'grep -qx -- "-g -j -a Notes" "$OPENLOG"'
    check "empty store: sidecar notes_has_fetched=False" '[[ "$(sig notes_has_fetched)" == "False" ]]'
    check "the sidecar keeps the keys it did not write" '[[ "$(sig mail_has_fetched)" == "True" && "$(sig install_completed_ts)" == "1" ]]'
    refresh
    check "empty store again inside the dwell: Notes is NOT re-opened" '[[ ! -s "$OPENLOG" ]]'
    OSTLER_WARM_REOPEN_S=0 refresh
    check "dwell elapsed: Notes is re-opened" 'grep -qx -- "-g -j -a Notes" "$OPENLOG"'

    make_store "$STORE_B" 2
    printf '[{"note_id":"syn-1"},{"note_id":"syn-2"}]\n' > "$JSON"
    KNOWLEDGE_FAIL=1 refresh; rc=$?
    check "a failed embed makes the step non-zero" '[[ $rc -ne 0 ]]'
    check "a failed embed records no hash, so the next tick retries" '[[ ! -f "${H}/.ostler/state/hydrate/apple_notes_knowledge.sha256" ]]'
    PGREP_RUNNING="Notes" OSTLER_WARM_REOPEN_S=0 refresh; rc=$?
    check "populated store, Notes running: Notes is not opened" '[[ ! -s "$OPENLOG" ]]'
    check "populated store: sidecar notes_has_fetched=True" '[[ "$(sig notes_has_fetched)" == "True" ]]'
    check "new extract: convert then embed into apple_notes_knowledge" \
        'grep -q "^convert " "$KLOG" && grep -q "^embed .*--collection apple_notes_knowledge" "$KLOG"'
    check "the hydrate sentinel records ok with the note count" \
        'grep -qx "status=ok" "${H}/.ostler/state/hydrate/apple_notes.done" && grep -qx "item_count=2" "${H}/.ostler/state/hydrate/apple_notes.done"'
    OSTLER_WARM_REOPEN_S=0 refresh
    check "populated store, Notes NOT running: Notes is re-opened (it syncs only while running)" \
        'grep -qx -- "-g -j -a Notes" "$OPENLOG"'
    check "unchanged extract: no second embed" '[[ ! -s "$KLOG" ]]'
    printf '[]\n' > "$JSON"
    PGREP_RUNNING="Notes" refresh
    check "an empty extract embeds nothing" '[[ ! -s "$KLOG" ]]'

    printf 'not a database' > "$STORE_B"
    rm -f "$SIG"
    OSTLER_WARM_REOPEN_S=0 refresh
    check "unreadable store: CANNOT-RUN, nothing recorded, Notes not opened" \
        'grep -q "CANNOT-RUN" "${WORK}/refresh.out" && [[ ! -f "$SIG" && ! -s "$OPENLOG" ]]'

    make_store "$STORE_B" 0
    OSTLER_FDA_SOURCES="calendar" OSTLER_WARM_REOPEN_S=0 refresh
    check "Notes not among the customer's sources: Notes not opened, no notes key" \
        '! grep -q "Notes" "$OPENLOG" && [[ "$(sig notes_has_fetched)" == "None" ]]'
    rm -f "$SIG"
    OSTLER_NOTES_REFRESH=0 OSTLER_WARM_REOPEN_S=0 refresh
    check "OSTLER_NOTES_REFRESH=0 turns the step off" '[[ ! -s "$OPENLOG" && ! -f "$SIG" ]]'
    OSTLER_APP_WARMUP=0 OSTLER_WARM_REOPEN_S=0 refresh
    check "OSTLER_APP_WARMUP=0 turns the warm-up off" '[[ ! -s "$OPENLOG" && ! -f "$SIG" ]]'
fi

echo "C. one rule for every app (executed from the embedded lib)"
HC="${WORK}/homeC"
mk() {  # <db> <create sql> <table> <rows>
    mkdir -p "$(dirname "$1")"; rm -f "$1"
    sqlite3 "$1" "$2"
    local i=0
    while (( i < $4 )); do sqlite3 "$1" "INSERT INTO $3 DEFAULT VALUES;"; i=$((i + 1)); done
}
MAILDB="${HC}/Library/Mail/V10/MailData/Envelope Index"
CHATDB="${HC}/Library/Messages/chat.db"
CALDB="${HC}/Library/Group Containers/group.com.apple.calendar/Calendar.sqlitedb"
REMDB="${HC}/Library/Group Containers/group.com.apple.reminders/Container_v1/Stores/Data-SYNTH.sqlite"
mk "$MAILDB" "CREATE TABLE messages (ROWID INTEGER PRIMARY KEY);" messages 3
mk "$CHATDB" "CREATE TABLE message (ROWID INTEGER PRIMARY KEY);" message 0
mk "$CALDB" "CREATE TABLE CalendarItem (ROWID INTEGER PRIMARY KEY);" CalendarItem 2
mk "$REMDB" "CREATE TABLE ZREMCDREMINDER (Z_PK INTEGER PRIMARY KEY);" ZREMCDREMINDER 0
lib() {  # <PGREP_RUNNING> <shell snippet>
    HOME="$HC" PATH="${BIN}:${PATH}" PGREP_RUNNING="$1" \
        bash -c "set -uo pipefail; . '${WORK}/warmup.sh'; $2"
}
check "Mail with 3 envelopes but NOT running is opened (Mail fetches only while it runs)" \
    '[[ "$(lib "" "ostler_warm_needs_open apple_mail")" == "not-running" ]]'
check "Mail with envelopes and running is left alone" \
    '! lib "Mail" "ostler_warm_needs_open apple_mail" >/dev/null'
check "Messages with an empty chat.db is opened even while running" \
    '[[ "$(lib "Messages" "ostler_warm_needs_open imessage")" == "empty" ]]'
check "Calendar with rows is left alone whether or not it runs" \
    '! lib "" "ostler_warm_needs_open calendar" >/dev/null'
check "Reminders with 0 rows is opened" \
    '[[ "$(lib "" "ostler_warm_needs_open reminders")" == "empty" ]]'
check "row counts are read from the stores, not inferred from files" \
    '[[ "$(lib "" "ostler_warm_store_rows apple_mail") $(lib "" "ostler_warm_store_rows imessage") $(lib "" "ostler_warm_store_rows calendar")" == "3 0 2" ]]'
printf 'not a database' > "$CHATDB"
check "an unreadable chat.db prints NO count (CANNOT-RUN), never 0" \
    '[[ -z "$(lib "" "ostler_warm_store_rows imessage")" ]]'
check "Mail, Messages and Notes keep running; Calendar, Contacts, Reminders may be quit" \
    'lib "" "ostler_warm_keep_running apple_mail && ostler_warm_keep_running imessage && ostler_warm_keep_running apple_notes && ! ostler_warm_keep_running calendar && ! ostler_warm_keep_running contacts && ! ostler_warm_keep_running reminders"'
: > "$OPENLOG"
rm -rf "${HC}/.ostler"
mk "$CHATDB" "CREATE TABLE message (ROWID INTEGER PRIMARY KEY);" message 5
lib "" "ostler_warm_rerun '${HC}/.ostler/state' '${HC}/.ostler/state/pipeline_signals.json' apple_mail imessage calendar reminders" >/dev/null
check "the rerun opens exactly Mail, Messages (not running) and Reminders (empty), not Calendar" \
    '[[ "$(sort "$OPENLOG" | tr "\n" "|")" == "-g -j -a Mail|-g -j -a Messages|-g -j -a Reminders|" ]]'
check "the rerun records every source it measured, under the historical mail key" \
    'python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if (d[\"mail_has_fetched\"], d[\"imessage_has_fetched\"], d[\"calendar_has_fetched\"], d[\"reminders_has_fetched\"]) == (True, True, True, False) else 1)" "${HC}/.ostler/state/pipeline_signals.json"'

echo
echo "== ${PASS} pass / ${FAIL} fail =="
[[ $FAIL -eq 0 ]]
