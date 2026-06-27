#!/usr/bin/env bash
#
# test_resource_throttle_pause.sh
#
# FUNCTION tests for the user resource throttle + Pause control
# (next-cut MUST-SHIP). Proves the wrapper-side contract, not just
# presence:
#
#   1. The Pause gate (lib/ostler-runtime.sh): a present + unexpired
#      sentinel pauses; an expired sentinel self-heals and does NOT
#      pause; an absent sentinel does not pause; 0/indefinite pauses.
#   2. A real tick wrapper exit-0s with the yield message when paused,
#      and proceeds past the gate (no yield message) when not paused.
#      Chat / daemon foreground is never gated (it does not source this).
#   3. All five tick wrappers (4 feeds + wiki recompile) source the
#      runtime lib and honour the pause gate.
#   4. The config env bridge: settings written by the Doctor Config
#      panel land in ~/.ostler/config/ostler.env and are loaded by the
#      wrapper's exact env-load path (FUNCTION test 1, wrapper half).
#   5. Quiet hours are parameterised in the four feeds (not hardcoded).
#   6. install.sh stages the runtime lib + the embed has not drifted
#      from the canonical lib/ostler-runtime.sh (CI drift guard).
#
# British English throughout.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO_ROOT/lib/ostler-runtime.sh"
INSTALL_SH="$REPO_ROOT/install.sh"
FAILED=0

failure() { echo "FAIL: $*" >&2; FAILED=1; }
pass() { echo "ok: $*"; }

[ -f "$LIB" ] || { echo "FAIL: missing $LIB" >&2; exit 1; }
bash -n "$LIB" || failure "runtime lib has a bash syntax error"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

BUNDLE_WRAPPERS=(
    "$REPO_ROOT/vendor/imessage_source/bin/imessage-bundle-tick.sh"
    "$REPO_ROOT/vendor/whatsapp_source/bin/whatsapp-bundle-tick.sh"
    "$REPO_ROOT/vendor/spoken_source/bin/spoken-bundle-tick.sh"
    "$REPO_ROOT/vendor/email_source/bin/email-bundle-tick.sh"
)
WIKI_WRAPPER="$REPO_ROOT/wiki-recompile/bin/wiki-recompile-tick.sh"

# --------------------------------------------------------------------
# Section 1 -- the Pause gate function in isolation.
# --------------------------------------------------------------------
pause_returns() {
    # pause_returns <sentinel-path> -> echoes "paused" or "running".
    OSTLER_PAUSE_SENTINEL="$1" bash -c '
        . "'"$LIB"'"
        if ostler_pause_active; then echo paused; else echo running; fi
    '
}

SENT="$TMP/processing.paused"

# Absent sentinel -> running.
rm -f "$SENT"
[ "$(pause_returns "$SENT")" = "running" ] \
    || failure "absent sentinel must not pause"

# Unexpired (1h in the future) -> paused.
echo "$(( $(date +%s) + 3600 ))" > "$SENT"
[ "$(pause_returns "$SENT")" = "paused" ] \
    || failure "unexpired sentinel must pause"

# Indefinite (0) -> paused.
echo "0" > "$SENT"
[ "$(pause_returns "$SENT")" = "paused" ] \
    || failure "indefinite (0) sentinel must pause"

# Expired (1h in the past) -> running, AND self-healed (file removed).
echo "$(( $(date +%s) - 3600 ))" > "$SENT"
[ "$(pause_returns "$SENT")" = "running" ] \
    || failure "expired sentinel must not pause"
[ ! -f "$SENT" ] \
    || failure "expired sentinel must self-heal (be removed)"

[ "$FAILED" -eq 0 ] && pass "pause gate: absent/expired run, unexpired/indefinite pause, expired self-heals"

# --------------------------------------------------------------------
# Section 2 -- a real wrapper honours the pause gate.
# --------------------------------------------------------------------
# Paused: the gate is the first thing after `set -euo pipefail`, so the
# wrapper must exit 0 and print the yield message BEFORE any side
# effects (no lock dirs, no python).
IM="$REPO_ROOT/vendor/imessage_source/bin/imessage-bundle-tick.sh"
echo "$(( $(date +%s) + 3600 ))" > "$SENT"
set +e
out="$(OSTLER_RUNTIME_LIB="$LIB" OSTLER_PAUSE_SENTINEL="$SENT" \
       bash "$IM" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 0 ] || failure "paused wrapper must exit 0 (got $rc)"
echo "$out" | grep -qi "paused by the user" \
    || failure "paused wrapper must print the yield message (got: $out)"
[ "$FAILED" -eq 0 ] && pass "paused tick exit-0s with the yield message before any work"

# Not paused: the wrapper proceeds PAST the pause gate (no yield
# message). It then fails fast for an unrelated reason (no real source
# dir), which is fine -- we only assert the gate did not fire. Side
# effects are pinned into TMP so the real home is untouched.
rm -f "$SENT"
set +e
out2="$(OSTLER_RUNTIME_LIB="$LIB" OSTLER_PAUSE_SENTINEL="$SENT" \
        OSTLER_RESOURCE_GOVERNOR=0 \
        OSTLER_INGEST_OFFPEAK_ONLY=0 \
        OSTLER_STATE_DIR="$TMP/state" \
        OSTLER_INGEST_LOCK="$TMP/lock.d" \
        OSTLER_INTERACTIVE_MARKER="$TMP/none" \
        OSTLER_SOURCE_DIR="$TMP/no-such-source" \
        bash "$IM" 2>&1)"
set -e
if echo "$out2" | grep -qi "paused by the user"; then
    failure "un-paused wrapper must NOT print the yield message"
fi
[ "$FAILED" -eq 0 ] && pass "un-paused tick proceeds past the pause gate"

# --------------------------------------------------------------------
# Section 3 -- all five wrappers source the runtime lib + honour pause.
# --------------------------------------------------------------------
for f in "${BUNDLE_WRAPPERS[@]}" "$WIKI_WRAPPER"; do
    name="$(basename "$f")"
    [ -f "$f" ] || { failure "$name: wrapper missing"; continue; }
    grep -q "ostler-runtime.sh" "$f" \
        || failure "$name: must source the runtime lib"
    grep -q "ostler_pause_active" "$f" \
        || failure "$name: must honour the pause gate"
    grep -q "ostler_runtime_load_env" "$f" \
        || failure "$name: must load the Config env file"
    bash -n "$f" || failure "$name: bash syntax error"
done
[ "$FAILED" -eq 0 ] && pass "all five wrappers source the runtime lib + honour pause + load env"

# --------------------------------------------------------------------
# Section 4 -- config env bridge end-to-end (panel write -> wrapper read).
# Drive the vendored config_panel to materialise ostler.env, then load
# it via the wrapper's exact env-load path and assert the new values
# reach the shell. Skips cleanly if PyYAML / python3 is unavailable.
# --------------------------------------------------------------------
ENV_FILE="$TMP/ostler.env"
VENDOR_DOCTOR="$REPO_ROOT/vendor/doctor/agent"
if PYTHONPATH="$VENDOR_DOCTOR" python3 -c "import config_panel" 2>/dev/null; then
    PYTHONPATH="$VENDOR_DOCTOR" OSTLER_ENV_FILE="$ENV_FILE" python3 - <<'PYEOF'
import os
from pathlib import Path
import config_panel
# Materialise the "gentle" preset with the governor on and a custom
# quiet-hours window. sync_env_file is the panel's write path.
config_panel.sync_env_file({
    "processing_preset": "gentle",
    "governor_enabled": True,
    "quiet_hours_start": "03:00",
    "quiet_hours_end": "05:00",
}, path=Path(os.environ["OSTLER_ENV_FILE"]))
PYEOF
    [ -f "$ENV_FILE" ] || failure "config_panel.sync_env_file did not write the env file"
    # The wrapper's exact code path: source the runtime lib + load env.
    loaded="$(OSTLER_ENV_FILE="$ENV_FILE" bash -c '
        . "'"$LIB"'"
        ostler_runtime_load_env
        echo "ceiling=$OSTLER_LOADAVG_CEILING start=$OSTLER_INGEST_OFFPEAK_START_HOUR end=$OSTLER_INGEST_OFFPEAK_END_HOUR offpeak=$OSTLER_INGEST_OFFPEAK_ONLY"
    ')"
    echo "$loaded" | grep -q "ceiling=0.4" \
        || failure "panel write did not reach the wrapper (ceiling): $loaded"
    echo "$loaded" | grep -q "start=3" \
        || failure "panel quiet-hours start did not reach the wrapper: $loaded"
    echo "$loaded" | grep -q "end=5" \
        || failure "panel quiet-hours end did not reach the wrapper: $loaded"
    [ "$FAILED" -eq 0 ] && pass "config-panel write is consumed by the wrapper env-load path (end-to-end)"
else
    echo "skip: python3/config_panel unavailable -- env-bridge end-to-end not run"
fi

# --------------------------------------------------------------------
# Section 5 -- quiet hours are parameterised in the four feeds.
# --------------------------------------------------------------------
for f in "${BUNDLE_WRAPPERS[@]}"; do
    name="$(basename "$f")"
    grep -q "OSTLER_INGEST_OFFPEAK_START_HOUR" "$f" \
        || failure "$name: off-peak window start must be env-driven"
    grep -q "OSTLER_INGEST_OFFPEAK_END_HOUR" "$f" \
        || failure "$name: off-peak window end must be env-driven"
    # The hardcoded `-lt 1 ... -ge 6` literal must be gone.
    if grep -q '_ostler_hour" -lt 1 ' "$f"; then
        failure "$name: still has the hardcoded 01:00 off-peak bound"
    fi
done
[ "$FAILED" -eq 0 ] && pass "quiet hours parameterised in all four feeds"

# --------------------------------------------------------------------
# Section 6 -- install.sh stages the lib + drift guard.
# --------------------------------------------------------------------
grep -q 'ostler-runtime.sh' "$INSTALL_SH" \
    || failure "install.sh must install the runtime lib"
grep -q 'OSTLER_RUNTIME_EOF' "$INSTALL_SH" \
    || failure "install.sh must embed the lib as a quoted heredoc"
grep -q '.ostler/run' "$INSTALL_SH" \
    || failure "install.sh must create the pause sentinel dir (~/.ostler/run)"

EMBED="$(awk '/<<.OSTLER_RUNTIME_EOF.$/{f=1;next} /^OSTLER_RUNTIME_EOF$/{f=0} f' "$INSTALL_SH")"
if [ "$EMBED" = "$(cat "$LIB")" ]; then
    pass "embedded install.sh copy matches the canonical runtime lib (no drift)"
else
    failure "embedded install.sh copy of the runtime lib has DRIFTED from $LIB -- re-embed it"
fi

# --------------------------------------------------------------------
if [ "$FAILED" -eq 0 ]; then
    echo "ALL RESOURCE-THROTTLE + PAUSE TESTS PASSED"
    exit 0
fi
echo "RESOURCE-THROTTLE + PAUSE TESTS FAILED" >&2
exit 1
