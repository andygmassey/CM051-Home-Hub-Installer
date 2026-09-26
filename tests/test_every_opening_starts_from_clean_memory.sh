#!/usr/bin/env bash
# tests/test_every_opening_starts_from_clean_memory.sh
#
# First real run of assistant_grounds_the_opening_turn (v1.0.102 candidate 4
# box): openings 1-6 grounded, 7-10 no_tool_call, consecutively. Each opening
# left memory about the seed person that the next was asked against. The probe
# now restores precondition 1 before EVERY opening. This drives the real
# _restore_precondition_before_opening with the memory reader stubbed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE="$HERE/scripts/box_walk_probes/probes/assistant_grounds_the_opening_turn.sh"
pass=0; fail=0
arm() { if [ "$2" -eq 0 ]; then pass=$((pass+1)); printf '  [PASS] %s\n' "$1"; else fail=$((fail+1)); printf '  [FAIL] %s\n         %s\n' "$1" "${3:-}"; fi; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
# The probe sources ../lib relative to itself, so the copy sits in a probes/
# directory beside a link to the real lib.
mkdir -p "$T/probes"; ln -s "$HERE/scripts/box_walk_probes/lib" "$T/lib"
sed '$d' "$PROBE" > "$T/probes/probe_nomain.sh"

# run <label> <memory state file contents...>: the stub reads $T/mem (count of
# remembered entries) and forget zeroes it unless $T/stuck exists.
run() {
    ( . "$T/probes/probe_nomain.sh" >/dev/null 2>&1
      _memory_mentions_person() { n="$(cat "$T/mem")"; [ "$n" = "ERR" ] && { echo "UNREADABLE http 500"; return; }; echo "READ 50 $n"; i=0; while [ "$i" -lt "$n" ]; do echo "KEY k$i"; i=$((i+1)); done; }
      _memory_forget_keys() { [ -f "$T/stuck" ] || echo 0 > "$T/mem"; echo "FORGOT $# 0"; }
      probe_note() { printf 'NOTE %s\n' "$1"; }
      probe_cannot_run() { printf 'CANNOT %s\n' "$1"; }
      _carried_total=0
      export OSTLER_SEED_PERSON_IS_SYNTHETIC="$1"
      _restore_precondition_before_opening "$2"; printf 'RC %s TOTAL %s\n' "$?" "$_carried_total" )
}

printf 'EVERY OPENING STARTS FROM CLEAN MEMORY\n\n'
echo 3 > "$T/mem"; out="$(run 1 2)"
arm "opening 2 with 3 carried memories: removed, recorded, and goes on" \
    "$(printf '%s' "$out" | grep -c -E 'RC 0 TOTAL 3' | awk '{print ($1==1)?0:1}')" "$out"
arm "and memory is actually clear afterwards" "$([ "$(cat "$T/mem")" = 0 ] && echo 0 || echo 1)"
echo 2 > "$T/mem"; out="$(run 1 1)"
arm "opening 1 is left to the precondition check, not purged here" "$([ "$(cat "$T/mem")" = 2 ] && echo 0 || echo 1)" "$out"
echo 2 > "$T/mem"; out="$(run 0 5)"
arm "a real contact (not synthetic) is never purged" "$([ "$(cat "$T/mem")" = 2 ] && echo 0 || echo 1)" "$out"
echo 2 > "$T/mem"; : > "$T/stuck"; out="$(run 1 4)"; rm -f "$T/stuck"
arm "a purge that does not take stops the battery as CANNOT-RUN" \
    "$(printf '%s' "$out" | grep -c -E '^CANNOT .*did not take' | awk '{print ($1==1)?0:1}')" "$out"
arm "and returns non-zero so the loop stops" "$(printf '%s' "$out" | grep -c 'RC 1' | awk '{print ($1==1)?0:1}')" "$out"
echo ERR > "$T/mem"; out="$(run 1 3)"
arm "an unreadable memory is CANNOT-RUN, not absent" \
    "$(printf '%s' "$out" | grep -c -E '^CANNOT .*could not be read' | awk '{print ($1==1)?0:1}')" "$out"
arm "the loop calls it before every opening" \
    "$(grep -c '_restore_precondition_before_opening "\$_i" || return' "$PROBE" | awk '{print ($1==1)?0:1}')"

printf '\n== %d pass / %d fail / %d total ==\n' "$pass" "$fail" "$((pass+fail))"
[ "$fail" -eq 0 ]
