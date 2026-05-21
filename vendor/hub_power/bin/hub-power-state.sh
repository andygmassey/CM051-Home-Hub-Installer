#!/usr/bin/env bash
#
# hub-power-state.sh
#
# Shared helper for the Ostler Hub power policy. Reads the current Mac
# power state via pmset and exposes it as environment-style key=value output
# on stdout, plus provides helper functions when sourced.
#
# When run directly, prints machine-readable lines:
#   POWER_SOURCE=ac|battery|unknown
#   BATTERY_PCT=<int 0-100 or -1>
#   LID=open|closed|unknown
#
# When sourced (e.g. `. hub-power-state.sh`), exposes functions:
#   hps_read_state        -> echoes the three lines above
#   hps_current_tier      -> echoes one of: ac | battery_high | battery_mid | battery_low
#   hps_load_policy       -> loads ~/.ostler/power.conf into $POWER_POLICY
#   hps_log <message>     -> appends timestamped line to ~/.ostler/hub-power.log
#
# Respects $DRY_RUN=1 (no side effects other than logging).
#
# British English throughout.

set -euo pipefail

# Paths (overridable for testing).
# OSTLER_DIR is the canonical name; LIFELINE_DIR is accepted as a
# backwards-compatible alias so any existing pre-rebrand env var still
# works (set by upstart scripts, user shells, or older tests).
OSTLER_DIR="${OSTLER_DIR:-${LIFELINE_DIR:-$HOME/.ostler}}"
OSTLER_LOG="${OSTLER_LOG:-${LIFELINE_LOG:-$OSTLER_DIR/hub-power.log}}"
OSTLER_CONF="${OSTLER_CONF:-${LIFELINE_CONF:-$OSTLER_DIR/power.conf}}"
OSTLER_STATE_CACHE="${OSTLER_STATE_CACHE:-${LIFELINE_STATE_CACHE:-$OSTLER_DIR/hub-power.state}}"

# Ensure the directory exists (but never create files here; callers decide).
mkdir -p "$OSTLER_DIR"

# ---------------------------------------------------------------------------
# hps_log <message>
# Appends an ISO-8601 timestamped entry to the log, capped at 10000 lines.
# ---------------------------------------------------------------------------
hps_log() {
    local msg="$1"
    local ts
    ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    local line="$ts $msg"

    # Append then trim. We rewrite the whole file so it never grows unbounded.
    # Naive but fine for this use case (<1MB even at max).
    if [ -f "$OSTLER_LOG" ]; then
        printf '%s\n' "$line" >> "$OSTLER_LOG"
        local total
        total="$(wc -l < "$OSTLER_LOG" | tr -d ' ')"
        if [ "$total" -gt 10000 ]; then
            local tmp
            tmp="$(mktemp)"
            tail -n 10000 "$OSTLER_LOG" > "$tmp"
            mv "$tmp" "$OSTLER_LOG"
        fi
    else
        printf '%s\n' "$line" > "$OSTLER_LOG"
    fi
}

# ---------------------------------------------------------------------------
# hps_load_policy
# Reads ~/.ostler/power.conf and exports $POWER_POLICY.
# Absent file or unrecognised value => POWER_POLICY=normal.
# ---------------------------------------------------------------------------
hps_load_policy() {
    POWER_POLICY="normal"
    if [ -f "$OSTLER_CONF" ]; then
        # shellcheck disable=SC1090
        local raw
        raw="$(grep -E '^POWER_POLICY=' "$OSTLER_CONF" | tail -n 1 | cut -d= -f2 | tr -d '"'"'" | tr -d '[:space:]' || true)"
        case "$raw" in
            normal|aggressive|eco) POWER_POLICY="$raw" ;;
            *) POWER_POLICY="normal" ;;
        esac
    fi
    export POWER_POLICY
}

# ---------------------------------------------------------------------------
# hps_read_state
# Parses `pmset -g batt` and `pmset -g` (for lid state). Returns three lines:
#   POWER_SOURCE=ac|battery|unknown
#   BATTERY_PCT=<int or -1>
#   LID=open|closed|unknown
#
# Testing hook: if $HPS_PMSET_FIXTURE is set and points to a readable file,
# that file's contents are used instead of calling pmset. Useful for unit
# tests without mocking the binary.
# ---------------------------------------------------------------------------
hps_read_state() {
    local batt_output=""
    if [ "${HPS_PMSET_FIXTURE:-}" != "" ] && [ -r "${HPS_PMSET_FIXTURE}" ]; then
        batt_output="$(cat "$HPS_PMSET_FIXTURE")"
    else
        # Never fail the whole script if pmset is unavailable (non-macOS CI).
        batt_output="$(/usr/bin/pmset -g batt 2>/dev/null || echo '')"
    fi

    local source="unknown"
    local pct="-1"
    local lid="unknown"

    # pmset -g batt first line looks like:
    #   Now drawing from 'AC Power'
    #   Now drawing from 'Battery Power'
    local first_line
    first_line="$(printf '%s\n' "$batt_output" | head -n 1)"
    case "$first_line" in
        *"'AC Power'"*)      source="ac" ;;
        *"'Battery Power'"*) source="battery" ;;
        *) source="unknown" ;;
    esac

    # Subsequent lines look like:
    #   -InternalBattery-0 (id=...)	87%; discharging; 4:12 remaining present: true
    # We pick the first percentage we find.
    local pct_raw
    pct_raw="$(printf '%s\n' "$batt_output" | grep -oE '[0-9]+%' | head -n 1 | tr -d '%' || true)"
    if [ -n "$pct_raw" ] && [ "$pct_raw" -ge 0 ] 2>/dev/null && [ "$pct_raw" -le 100 ] 2>/dev/null; then
        pct="$pct_raw"
    fi

    # If there's no battery at all (desktop Mac), pct stays -1 and source is
    # usually "ac". That's fine – callers should treat pct=-1 as "AC only".

    # Lid state via ioreg. Optional, may not always be available. We leave
    # this as "unknown" on non-macOS hosts so tests can still run.
    if [ "${HPS_LID_FIXTURE:-}" != "" ]; then
        lid="$HPS_LID_FIXTURE"
    elif command -v ioreg >/dev/null 2>&1; then
        # AppleClamshellState=Yes means lid is closed.
        local clamshell
        clamshell="$(ioreg -r -k AppleClamshellState 2>/dev/null | grep AppleClamshellState | head -n 1 || true)"
        case "$clamshell" in
            *"Yes"*) lid="closed" ;;
            *"No"*)  lid="open" ;;
            *) lid="unknown" ;;
        esac
    fi

    printf 'POWER_SOURCE=%s\n' "$source"
    printf 'BATTERY_PCT=%s\n'  "$pct"
    printf 'LID=%s\n'          "$lid"
}

# ---------------------------------------------------------------------------
# hps_current_tier
# Maps (POWER_SOURCE, BATTERY_PCT, POWER_POLICY) to a tier name:
#   ac            -> on AC or desktop Mac, no battery limits apply
#   battery_high  -> on battery, above the "slow down" threshold
#   battery_mid   -> on battery, at or below the "slow down" threshold
#   battery_low   -> on battery, at or below the "critical" threshold
#
# Thresholds depend on POWER_POLICY:
#   normal:     mid = 30%, low = 15%
#   eco:        mid = 50%, low = 20%
#   aggressive: mid = 0%,  low = 0%  (never slow down)
# ---------------------------------------------------------------------------
hps_current_tier() {
    hps_load_policy
    local state
    state="$(hps_read_state)"
    local src pct
    src="$(printf '%s\n' "$state" | awk -F= '/^POWER_SOURCE=/ {print $2}')"
    pct="$(printf '%s\n' "$state" | awk -F= '/^BATTERY_PCT=/  {print $2}')"

    # Desktop Mac or on AC => always the "ac" tier.
    if [ "$src" = "ac" ] || [ "$pct" = "-1" ]; then
        printf 'ac\n'
        return 0
    fi
    if [ "$src" = "unknown" ]; then
        # Be conservative: treat unknown as ac so we don't accidentally
        # pause services on a machine we can't read.
        printf 'ac\n'
        return 0
    fi

    local mid_threshold=30
    local low_threshold=15
    case "${POWER_POLICY:-normal}" in
        aggressive) mid_threshold=0;  low_threshold=0  ;;
        eco)        mid_threshold=50; low_threshold=20 ;;
        normal|*)   mid_threshold=30; low_threshold=15 ;;
    esac

    if [ "$pct" -le "$low_threshold" ]; then
        printf 'battery_low\n'
    elif [ "$pct" -le "$mid_threshold" ]; then
        printf 'battery_mid\n'
    else
        printf 'battery_high\n'
    fi
}

# If executed directly (not sourced), print the state lines.
# BASH_SOURCE[0] == $0 when executed; differ when sourced.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    hps_read_state
fi
