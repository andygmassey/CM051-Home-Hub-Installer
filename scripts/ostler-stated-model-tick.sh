#!/usr/bin/env bash
# One tick of the stated-preference TIER-MODEL stage (polarity only).
#
# NOT INSTALLED. DISABLED BY DECISION: measured precision on the Mini16 was 2 of
# 6 hand-graded model hits (33%), under the 80% bar Archie set, and 6 is under
# the 30-hit sample he asked for. install.sh does not write a LaunchAgent for
# this, so nothing runs it. Enabling it is: a _install_*_agent that runs this
# wrapper (ProcessType=Background, StartInterval ~3600), once precision >= 80%
# is measured on >= 30 hits. Until then the stage is code and tests only.
#
# What the wrapper guarantees, tested by tests/test_stated_model_tick_yields.sh:
#   * the resource-tier pause/defer check skips the tick (chat, the brief and
#     everything interactive come first);
#   * the shared ingest slot is TAKEN (ostler_slot_acquire); a busy slot yields
#     the tick instead of queueing behind it, and the payload runs under
#     ostler_slot_run so the slot's max-hold watchdog bounds it;
#   * the model is the RAM-tier model from ostler_recommend_model and nothing
#     else: there is no override, so it can never be a bigger model;
#   * a per-tick cap on model calls (OSTLER_STATED_MODEL_CAP, default 200);
#   * no tier lib or no resolvable model means no run, never a guess.
set -uo pipefail

OSTLER_DIR="${OSTLER_DIR:-${HOME}/.ostler}"
LOGS_DIR="${OSTLER_DIR}/logs"
CM019_DIR="${OSTLER_CM019_DIR:-${OSTLER_DIR}/services/cm019}"
CM019_PY="${CM019_DIR}/.venv/bin/python3"
LOG_FILE="${LOGS_DIR}/stated-model.log"
CAP="${OSTLER_STATED_MODEL_CAP:-200}"

mkdir -p "$LOGS_DIR"
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_FILE"; }

if [[ ! -x "$CM019_PY" ]]; then
    log "no preferences service at ${CM019_DIR}; nothing to do"
    exit 0
fi

_tier_lib="${OSTLER_RESOURCE_TIER_LIB:-${HOME}/.ostler/lib/ostler-resource-tier.sh}"
if [[ "${OSTLER_RESOURCE_GOVERNOR:-1}" == "1" && -f "$_tier_lib" ]]; then
    # shellcheck source=/dev/null
    . "$_tier_lib"
    if command -v ostler_resource_tier_detect >/dev/null 2>&1; then
        ostler_resource_tier_detect
        if ostler_resource_tier_should_defer_nonessential; then
            log "deferred (${OSTLER_DEFER_REASON:-load}); the next tick tries again"
            exit 0
        fi
    fi
fi

_fit_lib="${OSTLER_MODEL_FIT_LIB:-${HOME}/.ostler/lib/ostler-model-fit.sh}"
MODEL=""
if [[ -f "$_fit_lib" ]]; then
    # shellcheck source=/dev/null
    . "$_fit_lib"
    MODEL="$(ostler_recommend_model "$(ostler_detect_total_ram_gb)" 2>/dev/null || true)"
fi
if [[ -z "$MODEL" ]]; then
    log "no tier model resolved (model-fit lib missing or empty); not running"
    exit 0
fi

cd "$CM019_DIR" || { log "cannot enter ${CM019_DIR}"; exit 0; }
CMD=("$CM019_PY" -m services.enrich.src.derive.stated_model --model "$MODEL" --cap "$CAP")

_slot_lib="${OSTLER_SLOT_LIB:-${HOME}/.ostler/lib/ostler-ingest-slot.sh}"
if [[ ! -f "$_slot_lib" ]]; then
    log "no ingest slot lib; not running a model stage without the slot"
    exit 0
fi
# shellcheck source=/dev/null
. "$_slot_lib"
if ! ostler_slot_acquire "stated-model"; then
    log "ingest slot busy; yielding this tick"
    exit 0
fi
log "tick start (model ${MODEL}, cap ${CAP})"
if ostler_slot_run "${CMD[@]}" >>"$LOG_FILE" 2>&1; then
    log "tick finished"
else
    log "tick ended non-zero (the verdict cache keeps what finished)"
fi
exit 0
