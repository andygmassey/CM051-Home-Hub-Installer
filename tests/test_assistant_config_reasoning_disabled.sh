#!/usr/bin/env bash
#
# tests/test_assistant_config_reasoning_disabled.sh
#
# Locks the assistant-config wiring that disables hidden
# chain-of-thought on every model (#600).
#
# Why this test exists:
#
#   The daemon's Ollama provider only force-disables `think` for
#   the gemma4:* family (effective_think() in
#   crates/zeroclaw-providers/src/ollama.rs returns Some(false) for
#   "gemma4:" tags). Every other model -- including the qwen3.5:9b
#   mid tier and the qwen3.6:35b-a3b high tier the installer picks
#   for 24GB+ / 48GB+ machines -- falls through to the operator
#   config, which defaults to None (provider default = thinking ON).
#
#   With thinking ON the assistant runs a long hidden reasoning
#   pass before every interactive reply (tens of seconds on the 9B
#   at the ~13 tok/s the Mac Mini benchmarks per HR015
#   BENCHMARKS_2026-04-21.md). install.sh must emit
#   `reasoning_enabled = false` under `[runtime]` so the daemon
#   sends `think: false` on every Ollama request.
#
#   This test pins that wiring:
#     1. The TOML emitter writes a [runtime] header
#     2. reasoning_enabled = false
#     3. Both are emitted unconditionally (top-level brace-block
#        indent), so a future channel-gating edit cannot silently
#        re-enable thinking when the user skips channel config.
#
# Sister tests:
#   - test_assistant_config_vane_wiring.sh -- locks the web_search wiring

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${REPO_ROOT}/install.sh"

if [[ ! -f "$INSTALL_SCRIPT" ]]; then
    echo "FAIL: install.sh not found at $INSTALL_SCRIPT" >&2
    exit 1
fi

if ! bash -n "$INSTALL_SCRIPT"; then
    echo "FAIL: install.sh fails bash -n parse check" >&2
    exit 1
fi
echo "PASS: install.sh parses"

# ── [runtime] header present ────────────────────────────────────
if ! grep -q 'echo "\[runtime\]"' "$INSTALL_SCRIPT"; then
    echo "FAIL [runtime-header]: install.sh does not emit a [runtime] header" >&2
    exit 1
fi
echo "PASS: install.sh emits [runtime] header"

# ── reasoning_enabled = false ───────────────────────────────────
if ! grep -q 'echo "reasoning_enabled = false"' "$INSTALL_SCRIPT"; then
    echo "FAIL [reasoning-disabled]: install.sh does not set reasoning_enabled = false" >&2
    exit 1
fi
echo "PASS: install.sh sets reasoning_enabled = false"

# ── Both lines emitted unconditionally ──────────────────────────
# The TOML emitter is the body of `{ ... } > "$ASSISTANT_CONFIG"`.
# Top-level statements inside the brace block are indented exactly
# 4 spaces; anything nested inside an `if [[ ... ]]; then` is 8+.
# A future edit that wrapped [runtime] in a channel-gated if would
# silently re-enable thinking whenever the user skipped channels.
for needle in 'echo "\[runtime\]"' 'echo "reasoning_enabled = false"'; do
    INDENT="$(grep -nE "^[[:space:]]+${needle}\$" "$INSTALL_SCRIPT" \
        | head -n 1 | sed -E 's/^[0-9]+:( +).*/\1/' | awk '{ print length }')"
    if [[ -z "$INDENT" ]]; then
        echo "FAIL [emitter-missing]: could not locate '${needle}'" >&2
        exit 1
    fi
    if [[ "$INDENT" -ne 4 ]]; then
        echo "FAIL [runtime-conditional]: '${needle}' is indented ${INDENT} spaces (expected 4)" >&2
        echo "      The [runtime] reasoning override must be emitted at the top level" >&2
        echo "      of the brace block, not inside a channel-gated if." >&2
        exit 1
    fi
done
echo "PASS: [runtime] reasoning_enabled block is emitted unconditionally (top-level indent)"

# ── Ordering: [runtime] after the ollama model, before channels ─
# Not strictly required by TOML, but keeps the generated config
# readable and groups the model + its runtime knobs together.
RUNTIME_LINE="$(grep -nE '^[[:space:]]+echo "\[runtime\]"$' "$INSTALL_SCRIPT" | head -n 1 | cut -d: -f1)"
OLLAMA_LINE="$(grep -nE '^[[:space:]]+echo "\[providers\.models\.ollama\]"$' "$INSTALL_SCRIPT" | head -n 1 | cut -d: -f1)"
if [[ -n "$RUNTIME_LINE" && -n "$OLLAMA_LINE" && "$RUNTIME_LINE" -le "$OLLAMA_LINE" ]]; then
    echo "FAIL [ordering]: [runtime] block emitted before [providers.models.ollama]" >&2
    exit 1
fi
echo "PASS: [runtime] block emitted after the ollama model block"

echo ""
echo "ALL ASSISTANT-CONFIG REASONING-DISABLED TESTS PASSED"
