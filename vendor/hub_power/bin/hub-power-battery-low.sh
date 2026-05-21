#!/usr/bin/env bash
#
# hub-power-battery-low.sh
#
# Battery at or below the mid-tier threshold (default 30%, 50% in eco mode).
# We:
#   - Pause the PWG Docker stack (pause, not stop, so resume is cheap)
#   - Stop Ollama to free GPU + RAM
#   - Keep ZeroClaw running (it is light and handles inbound messages)
#   - Keep ical-server.py running (serves the Hub health pill)
#
# Respects $DRY_RUN=1.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/hub-power-actions.sh"

hps_load_policy
hps_log "battery-low: engaging mid-tier throttle (policy=$POWER_POLICY)"

hpa_pwg_pause
hpa_ollama_stop
# ZeroClaw untouched.
# ical-server untouched.

hps_log "battery-low: mid-tier throttle applied"
