#!/usr/bin/env bash
# test_tier48_picks_35b.sh -- the RAM tiers pick their chat model.
# 48GB+ installs qwen3.6:35b-a3b (restored v1.0.131, commit 6b0b8c40 withheld it
# at v1.0.121 only because no 48GB+ test box existed). 24-47GB installs
# qwen3.5:9b. 16GB installs qwen3.5:4b. The 48GB+ choice is not shipped on
# evidence until the 64GB MBP evidence lands (see the PR body).
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
echo "== 48GB+ -> qwen3.6:35b-a3b =="
for r in 48 64 128; do want "$r" qwen3.6:35b-a3b; done
echo "== 24-47GB -> qwen3.5:9b =="
for r in 24 32 47; do want "$r" qwen3.5:9b; done
echo "== 16GB -> qwen3.5:4b =="
want 16 qwen3.5:4b
echo "== 35b is in the picker and first (best-first) =="
[[ "${OSTLER_MODEL_TAGS[0]}" == "qwen3.6:35b-a3b" ]] && ok "35b-a3b is OSTLER_MODEL_TAGS[0]" \
    || bad "OSTLER_MODEL_TAGS[0] is ${OSTLER_MODEL_TAGS[0]}, not qwen3.6:35b-a3b"

echo "== install.sh stripped-bundle ladder, executed =="
# Extract the fallback if/elif/else and run it for each RAM value.
ladder="$(awk '/Fallback: helper not on disk/{f=1} f&&/ok "\$\(printf "\$MSG_OK_AI_MODEL_SELECTED/{exit} f' "${ROOT}/install.sh")"
[[ -n "$ladder" ]] && ok "ladder extracted ($(wc -l <<<"$ladder") lines)" || bad "ladder not found"
for r in 48 64 128; do
    got="$(RAM_GB=$r bash -c "$ladder"$'\nprintf %s "$AI_MODEL|$AI_MODEL_SIZE"' 2>&1)"
    [[ "$got" == "qwen3.6:35b-a3b|~22.7 GB" ]] && ok "ladder(${r}GB) = $got" || bad "ladder(${r}GB) = $got"
done
for r in 24 32 47; do
    got="$(RAM_GB=$r bash -c "$ladder"$'\nprintf %s "$AI_MODEL|$AI_MODEL_SIZE"' 2>&1)"
    [[ "$got" == "qwen3.5:9b|~6.6 GB" ]] && ok "ladder(${r}GB) = $got" || bad "ladder(${r}GB) = $got"
done
got="$(RAM_GB=16 bash -c "$ladder"$'\nprintf %s "$AI_MODEL"' 2>&1)"
[[ "$got" == "qwen3.5:4b" ]] && ok "ladder(16GB) = qwen3.5:4b" || bad "ladder(16GB) = $got"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
