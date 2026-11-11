#!/usr/bin/env bash
#
# tests/test_uninstall_legacy_documents_root.sh
#
# The uninstaller must never delete ~/Documents/Ostler silently. That folder is
# the pre-CM051 #3429 user root, and Documents is iCloud-synced. Removal is
# allowed only when the folder is EMPTY, or when the customer types YES at the
# legacy prompt. --yes and --remove-content do not count as consent for it.
#
# Same extraction and stub harness as tests/test_uninstaller_keep_prompt.sh:
# the uninstaller body is cut out of install.sh and run under a sandboxed HOME,
# with side-effect commands stubbed. Assertions are on the filesystem only.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${REPO_ROOT}/install.sh"

if [[ ! -f "$INSTALL_SCRIPT" ]]; then
    echo "FAIL: install.sh not found at $INSTALL_SCRIPT" >&2
    exit 1
fi

UNINSTALLER="$(mktemp)"
trap 'rm -f "$UNINSTALLER"' EXIT

awk '
    /^[[:space:]]*#/           { next }
    /<<'\''UNINSTALLEOF'\''/ { capture = 1; next }
    /^UNINSTALLEOF$/         { capture = 0 }
    capture                  { print }
' "$INSTALL_SCRIPT" > "$UNINSTALLER"

if [[ ! -s "$UNINSTALLER" ]]; then
    echo "FAIL: extracted uninstaller body is empty" >&2
    exit 1
fi
chmod +x "$UNINSTALLER"

SANDBOX=""
cleanup_sandbox() {
    if [[ -n "${SANDBOX:-}" && -d "$SANDBOX" ]]; then
        rm -rf "$SANDBOX"
    fi
    SANDBOX=""
}
trap 'cleanup_sandbox; rm -f "$UNINSTALLER"' EXIT

# make_sandbox <legacy-state: none|empty|full>
make_sandbox() {
    cleanup_sandbox
    SANDBOX="$(mktemp -d)"
    local stub_bin="${SANDBOX}/stub-bin"
    mkdir -p "$stub_bin"
    for cmd in docker launchctl sudo security pmset; do
        printf '#!/usr/bin/env bash\nexit 0\n' > "${stub_bin}/${cmd}"
        chmod +x "${stub_bin}/${cmd}"
    done
    mkdir -p "${SANDBOX}/.ostler" "${SANDBOX}/Ostler/Wiki"
    echo "test wiki page" > "${SANDBOX}/Ostler/Wiki/sample.md"
    case "$1" in
        none)  ;;
        empty) mkdir -p "${SANDBOX}/Documents/Ostler" ;;
        full)
            mkdir -p "${SANDBOX}/Documents/Ostler/Wiki"
            echo "legacy page" > "${SANDBOX}/Documents/Ostler/Wiki/legacy.md"
            ;;
    esac
}

# run_uninstaller <stdin> [flags...]. Captures output; never discards it.
run_uninstaller() {
    local stdin_input="$1"
    shift
    HOME="$SANDBOX" \
        PATH="${SANDBOX}/stub-bin:${PATH}" \
        bash "$UNINSTALLER" "$@" <<<"$stdin_input" >"${SANDBOX}/uninstaller.out" 2>&1 || true
}

fail() {
    echo "FAIL [$1]: $2" >&2
    if [[ -n "${SANDBOX:-}" && -f "${SANDBOX}/uninstaller.out" ]]; then
        echo "--- uninstaller output ---" >&2
        cat "${SANDBOX}/uninstaller.out" >&2
    fi
    cleanup_sandbox
    exit 1
}

# ── 1. Empty legacy folder is removed without a question ─────
make_sandbox empty
run_uninstaller $'YES\n' --keep-content
[[ -e "${SANDBOX}/Documents/Ostler" ]] && fail empty-removed "empty ~/Documents/Ostler survived"
[[ -f "${SANDBOX}/Ostler/Wiki/sample.md" ]] || fail empty-removed "~/Ostler content was touched"
cleanup_sandbox
echo "PASS: empty ~/Documents/Ostler is removed"

# ── 2. Files in legacy folder, no answer on stdin: kept ──────
make_sandbox full
run_uninstaller $'YES\n' --keep-content
[[ -f "${SANDBOX}/Documents/Ostler/Wiki/legacy.md" ]] || fail no-answer-keeps "legacy file deleted with no answer"
cleanup_sandbox
echo "PASS: no answer keeps a non-empty ~/Documents/Ostler"

# ── 3. Files in legacy folder, Enter or anything but YES: kept ─
make_sandbox full
run_uninstaller $'YES\n\n' --keep-content
[[ -f "${SANDBOX}/Documents/Ostler/Wiki/legacy.md" ]] || fail enter-keeps "Enter deleted the legacy folder"
cleanup_sandbox

make_sandbox full
run_uninstaller $'YES\nyes\n' --keep-content
[[ -f "${SANDBOX}/Documents/Ostler/Wiki/legacy.md" ]] || fail lowercase-keeps "lowercase yes deleted the legacy folder; only YES counts"
cleanup_sandbox
echo "PASS: Enter, and lowercase yes, keep a non-empty ~/Documents/Ostler"

# ── 4. --yes does not consent to deleting Documents files ───
make_sandbox full
run_uninstaller $'YES\n' --yes --keep-content  # the typed YES must NOT be read as consent
[[ -f "${SANDBOX}/Documents/Ostler/Wiki/legacy.md" ]] || fail yes-flag-keeps "--yes deleted files in Documents"
cleanup_sandbox
echo "PASS: --yes keeps a non-empty ~/Documents/Ostler"

# ── 5. Typing YES removes the legacy folder, and only it ─────
make_sandbox full
run_uninstaller $'YES\nYES\n' --keep-content
[[ -e "${SANDBOX}/Documents/Ostler" ]] && fail typed-yes-removes "YES did not remove ~/Documents/Ostler"
[[ -f "${SANDBOX}/Ostler/Wiki/sample.md" ]] || fail typed-yes-removes "~/Ostler content was removed with the legacy folder"
cleanup_sandbox
echo "PASS: typed YES removes ~/Documents/Ostler and leaves ~/Ostler"

# ── 6. No legacy folder: no legacy prompt at all ─────────────
make_sandbox none
run_uninstaller $'YES\n' --keep-content
if grep -q 'older Ostler folder' "${SANDBOX}/uninstaller.out"; then
    fail no-legacy-no-prompt "the legacy prompt appeared with no legacy folder"
fi
cleanup_sandbox
echo "PASS: no legacy folder, no legacy prompt"

echo ""
echo "All legacy-root uninstaller tests passed."
