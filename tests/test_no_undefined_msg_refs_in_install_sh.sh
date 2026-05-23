#!/usr/bin/env bash
# Regression guard (CX-18, locked 2026-05-23):
# every $MSG_* reference in install.sh MUST have a matching MSG_*=
# definition in install.sh.strings.en-GB.sh.
#
# The exact failure shape this refuses:
#   install.sh sources install.sh.strings.en-GB.sh under `set -u`, then
#   references $MSG_OK_OSTLER_FDA_INSTALLED_VENV — but the catalogue
#   lift in PR #161 added the 3 sibling keys (info / 2x warn) and
#   missed the ok key. Bash hits an unbound-variable error inside
#   the email_ingest step, terminates the subprocess, and the GUI
#   reports exit-success — so the installer silently bails mid-step
#   with steps 18-21+ (wiki recompile, Marvin spin-up, iMessage
#   bridge, etc.) never running. Studio retest #13 caught this on
#   DMG #15 (2026-05-23). A single-key gap detonated the install.
#
# This test walks every $MSG_* reference in install.sh byte-by-byte
# (both bare $MSG_ and ${MSG_} forms) and asserts every name appears
# as an MSG_NAME= definition in install.sh.strings.en-GB.sh. Refuses
# CI green on any gap.
#
# References:
#   - feedback_silent_bail_regression_test_shape (refuse the exact failure shape)
#   - feedback_customer_strings_extractable_from_day_one (Rule 0.9 catalogue)
#
# Exit 0 on clean. Exit 1 on any undefined reference.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

INSTALL_SH="$REPO_ROOT/install.sh"
CATALOGUE="$REPO_ROOT/install.sh.strings.en-GB.sh"

if [[ ! -f "$INSTALL_SH" ]]; then
    echo "FAIL: install.sh not found at $INSTALL_SH" >&2
    exit 1
fi
if [[ ! -f "$CATALOGUE" ]]; then
    echo "FAIL: install.sh.strings.en-GB.sh not found at $CATALOGUE" >&2
    exit 1
fi

REFS_FILE="$(mktemp -t msg-refs.XXXXXX)"
DEFS_FILE="$(mktemp -t msg-defs.XXXXXX)"
trap 'rm -f "$REFS_FILE" "$DEFS_FILE"' EXIT

# Extract every $MSG_* or ${MSG_*} reference name from install.sh.
# Matches: $MSG_FOO , ${MSG_FOO} , ${MSG_FOO:-default}
grep -oE '\$\{?MSG_[A-Z0-9_]+' "$INSTALL_SH" \
    | sed -E 's/^\$\{?//' \
    | sort -u > "$REFS_FILE"

# Extract every MSG_* assignment name from the en-GB catalogue.
# Matches: MSG_FOO=... at start of line.
grep -oE '^MSG_[A-Z0-9_]+=' "$CATALOGUE" \
    | sed 's/=$//' \
    | sort -u > "$DEFS_FILE"

REFS_COUNT=$(wc -l < "$REFS_FILE" | tr -d ' ')
DEFS_COUNT=$(wc -l < "$DEFS_FILE" | tr -d ' ')

UNDEFINED="$(comm -23 "$REFS_FILE" "$DEFS_FILE")"

if [[ -n "$UNDEFINED" ]]; then
    echo "FAIL: install.sh references MSG_* keys that have no MSG_*= definition" >&2
    echo "      in install.sh.strings.en-GB.sh. Under set -u, the first such" >&2
    echo "      reference at runtime will silently terminate the installer." >&2
    echo "" >&2
    echo "Undefined keys (referenced but not defined):" >&2
    echo "$UNDEFINED" | sed 's/^/    /' >&2
    echo "" >&2
    echo "Fix: add each missing MSG_NAME=\"...\" line to install.sh.strings.en-GB.sh" >&2
    echo "(keep the file alphabetically sorted within its MSG_OK_/MSG_INFO_/etc. block)." >&2
    exit 1
fi

echo "PASS: all $REFS_COUNT MSG_* references in install.sh resolve to one of $DEFS_COUNT catalogue definitions."
