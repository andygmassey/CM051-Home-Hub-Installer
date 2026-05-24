#!/usr/bin/env bash
# Sign every Mach-O inside the bundled Python tree with hardened runtime.
#
# Why: Apple's notary service requires `--options runtime` on every
# Mach-O executable + dylib + .so inside a notarised .app. xcodebuild's
# `--deep` re-sign at archive time signs embedded binaries with the
# Developer ID identity but DOES NOT enable hardened runtime on them
# (only the main app target gets that from xcodebuild build settings).
# notarytool rejects with "The executable does not have the hardened
# runtime enabled" — see DMG #17 submission 4e3721db-aff2-41fc-ae30-dd2e117ffb87.
#
# This script walks the bundled python tree, detects Mach-O files (file
# header magic, not extension), and re-signs each with --options runtime.
# Then re-signs the outer .app via the caller's codesign step so the
# outer signature seals the new inner signatures.
#
# Usage: sign-python-bundle.sh <APP_PATH> <CODESIGN_ID>
#   APP_PATH    Path to the .app being shipped (.../OstlerInstaller.app)
#   CODESIGN_ID Developer ID Application identity string
#
# Exit 0 on clean. Exit 1 on missing dir, no Mach-O files found
# (something is wrong), or any codesign failure.

set -euo pipefail

APP_PATH="${1:?APP_PATH argument required}"
CODESIGN_ID="${2:?CODESIGN_ID argument required}"

PYTHON_DIR="${APP_PATH}/Contents/Resources/python"
if [ ! -d "$PYTHON_DIR" ]; then
    echo "ERROR: Bundled Python not found at $PYTHON_DIR" >&2
    echo "       This script runs as part of 'make ship' AFTER the postBuildScript" >&2
    echo "       has extracted python-build-standalone into Resources/python/." >&2
    exit 1
fi

# CX-30 (2026-05-24, Studio retest #20): the bundled python3.11 is signed
# with hardened runtime (CX-20) but NO entitlements, so library validation
# is ON by default. When pip installs cryptography (transitive dep of
# ostler_security) into the customer venv, cryptography's _rust.abi3.so
# is signed by the cryptography maintainers' Team ID -- DIFFERENT to
# Creative Machines' V95N2B8X7A. Hardened-runtime library validation
# refuses dlopen() across team IDs and the import fails with:
#   "code signature ... not valid for use in process: mapping process
#    and mapped file (non-platform) have different Team IDs"
# Result: install.sh dies silently at encrypt_db (the setup_passphrase
# Python -c block exits 1, but the diagnostic is lost because the
# || block emits via warn() which only renders prefixed [WARN] lines).
#
# Fix: add the entitlement that disables library validation for the
# bundled Python interpreter. The same entitlements file used for the
# OstlerInstaller .app already declares disable-library-validation,
# allow-dyld-environment-variables (needed for venv to set PYTHONPATH),
# and the other minimal-privilege flags. Re-using it keeps a single
# source of truth.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTITLEMENTS="${SCRIPT_DIR}/../OstlerInstaller/OstlerInstaller.entitlements"
if [ ! -f "$ENTITLEMENTS" ]; then
    echo "ERROR: entitlements file not found at $ENTITLEMENTS" >&2
    echo "       Expected: gui/OstlerInstaller/OstlerInstaller.entitlements" >&2
    echo "       Without this the signed Python cannot load third-party C extensions" >&2
    echo "       (cryptography, etc.) on the customer Mac -- install dies at encrypt_db." >&2
    exit 1
fi

echo "Walking $PYTHON_DIR for Mach-O files..."
echo "Entitlements: $ENTITLEMENTS"

SIGNED=0
FAILED=0

while IFS= read -r -d '' f; do
    # file(1) header magic test — works regardless of extension. Catches
    # python3.11 / libpython3.11.dylib / *.so extension modules / any
    # nested binary tools shipped by python-build-standalone.
    if file -b "$f" 2>/dev/null | grep -qE "Mach-O.*(executable|dynamically linked shared library|bundle)"; then
        # CX-30: --entitlements applies library-validation-disabling entitlements
        # to the bundled Python so dlopen() of third-party C extensions
        # (cryptography, sqlcipher3, etc.) does NOT fail with Team ID mismatch
        # at runtime on the customer Mac. Entitlements are only effective on
        # main executables (python3.11), not libraries, but passing them
        # on every codesign call is harmless and keeps the signing flow uniform.
        if codesign --force --sign "$CODESIGN_ID" --options runtime --timestamp --entitlements "$ENTITLEMENTS" "$f" >/dev/null 2>&1; then
            SIGNED=$((SIGNED + 1))
        else
            echo "FAIL: codesign $f" >&2
            FAILED=$((FAILED + 1))
        fi
    fi
done < <(find "$PYTHON_DIR" -type f -print0)

echo "Signed $SIGNED Mach-O files in bundled Python ($FAILED failures)"

if [ "$FAILED" -gt 0 ]; then
    echo "ERROR: $FAILED codesign failures — refusing to ship a partially-signed bundle" >&2
    exit 1
fi

if [ "$SIGNED" -eq 0 ]; then
    echo "ERROR: 0 Mach-O files signed — bundled Python tree is missing binaries" >&2
    echo "       Expected at least python3.11 + libpython3.11.dylib + extension .so files." >&2
    exit 1
fi

echo "OK: all bundled Python Mach-O files signed with hardened runtime."
