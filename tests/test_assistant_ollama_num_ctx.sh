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
