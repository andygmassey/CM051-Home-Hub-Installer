#!/usr/bin/env bash
# test_ostler_gui_sudo_gates.sh
#
# Regression guard for the 2026-05-22 00:42 HKT Studio retest LAUNCH
# BLOCKER. install.sh's `sudo -v` pre-flight at the start of Phase 3
# fired without a TTY on the GUI subprocess, sudo refused to prompt,
# and the install bailed with:
#
#   [ERROR] Need sudo access to disable sleep + install Homebrew. Re-run when ready.
#   [ERROR] Install finished: fail
#
# Option B (PR #111 / this PR) makes install.sh not require sudo at
# all under OSTLER_GUI=1. The parent .app pre-creates /opt/homebrew
# and /usr/local/bin owned by the user, and spawns its own
# `caffeinate -dimsu` for sleep prevention.
#
# This test walks install.sh BYTE-BY-BYTE and pins the exact failure
# shape: every install-time sudo callsite that previously tripped the
# GUI install MUST be guarded by an `OSTLER_GUI` fork. A future
# contributor adding `sudo X` inside Phase 3 without the fork
# regresses the launch blocker; this test catches that at CI time.
#
# The shape mirrors the locked feedback memory
# `feedback_silent_bail_regression_test_shape`: a byte-walking test
# that refuses any future regression of the EXACT shape that
# produced the failure (an install-time sudo call outside an
# OSTLER_GUI fork), not a happy-path smoke check.

set -u  # not -e: we want to count failures, not bail on the first.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SCRIPT="$(dirname "$SCRIPT_DIR")/install.sh"

if [[ ! -f "$INSTALL_SCRIPT" ]]; then
    echo "FAIL [setup]: install.sh not found at $INSTALL_SCRIPT" >&2
    exit 1
fi

FAILED=0

# ── 1. sudo -v pre-flight gate is OSTLER_GUI-forked ────────────────
#
# Locate the `sudo -v || fail ...$MSG_FAIL_NEED_SUDO_ACCESS_DISABLE_SLEEP_INSTALL`
# line and assert it is inside an `if [[ "${OSTLER_GUI:-0}" != "1" ]]`
# or `else` branch.
#
# Strategy: find the line number, then walk backwards looking for an
# `if [[ "${OSTLER_GUI...` or `else` within ~20 lines. We allow either
# pattern because the Option B implementation uses an
# `if ... == "1"` / `else` shape rather than a negated `!=`.

PREFLIGHT_LINE=$(grep -n 'sudo -v || fail.*MSG_FAIL_NEED_SUDO_ACCESS' "$INSTALL_SCRIPT" | head -1 | cut -d: -f1)
if [[ -z "$PREFLIGHT_LINE" ]]; then
    echo "FAIL [preflight-callsite]: 'sudo -v || fail \$MSG_FAIL_NEED_SUDO_ACCESS_...' line not found" >&2
    FAILED=1
else
    # Look at the 30 lines BEFORE the preflight callsite for an
    # OSTLER_GUI gate.
    WINDOW_START=$((PREFLIGHT_LINE - 30))
    [[ $WINDOW_START -lt 1 ]] && WINDOW_START=1
    if sed -n "${WINDOW_START},${PREFLIGHT_LINE}p" "$INSTALL_SCRIPT" \
            | grep -qE 'if\s*\[\[\s*"\$\{OSTLER_GUI'; then
        echo "PASS [preflight-gate]: sudo -v pre-flight is OSTLER_GUI-forked at line $PREFLIGHT_LINE"
    else
        echo "FAIL [preflight-gate]: sudo -v pre-flight at line $PREFLIGHT_LINE has no OSTLER_GUI gate" >&2
        echo "       This is the EXACT launch-blocker regression from 2026-05-22 00:42 HKT." >&2
        FAILED=1
    fi
fi

# ── 2. 60s sudo keepalive loop is OSTLER_GUI-forked ─────────────────
#
# Same shape, applied to the `sudo -n true 2>/dev/null; sleep 60` loop.
# Under OSTLER_GUI=1 the parent .app handles sleep prevention via
# caffeinate, so this loop is a no-op anyway -- it would just emit a
# stray `sudo -n true` once a minute on the customer's machine for
# the full install window.

KEEPALIVE_LINE=$(grep -n 'sudo -n true.*sleep 60' "$INSTALL_SCRIPT" | head -1 | cut -d: -f1)
if [[ -z "$KEEPALIVE_LINE" ]]; then
    echo "FAIL [keepalive-callsite]: 'sudo -n true ... sleep 60' loop not found" >&2
    FAILED=1
else
    WINDOW_START=$((KEEPALIVE_LINE - 15))
    [[ $WINDOW_START -lt 1 ]] && WINDOW_START=1
    if sed -n "${WINDOW_START},${KEEPALIVE_LINE}p" "$INSTALL_SCRIPT" \
            | grep -qE 'if\s*\[\[\s*"\$\{OSTLER_GUI'; then
        echo "PASS [keepalive-gate]: sudo keepalive loop is OSTLER_GUI-forked at line $KEEPALIVE_LINE"
    else
        echo "FAIL [keepalive-gate]: sudo keepalive loop at line $KEEPALIVE_LINE has no OSTLER_GUI gate" >&2
        FAILED=1
    fi
fi

# ── 3. pmset block is OSTLER_GUI-forked ─────────────────────────────
#
# Under OSTLER_GUI=1 the parent .app holds an IOPMAssertion via
# `caffeinate -dimsu` for the install window; install.sh must not
# attempt `sudo pmset` (which would prompt for password on the
# subprocess's missing TTY and reproduce the launch-blocker shape).

PMSET_LINE=$(grep -n 'sudo pmset -c sleep 0\|sudo pmset -a sleep 0' "$INSTALL_SCRIPT" | head -1 | cut -d: -f1)
if [[ -z "$PMSET_LINE" ]]; then
    echo "FAIL [pmset-callsite]: 'sudo pmset -a/-c sleep 0' line not found" >&2
    FAILED=1
else
    WINDOW_START=$((PMSET_LINE - 25))
    [[ $WINDOW_START -lt 1 ]] && WINDOW_START=1
    if sed -n "${WINDOW_START},${PMSET_LINE}p" "$INSTALL_SCRIPT" \
            | grep -qE 'if\s*\[\[\s*"\$\{OSTLER_GUI'; then
        echo "PASS [pmset-gate]: pmset block is OSTLER_GUI-forked at line $PMSET_LINE"
    else
        echo "FAIL [pmset-gate]: pmset block at line $PMSET_LINE has no OSTLER_GUI gate" >&2
        FAILED=1
    fi
fi

# ── 4. Homebrew install carries NONINTERACTIVE=1 under OSTLER_GUI ──
#
# Homebrew's official installer prompts for sudo password even when
# the prefix is already user-owned, UNLESS NONINTERACTIVE=1 is set.
# On the GUI subprocess that prompt wedges invisibly behind the Log
# drawer (no TTY to read from), reproducing the launch-blocker shape.

BREW_LINE=$(grep -n 'raw.githubusercontent.com/Homebrew' "$INSTALL_SCRIPT" | head -1 | cut -d: -f1)
if [[ -z "$BREW_LINE" ]]; then
    echo "FAIL [brew-callsite]: Homebrew installer URL not found" >&2
    FAILED=1
else
    WINDOW_START=$((BREW_LINE - 10))
    [[ $WINDOW_START -lt 1 ]] && WINDOW_START=1
    WINDOW_END=$((BREW_LINE + 2))
    if sed -n "${WINDOW_START},${WINDOW_END}p" "$INSTALL_SCRIPT" \
            | grep -qE 'NONINTERACTIVE=1.*Homebrew|OSTLER_GUI.*NONINTERACTIVE'; then
        echo "PASS [brew-noninteractive]: Homebrew install carries NONINTERACTIVE=1 under OSTLER_GUI"
    else
        echo "FAIL [brew-noninteractive]: Homebrew install lacks NONINTERACTIVE=1 under OSTLER_GUI" >&2
        echo "       This would reproduce the launch-blocker shape: brew prompts for sudo on a missing TTY." >&2
        FAILED=1
    fi
fi

# ── 5. ostler-knowledge symlink carries an OSTLER_GUI no-sudo branch ─

SYMLINK_LINE=$(grep -n 'ln -sf "\$KNOWLEDGE_BIN" "\$KNOWLEDGE_SYMLINK"' "$INSTALL_SCRIPT" | head -1 | cut -d: -f1)
if [[ -z "$SYMLINK_LINE" ]]; then
    echo "FAIL [symlink-callsite]: ostler-knowledge symlink line not found" >&2
    FAILED=1
else
    WINDOW_START=$((SYMLINK_LINE - 15))
    [[ $WINDOW_START -lt 1 ]] && WINDOW_START=1
    WINDOW_END=$((SYMLINK_LINE + 5))
    if sed -n "${WINDOW_START},${WINDOW_END}p" "$INSTALL_SCRIPT" \
            | grep -qE 'if\s*\[\[\s*"\$\{OSTLER_GUI'; then
        echo "PASS [symlink-gate]: ostler-knowledge symlink is OSTLER_GUI-forked at line $SYMLINK_LINE"
    else
        echo "FAIL [symlink-gate]: ostler-knowledge symlink at line $SYMLINK_LINE has no OSTLER_GUI no-sudo branch" >&2
        FAILED=1
    fi
fi

# ── 6. The launch-blocker fail-string is reachable ONLY when not GUI ─
#
# Byte-walk: scan install.sh for any reference to the launch-blocker
# fail string ($MSG_FAIL_NEED_SUDO_ACCESS_DISABLE_SLEEP_INSTALL) and
# confirm every reference sits inside a `! OSTLER_GUI` fork (i.e. CLI
# only). If a contributor regresses this and adds a new sudo failure
# path under the GUI branch using the same message, this catches it.

FAIL_REFS=$(grep -n 'MSG_FAIL_NEED_SUDO_ACCESS_DISABLE_SLEEP_INSTALL' "$INSTALL_SCRIPT" | grep -v '^[[:digit:]]*:#' || true)
if [[ -z "$FAIL_REFS" ]]; then
    echo "FAIL [fail-msg-refs]: no references to the launch-blocker fail string at all (rename?)" >&2
    FAILED=1
else
    FAIL_REF_LINES=$(echo "$FAIL_REFS" | cut -d: -f1)
    UNGATED_LINES=""
    while read -r REF_LINE; do
        # Skip the catalogue declaration in install.sh.strings.en-GB.sh
        # (not in this file). Find the nearest preceding `if ... OSTLER_GUI`
        # within the same logical block: scan up to 60 lines back and
        # take the most recent `if`. If it gates on OSTLER_GUI=1 (i.e.
        # we are in the CLI branch), pass.
        WINDOW_START=$((REF_LINE - 60))
        [[ $WINDOW_START -lt 1 ]] && WINDOW_START=1
        CONTEXT=$(sed -n "${WINDOW_START},${REF_LINE}p" "$INSTALL_SCRIPT")
        if echo "$CONTEXT" | grep -qE 'else$|if\s*\[\[\s*"\$\{OSTLER_GUI:-0\}"\s*!='; then
            : # in CLI branch -- safe
        else
            UNGATED_LINES+="$REF_LINE "
        fi
    done <<< "$FAIL_REF_LINES"
    if [[ -z "$UNGATED_LINES" ]]; then
        echo "PASS [fail-msg-gating]: every fail-msg reference is CLI-branch only"
    else
        echo "FAIL [fail-msg-gating]: references at lines $UNGATED_LINES are reachable under OSTLER_GUI=1" >&2
        echo "       This regression would reproduce the 2026-05-22 launch blocker." >&2
        FAILED=1
    fi
fi

echo ""
if [[ $FAILED -eq 0 ]]; then
    echo "ALL OSTLER_GUI SUDO-GATE TESTS PASSED"
    exit 0
else
    echo "ONE OR MORE OSTLER_GUI SUDO-GATE TESTS FAILED -- launch-blocker regression risk" >&2
    exit 1
fi
