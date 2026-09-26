#!/bin/bash
# A live chat turn outranks every background feed on the shared model slot
# (#2385).
#
# WHY: the daemon touches interactive-chat.active when a live turn starts, but
# only the ticks' START looked at it. MEASURED on the v1.0.102 walk box: a feed
# waiting as "starving" took the slot the moment the holder let go and
# dispatched a summary 62s into a live turn, and an in-flight summary kept the
# one model busy while the user waited (live replies 287s, 308s, 900s timeout).
#
# Drives the REAL lib functions in a sandbox (OSTLER_STATE_DIR is a temp dir, so
# the marker is the sandbox's, never the machine's). Arms:
#   A  acquire with a FRESH marker refuses the slot           (RED on main)
#   B  a holder's payload is stopped within a few polls when  (RED on main)
#      a live chat starts, and the stop is recorded as a preempt
#   C  a waiter that is polling gives up when chat starts,    (RED on main)
#      and does not take the freed slot
# Controls, each must stay GREEN on main and on the fix:
#   D  STALE marker (older than the TTL): acquire takes the slot
#   E  NO marker: acquire takes the slot
#   F  TTL=0 disables the check: acquire takes the slot despite a fresh marker
#   G  holder with no chat: payload is left running
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
LIB="lib/ostler-ingest-slot.sh"
[ -f "$LIB" ] || { echo "CANNOT-RUN: $LIB missing"; exit 2; }
fails=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fails=$((fails+1)); }

# probe <ws> <body>: run body in a fresh shell with the lib sourced in the sandbox
probe() {
    local ws="$1" body="$2"
    cat > "$ws/probe.sh" <<PROBE
export OSTLER_STATE_DIR="$ws"
unset OSTLER_INTERACTIVE_MARKER
export OSTLER_SLOT_POLL_SECS=1
export OSTLER_SLOT_MAX_HOLD_SECS=3600
export OSTLER_SLOT_STALL_SECS=0
export OSTLER_SLOT_WAIT_SECS=30
${EXTRA_ENV:-}
. "$PWD/$LIB"
$body
PROBE
    bash "$ws/probe.sh" 2>/dev/null
}
fresh_marker() { : > "$1/interactive-chat.active"; }
stale_marker() { : > "$1/interactive-chat.active"; touch -t "$(date -v-10M +%Y%m%d%H%M.%S 2>/dev/null || date -d '-10 min' +%Y%m%d%H%M.%S)" "$1/interactive-chat.active"; }

# ── A: acquire refuses while chat is live ─────────────────────────────
ws="$(mktemp -d)"; fresh_marker "$ws"
got="$(probe "$ws" 'if ostler_slot_acquire feedA >/dev/null 2>&1; then echo TOOK; else echo REFUSED; fi')"
[ "$got" = "REFUSED" ] && ok "A: acquire refuses the slot while a live chat is fresh" || bad "A: acquire with a fresh chat marker: expected REFUSED, got ${got:-nothing}"
rm -rf "$ws"

# ── B: a running holder is stopped when chat starts ──────────────────
ws="$(mktemp -d)"
got="$(probe "$ws" '
ostler_slot_acquire feedB >/dev/null 2>&1 || { echo NOACQ; exit 0; }
( sleep 3; : > "$OSTLER_STATE_DIR/interactive-chat.active" ) &
t0=$(date +%s)
# bounded at 25s so an unpatched lib FAILS on elapsed time instead of hanging
ostler_slot_run bash -c "for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25; do sleep 1; done" >/dev/null 2>&1
t1=$(date +%s)
pre=$(_ostler_slot_state_get feedB preempt_count)
echo "ELAPSED=$((t1-t0)) PREEMPT=${pre:-0}"
')"
el="$(printf '%s' "$got" | sed -n 's/.*ELAPSED=\([0-9]*\).*/\1/p')"
pc="$(printf '%s' "$got" | sed -n 's/.*PREEMPT=\([0-9]*\).*/\1/p')"
if [ -n "$el" ] && [ "$el" -le 15 ] && [ "${pc:-0}" -ge 1 ]; then
    ok "B: holder stopped ${el}s after start (chat at 3s), recorded as a preempt"
else
    bad "B: holder with a live chat starting at 3s: expected stop within 15s and a preempt, got ${got:-nothing}"
fi
rm -rf "$ws"

# ── C: a polling waiter gives up when chat starts ─────────────────────
ws="$(mktemp -d)"
got="$(probe "$ws" '
# a live foreign holder: take the slot in a subshell that stays alive
( ostler_slot_acquire holderC >/dev/null 2>&1; sleep 6; ostler_slot_release >/dev/null 2>&1 ) &
sleep 1
( sleep 2; : > "$OSTLER_STATE_DIR/interactive-chat.active" ) &
if ostler_slot_acquire waiterC >/dev/null 2>&1; then echo TOOK; else echo GAVEUP; fi
')"
[ "$got" = "GAVEUP" ] && ok "C: a waiting feed gives up when a live chat starts" || bad "C: waiter with a chat starting mid-wait: expected GAVEUP, got ${got:-nothing}"
rm -rf "$ws"

# ── controls ──────────────────────────────────────────────────────────
ws="$(mktemp -d)"; stale_marker "$ws"
got="$(probe "$ws" 'if ostler_slot_acquire feedD >/dev/null 2>&1; then echo TOOK; else echo REFUSED; fi')"
[ "$got" = "TOOK" ] && ok "D control: a STALE marker does not block ingest" || bad "D control: stale marker: expected TOOK, got ${got:-nothing}"
rm -rf "$ws"

ws="$(mktemp -d)"
got="$(probe "$ws" 'if ostler_slot_acquire feedE >/dev/null 2>&1; then echo TOOK; else echo REFUSED; fi')"
[ "$got" = "TOOK" ] && ok "E control: no marker, ingest takes the slot" || bad "E control: no marker: expected TOOK, got ${got:-nothing}"
rm -rf "$ws"

ws="$(mktemp -d)"; fresh_marker "$ws"
got="$(EXTRA_ENV='export OSTLER_INTERACTIVE_TTL_SECS=0' probe "$ws" 'if ostler_slot_acquire feedF >/dev/null 2>&1; then echo TOOK; else echo REFUSED; fi')"
[ "$got" = "TOOK" ] && ok "F control: TTL=0 switches the check off" || bad "F control: TTL=0 with a fresh marker: expected TOOK, got ${got:-nothing}"
rm -rf "$ws"

ws="$(mktemp -d)"
got="$(probe "$ws" '
ostler_slot_acquire feedG >/dev/null 2>&1 || { echo NOACQ; exit 0; }
bash -c "for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do sleep 1; done" & w=$!
_ostler_slot_watchdog "$w" >/dev/null 2>&1 & wd=$!
sleep 6
if kill -0 "$w" 2>/dev/null; then echo ALIVE; else echo STOPPED; fi
kill "$w" "$wd" 2>/dev/null
')"
[ "$got" = "ALIVE" ] && ok "G control: with no chat the holder is left running" || bad "G control: no chat: expected ALIVE, got ${got:-nothing}"
rm -rf "$ws"

echo
[ "$fails" = "0" ] && { echo "All cases passed."; exit 0; }
echo "$fails case(s) failed."; exit 1
