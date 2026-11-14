#!/usr/bin/env bash
#
# tests/test_cli_symlink_owner_path.sh
#
# Same-shape sweep 2026-11-14, item 8 follow-up. The GUI install used to run
# `ln -sf X /usr/local/bin/Y || sudo ln -sf ...` and relied on the admin shell
# having chowned /usr/local/bin. That chown is gone, so the GUI path must NOT
# reach for sudo (the GUI pty cannot prompt). This test extracts the real
# _ostler_link_cli from install.sh and runs it against a link directory that
# the owner cannot write, with a sudo stub that records every call.
#
# RED on the pre-change code: the GUI branch falls through to sudo and leaves
# no owner-side link. The mutant (sudo restored) must fail the same assertion.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${INSTALL_SCRIPT:-${REPO_ROOT}/install.sh}"

W="$(mktemp -d)"
trap 'chmod -R u+w "$W" 2>/dev/null || true; rm -rf "$W"' EXIT

# Extract the helper exactly as shipped.
awk '/^_ostler_link_cli\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$INSTALL_SCRIPT" > "$W/helper.sh"
if [ ! -s "$W/helper.sh" ]; then
    echo "FAIL [helper-present]: _ostler_link_cli not found in install.sh" >&2
    exit 1
fi

# sudo stub: records the call, and fails the way a GUI pty does (no prompt).
mkdir -p "$W/bin" "$W/ro" "$W/rw" "$W/home/.ostler"
cat > "$W/bin/sudo" <<'SUDO'
#!/bin/bash
echo "SUDO $*" >> "$SUDO_LOG"
exit 1
SUDO
chmod +x "$W/bin/sudo"
echo target > "$W/target"
chmod 555 "$W/ro"

run_case() {  # $1 GUI value, $2 link path, $3 log name
    : > "$W/sudo.log"
    (
        export PATH="$W/bin:$PATH" SUDO_LOG="$W/sudo.log" OSTLER_DIR="$W/home/.ostler"
        export OSTLER_GUI="$1"
        # shellcheck disable=SC1090
        source "$W/helper.sh"
        _ostler_link_cli "$W/target" "$2" || true
        echo "$_OSTLER_LINKED" > "$W/$3.linked"
    )
}

# Case 1: GUI, /usr/local/bin-like dir not writable by the owner.
run_case 1 "$W/ro/pwg-convo" gui_ro
LINKED="$(cat "$W/gui_ro.linked")"
if grep -q '^SUDO' "$W/sudo.log"; then
    echo "FAIL [gui-no-sudo]: GUI install called sudo: $(cat "$W/sudo.log")" >&2
    exit 1
fi
if [ "$LINKED" != "$W/home/.ostler/bin/pwg-convo" ] || [ ! -L "$LINKED" ]; then
    echo "FAIL [gui-owner-link]: no owner-side link (reported: $LINKED)" >&2
    exit 1
fi
echo "PASS: GUI install with a non-writable link dir: no sudo, owner-side link at $LINKED"

# Case 2: GUI, writable dir (a legacy Mac): the link goes where asked, still no sudo.
run_case 1 "$W/rw/ostler-knowledge" gui_rw
if grep -q '^SUDO' "$W/sudo.log"; then
    echo "FAIL [gui-writable-no-sudo]: sudo called on a writable dir" >&2
    exit 1
fi
[ -L "$W/rw/ostler-knowledge" ] || { echo "FAIL [gui-writable-link]: link not created" >&2; exit 1; }
echo "PASS: GUI install with a writable link dir links in place, no sudo"

# Case 3: CLI (not GUI) keeps the elevated path.
run_case 0 "$W/ro/pwg-convo-cli" cli
if ! grep -q '^SUDO ln -sf' "$W/sudo.log"; then
    echo "FAIL [cli-sudo]: CLI install no longer uses sudo ln" >&2
    exit 1
fi
echo "PASS: CLI install keeps the sudo ln path"

echo ""
echo "All CLI symlink owner-path checks passed."
