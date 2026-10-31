#!/bin/bash
# scripts/bounded_step.sh <bound_s> <progress_file> -- <cmd> [args...]
#
# Runs <cmd> in its own process group and waits at most <bound_s>. On expiry it prints
# where the command is stuck (process tree, a `sample` of the deepest live child, the
# command's own progress file), kills the group and every descendant, and exits 1.
# A hang becomes a readable RED. Never a skip, never exit 0.
#
# The command learns the progress file path as $STEP_PROGRESS_FILE.
# Otherwise the exit code is the command's. bash 3.2 and BSD tools only.
set -uo pipefail

[ "$#" -ge 4 ] && [ "$3" = -- ] || { echo "usage: bounded_step.sh <bound_s> <progress_file> -- <cmd> [args...]" >&2; exit 2; }
BOUND="$1"; PROG="$2"; shift 3
case "$BOUND" in ''|*[!0-9]*) echo "bounded_step: bound_s must be a whole number, got '${BOUND}'" >&2; exit 2 ;; esac
: > "$PROG" || { echo "bounded_step: cannot write ${PROG}" >&2; exit 2; }
EXPIRED="${PROG}.expired"
rm -f "$EXPIRED"

descendants() { # descendants <pid>: every live descendant, depth first
    local k
    for k in $(pgrep -P "$1"); do echo "$k"; descendants "$k"; done
}

kill_group() { # kill_group <leader>: the whole group plus every descendant, even a setsid'd one
    local pids sig p
    pids="$(descendants "$1")"
    for sig in TERM KILL; do
        kill -CONT -- "-$1" 2>/dev/null
        kill "-$sig" -- "-$1" 2>/dev/null
        for p in $pids; do kill "-$sig" "$p" 2>/dev/null; done
        [ "$sig" = TERM ] && sleep 2
    done
}

bounded() { # bounded <secs> <cmd...>: a diagnostic must not become the next hang
    local secs="$1" bpid i=0; shift
    "$@" &
    bpid=$!
    while kill -0 "$bpid" 2>/dev/null && [ "$i" -lt "$secs" ]; do sleep 1; i=$((i + 1)); done
    if kill -0 "$bpid" 2>/dev/null; then echo "(diagnostic '$1' still running after ${secs}s, killed)"; kill -KILL "$bpid" 2>/dev/null; fi
    wait "$bpid" 2>/dev/null
    return 0
}

dump() { # dump <leader>
    local lead="$1" desc deepest cur kids
    desc=" $(descendants "$lead" | tr '\n' ' ')"
    echo "::group::BOUNDED-STEP DIAGNOSTIC (leader ${lead})"
    echo "--- ps: process group ${lead} and descendants"
    ps -axo pid,ppid,pgid,stat,etime,command | awk -v pg="$lead" -v d="$desc" 'NR==1 || $3==pg || $1==pg || index(d, " " $1 " ")'
    cur="$lead"
    while kids="$(pgrep -P "$cur")"; [ -n "$kids" ]; do cur="$(echo "$kids" | tail -n 1)"; done
    deepest="$cur"
    echo "--- deepest live child: pid ${deepest}"
    if command -v sample >/dev/null 2>&1; then
        echo "--- sample ${deepest} 1"
        SF="$(mktemp "${TMPDIR:-/tmp}/bounded-sample.XXXXXX")"
        bounded 20 sample "$deepest" 1 -file "$SF"
        sed '/^Total number in stack/q' "$SF"   # keep the call graph, drop the 60-line image list
        rm -f "$SF"
    elif command -v lsof >/dev/null 2>&1; then
        echo "--- lsof -p ${deepest}"
        bounded 20 lsof -p "$deepest"
    else
        echo "NOT INSTRUMENTED: neither sample nor lsof on PATH"
    fi
    echo "--- progress file ${PROG}"
    cat "$PROG"
    echo "::endgroup::"
}

set -m   # job control: the command becomes the leader of its own process group
export STEP_PROGRESS_FILE="$PROG"
"$@" &
PID=$!
echo "$PID" > "${PROG}.pgid"
echo "bounded_step: pid/pgid ${PID}, bound ${BOUND}s, progress ${PROG}"

trap 'kill_group "$PID"; exit 143' INT TERM HUP

( sleep "$BOUND"; : > "$EXPIRED"; echo "RED: BOUNDED-STEP EXPIRED after ${BOUND}s: $*"; dump "$PID"; kill_group "$PID" ) &
TIMER=$!

wait "$PID"; RC=$?
if [ -e "$EXPIRED" ]; then
    wait "$TIMER"
    rm -f "$EXPIRED"
    echo "RED: step exceeded ${BOUND}s, group killed (command rc ${RC})"
    exit 1
fi
kill -KILL -- "-$TIMER" 2>/dev/null
exit "$RC"
