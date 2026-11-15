#!/usr/bin/env bash
# lib/counted_run.sh -- which data_conservation run the walk record COUNTS.
#
# Walk 131 recorded two data_conservation results in one walk: the in-walk
# section (29 of 143 rows) and the manifest replay (5 of 119 rows). Two verdicts
# for one probe in one walk is itself a finding, so the record names the one
# that counts. Archie's ruling: the MANIFEST run counts; the in-walk run is
# advisory. Only a LIVE manifest replay line counts. A reused PASS or a
# phase-1 verdict is not a second measurement, so it is not the counted run.
#
# counted_run_row <manifest_log>  -> prints ONE walk-record row on stdout.
#   data_conservation_counted_run  manifest_replay      a live manifest row ran
#   data_conservation_counted_run  NONE-COUNTED ...     no live manifest row; the
#                                                       in-walk run counts for nothing
#
# bash 3.2, BSD userland. No em dashes.

counted_run_row() {
    local log="${1:-}" line
    if [ -z "$log" ] || [ ! -r "$log" ]; then
        printf 'data_conservation_counted_run\tNONE-COUNTED (no manifest replay log readable; the in-walk run is advisory and counts for nothing)\n'
        return 0
    fi
    # A live replay detail is indented and begins "probe=data_conservation ".
    # Reuse and phase-1 detail lines name the same probe, so they are excluded.
    line="$(grep -E '^ +probe=data_conservation ' "$log" \
        | grep -v -E 'REUSED|reused the PASS|took the phase 1 verdict' | head -n 1)"
    if [ -n "$line" ]; then
        printf 'data_conservation_counted_run\tmanifest_replay (live re-run at manifest time; the in-walk run is advisory)\n'
    else
        printf 'data_conservation_counted_run\tNONE-COUNTED (no live manifest replay row for data_conservation; the in-walk run is advisory and counts for nothing)\n'
    fi
}
