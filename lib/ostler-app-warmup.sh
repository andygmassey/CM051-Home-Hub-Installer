#!/usr/bin/env bash
# ostler-app-warmup.sh -- ONE rule for waking the Apple apps whose stores we read.
#
# Sourced by install.sh (the install-time warm-up) and by ~/.ostler/bin/ostler-fda
# (the hourly rerun). Both used to carry their own rules, and the rules differed
# per app, which is how a walk on 2026-09-24 found three of them wrong at once:
#
#   Notes     the store FILE existed but held 0 notes, so "file present" called
#             it populated and Notes was never opened. Opened by hand: 405 notes.
#   Mail      the store held 346,843 envelopes, newest a day old, and Mail was
#             not running. Mail only fetches while it runs, so a populated but
#             closed Mail is a store that has stopped moving.
#   Messages  same shape: history arrives from iCloud while Messages runs.
#
# And the install-time warm-up QUIT every app it opened after ten seconds, which
# stopped the sync that opening it was meant to start.
#
# THE RULE, the same for every source:
#   1. Count ROWS in the store the extractor reads. Never a file, never a folder.
#      Unreadable is CANNOT-RUN: nothing is recorded and it is never "0 rows".
#   2. Open the app (hidden, no focus steal) when its store has no rows, or, for
#      the apps that only fetch while running (Mail, Messages, Notes), when the
#      app is not running.
#   3. Never quit an app we opened. Apps outside the keep-running set may be
#      quit once their store HAS rows; before that, quitting stops the sync.
#   4. Record <source>_has_fetched and <source>_checked_ts in
#      pipeline_signals.json, merged so every other key survives.
#   5. The rerun re-opens an app at most once per OSTLER_WARM_REOPEN_S (a day).
#
# bash 3.2 safe: macOS /bin/bash runs this. No associative arrays.
#
# Every path is rooted at $HOME so a test can point HOME at a fixture tree.

# Map a source key to the app that owns its store. Empty for an unknown key.
ostler_warm_app_for() {
    case "$1" in
        apple_mail) echo "Mail" ;;
        apple_notes) echo "Notes" ;;
        imessage) echo "Messages" ;;
        calendar) echo "Calendar" ;;
        contacts) echo "Contacts" ;;
        reminders) echo "Reminders" ;;
        *) echo "" ;;
    esac
}

# Apps whose sync runs inside the app, so they must stay running to keep the
# store moving. Returns 0 for those.
ostler_warm_keep_running() {
    case "$1" in
        apple_mail|apple_notes|imessage) return 0 ;;
        *) return 1 ;;
    esac
}

# Read-only row count of one sqlite table. Prints the integer, or nothing when
# the database could not be read (CANNOT-RUN, deliberately not 0).
_ostler_warm_count() {
    local db="$1" sql="$2" n
    n="$(sqlite3 "file:${db}?mode=ro" -bail "$sql" 2>/dev/null)" || return 0
    [[ "$n" =~ ^[0-9]+$ ]] && printf '%s' "$n"
    return 0
}

# Print the number of rows in the store a source's extractor reads.
#   an integer  the store was read (0 means genuinely empty, or absent)
#   nothing     the store exists and could not be read: CANNOT-RUN
ostler_warm_store_rows() {
    local src="$1" db n total
    case "$src" in
        apple_notes)
            db="${HOME}/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"
            [[ -f "$db" ]] || { echo 0; return 0; }
            _ostler_warm_count "$db" "SELECT COUNT(*) FROM ZICNOTEDATA"
            ;;
        apple_mail)
            db="$(find "${HOME}/Library/Mail" -maxdepth 1 -type d -name 'V[0-9]*' 2>/dev/null | sort -V | tail -1)"
            [[ -n "$db" && -f "${db}/MailData/Envelope Index" ]] || { echo 0; return 0; }
            _ostler_warm_count "${db}/MailData/Envelope Index" "SELECT COUNT(*) FROM messages"
            ;;
        imessage)
            db="${HOME}/Library/Messages/chat.db"
            [[ -f "$db" ]] || { echo 0; return 0; }
            _ostler_warm_count "$db" "SELECT COUNT(*) FROM message"
            ;;
        calendar)
            db="${HOME}/Library/Group Containers/group.com.apple.calendar/Calendar.sqlitedb"
            [[ -f "$db" ]] || db="${HOME}/Library/Calendars/Calendar.sqlitedb"
            [[ -f "$db" ]] || { echo 0; return 0; }
            _ostler_warm_count "$db" "SELECT COUNT(*) FROM CalendarItem"
            ;;
        contacts)
            total=0
            local found=false
            while IFS= read -r db; do
                [[ -n "$db" ]] || continue
                found=true
                n="$(_ostler_warm_count "$db" "SELECT COUNT(*) FROM ZABCDRECORD")"
                [[ -n "$n" ]] || return 0
                total=$((total + n))
            done < <(find "${HOME}/Library/Application Support/AddressBook" -name '*.abcddb' -size +0c 2>/dev/null)
            [[ "$found" == true ]] || { echo 0; return 0; }
            echo "$total"
            ;;
        reminders)
            total=0
            local any=false
            for db in "${HOME}/Library/Group Containers/group.com.apple.reminders/Container_v1/Stores/"Data-*.sqlite; do
                [[ -f "$db" ]] || continue
                any=true
                n="$(_ostler_warm_count "$db" "SELECT COUNT(*) FROM ZREMCDREMINDER")"
                # A store without the table is a local scaffold, not a failure.
                [[ -n "$n" ]] || n=0
                total=$((total + n))
            done
            [[ "$any" == true ]] || { echo 0; return 0; }
            echo "$total"
            ;;
        *)
            ;;
    esac
    return 0
}

# Is the app running? pgrep -x on the process name, which for these six is the
# app name.
ostler_warm_app_running() {
    pgrep -x "$1" >/dev/null 2>&1
}

# Decide whether a source's app should be opened now. Prints a reason word and
# returns 0 when it should, returns 1 when it should not.
#   empty        the store has no rows
#   unreadable   the store could not be read; opening is harmless, guessing
#                "populated" is not
#   not-running  an app that only syncs while running is not running
ostler_warm_needs_open() {
    local src="$1" app rows
    app="$(ostler_warm_app_for "$src")"
    [[ -n "$app" ]] || return 1
    rows="$(ostler_warm_store_rows "$src")"
    if [[ -z "$rows" ]]; then
        echo "unreadable"; return 0
    fi
    if [[ "$rows" -eq 0 ]]; then
        echo "empty"; return 0
    fi
    if ostler_warm_keep_running "$src" && ! ostler_warm_app_running "$app"; then
        echo "not-running"; return 0
    fi
    return 1
}

# Open an app hidden, without stealing focus.
ostler_warm_open() {
    open -g -j -a "$1" >/dev/null 2>&1
}

# Merge <src>_has_fetched and <src>_checked_ts into pipeline_signals.json.
# Mail keeps its historical key name, mail_has_fetched.
ostler_warm_record() {
    local signals="$1" src="$2" fetched="$3" py="${OSTLER_PYTHON:-python3}" key
    case "$src" in
        apple_mail) key="mail" ;;
        apple_notes) key="notes" ;;
        *) key="$src" ;;
    esac
    mkdir -p "$(dirname "$signals")" 2>/dev/null || true
    "$py" - "$signals" "$key" "$fetched" <<'OSTLER_WARM_SIGNALS_EOF'
import json, os, sys, time
path, key, fetched = sys.argv[1], sys.argv[2], sys.argv[3] == "true"
try:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        data = {}
except (OSError, ValueError):
    data = {}
data[key + "_has_fetched"] = fetched
data[key + "_checked_ts"] = int(time.time())
tmp = path + ".tmp." + str(os.getpid())
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, sort_keys=True)
    fh.write("\n")
os.chmod(tmp, 0o600)
os.replace(tmp, path)
OSTLER_WARM_SIGNALS_EOF
}

# The install-time half. Opens what the rule says, waits up to $3 seconds for
# the opened stores to fill, records each opened source, and prints one line
# per decision for the caller, which owns the user-facing messages and the
# quitting (it has the timeout wrapper; this lib runs unattended too):
#   OPENED <App> <reason>   an app it opened
#   QUIT <App>              an opened app whose store now HAS rows and which
#                           need not keep running; nothing else is ever listed
#   $1 pipeline_signals.json   $2 state dir   $3 wait seconds   $@ source keys
ostler_warm_prelaunch() {
    local signals="$1" state="$2" wait="$3" src app rows all why
    shift 3
    local opened=()
    [[ "${OSTLER_APP_WARMUP:-1}" == "0" ]] && return 0
    for src in "$@"; do
        why="$(ostler_warm_needs_open "$src")" || continue
        app="$(ostler_warm_app_for "$src")"
        ostler_warm_open "$app" || true
        opened+=("$src")
        echo "OPENED ${app} ${why}"
    done
    [[ ${#opened[@]} -gt 0 ]] || return 0
    [[ "$wait" =~ ^[0-9]+$ ]] || wait=60
    while (( wait > 0 )); do
        all=true
        for src in "${opened[@]}"; do
            rows="$(ostler_warm_store_rows "$src")"
            if [[ -z "$rows" || "$rows" -eq 0 ]]; then
                all=false
                break
            fi
        done
        [[ "$all" == true ]] && break
        sleep "${OSTLER_WARM_POLL_S:-5}"
        wait=$((wait - ${OSTLER_WARM_POLL_S:-5}))
    done
    mkdir -p "$state" 2>/dev/null || true
    for src in "${opened[@]}"; do
        date +%s > "${state}/warm_opened_${src}" 2>/dev/null || true
        rows="$(ostler_warm_store_rows "$src")"
        # Unreadable: record nothing, quit nothing.
        [[ -n "$rows" ]] || continue
        if [[ "$rows" -gt 0 ]]; then
            ostler_warm_record "$signals" "$src" true || true
            ostler_warm_keep_running "$src" || echo "QUIT $(ostler_warm_app_for "$src")"
        else
            ostler_warm_record "$signals" "$src" false || true
        fi
    done
    return 0
}

# The hourly rerun's half. For each source: count rows, record the signal, and
# open the app when the rule says so, at most once per OSTLER_WARM_REOPEN_S.
#   $1  state dir (holds warm_opened_<src> stamps)
#   $2  pipeline_signals.json path
#   $@  source keys
ostler_warm_rerun() {
    local state="$1" signals="$2" src app rows fetched why stamp now last
    shift 2
    [[ "${OSTLER_APP_WARMUP:-1}" == "0" ]] && return 0
    mkdir -p "$state" 2>/dev/null || true
    for src in "$@"; do
        app="$(ostler_warm_app_for "$src")"
        [[ -n "$app" ]] || continue
        rows="$(ostler_warm_store_rows "$src")"
        if [[ -z "$rows" ]]; then
            # Unattended, an unreadable store is reported and left alone: it
            # usually means a lost permission, which opening an app cannot fix.
            echo "[warm] ${src}: CANNOT-RUN, the ${app} store exists and could not be read; nothing recorded"
            continue
        else
            fetched=false
            [[ "$rows" -gt 0 ]] && fetched=true
            ostler_warm_record "$signals" "$src" "$fetched" \
                || echo "[warm] ${src}: could not update pipeline_signals.json" >&2
        fi
        why="$(ostler_warm_needs_open "$src")" || continue
        stamp="${state}/warm_opened_${src}"
        now="$(date +%s)"
        last="$(cat "$stamp" 2>/dev/null || true)"
        [[ "$last" =~ ^[0-9]+$ ]] || last=0
        if (( now - last < ${OSTLER_WARM_REOPEN_S:-86400} )); then
            continue
        fi
        if ostler_warm_open "$app"; then
            printf '%s\n' "$now" > "$stamp"
            echo "[warm] ${src}: ${why}; opened ${app} in the background so it can sync"
        else
            echo "[warm] ${src}: ${why}; ${app} could not be opened"
        fi
    done
    return 0
}
