#!/usr/bin/env bash
#
# hub-power-ac.sh
#
# Called when the Mac transitions to AC power (or the watcher detects that
# state on startup / poll). Resumes any previously-paused services and makes
# sure all Hub tiers are running.
#
# Safe to invoke idempotently – every action is a no-op if already in the
# desired state.
#
# Respects $DRY_RUN=1.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/hub-power-actions.sh"

hps_load_policy
hps_log "ac: transitioning to AC / battery-high (policy=$POWER_POLICY)"

# Order: ical-server first (it's always up, but cheap to verify), then
# ZeroClaw, then Ollama, then PWG. See HUB_PORTABILITY_PLAN.md for rationale.
hpa_ical_ensure_up
hpa_zeroclaw_start
hpa_ollama_start
hpa_pwg_unpause

hps_log "ac: all services resumed"
