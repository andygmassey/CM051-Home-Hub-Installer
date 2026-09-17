#!/bin/bash
# CM051 #2112. THE WIKI SUMMARY BACKFILL NEVER RAN, AND THE REASON WAS THAT
# IT WAS INVISIBLE TO THE THING IT WAS WAITING FOR.
#
# Measured three times on the clean v1.0.100 install: the backfill's pid file
# named a dead process and the log it should write was 0 bytes, while the
# email-bundle tick held the shared Ollama slot for 25+ minutes.
#
# The block hand-rolled its own lock on the SHARED slot directory: a bare
# `mkdir`, and one file written into it, `pid`. Two consequences.
#
#   1. Nobody could say who held the slot. The library records `holder`,
#      `acquired_at` and `max_hold` and its diagnostics print them. A
#      directory carrying only a pid is why the box could only report
#      holder=? and why the cause took three reproductions to find.
#
#   2. IT NEVER ENROLLED AS A WAITER. The holder's bounded-hold countdown
#      arms only when another feed is ENROLLED AND WAITING. A waiter that
#      spins on `mkdir` is invisible, so the holder was never told anybody
#      wanted the slot, kept it correctly, and the backfill waited for ever.
#      That is the root cause, and arm 2 is the arm that measures it.
#
# The test drives the SHIPPED launcher body out of install.sh and the SHIPPED
# library out of lib/, with `docker` stubbed. It reports CANNOT-RUN and exits
# 2 rather than passing on anything it could not extract.
#
# HAS IT EVER FAILED: arm 5 rebuilds the pre-fix hand-rolled loop every run
# and asserts it enrols NO waiter. A green arm 5 means the mutant did not
# apply and arm 2 proves nothing.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="${ROOT}/install.sh"
LIB="${ROOT}/lib/ostler-ingest-slot.sh"
for f in "$INSTALL" "$LIB"; do
    [ -r "$f" ] || { echo "CANNOT-RUN: ${f} is not readable."; exit 2; }
done

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
BODY="${WORK}/launcher.sh"

# The launcher body is the single-quoted script inside `nohup bash -c '...'`.
awk "/^        nohup bash -c '\$/ { f = 1; next }
     f && /^        ' _ \"\\\$_wiki_slot\"/ { exit }
     f { print }" "$INSTALL" > "$BODY"
BODY_LINES="$(grep -c . "$BODY" || true)"
if [ "${BODY_LINES:-0}" -lt 20 ]; then
    echo "CANNOT-RUN: extracted only ${BODY_LINES:-0} lines of the launcher body."
    echo "            The nohup block has moved; re-point the awk range rather"
    echo "            than deleting this test."
    exit 2
fi
echo "EXAMINED: ${BODY_LINES} lines of the SHIPPED launcher, and $(grep -c . "$LIB") lines of the SHIPPED slot library"

# The pre-fix launcher, rebuilt. Arm 5 runs the same predicate against it.
MUTANT="${WORK}/mutant.sh"
cat > "$MUTANT" <<'MUT'
set -u
_slot="$1"; _wd="$2"
cd "$_wd" || exit 1
mkdir -p "$(dirname "$_slot")" 2>/dev/null || true
while ! mkdir "$_slot" 2>/dev/null; do
    _h="$(cat "$_slot/pid" 2>/dev/null || true)"
    if [ -n "${_h:-}" ] && kill -0 "$_h" 2>/dev/null; then
        sleep 1
    else
        rm -rf "$_slot" 2>/dev/null || true
    fi
done
printf "%s\n" "$$" > "$_slot/pid"
trap "rm -rf \"$_slot\" 2>/dev/null || true" EXIT
docker compose --profile compile run --rm -T wiki-compiler </dev/null
MUT

BIN="${WORK}/bin"; mkdir -p "$BIN"
printf '#!/bin/bash\necho "STUB docker $*"\nexit 0\n' > "${BIN}/docker"
chmod +x "${BIN}/docker"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        | /'; return 0; }

# fresh <name> -> a clean fake box, printing its root
fresh() {
    local h="${WORK}/$1"
    rm -rf "$h"; mkdir -p "$h/.ostler/lib" "$h/.ostler/workspace" "$h/wd"
    cp "$LIB" "$h/.ostler/lib/ostler-ingest-slot.sh"
    printf '%s\n' "$h"
}

# launch <script> <home> <logfile> [&] -- runs the launcher with a tiny
# patience so a yield takes seconds, not minutes.
launch() {
    local scr="$1" h="$2" log="$3"
    PATH="${BIN}:${PATH}" HOME="$h" \
    OSTLER_STATE_DIR="$h/.ostler/workspace" \
    OSTLER_SLOT_WAIT_SECS=1 OSTLER_SLOT_POLL_SECS=1 OSTLER_SLOT_GRACE_SECS=0 \
    /bin/bash "$scr" "$h/.ostler/workspace/ingest-ollama.lock.d" "$h/wd" \
              "$h/.ostler/lib/ostler-ingest-slot.sh" > "$log" 2>&1
}

echo
echo "ARM 1: an uncontended slot, and what the lock directory now records"
H="$(fresh a)"; LOG="${WORK}/a.log"
launch "$BODY" "$H" "$LOG"; rc=$?
SLOT="$H/.ostler/workspace/ingest-ollama.lock.d"
[ "$rc" -eq 0 ] && ok "(1a) the backfill runs the compile and exits 0" || no "(1a) exit $rc" "$(cat "$LOG")"
grep -q 'STUB docker' "$LOG" && ok "(1b) the compile was actually invoked" || no "(1b) docker was never called" "$(cat "$LOG")"
[ -s "$LOG" ] && ok "(1c) the log is NOT 0 bytes, which was the reported symptom" || no "(1c) the log is empty"
[ -d "$SLOT" ] && no "(1d) the slot was left behind, so the next compile is blocked" || ok "(1d) the slot is released on exit"

echo
echo "ARM 2: THE ROOT CAUSE. A contended slot must make the backfill ENROL,"
echo "       because a holder's bounded hold arms only for an enrolled waiter."
H="$(fresh b)"; LOG="${WORK}/b.log"
SLOT="$H/.ostler/workspace/ingest-ollama.lock.d"
WAITERS="$H/.ostler/workspace/ingest-ollama.lock.waiters.d"
# A LIVE foreign holder, recorded the way the library records one.
sleep 120 & HOLDER=$!
mkdir -p "$SLOT"
printf '%s\n' "$HOLDER" > "$SLOT/pid"
printf '%s\n' "email-bundle" > "$SLOT/holder"
printf '%s\n' "$(date +%s)" > "$SLOT/acquired_at"
printf '%s\n' "180" > "$SLOT/max_hold"
launch "$BODY" "$H" "$LOG" &
LPID=$!
enrolled=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if [ -d "$WAITERS" ] && [ -n "$(ls -A "$WAITERS" 2>/dev/null || true)" ]; then enrolled=1; break; fi
    sleep 1
done
[ "$enrolled" -eq 1 ] \
    && ok "(2) the backfill ENROLS as a waiter, so the holder's bounded hold can arm" \
    || no "(2) no waiter was enrolled: the holder is never told anybody wants the slot, which is #2112"
# The holder now goes away, as a real tick does when its bounded hold
# expires. The backfill must then TAKE the slot and compile, which is the
# whole point: it waited rather than dying, and it noticed.
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
rm -rf "$SLOT" 2>/dev/null || true
wait "$LPID" 2>/dev/null; brc=$?
[ -s "$LOG" ] \
    && ok "(2b) a contended backfill still writes to its log, every attempt" \
    || no "(2b) the contended path produced a 0-byte log, which is the reported symptom"
grep -q 'email-bundle' "$LOG" \
    && ok "(2c) the log NAMES the holder, where the box could only say holder=?" \
    || no "(2c) the holder is not named anywhere in the log" "$(cat "$LOG")"
grep -q 'STUB docker' "$LOG" \
    && ok "(2d) once the holder releases, the backfill takes the slot and compiles" \
    || no "(2d) the backfill never compiled even after the slot came free" "$(cat "$LOG")"
[ "$brc" -eq 0 ] \
    && ok "(2e) and exits 0, so the contended path is a delay and not a failure" \
    || no "(2e) the contended path exited $brc" "$(cat "$LOG")"

echo
echo "ARM 3: a missing library is CANNOT-RUN and says so, never a silent fallback"
H="$(fresh c)"; rm -f "$H/.ostler/lib/ostler-ingest-slot.sh"; LOG="${WORK}/c.log"
launch "$BODY" "$H" "$LOG"; rc=$?
[ "$rc" -eq 2 ] && ok "(3a) exits 2, the CANNOT-RUN code, not 0 and not 1" || no "(3a) exit $rc" "$(cat "$LOG")"
grep -q 'CANNOT-RUN' "$LOG" && ok "(3b) and says CANNOT-RUN in the log" || no "(3b)" "$(cat "$LOG")"
grep -q 'STUB docker' "$LOG" && no "(3c) it compiled anyway, unarbitrated" || ok "(3c) it did NOT compile without arbitration"

echo
echo "ARM 4: the launcher records WHY it carries no max-hold watchdog"
grep -qF 'unbounded_reason' "$BODY" \
    && ok "(4) the reason is written into the lock dir, not left in a comment" \
    || no "(4) a reader of the lock dir cannot tell why this holder is unbounded"

echo
echo "ARM 5: THE MUTANT. The pre-fix hand-rolled loop must enrol NOTHING."
H="$(fresh e)"; LOG="${WORK}/e.log"
SLOT="$H/.ostler/workspace/ingest-ollama.lock.d"
WAITERS="$H/.ostler/workspace/ingest-ollama.lock.waiters.d"
sleep 20 & HOLDER=$!
mkdir -p "$SLOT"; printf '%s\n' "$HOLDER" > "$SLOT/pid"
PATH="${BIN}:${PATH}" HOME="$H" OSTLER_STATE_DIR="$H/.ostler/workspace" \
    /bin/bash "$MUTANT" "$SLOT" "$H/wd" > "$LOG" 2>&1 &
MPID=$!
sleep 6
if [ -d "$WAITERS" ] && [ -n "$(ls -A "$WAITERS" 2>/dev/null || true)" ]; then
    no "(5) the pre-fix loop ALSO enrolled a waiter, so arm 2 proves nothing"
else
    ok "(5) the pre-fix loop enrols no waiter, which is exactly the defect"
fi
[ -s "$LOG" ] && no "(5b) the pre-fix loop wrote a log while blocked, so arm 2b proves nothing" \
              || ok "(5b) the pre-fix loop is SILENT while blocked: the 0-byte log, reproduced"
kill "$MPID" 2>/dev/null; wait "$MPID" 2>/dev/null
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null

echo
echo "=== ${PASS} passed / ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
