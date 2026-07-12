#!/usr/bin/env bash
#
# ostler-resource-tier.sh
#
# Adaptive first-run resource governor: hardware-tier detector (v1.0.3).
#
# A fresh install fires a storm of background enrichment work (the four
# conversation-bundle feeds + the wiki recompile, all RunAtLoad=true at
# install completion) on top of the Docker VM and macOS first-login
# Spotlight indexing. On capable hardware this is tolerable; on the
# 16GB floor it drives the 1-minute load average past 30 and the Hub app
# becomes unusable (dashboard "Load failed", Doctor fails, chat WS dies).
#
# This library detects the machine's tier from RAM + CPU cores and emits
# a per-tier first-run policy that the installer and the tick wrappers
# consult, so the background storm scales to the actual hardware and the
# interactive surfaces (chat, dashboard, Doctor, wiki) stay responsive.
#
# It REUSES the RAM detection already in install.sh
# (sysctl hw.memsize) and ADDS core-count detection (hw.ncpu /
# hw.perflevel0.physicalcpu for performance cores). It is installed to
# ~/.ostler/lib/ostler-resource-tier.sh (the same pattern as
# ostler-detect-exports.sh) so the policy is defined ONCE and both the
# installer and every tick wrapper source it.
#
# Usage (source it, then read the exported vars):
#
#     . "${HOME}/.ostler/lib/ostler-resource-tier.sh"
#     ostler_resource_tier_detect
#     echo "$OSTLER_TIER $OSTLER_ENRICH_CONCURRENCY"
#
# Or, as a one-shot CLI that prints the policy as KEY=VALUE lines:
#
#     bash ostler-resource-tier.sh
#
# Emitted variables (also printed by the CLI form):
#   OSTLER_TIER                 floor | low | high
#   OSTLER_ENRICH_CONCURRENCY   max simultaneous LLM enrichment jobs (1|2|4)
#   OSTLER_DEFER_NONESSENTIAL   1 = defer non-essential enrichment on first
#                               run; 0 = allow (high tier)
#   OSTLER_LOADAVG_CEILING      per-core 1-min loadavg above which a
#                               non-essential tick defers (tenths allowed)
#   OSTLER_ENRICH_NUM_CTX       reduced num_ctx for ENRICHMENT summaries
#                               ONLY (never the interactive chat); empty on
#                               high tier (use the model default)
#   OSTLER_RAM_GB               detected RAM in whole GB (diagnostics)
#   OSTLER_CPU_CORES            detected total cores (diagnostics)
#   OSTLER_PERF_CORES           detected performance cores (diagnostics)
#
# Fail-safe: every probe degrades to the CONSERVATIVE (floor) tier if it
# cannot read the hardware, so a sysctl quirk can never accidentally
# unleash the unbounded storm. British English throughout.

# Detect RAM in whole GB. Echoes 0 on failure (caller treats 0 as floor).
ostler_rt_ram_gb() {
    local bytes
    bytes="$(sysctl -n hw.memsize 2>/dev/null || true)"
    case "$bytes" in
        ''|*[!0-9]*) echo 0; return 0 ;;
    esac
    echo "$(( bytes / 1073741824 ))"
}

# Detect total logical cores. Echoes 0 on failure.
ostler_rt_cpu_cores() {
    local n
    n="$(sysctl -n hw.ncpu 2>/dev/null || true)"
    case "$n" in
        ''|*[!0-9]*) echo 0; return 0 ;;
    esac
    echo "$n"
}

# Detect performance cores. Apple Silicon exposes
# hw.perflevel0.physicalcpu (P-cores); Intel does not, so fall back to
# physical cores, then to total cores. Echoes 0 on total failure.
ostler_rt_perf_cores() {
    local n
    n="$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || true)"
    case "$n" in
        ''|*[!0-9]*) n="" ;;
    esac
    if [ -z "${n:-}" ]; then
        n="$(sysctl -n hw.physicalcpu 2>/dev/null || true)"
        case "$n" in
            ''|*[!0-9]*) n="" ;;
        esac
    fi
    if [ -z "${n:-}" ]; then
        n="$(ostler_rt_cpu_cores)"
    fi
    echo "${n:-0}"
}

# Read the 1-minute load average. Echoes it (a decimal) or empty on
# failure. macOS `sysctl -n vm.loadavg` -> "{ 1.23 4.56 7.89 }".
ostler_rt_loadavg_1m() {
    local raw
    raw="$(sysctl -n vm.loadavg 2>/dev/null || true)"
    if [ -z "$raw" ]; then
        # Linux / fallback: /proc/loadavg "1.23 4.56 7.89 ..."
        if [ -r /proc/loadavg ]; then
            raw="$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || true)"
            printf '%s' "$raw"
            return 0
        fi
        return 0
    fi
    # Strip the braces, take the first number.
    printf '%s' "$raw" | tr -d '{}' | awk '{print $1}'
}

# ── User-facing controls (the Doctor "Settings" panel) ───────────────
#
# The hardware-tier policy above is the automatic floor. On top of it the
# operator gets two explicit controls, surfaced in the Doctor Settings
# panel and persisted by it as a tiny KEY=VALUE file the panel writes and
# THIS engine reads (closing the writer/reader gap that made the old
# Config page a no-op):
#
#   * Pause  -- stop background enrichment/ingest entirely (OSTLER_PAUSED).
#   * Throttle -- how hard background work may push the machine
#                 (OSTLER_THROTTLE_LEVEL = full | balanced | gentle).
#
# Both are read here so EVERY consumer (all five conversation feeds + the
# wiki recompile) honours them from the one place they already source.

# Load the operator's Settings-panel choices. The panel writes a small
# KEY=VALUE file (governor.env). We parse it DEFENSIVELY -- only OSTLER_*
# assignments, values stripped of optional surrounding quotes -- and
# export each, so a corrupt or hostile file can never execute code the way
# a blind `source` would. An already-set environment variable always wins
# (we only fill keys the caller has not set), so a test or command-line
# override still takes precedence over the file.
#   OSTLER_GOVERNOR_SETTINGS -> override the settings file path
#                               (default ~/.ostler/config/governor.env).
ostler_rt_load_user_settings() {
    local f="${OSTLER_GOVERNOR_SETTINGS:-$HOME/.ostler/config/governor.env}"
    [ -f "$f" ] || return 0
    local line key val
    while IFS= read -r line || [ -n "$line" ]; do
        # Trim leading whitespace, drop blanks and comments.
        line="${line#"${line%%[![:space:]]*}"}"
        case "$line" in
            ''|'#'*) continue ;;
            'export '*) line="${line#export }" ;;
        esac
        # Only OSTLER_* = ... assignments are honoured; anything else is
        # ignored (never executed).
        case "$line" in
            OSTLER_[A-Z0-9_]*=*) ;;
            *) continue ;;
        esac
        key="${line%%=*}"
        val="${line#*=}"
        # Strip a single pair of matching surrounding quotes.
        case "$val" in
            \"*\") val="${val#\"}"; val="${val%\"}" ;;
            \'*\') val="${val#\'}"; val="${val%\'}" ;;
        esac
        # Explicit environment wins: only fill what is not already set.
        if [ -z "${!key+x}" ]; then
            export "$key=$val"
        fi
    done < "$f"
}

# Map the operator's throttle choice onto the concrete knobs the gates
# already read. Only fills a knob the operator/tier has not pinned, so an
# explicit ceiling still wins. "balanced" leaves the hardware-tier default
# untouched.
#   full    -- run freely: high per-core ceiling, no first-run defer, no
#              off-peak clamp. The single-flight lock + interactive-chat
#              yield still protect live replies.
#   gentle  -- ease right off: low per-core ceiling, defer on, and restrict
#              heavy history reads to the overnight off-peak window.
ostler_rt_apply_throttle_level() {
    case "${OSTLER_THROTTLE_LEVEL:-}" in
        full)
            OSTLER_LOADAVG_CEILING="${OSTLER_LOADAVG_CEILING:-8.0}"
            OSTLER_DEFER_NONESSENTIAL="${OSTLER_DEFER_NONESSENTIAL:-0}"
            OSTLER_INGEST_OFFPEAK_ONLY="${OSTLER_INGEST_OFFPEAK_ONLY:-0}"
            ;;
        gentle)
            OSTLER_LOADAVG_CEILING="${OSTLER_LOADAVG_CEILING:-1.0}"
            OSTLER_DEFER_NONESSENTIAL="${OSTLER_DEFER_NONESSENTIAL:-1}"
            OSTLER_INGEST_OFFPEAK_ONLY="${OSTLER_INGEST_OFFPEAK_ONLY:-1}"
            ;;
        balanced|'') ;;   # keep the hardware-tier default
        *) ;;             # unknown value: ignore, keep the tier default
    esac
}

# True (return 0) if the operator has paused background work. Pause is a
# soft, self-expiring yield: the panel writes OSTLER_PAUSED=1, optionally
# with OSTLER_PAUSE_UNTIL=<epoch-seconds>. With an until in the future we
# stay paused until it passes (auto-resume); with no until we stay paused
# until the operator resumes. A malformed until fails OPEN (treated as not
# paused) so a bad value can never wedge background work forever. Live
# interactive chat is never gated by this -- pause only stops the
# background enrichment/ingest storm.
ostler_resource_tier_is_paused() {
    [ "${OSTLER_PAUSED:-0}" = "1" ] || return 1
    local until="${OSTLER_PAUSE_UNTIL:-}"
    case "$until" in
        ''|forever) return 0 ;;      # paused until the operator resumes
        *[!0-9]*)  return 1 ;;       # malformed -> fail open (not paused)
    esac
    local now
    now="$(date +%s 2>/dev/null || echo 0)"
    if [ "$now" -lt "$until" ]; then
        return 0                     # still inside the pause window
    fi
    return 1                         # window elapsed -> auto-resume
}

# Compose the tier policy. Sets the OSTLER_* vars in the caller's shell.
# Honours pre-set overrides: if OSTLER_TIER is already exported we trust
# it and only fill the blanks (lets tests and operators pin a tier).
ostler_resource_tier_detect() {
    # Seed the operator's Settings-panel choices FIRST so pause/throttle
    # shape everything below, then let the throttle level fill its knobs
    # before the hardware-tier defaults do.
    ostler_rt_load_user_settings
    ostler_rt_apply_throttle_level

    OSTLER_RAM_GB="$(ostler_rt_ram_gb)"
    OSTLER_CPU_CORES="$(ostler_rt_cpu_cores)"
    OSTLER_PERF_CORES="$(ostler_rt_perf_cores)"

    # Allow an explicit override (testing / operator opt-out). An empty or
    # unknown value falls through to detection.
    local tier="${OSTLER_TIER:-}"
    case "$tier" in
        floor|low|high) ;;   # accept
        *) tier="" ;;
    esac

    if [ -z "$tier" ]; then
        # Conservative default: if we could read NOTHING, stay at floor.
        if [ "${OSTLER_RAM_GB:-0}" -le 0 ]; then
            tier="floor"
        elif [ "${OSTLER_RAM_GB}" -ge 32 ]; then
            tier="high"
        elif [ "${OSTLER_RAM_GB}" -ge 16 ]; then
            # 16GB is the installer's hard floor (ERR-02-PREREQ-RAM-LOW),
            # so the LOWEST supported machine sits at LOW, not floor:
            # concurrency 2, qwen3.5:9b. The "floor" tier below is reserved
            # for the sub-16GB / <=4 P-core case (e.g. an 8GB Air, were the
            # prereq ever lowered) and the detection-failure fallback.
            tier="low"
        else
            tier="floor"
        fi
        # Core-count override: <=4 performance cores is a floor machine
        # even if it somehow reports plenty of RAM (e.g. an 8GB Air, were
        # the 16GB prereq ever lowered).
        if [ "${OSTLER_PERF_CORES:-0}" -gt 0 ] && [ "${OSTLER_PERF_CORES}" -le 4 ]; then
            if [ "$tier" = "high" ]; then
                tier="low"
            else
                tier="floor"
            fi
        fi
    fi
    OSTLER_TIER="$tier"

    # Per-tier policy. Operator/test overrides win if already set.
    case "$OSTLER_TIER" in
        high)
            OSTLER_ENRICH_CONCURRENCY="${OSTLER_ENRICH_CONCURRENCY:-4}"
            OSTLER_DEFER_NONESSENTIAL="${OSTLER_DEFER_NONESSENTIAL:-0}"
            OSTLER_LOADAVG_CEILING="${OSTLER_LOADAVG_CEILING:-3.0}"
            OSTLER_ENRICH_NUM_CTX="${OSTLER_ENRICH_NUM_CTX:-}"
            ;;
        low)
            OSTLER_ENRICH_CONCURRENCY="${OSTLER_ENRICH_CONCURRENCY:-2}"
            OSTLER_DEFER_NONESSENTIAL="${OSTLER_DEFER_NONESSENTIAL:-1}"
            OSTLER_LOADAVG_CEILING="${OSTLER_LOADAVG_CEILING:-2.0}"
            OSTLER_ENRICH_NUM_CTX="${OSTLER_ENRICH_NUM_CTX:-8192}"
            ;;
        *)  # floor (the conservative fallback)
            OSTLER_TIER="floor"
            OSTLER_ENRICH_CONCURRENCY="${OSTLER_ENRICH_CONCURRENCY:-1}"
            OSTLER_DEFER_NONESSENTIAL="${OSTLER_DEFER_NONESSENTIAL:-1}"
            OSTLER_LOADAVG_CEILING="${OSTLER_LOADAVG_CEILING:-1.5}"
            OSTLER_ENRICH_NUM_CTX="${OSTLER_ENRICH_NUM_CTX:-4096}"
            ;;
    esac

    export OSTLER_TIER OSTLER_ENRICH_CONCURRENCY OSTLER_DEFER_NONESSENTIAL \
        OSTLER_LOADAVG_CEILING OSTLER_ENRICH_NUM_CTX \
        OSTLER_RAM_GB OSTLER_CPU_CORES OSTLER_PERF_CORES
    # Carry the operator controls into the caller's environment so the
    # later off-peak block (and any downstream tool) sees the same values.
    export OSTLER_PAUSED="${OSTLER_PAUSED:-0}" \
        OSTLER_PAUSE_UNTIL="${OSTLER_PAUSE_UNTIL:-}" \
        OSTLER_THROTTLE_LEVEL="${OSTLER_THROTTLE_LEVEL:-balanced}" \
        OSTLER_INGEST_OFFPEAK_ONLY="${OSTLER_INGEST_OFFPEAK_ONLY:-1}"
}

# Decide whether a NON-ESSENTIAL enrichment tick should defer right now.
# Returns 0 (yield) if it should defer, 1 (proceed) otherwise.
#
# A non-essential tick defers when EITHER the tier sets the defer flag
# (floor/low first-run posture) AND the machine is currently busier than
# the tier ceiling, OR -- regardless of the defer flag -- the normalised
# load is already over the ceiling. Essential work never calls this.
#
# "Normalised load" = 1-min loadavg / total cores, compared against
# OSTLER_LOADAVG_CEILING. We avoid floating point (POSIX sh has none) by
# scaling both sides by 100 and comparing integers via awk only for the
# division, falling back to "proceed" if anything is unreadable
# (fail-safe: never wedge background work on a probe quirk).
#
# Args: none. Reads OSTLER_DEFER_NONESSENTIAL, OSTLER_LOADAVG_CEILING,
# OSTLER_CPU_CORES (call ostler_resource_tier_detect first).
ostler_resource_tier_should_defer_nonessential() {
    # Operator pause wins over everything: yield unconditionally while
    # paused (auto-resumes when the pause window elapses).
    if ostler_resource_tier_is_paused; then
        OSTLER_DEFER_REASON="paused"
        return 0
    fi
    OSTLER_DEFER_REASON="load"

    local defer="${OSTLER_DEFER_NONESSENTIAL:-1}"
    local ceiling="${OSTLER_LOADAVG_CEILING:-1.5}"
    local cores="${OSTLER_CPU_CORES:-0}"

    local load
    load="$(ostler_rt_loadavg_1m)"

    # If we cannot read load or cores, fall back to the defer flag alone:
    # floor/low defer (conservative), high proceeds.
    if [ -z "${load:-}" ] || [ "${cores:-0}" -le 0 ]; then
        if [ "$defer" = "1" ]; then
            return 0
        fi
        return 1
    fi

    # over_ceiling = (load / cores) > ceiling ? 1 : 0, computed in awk so
    # the decimals are honoured. awk failure -> treat as NOT over (proceed).
    local over
    over="$(awk -v l="$load" -v c="$cores" -v cap="$ceiling" \
        'BEGIN { if (c <= 0) { print 0; exit } if ((l / c) > cap) print 1; else print 0 }' \
        2>/dev/null || echo 0)"

    if [ "$over" = "1" ]; then
        return 0   # busy: defer regardless of the flag
    fi

    # Not over the ceiling. Defer only on the floor/low first-run posture
    # is NOT applied here: the off-peak window + interactive marker handle
    # the steady-state drip. The defer flag's job is to keep the FIRST-RUN
    # spike from running at all while load is high, which the over-ceiling
    # check above already enforces. So below the ceiling we proceed.
    return 1
}

# CLI form: print the policy as KEY=VALUE lines (consumable by install.sh
# via `eval`), then exit. Only runs when executed directly, not sourced.
if [ "${BASH_SOURCE[0]:-$0}" = "${0}" ]; then
    ostler_resource_tier_detect
    printf 'OSTLER_TIER=%s\n' "$OSTLER_TIER"
    printf 'OSTLER_ENRICH_CONCURRENCY=%s\n' "$OSTLER_ENRICH_CONCURRENCY"
    printf 'OSTLER_DEFER_NONESSENTIAL=%s\n' "$OSTLER_DEFER_NONESSENTIAL"
    printf 'OSTLER_LOADAVG_CEILING=%s\n' "$OSTLER_LOADAVG_CEILING"
    printf 'OSTLER_ENRICH_NUM_CTX=%s\n' "$OSTLER_ENRICH_NUM_CTX"
    printf 'OSTLER_RAM_GB=%s\n' "$OSTLER_RAM_GB"
    printf 'OSTLER_CPU_CORES=%s\n' "$OSTLER_CPU_CORES"
    printf 'OSTLER_PERF_CORES=%s\n' "$OSTLER_PERF_CORES"
    printf 'OSTLER_PAUSED=%s\n' "${OSTLER_PAUSED:-0}"
    printf 'OSTLER_THROTTLE_LEVEL=%s\n' "${OSTLER_THROTTLE_LEVEL:-balanced}"
    printf 'OSTLER_INGEST_OFFPEAK_ONLY=%s\n' "${OSTLER_INGEST_OFFPEAK_ONLY:-1}"
fi
