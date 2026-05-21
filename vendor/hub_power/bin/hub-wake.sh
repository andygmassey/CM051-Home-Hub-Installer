#!/usr/bin/env bash
#
# hub-wake.sh
#
# Post-wake hook. Brings services back up in the order specified by the
# design doc:
#   1. ical-server (already up, just verified)
#   2. ZeroClaw (5s delay after ical-server)
#   3. Ollama (5s delay after ZeroClaw)
#   4. PWG Docker stack (5s delay after Ollama)
#
# Then triggers a ZeroClaw catch-up so the assistant replays any messages
# that arrived while the Mac was asleep.
#
# If the Mac wakes on battery and is already below the mid-tier threshold,
# we only bring up ical-server + ZeroClaw (matching the battery-low policy)
# and leave the rest paused. User can plug in to get full service back.
#
# Respects $DRY_RUN=1 (including shortening the 5s delays to 0 for tests).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/hub-power-actions.sh"

hps_load_policy

# How long we were asleep (best-effort).
marker="$OSTLER_DIR/last-awake"
asleep_for="unknown"
if [ -f "$marker" ]; then
    last_awake="$(cat "$marker" 2>/dev/null || true)"
    asleep_for="since $last_awake"
fi
hps_log "wake: system woke (policy=$POWER_POLICY, asleep $asleep_for)"

# Short delay helper – 5s for real, 0s for tests.
wake_delay() {
    if [ "${DRY_RUN:-0}" = "1" ] || [ "${HPS_STUB_CMD:-0}" = "1" ]; then
        return 0
    fi
    sleep 5
}

# Step 1: verify ical-server is up. It should be – macOS restores launchd
# agents on wake – but we double-check.
hpa_ical_ensure_up

# Decide how far up the ladder we go based on current power state.
tier="$(hps_current_tier)"
hps_log "wake: current tier=$tier"

case "$tier" in
    ac|battery_high)
        wake_delay
        hpa_zeroclaw_start

        wake_delay
        hpa_ollama_start

        wake_delay
        hpa_pwg_unpause
        ;;
    battery_mid)
        # Match the mid-tier policy: ZeroClaw only.
        wake_delay
        hpa_zeroclaw_start
        hps_log "wake: mid-tier battery, keeping Ollama + PWG paused"
        ;;
    battery_low)
        # Match the critical-tier policy: ical-server only, everything else
        # stays down. User needs to plug in.
        hps_log "wake: critical-tier battery, only ical-server running"
        ;;
    *)
        hps_log "wake: unknown tier=$tier, defaulting to full restore"
        wake_delay; hpa_zeroclaw_start
        wake_delay; hpa_ollama_start
        wake_delay; hpa_pwg_unpause
        ;;
esac

# Step 4: trigger assistant catch-up. This writes the well-known marker file
# that ZeroClaw is expected to poll. See hpa_zeroclaw_catchup_request()
# comments for the "ZeroClaw doesn't poll this yet" caveat.
#
# For v1: restarting ZeroClaw above is the actual catch-up path – on
# startup it drains its inbound queues. The marker is future-proofing.
hpa_zeroclaw_catchup_request

hps_log "wake: restoration complete"
