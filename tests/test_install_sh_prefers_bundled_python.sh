#!/usr/bin/env bash
# Regression guard (CX-19, locked 2026-05-23):
# install.sh MUST prefer the bundled python-build-standalone Python over
# any system python3 in its Python-resolution block.
#
# The exact failure shape this refuses:
#   Studio retest #14 (DMG #16, 2026-05-23) on a fresh customer Mac:
#   install.sh runs `python3 --version` early in the QUESTIONS phase.
#   On a stock macOS 15 install (no Command Line Tools, no Homebrew) that
#   hits the /usr/bin/python3 Apple stub which fires the "Install Command
#   Line Tools" GUI dialog and exits non-zero. The brew-install-python
#   fallback also fails because Homebrew is not installed yet. Customer
#   install dies silently mid-step.
#
#   Fix: bundle python-build-standalone Python 3.11 inside the .app and
#   prefer ${SCRIPT_DIR}/python/bin/python3.11 over any system python3.
#
# This test walks install.sh byte-by-byte and asserts that:
#   1. The Python-resolution block tests `[[ -x "$BUNDLED_PYTHON" ]]`
#      BEFORE any `command -v python3` lookup or `brew install python`.
#   2. The bundled-python path string `${SCRIPT_DIR}/python/bin/python3.11`
#      appears literally in install.sh (cannot be silently drift-renamed).
#   3. The MSG_OK_PYTHON_BUNDLED key is referenced inside install.sh.
#
# References:
#   - feedback_silent_bail_regression_test_shape (refuse exact failure shape)
#   - feedback_customer_strings_extractable_from_day_one (Rule 0.9)
#
# Exit 0 on clean. Exit 1 on any drift.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

INSTALL_SH="$REPO_ROOT/install.sh"

if [[ ! -f "$INSTALL_SH" ]]; then
    echo "FAIL: install.sh not found at $INSTALL_SH" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Assertion 1: the bundled-python literal path appears in install.sh.
# ---------------------------------------------------------------------------
BUNDLED_PATH_LITERAL='${SCRIPT_DIR}/python/bin/python3.11'
if ! grep -qF "$BUNDLED_PATH_LITERAL" "$INSTALL_SH"; then
    echo "FAIL: install.sh missing the bundled-python literal path." >&2
    echo "      expected to find: $BUNDLED_PATH_LITERAL" >&2
    echo "      The CX-19 fix bundles python-build-standalone into" >&2
    echo "      OstlerInstaller.app/Contents/Resources/python/ and" >&2
    echo "      install.sh must probe that exact path." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Assertion 2: walk install.sh line-by-line and confirm the bundled-python
# `[[ -x "$BUNDLED_PYTHON" ]]` (or equivalent literal-path) check fires
# BEFORE the system-python `command -v python3` discovery + the
# `brew install python@3.11` fallback.
# ---------------------------------------------------------------------------
# Find the line numbers of:
#   A) the bundled-python existence test
#   B) the first `command -v python3` lookup (system-python discovery)
#   C) the `brew install python@3.11` call (Homebrew fallback)
#
# A must be strictly less than B and C, or the customer install dies on a
# fresh Mac (the exact CX-19 failure shape).

A_LINE=$(grep -nE '^\s*if\s+\[\[\s+-x\s+"\$BUNDLED_PYTHON"' "$INSTALL_SH" \
         | head -1 | cut -d: -f1 || true)
B_LINE=$(grep -nE 'command -v python3' "$INSTALL_SH" \
         | head -1 | cut -d: -f1 || true)
# Anchor on the actual invocation (not a comment) — the call lives inside
# an `if ! brew install python@3.11; then` line in the dev-mode fallback.
C_LINE=$(grep -nE '^\s*if !\s*brew install python@3\.11' "$INSTALL_SH" \
         | head -1 | cut -d: -f1 || true)

if [[ -z "$A_LINE" ]]; then
    echo "FAIL: install.sh missing the bundled-python existence test." >&2
    echo "      Expected an 'if [[ -x \"\$BUNDLED_PYTHON\" ]]' line." >&2
    echo "      This is the CX-19 guard against the fresh-Mac install" >&2
    echo "      failure (no CLT + no Homebrew at QUESTIONS-phase time)." >&2
    exit 1
fi

if [[ -z "$B_LINE" ]]; then
    echo "FAIL: install.sh missing 'command -v python3' lookup." >&2
    echo "      That is the dev-mode fallback path; if it has been" >&2
    echo "      removed, developers running from a sibling clone will" >&2
    echo "      hit an unhandled branch." >&2
    exit 1
fi

if [[ -z "$C_LINE" ]]; then
    echo "FAIL: install.sh missing the 'brew install python@3.11' dev" >&2
    echo "      fallback. That branch is only used in dev mode but must" >&2
    echo "      remain wired so a developer clone still has a recovery" >&2
    echo "      path when system python3 is too old." >&2
    exit 1
fi

if (( A_LINE >= B_LINE )); then
    echo "FAIL: bundled-python check (line $A_LINE) does not come before" >&2
    echo "      the first 'command -v python3' lookup (line $B_LINE)." >&2
    echo "      On a fresh customer Mac, /usr/bin/python3 is the Apple" >&2
    echo "      stub which fires the CLT GUI dialog and exits non-zero." >&2
    echo "      Customer install dies silently. Fix: ensure the bundled-" >&2
    echo "      python branch is the FIRST python-resolution attempt." >&2
    exit 1
fi

if (( A_LINE >= C_LINE )); then
    echo "FAIL: bundled-python check (line $A_LINE) does not come before" >&2
    echo "      'brew install python@3.11' (line $C_LINE). Customers do" >&2
    echo "      not have Homebrew installed when this code runs." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Assertion 3: MSG_OK_PYTHON_BUNDLED is referenced inside install.sh
# (proves the bundled-python success-path actually emits its catalogue key,
# not the system-python MSG_OK_PYTHON).
# ---------------------------------------------------------------------------
if ! grep -q 'MSG_OK_PYTHON_BUNDLED' "$INSTALL_SH"; then
    echo "FAIL: install.sh does not reference MSG_OK_PYTHON_BUNDLED." >&2
    echo "      The bundled-python success branch must emit its own" >&2
    echo "      catalogue key so the GUI can distinguish bundled vs" >&2
    echo "      system Python in the install log." >&2
    exit 1
fi

echo "PASS: install.sh prefers bundled Python (line $A_LINE) before"
echo "      system 'command -v python3' (line $B_LINE) and before"
echo "      'brew install python@3.11' fallback (line $C_LINE)."
echo "PASS: bundled-python literal path \"$BUNDLED_PATH_LITERAL\" present."
echo "PASS: MSG_OK_PYTHON_BUNDLED catalogue key referenced."
