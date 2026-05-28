#!/usr/bin/env bash
#
# tests/test_cx30_33_python_library_validation_entitlement.sh
#
# Launch-week regression test for CX-30 + CX-33 (Studio retest #20,
# commit 12c9cfd, 2026-05-24).
#
# The fix surface lives in the build pipeline (gui/) rather than
# install.sh, but the failure mode is the same silent-bail shape the
# silent-fail audit memory targets:
#
#   - CX-20 hardened-runtime-signed bundled python3.11 with NO
#     entitlements, so library-validation defaulted to ON.
#   - The customer venv's cryptography (transitive dep of
#     ostler_security) ships a _rust.abi3.so signed by the upstream
#     maintainers' Team ID, different from V95N2B8X7A.
#   - hardened-runtime library-validation refused dlopen() across team
#     IDs. The Python heredoc failed with "code signature not valid
#     for use in process: mapping process and mapped file have
#     different Team IDs".
#   - install.sh's setup_passphrase block reported via warn() (not
#     err()) so the install completed with only a warning, and the
#     customer hit `encrypt_db` failure with no actionable diagnostic.
#
# CX-30 added `--entitlements OstlerInstaller.entitlements` to every
# codesign call inside gui/scripts/sign-python-bundle.sh.
# CX-33 added `--entitlements` to the OUTER `--force --deep` re-sign
# in gui/Makefile so the deep re-sign does not strip the entitlement
# CX-30 just applied to python3.11.
#
# Per feedback_silent_bail_regression_test_shape, this walks the
# build pipeline byte-by-byte asserting the EXACT failure shape
# (a codesign call without --entitlements, or the entitlements file
# missing the disable-library-validation key) cannot re-introduce
# itself. The post-sign verify gate in Makefile is a runtime
# guardrail; this is the CI guardrail that catches a PR before it
# ever reaches `make ship`.

set -euo pipefail

cd "$(dirname "$0")/.." || exit 99

SIGN_SCRIPT=gui/scripts/sign-python-bundle.sh
ENTITLEMENTS=gui/OstlerInstaller/OstlerInstaller.entitlements
MAKEFILE=gui/Makefile

for f in "$SIGN_SCRIPT" "$ENTITLEMENTS" "$MAKEFILE"; do
    test -f "$f" || { echo "FAIL: $f not found from $(pwd)"; exit 99; }
done

# Case 1: sign-python-bundle.sh resolves an ENTITLEMENTS file path and
# refuses to continue if the file is missing.
if ! grep -qE '^ENTITLEMENTS=' "$SIGN_SCRIPT"; then
    echo "FAIL [case-1a]: sign-python-bundle.sh does not define ENTITLEMENTS variable"
    exit 1
fi
if ! grep -qE 'if \[ ! -f "\$ENTITLEMENTS" \]' "$SIGN_SCRIPT"; then
    echo "FAIL [case-1b]: sign-python-bundle.sh does not hard-fail on missing entitlements file"
    echo "   without the hard-fail, a missing entitlements file would silently sign python3.11"
    echo "   without disable-library-validation and the customer install would die at encrypt_db"
    exit 1
fi
echo "PASS [case-1]: sign-python-bundle.sh resolves + hard-fails on missing entitlements file"

# Case 2: every codesign call inside sign-python-bundle.sh's signing loop
# passes --entitlements. Walks each codesign invocation (excluding the
# verify ones) and asserts --entitlements is present.
# A bare `codesign --force --sign ... --options runtime --timestamp <f>`
# without --entitlements would re-introduce CX-30 exactly.
CODESIGN_SIGN_LINES=$(grep -nE 'codesign --force --sign' "$SIGN_SCRIPT" || true)
if [[ -z "$CODESIGN_SIGN_LINES" ]]; then
    echo "FAIL [case-2a]: sign-python-bundle.sh has no codesign --force --sign call"
    exit 1
fi
while IFS= read -r match; do
    line_no="${match%%:*}"
    line_body="${match#*:}"
    if ! echo "$line_body" | grep -qE '\-\-entitlements'; then
        echo "FAIL [case-2b]: codesign signing call at $SIGN_SCRIPT:$line_no missing --entitlements"
        echo "   line: $line_body"
        exit 1
    fi
done <<< "$CODESIGN_SIGN_LINES"
echo "PASS [case-2]: every codesign --force --sign in $SIGN_SCRIPT passes --entitlements"

# Case 3: OstlerInstaller.entitlements file contains
# com.apple.security.cs.disable-library-validation set to <true/>.
# CX-30 depends on this exact key being present and true. Without it,
# the entitlements file becomes a no-op for the library-validation axis.
if ! awk '
    /<key>com\.apple\.security\.cs\.disable-library-validation<\/key>/ {
        getline next_line
        if (next_line ~ /<true\/>/) {
            print "OK"
            exit
        } else {
            print "FAIL_NOT_TRUE"
            exit
        }
    }
' "$ENTITLEMENTS" | grep -qE '^OK$'; then
    echo "FAIL [case-3]: $ENTITLEMENTS missing or false for com.apple.security.cs.disable-library-validation"
    echo "   without this, the bundled python3.11 cannot dlopen() third-party C extensions"
    echo "   (cryptography, sqlcipher3) signed by other Team IDs, and install dies at encrypt_db"
    exit 1
fi
echo "PASS [case-3]: $ENTITLEMENTS has disable-library-validation = true"

# Case 4: gui/Makefile sign-python-bundle target re-signs the outer .app
# with --entitlements. CX-33 found that a deep re-sign without
# --entitlements strips CX-30's fix from the inner python3.11 binary.
# The Makefile target's re-sign line is the recurrence vector.
MAKEFILE_RESIGN_LINE=$(awk '/sign-python-bundle:/,/^$/' "$MAKEFILE" | grep -E 'codesign --force --deep --sign' || true)
if [[ -z "$MAKEFILE_RESIGN_LINE" ]]; then
    echo "FAIL [case-4a]: gui/Makefile sign-python-bundle target has no outer --force --deep re-sign line"
    exit 1
fi
if ! echo "$MAKEFILE_RESIGN_LINE" | grep -qE '\-\-entitlements'; then
    echo "FAIL [case-4b]: gui/Makefile outer re-sign call missing --entitlements"
    echo "   line: $MAKEFILE_RESIGN_LINE"
    echo "   without --entitlements, --force --deep re-sign STRIPS the entitlement"
    echo "   sign-python-bundle.sh just applied to python3.11. CX-33 specifically locked this."
    exit 1
fi
echo "PASS [case-4]: gui/Makefile outer --force --deep re-sign passes --entitlements"

# Case 5: gui/Makefile sign-python-bundle target ends with a post-sign
# verify that exits 1 if disable-library-validation is missing from
# python3.11. The verify is the build-time guardrail; this case asserts
# the guardrail is present and the failure-mode message is intact.
if ! awk '/sign-python-bundle:/,/^$/' "$MAKEFILE" | grep -qE 'disable-library-validation MISSING from python3.11'; then
    echo "FAIL [case-5]: gui/Makefile post-sign verify gate missing the disable-library-validation MISSING error path"
    exit 1
fi
echo "PASS [case-5]: gui/Makefile post-sign verify gate present and intact"

# Case 6: bash -n
if ! bash -n "$SIGN_SCRIPT" 2>/dev/null; then
    echo "FAIL [case-6]: bash -n $SIGN_SCRIPT failed"
    bash -n "$SIGN_SCRIPT"
    exit 1
fi
echo "PASS [case-6]: bash -n sign-python-bundle.sh clean"

echo ""
echo "ALL CX-30 + CX-33 PYTHON LIBRARY VALIDATION ENTITLEMENT TESTS PASSED"
