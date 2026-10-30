#!/bin/bash
# stop_orphan_ticks.sh -- stop the Ostler tick scripts that outlived their agents.
#
# usage: stop_orphan_ticks.sh [ostler_root]      (default: ${HOME}/.ostler)
#
# MEASURED on a v1.0.121 trial box: after the uninstaller and its bootouts, an
# orphaned wiki-recompile-tick.sh (PPID 1) kept running and blocked the next
# install's reset. install.sh starts that tick with `nohup ... &`, not through
# launchd, so no bootout can reach it.
#
# Installed as ~/.ostler/bin/ostler-stop-background (no .sh suffix, so the
# *tick*.sh enumeration below can never match this file) and called by the
# generated ostler-uninstall straight after its LaunchAgent bootout loop.
#
# MATCHED NARROWLY, NEVER BY PATTERN. The candidates are the *tick*.sh FILES
# under the root, enumerated at run time so a tick added later is covered the
# day it ships. A process is stopped only when BOTH hold:
#   (a) it runs as this user's uid, and
#   (b) its command line carries one of those exact paths as a whole argument.
# A same-named script anywhere else (a user's own mytick.sh), or another
# user's process, is never touched; there is no `pkill -f`. Children of a
# matched tick (same uid) go with it. Our own pid and parent are excluded.
#
# THEN IT VERIFIES (signalable and not a zombie). Survivors are named by pid
# and command line on stdout.
#
# Exit: 0 nothing left running (including: nothing to stop), 3 survivors.
# Runs under /bin/bash 3.2.
set -u

root="${1:-${HOME}/.ostler}"
[[ -d "$root" ]] || exit 0
uid="$(id -u)"
ticks="$(find "$root" -type f -name '*tick*.sh' 2>/dev/null || true)"
[[ -n "$ticks" ]] || exit 0

alive() {  # $1 = pid
    kill -0 "$1" 2>/dev/null || return 1
    case "$(ps -o stat= -p "$1" 2>/dev/null || true)" in Z*) return 1 ;; esac
    return 0
}

pids=" "; grew=1; waited=0; live=""
ps_all="$(ps -axww -o pid= -o uid= -o args= 2>/dev/null || true)"
while IFS= read -r line; do
    read -r pid puid args <<< "$line" || true
    [[ -n "$pid" && "$puid" == "$uid" ]] || continue
    [[ "$pid" != "$$" && "$pid" != "${PPID:-0}" ]] || continue
    while IFS= read -r t; do
        case " ${args} " in *" ${t} "*) pids="${pids}${pid} "; break ;; esac
    done <<< "$ticks"
done <<< "$ps_all"
[[ "$pids" != " " ]] || exit 0

# Children (same uid), to any depth.
while [[ "$grew" -eq 1 ]]; do
    grew=0
    while read -r pid ppid puid; do
        [[ -n "$pid" && "$puid" == "$uid" ]] || continue
        case "$pids" in *" ${ppid} "*) ;; *) continue ;; esac
        case "$pids" in *" ${pid} "*) continue ;; esac
        [[ "$pid" != "$$" ]] || continue
        pids="${pids}${pid} "; grew=1
    done <<< "$(ps -axo pid= -o ppid= -o uid= 2>/dev/null || true)"
done

n="$(echo $pids | wc -w | tr -d ' ')"
echo "  Stopping ${n} Ostler background task(s) still running after their agents were unloaded..."
kill -TERM $pids 2>/dev/null || true
while [[ "$waited" -lt 20 ]]; do
    live=""
    for pid in $pids; do alive "$pid" && live="${live} ${pid}"; done
    [[ -n "$live" ]] || exit 0
    sleep 0.25; waited=$((waited + 1))
done
kill -KILL $live 2>/dev/null || true
sleep 0.25
survivors=""
for pid in $live; do
    alive "$pid" || continue
    survivors="${survivors}      pid ${pid}: $(ps -ww -o args= -p "$pid" 2>/dev/null || true)
"
done
if [[ -n "$survivors" ]]; then
    echo "  WARNING: these Ostler background tasks could not be stopped (restart this Mac to end them):"
    printf '%s' "$survivors"
    exit 3
fi
exit 0
