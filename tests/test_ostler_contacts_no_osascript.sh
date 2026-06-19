#!/usr/bin/env bash
#
# tests/test_ostler_contacts_no_osascript.sh
#
# CX-453 posture guard for the ostler-contacts native helper (spec §8.2 #6).
#
# The whole point of the native CNContact writer is that it does NOT use
# osascript / AppleEvents to touch Contacts (CX-453 deliberately moved
# Ostler off osascript-to-Contacts; the merge-via-osascript path was
# explicitly REJECTED in the BW-A spec §2.1). This test pins that the
# helper's Swift sources contain ZERO osascript / AppleScript Contacts
# automation, so a future "convenience" edit that reaches for osascript
# trips here.
#
# Pure bash + grep. Synthetic (source-text inspection), no Contacts access.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_SRC="${REPO_ROOT}/gui/ostler-contacts/Sources"

fail_test() { echo "FAIL: $*" >&2; exit 1; }

[[ -d "$PKG_SRC" ]] || fail_test "ostler-contacts Sources dir not found at $PKG_SRC"

# Strip line comments (// ...) before grepping so explanatory prose that
# merely *mentions* osascript (e.g. "osascript was REJECTED") does not trip
# the guard. We only care about executable code.
strip_comments() { sed -E 's://.*$::' "$1"; }

hits=0
while IFS= read -r -d '' f; do
    code="$(strip_comments "$f")"
    if grep -qE 'osascript|NSAppleScript|tell application "Contacts"' <<<"$code"; then
        echo "  offending file: $f" >&2
        grep -nE 'osascript|NSAppleScript|tell application "Contacts"' <<<"$code" >&2
        hits=$((hits + 1))
    fi
done < <(find "$PKG_SRC" -name '*.swift' -print0)

if [[ "$hits" -gt 0 ]]; then
    fail_test "ostler-contacts must be pure CNContact: found osascript/AppleScript "
fi
echo "PASS: ostler-contacts Swift sources contain zero osascript/AppleScript Contacts automation"

# Positive assertion: the destructive path uses CNSaveRequest (proves it is
# the native writer, not a shelled-out one).
if ! grep -rqE 'CNSaveRequest' "$PKG_SRC"; then
    fail_test "expected the native CNSaveRequest writer in ostler-contacts Sources"
fi
echo "PASS: ostler-contacts uses the native CNSaveRequest writer"

echo "ALL PASS: test_ostler_contacts_no_osascript.sh"
