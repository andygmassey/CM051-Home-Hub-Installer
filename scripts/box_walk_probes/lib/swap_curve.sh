#!/usr/bin/env bash
# lib/swap_curve.sh -- swap and pageout curve over the WHOLE walk, plus a
# bracket around the chat-battery probes.
#
# Walk 131 ended with 11.6 of 13.3 GB of swap in use, and nothing recorded how
# it got there. This samples the box every SWAP_CURVE_INTERVAL_S seconds
# (default 60) for the life of the walk, and writes each sample to
# <evidence dir>/swap_curve.tsv. Columns, tab-separated:
#   utc  label  swap_total_mb  swap_used_mb  pageouts_pages  status
# status is "measured" or "unreadable". An unreadable sample is NA, never 0:
# "could not look" and "found nothing" must print differently.
#
# Read-only on the box: vm_stat and sysctl -n vm.swapusage, nothing else.
# The sampler is a loop on the WALK RUNNER, one ssh call per tick, stopped by
# its own PID. Nothing is left running on the box.
#
# bash 3.2, BSD userland. No em dashes.

SWAP_CHAT_BATTERY="assistant_answers_grounded assistant_grounds_the_opening_turn chat_latency_baseline dislike_respected_in_brief"

# The one place the box is read. Tests replace this function.
_swap_run() {
    if declare -F _walk_box_exec >/dev/null; then
        _walk_box_exec 'vm_stat; sysctl -n vm.swapusage'
    else
        box_run 'vm_stat; sysctl -n vm.swapusage' 2>/dev/null
    fi
}

# "total = 2048.00M  used = 1523.44M  free = 524.56M  (encrypted)" -> "2048 1523"
# Units K, M or G. Anything else prints "NA NA".
swap_parse_swapusage() {
    local t="$1" re_total re_used tot used
    re_total='total = ([0-9.]+)([KMG])'
    re_used='used = ([0-9.]+)([KMG])'
    if [[ $t =~ $re_total ]]; then
        tot="$(_swap_to_mb "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}")"
    else
        tot="NA"
    fi
    if [[ $t =~ $re_used ]]; then
        used="$(_swap_to_mb "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}")"
    else
        used="NA"
    fi
    printf '%s %s\n' "$tot" "$used"
}

_swap_to_mb() {
    case "$2" in
        K) awk -v v="$1" 'BEGIN { printf "%d", v / 1024 }' ;;
        M) awk -v v="$1" 'BEGIN { printf "%d", v }' ;;
        G) awk -v v="$1" 'BEGIN { printf "%d", v * 1024 }' ;;
    esac
}

# "Pageouts:                      12345." -> "12345", else "NA".
swap_parse_pageouts() {
    local t="$1" re='Pageouts:[[:space:]]+([0-9]+)\.'
    if [[ $t =~ $re ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    else
        printf 'NA\n'
    fi
}

# swap_row <label> <vm_stat text> <swapusage text> -> one TSV row on stdout.
# Both inputs must parse for status=measured. Either NA makes it unreadable.
swap_row() {
    local label="$1" vm="$2" su="$3" utc tot used po status
    utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    set -- $(swap_parse_swapusage "$su")
    tot="$1"; used="$2"
    po="$(swap_parse_pageouts "$vm")"
    status="measured"
    if [ "$tot" = "NA" ] || [ "$used" = "NA" ] || [ "$po" = "NA" ]; then
        status="unreadable"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$utc" "$label" "$tot" "$used" "$po" "$status"
}

# Writes one sample of the box to the curve file. Never raises.
swap_sample() {
    local label="${1:-tick}" out vm su file="${SWAP_CURVE_FILE:-}"
    [ -n "$file" ] || return 0
    # No box host means nothing to measure. Without this guard the read would
    # run on the walk runner and print the RUNNER's swap as the box's.
    [ -n "${OSTLER_BOX_HOST:-}" ] || return 0
    out="$(_swap_run)" || out=""
    # vm_stat and the swap line arrive as one stream; split on the marker line.
    vm="$(printf '%s\n' "$out" | sed -n '/Pageouts/p; /page size/p')"
    su="$(printf '%s\n' "$out" | sed -n '/total = /p')"
    swap_row "$label" "$vm" "$su" >> "$file"
}

# swap_curve_start <evidence dir>. Starts the whole-walk sampler, once.
swap_curve_start() {
    local dir="$1" iv="${SWAP_CURVE_INTERVAL_S:-60}"
    if [ -z "${OSTLER_BOX_HOST:-}" ]; then
        echo "swap curve: NOT-MEASURED, no box host (OSTLER_BOX_HOST unset); nothing sampled" >&2
        return 0
    fi
    mkdir -p "$dir" || return 0
    SWAP_CURVE_FILE="${dir}/swap_curve.tsv"
    export SWAP_CURVE_FILE
    printf '# swap and pageout curve, one row per sample (see lib/swap_curve.sh)\n' > "$SWAP_CURVE_FILE"
    printf 'utc\tlabel\tswap_total_mb\tswap_used_mb\tpageouts_pages\tstatus\n' >> "$SWAP_CURVE_FILE"
    swap_sample "walk-start"
    # The loop stops itself when the walk's own shell is gone (kill -0 on $$),
    # so no exit path of the caller can leave a sampler ssh-ing to the box.
    local owner=$$
    (
        trap 'exit 0' TERM
        while kill -0 "$owner" 2>/dev/null; do
            sleep "$iv" &
            wait $!
            swap_sample "tick"
        done
    ) &
    SWAP_CURVE_PID=$!
    export SWAP_CURVE_PID
    printf '%s\n' "$SWAP_CURVE_PID" > "${dir}/swap_curve.pid"
}

# swap_curve_stop: stops the sampler by its own PID and marks the walk end.
swap_curve_stop() {
    if [ -n "${SWAP_CURVE_PID:-}" ]; then
        kill "$SWAP_CURVE_PID" 2>/dev/null
        wait "$SWAP_CURVE_PID" 2>/dev/null
        SWAP_CURVE_PID=""
    fi
    [ -n "${SWAP_CURVE_FILE:-}" ] && swap_sample "walk-end"
}

# Bracket around one probe, for the chat battery only.
swap_bracket_begin() {
    case " $SWAP_CHAT_BATTERY " in *" ${1:-} "*) swap_sample "begin:${1}" ;; esac
}
swap_bracket_end() {
    case " $SWAP_CHAT_BATTERY " in *" ${1:-} "*) swap_sample "end:${1}" ;; esac
}
