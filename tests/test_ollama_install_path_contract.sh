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
# 2026-10-18: limbs 1-4 now lock the PINNED release (no cask of any name, the
# OLLAMA_PIN_* record, one pinned install call, the exists-check on the pinned
# binary, and the already-running skip requiring the agent to serve it). The
# behaviour of the install function itself is executed by
# tests/test_ollama_pin_install_verifies_sha256.sh.
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

# ── 1. NO cask for Ollama, of any name (2026-10-18) ───────────────────────
# A cask cannot be version-pinned and the app it installs updates itself, so
# the model manifests and config digests on disk drift with whatever Ollama is
# current on install day. Neither `ollama` nor `ollama-app` may be installed.
if grep -nE '^[[:space:]]*(if[[:space:]]+)?brew install[[:space:]]+(--cask[[:space:]]+)?ollama(-app)?([[:space:]]|$)' "$INSTALL_SH" > /dev/null; then
    echo "Offending lines:" >&2
    grep -nE '^[[:space:]]*(if[[:space:]]+)?brew install[[:space:]]+(--cask[[:space:]]+)?ollama(-app)?([[:space:]]|$)' "$INSTALL_SH" >&2
    fail "install.sh installs Ollama from Homebrew. The cask is unpinned and self-updating (and the formula has no llama-server, CX-43). Ollama must come from the pinned, sha256-verified release (OLLAMA_PIN_*, _ostler_ollama_pin_install)."
fi

# ── 2. the pin is recorded: version, official URL for THAT version, sha256 ─
pin_ver=$(sed -nE 's/^OLLAMA_PIN_VERSION="([0-9]+\.[0-9]+\.[0-9]+)"$/\1/p' "$INSTALL_SH")
pin_url=$(sed -nE 's/^OLLAMA_PIN_URL="([^"]+)"$/\1/p' "$INSTALL_SH")
pin_sha=$(sed -nE 's/^OLLAMA_PIN_SHA256="([0-9a-f]{64})"$/\1/p' "$INSTALL_SH")
[ "$(printf '%s\n' "$pin_ver" | grep -c .)" = 1 ] || fail "install.sh must set OLLAMA_PIN_VERSION=\"X.Y.Z\" exactly once (got: '${pin_ver}')."
[ "$pin_url" = "https://github.com/ollama/ollama/releases/download/v${pin_ver}/ollama-darwin.tgz" ] \
    || fail "OLLAMA_PIN_URL must be Ollama's official GitHub release asset for v${pin_ver} (ollama-darwin.tgz), got '${pin_url}'. A URL for another version than OLLAMA_PIN_VERSION ships an engine the pin does not describe."
[ "$(printf '%s\n' "$pin_sha" | grep -c .)" = 1 ] || fail "install.sh must record OLLAMA_PIN_SHA256 as 64 lowercase hex characters exactly once."

# ── 3. the pinned install is what runs, once, and the binary lives in its dir ─
call_count=$(grep -cE '^[[:space:]]*_ostler_ollama_pin_install "\$OLLAMA_PIN_DIR" \|\| _ollama_pin_rc=\$\?$' "$INSTALL_SH" || true)
[ "$call_count" -eq 1 ] || fail "install.sh must call _ostler_ollama_pin_install \"\$OLLAMA_PIN_DIR\" exactly once (got ${call_count})."
grep -nE '^OLLAMA_PIN_DIR="\$\{HOME\}/\.ostler/runtime/ollama-\$\{OLLAMA_PIN_VERSION\}"$' "$INSTALL_SH" > /dev/null \
    || fail "OLLAMA_PIN_DIR must be the versioned Ostler-owned prefix \${HOME}/.ostler/runtime/ollama-\${OLLAMA_PIN_VERSION}."

# ── 4. a hard binary-exists check gates success, on the PINNED binary ─────
# DMG #48 lesson: a bare `command -v ollama` is satisfied by a leftover
# formula on PATH, so success must be decided by the binary's own path.
if ! grep -nE 'ERR-07-DMG48-OLLAMA-MISSING-AFTER-BREW' "$INSTALL_SH" > /dev/null; then
    fail "install.sh no longer fails with ERR-07-DMG48-OLLAMA-MISSING-AFTER-BREW when the Ollama binary is absent after install. Without that check an install that lands nothing is reported as OK and the failure surfaces 90 seconds later as an unrelated timeout."
fi
if ! grep -nE '^OLLAMA_APP_BIN="\$\{OLLAMA_PIN_DIR\}/ollama"$' "$INSTALL_SH" > /dev/null; then
    fail "OLLAMA_APP_BIN no longer points at the pinned binary. It is what the com.ostler.ollama LaunchAgent serves; pointed anywhere else, the customer runs an engine the pin does not describe."
fi
# An agent written by a cask-era install must not satisfy the "already
# running" skip, or the upgraded customer stays on the self-updating app.
if ! grep -nE '^if curl -sf http://localhost:11434/api/tags .*&& grep -qF "<string>\$\{OLLAMA_APP_BIN\}</string>" "\$OLLAMA_PLIST"; then$' "$INSTALL_SH" > /dev/null; then
    fail "the 'Ollama already running' skip no longer requires com.ostler.ollama to serve OLLAMA_APP_BIN, so an install upgraded from the cask keeps serving /Applications/Ollama.app."
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

echo "PASS: ollama install path contract -- no cask, pinned v${pin_ver} sha256-recorded, exists-checked, port 11434"
exit 0
