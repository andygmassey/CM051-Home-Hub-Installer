#!/usr/bin/env bash
#
# tests/test_a_manual_brew_tarball_must_target_a_branch_that_still_exists.sh
#
# Homebrew retired the master branch. The manual, no-sudo tarball install
# path in install.sh (taken when OSTLER_GUI=1 and /opt/homebrew is
# pre-chowned but sudo cannot be used non-interactively) used to fetch
# https://github.com/Homebrew/brew/tarball/master. curl succeeds and tar
# extracts fine, but the very next command, /opt/homebrew/bin/brew
# --version, exits 1 with:
#
#     Error: Homebrew's master branch is no longer supported.
#     Run brew update to migrate to the main branch.
#
# and install.sh aborts at ERR-04-HOMEBREW-INSTALL. Measured on a freshly
# wiped Mac with no Homebrew. The main branch is live: the same tarball
# fetched from /main and extracted to a scratch prefix reports
# "Homebrew >=4.3.0 (shallow or no git repository)" and exits 0. Every
# customer installing on a Mac without Homebrew already present hit this.
#
# This test reads the literal curl line install.sh uses for that manual
# tarball path and refuses the retired branch name.
#
# Pure bash + standard tools. Exit code 0 on pass, non-zero on fail.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"

if [[ ! -f "$INSTALL_SH" ]]; then
    echo "FAIL: install.sh not found at $INSTALL_SH" >&2
    exit 1
fi

failures=0
fail_test() {
    failures=$((failures + 1))
    echo "FAIL: $*" >&2
}
ok() { echo "ok: $*"; }

if ! grep -q 'Homebrew/brew/tarball/' "$INSTALL_SH"; then
    fail_test "install.sh no longer contains a Homebrew/brew/tarball/ fetch. If the manual tarball install path was removed, remove this test with it rather than leave it to fail blind."
elif grep -q 'Homebrew/brew/tarball/master' "$INSTALL_SH"; then
    fail_test "install.sh still fetches https://github.com/Homebrew/brew/tarball/master. Homebrew retired the master branch, so brew --version exits 1 immediately after extraction with a migrate-to-main error. Use tarball/main."
else
    ok "install.sh does not fetch the retired tarball/master branch"
fi

if grep -q 'Homebrew/brew/tarball/main\b' "$INSTALL_SH"; then
    ok "install.sh fetches the live tarball/main branch"
else
    fail_test "install.sh does not fetch https://github.com/Homebrew/brew/tarball/main. The manual no-sudo tarball install path must target a branch that still exists."
fi

echo ""
if [[ $failures -eq 0 ]]; then
    echo "PASS: the manual Homebrew tarball install targets a branch that still exists."
    exit 0
else
    echo "FAIL: ${failures} violation(s)." >&2
    exit 1
fi
