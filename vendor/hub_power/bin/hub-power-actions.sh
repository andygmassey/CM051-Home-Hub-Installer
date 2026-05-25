#!/usr/bin/env bash
#
# hub-power-actions.sh
#
# Shared library of service-control functions used by the Ostler Hub power
# policy scripts. Sourced, never executed directly.
#
# Every function respects $DRY_RUN=1 and logs what it would have done rather
# than doing it. This is mandatory for tests and for sandboxed agent runs.
#
# British English throughout.

set -euo pipefail

# Guard against accidental direct execution.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    echo "hub-power-actions.sh is a library, not an executable. Source it." >&2
    exit 2
fi

# Import shared state helpers. $HPS_DIR lets tests override the location.
HPS_DIR="${HPS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck disable=SC1091
. "$HPS_DIR/hub-power-state.sh"

# Stubbing hook for tests: when $HPS_STUB_CMD=1, the stub wrapper just logs
# the command instead of invoking it. DRY_RUN=1 sets this implicitly.
if [ "${DRY_RUN:-0}" = "1" ]; then
    HPS_STUB_CMD=1
fi
HPS_STUB_CMD="${HPS_STUB_CMD:-0}"

# ---------------------------------------------------------------------------
# hpa_run <description> <command...>
# Runs a command, or logs it if stubbed. Errors inside stubbed commands never
# propagate; real errors do (so a failing `docker pause` is visible).
# ---------------------------------------------------------------------------
hpa_run() {
    local desc="$1"
    shift
    if [ "$HPS_STUB_CMD" = "1" ]; then
        hps_log "stub: $desc :: $*"
        return 0
    fi
    hps_log "run: $desc :: $*"
    "$@"
}

# ---------------------------------------------------------------------------
# hpa_bounded <seconds> <command...>
#
# Runs a command with a hard wall-clock limit. Returns the command's own exit
# code on success, 124 on timeout (matching GNU coreutils `timeout` convention).
#
# macOS has no native `timeout`; coreutils isn't a hard dependency of the
# Hub; perl ships with macOS out of the box, so we lean on it. The fork path
# kills the child with SIGTERM and reaps it, so there are no zombies.
#
# Used to bound `docker ps` calls against a hung Docker daemon. A wedged
# docker.sock (common after sleep / wake, which is exactly when these scripts
# fire) otherwise pins the script until launchd's own ExitTimeOut kicks it,
# masking which tier of battery policy actually ran.
# ---------------------------------------------------------------------------
HPA_DOCKER_TIMEOUT_SECS="${HPA_DOCKER_TIMEOUT_SECS:-5}"

hpa_bounded() {
    local secs="$1"
    shift
    perl -e '
        my $secs = shift @ARGV;
        my $pid = fork;
        die "fork failed: $!" unless defined $pid;
        if ($pid == 0) {
            exec { $ARGV[0] } @ARGV;
            exit 127;
        }
        local $SIG{ALRM} = sub {
            kill "TERM", $pid;
            waitpid $pid, 0;
            exit 124;
        };
        alarm $secs;
        waitpid $pid, 0;
        exit $? >> 8;
    ' "$secs" "$@"
}

# ---------------------------------------------------------------------------
# PWG Docker stack control
#
# The PWG stack lives in a docker compose project. We pause/unpause the
# running containers rather than stopping them – pause is cheap to reverse
# and keeps in-memory state (vector indexes, graph caches) warm.
#
# We match containers by label (com.creativemachines.ostler.tier=pwg) when
# available, otherwise fall back to a hardcoded name list. Containers that
# aren't running are silently skipped.
# ---------------------------------------------------------------------------

# Fallback list if no labels are set yet. Matches CLAUDE.md "9 containers" + whisper.
HPA_PWG_CONTAINERS=(
    "qdrant"
    "oxigraph"
    "redis"
    "whisper-stt"
    "gateway"
    "assistant-api"
    "conversation-memory-extractor"
    "vane"
    "n8n"
)

hpa_pwg_containers_running() {
    # Returns running container names that match our filter. Never errors.
    # `docker ps` is bounded to HPA_DOCKER_TIMEOUT_SECS because a wedged
    # docker.sock after sleep / wake would otherwise hang the whole script.
    if ! command -v docker >/dev/null 2>&1; then
        return 0
    fi
    # Prefer label-based filter. Compose files do not currently set this
    # label, so the filter is best-effort and we fall through to the name
    # list below in normal deployments.
    local by_label
    by_label="$(hpa_bounded "$HPA_DOCKER_TIMEOUT_SECS" docker ps --filter "label=com.creativemachines.ostler.tier=pwg" --format '{{.Names}}' 2>/dev/null || true)"
    if [ -n "$by_label" ]; then
        printf '%s\n' "$by_label"
        return 0
    fi
    # Fallback: match known names.
    local all_running
    all_running="$(hpa_bounded "$HPA_DOCKER_TIMEOUT_SECS" docker ps --format '{{.Names}}' 2>/dev/null || true)"
    local name
    for name in "${HPA_PWG_CONTAINERS[@]}"; do
        printf '%s\n' "$all_running" | grep -xF "$name" || true
    done
}

hpa_pwg_pause() {
    local containers
    containers="$(hpa_pwg_containers_running | awk 'NF')"
    if [ -z "$containers" ]; then
        hps_log "pwg-pause: no running containers to pause"
        return 0
    fi
    local c
    while IFS= read -r c; do
        [ -z "$c" ] && continue
        hpa_run "pause $c" docker pause "$c" || hps_log "pwg-pause: failed to pause $c"
    done <<< "$containers"
}

hpa_pwg_unpause() {
    # Docker distinguishes `paused` from `exited`. We only unpause the paused ones.
    if ! command -v docker >/dev/null 2>&1; then
        return 0
    fi
    local paused
    paused="$(hpa_bounded "$HPA_DOCKER_TIMEOUT_SECS" docker ps --filter 'status=paused' --format '{{.Names}}' 2>/dev/null || true)"
    if [ -z "$paused" ]; then
        hps_log "pwg-unpause: no paused containers"
        return 0
    fi
    local c
    while IFS= read -r c; do
        [ -z "$c" ] && continue
        hpa_run "unpause $c" docker unpause "$c" || hps_log "pwg-unpause: failed to unpause $c"
    done <<< "$paused"
}

# ---------------------------------------------------------------------------
# Ollama control
#
# We stop Ollama entirely under low-power. `ollama stop` unloads models from
# memory (>=0.20.0). If the binary isn't available or the subcommand is
# missing (older versions), we fall back to SIGTERM on the daemon process.
# ---------------------------------------------------------------------------

hpa_ollama_stop() {
    if command -v ollama >/dev/null 2>&1; then
        # Try `ollama stop <model>` for every loaded model, then as a last
        # resort `ollama serve` termination.
        local loaded
        loaded="$(ollama ps 2>/dev/null | awk 'NR>1 {print $1}' || true)"
        local m
        while IFS= read -r m; do
            [ -z "$m" ] && continue
            hpa_run "ollama stop $m" ollama stop "$m" || true
        done <<< "$loaded"
    fi
    # Kill the serve process too – frees the port and GPU memory.
    local pid
    pid="$(pgrep -f 'ollama serve' 2>/dev/null | head -n 1 || true)"
    if [ -n "$pid" ]; then
        hpa_run "signal ollama serve (pid $pid)" kill -TERM "$pid" || true
    else
        hps_log "ollama-stop: no serve process found"
    fi
}

hpa_ollama_start() {
    if ! command -v ollama >/dev/null 2>&1; then
        hps_log "ollama-start: binary not found, skipping"
        return 0
    fi
    # If already running, no-op.
    if pgrep -f 'ollama serve' >/dev/null 2>&1; then
        hps_log "ollama-start: already running"
        return 0
    fi
    # Prefer launchd if the Mac-Mini plist is installed (Ollama-as-launchd
    # pattern). Otherwise spawn in background.
    if launchctl list 2>/dev/null | grep -q 'com.ostler.ollama\|ai.ollama'; then
        hpa_run "kickstart ollama via launchd" launchctl kickstart -k "gui/$(id -u)/ai.ollama" || true
    else
        hpa_run "spawn ollama serve" nohup ollama serve >/dev/null 2>&1 &
        # Detach.
        disown 2>/dev/null || true
    fi
    # Stub mode skips the health check: there's no real ollama and the
    # poll would always fail. Real runs verify the daemon actually bound
    # to its port. Without this, a failing spawn was invisible because
    # the script continued as if it had succeeded.
    if [ "$HPS_STUB_CMD" = "1" ]; then
        hps_log "stub: ollama health check skipped"
        return 0
    fi
    hpa_ollama_health_check
}

# ---------------------------------------------------------------------------
# hpa_ollama_health_check
#
# Polls localhost:11434 for up to 5 seconds (5 attempts, 1 s apart) and
# returns 0 once /api/tags responds. Logs failure if the daemon never
# binds. Each curl is wrapped in hpa_bounded with a 2 s ceiling so a
# half-bound socket can't pin the function for longer than its budget.
# ---------------------------------------------------------------------------
HPA_OLLAMA_HEALTH_ATTEMPTS="${HPA_OLLAMA_HEALTH_ATTEMPTS:-5}"
HPA_OLLAMA_HEALTH_URL="${HPA_OLLAMA_HEALTH_URL:-http://localhost:11434/api/tags}"

hpa_ollama_health_check() {
    local attempt
    for ((attempt=1; attempt<=HPA_OLLAMA_HEALTH_ATTEMPTS; attempt++)); do
        if hpa_bounded 2 curl -fsS "$HPA_OLLAMA_HEALTH_URL" >/dev/null 2>&1; then
            hps_log "ollama-start: bound on :11434 (attempt $attempt)"
            return 0
        fi
        sleep 1
    done
    hps_log "ollama-start: FAILED to bind on :11434 after $HPA_OLLAMA_HEALTH_ATTEMPTS attempts"
    return 1
}

# ---------------------------------------------------------------------------
# Dispatch helpers used by hub-power-battery.sh and hub-power-watch.sh.
# Extracted so the case-statement branches are testable in isolation; the
# unknown-tier fall-through arm in particular cannot be reached through
# real fixtures because hps_current_tier never returns anything other
# than ac / battery_high / battery_mid / battery_low. Tests cover it
# by calling these functions directly with a synthetic tier value.
# ---------------------------------------------------------------------------

# hpa_dispatch_battery_tier <tier> [<script_dir>]
#
# Each branch logs at least once so a silent fall-through to the *)
# arm is detectable. battery_mid / battery_low arms exec into a
# sub-script and never return; in tests call this in a subshell so
# exec doesn't replace the test process.
hpa_dispatch_battery_tier() {
    local tier="$1"
    local script_dir="${2:-$HPS_DIR}"
    case "$tier" in
        ac|battery_high)
            hpa_ical_ensure_up
            hpa_zeroclaw_start
            hpa_ollama_start
            hpa_pwg_unpause
            hps_log "battery: tier=$tier, no throttle (ensured services up)"
            ;;
        battery_mid)
            exec "$script_dir/hub-power-battery-low.sh"
            ;;
        battery_low)
            exec "$script_dir/hub-power-battery-critical.sh"
            ;;
        *)
            hps_log "battery: unknown tier=$tier, treating as battery_high (failsafe)"
            ;;
    esac
}

# hpa_dispatch_watch_tier <prev_tier> <curr_tier> [<script_dir>]
#
# Returns immediately if the tier is unchanged. On a transition,
# dispatches to the right sub-script and logs both the transition
# and the dispatch. Unknown tiers log and no-op.
hpa_dispatch_watch_tier() {
    local prev_tier="$1"
    local curr_tier="$2"
    local script_dir="${3:-$HPS_DIR}"
    if [ "$curr_tier" = "$prev_tier" ]; then
        return 0
    fi
    hps_log "watch: tier transition $prev_tier -> $curr_tier"
    case "$curr_tier" in
        ac|battery_high)
            "$script_dir/hub-power-ac.sh" || hps_log "watch: hub-power-ac.sh failed"
            ;;
        battery_mid|battery_low)
            "$script_dir/hub-power-battery.sh" || hps_log "watch: hub-power-battery.sh failed"
            ;;
        *)
            hps_log "watch: unknown tier=$curr_tier, doing nothing"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# ZeroClaw control
#
# ZeroClaw (the assistant agent) runs under launchd as com.zeroclaw.daemon on
# the Hub. We stop it by unloading the LaunchAgent and start it by loading it
# again. Falls back to pkill if launchd control fails.
# ---------------------------------------------------------------------------

HPA_ZEROCLAW_LABEL="${HPA_ZEROCLAW_LABEL:-com.zeroclaw.daemon}"

hpa_zeroclaw_stop() {
    hps_log "zeroclaw-stop: attempting"
    local uid
    uid="$(id -u)"
    if launchctl list 2>/dev/null | grep -q "$HPA_ZEROCLAW_LABEL"; then
        hpa_run "bootout zeroclaw" launchctl bootout "gui/$uid/$HPA_ZEROCLAW_LABEL" || \
            hpa_run "legacy unload zeroclaw" launchctl unload "$HOME/Library/LaunchAgents/$HPA_ZEROCLAW_LABEL.plist" || true
    else
        hps_log "zeroclaw-stop: label $HPA_ZEROCLAW_LABEL not loaded"
    fi
    # Safety net: if a process somehow survives, SIGTERM it.
    local pid
    pid="$(pgrep -f 'zeroclaw' 2>/dev/null | head -n 1 || true)"
    if [ -n "$pid" ]; then
        hpa_run "signal zeroclaw (pid $pid)" kill -TERM "$pid" || true
    else
        hps_log "zeroclaw-stop: no process to signal"
    fi
}

hpa_zeroclaw_start() {
    local uid
    uid="$(id -u)"
    local plist="$HOME/Library/LaunchAgents/$HPA_ZEROCLAW_LABEL.plist"
    if [ -f "$plist" ]; then
        hpa_run "bootstrap zeroclaw" launchctl bootstrap "gui/$uid" "$plist" || \
            hpa_run "legacy load zeroclaw" launchctl load "$plist" || true
    else
        hps_log "zeroclaw-start: plist not found at $plist"
    fi
}

hpa_zeroclaw_catchup_request() {
    # Best-effort trigger for a post-wake catch-up pass. ZeroClaw does not
    # currently poll for this marker (confirmed in the HR015 agent brief);
    # this writes the file anyway so the eventual polling hook can pick it
    # up, and logs the gap explicitly.
    local marker="$HOME/.zeroclaw/catchup_requested"
    mkdir -p "$(dirname "$marker")"
    local ts
    ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    if [ "$HPS_STUB_CMD" = "1" ]; then
        hps_log "stub: catchup marker write :: $marker ($ts)"
    else
        printf '%s\n' "$ts" > "$marker"
        hps_log "catchup marker written :: $marker"
    fi
    hps_log "catchup: ZeroClaw has no polling hook yet (v1); restart-on-wake is the delivery path"
}

# ---------------------------------------------------------------------------
# ical-server control
#
# ical-server.py is the last process standing. We never stop it as part of
# the power policy (it's lightweight and serves the Hub health endpoint that
# the iOS Companion polls). Start/restart helpers are here for wake paths.
# ---------------------------------------------------------------------------

HPA_ICAL_LABEL="${HPA_ICAL_LABEL:-com.ostler.ical-server}"

hpa_ical_ensure_up() {
    local uid
    uid="$(id -u)"
    if launchctl list 2>/dev/null | grep -q "$HPA_ICAL_LABEL"; then
        hps_log "ical-server: running under launchd, leaving alone"
        return 0
    fi
    local plist="$HOME/Library/LaunchAgents/$HPA_ICAL_LABEL.plist"
    if [ -f "$plist" ]; then
        hpa_run "bootstrap ical-server" launchctl bootstrap "gui/$uid" "$plist" || \
            hpa_run "legacy load ical-server" launchctl load "$plist" || true
    else
        hps_log "ical-server: plist not found at $plist"
    fi
}
