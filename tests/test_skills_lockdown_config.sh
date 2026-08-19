#!/usr/bin/env bash
#
# tests/test_skills_lockdown_config.sh
#
# Locks the v1.0 Skills surface lockdown (task #559) in install.sh.
#
# Why this test exists:
#
#   The bundled ostler-assistant runtime exposes a Skills system
#   (zeroclaw skills install <source> + script execution gated by
#   skills.allow_scripts). Shipping an open "install any skill +
#   run its scripts" surface to customers at v1.0 is a remote-code-
#   execution / supply-chain risk on a privacy product.
#
#   v1.0 locks it down at the config layer (resign-free; the daemon
#   binary is unchanged): install.sh writes an explicit [skills]
#   block into the customer's assistant config.toml so the posture
#   never depends on an upstream default that could drift.
#
#     1. The TOML emitter writes a [skills] header.
#     2. allow_scripts = false           (blocks script execution)
#     3. registry_url = ""               (suppresses the bundled
#        third-party registry default + disables bare-name installs)
#
#   "Unconditionally" matters: a future edit that wraps the block in
#   an `if [[ "$CHANNEL_..." == true ]]` would silently disable the
#   lockdown whenever the user skips channel config. The lockdown is
#   not channel-conditional; it always ships.
#
# Sister tests:
#   - test_assistant_config_vane_wiring.sh -- same brace-block emitter
#
# The full surface-off (hiding the install/test subcommands) is a
# binary change and ships in v1.0.1 with the Curator gallery (#546);
# this test pins only the resign-free config-layer half.

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

# -- Block presence ----------------------------------------------
if ! grep -q 'echo "\[skills\]"' "$INSTALL_SCRIPT"; then
    echo "FAIL [skills-header]: install.sh does not emit [skills] header" >&2
    exit 1
fi
echo "PASS: install.sh emits [skills] header"

# -- allow_scripts = false ---------------------------------------
if ! grep -q 'echo "allow_scripts = false"' "$INSTALL_SCRIPT"; then
    echo "FAIL [allow-scripts-false]: install.sh does not set allow_scripts = false" >&2
    exit 1
fi
echo "PASS: install.sh sets allow_scripts = false"

# -- registry_url empty (competitor default suppressed) ----------
if ! grep -qF 'echo "registry_url = \"\""' "$INSTALL_SCRIPT"; then
    echo "FAIL [registry-url-empty]: install.sh does not set registry_url = \"\"" >&2
    exit 1
fi
echo 'PASS: install.sh sets registry_url = "" (third-party registry suppressed)'

# -- Block is emitted unconditionally ----------------------------
# The TOML emitter is the body of `{ ... } > "$ASSISTANT_CONFIG"`.
# Top-level statements inside the brace block are indented exactly
# 4 spaces; a statement nested in an `if` is 8+. The [skills] header
# echo must be at 4 spaces, else a future edit gated the lockdown.
INDENT="$(grep -nE '^[[:space:]]+echo "\[skills\]"$' "$INSTALL_SCRIPT" \
    | head -n 1 | sed -E 's/^[0-9]+:( +).*/\1/' | awk '{ print length }')"

if [[ -z "$INDENT" ]]; then
    echo "FAIL [emitter-header-missing]: could not locate the [skills] echo line" >&2
    exit 1
fi

if [[ "$INDENT" -ne 4 ]]; then
    echo "FAIL [skills-conditional]: [skills] is indented ${INDENT} spaces (expected 4)" >&2
    echo "      The lockdown is not channel-conditional; it must be top-level in the brace block." >&2
    exit 1
fi
echo "PASS: [skills] block is emitted unconditionally (top-level indent)"

echo ""
echo "ALL SKILLS LOCKDOWN CONFIG TESTS PASSED"
