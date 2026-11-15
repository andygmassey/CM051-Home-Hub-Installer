#!/usr/bin/env bash
# test_assistant_ollama_num_ctx.sh -- v1.0.0 .153 cold-wipe walk, blocker B1.
#
# The daemon's agent system prompt is ~7,000 tokens. Ollama defaults the
# context window to 4096, so without OLLAMA_NUM_CTX set the prompt is
# silently truncated and qwen returns an EMPTY completion -- which the
# gateway surfaces to the user as "500 Internal Server Error / {error: EOF}".
# Every real chat failed on a fresh install because nothing set the env var.
#
# Fix: the assistant LaunchAgent plist now carries OLLAMA_NUM_CTX=32768 (and
# OLLAMA_KEEP_ALIVE) as fixed product constants in EnvironmentVariables.
# Proven live on the .153 box: at ctx 4096 the real agent prompt returns
# empty; at 32768 it returns a real reply.
#
# This test fails loudly if a future edit drops the keys, weakens the value
# below the prompt size, or breaks plist validity. It also confirms the keys
# survive INSTALL_SNIPPET's SELF_HANDLES sed render unchanged.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST="${HERE}/../assistant-agent/launchd/com.creativemachines.ostler.assistant.plist"
SNIPPET="${HERE}/../assistant-agent/INSTALL_SNIPPET.sh"
PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "== structural: plist carries the chat-context env =="
plutil -lint "$PLIST" >/dev/null 2>&1 \
    && ok "plist is valid (plutil -lint)" \
    || bad "plist failed plutil -lint"

NUMCTX="$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:OLLAMA_NUM_CTX' "$PLIST" 2>/dev/null)"
[[ "$NUMCTX" == "32768" ]] \
    && ok "OLLAMA_NUM_CTX = 32768 in EnvironmentVariables" \
    || bad "OLLAMA_NUM_CTX missing/wrong (got '${NUMCTX:-<unset>}')"

# Guard the floor: the agent prompt is ~7k tokens; anything <= 8192 risks
# truncating it back to an empty completion. Keep a generous margin.
if [[ "$NUMCTX" =~ ^[0-9]+$ ]] && (( NUMCTX >= 16384 )); then
    ok "OLLAMA_NUM_CTX comfortably exceeds the ~7k-token agent prompt"
else
    bad "OLLAMA_NUM_CTX too small for the agent prompt (got '${NUMCTX:-<unset>}')"
fi

KEEPALIVE="$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:OLLAMA_KEEP_ALIVE' "$PLIST" 2>/dev/null)"
[[ -n "$KEEPALIVE" ]] \
    && ok "OLLAMA_KEEP_ALIVE present (${KEEPALIVE}) -- model stays warm between turns" \
    || bad "OLLAMA_KEEP_ALIVE missing"

echo "== keep-alive: an IDLE window with a unit, so the model can be freed =="
# Walk #19: 30m let the chat model expire, and the cold reload starved chat.
# 2026-11-13 (F&F tester): -1m pinned a 7 GB model forever, so Pause could not
# free it. The daemon now asks for a 15m idle window: long enough that a
# conversation stays warm, short enough that an idle Mac frees the model. The
# daemon sends the value as a JSON STRING; Ollama parses it with Go's
# time.ParseDuration, which rejects a bare "-1" or "15" (missing unit). So the
# value must be a POSITIVE duration WITH a unit, and never forever.
is_idle_duration() { [[ "$1" =~ ^[1-9][0-9]*(s|m|h)$ ]]; }
# Predicate controls: forever and the unit-less trap must be rejected.
is_idle_duration "-1m" && bad "predicate accepts -1m (pins forever)" || ok "predicate rejects -1m (pins the model forever)"
is_idle_duration "-1"  && bad "predicate accepts bare -1" || ok "predicate rejects bare -1 (Ollama 400: missing unit)"
is_idle_duration "15"  && bad "predicate accepts 15 with no unit" || ok "predicate rejects 15 with no unit"
is_idle_duration "15m" && ok "predicate accepts 15m" || bad "predicate rejects 15m"
is_idle_duration "$KEEPALIVE" \
    && ok "OLLAMA_KEEP_ALIVE=${KEEPALIVE}: an idle window, with a unit" \
    || bad "OLLAMA_KEEP_ALIVE must be a positive idle duration with a unit (e.g. 15m); got '${KEEPALIVE:-<unset>}'"
grep -A1 '<key>OLLAMA_KEEP_ALIVE</key>' "${HERE}/../install.sh" | grep -q '<string>-1</string>' \
    && ok "the Ollama server is started with OLLAMA_KEEP_ALIVE=-1 (the value the daemon matches)" \
    || bad "install.sh no longer starts Ollama with OLLAMA_KEEP_ALIVE=-1; re-check what the daemon should match"

echo "== render-safety: keys survive INSTALL_SNIPPET's SELF_HANDLES sed =="
# Reproduce the snippet's substitution (the only sed that touches the plist)
# and confirm it does not disturb the OLLAMA_* keys.
esc_self_handles='+15550000000,user@example.com'
RENDERED="$(mktemp)"; trap 'rm -f "$RENDERED"' EXIT
sed -e "s/OSTLER_IMESSAGE_SELF_HANDLES_VALUE/$esc_self_handles/g" "$PLIST" > "$RENDERED"
plutil -lint "$RENDERED" >/dev/null 2>&1 \
    && [[ "$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:OLLAMA_NUM_CTX' "$RENDERED" 2>/dev/null)" == "32768" ]] \
    && ok "rendered plist still valid and retains OLLAMA_NUM_CTX=32768" \
    || bad "render clobbered the OLLAMA_NUM_CTX key or broke the plist"

# Belt: the snippet must not redefine OLLAMA_NUM_CTX to something smaller.
if grep -qE 'OLLAMA_NUM_CTX' "$SNIPPET" 2>/dev/null; then
    grep -qE 'OLLAMA_NUM_CTX[^0-9]*(3276[0-9]|[4-9][0-9]{4,})' "$SNIPPET" \
        && ok "INSTALL_SNIPPET (if it sets OLLAMA_NUM_CTX) keeps it large" \
        || bad "INSTALL_SNIPPET sets OLLAMA_NUM_CTX to a small/unknown value"
else
    ok "INSTALL_SNIPPET does not override OLLAMA_NUM_CTX (plist constant wins)"
fi

echo ""
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
