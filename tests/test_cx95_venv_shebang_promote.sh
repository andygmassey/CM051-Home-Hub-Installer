#!/usr/bin/env bash
#
# tests/test_cx95_venv_shebang_promote.sh
#
# Byte-walking regression test for the CX-95 launch-blocker fix
# (DMG #48g Studio retest, 2026-05-29).
#
# What the failure looks like (PRE-FIX, must never recur):
#
#   1. install.sh creates the ostler_security venv in
#      ${OSTLER_PRELAUNCH_DIR}/.venv (Phase 2 line ~2605 or
#      Phase 3.6 line ~4906) BEFORE the FDA-grant promote at
#      Phase 3.7 (line ~5281 / ~5415 / ~5435) mv's the staging
#      tree onto ~/.ostler/.
#
#   2. `python -m venv` bakes the absolute creation path into the
#      shebang of every script in bin/ (pip, pip3, pip3.11) AND
#      into pyvenv.cfg's `command = ...` line.
#
#   3. The promote `mv ${OSTLER_PRELAUNCH_DIR}/.venv
#      ${OSTLER_FINAL_DIR}/.venv` preserves file contents but
#      every shebang now points at a /tmp/ostler-prelaunch-<pid>
#      that macOS rm'd seconds earlier.
#
#   4. The next pip invocation (Phase 3.6 sqlcipher3 at line
#      ~4930, or any post-promote $OSTLER_PIP use) hits the
#      kernel's shebang resolver, which checks the interpreter
#      path BEFORE exec'ing the script, and dies with:
#        zsh:1: /Users/<user>/.ostler/.venv/bin/pip:
#          bad interpreter: /tmp/ostler-prelaunch-4490/.venv/bin/python3.11:
#          no such file or directory
#
#   5. install.sh's fail_with_code surface reports ERR-09 and the
#      install aborts.
#
# This test refuses the exact shape that caused the launch-blocker
# per locked memory feedback_silent_bail_regression_test_shape.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILED=0

failure() {
    echo "FAIL: $*" >&2
    FAILED=1
}

# ── Axis 1: install.sh must DEFINE the post-promote repair helper.

INSTALL_SH="$REPO_ROOT/install.sh"
if [[ ! -f "$INSTALL_SH" ]]; then
    failure "install.sh missing -- cannot verify CX-95 fix"
    exit 1
fi

if ! grep -q '^_ostler_repair_venv_after_promote()' "$INSTALL_SH"; then
    failure "install.sh missing _ostler_repair_venv_after_promote() definition"
fi

# ── Axis 2: _ostler_promote_prelaunch_tree must CALL the helper.
#
# Locating the call by name guards against a future refactor that
# moves the helper definition but forgets to wire it into the
# promote function -- which would silently re-open the bug.

if ! awk '
    /^_ostler_promote_prelaunch_tree\(\) \{/ { in_func=1; next }
    /^\}/ && in_func { in_func=0 }
    in_func && /_ostler_repair_venv_after_promote/ { found=1 }
    END { exit found ? 0 : 1 }
' "$INSTALL_SH"; then
    failure "_ostler_promote_prelaunch_tree does not call _ostler_repair_venv_after_promote -- post-promote venv repair never fires"
fi

# ── Axis 3: helper must detect stale shebangs by checking that the
# interpreter path actually exists. A check that only inspects the
# shebang string (without verifying the interpreter resolves) would
# silently miss the failure axis.

if ! grep -q 'if \[\[ ! -x "\$interp" \]\]' "$INSTALL_SH"; then
    failure "_ostler_repair_venv_after_promote does not verify shebang interpreter is executable -- stale shebang detection is wrong shape"
fi

# ── Axis 4: helper must rebuild via `python -m venv`, not in-place
# shebang rewrite (sed). In-place rewrite is brittle for future
# venv-internal files (every pip install adds new shebanged
# console scripts). Rebuild is the only durable fix.

if ! awk '
    /^_ostler_repair_venv_after_promote\(\) \{/ { in_func=1; next }
    /^\}/ && in_func { in_func=0 }
    in_func && /-m venv "\$venv_dir"/ { found=1 }
    END { exit found ? 0 : 1 }
' "$INSTALL_SH"; then
    failure "_ostler_repair_venv_after_promote does not rebuild via 'python -m venv \$venv_dir' -- sed-based shebang rewrite is too brittle"
fi

# ── Axis 5: helper must reinstall the Phase-2 packages
# (ostler_security + legal + sqlcipher3) after rebuild. Skipping
# this would re-open a different launch blocker: post-promote
# `from ostler_security.region import ...` (line ~5070), Phase
# 3.6b consent_cli (line ~5102), and the ical-server FDA
# check (line ~7314) all rely on ostler_security being in the
# venv's site-packages. Deployed services rely on sqlcipher3
# for encrypted DBs at runtime.

if ! awk '
    /^_ostler_repair_venv_after_promote\(\) \{/ { in_func=1; next }
    /^\}/ && in_func { in_func=0 }
    in_func && /ostler_security/ { os_seen=1 }
    in_func && /sqlcipher3/ { sql_seen=1 }
    in_func && /SCRIPT_DIR\}\/legal/ { legal_seen=1 }
    END { exit (os_seen && sql_seen && legal_seen) ? 0 : 1 }
' "$INSTALL_SH"; then
    failure "_ostler_repair_venv_after_promote does not reinstall ostler_security + legal + sqlcipher3 -- post-promote services lose required packages"
fi

# ── Axis 6: end-to-end behavioural test. Source the relevant
# install.sh functions in an isolated env, simulate the promote
# dance with a freshly-created venv in a staging tree, and assert
# the resulting venv's pip shebang points at a python that
# actually exists at the final location.

PYTHON_BIN=""
if command -v python3 &>/dev/null; then
    PYTHON_BIN="$(command -v python3)"
elif [[ -x "/opt/homebrew/opt/python@3.11/bin/python3.11" ]]; then
    PYTHON_BIN="/opt/homebrew/opt/python@3.11/bin/python3.11"
fi

if [[ -z "$PYTHON_BIN" ]]; then
    echo "SKIP: no python3 on PATH; cannot run end-to-end shebang test"
else
    TMP_HOME="$(mktemp -d -t cx95-test-XXXXXX)"
    trap 'rm -rf "$TMP_HOME"' EXIT

    STAGING="${TMP_HOME}/staging"
    FINAL="${TMP_HOME}/final"
    mkdir -p "$STAGING"

    # Create a venv inside the staging tree, mirroring what Phase 2
    # at line 2605 does. The shebangs will bake in the staging path.
    "$PYTHON_BIN" -m venv "${STAGING}/.venv" >/dev/null 2>&1 \
        || { echo "SKIP: python -m venv failed -- cannot run end-to-end test"; rm -rf "$TMP_HOME"; exit 0; }

    PRE_SHEBANG="$(head -n 1 "${STAGING}/.venv/bin/pip")"
    if [[ "$PRE_SHEBANG" != *"${STAGING}"* ]]; then
        failure "test fixture broken: fresh venv shebang does not contain staging path ($PRE_SHEBANG)"
    fi

    # Mv the venv to the final location, simulating the promote.
    # After this mv, the shebang is stale (points at the staging
    # dir, which we now remove). This is exactly the on-disk state
    # the bug surfaces.
    mkdir -p "$FINAL"
    mv "${STAGING}/.venv" "${FINAL}/.venv"
    rm -rf "$STAGING"

    POST_MV_SHEBANG="$(head -n 1 "${FINAL}/.venv/bin/pip")"
    POST_MV_INTERP="${POST_MV_SHEBANG#\#!}"
    if [[ -x "$POST_MV_INTERP" ]]; then
        failure "test fixture broken: post-mv shebang still resolves ($POST_MV_INTERP) -- staging cleanup did not happen"
    fi

    # Source the install.sh helper functions in a subshell with
    # the env vars they expect. SCRIPT_DIR points at the repo so
    # the (optional) reinstall hits real packages. PYTHON3_BIN is
    # set explicitly so the helper does not need to fall back.
    set +e
    (
        # Disable set -u + strict mode so the source can pick up
        # only the functions we need without dragging in every
        # global. We're testing the helper, not the whole script.
        set +eu
        OSTLER_FINAL_DIR="$FINAL"
        OSTLER_PRELAUNCH_DIR="$STAGING"
        OSTLER_PRELAUNCH_PROMOTED=true   # bypass promote walking
        PYTHON3_BIN="$PYTHON_BIN"
        SCRIPT_DIR="$REPO_ROOT"

        # Extract just the helper function body via awk + eval.
        # This avoids sourcing the full install.sh which has
        # side-effects (curl|bash bootstrap, gui_log, etc).
        helper_body="$(awk '
            /^_ostler_repair_venv_after_promote\(\) \{/ { print; in_func=1; next }
            in_func { print }
            in_func && /^\}/ { exit }
        ' "$INSTALL_SH")"
        eval "$helper_body"

        _ostler_repair_venv_after_promote
    )
    HELPER_EXIT=$?
    set -e

    if [[ $HELPER_EXIT -ne 0 ]]; then
        failure "_ostler_repair_venv_after_promote returned non-zero ($HELPER_EXIT)"
    fi

    # Assert the rebuilt venv's pip shebang points at a live python.
    if [[ ! -f "${FINAL}/.venv/bin/pip" ]]; then
        failure "post-repair venv missing bin/pip"
    else
        FINAL_SHEBANG="$(head -n 1 "${FINAL}/.venv/bin/pip")"
        FINAL_INTERP="${FINAL_SHEBANG#\#!}"
        if [[ ! -x "$FINAL_INTERP" ]]; then
            failure "post-repair pip shebang ($FINAL_SHEBANG) does not resolve to a live python -- the exact CX-95 failure shape has recurred"
        fi
        # The repair must bind the shebang to a python under the
        # final-location venv (which is itself a symlink chain to
        # the underlying interpreter). Asserting the shebang string
        # itself contains the final path is the precise check; we
        # canonicalise both sides to handle macOS's /var/folders ->
        # /private/var/folders realpath, and the resolution of any
        # `..` or `//` segments.
        FINAL_REAL="$("$PYTHON_BIN" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$FINAL")"
        # Walk back the shebang interp via dirname to identify the
        # venv root it was minted against; resolving the venv root,
        # not the symlinked interpreter target, isolates the axis
        # the bug surfaces on.
        INTERP_VENV_ROOT="$("$PYTHON_BIN" -c '
import os, sys
p = sys.argv[1]
# bin/python3 -> bin -> venv-root
venv_root = os.path.dirname(os.path.dirname(p))
print(os.path.realpath(venv_root))
' "$FINAL_INTERP")"
        EXPECTED_VENV_ROOT="${FINAL_REAL}/.venv"
        if [[ "$INTERP_VENV_ROOT" != "$EXPECTED_VENV_ROOT" ]]; then
            failure "post-repair pip shebang interp ($FINAL_INTERP) is not anchored to the final venv -- got root '$INTERP_VENV_ROOT', expected '$EXPECTED_VENV_ROOT' -- repair did not rebind to OSTLER_FINAL_DIR"
        fi
    fi

    rm -rf "$TMP_HOME"
    trap - EXIT
fi

if [[ $FAILED -ne 0 ]]; then
    exit 1
fi

echo "PASS: tests/test_cx95_venv_shebang_promote.sh"
