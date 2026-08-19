#!/usr/bin/env bash
#
# tests/test_gdpr_folder_access_denied.sh
#
# #619: the GDPR export scan must distinguish a folder it cannot READ
# (TCC or POSIX permission denied) from a genuinely EMPTY one. Before
# this fix, every scan ended `find ... 2>/dev/null || true`, so an
# access denial yielded zero hits indistinguishable from "nothing
# here" -- the customer's exports could sit in a denied folder and they
# would be told nothing was found, a silent dead-end.
#
# This test extracts the REAL `_gdpr_folder_readable` helper from
# install.sh and exercises it against:
#   - a readable empty folder        -> readable (exit 0)
#   - a readable non-empty folder    -> readable (exit 0)
#   - a folder denied via chmod 000  -> denied  (exit non-zero)
# It also asserts the three customer-facing strings the surfacing path
# depends on are defined in the catalogue.
#
# POSIX chmod 000 is the portable stand-in for a TCC denial: both make
# the directory exist while `ls` fails, which is exactly the signal the
# helper keys on. Real TCC denial can only be exercised on a live
# macOS box (see the PR description); this proves the discriminator.
#
# Pure bash. Synthetic dirs only.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${SCRIPT_DIR}/../install.sh"
STRINGS="${SCRIPT_DIR}/../install.sh.strings.en-GB.sh"
WORK="$(mktemp -d)"
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$INSTALL_SH" ]] || fail "install.sh not found"
bash -n "$INSTALL_SH" || fail "install.sh fails bash -n"
echo "PASS: install.sh parses"

# Extract the real helper definition from install.sh so we test the
# shipped code, not a copy.
HELPER="$(awk '/^_gdpr_folder_readable\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$INSTALL_SH")"
printf '%s\n' "$HELPER" | grep -q 'ls "\$1"' \
    || fail "could not extract _gdpr_folder_readable from install.sh"
eval "$HELPER"
echo "PASS: extracted the real _gdpr_folder_readable helper"

# ── readable empty folder -> readable ─────────────────────────────────
mkdir -p "$WORK/empty"
if _gdpr_folder_readable "$WORK/empty"; then
    echo "PASS: readable empty folder reads as readable"
else
    fail "readable empty folder wrongly reported as denied"
fi

# ── readable non-empty folder -> readable ─────────────────────────────
mkdir -p "$WORK/full"
: > "$WORK/full/Connections.csv"
if _gdpr_folder_readable "$WORK/full"; then
    echo "PASS: readable non-empty folder reads as readable"
else
    fail "readable non-empty folder wrongly reported as denied"
fi

# ── denied folder -> denied ───────────────────────────────────────────
# Root bypasses POSIX perms, so the denial cannot be simulated as root.
# Skip loudly (no silent cap) rather than assert a guarantee we cannot
# make on this host.
mkdir -p "$WORK/denied"
: > "$WORK/denied/Connections.csv"
chmod 000 "$WORK/denied"
if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    echo "SKIP: running as root; cannot simulate a permission denial (POSIX perms are bypassed). The discriminator is ls exit status; verify on a non-root host or a real TCC-clean macOS box."
else
    if _gdpr_folder_readable "$WORK/denied"; then
        chmod u+rwx "$WORK/denied"
        fail "denied folder (chmod 000) wrongly reported as readable -- the silent-failure hole is NOT closed"
    else
        echo "PASS: denied folder reads as denied (exits non-zero), so it is recorded not treated as empty"
    fi
fi
chmod u+rwx "$WORK/denied" 2>/dev/null

# ── the customer-facing strings the surfacing path needs exist ────────
[[ -f "$STRINGS" ]] || fail "strings catalogue not found"
for key in \
    MSG_WARN_FOLDER_ACCESS_DENIED_SCAN \
    MSG_INFO_FOLDER_ACCESS_DENIED_GUIDANCE \
    MSG_INFO_GDPR_SCAN_BLOCKED_BY_PERMISSIONS; do
    grep -qE "^${key}=" "$STRINGS" || fail "missing string: $key"
done
echo "PASS: all three #619 strings are defined in the catalogue"

# ── the %s template carries exactly one placeholder ───────────────────
tmpl="$(grep -E '^MSG_WARN_FOLDER_ACCESS_DENIED_SCAN=' "$STRINGS")"
[[ "$(grep -oc '%s' <<<"$tmpl")" == "1" ]] \
    || fail "MSG_WARN_FOLDER_ACCESS_DENIED_SCAN must carry exactly one %s for the folder path"
echo "PASS: denial warning template carries one %s placeholder"

echo ""
echo "ALL PASS: test_gdpr_folder_access_denied.sh"
