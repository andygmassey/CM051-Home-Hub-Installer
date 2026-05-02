#!/usr/bin/env bash
#
# tests/test_uninstaller_keep_prompt.sh
#
# Verifies the keep-content behaviour in the ostler-uninstall
# script that install.sh ships into ${OSTLER_DIR}/bin/.
#
# install.sh embeds the uninstaller as a single-quoted heredoc.
# These tests:
#   1. Extract the heredoc body into a standalone script.
#   2. Run it inside a sandboxed $HOME so the developer's real
#      machine is never touched.
#   3. Stub out the side-effect commands (docker, launchctl,
#      sudo, security) so the test focuses on the keep-content
#      prompt + flag handling, not the service-tear-down plumbing.
#
# Coverage:
#   - --keep-content flag: ~/Documents/Ostler/ survives.
#   - --remove-content flag: ~/Documents/Ostler/ is removed.
#   - Interactive Y (default): ~/Documents/Ostler/ survives.
#   - Interactive N: ~/Documents/Ostler/ is removed.
#   - --help exits 0 and prints usage.
#   - Unknown flag exits non-zero.
#
# Pure bash + standard shell tools.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${REPO_ROOT}/install.sh"

if [[ ! -f "$INSTALL_SCRIPT" ]]; then
    echo "FAIL: install.sh not found at $INSTALL_SCRIPT" >&2
    exit 1
fi

# ── Extract the uninstaller heredoc body ─────────────────────
# install.sh uses a single-quoted `<<'UNINSTALLEOF'` marker so
# the body is preserved verbatim. We grab everything between the
# opening and closing markers and write it to a temp file.
UNINSTALLER="$(mktemp)"
trap 'rm -f "$UNINSTALLER"' EXIT

awk '
    /<<'\''UNINSTALLEOF'\''/ { capture = 1; next }
    /^UNINSTALLEOF$/         { capture = 0 }
    capture                  { print }
' "$INSTALL_SCRIPT" > "$UNINSTALLER"

if [[ ! -s "$UNINSTALLER" ]]; then
    echo "FAIL: extracted uninstaller body is empty" >&2
    echo "      (heredoc markers in install.sh may have changed shape)" >&2
    exit 1
fi
chmod +x "$UNINSTALLER"

# ── Sandbox + stub harness ───────────────────────────────────
# Each test gets a fresh $HOME and a stub PATH so external
# commands the uninstaller would invoke (docker, launchctl,
# sudo, security) become no-ops that always succeed. We also
# pipe "YES" into stdin to satisfy the up-front confirm gate.
make_sandbox() {
    SANDBOX="$(mktemp -d)"
    STUB_BIN="${SANDBOX}/stub-bin"
    mkdir -p "$STUB_BIN"
    for cmd in docker launchctl sudo security pmset; do
        cat > "${STUB_BIN}/${cmd}" <<'STUBEOF'
#!/usr/bin/env bash
exit 0
STUBEOF
        chmod +x "${STUB_BIN}/${cmd}"
    done
    mkdir -p "${SANDBOX}/.ostler" \
             "${SANDBOX}/Documents/Ostler/Wiki" \
             "${SANDBOX}/Documents/Ostler/Transcripts" \
             "${SANDBOX}/Documents/Ostler/Daily-Briefs" \
             "${SANDBOX}/Documents/Ostler/Captures" \
             "${SANDBOX}/Documents/Ostler/Exports"
    # Seed a sample file so we can confirm the tree was actually
    # left in place (rather than just the empty dir).
    echo "test wiki page" > "${SANDBOX}/Documents/Ostler/Wiki/sample.md"
}

run_uninstaller() {
    # Args:
    #   $1 = stdin to feed (YES + optional Y/n response)
    #   $@ = uninstaller flags
    local stdin_input="$1"
    shift
    HOME="$SANDBOX" \
        PATH="${STUB_BIN}:${PATH}" \
        bash "$UNINSTALLER" "$@" <<<"$stdin_input" >/dev/null 2>&1
}

cleanup_sandbox() {
    if [[ -n "${SANDBOX:-}" && -d "$SANDBOX" ]]; then
        rm -rf "$SANDBOX"
    fi
}

# ── Test 1: --keep-content keeps the tree ────────────────────
make_sandbox
run_uninstaller "YES" --keep-content
if [[ ! -d "${SANDBOX}/Documents/Ostler" ]]; then
    echo "FAIL [keep-flag]: ~/Documents/Ostler/ was removed despite --keep-content" >&2
    cleanup_sandbox
    exit 1
fi
if [[ ! -f "${SANDBOX}/Documents/Ostler/Wiki/sample.md" ]]; then
    echo "FAIL [keep-flag]: seeded wiki page was deleted" >&2
    cleanup_sandbox
    exit 1
fi
cleanup_sandbox
echo "PASS: --keep-content preserves ~/Documents/Ostler/"

# ── Test 2: --remove-content removes the tree ────────────────
make_sandbox
run_uninstaller "YES" --remove-content
if [[ -d "${SANDBOX}/Documents/Ostler" ]]; then
    echo "FAIL [remove-flag]: ~/Documents/Ostler/ survived --remove-content" >&2
    cleanup_sandbox
    exit 1
fi
cleanup_sandbox
echo "PASS: --remove-content removes ~/Documents/Ostler/"

# ── Test 3: interactive Y (default) keeps the tree ──────────
# Stdin: "YES\nY\n" -- YES for the up-front gate, Y for the keep
# prompt. An empty newline (default) would also work; we send Y
# explicitly to make the assertion intent clear.
make_sandbox
run_uninstaller $'YES\nY'
if [[ ! -d "${SANDBOX}/Documents/Ostler" ]]; then
    echo "FAIL [interactive-Y]: ~/Documents/Ostler/ removed despite Y reply" >&2
    cleanup_sandbox
    exit 1
fi
cleanup_sandbox
echo "PASS: interactive Y reply preserves ~/Documents/Ostler/"

# ── Test 4: interactive default (just newline) keeps the tree ─
# An empty reply must default to Y, matching the bolded letter
# in the prompt. Customers who hit Enter without thinking do
# NOT lose their content.
make_sandbox
run_uninstaller $'YES\n'
if [[ ! -d "${SANDBOX}/Documents/Ostler" ]]; then
    echo "FAIL [interactive-default]: empty reply removed content (default must be keep)" >&2
    cleanup_sandbox
    exit 1
fi
cleanup_sandbox
echo "PASS: interactive default (Enter) preserves ~/Documents/Ostler/"

# ── Test 5: interactive N removes the tree ──────────────────
make_sandbox
run_uninstaller $'YES\nn'
if [[ -d "${SANDBOX}/Documents/Ostler" ]]; then
    echo "FAIL [interactive-N]: ~/Documents/Ostler/ survived n reply" >&2
    cleanup_sandbox
    exit 1
fi
cleanup_sandbox
echo "PASS: interactive n reply removes ~/Documents/Ostler/"

# ── Test 6: --help exits 0 and prints usage ─────────────────
HELP_OUT="$(bash "$UNINSTALLER" --help 2>&1)" || {
    echo "FAIL [help]: --help exited non-zero" >&2
    exit 1
}
if [[ "$HELP_OUT" != *"--keep-content"* || "$HELP_OUT" != *"--remove-content"* ]]; then
    echo "FAIL [help]: --help output missing flag documentation" >&2
    exit 1
fi
echo "PASS: --help exits 0 and documents both flags"

# ── Test 7: unknown flag exits non-zero ─────────────────────
if bash "$UNINSTALLER" --bogus-flag 2>/dev/null; then
    echo "FAIL [unknown-flag]: --bogus-flag exited 0; should be non-zero" >&2
    exit 1
fi
echo "PASS: unknown flag exits non-zero"

echo ""
echo "All uninstaller keep-content tests passed."
