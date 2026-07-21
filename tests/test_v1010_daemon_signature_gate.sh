#!/usr/bin/env bash
#
# tests/test_v1010_daemon_signature_gate.sh
#
# FIX 1 (v1.0.10 security lockdown -- daemon download integrity).
#
# Locks the invariant that NO daemon (ostler-assistant) is ever
# launched without clearing the SAME codesign --verify --deep --strict
# + spctl --assess --type execute gate that RemoteCapture and
# Ostler.app clear. Pre-v1.0.10 the curl|bash recovery path stripped
# quarantine on ANY valid Mach-O ("unsigned" state) and launched it,
# so an attacker who could serve a tarball + a matching SAME-ORIGIN
# .sha256 sidecar ran arbitrary code as the daemon.
#
# Pure shell + grep. No install run.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${REPO_ROOT}/install.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$INSTALL_SCRIPT" ]] || fail "install.sh not found at $INSTALL_SCRIPT"

# 1. The signature gate helper exists and holds the daemon to BOTH
#    codesign --verify --deep --strict AND spctl --assess --type execute.
grep -q '_verify_daemon_signature()' "$INSTALL_SCRIPT" \
    || fail "_verify_daemon_signature helper missing"
# Both checks must appear inside the helper body (single line, &&-joined).
grep -q 'codesign --verify --deep --strict "\$_bundle"' "$INSTALL_SCRIPT" \
    || fail "daemon gate does not run 'codesign --verify --deep --strict'"
grep -q 'spctl --assess --type execute "\$_bundle"' "$INSTALL_SCRIPT" \
    || fail "daemon gate does not run 'spctl --assess --type execute'"

# 2. A single shared finaliser gates EVERY staging path, and is
#    actually called from all three (bundled .app, bundled bin, curl).
grep -q '_finalise_daemon_staging()' "$INSTALL_SCRIPT" \
    || fail "_finalise_daemon_staging finaliser missing"
CALLS="$(grep -cE '^\s*_finalise_daemon_staging\s*$' "$INSTALL_SCRIPT" || true)"
[[ "$CALLS" -ge 3 ]] \
    || fail "_finalise_daemon_staging called $CALLS times; expected >= 3 (bundled-app, bundled-bin, curl)"

# 3. The vulnerable unsigned-launch path is GONE: no 'unsigned' sign
#    state that strips quarantine and proceeds.
if grep -q 'ASSISTANT_BINARY_SIGN_STATE="unsigned"' "$INSTALL_SCRIPT"; then
    fail "unsigned-launch path still present (ASSISTANT_BINARY_SIGN_STATE=\"unsigned\")"
fi
if grep -q 'MSG_OK_OSTLER_ASSISTANT_V_STAGED_UNSIGNED' "$INSTALL_SCRIPT"; then
    fail "still emits the 'staged unsigned' success message -- unsigned launch path lingers"
fi

# 4. The finaliser hard-fails (exit 1) rather than silently degrading.
#    Confirm the helper body reaches an 'exit 1' on the failure branch.
awk '/_finalise_daemon_staging\(\)/{c=1} c&&/exit 1/{found=1} c&&/^}/{c=0} END{exit found?0:1}' \
    "$INSTALL_SCRIPT" || fail "_finalise_daemon_staging never reaches 'exit 1' on failure"

# 5. Cross-origin pin (baked into install.sh, different origin than
#    the release) exists and is checked against the downloaded sha.
grep -q 'DEFAULT_ASSISTANT_TARBALL_SHA256=' "$INSTALL_SCRIPT" \
    || fail "cross-origin daemon tarball pin (DEFAULT_ASSISTANT_TARBALL_SHA256) missing"
grep -q 'ASSISTANT_TARBALL_SHA256' "$INSTALL_SCRIPT" \
    || fail "cross-origin pin variable ASSISTANT_TARBALL_SHA256 never referenced"

echo "PASS: daemon is gated on codesign + spctl on every staging path; no unsigned-launch path; cross-origin pin present."
