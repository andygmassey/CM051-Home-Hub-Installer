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
# Plus: the Ollama LaunchAgent must reserve a chat slot
# (OLLAMA_NUM_PARALLEL=2) and keep the model resident
# (OLLAMA_KEEP_ALIVE=-1).
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
    grep -q "find .* -mmin +30" "$w" \
        || failure "$name: missing stale-lock steal (find -mmin +30)"
    grep -q "trap 'rmdir" "$w" \
        || failure "$name: missing EXIT trap to release the lock"
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

# 2e. Single-flight: a held lock makes the tick yield (python never runs).
mkdir -p "$LOCK"
run_tick 3
if [ -f "$TMP/out.txt" ]; then
    failure "tick ran the pipeline while the shared lock was held (no single-flight)"
else
    pass "a held lock makes the tick yield without touching the model slot"
fi
rmdir "$LOCK" 2>/dev/null || true

# 2f. Stale lock (older than 30 min) is stolen, and the tick runs.
mkdir -p "$LOCK"
# Backdate the lock dir 40 minutes.
touch -A -004000 "$LOCK" 2>/dev/null || touch -d '40 minutes ago' "$LOCK" 2>/dev/null || true
run_tick 3
got="$(since_days_was)"
[ "$got" = "30" ] || failure "stale (40-min-old) lock should be stolen and the tick should run, got '$got'"
[ "$got" = "30" ] && pass "a stale lock (>30 min) is stolen so a wedged tick cannot block forever"

# --------------------------------------------------------------------
if [ "$FAILED" -ne 0 ]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
