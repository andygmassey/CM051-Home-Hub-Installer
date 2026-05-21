#!/usr/bin/env bash
#
# hub-power-battery.sh
#
# Entry point for battery-tier transitions. Reads current state, resolves
# the policy tier, and dispatches to the right sub-script.
#
# Battery tiers (after policy is applied):
#   battery_high -> no action (all services running, same as AC)
#   battery_mid  -> hub-power-battery-low.sh (pause PWG, stop Ollama)
#   battery_low  -> hub-power-battery-critical.sh (above + stop ZeroClaw)
#
# Called by the LaunchAgent on every poll tick when on battery, and by
# hub-wake.sh after a wake if the Mac woke on battery.
#
# Respects $DRY_RUN=1.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/hub-power-actions.sh"

hps_load_policy

tier="$(hps_current_tier)"
hps_log "battery: dispatching (tier=$tier, policy=$POWER_POLICY)"

# Dispatch lives in actions.sh so the branch logic is unit-testable.
# See hpa_dispatch_battery_tier() and tests/test_hub_power_dispatch.sh.
hpa_dispatch_battery_tier "$tier" "$SCRIPT_DIR"
