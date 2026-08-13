#!/usr/bin/env bash
#
# tests/test_ollama_formula_swap.sh
#
# Locks the Ollama install path: the `ollama-app` CASK, served headless
# under our own LaunchAgent.
#
# THE HISTORY MATTERS, BECAUSE THIS TEST HAS ALREADY BEEN WRONG ONCE.
#
# CX-14 E1 (2026-05-23) swapped cask -> formula to dodge the Gatekeeper
# "downloaded from internet" dialog that Ollama.app shows on first GUI
# launch. This file was written to lock that swap in.
#
# That swap was later REVERSED, deliberately, and this file was not
# updated. The formula cannot serve our models at all: it does not bundle
# llama-server, so /api/embed fails, and with it the iOS People tab,
# semantic search, browsing, and the assistant's voice. That is a hard
# blocker, not a preference. The cask bundles llama-server (validated on
# the Studio: /api/embed -> 200, 768-dim).
#
# E1's ACTUAL goal was "no mid-install dialog", and install.sh now meets it
# by a different mechanism rather than by accepting a broken engine:
#
#   1. We never `open -a Ollama`. A GUI launch is what fires the
#      app-launch quarantine dialog. We run the cask's INNER CLI binary
#      headless -- /Applications/Ollama.app/Contents/Resources/ollama
#      serve -- under our own com.ostler.ollama LaunchAgent. Launching the
#      inner binary never fires the dialog (Studio: no prompt, embed 200).
#   2. We strip the quarantine xattr from the bundle after install, so
#      even a stricter Gatekeeper cannot block the exec.
#   3. We do NOT use `brew services`. That is the formula's persistence
#      mechanism; the cask is persisted by com.ostler.ollama instead.
#
# Net: no mid-install dialog (E1's real concern) AND a working
# llama-server (the bug E1 did not know about). Do not "restore" the
# formula on the strength of E1's comment alone -- read this block first.
#
# v1018-D675 -- WHY THIS FILE CHANGED. It had never run. When finally
# executed it failed against CORRECT shipped code, and the cause was a
# predicate with no right-hand boundary:
#
#     grep -E '^\s*(if\s+)?brew install --cask ollama'
#
# `brew install --cask ollama-app` STARTS WITH that string, so the guard
# forbidding the bare `ollama` cask also matched the `ollama-app` cask we
# deliberately ship. A prefix match reported a violation that did not
# exist. The bare-cask ban is still right and is kept -- it is now
# asserted on the exact token with a boundary on both sides, and the
# permitted `ollama-app` form is asserted POSITIVELY so the two can never
# be confused again.
#
# Checks 2 and 4 were not false positives; they were simply asserting the
# abandoned formula design (exactly one `brew install ollama`, at least
# one `brew services start ollama`). Both are now inverted to match the
# shipped design, with the reasoning above recorded so the next reader
# does not re-litigate it.
#
# Check 3 was audited during that pass and left alone: `^\s*open` cannot
# match the two comment lines that mention `open -a Ollama`, so it is
# comment-safe already. Verified, not assumed.

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

failures=0
fail() { echo "FAIL: $1" >&2; failures=$((failures + 1)); }
ok()   { echo "ok: $1"; }

# ── 1a. NO bare `--cask ollama` ───────────────────────────────
# The bare cask is the GUI-app cask whose first launch fires the
# Gatekeeper dialog E1 was right to avoid. `ollama-app` is a DIFFERENT
# cask token and is the one we ship.
#
# The boundary is the whole point of this check. `ollama` followed by
# `-app` must NOT match, so the token must end at whitespace or
# end-of-line -- never a bare prefix.
if grep -nE '^[[:space:]]*(if[[:space:]]+)?brew install --cask ollama([[:space:]]|$)' "$INSTALL_SH" > /dev/null; then
    echo "Offending lines:" >&2
    grep -nE '^[[:space:]]*(if[[:space:]]+)?brew install --cask ollama([[:space:]]|$)' "$INSTALL_SH" >&2
    fail "install.sh installs the BARE 'ollama' cask. That is the GUI app whose first launch fires the Gatekeeper quarantine dialog mid-install. Ship '--cask ollama-app' and serve its inner binary headless. Talk to Andy before changing this."
else
    ok "no bare '--cask ollama' invocation"
fi

# ── 1b. The ollama-app cask IS installed, exactly once ────────
# Asserted positively so a future rewrite cannot satisfy 1a by removing
# the Ollama install altogether.
cask_count=$(grep -cE '^[[:space:]]*brew install --cask ollama-app([[:space:]]|$)' "$INSTALL_SH" || true)
if [ "$cask_count" -ne 1 ]; then
    echo "Offending matches (expected 1, got $cask_count):" >&2
    grep -nE '^[[:space:]]*brew install --cask ollama-app([[:space:]]|$)' "$INSTALL_SH" >&2 || true
    fail "install.sh must install the 'ollama-app' cask exactly once. Got $cask_count. The cask is REQUIRED: it bundles llama-server, and the formula cannot serve our models at all."
else
    ok "installs '--cask ollama-app' exactly once"
fi

# ── 2. NO formula install ─────────────────────────────────────
# Inverted from the original "exactly one formula install". The formula
# is a hard blocker: no llama-server, so /api/embed fails and every
# downstream retrieval surface goes blank.
if grep -nE '^[[:space:]]*brew install ollama([[:space:]]|$)' "$INSTALL_SH" > /dev/null; then
    echo "Offending lines:" >&2
    grep -nE '^[[:space:]]*brew install ollama([[:space:]]|$)' "$INSTALL_SH" >&2
    fail "install.sh installs the Ollama FORMULA. The formula does not bundle llama-server, so /api/embed fails and the People tab, semantic search, browsing and the assistant all go blank. Use '--cask ollama-app'."
else
    ok "no Ollama formula install"
fi

# ── 2b. The broken formula is torn down if present ────────────
# A pre-existing formula shadows the cask binary on PATH and its
# brew-services launchd respawns it onto :11434 even after a pkill, so
# install.sh must remove it before the cask goes in.
if ! grep -qE '^[[:space:]]*brew uninstall --formula ollama' "$INSTALL_SH"; then
    fail "install.sh does not uninstall a pre-existing Ollama FORMULA. It shadows the cask binary on PATH and brew-services respawns it onto :11434, so the cask never serves."
else
    ok "tears down a pre-existing broken formula"
fi

# ── 3. NO 'open -a Ollama' ────────────────────────────────────
# A GUI launch is exactly what fires the app-launch quarantine dialog.
# `^\s*open` cannot match the comment lines that mention this, so no
# comment-stripping is needed here (verified, not assumed).
if grep -nE '^[[:space:]]*open .*-a Ollama' "$INSTALL_SH" > /dev/null; then
    echo "Offending lines:" >&2
    grep -nE '^[[:space:]]*open .*-a Ollama' "$INSTALL_SH" >&2
    fail "install.sh contains an 'open -a Ollama' invocation. A GUI launch fires the Gatekeeper app-launch dialog mid-install, which is the whole reason we serve the inner CLI binary headless instead."
else
    ok "never GUI-launches Ollama.app"
fi

# ── 4. Persistence is our LaunchAgent, NOT brew services ──────
# Inverted from the original "at least one brew services start ollama".
# brew-services is the FORMULA's persistence mechanism. The cask is
# persisted by com.ostler.ollama running the inner binary.
#
# Note `brew services stop ollama` IS expected (it tears down the broken
# formula at 2b), so this asserts on `start` specifically.
if grep -nE '^[[:space:]]*brew services start ollama' "$INSTALL_SH" > /dev/null; then
    echo "Offending lines:" >&2
    grep -nE '^[[:space:]]*brew services start ollama' "$INSTALL_SH" >&2
    fail "install.sh wires 'brew services start ollama'. That is the FORMULA's persistence mechanism and it would respawn the broken formula onto :11434. The cask is persisted by the com.ostler.ollama LaunchAgent."
else
    ok "does not use brew-services for persistence"
fi

if ! grep -q 'com.ostler.ollama' "$INSTALL_SH"; then
    fail "install.sh does not reference the com.ostler.ollama LaunchAgent. Without it nothing serves Ollama across reboots, and check 4 above would pass on an install that simply never starts it."
else
    ok "persists Ollama via the com.ostler.ollama LaunchAgent"
fi

# The LaunchAgent must run the cask's INNER binary. Pointing it at a bare
# `ollama` on PATH would resolve to a shadowing formula if one survives.
if ! grep -q 'Ollama.app/Contents/Resources/ollama' "$INSTALL_SH"; then
    fail "install.sh does not reference the cask's inner binary (Ollama.app/Contents/Resources/ollama). Serving a bare 'ollama' from PATH can resolve to a shadowing formula."
else
    ok "serves the cask's inner binary explicitly"
fi

# ── 5. Port 11434 unchanged ───────────────────────────────────
# The wire contract with Hub agents, the embedding pipeline, the
# providers TOML and the post-install health probes.
if ! grep -nE 'localhost:11434/api/tags' "$INSTALL_SH" > /dev/null; then
    fail "install.sh no longer probes localhost:11434/api/tags. The Ollama port is part of the cross-component wire contract; audit Hub agents + embedding pipeline + providers TOML before changing it."
else
    ok "still probes localhost:11434/api/tags"
fi

echo ""
if [ "$failures" -eq 0 ]; then
    echo "PASS: tests/test_ollama_formula_swap.sh"
    exit 0
fi
echo "FAIL: ${failures} Ollama install-path violation(s)." >&2
exit 1
