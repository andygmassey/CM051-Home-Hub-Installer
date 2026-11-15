#!/usr/bin/env bash
# The walk record names the data_conservation run that COUNTS (Archie ruling):
# a live manifest replay counts; a reused PASS, a phase-1 verdict, a missing
# log or no row counts nothing. Real function, real temp logs, no box.
# Exit 0 pass, 1 fail.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "${HERE}/../scripts/box_walk_probes/lib/counted_run.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/counted-run.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT
fails=0
check() { if [ "$2" = "1" ]; then echo "  ok    $1"; else echo "  FAIL  $1"; fails=$((fails + 1)); fi; }
row_has() { case "$(counted_run_row "$1")" in *"$2"*) echo 1 ;; *) echo 0 ;; esac; }

printf 'ok row\n        probe=data_conservation rows=119 live\n' > "$T/live.log"
check "a live manifest replay row counts as manifest_replay" "$(row_has "$T/live.log" 'manifest_replay')"

printf '        probe=data_conservation took the phase 1 verdict FAIL (run_box_walk.sh)\n' > "$T/p1.log"
check "a phase-1 verdict is not a manifest run: NONE-COUNTED" "$(row_has "$T/p1.log" 'NONE-COUNTED')"

printf '        probe=data_conservation reused the PASS recorded by this walk\n' > "$T/reuse.log"
check "a reused PASS is not a manifest run: NONE-COUNTED" "$(row_has "$T/reuse.log" 'NONE-COUNTED')"

printf 'ok row\n        probe=people_count_agreement rows=9\n' > "$T/other.log"
check "a manifest with no data_conservation row: NONE-COUNTED" "$(row_has "$T/other.log" 'NONE-COUNTED')"

check "no manifest log at all: NONE-COUNTED, never a manifest_replay" "$(row_has "$T/missing.log" 'NONE-COUNTED')"

# negative control: the live-row regex must NOT match a row for another probe
printf '        probe=data_conservation_extra rows=1\n' > "$T/prefix.log"
check "a longer probe name is not mistaken for data_conservation" "$(row_has "$T/prefix.log" 'NONE-COUNTED')"

[ "$fails" -eq 0 ] && echo "PASS" || { echo "FAIL: ${fails}"; exit 1; }
