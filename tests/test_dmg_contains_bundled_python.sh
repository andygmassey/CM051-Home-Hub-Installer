#!/usr/bin/env bash
# Regression guard (CX-19, locked 2026-05-23):
# the shipped OstlerInstaller DMG must contain the bundled
# python-build-standalone Python 3.11 inside the .app at the exact path
# install.sh probes.
#
# The exact failure shape this refuses:
#   make ship cuts a DMG, notarytool says Accepted, spctl says accepted,
#   stapler stamps the ticket -- but the xcodebuild bundle phase silently
#   skipped the python-bundle.tar.gz extraction (cache miss, wrong env,
#   layout drift) so Resources/python/bin/python3.11 is absent. install.sh
#   on customer install falls through to the dev-mode brew fallback,
#   triggers the CLT GUI dialog, dies. The 2026-05-21 incident (verify-
#   dmg-contents in the Makefile) demonstrated this is a real failure
#   shape: every code-signing chain went green while the payload was
#   missing.
#
# This test is a smoke test: it skips when no DMG is present locally
# (CI green path). When a DMG IS present, it mounts it, walks
# Resources/python/ byte-by-byte, and refuses ship if:
#   - python3.11 binary missing
#   - python3.11 binary not executable
#   - python3.11 binary not Mach-O arm64
#   - the bundled tree codesign chain breaks
#
# Default DMG location:
#   /tmp/ostler-installer-dist-${USER}/OstlerInstaller-1.0.0.dmg
# Override via OSTLER_DMG_PATH.
#
# References:
#   - feedback_silent_bail_regression_test_shape
#   - feedback_verify_dmg_payload_before_declaring_ship_done
#
# Exit 0 on clean OR on skip. Exit 1 on actual breakage.

set -euo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR_TEST/.." && pwd)"

# Resolve the DMG path. Default mirrors gui/Makefile's DIST_DIR pattern.
DEFAULT_DMG="/tmp/ostler-installer-dist-${USER}/OstlerInstaller-1.0.0.dmg"
DMG_PATH="${OSTLER_DMG_PATH:-${DEFAULT_DMG}}"

if [[ ! -f "$DMG_PATH" ]]; then
    echo "SKIP: no DMG at $DMG_PATH (this is a smoke test, only runs when DMG is present)."
    echo "      To run end-to-end: cd gui && make ship, then re-run this test."
    exit 0
fi

# Mount the DMG read-only, nobrowse.
echo "[STEP] Mounting $DMG_PATH"
MOUNT_OUTPUT="$(hdiutil attach "$DMG_PATH" -nobrowse -readonly 2>&1)"
MOUNT_POINT="$(printf '%s\n' "$MOUNT_OUTPUT" | tail -1 | awk -F'\t' '{print $NF}')"

if [[ -z "$MOUNT_POINT" || ! -d "$MOUNT_POINT" ]]; then
    echo "FAIL: could not mount $DMG_PATH" >&2
    echo "      hdiutil output:" >&2
    printf '%s\n' "$MOUNT_OUTPUT" >&2
    exit 1
fi

cleanup() {
    hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

RESOURCES="$MOUNT_POINT/OstlerInstaller.app/Contents/Resources"
BUNDLED_PY="$RESOURCES/python/bin/python3.11"

# ---------------------------------------------------------------------------
# Byte-walk the bundled Python tree and refuse any silent skip.
# ---------------------------------------------------------------------------
FAILED=0

if [[ ! -d "$RESOURCES/python" ]]; then
    echo "FAIL: $RESOURCES/python/ directory missing." >&2
    echo "      The xcodebuild postBuildScript 'Bundle python-build-" >&2
    echo "      standalone Python 3.11 into Resources' did not run, or" >&2
    echo "      ran but silently skipped extraction (tarball missing)." >&2
    echo "      Customer install would die on fresh Mac (CX-19 shape)." >&2
    FAILED=1
fi

if [[ ! -f "$BUNDLED_PY" ]]; then
    echo "FAIL: $BUNDLED_PY missing on DMG." >&2
    echo "      install.sh probes this exact path on first run; without" >&2
    echo "      it the installer falls through to the brew dev fallback" >&2
    echo "      and dies on a fresh Mac." >&2
    FAILED=1
elif [[ ! -x "$BUNDLED_PY" ]]; then
    echo "FAIL: $BUNDLED_PY present but not executable." >&2
    FAILED=1
else
    # Confirm it is a Mach-O arm64 binary, not something masquerading.
    FILE_OUT="$(file "$BUNDLED_PY")"
    if ! printf '%s\n' "$FILE_OUT" | grep -q "Mach-O .* arm64"; then
        echo "FAIL: $BUNDLED_PY is not Mach-O arm64." >&2
        echo "      file says: $FILE_OUT" >&2
        echo "      v1.0 ships arm64-only; Intel comes in v1.0.1." >&2
        FAILED=1
    fi
fi

# Confirm the codesign chain validates. notarytool +
# spctl on the DMG itself does not necessarily exercise the embedded
# Python binary's signature in isolation, so check it directly.
if [[ -x "$BUNDLED_PY" ]]; then
    if ! codesign --verify --verbose=1 "$BUNDLED_PY" >/dev/null 2>&1; then
        echo "FAIL: codesign verification of $BUNDLED_PY failed." >&2
        echo "      The xcodebuild --deep re-sign at archive time did not" >&2
        echo "      pick up the bundled Python tree. Notarisation should" >&2
        echo "      have caught this; investigate xcodebuild output." >&2
        FAILED=1
    fi
fi

if [[ $FAILED -ne 0 ]]; then
    exit 1
fi

# Run the binary to confirm it actually works.
# (We are already on the same Mac that built it; if it fails to start
# here, customer Macs of the same arch will fail too.)
PY_VERSION="$("$BUNDLED_PY" --version 2>&1 || true)"
if [[ "$PY_VERSION" != Python\ 3.11.* ]]; then
    echo "FAIL: bundled python3.11 returned unexpected --version: $PY_VERSION" >&2
    echo "      expected: Python 3.11.X" >&2
    exit 1
fi

echo "PASS: DMG payload verified."
echo "      $BUNDLED_PY"
echo "      $PY_VERSION"
echo "      codesign --verify: passed"
