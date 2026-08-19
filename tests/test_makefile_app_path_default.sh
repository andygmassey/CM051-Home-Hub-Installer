#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gui/Makefile's OSTLER_APP_PATH default must actually apply (v1018-D668).
#
# THE BUG THIS PINS, which is subtler than the board entry said.
#
# The board said the default "points at the abandoned ~/Documents/Projects
# tree". True, and irrelevant: the default never applied at all. A bare
# `export VAR` DEFINES VAR (origin becomes "file"), and `?=` assigns only to an
# UNDEFINED variable. `export OSTLER_APP_PATH` sat ABOVE the `?=`, so the
# default was dead on every version of this file:
#
#   export FOO / FOO ?= default   ->  origin=file  value=[]         BROKEN
#   FOO ?= default / export FOO   ->  origin=file  value=[default]  WORKS
#
# Measured on GNU Make 3.81, the make macOS ships.
#
# WHY IT MATTERS RATHER THAN BEING A TIDY-UP: `make package` treats a missing
# OSTLER_APP_PATH as NON-FATAL and cuts the DMG anyway. So the failure was a
# silently Hub-less DMG, met by the customer as install.sh's "Ostler.app not
# found" at run time. The Makefile's own error text blames "a parent shell
# exported OSTLER_APP_PATH= (empty string)", misdiagnosing its own bug -- which
# is presumably why it survived this long.
#
# This test asserts the ORDER by asserting the CONSEQUENCE (a non-empty value),
# not by grepping line numbers: a predicate pinned to formatting goes green
# while blind and red while fixed.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GUI_DIR="$REPO_ROOT/gui"

PASSED=0
FAILED=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$*"; PASSED=$((PASSED+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*" >&2; FAILED=$((FAILED+1)); }

command -v make >/dev/null 2>&1 || { echo "make not found" >&2; exit 2; }

# Evaluate the variable the way make itself would, rather than parsing text.
# OSTLER_APP_PATH is deliberately UNSET in this environment: an inherited value
# would mask exactly the defect under test.
eval_var() {
    local mk; mk="$(mktemp -t tnm-appath-XXXXXX)"
    printf 'include Makefile\n_tnm_show:\n\t@printf "%%s" "$(OSTLER_APP_PATH)"\n' > "$mk"
    ( cd "$GUI_DIR" && env -u OSTLER_APP_PATH make -f "$mk" --no-print-directory _tnm_show 2>/dev/null )
    rm -f "$mk"
}

echo "test_makefile_app_path_default"

VALUE="$(eval_var)"

if [[ -n "$VALUE" ]]; then
    ok "default applies (OSTLER_APP_PATH is non-empty with nothing in the env)"
else
    bad "OSTLER_APP_PATH evaluates EMPTY with nothing in the environment.
       The \`?=\` default is not applying. Almost certainly a bare
       \`export OSTLER_APP_PATH\` sits ABOVE the assignment -- that DEFINES the
       variable, and \`?=\` only assigns when undefined. Move the export BELOW."
fi

if [[ "$VALUE" == */Ostler.app ]]; then
    ok "default names an Ostler.app bundle"
else
    bad "expected the default to end in /Ostler.app, got: ${VALUE:-<empty>}"
fi

# Location-independent: derived from this checkout, not from one operator's
# home layout. ~/Documents/Projects is the superseded tree (repos live in
# ~/Developer now) and a home literal is also an operator path in a shipping
# repo.
# Guarded on non-empty: a substring check against "" passes for the wrong
# reason. On the unfixed tree this check went GREEN purely because there was no
# value to inspect -- a vacuous pass, and the same shape as every other gate
# corrected this week.
if [[ -z "$VALUE" ]]; then
    bad "cannot judge the path: the value is empty (see the failure above).
       Reporting this rather than passing on an absent string."
elif [[ "$VALUE" == *"/Documents/Projects/"* ]]; then
    bad "default still points into the superseded ~/Documents/Projects tree:
       $VALUE"
else
    ok "default is not pinned to the superseded Documents/Projects tree"
fi

if [[ "$VALUE" == "$REPO_ROOT"/../* || "$VALUE" == "$(cd "$REPO_ROOT/.." && pwd)"/* ]]; then
    ok "default is derived from this checkout's location (sibling repo)"
else
    bad "default does not resolve beside this checkout; it looks hardcoded:
       repo=$REPO_ROOT
       value=$VALUE"
fi

# --- NEGATIVE CONTROL ------------------------------------------------------
# Everything above could pass against a make that ignores order entirely, or an
# eval_var that silently returns something. Build BOTH orders from scratch and
# require them to DIFFER -- that is what proves this test can see the defect at
# all. Without it the file is a guard-shaped no-op.
CTL_DIR="$(mktemp -d)"
cat > "$CTL_DIR/broken.mk" <<'EOF'
export CTLVAR
CTLVAR ?= a-default
show:
	@printf "%s" "$(CTLVAR)"
EOF
cat > "$CTL_DIR/fixed.mk" <<'EOF'
CTLVAR ?= a-default
export CTLVAR
show:
	@printf "%s" "$(CTLVAR)"
EOF
BROKEN="$(cd "$CTL_DIR" && env -u CTLVAR make -f broken.mk --no-print-directory show 2>/dev/null)"
FIXED="$(cd "$CTL_DIR" && env -u CTLVAR make -f fixed.mk --no-print-directory show 2>/dev/null)"
rm -rf "$CTL_DIR"

if [[ -z "$BROKEN" && "$FIXED" == "a-default" ]]; then
    ok "CONTROL: export-before-?= yields EMPTY, export-after yields the default"
else
    bad "CONTROL FAILED: this make does not reproduce the ordering defect
       (export-first gave '${BROKEN}', export-last gave '${FIXED}').
       Either make changed behaviour or the probe is broken -- either way the
       assertions above prove nothing about ordering."
fi

echo
if (( FAILED == 0 )); then
    printf '\033[32m%s passed, 0 failed\033[0m\n' "$PASSED"
    printf 'OSTLER_APP_PATH default = %s\n' "$VALUE"
    exit 0
else
    printf '\033[31m%s passed, %s FAILED\033[0m\n' "$PASSED" "$FAILED" >&2
    exit 1
fi
