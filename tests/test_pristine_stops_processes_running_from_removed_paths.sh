#!/usr/bin/env bash
# tests/test_pristine_stops_processes_running_from_removed_paths.sh
#
# Before the v1.0.102 fourth walk the Mini16 still ran, a day after
# box_pristine.sh had called it pristine, ostler-hub from the deleted
# /Applications/Ostler.app, SafariHistoryExt from the deleted
# /Applications/Ostler, and `tail -f ~/.ostler/logs/install.log`. A deleted
# but running hub can answer a walk's probes as the OLD binary.
#
# This lifts the REAL process functions out of box_pristine.sh and runs them
# against a SANDBOX only: PATHS is overridden to two sandbox roots, so nothing
# outside the sandbox can be matched or signalled on the machine running the
# test. Three planted processes: an executable under a removed "app" root, an
# executable under the sandbox ~/.ostler, and /bin/sleep whose ARGV names a
# path under the sandbox ~/.ostler (the tail shape). Plus a control process
# outside every root that must be left running.
set -euo pipefail
[ "$(uname -s)" = "Darwin" ] || { echo "CANNOT-RUN: macOS-only (box_pristine.sh runs on a Mac; ps comm is a path only there)"; exit 2; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/scripts/box_pristine.sh"
SB="$(mktemp -d)"; PIDS=""
cleanup() { for p in $PIDS; do kill -KILL "$p" 2>/dev/null || true; done; rm -rf "$SB"; }
trap cleanup EXIT

awk '/^_pristine_roots\(\) \{/{f=1} f{print} f&&/^_pristine_stop_procs$/{exit}' "$SRC" | sed '$d' > "$SB/fns.sh"
if [ "$(grep -c '^_pristine_procs() {' "$SB/fns.sh")" -ne 1 ] || [ "$(grep -c '^_pristine_stop_procs() {' "$SB/fns.sh")" -ne 1 ]; then
    echo "FAIL: box_pristine.sh has no process stop (_pristine_procs / _pristine_stop_procs): a process running from a removed path survives the reset"
    exit 1
fi

H="$SB/home"; APP="$SB/Applications/Ostler.app"; OUT="$SB/outside"
mkdir -p "$H/.ostler/logs" "$APP/Contents/MacOS" "$OUT"
# A tiny sleeper compiled here, because a COPIED Apple platform binary is
# SIGKILLed on launch from a new path even after an ad-hoc re-sign (measured
# on the dev Mac: every copy died before ps could see it, which read as "not
# detected" and "stopped" at once). macOS-only, like the script under test.
command -v cc >/dev/null 2>&1 || { echo "CANNOT-RUN: no C compiler to build the sleeper"; exit 2; }
printf '#include <stdlib.h>\n#include <unistd.h>\nint main(int c,char**v){sleep(c>1?atoi(v[1]):300);return 0;}\n' > "$SB/s.c"
cc -o "$SB/sleeper" "$SB/s.c" || { echo "CANNOT-RUN: could not build the sleeper"; exit 2; }
for _dst in "$APP/Contents/MacOS/ostler-hub" "$H/.ostler/worker" "$OUT/bystander"; do cp "$SB/sleeper" "$_dst"; done
: > "$H/.ostler/logs/install.log"
"$APP/Contents/MacOS/ostler-hub" 300 & PIDS="$PIDS $!"; P_APP=$!
"$H/.ostler/worker" 300 & PIDS="$PIDS $!"; P_DOT=$!
"$SB/sleeper" 300 "$H/.ostler/logs/install.log" & PIDS="$PIDS $!"; P_ARG=$!
"$OUT/bystander" 300 & PIDS="$PIDS $!"; P_OUT=$!
sleep 0.5

fails=0
seen="$(HOME="$H" DRY=0 bash -c '
    PATHS=("$HOME/.ostler|dot" "'"$APP"'|app")
    . "'"$SB/fns.sh"'"
    _pristine_procs | cut -f1 | sort -u | tr "\n" " "
')"
for p in "$P_APP" "$P_DOT"; do
    case " $seen " in *" $p "*) echo "ok    detected pid $p under a removed path" ;; *) echo "FAIL  pid $p under a removed path was not detected"; fails=$((fails+1)) ;; esac
done
# The argv shape (tail -f ~/.ostler/...) is reported by the args pass.
case " $seen " in *" $P_ARG "*) echo "ok    detected pid $P_ARG by an argv naming ~/.ostler" ;; *) echo "FAIL  argv-only process not detected"; fails=$((fails+1)) ;; esac
case " $seen " in *" $P_OUT "*) echo "FAIL  bystander outside every root was matched"; fails=$((fails+1)) ;; *) echo "ok    bystander outside every root not matched" ;; esac

HOME="$H" DRY=0 bash -c '
    PATHS=("$HOME/.ostler|dot" "'"$APP"'|app")
    . "'"$SB/fns.sh"'"
    _pristine_stop_procs >/dev/null
'
sleep 0.5
for p in "$P_APP" "$P_DOT" "$P_ARG"; do
    if kill -0 "$p" 2>/dev/null; then echo "FAIL  pid $p still running after the stop"; fails=$((fails+1)); else echo "ok    pid $p stopped"; fi
done
if kill -0 "$P_OUT" 2>/dev/null; then echo "ok    bystander left running"; else echo "FAIL  bystander was killed"; fails=$((fails+1)); fi

[ "$fails" -eq 0 ] && { echo "PASS: pristine stops what runs from a removed path, and nothing else"; exit 0; }
echo "FAIL: $fails arm(s)"; exit 1
