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

# ── FIX-RT2-F3: hardening must run AFTER promotion, not on staging ──
# On a fresh curl|bash install OSTLER_DIR is the ephemeral staging tree
# (${OSTLER_PRELAUNCH_DIR}, /tmp/ostler-prelaunch-$$) until
# _ostler_promote_prelaunch_tree renames it onto ~/.ostler/. If the
# `_ostler_harden_at_rest "$OSTLER_DIR"` call fires BEFORE that
# promotion, the tmutil exclusion is set on the /tmp node that promotion
# then rm -rf's -- so ~/.ostler/ (secrets + .env JWT_SECRET) is NEVER
# excluded and Time Machine copies it off-box. Assert the OSTLER_DIR
# hardening call is positioned after the FDA-phase promotion, not in the
# Phase-2 staging region.
harden_line="$(grep -n '_ostler_harden_at_rest "\$OSTLER_DIR"' "$INSTALL_SCRIPT" | head -1 | cut -d: -f1)"
[[ -n "$harden_line" ]] || fail "FIX-RT2-F3: no _ostler_harden_at_rest \$OSTLER_DIR invocation found"
# Exactly one live invocation (the relocated one) -- a stray Phase-2 copy
# would re-introduce the staging-node bug.
harden_count="$(grep -c '^_ostler_harden_at_rest "\$OSTLER_DIR"' "$INSTALL_SCRIPT" || true)"
[[ "$harden_count" -eq 1 ]] \
    || fail "FIX-RT2-F3: expected exactly 1 live _ostler_harden_at_rest \$OSTLER_DIR call, found ${harden_count}"
fda_hdr_line="$(grep -n '3.7 FDA extraction' "$INSTALL_SCRIPT" | head -1 | cut -d: -f1)"
promote_catchall_line="$(grep -n 'catch-all promotion of the staging tree' "$INSTALL_SCRIPT" | head -1 | cut -d: -f1)"
[[ -n "$fda_hdr_line" && -n "$promote_catchall_line" ]] \
    || fail "FIX-RT2-F3: could not locate the FDA-phase promotion landmarks"
[[ "$harden_line" -gt "$promote_catchall_line" ]] \
    || fail "FIX-RT2-F3: OSTLER_DIR hardening (line ${harden_line}) runs BEFORE the catch-all promotion (line ${promote_catchall_line}) -- it would harden the /tmp staging node, not ~/.ostler"

# ── FIX-RT2-F4: the Colima VM disk (plaintext embedded graph) too ──
grep -q '_ostler_harden_at_rest "\${HOME}/.colima"' "$INSTALL_SCRIPT" \
    || fail "FIX-RT2-F4: ~/.colima (plaintext Qdrant/Oxigraph VM disk) not in the exclusion set"

echo "PASS: Spotlight + Time Machine exclusions on both Ostler trees; hardening runs post-promotion (not on /tmp staging); ~/.colima excluded; FileVault decline is loud + recorded."

# ── FIX-RT2-F3 functional reproduction ────────────────────────────
# Extract the real _ostler_harden_at_rest helper from install.sh and
# drive it through the staging->promote->final sequence with a stubbed
# tmutil, proving the Time Machine exclusion lands on the PERSISTENT
# final directory and NOT on the /tmp node that promotion deletes.
HARNESS="$(mktemp -d)"
trap 'rm -rf "$HARNESS"' EXIT

awk '/^_ostler_harden_at_rest\(\) \{/{c=1} c{print} c&&/^\}/{exit}' \
    "$INSTALL_SCRIPT" > "$HARNESS/harden.sh"
grep -q 'tmutil addexclusion' "$HARNESS/harden.sh" \
    || fail "FIX-RT2-F3: failed to extract _ostler_harden_at_rest helper"

EXCL_LOG="$HARNESS/tmutil_exclusions.log"
# shellcheck disable=SC2317
tmutil() { if [[ "$1" == "addexclusion" ]]; then echo "$2" >> "$EXCL_LOG"; fi; }
export -f tmutil 2>/dev/null || true
# shellcheck source=/dev/null
source "$HARNESS/harden.sh"

STAGING="$HARNESS/tmp/ostler-prelaunch-999"
FINAL="$HARNESS/dot-ostler"
mkdir -p "$STAGING/secrets"
printf 'plaintext-service-token\n' > "$STAGING/secrets/service_token"

# (a) The BUGGED order: harden the staging node, THEN promote (which
# rm -rf's staging). The exclusion was recorded against the /tmp node.
: > "$EXCL_LOG"
_ostler_harden_at_rest "$STAGING"
mkdir -p "$FINAL"
mv "$STAGING/secrets" "$FINAL/secrets"
rm -rf "$STAGING"
grep -qxF "$STAGING" "$EXCL_LOG" \
    || fail "FIX-RT2-F3 repro: helper did not record the exclusion for the dir it was given"
grep -qxF "$FINAL" "$EXCL_LOG" \
    && fail "FIX-RT2-F3 repro: sanity -- final should NOT be excluded in the bugged order"
[[ -f "$FINAL/secrets/service_token" ]] \
    || fail "FIX-RT2-F3 repro: promotion sanity -- secrets did not reach the final dir"
echo "  repro: bugged order excludes only the (now-deleted) staging node -> ${FINAL} left UNPROTECTED (secrets would hit Time Machine)"

# (b) The FIXED order: promote first, then harden the final node.
: > "$EXCL_LOG"
_ostler_harden_at_rest "$FINAL"
grep -qxF "$FINAL" "$EXCL_LOG" \
    || fail "FIX-RT2-F3 repro: fixed order did not exclude the promoted ~/.ostler node"
[[ -f "$FINAL/.metadata_never_index" ]] \
    || fail "FIX-RT2-F3 repro: Spotlight opt-out marker not written to the final node"
echo "  repro: fixed order (harden AFTER promotion) excludes ${FINAL} -> secrets protected."

echo "PASS [repro]: at-rest hardening protects the persistent ~/.ostler node only when applied post-promotion."
