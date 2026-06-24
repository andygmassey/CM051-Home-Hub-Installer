#!/usr/bin/env bash
#
# tests/test_imessage_daemon_prime_bug020.sh
#
# Locks the BUG-020 daemon-identity Automation-prime wiring in
# install.sh.
#
# Why this test exists:
#
#   macOS TCC Automation is PER-SOURCE-APP. The installer's own
#   read-only Messages probe (Phase 3.18, and the front-loaded prime
#   in Phase 2) triggers the "wants to control Messages" consent
#   dialog, but it grants the INSTALLER binary (Ostler Installer /
#   Terminal) -- NOT the daemon (OstlerAssistant.app). The daemon has
#   its OWN, separate grant.
#
#   Before this fix, the daemon's grant was only ever requested the
#   first time the daemon touched Messages, which is 1-2 minutes AFTER
#   the installer finished, when launchd booted it. That surfaced a
#   "OstlerAssistant wants to control Messages" popup AFTER the success
#   screen -- ambushing the customer, breaking the launch promise that
#   nothing prompts after "all done".
#
#   The fix invokes the daemon binary's own one-shot
#   `prime-imessage-automation` subcommand DURING the guided install
#   (inside the pre-warned Phase 3.18 block, after the daemon bundle is
#   staged on disk, before the daemon's late launchctl kickstart), so
#   the daemon-identity prompt fires in the attention window. Once
#   granted it persists for daemon runtime; the late boot does not
#   re-prompt.
#
#   This test pins the wiring so a future edit cannot quietly regress:
#     1. The daemon binary is invoked with `prime-imessage-automation`.
#     2. The invocation is gated on the daemon binary existing on disk
#        (`-x "${ASSISTANT_BINARY...}"`), the GUI flow, and the absence
#        of the test shim (so harnesses never osascript).
#     3. It is best-effort / non-fatal (`|| true`).
#     4. It sits BEFORE the daemon's late `launchctl kickstart` (so the
#        prompt lands during install, not on the late daemon boot).
#     5. The MSG_INFO_PRIMING_DAEMON_IMESSAGE_AUTOMATION pre-warn string
#        is defined in the en-GB catalogue.
#
# Companion to tests/test_imessage_tcc_posture.sh (the installer-side
# posture probe). This test covers the DAEMON-side grant only.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${REPO_ROOT}/install.sh"
STRINGS_FILE="${REPO_ROOT}/install.sh.strings.en-GB.sh"

if [[ ! -f "$INSTALL_SCRIPT" ]]; then
    echo "FAIL: install.sh not found at $INSTALL_SCRIPT" >&2
    exit 1
fi

if ! bash -n "$INSTALL_SCRIPT"; then
    echo "FAIL: install.sh fails bash -n parse check" >&2
    exit 1
fi
echo "PASS: install.sh parses"

# ── 1. The daemon's prime subcommand is invoked ─────────────────
if ! grep -q 'prime-imessage-automation' "$INSTALL_SCRIPT"; then
    echo "FAIL [no-invoke]: install.sh never invokes 'prime-imessage-automation'" >&2
    exit 1
fi
echo "PASS: install.sh invokes daemon 'prime-imessage-automation'"

# ── 2a. Gated on the daemon binary existing on disk ─────────────
if ! grep -qE '\-x "\$\{ASSISTANT_BINARY:-\}"' "$INSTALL_SCRIPT"; then
    echo "FAIL [no-disk-gate]: prime not gated on ASSISTANT_BINARY existing (-x)" >&2
    exit 1
fi
echo "PASS: prime gated on daemon binary present on disk"

# ── 2b. Gated to a no-op under the test shim ────────────────────
# The guard must skip osascript-driving when PWG_IMESSAGE_PROBE_OUTCOME
# is set, so harnesses never actually prompt Messages.
if ! grep -q 'z "${PWG_IMESSAGE_PROBE_OUTCOME:-}"' "$INSTALL_SCRIPT"; then
    echo "FAIL [no-shim-gate]: prime not gated on PWG_IMESSAGE_PROBE_OUTCOME being unset" >&2
    exit 1
fi
echo "PASS: prime suppressed under the PWG_IMESSAGE_PROBE_OUTCOME test shim"

# ── 3. Best-effort / non-fatal (|| true on the invocation) ──────
if ! grep -qE 'prime-imessage-automation \\$' "$INSTALL_SCRIPT"; then
    echo "FAIL [shape]: prime invocation does not have the expected continuation shape" >&2
    exit 1
fi
# The line that follows the invocation must redirect + `|| true`.
if ! grep -A1 'prime-imessage-automation \\$' "$INSTALL_SCRIPT" \
        | grep -q '|| true'; then
    echo "FAIL [non-fatal]: prime invocation is not '|| true' (must never abort install)" >&2
    exit 1
fi
echo "PASS: prime invocation is best-effort / non-fatal (|| true)"

# ── 4. Prime fires BEFORE the daemon's late launchctl kickstart ──
# The whole point of BUG-020: the prompt must land during install,
# not on the late daemon boot. The prime call must therefore precede
# the assistant's launchctl kickstart line in file order.
PRIME_LINE="$(grep -n 'prime-imessage-automation' "$INSTALL_SCRIPT" \
    | grep -v '^[0-9]*:#' | head -1 | cut -d: -f1)"
KICKSTART_LINE="$(grep -n 'launchctl kickstart -k "gui/\$(id -u)/com.creativemachines.ostler.assistant"' \
    "$INSTALL_SCRIPT" | tail -1 | cut -d: -f1)"
if [[ -z "$PRIME_LINE" || -z "$KICKSTART_LINE" ]]; then
    echo "FAIL [ordering-lines]: could not locate prime ($PRIME_LINE) or kickstart ($KICKSTART_LINE) line" >&2
    exit 1
fi
if (( PRIME_LINE >= KICKSTART_LINE )); then
    echo "FAIL [ordering]: prime (line $PRIME_LINE) must precede the daemon kickstart (line $KICKSTART_LINE)" >&2
    exit 1
fi
echo "PASS: prime (line $PRIME_LINE) fires before daemon kickstart (line $KICKSTART_LINE)"

# ── 5. The pre-warn string is defined in the catalogue ──────────
if [[ ! -f "$STRINGS_FILE" ]]; then
    echo "FAIL: en-GB strings file not found at $STRINGS_FILE" >&2
    exit 1
fi
if ! grep -q '^MSG_INFO_PRIMING_DAEMON_IMESSAGE_AUTOMATION=' "$STRINGS_FILE"; then
    echo "FAIL [string]: MSG_INFO_PRIMING_DAEMON_IMESSAGE_AUTOMATION not defined in en-GB catalogue" >&2
    exit 1
fi
echo "PASS: MSG_INFO_PRIMING_DAEMON_IMESSAGE_AUTOMATION defined in en-GB catalogue"

echo ""
echo "ALL PASS: BUG-020 daemon Automation-prime wiring is intact."
