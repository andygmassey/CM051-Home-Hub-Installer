#!/usr/bin/env bash
#
# tests/test_editor_frontpage_hook.sh
#
# Locks the Editor Front Page install hook (Job 2). Two legs:
#   1. SOURCE-STAGING: the vendored CM059 sources (vendor/cm059_editor,
#      bundled to ${SCRIPT_DIR}/cm059_editor) are copied into
#      ${EDITOR_DIR} (~/.ostler/editor) so `python -m
#      compiler.emit_frontpage` resolves on a clean box.
#   2. AGENT: install.sh sed-substitutes the plist's two placeholders
#      and launchctl-loads the hourly emitter.
#
# This is the "#2 Front Page refreshes on schedule" function gate's
# install leg. Verifies the staged source + the plist's ProgramArguments
# command resolve together, gated cleanly when the editor is unstaged.
#
# British English throughout.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
VENDOR_EDITOR="${REPO_ROOT}/vendor/cm059_editor"
FAILED=0
fail() { echo "FAIL: $*" >&2; FAILED=1; }
pass() { echo "ok: $*"; }

# ── 1. The hook section exists ─────────────────────────────────────
grep -q "The Editor Front Page refresh agent" "$INSTALL_SH" \
    && pass "editor frontpage hook section present" \
    || fail "editor frontpage hook section missing"

# ── 2. Source-staging leg: copies the vendored sources ─────────────
if grep -q 'cp -R "${EDITOR_SRC}/compiler"' "$INSTALL_SH" \
   && grep -q 'SCRIPT_DIR}/cm059_editor' "$INSTALL_SH"; then
    pass "hook stages the vendored cm059_editor sources into EDITOR_DIR"
else
    fail "hook does not stage the vendored editor sources"
fi

# ── 3. Substitutes both plist placeholders ─────────────────────────
grep -q 's/__EDITOR_REPO__/' "$INSTALL_SH" && grep -q 's/__PYTHON__/' "$INSTALL_SH" \
    && pass "hook sed-substitutes __EDITOR_REPO__ and __PYTHON__" \
    || fail "hook does not substitute both placeholders"

# ── 4. launchctl loads + teardown removes the agent ────────────────
grep -q 'launchctl bootstrap "gui/\$(id -u)" "\$EDITOR_FRONTPAGE_PLIST"' "$INSTALL_SH" \
    && pass "hook launchctl-bootstraps the agent" \
    || fail "hook does not launchctl-bootstrap the agent"
if grep -q 'bootout "gui/\$(id -u)/com.ostler.editor.frontpage"' "$INSTALL_SH" \
   && grep -q 'rm -f "\${HOME}/Library/LaunchAgents/com.ostler.editor.frontpage.plist"' "$INSTALL_SH"; then
    pass "teardown boots out + removes the editor agent"
else
    fail "teardown missing editor agent bootout / rm"
fi

# ── 5. The vendored sources exist and are stdlib-only ──────────────
if [[ -f "${VENDOR_EDITOR}/compiler/emit_frontpage.py" \
      && -f "${VENDOR_EDITOR}/deploy/com.ostler.editor.frontpage.plist" ]]; then
    pass "vendor/cm059_editor carries the emitter + plist"
else
    fail "vendor/cm059_editor is missing the emitter or plist"
fi
# No third-party imports (no pip install at install time).
if grep -rhE '^(import|from) ' "${VENDOR_EDITOR}/compiler/" \
   | grep -vE 'from compiler|from \.|import compiler|__future__' \
   | grep -vE '^(import|from) (csv|hashlib|html|io|json|os|re|sys|datetime|urllib|argparse|typing|collections|itertools|functools|pathlib|math|time|textwrap)\b' \
   | grep -q .; then
    fail "vendored editor has non-stdlib imports -- staging would need pip"
else
    pass "vendored editor is stdlib-only (no pip install needed)"
fi

# ── 6. End-to-end: stage from a bundled SCRIPT_DIR into an EMPTY ────
#      EDITOR_DIR, then assert the module + the rendered plist command
#      resolve together.
SBX=$(mktemp -d)
trap 'rm -rf "$SBX"' EXIT
mkdir -p "$SBX/scriptdir/cm059_editor" "$SBX/ostler" "$SBX/home/Library/LaunchAgents" "$SBX/stubs"
cp -R "${VENDOR_EDITOR}/compiler" "${VENDOR_EDITOR}/deploy" "$SBX/scriptdir/cm059_editor/"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SBX/stubs/launchctl"
chmod +x "$SBX/stubs/launchctl"
PY="$(command -v python3)"

HOOK="$SBX/hook.sh"
awk '/3.13-editor  The Editor Front Page/{f=1} f{print} /^unset EDITOR_DIR EDITOR_FRONTPAGE_PLIST_SRC/{if(f)exit}' "$INSTALL_SH" > "$HOOK"
(
    cd "$SBX"
    ok(){ :; }; warn(){ echo "HOOK-WARN: $*" >&2; }; info(){ :; }
    MSG_OK_EDITOR_FRONTPAGE_AGENT_INSTALLED=x; MSG_WARN_EDITOR_FRONTPAGE_PLIST_LOAD_FAILED=x
    MSG_INFO_EDITOR_FRONTPAGE_STAGING=x; MSG_WARN_EDITOR_FRONTPAGE_STAGING_FAILED=x
    export HOME="$SBX/home"; export PATH="$SBX/stubs:$PATH"
    OSTLER_DIR="$SBX/ostler"; SCRIPT_DIR="$SBX/scriptdir"; PYTHON3_BIN="$PY"
    source "$HOOK"
)
STAGED_DIR="$SBX/ostler/editor"
RENDERED="$SBX/home/Library/LaunchAgents/com.ostler.editor.frontpage.plist"

# 6a. sources staged
[[ -f "$STAGED_DIR/compiler/emit_frontpage.py" ]] \
    && pass "sources staged into EDITOR_DIR (~/.ostler/editor)" \
    || fail "sources not staged into EDITOR_DIR"

# 6b. plist rendered placeholder-free, EDITOR_REPO points at the staged dir
if [[ -f "$RENDERED" ]] && ! grep -q '__PYTHON__\|__EDITOR_REPO__' "$RENDERED"; then
    pass "plist rendered placeholder-free"
else
    fail "plist missing or still carries placeholders"
fi
grep -q "$STAGED_DIR" "$RENDERED" 2>/dev/null \
    && pass "rendered plist WorkingDirectory/PYTHONPATH points at the staged editor dir" \
    || fail "rendered plist does not reference the staged editor dir"

# 6c. THE function gate: `python -m compiler.emit_frontpage` resolves
#     from the staged dir (the exact command the plist runs).
if ( cd "$STAGED_DIR" && PYTHONPATH="$STAGED_DIR" "$PY" -c "import importlib.util,sys; sys.exit(0 if importlib.util.find_spec('compiler.emit_frontpage') else 1)" ); then
    pass "python -m compiler.emit_frontpage resolves from the staged editor dir"
else
    fail "python -m compiler.emit_frontpage does NOT resolve -- the tick would fail"
fi

# ── 7. Negative gate: nothing bundled, nothing pre-staged => no-op ─
SBX2=$(mktemp -d)
mkdir -p "$SBX2/scriptdir" "$SBX2/ostler" "$SBX2/home/Library/LaunchAgents" "$SBX2/stubs"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SBX2/stubs/launchctl"; chmod +x "$SBX2/stubs/launchctl"
(
    cd "$SBX2"
    ok(){ :; }; warn(){ :; }; info(){ :; }
    MSG_OK_EDITOR_FRONTPAGE_AGENT_INSTALLED=x; MSG_WARN_EDITOR_FRONTPAGE_PLIST_LOAD_FAILED=x
    MSG_INFO_EDITOR_FRONTPAGE_STAGING=x; MSG_WARN_EDITOR_FRONTPAGE_STAGING_FAILED=x
    export HOME="$SBX2/home"; export PATH="$SBX2/stubs:$PATH"
    OSTLER_DIR="$SBX2/ostler"; SCRIPT_DIR="$SBX2/scriptdir"; PYTHON3_BIN="$(command -v python3)"
    source "$HOOK"
)
if [[ ! -f "$SBX2/home/Library/LaunchAgents/com.ostler.editor.frontpage.plist" \
      && ! -d "$SBX2/ostler/editor/compiler" ]]; then
    pass "hook no-ops cleanly when the editor is neither bundled nor staged"
else
    fail "hook acted with no editor sources present"
fi
rm -rf "$SBX2"

if [[ "$FAILED" -ne 0 ]]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
