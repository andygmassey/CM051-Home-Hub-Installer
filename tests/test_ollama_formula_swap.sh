#!/usr/bin/env bash
#
# tests/test_ollama_formula_swap.sh
#
# Ollama install-path regression test. UPDATED 2026-07-07 to lock the
# CURRENT decision (ollama-app CASK, headless), superseding CX-14 E1.
#
# Decision history (both documented inline in install.sh Phase 3.3):
#
#   1. CX-14 E1 (2026-05-23): swapped the `ollama` cask to the FORMULA
#      to dodge the cask's Gatekeeper "downloaded from internet"
#      quarantine dialog on first GUI launch. This test originally
#      locked that formula path.
#
#   2. SUPERSEDED: the Homebrew `ollama` FORMULA stopped bundling
#      llama-server, so /api/embed returns 404 on every embedding call.
#      Every ingest pipeline dies, People/search/browsing come up blank
#      and the assistant is mute. The `ollama-app` CASK bundles
#      llama-server (validated on the Studio: /api/embed -> 200,
#      768-dim). E1's actual goal (no mid-install Gatekeeper dialog) is
#      honoured by a DIFFERENT mechanism: never `open -a Ollama` (the
#      GUI launch is what fires the dialog); instead run the cask's
#      inner CLI binary headless under a com.ostler.ollama LaunchAgent,
#      plus a defensive quarantine-xattr strip on the bundle.
#
# This test walks install.sh line-by-line asserting the CURRENT shape:
#   1. EXACTLY ONE `brew install --cask ollama-app` invocation.
#   2. NO `brew install ollama` FORMULA invocation (the formula cannot
#      serve embeddings; re-adding it = every pipeline silently dead).
#   3. NO `open -a Ollama` invocation (GUI launch fires the Gatekeeper
#      dialog E1 was written to avoid).
#   4. The quarantine xattr strip is present (belt-and-braces half of
#      the E1-goal mechanism).
#   5. The headless serve wire exists: the cask's inner binary path and
#      the com.ostler.ollama LaunchAgent (NOT `brew services start
#      ollama`, which is the formula wire).
#   6. The broken-formula teardown branch exists (a pre-existing
#      formula shadows the cask binary on PATH and respawns onto
#      :11434, so it must be uninstalled first).
#   7. The port number 11434 is UNCHANGED (wire contract with Hub
#      agents, embedding pipeline, providers TOML, health probes).
#
# Per locked memory `feedback_silent_bail_regression_test_shape`:
# refuse the EXACT failure shape (formula invocation OR open -a Ollama
# OR missing headless-serve wire OR drifted port).

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

# ── 1. EXACTLY ONE ollama-app cask invocation ────────────────
cask_count=$(grep -cE '^\s*brew install --cask ollama-app( |$)' "$INSTALL_SH" || true)
if [ "$cask_count" -ne 1 ]; then
    echo "Offending matches (expected 1, got $cask_count):" >&2
    grep -nE '^\s*brew install --cask ollama-app( |$)' "$INSTALL_SH" >&2 || true
    fail "install.sh must have exactly ONE 'brew install --cask ollama-app' invocation. The ollama-app cask is the only Homebrew artefact that bundles llama-server (embeddings); the formula does not."
fi

# ── 2. NO formula invocation ─────────────────────────────────
# Pattern: 'brew install ollama' with NO --cask. Comments are fine
# (the decision-history comment mentions the formula). The teardown
# `brew uninstall --formula ollama` is expected and does not match.
if grep -nE '^\s*(if\s+)?brew install ollama( |$)' "$INSTALL_SH" > /dev/null; then
    echo "Offending lines:" >&2
    grep -nE '^\s*(if\s+)?brew install ollama( |$)' "$INSTALL_SH" >&2
    fail "install.sh contains a 'brew install ollama' FORMULA invocation. The formula has no llama-server, so /api/embed 404s and every ingest pipeline silently dies (Studio-validated). If you need to re-add the formula, talk to Andy first."
fi

# ── 3. NO 'open -a Ollama' ───────────────────────────────────
# A GUI app launch is what fires the Gatekeeper quarantine dialog
# (CX-14 E1's real concern). The headless LaunchAgent wire replaces it.
if grep -nE '^\s*open .*-a Ollama' "$INSTALL_SH" > /dev/null; then
    echo "Offending lines:" >&2
    grep -nE '^\s*open .*-a Ollama' "$INSTALL_SH" >&2
    fail "install.sh contains an 'open -a Ollama' invocation. GUI-launching Ollama.app fires the Gatekeeper dialog mid-install (CX-14 E1). Serve headless via the com.ostler.ollama LaunchAgent instead."
fi

# ── 4. Quarantine xattr strip present ────────────────────────
if ! grep -qE 'xattr -dr com\.apple\.quarantine /Applications/Ollama\.app' "$INSTALL_SH"; then
    fail "install.sh must strip the quarantine xattr from /Applications/Ollama.app after the cask install (belt-and-braces half of the E1-goal mechanism)."
fi

# ── 5. Headless serve wire ───────────────────────────────────
# The cask's inner CLI binary, run under our own LaunchAgent.
if ! grep -q '/Applications/Ollama.app/Contents/Resources/ollama' "$INSTALL_SH"; then
    fail "install.sh no longer references the cask's inner CLI binary (/Applications/Ollama.app/Contents/Resources/ollama). That binary is the headless-serve path that avoids the GUI Gatekeeper dialog."
fi
if ! grep -q 'com.ostler.ollama' "$INSTALL_SH"; then
    fail "install.sh no longer wires the com.ostler.ollama LaunchAgent. Without it Ollama does not persist across reboots (the formula-era 'brew services start ollama' wire was removed with the formula)."
fi
# The formula-era wire must NOT come back: brew services would try to
# manage a formula that is no longer installed.
if grep -nE '^\s*brew services start ollama( |$)' "$INSTALL_SH" > /dev/null; then
    echo "Offending lines:" >&2
    grep -nE '^\s*brew services start ollama( |$)' "$INSTALL_SH" >&2
    fail "install.sh contains 'brew services start ollama' (the formula-era launch wire). The cask path serves headless via the com.ostler.ollama LaunchAgent."
fi

# ── 6. Broken-formula teardown branch ────────────────────────
if ! grep -qE '^\s*brew uninstall --formula ollama' "$INSTALL_SH"; then
    fail "install.sh must tear down a pre-existing broken ollama FORMULA (brew uninstall --formula ollama) before the cask install; the formula shadows the cask binary on PATH and its brew-services launchd respawns onto :11434."
fi

# ── 7. Port 11434 unchanged ──────────────────────────────────
# If a future install.sh diff flips this to 11435 or similar it is
# almost certainly a copy-paste bug, not an intentional change. Hub
# agents, embedding pipeline, providers TOML, and post-install
# health probes all hard-code 11434.
if ! grep -nE 'localhost:11434/api/tags' "$INSTALL_SH" > /dev/null; then
    fail "install.sh no longer probes localhost:11434/api/tags. The Ollama port is part of the cross-component wire contract. If a deliberate port change is required, audit Hub agents + embedding pipeline + providers TOML first."
fi

echo "PASS: tests/test_ollama_formula_swap.sh (ollama-app cask, headless serve, no formula)"
exit 0
