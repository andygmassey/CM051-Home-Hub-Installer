#!/bin/bash
# tests/test_a_hung_slot_holder_is_stopped.sh spawns CPU burners. When it was
# killed or timed out they were orphaned to launchd and burned a core forever
# (2026-10-22: six of them, Mac at load ~600). This starts that test, signals
# it mid-run, and counts the burners still alive afterwards.
#
# Burners are found by an env tag every descendant inherits (ps -E), never by
# command pattern, and only tagged PIDs are ever killed.
#   TARGET   test to run (default: the real one; the mutant arm points it at a
#            copy with the trap lines removed)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
TARGET="${TARGET:-tests/test_a_hung_slot_holder_is_stopped.sh}"
[ -f "$TARGET" ] || { echo "CANNOT-RUN: $TARGET missing"; exit 2; }
fails=0
TAGS=()
OUTD="$(mktemp -d)"

tagged_pids() { # <tag>: PIDs of live processes carrying the tag in their environment
    local d
    if [ -d /proc/self ]; then   # Linux: read each environ, ps -E does not exist
        for d in /proc/[0-9]*; do
            /usr/bin/grep -qaF -- "OSTLER_BURN_TAG=$1" "$d/environ" 2>/dev/null && echo "${d#/proc/}"
        done
    else                          # macOS/BSD: ps -E appends the environment
        ps -axwwE -o pid=,command= 2>/dev/null | /usr/bin/grep -F -- "OSTLER_BURN_TAG=$1" \
            | /usr/bin/grep -vF 'grep' | awk '{print $1}'
    fi
}
burners() { # <tag>: count of tagged busy loops (pcpu>0 or a while-loop shell)
    local n=0 p
    for p in $(tagged_pids "$1"); do
        case "$(ps -o command= -p "$p" 2>/dev/null)" in
            *test_a_hung_slot*|*probe.sh*|*"sleep "*|"") ;;
            *) n=$((n + 1)) ;;
        esac
    done
    echo "$n"
}
alive_any() { [ -n "$(tagged_pids "$1")" ]; }
reap() { local t p; for t in "${TAGS[@]:-}"; do [ -n "$t" ] || continue
    for p in $(tagged_pids "$t"); do kill -KILL "$p" 2>/dev/null; done; done; return 0; }
trap 'reap; rm -rf "$OUTD"' EXIT
trap 'reap; exit 143' INT TERM HUP

start() { # <tag>: run the target with the tag; sets T_PID
    local tag="$1"; TAGS+=("$tag")
    OSTLER_BURN_TAG="$tag" bash "$TARGET" >"$OUTD/$tag.out" 2>&1 &
    T_PID=$!
}
wait_burning() { # <tag> [pipeline]: until a burner exists (max 80s); "pipeline"
    # waits for the third case's `( loop ) | cat`, the one that leaked on main.
    local i=0 p; while [ "$i" -lt 400 ]; do
        if [ "${2:-}" = pipeline ]; then
            for p in $(tagged_pids "$1"); do
                case "$(ps -o command= -p "$p" 2>/dev/null)" in "bash -c "*) return 0 ;; esac
            done
        elif [ "$(burners "$1")" -gt 0 ]; then return 0; fi
        sleep 0.2; i=$((i + 1)); done; return 1
}
check() { # <label> <leftover> 
    if [ "$2" = "0" ]; then echo "  ok   $1 (leftover=0)"
    else echo "  FAIL $1 (leftover=$2)"; fails=$((fails + 1)); fi
}

# A: the test runs to completion. It must pass AND leave nothing behind.
tagA="nbA$$"; start "$tagA"
wait "$T_PID"; rcA=$?
sleep 1
[ "$rcA" = 0 ] && echo "  ok   the test itself passes (rc=0)" || { echo "  FAIL the test itself failed (rc=$rcA)"; sed 's/^/    | /' "$OUTD/$tagA.out"; fails=$((fails + 1)); }
check "normal completion leaves no burner" "$(burners "$tagA")"

# B: SIGTERM mid-run (a timeout kill).
tagB="nbB$$"; start "$tagB"
if wait_burning "$tagB"; then
    kill -TERM "$T_PID"; wait "$T_PID" 2>/dev/null; sleep 2
    check "SIGTERM mid-run leaves no burner" "$(burners "$tagB")"
else echo "  CANNOT-RUN: no burner appeared for SIGTERM arm"; fails=$((fails + 1)); fi

# C: SIGKILL mid-run (untrappable). The probe finishes its own bounded run and
# cleans up, and every burner self-limits, so none may remain after the grace.
tagC="nbC$$"; start "$tagC"
if wait_burning "$tagC" pipeline; then
    kill -KILL "$T_PID"; wait "$T_PID" 2>/dev/null
    i=0; while [ "$i" -lt 25 ] && alive_any "$tagC"; do sleep 1; i=$((i + 1)); done
    check "SIGKILL mid-run leaves no burner after the grace" "$(burners "$tagC")"
else echo "  CANNOT-RUN: no burner appeared for SIGKILL arm"; fails=$((fails + 1)); fi

echo
[ "$fails" = 0 ] && { echo "All cases passed."; exit 0; }
echo "$fails case(s) failed."; exit 1
