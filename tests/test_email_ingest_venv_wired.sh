#!/usr/bin/env bash
#
# test_email_ingest_venv_wired.sh
#
# Byte-walking regression test for the CX-17 email-ingest venv fix
# (retest 2026-05-23). Refuses the exact failure shape that caused
# the launch-blocker: a customer install where the email-ingest
# LaunchAgent invokes the system python3 to import ostler_fda,
# hitting ModuleNotFoundError on the first RunAtLoad tick.
#
# What the failure looks like (PRE-FIX, must never recur):
#   1. install.sh has NO venv-creation block for email-ingest before
#      sourcing the bundled snippet
#   2. plist has NO EnvironmentVariables.OSTLER_PYTHON pointing at
#      a venv python
#   3. INSTALL_SNIPPET.sh has NO sed-substitution rendering
#      OSTLER_PYTHON_PATH into the plist
#   4. vendor/ostler_fda/ has NO pyproject.toml so pip install is
#      impossible
#
# All four axes must be wired. The test refuses any regression on
# any one of them per locked memory feedback_silent_bail_regression
# _test_shape.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILED=0

failure() {
    echo "FAIL: $*" >&2
    FAILED=1
}

# Axis 1: vendor/ostler_fda must be pip-installable
PYPROJECT="$REPO_ROOT/vendor/ostler_fda/pyproject.toml"
if [[ ! -f "$PYPROJECT" ]]; then
    failure "vendor/ostler_fda/pyproject.toml missing — pip install is impossible"
fi
if ! grep -q 'name = "ostler-fda"' "$PYPROJECT" 2>/dev/null; then
    failure "vendor/ostler_fda/pyproject.toml missing 'name = \"ostler-fda\"' — pip will not know what to install"
fi
if ! grep -q 'packages = \["ostler_fda"\]' "$PYPROJECT" 2>/dev/null; then
    failure "vendor/ostler_fda/pyproject.toml missing 'packages = [\"ostler_fda\"]' — setuptools will not produce an importable ostler_fda module"
fi

# Axis 2: install.sh must create a venv + pip install ostler_fda
# BEFORE the email-ingest snippet runs.
INSTALL_SH="$REPO_ROOT/install.sh"
if [[ ! -f "$INSTALL_SH" ]]; then
    failure "install.sh missing — cannot verify venv wiring"
else
    if ! grep -q 'EMAIL_INGEST_VENV=' "$INSTALL_SH"; then
        failure "install.sh missing EMAIL_INGEST_VENV variable — venv setup not wired"
    fi
    if ! grep -q 'EMAIL_INGEST_VENV_PYTHON=' "$INSTALL_SH"; then
        failure "install.sh missing EMAIL_INGEST_VENV_PYTHON variable — venv python path not exported"
    fi
    if ! grep -q 'pip" install .*ostler_fda\|pip" install .*OSTLER_FDA_SRC' "$INSTALL_SH"; then
        failure "install.sh does not pip-install ostler_fda into the email-ingest venv"
    fi
    if ! grep -q 'OSTLER_VENV_PYTHON=' "$INSTALL_SH"; then
        failure "install.sh does not pass OSTLER_VENV_PYTHON env to the email-ingest snippet"
    fi

    # Axis 2b: the venv setup must come BEFORE the snippet sources.
    # Use line numbers to verify ordering.
    venv_line=$(grep -n 'EMAIL_INGEST_VENV_PYTHON=' "$INSTALL_SH" | head -1 | cut -d: -f1)
    snippet_line=$(grep -n 'bash "\$EMAIL_INGEST_SNIPPET"' "$INSTALL_SH" | head -1 | cut -d: -f1)
    if [[ -n "$venv_line" && -n "$snippet_line" ]] && [[ "$venv_line" -gt "$snippet_line" ]]; then
        failure "install.sh venv setup (line $venv_line) comes AFTER snippet sourcing (line $snippet_line) — LaunchAgent will fire before venv exists"
    fi
fi

# Axis 3: plist must declare EnvironmentVariables.OSTLER_PYTHON
PLIST="$REPO_ROOT/vendor/email_ingest/launchd/com.creativemachines.ostler.email-ingest.plist"
if [[ ! -f "$PLIST" ]]; then
    failure "email-ingest plist missing"
else
    if ! grep -q '<key>EnvironmentVariables</key>' "$PLIST"; then
        failure "email-ingest plist missing EnvironmentVariables block"
    fi
    if ! grep -q '<key>OSTLER_PYTHON</key>' "$PLIST"; then
        failure "email-ingest plist missing OSTLER_PYTHON env var"
    fi
    if ! grep -q '<string>OSTLER_PYTHON_PATH</string>' "$PLIST"; then
        failure "email-ingest plist missing OSTLER_PYTHON_PATH placeholder (rendered by INSTALL_SNIPPET.sh)"
    fi
fi

# Axis 4: INSTALL_SNIPPET.sh must sed-substitute OSTLER_PYTHON_PATH
SNIPPET="$REPO_ROOT/vendor/email_ingest/INSTALL_SNIPPET.sh"
if [[ ! -f "$SNIPPET" ]]; then
    failure "email-ingest INSTALL_SNIPPET.sh missing"
else
    if ! grep -q 'OSTLER_VENV_PYTHON' "$SNIPPET"; then
        failure "INSTALL_SNIPPET.sh does not consume OSTLER_VENV_PYTHON env var from install.sh"
    fi
    if ! grep -q 's/OSTLER_PYTHON_PATH/' "$SNIPPET"; then
        failure "INSTALL_SNIPPET.sh missing sed substitution for OSTLER_PYTHON_PATH — placeholder will reach launchd unrendered"
    fi
fi

# Axis 5: no LaunchAgent plist anywhere should call a python module
# without staging OSTLER_PYTHON through EnvironmentVariables.
# Specifically refuse the pattern "<string>python3</string>" followed
# by a ProgramArguments invocation of any ostler-prefixed module.
# (Defensive — currently we only have the one plist, but this catches
# future agents that get added in similar shape.)
for plist in $(find "$REPO_ROOT/vendor" -name '*.plist' 2>/dev/null); do
    if grep -q 'ostler_fda\|ostler_security\|ostler-fda\|ostler-security' "$plist"; then
        if ! grep -q '<key>EnvironmentVariables</key>' "$plist"; then
            failure "$plist references ostler_fda/security module but has no EnvironmentVariables block — will fall through to system python"
        fi
    fi
done

if [[ "$FAILED" -eq 0 ]]; then
    echo "PASS: email-ingest venv wiring is byte-correct across all 5 axes"
    exit 0
else
    echo "" >&2
    echo "Regression test failed. The CX-17 fix (retest 2026-05-23) is incomplete on at least one axis." >&2
    echo "See vendor/email_ingest/INSTALL_SNIPPET.sh + install.sh email-ingest section + the plist." >&2
    exit 1
fi
