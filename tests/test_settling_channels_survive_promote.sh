#!/usr/bin/env bash
#
# test_settling_channels_survive_promote.sh (CM051 #3426 follow-up)
#
# #3426 bundled lib/settling_channels.json and install.sh copied it to
# "${HOME}/.ostler/state/". The v1.0.129 walk box had no such file and the wiki
# compiler logged "settling channel manifest ABSENT at /state/settling_channels.json".
# Cause: Phase 2 writes into a staging tree (OSTLER_DIR) and
# _ostler_promote_prelaunch_tree replaces each top-level entry of the final tree,
# state/ included, so a write straight to ${HOME}/.ostler/state is deleted.
#
# This runs the REAL install.sh write line and the REAL promote function against
# a temp HOME with synthetic data, then compares the installed bytes with
# lib/settling_channels.json. Exit 0 PASS, 1 FAIL, 2 CANNOT-RUN.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
SRC="$REPO_ROOT/lib/settling_channels.json"
cannot_run() { echo "CANNOT-RUN: $*" >&2; exit 2; }

[ -f "$INSTALL_SH" ] && [ -f "$SRC" ] || cannot_run "install.sh or lib/settling_channels.json missing"
PROMOTE_FN="$(awk '/^_ostler_promote_prelaunch_tree\(\) \{$/{f=1} f{print} f&&/^\}$/{exit}' "$INSTALL_SH")"
[ "$(printf '%s\n' "$PROMOTE_FN" | grep -c .)" -ge 20 ] || cannot_run "could not extract the promote function"
WRITE_LINE="$(grep -F 'lib/settling_channels.json" "' "$INSTALL_SH" | grep -F 'cp ' | head -1)"
[ -n "$WRITE_LINE" ] || cannot_run "no settling_channels.json write line in install.sh"

SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT
FAKE_HOME="$SANDBOX/home"; FINAL="$FAKE_HOME/.ostler"; STAGING="$SANDBOX/ostler-prelaunch-test"
mkdir -p "$FINAL/state" "$STAGING/state"
# A staged state/ file is what makes state/ a top-level entry the promote replaces.
echo '{}' > "$STAGING/state/pipeline_signals.json"

# Run the write line as install.sh does: SCRIPT_DIR is the bundle, OSTLER_DIR is staging.
HOME="$FAKE_HOME" SCRIPT_DIR="$REPO_ROOT" OSTLER_DIR="$STAGING" bash -c "$WRITE_LINE" >/dev/null 2>&1

HOME="$FAKE_HOME" bash -c '
    set -uo pipefail
    OSTLER_FINAL_DIR="$1"; OSTLER_PRELAUNCH_DIR="$2"; OSTLER_DIR="$2"; OSTLER_PRELAUNCH_PROMOTED=false
    _ostler_quiesce_interval_agents() { :; }
    _ostler_set_paths() { OSTLER_DIR="$1"; }
    _ostler_repair_venv_after_promote() { :; }
    _ostler_promote_venv_note() { :; }
    eval "$3"
    _ostler_promote_prelaunch_tree
' _ "$FINAL" "$STAGING" "$PROMOTE_FN" >/dev/null 2>&1

# Control: the staged sibling must have arrived, or the harness cannot see a success.
[ -f "$FINAL/state/pipeline_signals.json" ] || cannot_run "staged state/pipeline_signals.json did not arrive; promote did not run"

DST="$FINAL/state/settling_channels.json"
if [ -f "$DST" ] && cmp -s "$SRC" "$DST"; then
    echo "PASS: $DST present after promote, bytes identical to lib/settling_channels.json"
    exit 0
fi
echo "FAIL: $DST missing or differs after the promote. install.sh writes it to a path the promote deletes; write it to \${OSTLER_DIR}/state." >&2
exit 1
