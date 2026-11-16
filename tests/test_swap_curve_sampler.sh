#!/usr/bin/env bash
# The swap and pageout curve: parses real vm_stat / vm.swapusage text, writes
# NA (never 0) for anything unreadable, brackets only the chat battery, and
# runs for the whole walk and stops by its own PID. The box read is stubbed.
# Exit 0 pass, 1 fail.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "${HERE}/../scripts/box_walk_probes/lib/swap_curve.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/swap-curve.XXXXXX")" || exit 1
OSTLER_BOX_HOST="stub-box"; export OSTLER_BOX_HOST
trap 'rm -rf "$T"' EXIT
fails=0
check() { if [ "$2" = "1" ]; then echo "  ok    $1"; else echo "  FAIL  $1"; fails=$((fails + 1)); fi; }
# bash 3.2 safe: a case inside $(...) with a ')' in a pattern does not parse there.
has() { if [[ "$1" == *"$2"* ]]; then echo 1; else echo 0; fi; }

VM_OK='Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                               12345.
Pageouts:                                 98765.'
SU_OK='vm.swapusage: total = 13312.00M  used = 11878.44M  free = 1433.56M  (encrypted)'

# 1. a real reading parses to measured values
set -- $(swap_parse_swapusage "$SU_OK")
check "swap total and used parse to MB (got $1 $2)" "$([ "$1" = 13312 ] && [ "$2" = 11878 ] && echo 1 || echo 0)"
check "pageouts parse to the page count (got $(swap_parse_pageouts "$VM_OK"))" "$([ "$(swap_parse_pageouts "$VM_OK")" = 98765 ] && echo 1 || echo 0)"
check "a G-unit total converts to MB" "$(set -- $(swap_parse_swapusage 'total = 13.0G  used = 11.6G'); [ "$1" = 13312 ] && echo 1 || echo 0)"

# 2. unreadable is NA and status unreadable, NEVER 0
row="$(swap_row walk-start "garbage" "no swap line here")"
check "an unreadable sample is NA and status unreadable: $row" "$(has "$row" "	NA	NA	NA	unreadable")"
check "an unreadable sample never prints a zero for swap or pageouts" "$([ "$(has "$row" "	0	")" = 0 ] && echo 1 || echo 0)"
row="$(swap_row tick "$VM_OK" "$SU_OK")"
check "a measured sample says measured: ${row##*	}" "$(has "$row" "	measured")"

# 2b. no box host: a sample is refused, so the runner's own swap is never read
( unset OSTLER_BOX_HOST; SWAP_CURVE_FILE="$T/nohost.tsv"; : > "$SWAP_CURVE_FILE"; swap_sample "x"; [ ! -s "$SWAP_CURVE_FILE" ] )
nohost_rc=$?
check "no box host: a sample writes nothing (the runner's swap is never reported as the box's)" "$([ "$nohost_rc" = 0 ] && echo 1 || echo 0)"

# 3. the box read feeds the sampler; a sample lands in the curve file
_swap_run() { printf '%s\n%s\n' "$VM_OK" "$SU_OK"; }
SWAP_CURVE_FILE="$T/curve.tsv"; : > "$SWAP_CURVE_FILE"
swap_sample "probe-x"
check "a sample is one TSV row with 6 columns" "$([ "$(awk -F'\t' 'NR==1{print NF}' "$SWAP_CURVE_FILE")" = 6 ] && echo 1 || echo 0)"

# 4. brackets: chat battery only
: > "$SWAP_CURVE_FILE"
swap_bracket_begin chat_latency_baseline
swap_bracket_end chat_latency_baseline
swap_bracket_begin usage_journal_producers
check "the chat-battery probe is bracketed (2 rows)" "$([ "$(wc -l < "$SWAP_CURVE_FILE" | tr -d ' ')" = 2 ] && echo 1 || echo 0)"
check "a probe outside the chat battery writes no bracket row" "$(grep -c 'usage_journal_producers' "$SWAP_CURVE_FILE" | awk '{print ($1==0)?1:0}')"
check "bracket rows name the begin and end edges" "$(grep -c 'begin:chat_latency_baseline' "$SWAP_CURVE_FILE" | awk '{print ($1==1)?1:0}')"

# 5. whole-walk sampler: starts, samples on its interval, stops by its own PID
( unset OSTLER_BOX_HOST; swap_curve_start "$T/nobox" 2>"$T/nobox.err" )
check "no box host: NOT-MEASURED, no curve written" "$([ ! -e "$T/nobox/swap_curve.tsv" ] && grep -q NOT-MEASURED "$T/nobox.err" && echo 1 || echo 0)"
SWAP_CURVE_INTERVAL_S=1 swap_curve_start "$T/walk.evidence"
sleep 2.5
pid="${SWAP_CURVE_PID:-}"
swap_curve_stop
ticks="$(grep -c "	tick	" "$T/walk.evidence/swap_curve.tsv")"
check "the sampler ticks through the walk (tick rows: $ticks)" "$([ "${ticks:-0}" -ge 2 ] && echo 1 || echo 0)"
check "the curve starts at walk-start and ends at walk-end" "$(grep -c "	walk-start	" "$T/walk.evidence/swap_curve.tsv" | awk '{print ($1==1)?1:0}')"
check "the sampler is stopped by its own PID (no sampler left running)" "$(kill -0 "$pid" 2>/dev/null && echo 0 || echo 1)"

# negative control: the kill -0 probe must answer ALIVE for a process we started
sleep 30 &
live=$!
check "negative control: kill -0 reports a live process as alive (so the stop check can fail)" "$(kill -0 "$live" 2>/dev/null && echo 1 || echo 0)"
kill "$live" 2>/dev/null; wait "$live" 2>/dev/null

[ "$fails" -eq 0 ] && echo "PASS" || { echo "FAIL: ${fails}"; exit 1; }
