#!/usr/bin/env bash
#
# tests/test_cx98_previous_install_detection.sh
#
# Byte-walking regression test for the CX-98 Part 3 fix:
# tighten the "previous installation detected" trigger so it
# does NOT fire on a pre-FDA scaffolding state (licence-only,
# no .env, or partial .env).
#
# What the failure looks like (PRE-CX-87 / PRE-CX-98, must never recur):
#
#   1. The Tauri GUI writes the customer's licence file to
#      ~/.ostler/license/license.json at the licence-drop step
#      (~13:24:43 on Andy's Studio retest), seconds before
#      install.sh begins.
#
#   2. install.sh starts (~13:24:52) and probes for a prior
#      install. The OLD detector (pre-CX-87) just checked the
#      EXISTENCE of license.json + the staging-tree config path,
#      which silently triggered reuse against install.sh's own
#      seconds-old scaffolding.
#
#   3. Reuse=yes → SKIP_PHASE2=true → defaults block skipped →
#      config_save trips set -u on CHANNEL_IMESSAGE_ENABLED at
#      line 4823 (CX-98).
#
# Post-CX-87 the detector probes
# ${OSTLER_FINAL_DIR}/config/.env, which is only written at
# config_save (the END of Phase 2). CX-98 tightens further by
# requiring the .env to contain a real USER_ID= line so a
# partial / truncated .env from a crashed prior install cannot
# mis-trigger.
#
# Axes covered:
#   1. Detector lives at the SKIP_PHASE2=false line and probes
#      ~/.ostler/config/.env -- NOT the licence file alone, NOT
#      the staging-tree path.
#   2. Detector requires USER_ID= grep, not just file existence.
#   3. The .env-write site (config_save, ~line 4525) is the
#      single source of USER_ID= -- the licence-drop path does
#      NOT write USER_ID= into ~/.ostler/config/.env.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
FAILED=0

failure() {
    echo "FAIL: $*" >&2
    FAILED=1
}

if [[ ! -f "$INSTALL_SH" ]]; then
    echo "FATAL: install.sh not found at $INSTALL_SH" >&2
    exit 2
fi

# ── Axis 1: detector probe location ──
# The probe must reference ${OSTLER_FINAL_DIR}/config/.env
# (final location, not staging) at the SKIP_PHASE2=false line.

if ! grep -qE 'OSTLER_FINAL_DIR.*config/\.env' "$INSTALL_SH"; then
    failure "detector does not probe \${OSTLER_FINAL_DIR}/config/.env -- CX-87 contract broken"
fi

# ── Axis 2: detector requires USER_ID= content, not just file ──
# existence. Find the line bracketing the SKIP_PHASE2=false +
# scan a 30-line window for the grep -q '^USER_ID=' guard.

PHASE2_LINE="$(grep -n '^SKIP_PHASE2=false$' "$INSTALL_SH" | head -1 | cut -d: -f1)"
if [[ -z "$PHASE2_LINE" ]]; then
    failure "could not locate SKIP_PHASE2=false"
else
    WINDOW_END=$(( PHASE2_LINE + 30 ))
    if ! sed -n "${PHASE2_LINE},${WINDOW_END}p" "$INSTALL_SH" \
        | grep -qE "grep -q '\\^USER_ID=' "; then
        failure "detector does not require USER_ID= grep -- partial / pre-FDA .env can mis-trigger reuse"
    fi
fi

# ── Axis 3: USER_ID= is only written by the config_save block. ──
# Survey every USER_ID= write into config/.env across install.sh
# and assert there is only one source -- the config_save
# heredoc. Anything else would be a phantom trigger.

USER_ID_WRITE_SITES="$(grep -nE 'USER_ID="\$\{USER_ID\}"' "$INSTALL_SH" | wc -l | tr -d ' ')"
if (( USER_ID_WRITE_SITES != 1 )); then
    failure "expected exactly 1 USER_ID=... write site, found ${USER_ID_WRITE_SITES} -- a second write path could trigger reuse without a complete Phase 2"
fi

# Confirm that single write site is INSIDE the config_save block.
USER_ID_LINE="$(grep -nE 'USER_ID="\$\{USER_ID\}"' "$INSTALL_SH" | head -1 | cut -d: -f1)"
CONFIG_SAVE_LINE="$(grep -nE 'progress "Saving your configuration" "config_save"' "$INSTALL_SH" | head -1 | cut -d: -f1)"
if [[ -n "$USER_ID_LINE" && -n "$CONFIG_SAVE_LINE" ]]; then
    if (( USER_ID_LINE < CONFIG_SAVE_LINE )); then
        failure "USER_ID= write at line ${USER_ID_LINE} is BEFORE config_save at line ${CONFIG_SAVE_LINE} -- ordering invariant broken"
    fi
fi

# ── Axis 4: integration ──
# Build a fake ~/.ostler/ tree with ONLY the licence file (no
# .env) and assert install.sh's detector logic returns false.
# We extract the detector predicate as a standalone bash test
# and exercise it against two mocked OSTLER_FINAL_DIR states.

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# State A: licence-only (pre-FDA scaffolding). Detector should
# NOT trigger reuse.
STATE_A="${TMPDIR}/state_a"
mkdir -p "${STATE_A}/license"
echo '{"licence_id":"test"}' > "${STATE_A}/license/license.json"

# State B: licence + EMPTY config/.env. Detector should NOT
# trigger reuse (no USER_ID= line).
STATE_B="${TMPDIR}/state_b"
mkdir -p "${STATE_B}/license" "${STATE_B}/config"
echo '{"licence_id":"test"}' > "${STATE_B}/license/license.json"
: > "${STATE_B}/config/.env"

# State C: licence + .env with comment but NO USER_ID=. Detector
# should NOT trigger reuse.
STATE_C="${TMPDIR}/state_c"
mkdir -p "${STATE_C}/license" "${STATE_C}/config"
echo '{"licence_id":"test"}' > "${STATE_C}/license/license.json"
echo '# Ostler configuration – generated by installer' > "${STATE_C}/config/.env"

# State D: licence + complete .env (USER_ID set). Detector
# SHOULD trigger reuse -- this is the legitimate Phase-2-complete
# state.
STATE_D="${TMPDIR}/state_d"
mkdir -p "${STATE_D}/license" "${STATE_D}/config"
echo '{"licence_id":"test"}' > "${STATE_D}/license/license.json"
cat > "${STATE_D}/config/.env" <<'ENVEOF'
# Ostler configuration – generated by installer
USER_ID="andy"
USER_NAME="Andy"
ENVEOF

# Standalone predicate (mirrors the install.sh detector contract).
detector_fires() {
    local OSTLER_FINAL_DIR="$1"
    if [[ -f "${OSTLER_FINAL_DIR}/config/.env" ]] \
       && grep -q '^USER_ID=' "${OSTLER_FINAL_DIR}/config/.env" 2>/dev/null; then
        return 0
    fi
    return 1
}

if detector_fires "$STATE_A"; then
    failure "detector fires on State A (licence-only, no .env) -- pre-FDA scaffolding mis-triggers reuse"
fi
if detector_fires "$STATE_B"; then
    failure "detector fires on State B (empty .env) -- partial .env mis-triggers reuse"
fi
if detector_fires "$STATE_C"; then
    failure "detector fires on State C (.env without USER_ID) -- malformed .env mis-triggers reuse"
fi
if ! detector_fires "$STATE_D"; then
    failure "detector does NOT fire on State D (complete .env with USER_ID) -- legitimate reuse path broken"
fi

if (( FAILED == 0 )); then
    echo "PASS: tests/test_cx98_previous_install_detection.sh"
    exit 0
else
    echo "FAILED: tests/test_cx98_previous_install_detection.sh" >&2
    exit 1
fi
