#!/usr/bin/env bash
# F&F 2026-11-05 item 4. `ollama pull` reports a percent PER LAYER; the old
# wrapper emitted it as the step bar, so the bar reset per layer and sat at 100%
# whenever a small layer finished while the big one ran on. The aggregator
# (ollama_pull_progress in lib/progress_emitter.sh) must give ONE overall bar: summed bytes,
# capped at 99 until success, monotonic, one line per change.
# Usage: tests/test_model_pull_progress_is_one_overall_bar.sh [lib/progress_emitter.sh]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${1:-${HERE}/../lib/progress_emitter.sh}"
FIX="${HERE}/fixtures/ollama_pull_multilayer.stream"
[ -f "$LIB" ] && [ -f "$FIX" ] || { echo "CANNOT-RUN: lib or fixture missing"; exit 2; }
# the REAL function, sourced from the shipped helper
# shellcheck disable=SC1090
. "$LIB" 2>/dev/null
type ollama_pull_progress >/dev/null 2>&1 || { echo "CANNOT-RUN: ollama_pull_progress not defined by $LIB"; exit 2; }
FAIL=0
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
ok()  { echo "  [PASS] $1"; }
run() { tr '\n' '\r' < "$FIX" | tr '\r' '\n' | ollama_pull_progress "$1" "$2"; }

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

# END TO END through the REAL _gui_ollama_pull (lifted from install.sh) with a stub
# engine that replays the fixture: 100 appears only AFTER a successful exit.
INS="${HERE}/../install.sh"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
awk '/^_gui_ollama_pull\(\) \{/{f=1} f{print} f&&/^}$/{exit}' "$INS" > "$W/fn.sh"
[ -s "$W/fn.sh" ] || { echo "CANNOT-RUN: could not lift _gui_ollama_pull"; exit 2; }
grep -q 'ollama_pull_progress "\$idx" "\$n"' "$W/fn.sh" && ok "_gui_ollama_pull calls the aggregator (wired)" || bad "_gui_ollama_pull does not call ollama_pull_progress (unwired)"
printf '#!/bin/sh\ncat "%s"\nexit "${STUB_RC:-0}"\n' "$FIX" > "$W/ollama"; chmod +x "$W/ollama"
# install.sh is macOS-only and calls BSD `mktemp -t <prefix>`; GNU mktemp (Linux CI) refuses a
# -t prefix with no XXX, the rc file is then empty and a SUCCESSFUL pull reads as rc 1. Shim it
# to the BSD meaning (same shim as test_a_retried_model_pull_emits_no_fatal_done.sh).
printf '#!/bin/sh\nif [ "${1:-}" = "-t" ]; then exec /usr/bin/mktemp "${TMPDIR:-/tmp}/${2:-tmp}.XXXXXX"; fi\nexec /usr/bin/mktemp "$@"\n' > "$W/mktemp"; chmod +x "$W/mktemp"
e2e() { # $1 = stub rc
  ( set +u; PATH="$W:$PATH"; . "$LIB" 2>/dev/null; . "$W/fn.sh"
    export OSTLER_GUI=1 OLLAMA_APP_BIN="$W/ollama" STUB_RC="$1"
    gui_emit() { shift; printf '%s\n' "$*"; }; gui_log() { :; }
    OSTLER_PULL_IDX=0; OSTLER_PULL_N=1; _gui_ollama_pull modelx ai_models; echo "rc=$?" ) 2>/dev/null
}
okout="$(e2e 0)"; badout="$(e2e 1)"
printf '%s\n' "$okout" | grep -q '^rc=0' && ok "success run returns rc 0" || bad "success run did not return rc 0 (harness)"
last="$(printf '%s\n' "$okout" | grep 'pct=' | tail -1)"
[ "$last" = "step=ai_models pct=100" ] && ok "success: bar ends at 100 only after rc 0" || bad "success run ended '$last'"
printf '%s\n' "$okout" | grep 'pct=' | sed '$d' | grep -q 'pct=100' && bad "100 emitted before success" || ok "no 100 before the exit status"
printf '%s\n' "$badout" | grep -q 'pct=100' && bad "failed pull still reached 100" || ok "failed pull (rc 1) never reaches 100"
printf '%s\n' "$badout" | grep -q '^rc=1' && ok "failure rc preserved" || bad "rc not preserved"
echo "fail=$FAIL"; [ "$FAIL" -eq 0 ]
