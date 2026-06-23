#!/usr/bin/env bash
# test_model_fit.sh -- REUSE-4 hardware-fit model picker.
#
# install.sh used to pick the Ollama model from a flat RAM ladder that ignored
# the agent's required context window (num_ctx=32768). A 32k KV cache costs
# gigabytes ON TOP of the model weights, so boxes that "had enough RAM for the
# weights" still cold-start-failed when Ollama allocated the 32k context.
#
# lib/ostler-model-fit.sh now scores each candidate model Fits / may be slow /
# won't fit against the real num_ctx and recommends the best comfortable fit.
# This test sources that pure helper and drives it over SYNTHETIC RAM values,
# asserting the fit verdict per model and the recommended model at each tier.
# It also confirms install.sh wires the helper in and keeps a legacy fallback.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
HELPER="${ROOT}/lib/ostler-model-fit.sh"
INSTALL="${ROOT}/install.sh"
STRINGS="${ROOT}/install.sh.strings.en-GB.sh"

PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "== helper sources cleanly and is side-effect-free =="
bash -n "$HELPER" && ok "ostler-model-fit.sh passes bash -n" \
    || bad "ostler-model-fit.sh failed bash -n"

# Sourcing must print nothing (pure logic) and define the contract functions.
src_out="$(source "$HELPER" 2>&1)"
[[ -z "$src_out" ]] \
    && ok "sourcing the helper prints nothing" \
    || bad "sourcing the helper printed output: '$src_out'"

# shellcheck source=../lib/ostler-model-fit.sh
source "$HELPER"
for fn in ostler_detect_total_ram_gb ostler_detect_chip ostler_detect_gpu_cores \
          ostler_model_fit ostler_recommend_model ostler_model_size_label \
          ostler_model_quant ostler_model_fit_pill; do
    declare -F "$fn" >/dev/null 2>&1 \
        && ok "function defined: $fn" \
        || bad "function MISSING: $fn"
done

echo "== num_ctx the fit is computed against =="
[[ "${OSTLER_MODEL_FIT_NUM_CTX}" == "32768" ]] \
    && ok "fit computed against num_ctx 32768 (matches OLLAMA_NUM_CTX)" \
    || bad "OSTLER_MODEL_FIT_NUM_CTX wrong (got '${OSTLER_MODEL_FIT_NUM_CTX:-<unset>}')"

# ── Per-model fit verdicts over synthetic RAM ─────────────────────────
# assert_fit <model> <ram_gb> <expected: fits|slow|nofit>
assert_fit() {
    local model="$1" ram="$2" want="$3" got
    got="$(ostler_model_fit "$model" "$ram")"
    if [[ "$got" == "$want" ]]; then
        ok "fit($model, ${ram}GB) = $want"
    else
        bad "fit($model, ${ram}GB) expected $want, got $got"
    fi
}

echo "== verdicts: gemma4:e2b (16/12 thresholds) =="
assert_fit gemma4:e2b 8  nofit   # below min_slow -> won't fit
assert_fit gemma4:e2b 12 slow    # min_slow boundary -> may be slow
assert_fit gemma4:e2b 15 slow
assert_fit gemma4:e2b 16 fits    # min_fit boundary -> fits
assert_fit gemma4:e2b 64 fits

echo "== verdicts: qwen3.5:9b (24/18 thresholds) =="
assert_fit qwen3.5:9b 16 nofit
assert_fit qwen3.5:9b 18 slow    # min_slow boundary
assert_fit qwen3.5:9b 23 slow
assert_fit qwen3.5:9b 24 fits    # min_fit boundary
assert_fit qwen3.5:9b 48 fits

echo "== verdicts: qwen3.6:35b-a3b (48/36 thresholds) =="
assert_fit qwen3.6:35b-a3b 24 nofit
assert_fit qwen3.6:35b-a3b 36 slow   # min_slow boundary
assert_fit qwen3.6:35b-a3b 47 slow
assert_fit qwen3.6:35b-a3b 48 fits   # min_fit boundary
assert_fit qwen3.6:35b-a3b 128 fits

echo "== recommended model per RAM tier (best comfortable fit) =="
# assert_reco <ram_gb> <expected_model>
assert_reco() {
    local ram="$1" want="$2" got
    got="$(ostler_recommend_model "$ram")"
    if [[ "$got" == "$want" ]]; then
        ok "recommend(${ram}GB) = $want"
    else
        bad "recommend(${ram}GB) expected $want, got $got"
    fi
}
# Below everything's min_fit but e2b still loads at 12-15GB -> e2b (smallest
# that at least runs). At/below 8GB nothing loads -> still e2b as last resort.
assert_reco 8   gemma4:e2b
assert_reco 12  gemma4:e2b
assert_reco 16  gemma4:e2b        # e2b fits, 9b does not at 16
assert_reco 18  gemma4:e2b        # 9b only "slow" at 18, so e2b is the comfy fit
assert_reco 24  qwen3.5:9b        # 9b now fits comfortably
assert_reco 36  qwen3.5:9b        # 35b only "slow" at 36, 9b still the comfy fit
assert_reco 48  qwen3.6:35b-a3b   # 35b fits comfortably
assert_reco 64  qwen3.6:35b-a3b
assert_reco 128 qwen3.6:35b-a3b

echo "== recommended model never recommends a model that won't fit =="
for ram in 4 8 12 16 18 20 24 32 36 48 64 96 128; do
    reco="$(ostler_recommend_model "$ram")"
    verdict="$(ostler_model_fit "$reco" "$ram")"
    # At very small boxes (<12GB) even the smallest model is "nofit"; that is
    # the documented last-resort. Above that the recommendation must at least
    # load (fits or slow), never nofit.
    if (( ram >= 12 )); then
        [[ "$verdict" != "nofit" ]] \
            && ok "recommend(${ram}GB)=$reco is runnable ($verdict)" \
            || bad "recommend(${ram}GB)=$reco verdict nofit -- would cold-start-fail"
    else
        ok "recommend(${ram}GB)=$reco (last-resort tier, <12GB)"
    fi
done

echo "== monotonicity: more RAM never recommends a SMALLER model =="
# Encode capability rank (best=2 .. smallest=0).
rank() {
    case "$1" in
        qwen3.6:35b-a3b) printf 2 ;;
        qwen3.5:9b)      printf 1 ;;
        gemma4:e2b)      printf 0 ;;
        *)               printf -1 ;;
    esac
}
prev_rank=-1
mono_ok=1
for ram in 8 16 18 24 36 48 64 128; do
    r="$(rank "$(ostler_recommend_model "$ram")")"
    if (( r < prev_rank )); then mono_ok=0; fi
    prev_rank="$r"
done
(( mono_ok == 1 )) \
    && ok "recommendation is monotonic in RAM (never downgrades as RAM grows)" \
    || bad "recommendation downgraded with more RAM (non-monotonic)"

echo "== accessors + pills =="
[[ "$(ostler_model_size_label qwen3.5:9b)" == "~6.6 GB" ]] \
    && ok "size label for 9b" || bad "size label for 9b wrong"
[[ -n "$(ostler_model_quant qwen3.5:9b)" ]] \
    && ok "quant tier present for 9b ($(ostler_model_quant qwen3.5:9b))" \
    || bad "quant tier missing for 9b"
[[ "$(ostler_model_fit_pill fits)" == "Fits" ]] \
    && ok "pill: fits -> Fits" || bad "pill fits wrong"
[[ "$(ostler_model_fit_pill slow)" == "May be slow" ]] \
    && ok "pill: slow -> May be slow" || bad "pill slow wrong"
[[ -n "$(ostler_model_fit_pill nofit)" ]] \
    && ok "pill: nofit -> '$(ostler_model_fit_pill nofit)'" || bad "pill nofit empty"

echo "== en-GB pill strings override the built-in defaults when sourced first =="
( source "$STRINGS"; source "$HELPER"
  [[ "$(ostler_model_fit_pill fits)" == "$MSG_MODELFIT_PILL_FITS" ]] ) \
    && ok "pill uses catalogue MSG_MODELFIT_PILL_FITS when available" \
    || bad "pill did not honour the en-GB catalogue"

echo "== detection helpers run on this host without aborting =="
ram_here="$(ostler_detect_total_ram_gb)"
[[ "$ram_here" =~ ^[0-9]+$ ]] \
    && ok "ostler_detect_total_ram_gb returned an integer (${ram_here})" \
    || bad "ostler_detect_total_ram_gb returned non-integer '${ram_here}'"
[[ -n "$(ostler_detect_chip)" ]] \
    && ok "ostler_detect_chip returned non-empty ('$(ostler_detect_chip)')" \
    || bad "ostler_detect_chip returned empty"
# GPU cores may legitimately be empty (VM / parse miss); just must not error.
ostler_detect_gpu_cores >/dev/null 2>&1 \
    && ok "ostler_detect_gpu_cores ran without error" \
    || bad "ostler_detect_gpu_cores errored"

echo "== install.sh wiring =="
grep -q 'lib/ostler-model-fit.sh' "$INSTALL" \
    && ok "install.sh sources lib/ostler-model-fit.sh" \
    || bad "install.sh does NOT source the helper"
grep -q 'ostler_recommend_model' "$INSTALL" \
    && ok "install.sh calls ostler_recommend_model for the model pick" \
    || bad "install.sh does NOT call ostler_recommend_model"
# Legacy fallback must remain so a stripped bundle degrades, not aborts.
grep -q 'declare -F ostler_recommend_model' "$INSTALL" \
    && ok "install.sh guards on the helper being present (legacy fallback kept)" \
    || bad "install.sh has no presence-guard / fallback for a stripped bundle"
bash -n "$INSTALL" \
    && ok "install.sh passes bash -n with the wiring in place" \
    || bad "install.sh failed bash -n"

echo "== strings catalogue carries the new keys =="
for key in MSG_MODELFIT_PILL_FITS MSG_MODELFIT_PILL_SLOW MSG_MODELFIT_PILL_NOFIT \
           MSG_MODELFIT_HEADER MSG_MODELFIT_ROW MSG_MODELFIT_RECOMMENDED_TAG \
           MSG_MODELFIT_SELECTED; do
    grep -q "^${key}=" "$STRINGS" \
        && ok "strings catalogue defines ${key}" \
        || bad "strings catalogue MISSING ${key}"
done

echo ""
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
