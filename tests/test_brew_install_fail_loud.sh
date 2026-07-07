#!/usr/bin/env bash
#
# tests/test_brew_install_fail_loud.sh
#
# DMG #48 (2026-05-27) silent-bail regression test. Andy's Studio
# retest of DMG #47 surfaced the bug: every `brew install <pkg>`
# block in install.sh would silently no-op on a fresh Mac (Homebrew
# missing, but the upstream Homebrew-install step also silent-failed
# upstream), leaving the customer with no brew/colima/tailscale yet
# the install GUI flowed all the way to "end".
#
# The fix (PR 2 of the DMG #48 TNM brief at
# `launch/TNM_BRIEF_dmg48_three_blockers_2026-05-27.md` in the HR015
# repo): every
# `brew install <pkg>` step in install.sh must verify the
# post-condition byte-by-byte BEFORE the install proceeds. That is
# either:
#
#   - `command -v <binary>` returning a path, OR
#   - `[[ -x /opt/homebrew/bin/<binary> ]]`, OR
#   - For casks: `[[ -d /Applications/<App>.app ]]`
#
# AND every such verification, when it fails, MUST be a
# `fail_with_code "ERR-NN-DMG48-..." ...` (not a `warn`, not a bare
# `fail`, not a silent `|| true`).
#
# Per [[feedback-silent-bail-regression-test-shape]], the test walks
# install.sh assembled-output byte-by-byte refusing the EXACT failure
# shape (an unverified brew install). A future agent removing or
# wrapping a `command -v` check in `|| true` will trip this test.
#
# Pure bash + standard tools. Exit code 0 on pass, non-zero on fail.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"

if [[ ! -f "$INSTALL_SH" ]]; then
    echo "FAIL: install.sh not found at $INSTALL_SH" >&2
    exit 1
fi

failures=0
fail_test() {
    failures=$((failures + 1))
    echo "FAIL: $*" >&2
}

ok() { echo "ok: $*"; }

# ── Test 1 — Homebrew install has a post-condition verification ──
#
# After the `if command -v brew &>/dev/null; then ... else <install>
# fi` block, install.sh MUST verify that /opt/homebrew/bin/brew is
# executable AND `command -v brew` returns a path. The verification
# MUST be `fail_with_code`, not `warn` or bare `fail`.

if ! grep -q 'ERR-04-DMG48-HOMEBREW-MISSING-AFTER-INSTALL' "$INSTALL_SH"; then
    fail_test "install.sh must call fail_with_code with code ERR-04-DMG48-HOMEBREW-MISSING-AFTER-INSTALL when /opt/homebrew/bin/brew is missing post-install."
else
    ok "Homebrew post-install MISSING-AFTER-INSTALL fail_with_code wired."
fi

if ! grep -q 'ERR-04-DMG48-HOMEBREW-NOT-ON-PATH' "$INSTALL_SH"; then
    fail_test "install.sh must call fail_with_code with code ERR-04-DMG48-HOMEBREW-NOT-ON-PATH when brew is not on PATH after shellenv eval."
else
    ok "Homebrew post-install NOT-ON-PATH fail_with_code wired."
fi

# ── Test 2 — colima/docker post-install verification ──
if ! grep -q 'ERR-06-DMG48-COLIMA-MISSING-AFTER-BREW' "$INSTALL_SH"; then
    fail_test "install.sh must call fail_with_code with code ERR-06-DMG48-COLIMA-MISSING-AFTER-BREW after brew install colima."
else
    ok "colima post-install fail_with_code wired."
fi

if ! grep -q 'ERR-06-DMG48-DOCKER-CLI-MISSING-AFTER-BREW' "$INSTALL_SH"; then
    fail_test "install.sh must call fail_with_code with code ERR-06-DMG48-DOCKER-CLI-MISSING-AFTER-BREW after brew install docker."
else
    ok "docker CLI post-install fail_with_code wired."
fi

# ── Test 3 — ollama post-install verification ──
if ! grep -q 'ERR-07-DMG48-OLLAMA-MISSING-AFTER-BREW' "$INSTALL_SH"; then
    fail_test "install.sh must call fail_with_code with code ERR-07-DMG48-OLLAMA-MISSING-AFTER-BREW after brew install ollama."
else
    ok "ollama post-install fail_with_code wired."
fi

# ── Test 4 — sqlcipher post-install verification ──
if ! grep -q 'ERR-08-DMG48-SQLCIPHER-MISSING-AFTER-BREW' "$INSTALL_SH"; then
    fail_test "install.sh must call fail_with_code with code ERR-08-DMG48-SQLCIPHER-MISSING-AFTER-BREW after brew install sqlcipher."
else
    ok "sqlcipher post-install fail_with_code wired."
fi

# ── Test 5 — tailscale install shape (CURRENT: formula, warn-not-fail) ──
#
# DMG #48 originally demanded fail-loud with
# ERR-15-DMG48-TAILSCALE-INSTALL-FAILED after `brew install --cask
# tailscale`. SUPERSEDED twice (assertions updated 2026-07-07):
#   - CX-105 (PR #213): Tailscale is OPTIONAL, a failed install must
#     warn-and-continue (OSTLER_TAILSCALE_SKIPPED=1), not abort the
#     whole install over an off-LAN nicety.
#   - #604 (2026-06-02 Studio walk): the cask resolves to tailscale-app
#     with a kext + sudo .pkg the non-interactive installer cannot
#     complete. Swapped to the `tailscale` FORMULA (headless CLI +
#     tailscaled, userspace networking, no kext, no sudo).
# The failure is still LOUD (an explicit warn string, not a silent
# `|| true`), so the DMG #48 silent-bail axis is preserved.
if ! grep -qE '^\s*if brew install tailscale' "$INSTALL_SH"; then
    fail_test "install.sh must install Tailscale via the FORMULA ('brew install tailscale', #604). The cask needs an interactive kext approval the installer cannot drive."
else
    ok "tailscale FORMULA install path present (#604)."
fi
if ! grep -q 'MSG_WARN_TAILSCALE_INSTALL_FAILED_YOU_CAN_INSTALL' "$INSTALL_SH"; then
    fail_test "install.sh must warn loudly (MSG_WARN_TAILSCALE_INSTALL_FAILED_YOU_CAN_INSTALL) when the tailscale formula install fails (CX-105 warn-not-fail; never a silent bail)."
else
    ok "tailscale install failure warns loudly (CX-105)."
fi
if ! grep -q 'OSTLER_TAILSCALE_SKIPPED=1' "$INSTALL_SH"; then
    fail_test "install.sh must set OSTLER_TAILSCALE_SKIPPED=1 on tailscale install failure so downstream steps skip cleanly instead of half-configuring."
else
    ok "tailscale failure flags OSTLER_TAILSCALE_SKIPPED=1."
fi

# Refuse the cask path returning (either the old soft-fail shape or a
# plain cask invocation).
if grep -qE '^\s*(if\s+)?brew install --cask tailscale' "$INSTALL_SH"; then
    fail_test "install.sh contains a 'brew install --cask tailscale' invocation. #604: the cask's kext + sudo .pkg cannot complete non-interactively; use the formula."
else
    ok "Tailscale cask invocation is absent (#604 formula path holds)."
fi

# ── Test 6 — install.log transcript is set up early ──
#
# Studio retest of DMG #47 found NO install.log on disk. The
# transcript must tee everything from early in install.sh into
# ${LOGS_DIR}/install.log so the next failure leaves a paper trail.
if ! grep -q '^INSTALL_LOG="\${LOGS_DIR}/install.log"' "$INSTALL_SH"; then
    fail_test "install.sh must set INSTALL_LOG=\${LOGS_DIR}/install.log early (after the path defs, before Phase 1) so the customer + support have a paper trail."
else
    ok "INSTALL_LOG path wired to \${LOGS_DIR}/install.log."
fi

# Verify the actual tee redirection is in place. Both the stdout AND
# stderr arms must be redirected.
#
# SUPERSEDED shape note (assertion updated 2026-07-07): the original
# DMG #48 pattern hard-coded `stdbuf -oL tee`, but macOS has no native
# stdbuf (GNU coreutils only) and on a fresh customer Mac brew is
# installed AFTER this block runs. install.sh now probes
# stdbuf > gstdbuf > plain tee via _ostler_select_tee_cmd() and execs
# through ${_OSTLER_TEE_CMD}. Same fail-loud transcript guarantee,
# portable implementation.
if ! grep -qE 'exec > >\(\$\{_OSTLER_TEE_CMD\} -a "\$\{INSTALL_LOG\}"\) 2>&1' "$INSTALL_SH"; then
    fail_test "install.sh must redirect stdout+stderr through 'exec > >(\${_OSTLER_TEE_CMD} -a \"\${INSTALL_LOG}\") 2>&1'. Without it, the GUI's progress lines never reach disk."
else
    ok "install.log tee redirection in place (exec > >(\${_OSTLER_TEE_CMD} -a ...) 2>&1)."
fi
# The probe must still PREFER line-buffered stdbuf when available so
# the GUI log streams live rather than in 4KB chunks.
if ! grep -q '_ostler_select_tee_cmd' "$INSTALL_SH" || ! grep -q 'stdbuf -oL tee' "$INSTALL_SH"; then
    fail_test "install.sh must probe for line-buffered tee (stdbuf -oL tee, falling back to gstdbuf/plain tee) via _ostler_select_tee_cmd; a plain-tee-only wire makes the GUI log viewer lag by kilobytes."
else
    ok "line-buffered tee probe (_ostler_select_tee_cmd, stdbuf preferred) present."
fi

# ── Test 7 — the new MSG_FAIL_* strings exist in the en-GB catalogue ──
STRINGS_FILE="${REPO_ROOT}/install.sh.strings.en-GB.sh"
if [[ ! -f "$STRINGS_FILE" ]]; then
    fail_test "install.sh.strings.en-GB.sh not found at $STRINGS_FILE"
else
    for key in \
        MSG_FAIL_HOMEBREW_MISSING_AFTER_INSTALL \
        MSG_FAIL_HOMEBREW_NOT_ON_PATH \
        MSG_FAIL_COLIMA_MISSING_AFTER_BREW \
        MSG_FAIL_DOCKER_CLI_MISSING_AFTER_BREW \
        MSG_FAIL_OLLAMA_MISSING_AFTER_BREW \
        MSG_FAIL_SQLCIPHER_MISSING_AFTER_BREW \
        MSG_WARN_TAILSCALE_INSTALL_FAILED_YOU_CAN_INSTALL; do
        if ! grep -q "^${key}=" "$STRINGS_FILE"; then
            fail_test "Locale catalogue missing key: ${key}. Rule 0.9 (customer strings extractable from day one) requires it in install.sh.strings.en-GB.sh."
        else
            ok "Locale catalogue has key: ${key}"
        fi
    done
fi

# ── Test 8 — no `brew install <X>` is missing a follow-up verification ──
#
# Walk every `brew install` line that isn't `brew install --cask`
# and isn't behind `brew list <X> &>/dev/null` (idempotent guard).
# This is the byte-by-byte axis. Within 30 lines after each, we
# expect to see EITHER:
#   - a command -v <X> &>/dev/null check, OR
#   - a [[ -x /opt/homebrew/... ]] check, OR
#   - a [[ -d /Applications/<App>.app ]] check (cask case)
# followed within 5 lines by fail_with_code.

# Read brew install lines into an array. `mapfile` is bash 4+
# (Homebrew bash 5 has it, but the system /bin/bash on macOS is 3.2).
# Use a portable while-read loop instead.
brew_lines=()
while IFS= read -r line; do
    brew_lines+=("$line")
done < <(grep -n '^[[:space:]]*brew install\b' "$INSTALL_SH" | grep -v 'reinstall' || true)

for entry in "${brew_lines[@]}"; do
    line_no="${entry%%:*}"
    line_body="${entry#*:}"
    end_line=$(( line_no + 30 ))
    # Skip the `brew install --cask` check for python@3.11 -- it has
    # its own MSG_FAIL_HOMEBREW_PYTHON_MISSING verification a few
    # lines below it (pre-existing).
    window=$(sed -n "${line_no},${end_line}p" "$INSTALL_SH")
    if grep -qE 'command -v [a-zA-Z0-9_-]+ &>/dev/null|\[\[ -x .*homebrew.*\]\]|\[\[ -d "/Applications/.*\.app"\s*\]\]|fail_with_code' <<<"$window"; then
        ok "brew install at line ${line_no} has a downstream post-condition check"
    else
        fail_test "brew install at line ${line_no} (${line_body}) has NO downstream command -v / -x / fail_with_code check within 30 lines. DMG #47 customers tripped over exactly this shape."
    fi
done

if [[ ${#brew_lines[@]} -eq 0 ]]; then
    echo "WARN: no brew install lines found -- did install.sh structure change?" >&2
fi

# ── Summary ──
echo ""
if [[ $failures -eq 0 ]]; then
    echo "PASS: every brew install in install.sh fail-loud + install.log transcript wired."
    exit 0
else
    echo "FAIL: ${failures} silent-bail axis violation(s) in install.sh." >&2
    exit 1
fi
