#!/usr/bin/env bash
# Per-probe and per-manifest-row seconds must be printed AND recorded (names and seconds only).
# Lifts the real sed extractors out of post_walk_qa.sh and applies them to synthetic logs shaped like the
# output of run_box_walk.sh and verify_cut_manifest.py.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QA="$REPO/scripts/post_walk_qa.sh"; RUN="$REPO/scripts/box_walk_probes/run_box_walk.sh"
PASS=0; FAIL=0
arm() { if [ "$2" -eq 0 ]; then echo "  [PASS] $1"; PASS=$((PASS+1)); else echo "  [FAIL] $1"; printf '%s\n' "${3:-}" | tail -8 | sed 's/^/         /'; FAIL=$((FAIL+1)); fi; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
grep -q 'TIMING probe=%s seconds=' "$RUN" && grep -q 'PROBE_TIMINGS' "$RUN" && grep -q 'TIMING top15 probe=' "$RUN"
arm "run_box_walk.sh prints one TIMING line per probe and a sorted top 15" $? "missing"
# the extractors, lifted verbatim
ex() { # $1 = probe log, $2 = manifest log
    PROBE_LOG="$1"; MANIFEST_LOG="$2"
    eval "$(grep -E "^ *sed -n 's/\^ \*TIMING" "$QA" | sed 's/^ *//')"
}
printf '  TIMING top15 probe=people_count_agreement seconds=412\n  TIMING top15 probe=daemon_is_listening seconds=3\n  TIMING phase2_probes_total seconds=2900 (probes only)\n' > "$W/p.log"
printf '  TIMING manifest_top15 probe=assistant_answers_grounded seconds=301.5\n  TIMING manifest_total rows=33 box_walk_rows=33 seconds=3600.2\n' > "$W/m.log"
out="$(ex "$W/p.log" "$W/m.log")"
printf '%s\n' "$out" | grep -q $'timing_phase2_probe\tpeople_count_agreement\t412'; arm "phase-2 probe seconds become timing_phase2_probe rows" $? "$out"
printf '%s\n' "$out" | grep -q $'timing_phase2_probes_total\t2900'; arm "and the phase-2 total" $? "$out"
printf '%s\n' "$out" | grep -q $'timing_manifest_row\tassistant_answers_grounded\t301.5'; arm "manifest row seconds become timing_manifest_row rows" $? "$out"
printf '%s\n' "$out" | grep -q $'timing_manifest_total\t3600.2'; arm "and the manifest total" $? "$out"
printf 'RESULT\n' > "$W/none.log"; : > "$W/none.m"
[ -z "$(ex "$W/none.log" "$W/none.m")" ]; arm "control: logs with no TIMING lines yield no rows (nothing invented)" $? ""
printf '\n== %s pass / %s fail ==\n' "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ]
