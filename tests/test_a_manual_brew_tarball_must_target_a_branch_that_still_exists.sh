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

# RED TEAM DMG #27 F3-1 (walk #27 item 6b) replaced the branch fetch
# (tarball/main) with a pinned RELEASE TAG verified by sha256, which is what
# tests/test_homebrew_bootstrap_is_pinned.sh checks in full. What this test
# still owns: the manual no-sudo path exists and never targets the retired
# master branch (or any branch).
if ! grep -q 'Homebrew/brew/archive/refs/tags/' "$INSTALL_SH"; then
    fail_test "install.sh no longer fetches a Homebrew/brew release tag archive. If the manual tarball install path was removed, remove this test with it rather than leave it to fail blind."
else
    ok "install.sh fetches a pinned Homebrew/brew release tag"
fi
if grep -qE 'Homebrew/brew/tarball/(master|main)' "$INSTALL_SH"; then
    fail_test "install.sh still fetches a Homebrew/brew BRANCH tarball. Branches move (and master was retired); fetch the pinned tag."
else
    ok "install.sh does not fetch a moving Homebrew/brew branch"
fi

echo ""
if [[ $failures -eq 0 ]]; then
    echo "PASS: the manual Homebrew tarball install targets a pinned release tag."
    exit 0
else
    echo "FAIL: ${failures} violation(s)." >&2
    exit 1
fi
