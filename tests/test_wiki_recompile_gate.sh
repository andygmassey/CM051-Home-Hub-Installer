#!/usr/bin/env bash
#
# tests/test_wiki_recompile_gate.sh
#
# v1.0.108 Rule 0.8 for the wiki: a FRESH recompile is Pro, the VIEW is free.
# Hermetic (no real docker needed, so it runs where the stubbed pytest in
# wiki-recompile/tests is skipped because a real docker shadows the stub):
# it lifts the Rule 0.8 block out of the shipped wrapper -- the exact block
# that ships -- and runs it with a fake `docker` and a staged gate.
#
# Both directions + the fail-open control:
#   lapsed  -> block exits before the compile, and keeps the view up
#   active  -> block falls through to the compile (sentinel reached)
#   missing -> fail open (sentinel reached), view not force-paused

set -uo pipefail
cd "$(dirname "$0")/.." || exit 99
REPO_ROOT="$(pwd)"

PY="${PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 || { echo "CANNOT-RUN: no $PY on PATH"; exit 99; }
WRAPPER="wiki-recompile/bin/wiki-recompile-tick.sh"
GATE_SRC="vendor/cm041/assistant_api/subscription_gate.py"
test -f "$WRAPPER" || { echo "CANNOT-RUN: $WRAPPER missing"; exit 99; }

fails=0
pass() { echo "PASS [$1]: $2"; }
fail() { echo "FAIL [$1]: $2"; fails=$((fails + 1)); }

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
HUB="$TMPROOT/hub"
mkdir -p "$HUB/services/ical-server" "$HUB/state"
cp "$GATE_SRC" "$HUB/services/ical-server/subscription_gate.py"
GATE="$HUB/services/ical-server/subscription_gate.py"
STATE="$HUB/state/subscription_state.json"

# Fake docker on PATH: records args, always succeeds.
BIN="$TMPROOT/bin"; mkdir -p "$BIN"
DOCKERLOG="$TMPROOT/docker.log"
cat > "$BIN/docker" <<EOF
#!/bin/sh
echo "\$@" >> "$DOCKERLOG"
exit 0
EOF
chmod +x "$BIN/docker"

# Lift the Rule 0.8 block from the shipped wrapper.
block="$(awk '/^# --- Rule 0\.8: the Ostler Pro subscription gate \(v1\.0\.108\)/,/^# --- end Rule 0\.8 gate/' "$WRAPPER")"
[ -n "$block" ] || { echo "CANNOT-RUN: no Rule 0.8 block in $WRAPPER"; exit 99; }

set_state() {  # $1 = days ago (1 active, 31 lapsed)
    rm -f "$STATE"
    OSTLER_SUBSCRIPTION_STATE="$STATE" "$PY" -c "
import sys; sys.path.insert(0, '$HUB/services/ical-server')
from subscription_gate import activate_first_month_free
from datetime import datetime, timezone, timedelta
activate_first_month_free((datetime.now(timezone.utc)-timedelta(days=$1)).isoformat().replace('+00:00','Z'))
"
}

run_block() {  # runs the block; prints the output; sentinel = REACHED_COMPILE
    harness="$TMPROOT/h.sh"
    {
        echo 'set -euo pipefail'
        echo "OSTLER_DIR='$HUB'"
        echo "OSTLER_PYTHON='$PY'"
        echo "PATH='$BIN:$PATH'"
        echo "export OSTLER_SUBSCRIPTION_STATE='$STATE'"
        echo 'log() { printf "%s\n" "$*"; }'
        echo "$block"
        echo 'echo REACHED_COMPILE'
    } > "$harness"
    /bin/bash "$harness" 2>&1
}

# ── lapsed -> paused: no compile reached, view kept up ──
: > "$DOCKERLOG"; set_state 31
out="$(run_block)"
if printf '%s' "$out" | grep -q "REACHED_COMPILE"; then
    fail "lapsed" "a lapsed owner fell through to the compile (fresh recompile not gated)"
else
    pass "lapsed" "lapsed owner: fresh compile skipped (block exited before it)"
fi
if grep -q "compose up -d wiki-site" "$DOCKERLOG"; then
    pass "lapsed.view" "the view container was kept up on stale-but-compiled content"
else
    fail "lapsed.view" "paused tick did not keep wiki-site up: $(cat "$DOCKERLOG")"
fi

# ── active -> compile reached ──
: > "$DOCKERLOG"; set_state 1
out="$(run_block)"
if printf '%s' "$out" | grep -q "REACHED_COMPILE"; then
    pass "active" "active subscription falls through to the fresh compile"
else
    fail "active" "active subscription was wrongly paused: $out"
fi

# ── missing module -> fail open (compile reached) ──
: > "$DOCKERLOG"; set_state 31
mv "$GATE" "$GATE.hidden"
out="$(run_block)"
mv "$GATE.hidden" "$GATE"
if printf '%s' "$out" | grep -q "REACHED_COMPILE"; then
    pass "missing" "missing gate module: fail open (recompile proceeds; view never starved)"
else
    fail "missing" "missing gate module stopped the recompile; should fail open"
fi

echo
if [ "$fails" -eq 0 ]; then
    echo "ALL PASS: fresh recompile is gated; the view is not."
    exit 0
fi
echo "FAILURES: $fails"; exit 1
