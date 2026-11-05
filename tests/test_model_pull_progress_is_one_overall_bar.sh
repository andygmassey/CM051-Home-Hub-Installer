#!/usr/bin/env bash
# F&F 2026-11-05 item 4. `ollama pull` reports a percent PER LAYER; the old
# wrapper emitted it as the step bar, so the bar reset per layer and sat at 100%
# whenever a small layer finished while the big one ran on. The aggregator
# (awk_src in _gui_ollama_pull, install.sh) must give ONE overall bar: summed bytes,
# capped at 99 until success, monotonic, one line per change.
# Usage: tests/test_model_pull_progress_is_one_overall_bar.sh [install.sh]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="${1:-${HERE}/../install.sh}"
FIX="${HERE}/fixtures/ollama_pull_multilayer.stream"
[ -f "$SH" ] && [ -f "$FIX" ] || { echo "CANNOT-RUN: install.sh or fixture missing"; exit 2; }
AWKSRC="$(awk '/^    local awk_src=\x27$/{f=1;next} f&&/^    \x27$/{exit} f{print}' "$SH")"
[ -n "$AWKSRC" ] || { echo "CANNOT-RUN: local awk_src not found in $SH"; exit 2; }
FAIL=0
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
ok()  { echo "  [PASS] $1"; }
run() { tr '\n' '\r' < "$FIX" | tr '\r' '\n' | awk -v idx="$1" -v n="$2" "$AWKSRC"; }

out1="$(run 1 1)"
[ -n "$out1" ] || { echo "CANNOT-RUN: aggregator produced no output on the fixture"; exit 2; }
bars1="$(printf '%s\n' "$out1" | awk -F'\t' '$1=="PCT"{print $2}')"
echo "  n=1 bars: $(echo $bars1)"
mx="$(printf '%s\n' $bars1 | sort -n | tail -1)"
[ "$mx" -le 99 ] && ok "never reaches 100 before success (max $mx)" || bad "bar reached $mx before success"
prev=-1; mono=1; dup=0
for b in $bars1; do [ "$b" -lt "$prev" ] && mono=0; [ "$b" -eq "$prev" ] && dup=1; prev=$b; done
[ $mono = 1 ] && ok "monotonic" || bad "bar went backwards"
[ $dup = 0 ] && ok "one line per overall-percent change (deduped)" || bad "repeated percent emitted"
# The frame the tester saw: small layer 100% while the big one is at 26%.
early="$(printf '%s\n' "$out1" | awk -F'\t' '$3 ~ /1\.5 GB of|2\.[0-9] GB of/ {print $2; exit}')"
[ -n "$early" ] && [ "$early" -lt 50 ] && ok "small layer at 100% with big layer at 26% reads ${early}%, not 100%" || bad "tester frame reads '${early:-none}', expected under 50"
# several models: the step bar is one bar across them
out2="$(run 2 2 | awk -F'\t' '$1=="PCT"{print $2}')"
mn="$(printf '%s\n' $out2 | sort -n | head -1)"; mx2="$(printf '%s\n' $out2 | sort -n | tail -1)"
{ [ "$mn" -ge 50 ] && [ "$mx2" -le 99 ]; } && ok "model 2 of 2 stays within 50..99 (${mn}..${mx2})" || bad "model 2 of 2 range ${mn}..${mx2}"
run 1 2 | grep -q 'Model 1 of 2' && ok "log text names 'Model 1 of 2'" || bad "no 'Model 1 of N' text"
run 1 1 | grep -q 'Model ' && bad "single model should not say 'Model 1 of 1'" || ok "single model has no 'Model' prefix"
echo "fail=$FAIL"; [ "$FAIL" -eq 0 ]
