#!/usr/bin/env bash
# test_usr_local_bin_symlinks_gui_safe.sh
#
# Regression guard for the 2026-05-23 Studio retest LAUNCH BLOCKER.
# install.sh's `cm048_setup` step ran a naked
#
#     sudo ln -sf "$CM048_BIN" "$CM048_SYMLINK"
#
# at line 4812. Under OSTLER_GUI=1 (Option B, parent .app subprocess)
# there is no TTY for sudo to prompt against; the command failed
# non-interactively, `set -euo pipefail` tripped, and the install bailed
# at exit-1 inside `cm048_setup`.
#
# The fix follows the existing ostler-knowledge pattern at install.sh
# (~line 5591): under OSTLER_GUI=1 a plain `ln -sf` is used because
# /usr/local/bin has already been chowned to the user by the parent
# .app's AuthorizationHelper. Sudo is only invoked in the CLI branch.
#
# This test walks install.sh BYTE-BY-BYTE looking for every site that
# symlinks into /usr/local/bin/. For each such site, it asserts the
# surrounding window contains an `OSTLER_GUI` conditional branch -- i.e.
# a bare `sudo ln -sf "$BIN" /usr/local/bin/...` is forbidden.
#
# Today's sites: pwg-convo (CM048) + ostler-knowledge. A future
# contributor wiring a third /usr/local/bin/ symlink (say
# pwg-resolver, ostler-doctor, etc.) without the OSTLER_GUI fork
# regresses the launch blocker; this test catches that at CI time.
#
# Shape mirrors locked feedback memory
# `feedback_silent_bail_regression_test_shape`: refuse the EXACT failure
# shape, not a happy-path smoke check. Byte-walking variant of the
# pattern already used by test_ostler_gui_sudo_gates.sh.

# Not `set -u` -- we collect into arrays under bash 3.2 (macOS system bash)
# where empty-array expansion under `set -u` is itself an unbound-var error.
# Not `set -e` either: we want to count failures, not bail on the first.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SCRIPT="$(dirname "$SCRIPT_DIR")/install.sh"

if [[ ! -f "$INSTALL_SCRIPT" ]]; then
    echo "FAIL [setup]: install.sh not found at $INSTALL_SCRIPT" >&2
    exit 1
fi

FAILED=0

# ── 1. Discover every /usr/local/bin/ symlink VARIABLE ───────────────
#
# We search for `<NAME>_SYMLINK="/usr/local/bin/<thing>"` declarations.
# Each such variable defines a callsite we must then audit.
#
# bash-3.2 compatible: while-read into an array rather than mapfile.

SYMLINK_VARS=()
SYMLINK_VAR_COUNT=0
SYMLINK_DISCOVERY=$(grep -n '^[A-Z0-9_]*SYMLINK="/usr/local/bin/' "$INSTALL_SCRIPT" || true)

if [[ -z "$SYMLINK_DISCOVERY" ]]; then
    echo "FAIL [discovery]: no /usr/local/bin/ symlink variables found in install.sh" >&2
    echo "       Either the install script no longer wires PATH-side symlinks, or the" >&2
    echo "       declaration shape changed and this test is now stale." >&2
    exit 1
fi

echo "INFO [discovery]: /usr/local/bin/ symlink declarations:"
while IFS= read -r ENTRY; do
    [[ -z "$ENTRY" ]] && continue
    LINE_NO="${ENTRY%%:*}"
    DECL="${ENTRY#*:}"
    VAR_NAME="${DECL%%=*}"
    echo "       line $LINE_NO: $DECL"
    SYMLINK_VARS[$SYMLINK_VAR_COUNT]="$VAR_NAME"
    SYMLINK_VAR_COUNT=$((SYMLINK_VAR_COUNT + 1))
done <<< "$SYMLINK_DISCOVERY"

echo "INFO [discovery]: $SYMLINK_VAR_COUNT total"

# ── 2. For each symlink variable, walk every usage with `ln -sf` ─────
#
# We look for the EXACT bug shape: `sudo ln -sf "$<SOMETHING>" "$<VAR>"`
# (or with the symlink path inlined as a literal). For each match, we
# scan the surrounding window for an `OSTLER_GUI` gate. No gate => fail.

audit_symlink_var() {
    local VAR_NAME="$1"
    local CALLSITES
    # Match any `ln -sf <anything> "$VAR_NAME"`, sudo-prefixed or not.
    # The bug shape and the fix shape both involve `"$VAR_NAME"` as the
    # target argument, so this anchors us at the right callsites.
    CALLSITES=$(grep -nE "ln -sf\s+.*\"\\\$$VAR_NAME\"" "$INSTALL_SCRIPT" || true)

    if [[ -z "$CALLSITES" ]]; then
        echo "WARN [$VAR_NAME]: declared but never used as an ln -sf target -- dead variable?" >&2
        return 0
    fi

    # Track whether at least one `sudo ln -sf ... "$VAR"` site exists
    # AND whether any such bare-sudo site sits outside an OSTLER_GUI
    # gate. Multiple `ln -sf` lines per symlink is fine (the fix shape
    # has both a non-sudo branch and a sudo branch); what matters is
    # that an OSTLER_GUI conditional gates them within ~15 lines.
    local SAW_GATED_BLOCK=0
    while IFS= read -r CALL; do
        local CALL_LINE="${CALL%%:*}"
        # Look at 20 lines BEFORE and 5 lines AFTER the callsite for an
        # OSTLER_GUI conditional. The fix shape's `if [[ "${OSTLER_GUI:-0}"`
        # always sits within 5 lines above the first ln -sf inside the
        # block; the closing `else` + sudo line sits 1-3 lines after.
        local WIN_START=$((CALL_LINE - 20))
        [[ $WIN_START -lt 1 ]] && WIN_START=1
        local WIN_END=$((CALL_LINE + 5))
        local WINDOW
        WINDOW=$(sed -n "${WIN_START},${WIN_END}p" "$INSTALL_SCRIPT")
        if echo "$WINDOW" | grep -qE 'if\s*\[\[\s*"\$\{OSTLER_GUI'; then
            SAW_GATED_BLOCK=1
        fi
    done <<< "$CALLSITES"

    if [[ $SAW_GATED_BLOCK -eq 1 ]]; then
        echo "PASS [$VAR_NAME]: every ln -sf callsite sits in an OSTLER_GUI-gated block"
        return 0
    else
        echo "FAIL [$VAR_NAME]: ln -sf callsite(s) have no OSTLER_GUI gate within +/-20 lines" >&2
        echo "       Offending callsite(s):" >&2
        echo "$CALLSITES" | sed 's/^/         /' >&2
        echo "       This is the EXACT shape of the 2026-05-23 launch-blocker" >&2
        echo "       (cm048_setup crash under OSTLER_GUI=1 on a missing TTY)." >&2
        echo "       Wrap the sudo ln -sf in:" >&2
        echo "         if [[ \"\${OSTLER_GUI:-0}\" == \"1\" ]]; then" >&2
        echo "             ln -sf \"\$BIN\" \"\$$VAR_NAME\" \\" >&2
        echo "                 || sudo ln -sf \"\$BIN\" \"\$$VAR_NAME\"" >&2
        echo "         else" >&2
        echo "             sudo ln -sf \"\$BIN\" \"\$$VAR_NAME\"" >&2
        echo "         fi" >&2
        return 1
    fi
}

IDX=0
while [[ $IDX -lt $SYMLINK_VAR_COUNT ]]; do
    VAR="${SYMLINK_VARS[$IDX]}"
    if ! audit_symlink_var "$VAR"; then
        FAILED=1
    fi
    IDX=$((IDX + 1))
done

# ── 3. Belt-and-braces: refuse a BARE `sudo ln -sf X /usr/local/bin/Y` ─
#
# Even if a future contributor inlines the path literal (skipping the
# `<NAME>_SYMLINK=` declaration and so dodging audit #2 above), we still
# want to catch a bare `sudo ln -sf "$X" /usr/local/bin/Y` not gated by
# OSTLER_GUI. Walk the file linearly.

BARE_SITES_RAW=$(grep -nE 'sudo ln -sf .* /usr/local/bin/' "$INSTALL_SCRIPT" || true)

UNGATED_BARE=""
while IFS= read -r ENTRY; do
    [[ -z "$ENTRY" ]] && continue
    LINE_NO="${ENTRY%%:*}"
    WIN_START=$((LINE_NO - 20))
    [[ $WIN_START -lt 1 ]] && WIN_START=1
    WIN_END=$((LINE_NO + 5))
    WINDOW=$(sed -n "${WIN_START},${WIN_END}p" "$INSTALL_SCRIPT")
    if echo "$WINDOW" | grep -qE 'if\s*\[\[\s*"\$\{OSTLER_GUI'; then
        : # gated -- safe
    else
        UNGATED_BARE+="$LINE_NO "
    fi
done <<< "$BARE_SITES_RAW"

if [[ -n "$UNGATED_BARE" ]]; then
    echo "FAIL [bare-literal]: ungated 'sudo ln -sf ... /usr/local/bin/...' at lines $UNGATED_BARE" >&2
    echo "       (Inline /usr/local/bin/ literal, no OSTLER_GUI fork within +/-20 lines.)" >&2
    FAILED=1
else
    echo "PASS [bare-literal]: no ungated 'sudo ln -sf X /usr/local/bin/Y' literals"
fi

echo ""
if [[ $FAILED -eq 0 ]]; then
    echo "ALL /usr/local/bin/ SYMLINK GUI-SAFE TESTS PASSED"
    exit 0
else
    echo "ONE OR MORE /usr/local/bin/ SYMLINK SITES LACK OSTLER_GUI GATING" >&2
    echo "  -- regression risk for the 2026-05-23 cm048_setup launch blocker." >&2
    exit 1
fi
