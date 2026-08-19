#!/usr/bin/env bash
#
# tests/test_v1010_redteam3_teamid_pin.sh
#
# RED-TEAM-3 (v1.0.10 security lockdown -- Team-ID designated
# requirement + curl-recovery fail-closed).
#
# THE FINDING: the installer's Gatekeeper staging gates verified a
# bundle was validly signed + Apple-notarised, but NEVER pinned
# Creative Machines' Team ID. `spctl --assess` accepts ANY notarised
# Developer-ID app, so an attacker who notarises their OWN $99 Apple-ID
# malware and can steer a release asset / download URL gets it staged,
# quarantine-stripped, and loaded as a persistent user LaunchAgent.
# Compounded: DEFAULT_ASSISTANT_TARBALL_SHA256 was still the
# REPLACE_AT_RELEASE_TIME sentinel, so the cross-origin SHA pin guard
# was inert this cut.
#
# THE FIX (asserted here):
#   (a) an explicit Team-ID designated requirement (codesign -R with
#       V95N2B8X7A) is present on ALL THREE staging gates -- daemon,
#       RemoteCapture, and Hub .app; and
#   (b) the curl RECOVERY DOWNLOAD path FAILS CLOSED (aborts) while the
#       cross-origin pin is still the REPLACE_AT_RELEASE_TIME sentinel.
#
# The Team-ID designated requirement string was validated empirically
# against the notarised 0.4.34 daemon and the signed Hub Ostler.app
# before this test was written (subject.OU == TeamIdentifier for our
# Developer ID Application cert); a wrong Team ID is rejected. See the
# PR description for the exact `codesign -dv` evidence.
#
# Pure shell + grep/awk. No install run.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${REPO_ROOT}/install.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$INSTALL_SCRIPT" ]] || fail "install.sh not found at $INSTALL_SCRIPT"

TEAM_ID="V95N2B8X7A"

# ─────────────────────────────────────────────────────────────────
# 0. The shared Team-ID designated requirement is defined once, and
#    pins OUR Team ID via the leaf cert's subject.OU.
# ─────────────────────────────────────────────────────────────────
grep -q "OSTLER_TEAM_ID=\"${TEAM_ID}\"" "$INSTALL_SCRIPT" \
    || fail "OSTLER_TEAM_ID is not pinned to ${TEAM_ID}"
grep -q 'OSTLER_CODESIGN_REQ=' "$INSTALL_SCRIPT" \
    || fail "shared OSTLER_CODESIGN_REQ designated-requirement string missing"
grep -q 'certificate leaf\[subject.OU\] = ' "$INSTALL_SCRIPT" \
    || fail "designated requirement does not constrain certificate leaf[subject.OU]"
grep -q 'anchor apple generic' "$INSTALL_SCRIPT" \
    || fail "designated requirement missing 'anchor apple generic'"

# ─────────────────────────────────────────────────────────────────
# 1. All THREE staging gates carry the Team-ID -R requirement.
#    We assert on the codesign invocations that gate each surface.
# ─────────────────────────────────────────────────────────────────

# Gate 1: daemon (_verify_daemon_signature)
grep -Eq 'codesign --verify --deep --strict -R "=\$\{OSTLER_CODESIGN_REQ\}" "\$_bundle"' "$INSTALL_SCRIPT" \
    || fail "GATE 1 (daemon _verify_daemon_signature) missing Team-ID -R requirement"

# Gate 2: RemoteCapture
grep -Eq 'codesign --verify --deep --strict -R "=\$\{OSTLER_CODESIGN_REQ\}" "\$REMOTECAPTURE_APP_PATH"' "$INSTALL_SCRIPT" \
    || fail "GATE 2 (RemoteCapture) missing Team-ID -R requirement"

# Gate 3: Hub .app
grep -Eq 'codesign --verify --deep --strict -R "=\$\{OSTLER_CODESIGN_REQ\}" "\$HUB_APP_DEST"' "$INSTALL_SCRIPT" \
    || fail "GATE 3 (Hub .app) missing Team-ID -R requirement"

# Belt-and-braces: there must be NO bare 'codesign --verify --deep
# --strict "<bundle>"' staging gate left WITHOUT a -R requirement.
# (Count strict-verify staging invocations that lack -R. Only the
# three gated ones above should exist, all WITH -R.)
BARE="$(grep -nE 'codesign --verify --deep --strict "[^"]+"' "$INSTALL_SCRIPT" | grep -v -- '-R ' || true)"
if [[ -n "$BARE" ]]; then
    echo "$BARE" >&2
    fail "found strict-verify staging gate(s) WITHOUT a Team-ID -R requirement (above)"
fi

# The literal Team ID must appear in the enforced requirement path.
grep -q "${TEAM_ID}" "$INSTALL_SCRIPT" \
    || fail "Team ID ${TEAM_ID} not present in install.sh"

# ─────────────────────────────────────────────────────────────────
# 2. Curl RECOVERY DOWNLOAD path FAILS CLOSED on the sentinel.
#    When ASSISTANT_TARBALL_SHA256 is still REPLACE_AT_RELEASE_TIME
#    (or empty), the download branch must ABORT (exit 1), not proceed
#    on same-origin sidecar + notarisation alone.
# ─────────────────────────────────────────────────────────────────

# The download branch has an else on the cross-origin pin guard that
# aborts. Assert the guard's else-branch reaches 'exit 1' with a
# refusal message mentioning the unresolved pin.
grep -q 'curl-recovery download refused' "$INSTALL_SCRIPT" \
    || fail "curl-recovery path does not emit an unresolved-pin refusal message"

# Structural check: within the download branch, the cross-origin pin
# 'if [[ -n ... != REPLACE_AT_RELEASE_TIME ]]' construct now has an
# else that exits. Verify an 'else' + 'exit 1' follows that guard
# before the extraction (tar xzf) step.
awk '
    /ASSISTANT_TARBALL_SHA256" != "REPLACE_AT_RELEASE_TIME"/ { inguard=1 }
    inguard && /^[[:space:]]*else[[:space:]]*$/ { sawelse=1 }
    inguard && sawelse && /exit 1/ { found=1 }
    inguard && /tar xzf/ { inguard=0 }   # left the guard region
    END { exit found?0:1 }
' "$INSTALL_SCRIPT" \
    || fail "curl-recovery cross-origin pin guard has no fail-closed else (exit 1) on the sentinel"

# The DMG-bundled path must NOT be gated by the sentinel abort: the
# comment must make clear the DMG path proceeds on the signature gate.
grep -q 'DMG-bundled' "$INSTALL_SCRIPT" \
    || fail "no note distinguishing the DMG-bundled path from the fail-closed curl path"

# ─────────────────────────────────────────────────────────────────
# 3. The sentinel is STILL the sentinel (this is source control; the
#    ORM pins the real hex at cut assembly). Guard against someone
#    hard-coding a real SHA into DEFAULT_ASSISTANT_TARBALL_SHA256.
# ─────────────────────────────────────────────────────────────────
grep -q 'DEFAULT_ASSISTANT_TARBALL_SHA256="REPLACE_AT_RELEASE_TIME"' "$INSTALL_SCRIPT" \
    || fail "DEFAULT_ASSISTANT_TARBALL_SHA256 is not the REPLACE_AT_RELEASE_TIME sentinel (ORM pins at cut time, not in source)"

# The loud ORM cut-time note must be present near the sentinel.
grep -q 'ORM CUT-TIME ACTION REQUIRED' "$INSTALL_SCRIPT" \
    || fail "loud ORM cut-time pin note missing at the sentinel"

echo "PASS: Team-ID (-R ${TEAM_ID}) requirement on all three staging gates; curl-recovery fails closed on the sentinel; DMG-bundled path preserved; sentinel intact for ORM."
