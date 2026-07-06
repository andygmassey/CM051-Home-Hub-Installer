#!/usr/bin/env bash
#
# test_ingest_offpeak_throttle.sh
#
# Regression test for the v1.0.0 chat-responsiveness throttle. On a
# fresh install the four conversation feeds (iMessage / email / WhatsApp
# / spoken) each summarise every new session through the ONE shared
# Ollama model slot (~1 minute per session). Left unthrottled they
# saturate the slot for hours and live chat feels dead. Two mechanisms
# fix it, and this test refuses any regression on either:
#
#   1. Off-peak read-window gate. Outside 01:00-06:00 the tick shrinks
#      its --since-days window so daytime stays light; overnight it
#      drains the full configured window at full throttle.
#   2. Single-flight lock. The feeds share one atomic mkdir lock so they
#      never hit the model slot concurrently; a feed that cannot take
#      the lock yields its tick (the watermark means nothing is lost).
#
# Plus: the Ollama LaunchAgent must keep the model resident
# (OLLAMA_KEEP_ALIVE=-1). It runs OLLAMA_NUM_PARALLEL=1 (perf fix
# 2026-07-07: the old second slot halved usable context to 16,386
# tokens and gave no real concurrency), so this single-flight lock is
# the only thing keeping background producers from stacking up on the
# one slot.
#
# British English throughout.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILED=0

failure() {
    echo "FAIL: $*" >&2
    FAILED=1
}

pass() {
    echo "ok: $*"
}

IMSG="$REPO_ROOT/vendor/imessage_source/bin/imessage-bundle-tick.sh"
EMAIL="$REPO_ROOT/vendor/email_source/bin/email-bundle-tick.sh"
WA="$REPO_ROOT/vendor/whatsapp_source/bin/whatsapp-bundle-tick.sh"
SPOKEN="$REPO_ROOT/vendor/spoken_source/bin/spoken-bundle-tick.sh"
ALL_WRAPPERS=("$IMSG" "$EMAIL" "$WA" "$SPOKEN")

# --------------------------------------------------------------------
# Section 1 -- static assertions across all four feeds.
# --------------------------------------------------------------------
for w in "${ALL_WRAPPERS[@]}"; do
    name="$(basename "$w")"
    grep -q "OSTLER_INGEST_OFFPEAK_ONLY" "$w" \
        || failure "$name: missing off-peak gate (OSTLER_INGEST_OFFPEAK_ONLY)"
    grep -qF '10#$(date +%H)' "$w" \
        || failure "$name: hour must be parsed base-10 (10#\$(date +%H)) to avoid octal '08'/'09'"
    grep -q "OSTLER_INGEST_DAYTIME_SINCE_DAYS" "$w" \
        || failure "$name: missing daytime window override"
    grep -q "ingest-ollama.lock.d" "$w" \
        || failure "$name: missing shared single-flight lock"
    # Interactive-chat priority yield (v1.0.3): the tick must back off the
    # shared slot while a live chat turn is in flight, keyed on the daemon's
    # freshness marker, so background enrichment never starves live replies.
    grep -q "OSTLER_INTERACTIVE_MARKER" "$w" \
        || failure "$name: missing interactive-chat marker path (OSTLER_INTERACTIVE_MARKER)"
    grep -q "OSTLER_INTERACTIVE_TTL_SECS" "$w" \
        || failure "$name: missing interactive-chat freshness window (OSTLER_INTERACTIVE_TTL_SECS)"
    grep -q "interactive-chat.active" "$w" \
        || failure "$name: interactive marker must default beside the lock (interactive-chat.active)"
    # PID-liveness reclaim (v1.0.0 chat fix): the wiki summary backfill
    # holds this SAME lock for HOURS, so a time-based steal would wrongly
    # evict it mid-compile and re-create the 2-producer collision. The lock
    # must reclaim on a DEAD holder pid, never on age.
    grep -q 'kill -0 "\$_ostler_h"' "$w" \
        || failure "$name: missing PID-liveness reclaim (kill -0 on the holder pid)"
    grep -q '"\$_ostler_lock/pid"' "$w" \
        || failure "$name: must record the holder pid in the lock dir"
    if grep -q "find .* -mmin +30" "$w"; then
        failure "$name: still uses a TIME-BASED steal (-mmin) -- would evict the multi-hour wiki backfill"
    fi
    grep -q "trap 'rm -rf" "$w" \
        || failure "$name: missing EXIT trap (rm -rf) to release the lock dir + pid file"
    # The exec must be gone: an exec'd shell loses its EXIT trap, so the
    # lock would never be released.
    if grep -Eq 'exec +"\$PYTHON_BIN"' "$w"; then
        failure "$name: still uses 'exec \$PYTHON_BIN' -- EXIT trap will not fire, lock leaks"
    fi
    bash -n "$w" || failure "$name: bash syntax error"
done
[ "$FAILED" -eq 0 ] && pass "all four feeds carry the off-peak gate + single-flight lock"

# Ollama LaunchAgent reserves a chat slot + keeps the model warm.
INSTALL_SH="$REPO_ROOT/install.sh"
grep -q "OLLAMA_NUM_PARALLEL" "$INSTALL_SH" \
    || failure "install.sh ollama plist missing OLLAMA_NUM_PARALLEL (reserve a chat slot)"
grep -q "OLLAMA_KEEP_ALIVE" "$INSTALL_SH" \
    || failure "install.sh ollama plist missing OLLAMA_KEEP_ALIVE (keep model resident)"

# --------------------------------------------------------------------
# Section 2 -- behavioural: drive the iMessage wrapper with a fake
# python (records its args) and a PATH-shimmed `date` (controls the
# hour), then assert the --since-days the pipeline is actually invoked
# with, and the lock behaviour.
# --------------------------------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/src" "$TMP/state"

# Fake python: write the args it was invoked with, so we can assert the
# rendered --since-days.
cat > "$TMP/bin/fakepy" <<'FAKEPY'
#!/bin/bash
printf '%s\n' "$@" > "$FAKEPY_OUT"
FAKEPY
chmod +x "$TMP/bin/fakepy"

# `date` shim: return FAKE_HOUR for `+%H`, delegate everything else.
cat > "$TMP/bin/date" <<'FAKEDATE'
#!/bin/bash
if [ "$1" = "+%H" ]; then echo "$FAKE_HOUR"; else exec /bin/date "$@"; fi
FAKEDATE
chmod +x "$TMP/bin/date"

LOCK="$TMP/state/ingest.lock.d"

run_tick() {
    # run_tick <fake_hour> [extra OSTLER_* env assignments...]
    local hour="$1"; shift
    rm -f "$TMP/out.txt"
    env PATH="$TMP/bin:$PATH" \
        FAKE_HOUR="$hour" \
        FAKEPY_OUT="$TMP/out.txt" \
        OSTLER_PYTHON="$TMP/bin/fakepy" \
        OSTLER_SOURCE_DIR="$TMP/src" \
        OSTLER_IMESSAGE_SINCE_DAYS=30 \
        OSTLER_INGEST_LOCK="$LOCK" \
        "$@" \
        bash "$IMSG" >/dev/null 2>&1 || true
}

since_days_was() {
    # Echo the --since-days value from the recorded args, or empty.
    [ -f "$TMP/out.txt" ] || { echo ""; return; }
    awk '/^--since-days$/{getline; print; exit}' "$TMP/out.txt"
}

# 2a. Daytime (14:00) clamps 30 -> 2.
run_tick 14
got="$(since_days_was)"
[ "$got" = "2" ] || failure "daytime tick should clamp --since-days to 2, got '$got'"
[ -d "$LOCK" ] && failure "lock not released after a normal daytime tick"
[ "$FAILED" -eq 0 ] || true; [ "$got" = "2" ] && pass "daytime tick clamps the read window to 2 days"

# 2b. Off-peak (03:00) keeps the full 30.
run_tick 3
got="$(since_days_was)"
[ "$got" = "30" ] || failure "off-peak tick should keep --since-days 30, got '$got'"
[ "$got" = "30" ] && pass "off-peak (03:00) tick drains the full 30-day window"

# 2c. Leading-zero hour (09:00) is daytime, NOT a base-8 crash.
run_tick 09
got="$(since_days_was)"
[ "$got" = "2" ] || failure "09:00 must parse base-10 and clamp to 2, got '$got'"
[ "$got" = "2" ] && pass "leading-zero hour 09 parses base-10 (no octal crash)"

# 2d. OSTLER_INGEST_OFFPEAK_ONLY=0 disables the gate (full window by day).
run_tick 14 OSTLER_INGEST_OFFPEAK_ONLY=0
got="$(since_days_was)"
[ "$got" = "30" ] || failure "gate-disabled daytime tick should keep 30, got '$got'"
[ "$got" = "30" ] && pass "OSTLER_INGEST_OFFPEAK_ONLY=0 disables the daytime clamp"

# 2e. Single-flight: a lock held by a LIVE process makes the tick yield
#     (python never runs). The live holder is the test process itself ($$).
mkdir -p "$LOCK"
printf '%s\n' "$$" > "$LOCK/pid"
run_tick 3
if [ -f "$TMP/out.txt" ]; then
    failure "tick ran the pipeline while a LIVE process held the lock (no single-flight)"
else
    pass "a lock held by a live process makes the tick yield"
fi
[ -d "$LOCK" ] || failure "the wrapper stole a LIVE holder's lock (must reclaim only on a dead pid)"
rm -rf "$LOCK" 2>/dev/null || true

# 2f. A lock whose holder PID is DEAD is reclaimed and the tick runs. Time
#     is irrelevant now -- only liveness -- so a multi-hour wiki backfill
#     (live pid) is never stolen, but a crashed holder is.
mkdir -p "$LOCK"
# A definitely-dead pid: spawn a trivial child, wait for it to exit.
( exec true ) & _dead=$!; wait "$_dead" 2>/dev/null || true
printf '%s\n' "$_dead" > "$LOCK/pid"
run_tick 3
got="$(since_days_was)"
[ "$got" = "30" ] || failure "a lock held by a DEAD pid should be reclaimed and the tick should run, got '$got'"
[ "$got" = "30" ] && pass "a dead-holder lock is reclaimed so a crashed tick cannot block forever"
rm -rf "$LOCK" 2>/dev/null || true

# --------------------------------------------------------------------
# Section 2g -- interactive-chat priority yield. While the daemon's
# interactive marker is FRESH the tick must yield (no LLM call); when the
# marker is absent or stale it must proceed; a stat quirk must NOT wedge
# background work (fail-safe).
# --------------------------------------------------------------------
IMARKER="$TMP/state/interactive-chat.active"

run_tick_marker() {
    # run_tick_marker <fake_hour> [extra OSTLER_* env assignments...]
    local hour="$1"; shift
    rm -f "$TMP/out.txt"
    env PATH="$TMP/bin:$PATH" \
        FAKE_HOUR="$hour" \
        FAKEPY_OUT="$TMP/out.txt" \
        OSTLER_PYTHON="$TMP/bin/fakepy" \
        OSTLER_SOURCE_DIR="$TMP/src" \
        OSTLER_IMESSAGE_SINCE_DAYS=30 \
        OSTLER_INGEST_LOCK="$LOCK" \
        OSTLER_INTERACTIVE_MARKER="$IMARKER" \
        "$@" \
        bash "$IMSG" >/dev/null 2>&1 || true
}

# 2g-i. A FRESH marker (just touched) makes the tick yield -- python never
#       runs -- so background enrichment does not start while chat is live.
mkdir -p "$TMP/state"
: > "$IMARKER"   # mtime = now -> fresh
run_tick_marker 3
if [ -f "$TMP/out.txt" ]; then
    failure "tick ran the pipeline while a FRESH interactive marker was present (no chat priority)"
else
    pass "a fresh interactive marker makes the tick yield to live chat"
fi
[ -d "$LOCK" ] && failure "tick took the slot lock despite yielding to interactive chat"

# 2g-ii. A STALE marker (older than the TTL) does NOT block the tick. We
#        force a tiny TTL so the just-touched marker reads as stale.
run_tick_marker 3 OSTLER_INTERACTIVE_TTL_SECS=0
got="$(since_days_was)"
[ "$got" = "30" ] || failure "tick should proceed when the interactive yield is disabled (TTL=0), got '$got'"
[ "$got" = "30" ] && pass "OSTLER_INTERACTIVE_TTL_SECS=0 disables the interactive yield (background proceeds)"
rm -f "$IMARKER"

# 2g-iii. NO marker file at all -> tick proceeds exactly as before (the
#         common steady-state path: fail-safe, no deadlock).
run_tick_marker 3
got="$(since_days_was)"
[ "$got" = "30" ] || failure "tick should proceed when no interactive marker exists, got '$got'"
[ "$got" = "30" ] && pass "absent interactive marker leaves background work unaffected (fail-safe)"
rm -rf "$LOCK" 2>/dev/null || true

# 2g-iv. A missing workspace dir (marker path under a non-existent dir)
#        must not wedge: the tick still runs.
run_tick_marker 3 OSTLER_INTERACTIVE_MARKER="$TMP/does-not-exist/interactive-chat.active"
got="$(since_days_was)"
[ "$got" = "30" ] || failure "tick should proceed when the marker dir is missing, got '$got'"
[ "$got" = "30" ] && pass "a missing marker directory does not deadlock background work"
rm -rf "$LOCK" 2>/dev/null || true

# --------------------------------------------------------------------
# Section 3 -- the wiki summary backfill MUST hold the SAME shared lock.
#
# This is the producer the original throttle missed: the four conversation
# feeds were capped to 1, but the wiki full-summary compile ran as an
# INDEPENDENT 2nd Ollama producer. That is
# enough to starve live chat -- app AND iMessage /
# WhatsApp / email replies, which all go through the daemon's /api/chat
# (measured on the .149 box: 277s + truncated under load vs 1.5s idle).
# Both launch sites must wrap the detached `wiki-compiler` run in a
# BLOCKING acquire of ingest-ollama.lock.d with PID-liveness reclaim.
# --------------------------------------------------------------------
WIKI_TICK="$REPO_ROOT/wiki-recompile/bin/wiki-recompile-tick.sh"
for site in "$INSTALL_SH" "$WIKI_TICK"; do
    sname="$(basename "$site")"
    grep -q "ingest-ollama.lock.d" "$site" \
        || failure "$sname: wiki full-summary backfill is not on the shared Ollama lock"
    grep -q 'while ! mkdir "$_slot"' "$site" \
        || failure "$sname: backfill must BLOCK-acquire the slot (it must finish; a yield would skip summaries)"
    grep -q 'kill -0 "$_h"' "$site" \
        || failure "$sname: backfill lock must reclaim on a dead pid, not a time threshold"
    bash -n "$site" || failure "$sname: bash syntax error"
done
[ "$FAILED" -eq 0 ] && pass "wiki summary backfill holds the shared Ollama slot lock at both launch sites"

# --------------------------------------------------------------------
# Section 4 -- the simple-feed lock blocks must stay byte-identical
# (only the feed-name label differs). Drift here silently re-breaks the
# single-flight guarantee on one feed.
#
# iMessage is DELIBERATELY excluded from this parity set: it carries the
# extra anti-starvation branch (a never-run feed waits a bounded window
# for the slot instead of instant-yielding) which the other three do not.
# So the reference is one of the simple feeds, and the parity set is the
# remaining simple feeds -- email / whatsapp / spoken. iMessage keeps its
# own coverage via the static + behavioural sections above.
# --------------------------------------------------------------------
_extract_lock() {
    # Print the lock block (mkdir acquire .. trap), with the feed label
    # normalised, so the feeds can be compared.
    awk '/if ! mkdir "\$_ostler_lock"/{f=1} f{print} /trap .rm -rf "\$_ostler_lock"/{exit}' "$1" \
        | sed -E 's/(imessage|email|whatsapp|spoken)-bundle/FEED-bundle/g'
}
_ref="$(_extract_lock "$EMAIL")"
for w in "$WA" "$SPOKEN"; do
    if [ "$(_extract_lock "$w")" != "$_ref" ]; then
        failure "$(basename "$w"): lock block has drifted from the simple-feed reference (single-flight at risk)"
    fi
done
[ -n "$_ref" ] || failure "could not extract the simple-feed lock block (parity check inert)"
[ "$FAILED" -eq 0 ] && pass "the simple-feed lock blocks are byte-identical (no drift)"

# --------------------------------------------------------------------
if [ "$FAILED" -ne 0 ]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
