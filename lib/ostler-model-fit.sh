#!/usr/bin/env bash
# lib/ostler-model-fit.sh -- hardware-fit Ollama model picker (REUSE-4).
#
# WHY THIS EXISTS
# ---------------
# Pre-this-helper, install.sh chose the Ollama model from a flat RAM ladder
# (>=48 -> 35b-a3b, >=24 -> 9b, else e2b). That ladder ignored the agent's
# required context window: the daemon runs every chat at num_ctx=32768
# (OLLAMA_NUM_CTX, see test_assistant_ollama_num_ctx.sh), and a 32k KV cache
# costs gigabytes ON TOP of the model weights. So a box could "have enough RAM
# for the weights" yet still cold-start-fail when Ollama allocated the 32k
# context. Box-walks hit exactly this num_ctx-too-big / model-doesn't-fit class.
#
# This helper detects the Mac's hardware and scores each candidate model as
# Fits / may be slow / won't fit AGAINST the agent's real num_ctx, then names
# the best-fitting model as Recommended. It is pure logic: sourcing it defines
# functions and the model table but performs NO I/O and prints nothing, so it
# is trivially unit-testable over synthetic RAM values (tests/test_model_fit.sh).
#
# CONTRACT
# --------
# Source it, then call:
#
#   ostler_detect_total_ram_gb            -> echoes integer GB (sysctl hw.memsize)
#   ostler_detect_chip                    -> echoes chip string (e.g. "Apple M2 Pro")
#   ostler_detect_gpu_cores               -> echoes integer GPU core count or "" if unknown
#   ostler_model_fit <model> <ram_gb>     -> echoes one of: fits | slow | nofit
#   ostler_recommend_model <ram_gb>       -> echoes the best model tag that fits comfortably
#   ostler_model_size_label <model>       -> echoes the human download-size label (e.g. "~6.6 GB")
#   ostler_model_quant <model>            -> echoes the quant tier (e.g. "q4_K_M")
#   ostler_model_fit_pill <verdict>       -> echoes a short en-GB pill ("Fits" / "May be slow" / "Won't fit")
#
# The agent context window the fit is computed against:
OSTLER_MODEL_FIT_NUM_CTX="${OSTLER_MODEL_FIT_NUM_CTX:-32768}"

# ── Static model table ────────────────────────────────────────────────
#
# Columns (parallel-indexed arrays so this works on bash 3.2, the macOS
# system bash -- no associative arrays):
#
#   tag        : the `ollama pull` tag
#   weights_gb : approximate resident weight size, GB (download ~ same)
#   quant      : quant tier shipped at that tag
#   size_label : human-friendly download size for the installer copy
#   min_fit    : MINIMUM total system RAM (GB) to run this model AT
#                OSTLER_MODEL_FIT_NUM_CTX comfortably (= weights + 32k KV
#                cache + macOS/Docker headroom). Below this -> "won't fit".
#   min_slow   : RAM (GB) at/above which it runs but with little headroom,
#                so it may swap / be slow. Between min_slow and min_fit
#                -> "may be slow"; at/above min_fit -> "fits".
#
# The min_fit / min_slow figures are deliberately conservative: a cold
# install that picks a too-big model is a hard box-walk failure, whereas
# picking one tier down is merely "less rich answers". We bias to "fits".
#
# Ordering matters: BEST-first (most capable model first). The recommender
# walks this order and picks the first model whose verdict is "fits".
OSTLER_MODEL_TAGS=(   "qwen3.6:35b-a3b" "qwen3.5:9b" "gemma4:e2b" )
OSTLER_MODEL_WEIGHTS=( 23                6            5            )
OSTLER_MODEL_QUANT=(  "q4_K_M"          "q4_K_M"     "q4_K_M"      )
OSTLER_MODEL_SIZELBL=("~23 GB"          "~6.6 GB"    "~5 GB"       )
# min_fit: comfortable at num_ctx 32768.
#   35b-a3b: ~23 GB weights + ~5 GB 32k KV + headroom -> needs ~48 GB box.
#   9b     : ~6 GB weights  + ~2 GB 32k KV + headroom -> needs ~24 GB box.
#   e2b    : ~5 GB weights  + ~1 GB 32k KV + headroom -> needs ~16 GB box.
OSTLER_MODEL_MINFIT=( 48                24           16           )
# min_slow: will load but tight (swap risk) below min_fit.
OSTLER_MODEL_MINSLOW=(36                18           12           )

# Internal: index of a model tag in the parallel arrays. Echoes -1 if absent.
_ostler_model_index() {
    local want="$1" i
    for i in "${!OSTLER_MODEL_TAGS[@]}"; do
        if [[ "${OSTLER_MODEL_TAGS[$i]}" == "$want" ]]; then
            printf '%s' "$i"
            return 0
        fi
    done
    printf '%s' "-1"
    return 1
}

# ── Hardware detection ────────────────────────────────────────────────

# Total physical RAM in whole GB. Mirrors install.sh's existing
# RAM_GB=$(( $(sysctl -n hw.memsize) / 1073741824 )) so the two never drift.
ostler_detect_total_ram_gb() {
    local bytes
    bytes="$(sysctl -n hw.memsize 2>/dev/null || printf '0')"
    if [[ "$bytes" =~ ^[0-9]+$ ]] && (( bytes > 0 )); then
        printf '%s' "$(( bytes / 1073741824 ))"
    else
        printf '%s' "0"
    fi
}

# Chip / SoC string, e.g. "Apple M2 Pro". Falls back to hw.model then
# uname -m so it always echoes something non-empty on a real Mac.
ostler_detect_chip() {
    local chip
    chip="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || true)"
    if [[ -z "$chip" ]]; then
        chip="$(sysctl -n hw.model 2>/dev/null || true)"
    fi
    if [[ -z "$chip" ]]; then
        chip="$(uname -m 2>/dev/null || printf 'unknown')"
    fi
    printf '%s' "$chip"
}

# GPU core count via system_profiler, if reported. Echoes "" when unknown
# (older OS / VM / parse miss) -- callers must treat empty as "no signal".
ostler_detect_gpu_cores() {
    local cores
    cores="$(system_profiler SPDisplaysDataType 2>/dev/null \
        | awk -F': ' '/Total Number of Cores/ {gsub(/[^0-9]/,"",$2); print $2; exit}')"
    if [[ "$cores" =~ ^[0-9]+$ ]]; then
        printf '%s' "$cores"
    else
        printf '%s' ""
    fi
}

# ── Fit logic ─────────────────────────────────────────────────────────

# ostler_model_fit <model_tag> <ram_gb> -> fits | slow | nofit
# Compares detected RAM against the model's min_fit / min_slow thresholds.
ostler_model_fit() {
    local model="$1" ram="$2" idx
    idx="$(_ostler_model_index "$model")" || { printf 'nofit'; return 1; }
    [[ "$ram" =~ ^[0-9]+$ ]] || { printf 'nofit'; return 1; }
    local minfit="${OSTLER_MODEL_MINFIT[$idx]}"
    local minslow="${OSTLER_MODEL_MINSLOW[$idx]}"
    if (( ram >= minfit )); then
        printf 'fits'
    elif (( ram >= minslow )); then
        printf 'slow'
    else
        printf 'nofit'
    fi
}

# ostler_recommend_model <ram_gb> -> best model tag that FITS comfortably.
# Walks the BEST-first table and returns the first model whose verdict is
# "fits". If nothing fits comfortably (very small box), falls back to the
# smallest model that at least loads ("slow"), and finally to the smallest
# model in the table as a last resort so the installer always has a target.
ostler_recommend_model() {
    local ram="$1" i tag verdict
    [[ "$ram" =~ ^[0-9]+$ ]] || ram=0
    # Pass 1: first model that fits comfortably.
    for i in "${!OSTLER_MODEL_TAGS[@]}"; do
        tag="${OSTLER_MODEL_TAGS[$i]}"
        verdict="$(ostler_model_fit "$tag" "$ram")"
        if [[ "$verdict" == "fits" ]]; then
            printf '%s' "$tag"
            return 0
        fi
    done
    # Pass 2: nothing fits comfortably -- pick the smallest model that at
    # least loads (highest index with verdict != nofit). Table is best-first
    # so iterate in reverse to prefer the smallest.
    for (( i=${#OSTLER_MODEL_TAGS[@]}-1; i>=0; i-- )); do
        tag="${OSTLER_MODEL_TAGS[$i]}"
        verdict="$(ostler_model_fit "$tag" "$ram")"
        if [[ "$verdict" != "nofit" ]]; then
            printf '%s' "$tag"
            return 0
        fi
    done
    # Pass 3: last resort -- smallest model in the table.
    printf '%s' "${OSTLER_MODEL_TAGS[$(( ${#OSTLER_MODEL_TAGS[@]} - 1 ))]}"
}

# Accessors for the installer copy.
ostler_model_size_label() {
    local idx; idx="$(_ostler_model_index "$1")" || { printf ''; return 1; }
    printf '%s' "${OSTLER_MODEL_SIZELBL[$idx]}"
}
ostler_model_quant() {
    local idx; idx="$(_ostler_model_index "$1")" || { printf ''; return 1; }
    printf '%s' "${OSTLER_MODEL_QUANT[$idx]}"
}

# ostler_model_fit_pill <verdict> -> short label. Uses the installer's en-GB
# strings catalogue if those MSG_* are defined (sourced before this helper),
# otherwise falls back to built-in English so the helper is self-contained
# for unit tests.
ostler_model_fit_pill() {
    case "$1" in
        fits)  printf '%s' "${MSG_MODELFIT_PILL_FITS:-Fits}" ;;
        slow)  printf '%s' "${MSG_MODELFIT_PILL_SLOW:-May be slow}" ;;
        nofit) printf '%s' "${MSG_MODELFIT_PILL_NOFIT:-Will not fit}" ;;
        *)     printf '%s' "$1" ;;
    esac
}
