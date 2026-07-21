#!/usr/bin/env bash
#
# tests/test_v1010_at_rest_exclusions.sh
#
# FIX 3 (v1.0.10 security lockdown -- at-rest exposure).
#
# The plaintext personal graph (~/Documents/Ostler wiki + vault +
# transcripts) and the secrets/config under ~/.ostler must be kept
# out of the Spotlight index and out of Time Machine (which frequently
# copies to an off-site NAS). Also: FileVault, if declined, must be a
# loud + recorded acknowledgement, not a silent skip.
#
# Pure shell + grep. No install run.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${REPO_ROOT}/install.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$INSTALL_SCRIPT" ]] || fail "install.sh not found"

# 1. Spotlight opt-out marker + Time Machine exclusion helper exists.
grep -q '.metadata_never_index' "$INSTALL_SCRIPT" \
    || fail "Spotlight opt-out marker (.metadata_never_index) not written"
grep -q 'tmutil addexclusion' "$INSTALL_SCRIPT" \
    || fail "Time Machine exclusion (tmutil addexclusion) missing"
grep -q '_ostler_harden_at_rest()' "$INSTALL_SCRIPT" \
    || fail "_ostler_harden_at_rest helper missing"

# 2. Applied to BOTH sensitive trees.
grep -q '_ostler_harden_at_rest "\$OSTLER_DIR"' "$INSTALL_SCRIPT" \
    || fail "at-rest hardening not applied to \$OSTLER_DIR (~/.ostler)"
grep -q '_ostler_harden_at_rest "\$USER_FACING_ROOT"' "$INSTALL_SCRIPT" \
    || fail "at-rest hardening not applied to \$USER_FACING_ROOT (~/Documents/Ostler)"

# 3. FileVault decline is a recorded acknowledgement, not a silent skip.
grep -q 'filevault_ack.txt' "$INSTALL_SCRIPT" \
    || fail "FileVault decline is not recorded (filevault_ack.txt marker missing)"
# And the pre-existing hard gate (refuse unless explicit opt-in) is intact.
grep -q 'Enable FileVault first, then re-run this installer.' "$INSTALL_SCRIPT" \
    || fail "FileVault hard gate (refuse + exit) removed"

echo "PASS: Spotlight + Time Machine exclusions on both Ostler trees; FileVault decline is loud + recorded."
