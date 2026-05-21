#!/usr/bin/env bash
#
# hub-power-battery-critical.sh
#
# Battery at or below the critical threshold (default 15%, 20% in eco mode).
# Same as battery-low, plus we stop ZeroClaw. Only ical-server.py keeps
# running so the iOS Companion's Hub health pill still has something to
# talk to (it will report degraded features and the low-power reason).
#
# Respects $DRY_RUN=1.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/hub-power-actions.sh"

hps_load_policy
hps_log "battery-critical: engaging critical-tier throttle (policy=$POWER_POLICY)"

hpa_pwg_pause
hpa_ollama_stop
hpa_zeroclaw_stop
# ical-server untouched.

hps_log "battery-critical: only ical-server left running"
