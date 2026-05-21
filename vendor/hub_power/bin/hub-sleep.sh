#!/usr/bin/env bash
#
# hub-sleep.sh
#
# Pre-sleep hook. macOS will pause all user processes when the system sleeps
# anyway, but we take this opportunity to:
#   - Flush the log cleanly
#   - Record the last-awake timestamp (used by the wake detector)
#   - Leave in-flight writes alone (no force-kills)
#
# This script must exit quickly. pmset does not wait indefinitely for sleep
# hooks, and a slow script just gets cut off.
#
# Respects $DRY_RUN=1 but there's little to stub here – the only side effect
# is writing a small marker file.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/hub-power-state.sh"

hps_load_policy
hps_log "sleep: system going to sleep (policy=$POWER_POLICY)"

# Write the last-awake timestamp. hub-wake.sh reads this to estimate how
# long we were asleep and whether a catch-up is worthwhile.
marker="$OSTLER_DIR/last-awake"
if [ "${DRY_RUN:-0}" = "1" ]; then
    hps_log "sleep: stub write last-awake marker"
else
    date -u +"%Y-%m-%dT%H:%M:%SZ" > "$marker"
fi

hps_log "sleep: handoff to macOS complete"
