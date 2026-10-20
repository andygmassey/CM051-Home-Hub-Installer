#!/usr/bin/env bash
# lib_walk_safari_seed.sh -- plant a SYNTHETIC Safari History.db on the walk
# account BEFORE install, so the walk exercises the Safari reader end to end.
#
# WHY (walk34 classify, v1.0.115): the walk account never opened Safari, so
# ~/Library/Safari did not exist, the reader reported not_found, the
# safari_history collection was never created and ingest_coverage FAILed for a
# source that had nothing to give. The probe now grades that SOURCE-ABSENT
# (CANNOT-RUN). This seed is the other half: give the walk a source, so Safari
# is covered instead of merely excused.
#
# THE TCC CAVEAT, said here so a green does not overstate itself: ~/Library/Safari
# is TCC-protected. Over ssh the planting can be refused ("Operation not
# permitted") and, even when planted, the READER can still be refused (status
# no_fda) when the installer lacks Full Disk Access. Both are CANNOT-RUN (FDA),
# never a pass: this seed records which one happened in ~/.walk-safari-seed-run
# and ingest_coverage reads that marker. Whether FDA is held on a given walk
# account is not knowable from this file; only a walk can say.
#
# Marker states (one line): planted(...) | skipped-real-history-present |
#                           cannot-plant:<reason>
#
# NEVER overwrites a History.db that lacks the walk_synthetic_marker table: a
# real browser history is not ours to replace.
#
# Use as: walk_safari_seed_apply <fixture.db>   (runs ON the walk account)

walk_safari_seed_apply() {
    local fixture="$1" dir db marker err n
    dir="$HOME/Library/Safari"; db="$dir/History.db"; marker="$HOME/.walk-safari-seed-run"
    [ -s "$fixture" ] || { printf 'cannot-plant:no-fixture-file\n' > "$marker"; echo "safari seed: no fixture file"; return 0; }
    if [ -e "$db" ]; then
        n="$(/usr/bin/sqlite3 "file:${db}?mode=ro" 'select count(*) from walk_synthetic_marker' 2>/dev/null || true)"
        if [ -z "$n" ]; then
            printf 'skipped-real-history-present\n' > "$marker"
            echo "safari seed: a History.db without the synthetic marker exists (or is unreadable); left untouched"
            return 0
        fi
    fi
    if ! err="$(mkdir -p "$dir" 2>&1)"; then
        printf 'cannot-plant:mkdir-refused (%s)\n' "$(printf '%s' "$err" | tr -d '\r\n' | head -c 120)" > "$marker"
        echo "safari seed: CANNOT-RUN (FDA/TCC): could not create ${dir}: ${err}"
        return 0
    fi
    if ! err="$(cp "$fixture" "${db}.walk-new" 2>&1 && mv -f "${db}.walk-new" "$db" 2>&1)"; then
        rm -f "${db}.walk-new" 2>/dev/null || true
        printf 'cannot-plant:write-refused (%s)\n' "$(printf '%s' "$err" | tr -d '\r\n' | head -c 120)" > "$marker"
        echo "safari seed: CANNOT-RUN (FDA/TCC): could not write ${db}: ${err}"
        return 0
    fi
    n="$(/usr/bin/sqlite3 "file:${db}?mode=ro" 'select count(*) from history_visits' 2>/dev/null || true)"
    if [ -z "$n" ] || [ "$n" -le 0 ] 2>/dev/null; then
        printf 'cannot-plant:planted-but-unreadable-by-this-account\n' > "$marker"
        echo "safari seed: file written but not readable back by this account; not claiming a plant"
        return 0
    fi
    printf 'planted(visits=%s)\n' "$n" > "$marker"
    echo "safari seed: planted synthetic History.db (${n} visits) at ${db}"
}
