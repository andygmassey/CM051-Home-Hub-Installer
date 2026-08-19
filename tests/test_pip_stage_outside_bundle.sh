#!/usr/bin/env bash
# _ostler_pip_install_pkg must never let pip build inside the signed bundle
# ========================================================================
#
# Behavioural test. Extracts the REAL helper from install.sh and executes it,
# so it cannot pass against a copy of the logic.
#
# THE DEFECT, measured on the v1.0.32 box 2026-08-16:
#
#     spctl -a -vv /Applications/OstlerInstaller.app
#       -> "a sealed resource is missing or invalid"     rc=1
#     codesign --verify --deep --strict  -> 346 unsealed files
#     263 of them written DURING the install window
#
# `pip install <dir>` builds IN PLACE: it writes <dir>/*.egg-info and
# <dir>/build/lib/ into the SOURCE directory. When install.sh runs from the
# signed app, SCRIPT_DIR is Contents/Resources, so those writes land inside a
# notarised bundle and void it. FIVE call sites did this.
#
# WHY A FAKE pip
#
# The behaviour under test is "the source directory is not written into". Real
# pip needs a network, a real package, and minutes. A fake pip that writes
# egg-info and build/ into whatever directory it is handed reproduces exactly
# the property that matters, deterministically and offline -- and control (0)
# proves the fake actually does write, so control (1)'s zero cannot be the
# quiet kind that means "nothing ran".
#
# CONTROL (5) IS THE POINT OF THIS FILE
#
# The obvious way to assert "the stage is outside the bundle" is
#     case "$stage" in "$SCRIPT_DIR"*) return 2 ;; esac
# With SCRIPT_DIR empty that pattern is `*`, it matches every path, and every
# call returns 2 -- ostler_security silently stops installing, delivered by the
# guard meant to protect it. Control (5) sets SCRIPT_DIR empty and requires an
# ordinary install to SUCCEED, so that form cannot ship green.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$REPO_ROOT/install.sh"

FAILURES=0
CHECKS=0
fail() { echo "  FAIL  $*" >&2; FAILURES=$((FAILURES + 1)); }
pass() { echo "  PASS  $*"; }
check() {
    CHECKS=$((CHECKS + 1))
    if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$3', got '$2')"; fi
}

[[ -f "$INSTALL" ]] || { echo "CANNOT-RUN: install.sh not found at $INSTALL" >&2; exit 2; }

HARNESS="$(mktemp -d -t pipstage-XXXXXX)"
trap 'rm -rf "$HARNESS"' EXIT

# --- extract the REAL helper, not a copy ------------------------------------
extract_fn() {
    awk -v fn="$1" '
        $0 ~ "^"fn"\\(\\) \\{" { inside = 1 }
        inside { print }
        inside && /^\}$/ { exit }
    ' "$INSTALL"
}

{
    # The log path the helper appends to, redirected into the harness so the
    # test never writes to the real /tmp location.
    printf '_OSTLER_PIP_STAGE_LOG="%s/stage.log"\n' "$HARNESS"
    extract_fn _ostler_pip_stage_note
    extract_fn _ostler_pip_install_pkg
} > "$HARNESS/helpers.sh"

for fn in _ostler_pip_stage_note _ostler_pip_install_pkg; do
    if ! grep -q "^${fn}() {" "$HARNESS/helpers.sh"; then
        echo "CANNOT-RUN: could not extract $fn from install.sh." >&2
        echo "  This test drives the REAL helper; it refuses to run against a copy." >&2
        exit 2
    fi
done
bash -n "$HARNESS/helpers.sh" || { echo "CANNOT-RUN: extracted helpers do not parse" >&2; exit 2; }

# --- the fake pip -----------------------------------------------------------
# Writes build metadata INTO the directory it is given, exactly as a real
# in-place build does, then exits with $FAKE_PIP_RC (default 0).
mkdir -p "$HARNESS/bin"
cat > "$HARNESS/bin/pip" <<'FAKEPIP'
#!/usr/bin/env bash
target=""
for a in "$@"; do case "$a" in -*) ;; install) ;; *) target="$a" ;; esac; done
if [[ -n "$target" && -d "$target" ]]; then
    mkdir -p "$target/pkg.egg-info" "$target/build/lib"
    echo "in-place build" > "$target/pkg.egg-info/PKG-INFO"
    echo "built" > "$target/build/lib/mod.py"
fi
echo "$target" > "${FAKE_PIP_MARKER:-/dev/null}"
exit "${FAKE_PIP_RC:-0}"
FAKEPIP
chmod +x "$HARNESS/bin/pip"
PIP="$HARNESS/bin/pip"

# A pretend signed bundle, with a package inside it.
BUNDLE="$HARNESS/OstlerInstaller.app/Contents/Resources"
mk_src() {
    rm -rf "$BUNDLE"
    mkdir -p "$BUNDLE/ostler_security"
    echo "print('hi')" > "$BUNDLE/ostler_security/setup.py"
}

dirty() {
    # Does the SOURCE package directory carry build residue?
    if [[ -d "$1/pkg.egg-info" || -d "$1/build" ]]; then echo dirty; else echo clean; fi
}

echo "test_pip_stage_outside_bundle.sh"

# (0) POSITIVE CONTROL for the instrument. The fake pip MUST write into the
#     directory it is handed. Without this, (1) proves nothing: a zero from a
#     pip that never ran looks exactly like a zero from a pip that was staged.
mk_src
FAKE_PIP_RC=0 "$PIP" install --quiet "$BUNDLE/ostler_security" >/dev/null 2>&1
check "(0) CONTROL: pip run directly DOES dirty the source dir" \
      "$(dirty "$BUNDLE/ostler_security")" "dirty"

# (1) THE DEFECT. Through the helper, the source dir is untouched.
mk_src
rc=0
( export TMPDIR="$HARNESS/tmp"; mkdir -p "$TMPDIR"
  # shellcheck disable=SC1090
  source "$HARNESS/helpers.sh"
  SCRIPT_DIR="$BUNDLE"
  _ostler_pip_install_pkg "$PIP" "$BUNDLE/ostler_security" --quiet ) >/dev/null 2>&1 || rc=$?
check "(1) the bundle source dir stays CLEAN when staged" \
      "$(dirty "$BUNDLE/ostler_security")" "clean"
check "(1b) and the install still reports success" "$rc" "0"

# (2) rc PASSTHROUGH. The new refusal arms must not swallow or fabricate a
#     code. A pip that fails must still surface as a pip failure.
mk_src
rc=0
( export TMPDIR="$HARNESS/tmp2"; mkdir -p "$TMPDIR"
  source "$HARNESS/helpers.sh"
  SCRIPT_DIR="$BUNDLE"
  FAKE_PIP_RC=7 _ostler_pip_install_pkg "$PIP" "$BUNDLE/ostler_security" --quiet ) >/dev/null 2>&1 || rc=$?
check "(2) pip's own rc is passed through unchanged" "$rc" "7"

# (3) REFUSAL, with no SCRIPT_DIR involved. If TMPDIR itself lands inside a
#     bundle the helper must refuse rather than build there. The marker proves
#     pip was never invoked, so this is a refusal and not a silent success.
mk_src
MARK="$HARNESS/mark3"; rm -f "$MARK"
rc=0
( export TMPDIR="$BUNDLE/tmpstage"; mkdir -p "$TMPDIR"
  source "$HARNESS/helpers.sh"
  unset SCRIPT_DIR
  FAKE_PIP_MARKER="$MARK" _ostler_pip_install_pkg "$PIP" "$BUNDLE/ostler_security" --quiet ) >/dev/null 2>&1 || rc=$?
check "(3) a stage inside a .app is REFUSED, without needing SCRIPT_DIR" "$rc" "2"
CHECKS=$((CHECKS + 1))
if [[ -f "$MARK" ]]; then fail "(3b) pip was invoked despite the refusal"; else pass "(3b) pip was never invoked"; fi

# (4) REFUSAL via SCRIPT_DIR, for a bundle path the *.app test would miss.
PLAINDIR="$HARNESS/plain-resources"
mkdir -p "$PLAINDIR/ostler_security"
rc=0
( export TMPDIR="$PLAINDIR/tmpstage"; mkdir -p "$TMPDIR"
  source "$HARNESS/helpers.sh"
  SCRIPT_DIR="$PLAINDIR"
  _ostler_pip_install_pkg "$PIP" "$PLAINDIR/ostler_security" --quiet ) >/dev/null 2>&1 || rc=$?
check "(4) a stage under SCRIPT_DIR is REFUSED" "$rc" "2"

# (5) THE TRAP CONTROL. With SCRIPT_DIR EMPTY, an ordinary install must still
#     SUCCEED. `case "$stage" in "$SCRIPT_DIR"*)` degenerates to `*` here and
#     would return 2 for every package on the machine.
mk_src
rc=0
( export TMPDIR="$HARNESS/tmp5"; mkdir -p "$TMPDIR"
  source "$HARNESS/helpers.sh"
  SCRIPT_DIR=""
  _ostler_pip_install_pkg "$PIP" "$BUNDLE/ostler_security" --quiet ) >/dev/null 2>&1 || rc=$?
check "(5) an EMPTY SCRIPT_DIR does not refuse every package" "$rc" "0"

# (5b) and with SCRIPT_DIR entirely unset, under set -u.
mk_src
rc=0
( export TMPDIR="$HARNESS/tmp5b"; mkdir -p "$TMPDIR"
  set -u
  source "$HARNESS/helpers.sh"
  unset SCRIPT_DIR
  _ostler_pip_install_pkg "$PIP" "$BUNDLE/ostler_security" --quiet ) >/dev/null 2>&1 || rc=$?
check "(5b) an UNSET SCRIPT_DIR under set -u does not abort or refuse" "$rc" "0"

# (6) DIAGNOSTICS SURVIVE A CALLER'S 2>/dev/null. Two call sites are written
#     `... 2>/dev/null || true`, so a staging failure would otherwise be
#     invisible and indistinguishable from a pip failure.
: > "$HARNESS/stage.log"
CHECKS=$((CHECKS + 1))
if grep -q 'no such package dir' "$HARNESS/stage.log" 2>/dev/null; then
    fail "(6a) CONTROL: the log already carried the token before the call"
else
    pass "(6a) CONTROL: the log is clean before the call"
fi
rc=0
( source "$HARNESS/helpers.sh"
  _ostler_pip_install_pkg "$PIP" "$HARNESS/does-not-exist" --quiet 2>/dev/null || exit $? ) >/dev/null 2>&1 || rc=$?
check "(6b) an absent package dir still returns 2" "$rc" "2"
CHECKS=$((CHECKS + 1))
if grep -q 'no such package dir' "$HARNESS/stage.log"; then
    pass "(6c) the reason reached the stage log despite 2>/dev/null"
else
    fail "(6c) the diagnostic was swallowed: the stage log has no record"
fi

# (7) POPULATION. Every pip install sourced from SCRIPT_DIR must route through
#     the helper. Case-INSENSITIVE: two of the five sites use the uppercase
#     $OSTLER_PIP, and a lowercase-only pattern found 3 where there were 5.
CHECKS=$((CHECKS + 1))
unrouted=$(grep -nEi 'pip"?[[:space:]]+install\b' "$INSTALL" \
           | grep 'SCRIPT_DIR' \
           | grep -v '_ostler_pip_install_pkg' \
           | grep -vc '^[[:space:]]*#' || true)
if [[ "$unrouted" -eq 0 ]]; then
    pass "(7) no pip install still sources directly from SCRIPT_DIR"
else
    fail "(7) $unrouted pip install site(s) still source from SCRIPT_DIR"
fi
routed=$(grep -c '_ostler_pip_install_pkg "' "$INSTALL" || true)
CHECKS=$((CHECKS + 1))
if [[ "$routed" -ge 5 ]]; then
    pass "(7b) all 5 known call sites are routed (found $routed)"
else
    fail "(7b) coverage went BACKWARDS: $routed routed, floor is 5"
fi

echo
echo "=== $((CHECKS - FAILURES)) passed / $FAILURES failed ==="
[[ "$FAILURES" -eq 0 ]]
