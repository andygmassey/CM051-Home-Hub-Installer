#!/usr/bin/env bash
#
# tests/test_ollama_install_path_contract.sh
#   (was tests/test_ollama_formula_swap.sh until 2026-08-15)
#
# Locks the Ollama install path against the failure CX-14 E1 was about: a
# Gatekeeper dialog mid-install that the customer ignores, after which the
# install "succeeds" while Ollama is not serving on :11434.
#
# WHY THIS FILE WAS REWRITTEN, AND WHY THE OLD ONE WAS NOT A DEFECT REPORT
# -----------------------------------------------------------------------
# The previous version forbade the cask outright and required the formula:
#
#     1  NO  brew install --cask ollama
#     2  EXACTLY ONE  brew install ollama          <- formula
#     3  NO  open -a Ollama
#     4  AT LEAST ONE  brew services start ollama  <- formula's launchd wire
#     5  port 11434 unchanged
#
# Measured against install.sh on 2026-08-15: (1) fires, (2) is 0, (4) is 0.
# The formula path is gone. It was not lost -- it was deliberately replaced,
# and the replacement handles the concern that motivated the swap. install.sh
# now runs `brew install --cask ollama-app` and, at the same site:
#
#     xattr -dr com.apple.quarantine /Applications/Ollama.app
#     # Belt-and-braces de-quarantine (CX-14 E1's concern, neutralised).
#     if [[ ! -x "$OLLAMA_APP_BIN" ]]; then
#         fail_with_code "ERR-07-DMG48-OLLAMA-MISSING-AFTER-BREW" ...
#
# So the old test asserted a POLICY WE RETIRED, not a defect in the installer.
# Left as-is it would have driven someone to "fix" a working install path by
# reverting a considered decision. Board row #676 is the same shape: a pin test
# asserting a source policy main has never followed.
#
# THE SUBSTRING BUG, WHICH MADE IT WORSE
# --------------------------------------
# `grep -E 'brew install --cask ollama'` matches `brew install --cask
# ollama-app`, because the pattern is a prefix of the other cask's name.
# `ollama` and `ollama-app` are DIFFERENT Homebrew casks. The predicate could
# not tell them apart, so it would have reported the same failure whichever one
# was there -- including passing judgement on the wrong cask while claiming to
# have found the right one. Every pattern below anchors to end-of-token.
#
# WHAT IS ASSERTED NOW: the current contract, so the CX-14 protection stays
# under test instead of the coverage being deleted.
#
#   1  the BARE `ollama` cask is still refused -- that is the one whose first
#      launch shows the Gatekeeper dialog. Anchored so `ollama-app` does not
#      match it.
#   2  exactly one `--cask ollama-app` install (the current path)
#   3  the de-quarantine runs at that site -- this is what neutralises the
#      CX-14 concern, and without it the cask reintroduces the original bug
#   4  a hard binary-exists check gates success, so a cask install that lands
#      nothing cannot report OK (the DMG #48 silent-bail lesson)
#   5  no `open -a Ollama` -- success is decided by the binary path, not by
#      whether `open` managed to spawn something
#   6  port 11434 unchanged (cross-component wire contract)
#
# Per feedback_silent_bail_regression_test_shape: walk install.sh refusing the
# EXACT failure shape. A happy-path "does the install work" test would not
# catch the de-quarantine or the exists-check being dropped, because the cask
# usually works on a developer Mac where Gatekeeper is more permissive -- which
# is precisely the box these are never exercised on.
#
# British English throughout; " -- " not em-dashes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"

[ -f "$INSTALL_SH" ] || { echo "CANNOT RUN: ${INSTALL_SH} does not exist" >&2; exit 2; }

fail() { echo "FAIL: $1" >&2; exit 1; }

# ── 1. the BARE `ollama` cask is still refused ────────────────────────────
# End-of-token anchored: `--cask ollama` followed by whitespace or end of
# line. `--cask ollama-app` does NOT match, which is the whole point.
if grep -nE '^[[:space:]]*(if[[:space:]]+)?brew install --cask ollama([[:space:]]|$)' "$INSTALL_SH" > /dev/null; then
    echo "Offending lines:" >&2
    grep -nE '^[[:space:]]*(if[[:space:]]+)?brew install --cask ollama([[:space:]]|$)' "$INSTALL_SH" >&2
    fail "install.sh installs the BARE 'ollama' cask. That is the one whose first launch shows the Gatekeeper 'downloaded from internet' dialog mid-install (CX-14 E1). The supported path is the 'ollama-app' cask plus the de-quarantine below. If you need the bare cask, talk to Andy first."
fi

# ── 2. exactly one `--cask ollama-app` install ────────────────────────────
cask_count=$(grep -cE '^[[:space:]]*brew install --cask ollama-app([[:space:]]|$)' "$INSTALL_SH" || true)
if [ "$cask_count" -ne 1 ]; then
    echo "Offending matches (expected 1, got $cask_count):" >&2
    grep -nE 'brew install --cask ollama-app' "$INSTALL_SH" >&2 || true
    fail "install.sh must have exactly ONE 'brew install --cask ollama-app' invocation. Got $cask_count. Two install sites means two chances to diverge on the de-quarantine and the exists-check that make the cask path safe."
fi

# ── 3. the de-quarantine runs ─────────────────────────────────────────────
# THE LOAD-BEARING ONE. Without this the cask reintroduces exactly the
# Gatekeeper dialog CX-14 E1 was raised about, and the rest of the block
# still looks correct.
if ! grep -nE '^[[:space:]]*xattr -dr com\.apple\.quarantine[[:space:]]+/Applications/Ollama\.app' "$INSTALL_SH" > /dev/null; then
    fail "install.sh does not de-quarantine /Applications/Ollama.app after the cask install. The cask path is only safe BECAUSE of that step: without it the first launch shows the Gatekeeper dialog, the customer ignores it, and the :11434 poll times out with the install reporting a generic 'could not start Ollama'. This is the CX-14 E1 concern and this line is what neutralises it."
fi

# ── 4. a hard binary-exists check gates success ───────────────────────────
# DMG #48 lesson: a bare `command -v ollama` is satisfied by a leftover
# formula on PATH, so success must be decided by the CASK binary's own path.
if ! grep -nE 'ERR-07-DMG48-OLLAMA-MISSING-AFTER-BREW' "$INSTALL_SH" > /dev/null; then
    fail "install.sh no longer fails with ERR-07-DMG48-OLLAMA-MISSING-AFTER-BREW when the cask binary is absent after brew reports success. Without that check a brew install that lands nothing is reported as OK and the failure surfaces 90 seconds later as an unrelated timeout."
fi
if ! grep -nE '^OLLAMA_APP_BIN="/Applications/Ollama\.app/Contents/Resources/ollama"' "$INSTALL_SH" > /dev/null; then
    fail "OLLAMA_APP_BIN no longer points at the cask binary inside Ollama.app. A bare 'command -v ollama' is satisfied by a leftover broken FORMULA on PATH, which is why the check path-matches the app binary instead."
fi

# ── 5. no `open -a Ollama` ────────────────────────────────────────────────
# `open` returns 0 for having spawned something, which is not the same as
# Ollama serving. Success must come from the binary check above.
if grep -nE '^[[:space:]]*open .*-a Ollama' "$INSTALL_SH" > /dev/null; then
    echo "Offending lines:" >&2
    grep -nE '^[[:space:]]*open .*-a Ollama' "$INSTALL_SH" >&2
    fail "install.sh contains an 'open -a Ollama' invocation. 'open' exits 0 for having spawned the app -- including when it spawned a Gatekeeper dialog and nothing is serving. Decide success from OLLAMA_APP_BIN and the :11434 probe, not from open's exit code."
fi

# ── 6. port 11434 unchanged ───────────────────────────────────────────────
if ! grep -nE 'localhost:11434/api/tags' "$INSTALL_SH" > /dev/null; then
    fail "install.sh no longer probes localhost:11434/api/tags. The Ollama port is a cross-component wire contract (Hub agents, embedding pipeline, providers TOML, post-install health probes). A deliberate port change means auditing all four first; a silent one is a copy-paste bug."
fi

echo "PASS: ollama install path contract -- cask 'ollama-app', de-quarantined, exists-checked, port 11434"
exit 0
