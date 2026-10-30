#!/usr/bin/env bash
# lib_walk_tcc_declared.sh -- the thin walk's DECLARED STATE: which Ostler TCC
# rows already exist on the box BEFORE this walk installs anything.
#
# WHY (NEW-119, diag118 Mini16 on macOS 27.2, 2026-10-29): the system TCC.db
# keeps Ostler grants across a "cold" reset. Mini16 still held
# ai.ostler.installer=2, ai.ostler.assistant=2 and a ~/.ostler/python3.11=0 row
# written six weeks earlier. A walk that does not print these cannot say
# whether its TCC results came from this install or from a grant inherited
# from the last one. So the walk header records them, as state, not a verdict.
#
# READ-ONLY. One `sudo -n sqlite3 -readonly` SELECT on the system TCC.db. No
# tccutil, no write, no setting changed. Per-user TCC.db is absent on 27 and
# is reported as such, never read.
#
# NEVER FAILS THE WALK. Unreadable (no passwordless sudo, no sqlite3, SIP/TCC
# refusal) prints CANNOT-READ with the reason and returns 0. A zero is printed
# WITH its denominator (total rows in access) so "no Ostler rows" and "could
# not look" never print the same.
#
# Runs ON the box:  { declare -f walk_tcc_declared_state; echo walk_tcc_declared_state; } | ssh host 'bash -s'
# Bash 3.2 safe.

walk_tcc_declared_state() {
    local db sudo_bin sq out rc total n
    db="${OSTLER_TCC_SYSTEM_DB:-/Library/Application Support/com.apple.TCC/TCC.db}"
    sudo_bin="${OSTLER_TCC_SUDO:-sudo}"
    sq="${OSTLER_TCC_SQLITE:-/usr/bin/sqlite3}"
    out="$("$sudo_bin" -n "$sq" -readonly -separator '|' "$db" \
        "select client, service, auth_value, datetime(last_modified,'unixepoch') from access where lower(client) like '%ostler%' order by client, service; select '__TOTAL=' || count(*) from access;" 2>&1)"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'tcc declared: CANNOT-READ system TCC.db (rc=%s: %s); pre-existing grants are UNKNOWN for this walk\n' \
            "$rc" "$(printf '%s' "$out" | head -1 | cut -c1-160)"
        return 0
    fi
    total="$(printf '%s\n' "$out" | sed -n 's/^__TOTAL=//p')"
    case "$total" in
        ''|*[!0-9]*)
            printf 'tcc declared: CANNOT-READ system TCC.db (the query answered without its row count); pre-existing grants are UNKNOWN for this walk\n'
            return 0 ;;
    esac
    n="$(printf '%s\n' "$out" | /usr/bin/grep -v '^__TOTAL=' | /usr/bin/grep -c '|')"
    printf 'tcc declared: system TCC.db, %s pre-existing Ostler row(s) of %s total (client|service|auth_value|last_modified UTC):\n' "$n" "$total"
    printf '%s\n' "$out" | /usr/bin/grep -v '^__TOTAL=' | /usr/bin/grep '|' | sed 's/^/  tcc declared:   /'
    if [ -e "$HOME/Library/Application Support/com.apple.TCC/TCC.db" ]; then
        printf 'tcc declared: per-user TCC.db present (not read)\n'
    else
        printf 'tcc declared: per-user TCC.db absent (expected on macOS 27)\n'
    fi
    return 0
}
