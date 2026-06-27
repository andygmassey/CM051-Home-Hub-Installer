#!/usr/bin/env bash
#
# ostler-runtime.sh
#
# Per-tick user-control gates for the background processing wrappers.
# Sourced at the very top of every tick wrapper (the four conversation
# feeds + the wiki recompile). Two jobs, both user-facing:
#
#   1. ostler_runtime_load_env -- source the Doctor Config panel's env
#      file (~/.ostler/config/ostler.env) so a settings change (preset,
#      quiet hours, governor on/off) actually reaches the wrappers. This
#      is the contract the old config panel was missing: it wrote a YAML
#      nothing read; the panel now ALSO materialises these env knobs and
#      the wrappers source them here.
#
#   2. ostler_pause_active -- the user-facing Pause control. Returns 0
#      (true) when background processing is paused and the pause has not
#      expired, so the wrapper can exit 0 and yield the tick. Live chat
#      and the assistant daemon's foreground turns NEVER call this -- only
#      background ingest / enrich / recompile.
#
# Installed to ~/.ostler/lib/ostler-runtime.sh (same pattern as
# ostler-resource-tier.sh) so it is defined once and every wrapper
# sources it. British English throughout.
#
# Overrides (tests / non-default deployments):
#   OSTLER_ENV_FILE        -> the sourced env file (default
#                             ~/.ostler/config/ostler.env).
#   OSTLER_PAUSE_SENTINEL  -> the pause sentinel (default
#                             ~/.ostler/run/processing.paused).

# Source the Doctor Config env file if present. Absent file = use the
# wrappers' built-in defaults (the pre-panel behaviour), so a fresh
# install with no saved settings is unchanged.
ostler_runtime_load_env() {
    local f="${OSTLER_ENV_FILE:-$HOME/.ostler/config/ostler.env}"
    if [ -f "$f" ]; then
        # shellcheck source=/dev/null
        . "$f"
    fi
}

# Pause sentinel. The Doctor writes the first line as the expiry epoch:
#   - a positive integer  -> paused until that epoch (UTC seconds)
#   - 0 / empty / never    -> paused indefinitely, until the user resumes
# An expired sentinel is removed and treated as not-paused (self-heal),
# so a "Pause 1 hour" cannot wedge background work past its window even
# if the Doctor never runs again. An unparseable first line is treated
# as paused (honour the user intent; the Resume control always clears
# it).
#
# Returns 0 (paused -> caller should yield) or 1 (not paused -> proceed).
ostler_pause_active() {
    local f="${OSTLER_PAUSE_SENTINEL:-$HOME/.ostler/run/processing.paused}"
    [ -f "$f" ] || return 1

    local expiry
    expiry="$(head -n1 "$f" 2>/dev/null | tr -d '[:space:]')"
    case "$expiry" in
        ''|0|never|forever)
            return 0 ;;            # indefinite pause
        *[!0-9]*)
            return 0 ;;            # unparseable -> honour the pause
        *)
            ;;                     # a plain integer epoch: check expiry
    esac

    local now
    now="$(date +%s 2>/dev/null || echo 0)"
    if [ "${now:-0}" -ge "$expiry" ]; then
        rm -f "$f" 2>/dev/null || true   # expired: self-heal
        return 1
    fi
    return 0
}
