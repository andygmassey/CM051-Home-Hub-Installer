#!/usr/bin/env bash
#
# tests/test_ollama_formula_swap.sh
#
# CX-14 Section E1 (2026-05-23) regression test. Locks in the
# Ollama installation path swap: `brew install --cask ollama`
# (cask, triggers Gatekeeper dialog mid-install) -> `brew install
# ollama` (formula, no .app to quarantine, no dialog).
#
# Why this test exists:
#
# The cask path installs Ollama.app, whose first launch shows a
# Gatekeeper "downloaded from internet" dialog. Mid-install the
# customer either fights through it or ignores it; in the second
# case the install.sh `open -a Ollama` call returns 0 (it
# successfully spawned the dialog) but Ollama is NOT actually
# serving on :11434. The downstream `curl http://localhost:11434
# /api/tags` polling then times out at 90 seconds and the install
# bails with "could not start Ollama automatically".
#
# The formula path installs `ollama` as a CLI binary. No .app to
# quarantine, no Gatekeeper. `brew services start ollama` wires
# the persistent launchd plist (formula equivalent of the cask's
# built-in LaunchAgent).
#
# This test walks install.sh line-by-line asserting:
#   1. NO `brew install --cask ollama` invocation anywhere
#      (the silent-bail axis: a cask invocation = Gatekeeper
#       dialog = silent denial path on customer install)
#   2. EXACTLY ONE `brew install ollama` invocation (the formula
#      path) in Phase 3.3
#   3. NO `open -a Ollama` invocation (no .app to launch in the
#      formula path; using `open -a` returns "application not
#      found" silently in customer install logs)
#   4. AT LEAST ONE `brew services start ollama` invocation as
#      the formula's persistent-launch wire
#   5. The port number 11434 is UNCHANGED (the wire contract
#      with Hub agents, the embedding pipeline, the providers
#      TOML, and the post-install health probes -- if anything
#      ever flips this it should be a deliberate breaking change,
#      not a side effect of the install path swap)
#
# Per locked memory `feedback_silent_bail_regression_test_shape`:
# walk the assembled install.sh line-by-line refusing the EXACT
# failure shape (cask invocation OR open -a Ollama OR missing
# brew-services wire OR drifted port). A happy-path "does install
# work" test would not catch a regression that swaps the formula
# back to the cask because the cask probably still "works" on a
# developer Mac where Gatekeeper is more permissive.

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

# ── 1. NO cask invocation ─────────────────────────────────────
# Pattern: 'brew install --cask ollama' anywhere in install.sh.
# Comments are fine (they explain why we don't use the cask).
# Match only EXECUTABLE invocations (start-of-line whitespace,
# possibly 'if ', then `brew install --cask ollama`).
if grep -nE '^\s*(if\s+)?brew install --cask ollama' "$INSTALL_SH" > /dev/null; then
    echo "Offending lines:" >&2
    grep -nE '^\s*(if\s+)?brew install --cask ollama' "$INSTALL_SH" >&2
    fail "install.sh contains a 'brew install --cask ollama' invocation. CX-14 E1 swapped this to the formula path (brew install ollama) because the cask triggers a Gatekeeper dialog mid-install. If you need to re-add the cask, talk to Andy first."
fi

# ── 2. EXACTLY ONE formula invocation ─────────────────────────
# Pattern: 'brew install ollama' (no --cask).
# Comments are fine (the cask-removal comment mentions the
# formula too).
formula_count=$(grep -cE '^\s*brew install ollama( |$)' "$INSTALL_SH" || true)
if [ "$formula_count" -ne 1 ]; then
    echo "Offending matches (expected 1, got $formula_count):" >&2
    grep -nE '^\s*brew install ollama( |$)' "$INSTALL_SH" >&2 || true
    fail "install.sh must have exactly ONE 'brew install ollama' invocation (formula path). Got $formula_count. CX-14 E1 collapsed the cask + formula fallback branch into a single formula install."
fi

# ── 3. NO 'open -a Ollama' ────────────────────────────────────
# The formula path has no Ollama.app, so 'open -a Ollama'
# returns "application not found" silently in customer logs.
if grep -nE '^\s*open .*-a Ollama' "$INSTALL_SH" > /dev/null; then
    echo "Offending lines:" >&2
    grep -nE '^\s*open .*-a Ollama' "$INSTALL_SH" >&2
    fail "install.sh contains an 'open -a Ollama' invocation. The formula path (CX-14 E1) has no Ollama.app to launch; use 'brew services start ollama' to wire the persistent launchd plist instead."
fi

# ── 4. AT LEAST ONE 'brew services start ollama' ──────────────
# The formula's persistent-launch wire. Cask used to do this via
# the .app's built-in LaunchAgent; formula needs the explicit
# brew-services wire.
if ! grep -nE '^\s*brew services start ollama' "$INSTALL_SH" > /dev/null; then
    fail "install.sh must wire 'brew services start ollama' so the launchd plist persists across reboots. The cask used to do this via the .app's built-in LaunchAgent; the formula needs the explicit brew-services wire (CX-14 E1)."
fi

# ── 5. Port 11434 unchanged ───────────────────────────────────
# The cask and the formula serve on the same port; if a future
# install.sh diff flips this to 11435 or similar it is almost
# certainly a copy-paste bug, not an intentional change. Hub
# agents, embedding pipeline, providers TOML, and post-install
# health probes all hard-code 11434.
if ! grep -nE 'localhost:11434/api/tags' "$INSTALL_SH" > /dev/null; then
    fail "install.sh no longer probes localhost:11434/api/tags. The Ollama port is part of the cross-component wire contract; CX-14 E1 swapped the install path but did NOT change the port. If a deliberate port change is required, audit Hub agents + embedding pipeline + providers TOML first."
fi

echo "PASS: tests/test_ollama_formula_swap.sh"
exit 0
