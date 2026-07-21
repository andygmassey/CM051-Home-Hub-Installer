#!/usr/bin/env bash
#
# tests/test_daemon_fda_app_bundle_path.sh
#
# DMG #48d -> #48e -> #48f follow-up regression test for PR #201
# (daemon FDA at .app bundle path, v0.4.3 daemon shape).
#
# Byte-walks install.sh asserting the daemon-staging invariants:
#
#   1. ASSISTANT_APP_BUNDLE is the canonical bundle path (~/.ostler/OstlerAssistant.app).
#   2. ASSISTANT_BINARY points at the inner Mach-O inside that bundle.
#   3. ASSISTANT_BINARY_LEGACY exists for TCC-grant carry-over reasons.
#   4. Each staging exit point ends with ASSISTANT_BINARY_INSTALLED=true.
#      Three exit points exist: bundled .app, bundled bare-binary local-wrap,
#      and the converged download path (which handles both downloaded .app and
#      downloaded bare-bin via one sign-state plus --version check).
#   5. Both local-wrap synthesis call sites write the same CFBundleIdentifier
#      (ai.ostler.assistant) so a future upgrade preserves the FDA grant.
#   6. The TCC pre-probe SELECT statement checks BOTH 'ai.ostler.assistant'
#      AND ${ASSISTANT_BINARY_LEGACY} so an upgrade from v0.4.1's bare-binary
#      path resolves the existing grant.
#   7. The launchctl install snippet (assistant-agent/INSTALL_SNIPPET.sh)
#      substitutes ASSISTANT_MACOS_DIR (inside the bundle), not the legacy
#      bare-bin dir, into the rendered launchd plist.
#   8. bash -n parses install.sh + the install snippet cleanly.
#
# WHY THIS TEST EXISTS
#
# PR #201 moved the daemon FDA target from ${OSTLER_DIR}/bin/ostler-assistant
# (legacy v0.4.1 bare binary) to ${OSTLER_DIR}/OstlerAssistant.app/Contents/
# MacOS/ostler-assistant (v0.4.3+ .app bundle wrapping) so macOS TCC, Activity
# Monitor, and the FDA grant dialog render the Ostler v4 oxblood squircle.
#
# Four code paths land the binary: a bundled v0.4.3 .app, a bundled v0.4.1
# bare-bin wrapped locally, a downloaded v0.4.3 tarball, and a downloaded
# v0.4.1 tarball wrapped locally. Per
# feedback_silent_bail_regression_test_shape, the regression test walks the
# assembled install.sh byte-by-byte for the EXACT failure shape (a stray
# fall-through to the bare-bin path that points launchd at a path outside the
# bundle, or a wrap that uses a different CFBundleIdentifier and breaks the
# TCC carry-over) rather than asserting end-to-end "does the daemon launch."
# A future change could re-introduce the fall-through and the happy-path
# launch test would still pass against a fresh fixture.

set -euo pipefail

cd "$(dirname "$0")/.." || exit 99

INSTALL_SH=install.sh
SNIPPET=assistant-agent/INSTALL_SNIPPET.sh

test -f "$INSTALL_SH" || { echo "FAIL: $INSTALL_SH not found from $(pwd)"; exit 99; }
test -f "$SNIPPET" || { echo "FAIL: $SNIPPET not found from $(pwd)"; exit 99; }

# Case 1: ASSISTANT_APP_BUNDLE definition
if ! grep -qE '^ASSISTANT_APP_BUNDLE="\$\{OSTLER_DIR\}/OstlerAssistant\.app"' "$INSTALL_SH"; then
    echo "FAIL [case-1]: ASSISTANT_APP_BUNDLE definition missing or drifted from canonical path"
    grep -nE 'ASSISTANT_APP_BUNDLE=' "$INSTALL_SH" | head -3
    exit 1
fi
echo "PASS [case-1]: ASSISTANT_APP_BUNDLE points at ~/.ostler/OstlerAssistant.app"

# Case 2: ASSISTANT_BINARY points inside the bundle
if ! grep -qE '^ASSISTANT_BINARY="\$\{ASSISTANT_APP_BUNDLE\}/Contents/MacOS/ostler-assistant"' "$INSTALL_SH"; then
    echo "FAIL [case-2]: ASSISTANT_BINARY does not point at the bundle's inner Mach-O"
    grep -nE '^ASSISTANT_BINARY=' "$INSTALL_SH" | head -5
    exit 1
fi
echo "PASS [case-2]: ASSISTANT_BINARY points inside the bundle"

# Case 3: ASSISTANT_BINARY_LEGACY defined for TCC carry-over
if ! grep -qE '^ASSISTANT_BINARY_LEGACY="\$\{OSTLER_DIR\}/bin/ostler-assistant"' "$INSTALL_SH"; then
    echo "FAIL [case-3]: ASSISTANT_BINARY_LEGACY definition missing"
    echo "   the TCC pre-probe needs the legacy path to recognise a pre-v0.4.3 FDA grant"
    grep -nE 'ASSISTANT_BINARY_LEGACY' "$INSTALL_SH" | head -3
    exit 1
fi
echo "PASS [case-3]: ASSISTANT_BINARY_LEGACY definition present"

# Case 4: every staging exit point converges on the shared
# _finalise_daemon_staging fan-in (v1.0.10 security lockdown, PR #419).
# The three staging paths (bundled-.app, bundled-bare-bin-local-wrap,
# converged download) no longer each set ASSISTANT_BINARY_INSTALLED=true
# inline -- they all call _finalise_daemon_staging, which runs the
# codesign + spctl gate and sets ASSISTANT_BINARY_INSTALLED=true in ONE
# place (behaviour preserved, dedup'd). Assert the fan-in exists, is
# called from all three paths, and is the SOLE setter of =true, so a
# future edit cannot re-introduce an ungated inline install.
if ! grep -qE '^_finalise_daemon_staging\(\)' "$INSTALL_SH"; then
    echo "FAIL [case-4a]: shared _finalise_daemon_staging fan-in missing"
    exit 1
fi
FINALISE_CALLS=$(grep -cE '^[[:space:]]*_finalise_daemon_staging[[:space:]]*$' "$INSTALL_SH" || true)
if (( FINALISE_CALLS < 3 )); then
    echo "FAIL [case-4b]: only $FINALISE_CALLS _finalise_daemon_staging call sites; expected >= 3"
    echo "   (one per staging path: bundled-app, bundled-bin-wrap, converged-download)"
    exit 1
fi
# The fan-in is the sole place ASSISTANT_BINARY_INSTALLED is set true.
SET_TRUE_COUNT=$(grep -cE '^[[:space:]]*ASSISTANT_BINARY_INSTALLED=true' "$INSTALL_SH" || true)
if (( SET_TRUE_COUNT != 1 )); then
    echo "FAIL [case-4c]: expected exactly 1 ASSISTANT_BINARY_INSTALLED=true site (inside _finalise_daemon_staging), found $SET_TRUE_COUNT"
    echo "   an inline =true outside the fan-in would bypass the codesign + spctl gate"
    grep -nE '^[[:space:]]*ASSISTANT_BINARY_INSTALLED=true' "$INSTALL_SH"
    exit 1
fi
# And that lone site is inside the fan-in function body.
if ! awk '/^_finalise_daemon_staging\(\)/{c=1} c&&/ASSISTANT_BINARY_INSTALLED=true/{f=1} c&&/^}/{c=0} END{exit f?0:1}' "$INSTALL_SH"; then
    echo "FAIL [case-4d]: the lone ASSISTANT_BINARY_INSTALLED=true is not inside _finalise_daemon_staging"
    exit 1
fi
echo "PASS [case-4]: 3 staging paths converge on _finalise_daemon_staging; it is the sole (gated) ASSISTANT_BINARY_INSTALLED=true setter"

# Case 5: both local-wrap synthesis sites write CFBundleIdentifier = ai.ostler.assistant
# Count the Info.plist heredocs containing the bundle ID.
WRAP_BUNDLE_ID_COUNT=$(grep -cE '<string>ai\.ostler\.assistant</string>' "$INSTALL_SH" || true)
if (( WRAP_BUNDLE_ID_COUNT < 2 )); then
    echo "FAIL [case-5]: only ${WRAP_BUNDLE_ID_COUNT} ai.ostler.assistant CFBundleIdentifier site(s) in install.sh"
    echo "   need >= 2 (bundled-bin local-wrap + downloaded-bin local-wrap)"
    exit 1
fi
echo "PASS [case-5]: ${WRAP_BUNDLE_ID_COUNT} CFBundleIdentifier sites write ai.ostler.assistant"

# Case 6: TCC pre-probe SELECT references BOTH the bundle ID and the legacy binary path
if ! grep -qE "client IN \('ai\.ostler\.assistant', '\\\$\{ASSISTANT_BINARY_LEGACY\}'\)" "$INSTALL_SH"; then
    echo "FAIL [case-6]: TCC pre-probe SQL does not check both bundle ID and \${ASSISTANT_BINARY_LEGACY}"
    echo "   without the legacy path, an upgrade from v0.4.1's bare-bin layout silently loses the FDA grant"
    grep -nE 'client IN' "$INSTALL_SH" | head -3
    exit 1
fi
echo "PASS [case-6]: TCC pre-probe SQL covers both bundle ID and legacy binary path"

# Case 7: INSTALL_SNIPPET.sh uses ASSISTANT_MACOS_DIR (inner-bundle dir), NOT the legacy bin/
if ! grep -qE '^esc_bin="\$\(printf .* "\$ASSISTANT_MACOS_DIR"' "$SNIPPET"; then
    echo "FAIL [case-7]: $SNIPPET 'esc_bin' substitution does not use ASSISTANT_MACOS_DIR"
    echo "   if launchd OSTLER_BIN points at the bare-bin dir instead of the inner-bundle MacOS dir,"
    echo "   TCC reads the legacy bundle ID (or no bundle ID at all) and the FDA icon never resolves"
    grep -nE 'esc_bin=' "$SNIPPET" | head -3
    exit 1
fi
# And confirm it does NOT use OSTLER_DIR/bin (the legacy shape we are moving away from)
if grep -qE 'esc_bin="\$\(printf .* "\$OSTLER_DIR/bin"' "$SNIPPET"; then
    echo "FAIL [case-7b]: $SNIPPET still substitutes the legacy \$OSTLER_DIR/bin into OSTLER_BIN"
    exit 1
fi
echo "PASS [case-7]: launchctl snippet substitutes ASSISTANT_MACOS_DIR into OSTLER_BIN"

# Case 8: bash -n
if ! bash -n "$INSTALL_SH" 2>/dev/null; then
    echo "FAIL [case-8a]: bash -n $INSTALL_SH failed"
    bash -n "$INSTALL_SH"
    exit 1
fi
if ! bash -n "$SNIPPET" 2>/dev/null; then
    echo "FAIL [case-8b]: bash -n $SNIPPET failed"
    bash -n "$SNIPPET"
    exit 1
fi
echo "PASS [case-8]: bash -n install.sh + install snippet both clean"

echo ""
echo "ALL DAEMON FDA APP BUNDLE PATH INVARIANTS LOCKED"
