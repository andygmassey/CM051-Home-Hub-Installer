#!/usr/bin/env bash
# The dead tarball URL must not be advertised to a human as a working default.
#
# releases/latest/download/install.tar.gz 404s (no tarball published since
# v0.3.0). The code default is DECLARED known-absent and refuses honestly
# (test_a_missing_tarball_is_not_a_network_problem.sh), but two places still
# TOLD a reader it works: the install.sh --help text ("Default: <url>") and the
# RELEASE.md verify step (curl -sI <url>). Link sweep 2026-10-25.
#
# Usage: test_dead_tarball_url_is_not_advertised.sh [install.sh] [RELEASE.md]
# Exit 0 pass, 1 fail, 2 cannot-run.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${1:-${HERE}/../install.sh}"
RELEASE_MD="${2:-${HERE}/../RELEASE.md}"
DEAD='releases/latest/download/install.tar.gz'
for f in "$INSTALL_SH" "$RELEASE_MD"; do
    [ -r "$f" ] || { echo "CANNOT-RUN: $f unreadable"; exit 2; }
done

fail=0
# Control: the code default must still exist, so a rename cannot make this vacuous.
if ! /usr/bin/grep -q '^DEFAULT_INSTALLER_TARBALL_URL=' "$INSTALL_SH"; then
    echo "CANNOT-RUN: DEFAULT_INSTALLER_TARBALL_URL not found; extractor would examine nothing"; exit 2
fi

# 1. --help must not present the dead URL as the Default.
if /usr/bin/grep -nE 'echo ".*Default: .*'"${DEAD}" "$INSTALL_SH"; then
    echo "FAIL: install.sh help advertises the dead tarball URL as a default"; fail=1
fi
# 2. RELEASE.md must not tell the releaser to curl the dead URL as a verify step.
if /usr/bin/grep -nE '^curl .*'"${DEAD}" "$RELEASE_MD"; then
    echo "FAIL: RELEASE.md verify step curls the dead tarball URL"; fail=1
fi
# 3. The replacement must point at the DMG redirect.
/usr/bin/grep -q 'curl -sI https://ostler.ai/install.dmg' "$RELEASE_MD" \
    || { echo "FAIL: RELEASE.md verify step does not check ostler.ai/install.dmg"; fail=1; }
/usr/bin/grep -q 'No default is published' "$INSTALL_SH" \
    || { echo "FAIL: install.sh help does not say no tarball default is published"; fail=1; }

[ $fail -eq 0 ] && echo "PASS: dead tarball URL not advertised"
exit $fail
