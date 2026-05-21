#!/usr/bin/env bash
#
# hub-power-watch.sh
#
# The polling heart of the Hub power policy. Invoked by the LaunchAgent
# every 60 seconds (StartInterval). Reads current state, compares to the
# cached previous state, and dispatches the right transition script.
#
# Transitions we care about:
#   ac         <-> battery_high
#   battery_*  <->  battery_*  (within the battery cluster)
#   "long gap" (>120s since last tick) -> treat as wake event
#
# We deliberately do not try to detect sleep from here – macOS pauses this
# script during sleep, so by the time it runs again we've already woken.
# The "long gap" heuristic covers it.
#
# Respects $DRY_RUN=1.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/hub-power-actions.sh"

hps_load_policy

prev_cache="$OSTLER_DIR/hub-power.state"
now_ts="$(date +%s)"

tier="$(hps_current_tier)"
state_lines="$(hps_read_state)"

# Load previous state (if any).
prev_tier=""
prev_ts=0
if [ -f "$prev_cache" ]; then
    # shellcheck disable=SC1090
    . "$prev_cache" 2>/dev/null || true
fi

# Detect long gap = likely wake.
gap="$(( now_ts - prev_ts ))"
if [ "$prev_ts" -gt 0 ] && [ "$gap" -gt 120 ]; then
    hps_log "watch: detected long gap ($gap s) – invoking wake handler"
    "$SCRIPT_DIR/hub-wake.sh" || hps_log "watch: hub-wake.sh exited non-zero"
fi

# Dispatch on tier change. First run has empty prev_tier -> we treat that
# as a transition from unknown and fire the right handler once.
# Branch logic lives in actions.sh so it's unit-testable.
# See hpa_dispatch_watch_tier() and tests/test_hub_power_dispatch.sh.
hpa_dispatch_watch_tier "$prev_tier" "$tier" "$SCRIPT_DIR"

# Persist cache.
{
    printf 'prev_tier=%s\n' "$tier"
    printf 'prev_ts=%s\n'   "$now_ts"
    # Include the raw read-state lines (commented) for ops debugging.
    printf '%s\n' "$state_lines" | sed 's/^/# /'
} > "$prev_cache"
