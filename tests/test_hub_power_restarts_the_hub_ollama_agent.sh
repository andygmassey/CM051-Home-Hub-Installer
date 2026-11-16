#!/usr/bin/env bash
# tests/test_hub_power_restarts_the_hub_ollama_agent.sh
#
# NEW-119. hub-power's restart-engine action (hpa_ollama_start, run on wake
# and on return to AC) matched `com.ostler.ollama|ai.ollama` in `launchctl
# list` and then ALWAYS kickstarted gui/<uid>/ai.ollama. The Hub's agent is
# com.ostler.ollama (install.sh writes it); ai.ollama is never installed by
# us, so on every Hub the kickstart failed and `|| true` hid it.
#
# Runs the REAL vendor/hub_power library (not DRY_RUN, so the real kickstart
# line executes) under env -i with stubs FIRST on PATH: `launchctl` lists
# com.ostler.ollama and records every argv; `pgrep` reports no serve process
# (so a real ollama on this machine cannot short-circuit the arm). The engine
# binary is a fake at the path the LaunchAgent plist names.
#
#   A  kickstart targets gui/<uid>/com.ostler.ollama          (RED on main: ai.ollama)
#   B  control: with NO Hub agent loaded (only ai.ollama, a customer's own
#      Ollama.app) nothing is kickstarted; the pinned engine is spawned.
#   M  mutant: the label put back to ai.ollama must turn A RED.
#
# HUB_POWER_ACTIONS=<path> runs it against another copy (e.g. origin/main's).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HP="$ROOT/vendor/hub_power/bin"
LIB="${HUB_POWER_ACTIONS:-$HP/hub-power-actions.sh}"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
fails=0
pass(){ echo "ok    $*"; }
bad(){ echo "FAIL  $*"; fails=$((fails+1)); }
[ -f "$LIB" ] && [ -f "$HP/hub-power-state.sh" ] || { echo "CANNOT-RUN: hub_power library not found"; exit 2; }

# run <lib> <listed-label> -> prints the recorded launchctl argv and engine argv
run() {
    local lib="$1" listed="$2" d; d="$(mktemp -d "$W/r.XXXXXX")"
    mkdir -p "$d/stub" "$d/hm/.ostler/runtime/ollama-x" "$d/hm/Library/LaunchAgents" "$d/lib"
    cp "$lib" "$d/lib/hub-power-actions.sh"; cp "$HP/hub-power-state.sh" "$d/lib/"
    printf '%s\n' '#!/bin/sh' "echo \"\$*\" >> \"$d/launchctl.argv\"" \
        "if [ \"\$1\" = list ]; then printf 'PID\tStatus\tLabel\n123\t0\t%s\n' '$listed'; fi" 'exit 0' > "$d/stub/launchctl"
    printf '%s\n' '#!/bin/sh' 'exit 1' > "$d/stub/pgrep"
    local fake="$d/hm/.ostler/runtime/ollama-x/ollama"
    printf '%s\n' '#!/bin/sh' "echo \"\$*\" >> \"$d/engine.argv\"" 'exit 0' > "$fake"
    chmod +x "$d/stub/launchctl" "$d/stub/pgrep" "$fake"
    printf '<plist><dict><key>ProgramArguments</key><array>\n<string>%s</string>\n<string>serve</string>\n</array></dict></plist>\n' "$fake" \
        > "$d/hm/Library/LaunchAgents/com.ostler.ollama.plist"
    : > "$d/hm/.ostler/hub-power.log"
    env -i PATH="$d/stub:/usr/bin:/bin" HOME="$d/hm" L="$d/lib" \
        HPA_OLLAMA_HEALTH_ATTEMPTS=1 HPA_OLLAMA_HEALTH_URL="http://127.0.0.1:9/none" \
        /bin/bash -c '. "$L/hub-power-actions.sh"; sleep(){ :; }; hpa_ollama_start; wait' > "$d/out" 2>&1
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$d/engine.argv" ] && break; /bin/sleep 0.2; done   # the spawn arm backgrounds the fake engine
    [ -n "${DEBUG:-}" ] && { cat "$d/out" "$d/hm/.ostler/hub-power.log" >&2; }
    echo "KICK $(grep '^kickstart' "$d/launchctl.argv" 2>/dev/null | tr '\n' ';')"
    echo "ENGINE $([ -f "$d/engine.argv" ] && tr '\n' ';' < "$d/engine.argv")"
}

uid="$(id -u)"
r="$(run "$LIB" com.ostler.ollama)"
if grep -qx "KICK kickstart -k gui/$uid/com.ostler.ollama;" <<<"$r"; then
    pass "A Hub agent loaded: kickstart targets gui/$uid/com.ostler.ollama"
else bad "A Hub agent loaded: $(tr '\n' ' ' <<<"$r") (want kickstart -k gui/$uid/com.ostler.ollama)"; fi

r="$(run "$LIB" ai.ollama)"
if grep -qx 'KICK ' <<<"$r" && grep -qx 'ENGINE serve;' <<<"$r"; then
    pass "B control, only a customer's ai.ollama loaded: nothing kickstarted, pinned engine spawned"
else bad "B control: $(tr '\n' ' ' <<<"$r") (want no kickstart, ENGINE serve)"; fi

if [ -z "${HUB_POWER_ACTIONS:-}" ] && [ "$fails" -eq 0 ]; then
    sed 's|"gui/$(id -u)/$HPA_OLLAMA_LABEL"|"gui/$(id -u)/ai.ollama"|' "$LIB" > "$W/mut.sh"
    if cmp -s "$LIB" "$W/mut.sh"; then bad "M mutant did not apply (kickstart line moved): CANNOT-RUN"
    else
        r="$(run "$W/mut.sh" com.ostler.ollama)"
        if ! grep -qx "KICK kickstart -k gui/$uid/com.ostler.ollama;" <<<"$r"; then pass "M label put back to ai.ollama is caught: $(head -1 <<<"$r")"
        else bad "M mutant not caught: $r"; fi
    fi
fi

if [ "$fails" -gt 0 ]; then echo "RED: $fails failure(s)"; exit 1; fi
echo "GREEN"
