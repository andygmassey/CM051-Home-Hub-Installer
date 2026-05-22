#!/usr/bin/env bash
#
# tests/test_installer_app_bundle_contents.sh
#
# Byte-by-byte regression for the gui/project.yml -> install.sh
# bundling contract. Locked 2026-05-22 after the deep-dive audit
# (CM051_INSTALLER_DEEP_DIVE_FINDINGS_2026-05-22.md) found that
# 10+ install.sh ${SCRIPT_DIR}/X probes had no matching postBuildScript
# and silently warn-skipped on the GUI install path.
#
# This test walks the per-finding fix shape: for each asset that the
# audit flagged, assert that the corresponding postBuildScript entry
# exists in gui/project.yml AND that the install.sh probe still points
# at the bundled path.
#
# The companion CI gate (.github/workflows/install-gui-contract.yml)
# does the full xcodegen + xcodebuild build and asserts the assets
# actually land in Contents/Resources/. That step requires macOS +
# Xcode + signing certs, so this test runs in the lighter pure-bash
# layer that GitHub's ubuntu runners + every developer can execute.
#
# Per locked memory feedback_silent_bail_regression_test_shape: each
# assertion pins the EXACT failure shape the audit flagged. Happy-path
# "does the build green" tests are insufficient.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_YML="${REPO_ROOT}/gui/project.yml"
INSTALL_SCRIPT="${REPO_ROOT}/install.sh"
STRINGS="${REPO_ROOT}/install.sh.strings.en-GB.sh"

for f in "$PROJECT_YML" "$INSTALL_SCRIPT" "$STRINGS"; do
    if [[ ! -f "$f" ]]; then
        echo "FAIL: missing $f" >&2
        exit 1
    fi
done

# 1. install.sh parses (defence-in-depth; the existing test_vane_bundle.sh
#    does the same but we re-check here so a regression in the deep-dive
#    branch surfaces in this test's output rather than another.)
if ! bash -n "$INSTALL_SCRIPT"; then
    echo "FAIL: install.sh fails bash -n parse" >&2
    exit 1
fi
echo "PASS: install.sh parses"

if ! bash -n "$STRINGS"; then
    echo "FAIL: install.sh.strings.en-GB.sh fails bash -n parse" >&2
    exit 1
fi
echo "PASS: strings catalogue parses"

# Helper -- assert a literal string appears in a file.
assert_grep() {
    local label="$1"
    local needle="$2"
    local file="$3"
    if ! grep -qF -- "$needle" "$file"; then
        echo "FAIL [$label]: needle missing in $(basename "$file")" >&2
        echo "  needle: $needle" >&2
        exit 1
    fi
}

# ── F1: assistant-agent postBuildScript present, sources from repo root ──
assert_grep "f1-postbuild-name" \
    "Bundle assistant-agent" \
    "$PROJECT_YML"
assert_grep "f1-postbuild-source" \
    "SRC=\"\${SRCROOT}/../assistant-agent\"" \
    "$PROJECT_YML"
assert_grep "f1-postbuild-dest" \
    "/assistant-agent" \
    "$PROJECT_YML"
assert_grep "f1-install-else-warn" \
    "MSG_WARN_ASSISTANT_AGENT_NOT_BUNDLED_LAUNCHAGENT_SKIPPED" \
    "$INSTALL_SCRIPT"
assert_grep "f1-string-defined" \
    "MSG_WARN_ASSISTANT_AGENT_NOT_BUNDLED_LAUNCHAGENT_SKIPPED=" \
    "$STRINGS"
echo "PASS: F1 (assistant-agent) postBuildScript + else-warn + string entry present"

# ── F2: wiki-recompile postBuildScript present, sources from repo root ──
assert_grep "f2-postbuild-name" \
    "Bundle wiki-recompile" \
    "$PROJECT_YML"
assert_grep "f2-postbuild-source" \
    "SRC=\"\${SRCROOT}/../wiki-recompile\"" \
    "$PROJECT_YML"
assert_grep "f2-install-else-warn" \
    "MSG_WARN_WIKI_RECOMPILE_SCRIPTS_NOT_BUNDLED" \
    "$INSTALL_SCRIPT"
assert_grep "f2-string-defined" \
    "MSG_WARN_WIKI_RECOMPILE_SCRIPTS_NOT_BUNDLED=" \
    "$STRINGS"
echo "PASS: F2 (wiki-recompile) postBuildScript + else-warn + string entry present"

# ── F3: legal Python package postBuildScript, sources from vendor/legal ──
assert_grep "f3-postbuild-name" \
    "Bundle legal Python package" \
    "$PROJECT_YML"
assert_grep "f3-postbuild-source" \
    "SRC=\"\${SRCROOT}/../vendor/legal\"" \
    "$PROJECT_YML"
assert_grep "f3-install-else-warn" \
    "MSG_WARN_LEGAL_PACKAGE_NOT_BUNDLED_CONSENT_DEGRADED" \
    "$INSTALL_SCRIPT"
assert_grep "f3-string-defined" \
    "MSG_WARN_LEGAL_PACKAGE_NOT_BUNDLED_CONSENT_DEGRADED=" \
    "$STRINGS"
# Source-on-disk: vendor/legal/pyproject.toml must exist for the
# postBuildScript to pass its source-side guard.
if [[ ! -f "${REPO_ROOT}/vendor/legal/pyproject.toml" ]]; then
    echo "FAIL [f3-source-vendored]: vendor/legal/pyproject.toml not vendored" >&2
    exit 1
fi
echo "PASS: F3 (legal) postBuildScript + else-warn + string entry + vendor source present"

# ── F4: gws install code path present + SHA256 pinning ──
assert_grep "f4-version-pinned" \
    'GWS_VERSION="0.22.5"' \
    "$INSTALL_SCRIPT"
assert_grep "f4-bin-dest" \
    'GWS_BIN_DEST="/usr/local/bin/gws"' \
    "$INSTALL_SCRIPT"
assert_grep "f4-sha256-arm64" \
    'GWS_SHA256_ARM64="1d2a9ffd5bc9b2c2c4b48630daf082fad13d9e57d741988a2c248eed562f7dac"' \
    "$INSTALL_SCRIPT"
assert_grep "f4-sha256-x86_64" \
    'GWS_SHA256_X86_64="51f9bd731404d4bba26c36e2e30dd68c56dccd1f834c01252cb0b14d6a6544b2"' \
    "$INSTALL_SCRIPT"
assert_grep "f4-progress-step" \
    'progress "Installing Google Workspace CLI' \
    "$INSTALL_SCRIPT"
# Step id registered in canonical order so the GUI sidebar shows the phase.
assert_grep "f4-step-id-canonical" \
    '"gws_install"' \
    "${REPO_ROOT}/gui/OstlerInstaller/Steps/StepCatalog.swift"
echo "PASS: F4 (gws) install code path + SHA256 pinning + step id present"

# ── F5: ical-query.sh wrapper writer present ──
assert_grep "f5-wrapper-path" \
    'ICAL_WRAPPER="${ICAL_WRAPPER_DIR}/ical-query.sh"' \
    "$INSTALL_SCRIPT"
assert_grep "f5-wrapper-chmod" \
    'chmod 755 "$ICAL_WRAPPER"' \
    "$INSTALL_SCRIPT"
# Body sanity: the wrapper must source the customer .env so OSTLER_ICLOUD_*
# vars reach the Python heredoc.
assert_grep "f5-wrapper-env-source" \
    'OSTLER_ICLOUD_USER' \
    "$INSTALL_SCRIPT"
echo "PASS: F5 (ical-query.sh) wrapper writer present"

# ── F6: Safari extension -- DEFERRED (CM020 source needs build pipeline) ──
# Confirm install.sh still has the existing graceful-skip path (the
# .app.zip is bundled by CM020 if its build pipeline is wired in
# release; the audit explicitly left this as a TODO).
assert_grep "f6-existing-skip-path" \
    'EXTENSIONS_BUNDLE="${SCRIPT_DIR}/extensions/OstlerSafariExtension.app.zip"' \
    "$INSTALL_SCRIPT"
echo "PASS: F6 (Safari extension) graceful-skip path unchanged (deferred)"

# ── F7 + F8: LICENSES + THIRD_PARTY_NOTICES.md vendored + postBuildScript ──
assert_grep "f7-postbuild-name" \
    "Bundle LICENSES + THIRD_PARTY_NOTICES.md" \
    "$PROJECT_YML"
assert_grep "f7-postbuild-licenses-src" \
    'LICENSES_SRC="${SRCROOT}/../vendor/LICENSES"' \
    "$PROJECT_YML"
assert_grep "f7-postbuild-notices-src" \
    'NOTICES_SRC="${SRCROOT}/../vendor/THIRD_PARTY_NOTICES.md"' \
    "$PROJECT_YML"
if [[ ! -f "${REPO_ROOT}/vendor/THIRD_PARTY_NOTICES.md" ]]; then
    echo "FAIL [f7-notices-vendored]: vendor/THIRD_PARTY_NOTICES.md not vendored" >&2
    exit 1
fi
if [[ ! -d "${REPO_ROOT}/vendor/LICENSES" ]]; then
    echo "FAIL [f8-licenses-vendored]: vendor/LICENSES/ not vendored" >&2
    exit 1
fi
# Spot-check one canonical licence file landed (MIT.txt is the smallest +
# universally-referenced one).
if [[ ! -f "${REPO_ROOT}/vendor/LICENSES/MIT.txt" ]]; then
    echo "FAIL [f8-mit-license]: vendor/LICENSES/MIT.txt not vendored" >&2
    exit 1
fi
echo "PASS: F7 + F8 (LICENSES + THIRD_PARTY_NOTICES.md) postBuildScript + vendored sources present"

# ── F9: scripts/deferred-register-device.sh postBuildScript ──
assert_grep "f9-postbuild-name" \
    "Bundle scripts/deferred-register-device.sh" \
    "$PROJECT_YML"
assert_grep "f9-postbuild-source" \
    'SRC="${SRCROOT}/../scripts/deferred-register-device.sh"' \
    "$PROJECT_YML"
assert_grep "f9-install-else-warn" \
    "MSG_WARN_DEFERRED_REGISTER_SCRIPT_NOT_BUNDLED_RETRY_DISABLED" \
    "$INSTALL_SCRIPT"
assert_grep "f9-string-defined" \
    "MSG_WARN_DEFERRED_REGISTER_SCRIPT_NOT_BUNDLED_RETRY_DISABLED=" \
    "$STRINGS"
echo "PASS: F9 (deferred-register-device.sh) postBuildScript + else-warn + string entry present"

# ── F10: ostler-import.sh -- DEFERRED (working inline fallback) ──
# Confirm install.sh still has the inline fallback that materialises
# ostler-import without the SCRIPT_DIR/ostler-import.sh dependency.
assert_grep "f10-inline-fallback" \
    'if [[ -f "${SCRIPT_DIR}/ostler-import.sh" ]]; then' \
    "$INSTALL_SCRIPT"
assert_grep "f10-fallback-body" \
    'contact_syncer.import_all' \
    "$INSTALL_SCRIPT"
echo "PASS: F10 (ostler-import.sh) inline fallback still present (deferred)"

echo ""
echo "ALL INSTALLER APP BUNDLE CONTENTS TESTS PASSED"
