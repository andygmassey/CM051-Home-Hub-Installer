#!/usr/bin/env bash
# test_tier48_picks_9b.sh -- v1.0.121: the 48GB+ RAM tier installs qwen3.5:9b.
# The 35b-a3b model cannot be safety-tested until about 21 Nov (no 48GB+ test
# box exists). 35b restored after the M5 red team, tracked as a 122 row.
# Covers the picker (lib/ostler-model-fit.sh) AND the stripped-bundle ladder
# in install.sh, which is a second copy of the same mapping.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

# shellcheck source=../lib/ostler-model-fit.sh
source "${ROOT}/lib/ostler-model-fit.sh"
want() {
    local ram="$1" model="$2" got
    got="$(ostler_recommend_model "$ram")"
    [[ "$got" == "$model" ]] && ok "recommend(${ram}GB) = $model" \
        || bad "recommend(${ram}GB) expected $model, got $got"
}
echo "== 48GB+ -> qwen3.5:9b =="
for r in 48 64 128; do want "$r" qwen3.5:9b; done
echo "== unchanged tiers =="
want 16 gemma4:e2b
for r in 24 32 47; do want "$r" qwen3.5:9b; done
echo "== no 35b anywhere the customer is shown a model =="
[[ " ${OSTLER_MODEL_TAGS[*]} " != *35b* ]] && ok "35b not in OSTLER_MODEL_TAGS" \
    || bad "35b is in OSTLER_MODEL_TAGS"

echo "== install.sh stripped-bundle ladder, executed =="
# Extract the fallback if/elif/else and run it for each RAM value.
ladder="$(awk '/Fallback: helper not on disk/{f=1} f&&/ok "\$\(printf "\$MSG_OK_AI_MODEL_SELECTED/{exit} f' "${ROOT}/install.sh")"
[[ -n "$ladder" ]] && ok "ladder extracted ($(wc -l <<<"$ladder") lines)" || bad "ladder not found"
for r in 48 64 128; do
    got="$(RAM_GB=$r bash -c "$ladder"$'\nprintf %s "$AI_MODEL|$AI_MODEL_SIZE"' 2>&1)"
    [[ "$got" == "qwen3.5:9b|~6.6 GB" ]] && ok "ladder(${r}GB) = $got" || bad "ladder(${r}GB) = $got"
done
got="$(RAM_GB=16 bash -c "$ladder"$'\nprintf %s "$AI_MODEL"' 2>&1)"
[[ "$got" == "gemma4:e2b" ]] && ok "ladder(16GB) = gemma4:e2b" || bad "ladder(16GB) = $got"
got="$(RAM_GB=32 bash -c "$ladder"$'\nprintf %s "$AI_MODEL"' 2>&1)"
[[ "$got" == "qwen3.5:9b" ]] && ok "ladder(32GB) = qwen3.5:9b" || bad "ladder(32GB) = $got"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
