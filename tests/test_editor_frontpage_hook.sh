#!/usr/bin/env bash
#
# tests/test_editor_frontpage_hook.sh
#
# Locks the Editor Front Page install hook (Job 2): install.sh must
# sed-substitute the two placeholders in
# deploy/com.ostler.editor.frontpage.plist and launchctl-load it,
# mirroring the Doctor / ical-server agents, gated on the editor
# sources actually being staged.
#
# British English throughout.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
FAILED=0
fail() { echo "FAIL: $*" >&2; FAILED=1; }
pass() { echo "ok: $*"; }

# ── 1. The hook section exists ─────────────────────────────────────
if grep -q "The Editor Front Page refresh agent" "$INSTALL_SH"; then
    pass "editor frontpage hook section present"
else
    fail "editor frontpage hook section missing"
fi

# ── 2. Substitutes both placeholders ───────────────────────────────
if grep -q 's/__EDITOR_REPO__/' "$INSTALL_SH" && grep -q 's/__PYTHON__/' "$INSTALL_SH"; then
    pass "hook sed-substitutes __EDITOR_REPO__ and __PYTHON__"
else
    fail "hook does not substitute both placeholders"
fi

# ── 3. Gated on the emitter module being staged ────────────────────
if grep -q 'compiler/emit_frontpage.py' "$INSTALL_SH"; then
    pass "hook gated on compiler/emit_frontpage.py presence"
else
    fail "hook not gated on the emitter module -- would thrash if unstaged"
fi

# ── 4. launchctl loads the agent ───────────────────────────────────
if grep -q 'launchctl bootstrap "gui/\$(id -u)" "\$EDITOR_FRONTPAGE_PLIST"' "$INSTALL_SH"; then
    pass "hook launchctl-bootstraps the agent"
else
    fail "hook does not launchctl-bootstrap the agent"
fi

# ── 5. Teardown removes the agent ──────────────────────────────────
if grep -q 'bootout "gui/\$(id -u)/com.ostler.editor.frontpage"' "$INSTALL_SH" \
   && grep -q 'rm -f "\${HOME}/Library/LaunchAgents/com.ostler.editor.frontpage.plist"' "$INSTALL_SH"; then
    pass "teardown boots out + removes the editor agent"
else
    fail "teardown missing editor agent bootout / rm"
fi

# ── 6. End-to-end: hook renders a placeholder-free plist ───────────
SRC_PLIST=""
for cand in "${REPO_ROOT}/deploy/com.ostler.editor.frontpage.plist" \
            "${REPO_ROOT}/editor/deploy/com.ostler.editor.frontpage.plist"; do
    [[ -f "$cand" ]] && SRC_PLIST="$cand" && break
done
# The plist may not live in CM051 (it ships from the Editor repo); use a
# minimal synthetic one carrying the same placeholders if absent.
SBX=$(mktemp -d)
trap 'rm -rf "$SBX"' EXIT
mkdir -p "$SBX/editor/compiler" "$SBX/editor/deploy" "$SBX/home/Library/LaunchAgents" "$SBX/stubs"
touch "$SBX/editor/compiler/emit_frontpage.py"
if [[ -n "$SRC_PLIST" ]]; then
    cp "$SRC_PLIST" "$SBX/editor/deploy/com.ostler.editor.frontpage.plist"
else
    cat > "$SBX/editor/deploy/com.ostler.editor.frontpage.plist" <<'PLIST'
<plist version="1.0"><dict>
<key>ProgramArguments</key><array>
<string>__PYTHON__</string><string>-m</string><string>compiler.emit_frontpage</string>
</array>
<key>WorkingDirectory</key><string>__EDITOR_REPO__</string>
<key>EnvironmentVariables</key><dict><key>PYTHONPATH</key><string>__EDITOR_REPO__</string></dict>
</dict></plist>
PLIST
fi
printf '#!/usr/bin/env bash\nexit 0\n' > "$SBX/stubs/launchctl"
chmod +x "$SBX/stubs/launchctl"

HOOK="$SBX/hook.sh"
awk '/3.13-editor  The Editor Front Page/{f=1} f{print} /^unset EDITOR_DIR EDITOR_FRONTPAGE_PLIST_SRC/{if(f)exit}' "$INSTALL_SH" > "$HOOK"
(
    cd "$SBX"
    ok(){ :; }; warn(){ :; }; info(){ :; }
    MSG_OK_EDITOR_FRONTPAGE_AGENT_INSTALLED=x; MSG_WARN_EDITOR_FRONTPAGE_PLIST_LOAD_FAILED=x
    export HOME="$SBX/home"; export PATH="$SBX/stubs:$PATH"
    OSTLER_EDITOR_DIR="$SBX/editor"; OSTLER_DIR="$SBX/unused"; SCRIPT_DIR="$SBX/nope"; PYTHON3_BIN="/usr/bin/python3"
    source "$HOOK"
)
RENDERED="$SBX/home/Library/LaunchAgents/com.ostler.editor.frontpage.plist"
if [[ -f "$RENDERED" ]] && ! grep -q '__PYTHON__\|__EDITOR_REPO__' "$RENDERED"; then
    pass "hook renders a placeholder-free plist"
else
    fail "rendered plist missing or still carries placeholders"
fi

# ── 7. Negative gate: no emitter module => no plist rendered ───────
rm -f "$SBX/editor/compiler/emit_frontpage.py" "$RENDERED"
(
    cd "$SBX"
    ok(){ :; }; warn(){ :; }; info(){ :; }
    MSG_OK_EDITOR_FRONTPAGE_AGENT_INSTALLED=x; MSG_WARN_EDITOR_FRONTPAGE_PLIST_LOAD_FAILED=x
    export HOME="$SBX/home"; export PATH="$SBX/stubs:$PATH"
    OSTLER_EDITOR_DIR="$SBX/editor"; OSTLER_DIR="$SBX/unused"; SCRIPT_DIR="$SBX/nope"; PYTHON3_BIN="/usr/bin/python3"
    source "$HOOK"
)
if [[ ! -f "$RENDERED" ]]; then
    pass "hook no-ops cleanly when the editor is not staged"
else
    fail "hook rendered a plist with no emitter staged"
fi

if [[ "$FAILED" -ne 0 ]]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
