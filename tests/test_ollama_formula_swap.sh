#!/usr/bin/env bash
#
# tests/test_ollama_formula_swap.sh
#
# CX-14 Section E1 (2026-05-23) + CX-43 (2026-06-02) regression test.
# Locks in the CURRENT Ollama installation contract.
#
# History (why this test looks the way it does):
#
# CX-14 E1 originally swapped the cask (`brew install --cask ollama`)
# to the FORMULA (`brew install ollama`) to dodge the Gatekeeper
# "downloaded from internet" dialog that fires on the .app's first
# GUI launch. This test used to pin the formula path.
#
# CX-43 (2026-06-02) then discovered the formula is functionally
# BROKEN for our models: formula ollama (0.30.0) ships ONLY an MLX
# runner and NO llama-server, so every GGUF model (nomic-embed-text,
# the qwen conversation models) returns HTTP 500. Embeddings die,
# Qdrant stays empty, People/semantic search/assistant all come up
# blank. The cask bundles llama-server (validated on the Studio:
# /api/embed -> 200, 768-dim). So install.sh went BACK to the cask
# (`brew install --cask ollama-app`) while honouring E1's actual
# goal (no mid-install dialog) by a different mechanism:
#   - never `open -a Ollama` (the GUI app launch is what triggers
#     the quarantine dialog); run the INNER CLI binary headless
#     (/Applications/Ollama.app/Contents/Resources/ollama serve)
#     under our own com.ostler.ollama LaunchAgent
#   - defensively strip the quarantine xattr from the bundle
#   - tear down any pre-existing broken FORMULA install (its
#     brew-services launchd respawns onto :11434 and shadows the
#     cask binary on PATH)
#
# This test walks the assembled install.sh asserting the CX-43
# contract, refusing the exact regression shapes on both sides:
#   - a swap BACK to the broken formula (silent blank-brain Hub)
#   - a GUI `open -a Ollama` launch (mid-install Gatekeeper dialog,
#     E1's original complaint)
#
# Per locked memory `feedback_silent_bail_regression_test_shape`:
# refuse the EXACT failure shape line-by-line rather than asserting
# a happy path that "probably works" on a permissive developer Mac.

set -euo pipefail

# Repo root is the directory containing install.sh. tests/ is the
# direct child, so the repo root is the parent of this script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"

if [ ! -f "$INSTALL_SH" ]; then
    echo "FAIL: ${INSTALL_SH} does not exist" >&2
    exit 1
fi

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

# ── 1. EXACTLY ONE cask invocation (ollama-app) ───────────────
# CX-43: the cask is the ONLY install path that ships llama-server.
# Match only EXECUTABLE invocations (start-of-line whitespace,
# possibly 'if ', then the brew call). Comments are fine.
cask_count=$(grep -cE '^\s*(if\s+)?brew install --cask ollama-app( |$)' "$INSTALL_SH" || true)
if [ "$cask_count" -ne 1 ]; then
    echo "Offending matches (expected 1, got $cask_count):" >&2
    grep -nE '^\s*(if\s+)?brew install --cask ollama-app( |$)' "$INSTALL_SH" >&2 || true
    fail "install.sh must have exactly ONE 'brew install --cask ollama-app' invocation (CX-43: the formula ships no llama-server; the cask is the only working install path). Got $cask_count."
fi

# ── 2. NO formula install ─────────────────────────────────────
# The formula's ollama (MLX runner only, no llama-server) cannot
# serve our GGUF models at all -- HTTP 500 on /api/embed, blank
# Hub. `brew uninstall --formula ollama` (teardown) is fine and
# required; `brew install ollama` (no --cask) is the regression.
if grep -nE '^\s*(if\s+)?brew install ollama( |$)' "$INSTALL_SH" > /dev/null; then
    echo "Offending lines:" >&2
    grep -nE '^\s*(if\s+)?brew install ollama( |$)' "$INSTALL_SH" >&2
    fail "install.sh contains a 'brew install ollama' FORMULA invocation. CX-43: the formula ships no llama-server, so embeddings/chat return HTTP 500 and the Hub comes up blank. Install the cask (ollama-app) and serve its inner binary headless. If you believe the formula is fixed upstream, talk to Andy first."
fi

# ── 3. Broken-formula teardown present ────────────────────────
# A pre-existing formula install shadows the cask binary on PATH
# and its brew-services launchd respawns it onto :11434 even after
# a pkill. install.sh must stop the service AND uninstall the
# formula before the cask goes in.
if ! grep -nE '^\s*brew uninstall --formula ollama' "$INSTALL_SH" > /dev/null; then
    fail "install.sh must tear down a pre-existing broken Ollama FORMULA ('brew uninstall --formula ollama') before installing the cask. Without it the formula's brew-services launchd respawns onto :11434 and shadows the cask binary (CX-43)."
fi

# ── 4. NO GUI app launch ('open -a Ollama') ───────────────────
# The GUI launch is what fires the Gatekeeper quarantine dialog
# mid-install -- E1's original complaint. The inner CLI binary is
# run headless instead.
if grep -nE '^\s*open .*-a Ollama' "$INSTALL_SH" > /dev/null; then
    echo "Offending lines:" >&2
    grep -nE '^\s*open .*-a Ollama' "$INSTALL_SH" >&2
    fail "install.sh contains an 'open -a Ollama' invocation. A GUI app launch triggers the Gatekeeper quarantine dialog mid-install (CX-14 E1). Run the cask's inner CLI binary headless under the com.ostler.ollama LaunchAgent instead."
fi

# ── 5. NO brew-services wire for ollama ───────────────────────
# 'brew services start ollama' only exists for the FORMULA; wiring
# it back would resurrect the broken-formula serve path. The cask
# is served by our own com.ostler.ollama LaunchAgent instead.
# (The teardown path's 'brew services stop ollama' is fine.)
if grep -nE '^\s*brew services start ollama' "$INSTALL_SH" > /dev/null; then
    echo "Offending lines:" >&2
    grep -nE '^\s*brew services start ollama' "$INSTALL_SH" >&2
    fail "install.sh contains 'brew services start ollama' -- that is the FORMULA's launch wire and would resurrect the broken no-llama-server serve path (CX-43). The cask's inner binary is served by the com.ostler.ollama LaunchAgent."
fi

# ── 6. Headless serve via inner binary + own LaunchAgent ──────
# The dialog-free serve mechanism: the cask's inner CLI binary
# (Contents/Resources/ollama) run as `serve` under our own
# com.ostler.ollama LaunchAgent.
if ! grep -nE 'OLLAMA_APP_BIN="/Applications/Ollama\.app/Contents/Resources/ollama"' "$INSTALL_SH" > /dev/null; then
    fail "install.sh must define OLLAMA_APP_BIN as the cask's inner CLI binary (/Applications/Ollama.app/Contents/Resources/ollama). Launching the inner binary headless is what avoids the Gatekeeper dialog (CX-43 honouring CX-14 E1)."
fi
if ! grep -nE 'com\.ostler\.ollama' "$INSTALL_SH" > /dev/null; then
    fail "install.sh must serve Ollama under the com.ostler.ollama LaunchAgent (persists across reboots, no GUI app launch, no Gatekeeper dialog)."
fi

# ── 7. Quarantine xattr strip ─────────────────────────────────
# Belt-and-braces: even a stricter Gatekeeper cannot block the
# exec once the quarantine xattr is stripped from the bundle.
if ! grep -nE 'xattr -dr com\.apple\.quarantine /Applications/Ollama\.app' "$INSTALL_SH" > /dev/null; then
    fail "install.sh must strip the quarantine xattr from /Applications/Ollama.app after the cask install ('xattr -dr com.apple.quarantine ...'). This is the belt-and-braces half of the no-dialog mechanism (CX-43)."
fi

# ── 8. Fail-loud post-install binary check ────────────────────
# DMG #48 silent-bail hardening: verify the cask binary exists
# before declaring success (not a bare `command -v`, which a
# leftover formula binary on PATH would satisfy).
if ! grep -nE 'ERR-07-DMG48-OLLAMA-MISSING-AFTER-BREW' "$INSTALL_SH" > /dev/null; then
    fail "install.sh must fail_with_code ERR-07-DMG48-OLLAMA-MISSING-AFTER-BREW when the cask binary is missing after brew install (silent-bail axis)."
fi

# ── 9. Port 11434 unchanged ───────────────────────────────────
# The wire contract with Hub agents, the embedding pipeline, the
# providers TOML, and the post-install health probes. If a future
# diff flips this it is almost certainly a copy-paste bug, not an
# intentional change.
if ! grep -nE 'localhost:11434/api/tags' "$INSTALL_SH" > /dev/null; then
    fail "install.sh no longer probes localhost:11434/api/tags. The Ollama port is part of the cross-component wire contract; the install-path history (E1 formula -> CX-43 cask) never changed the port. If a deliberate port change is required, audit Hub agents + embedding pipeline + providers TOML first."
fi

echo "PASS: tests/test_ollama_formula_swap.sh"
exit 0
