#!/usr/bin/env bash
# check_no_em_dashes.sh - house typography gate.
#
# Hard rule (owner-locked): NO em dash (U+2014) anywhere in shipped
# user-facing copy. The house convention is the EN DASH (U+2013 '-')
# with spaces, or a literal ASCII '--'. Em dashes "smack of AI slop"
# and are banned outright. This gate mechanically catches the recurring
# class so it cannot slip back into a cut.
#
# The gate greps the shipped copy files for the em-dash character and
# FAILS (exit 1) if any is found, printing file:line for each hit.
#
# It also emits a NON-FATAL advisory listing ' -- ' occurrences inside
# the JSON copy files' user-facing values (excluding _meta / _exempt /
# note developer-only keys), so reviewers can eyeball any stray
# placeholder dash. Only the em-dash check can fail the build.
#
# Shipped copy files scanned:
#   install.sh                                        (echoed / printed copy)
#   install.sh.strings.*.sh                           (MSG_* catalogues, all locales)
#   gui/OstlerInstaller/Resources/ViewCopy.json       (SwiftUI GUI strings)
#   gui/OstlerInstaller/Resources/HintCopy.json       (SwiftUI GUI hints)
#
# Usage: scripts/check_no_em_dashes.sh
# Exit:  0 = clean, 1 = em dash found, 2 = no copy files found (misconfig).

set -euo pipefail

# Resolve repo root (this script lives in scripts/).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

# U+2014 EM DASH as raw UTF-8 bytes, so this script contains no literal
# em dash itself (and stays portable across bash 3.2 / 5.x / zsh).
EMDASH="$(printf '\xe2\x80\x94')"

# Collect the shipped user-facing copy files that actually exist.
FILES=()
[ -f install.sh ] && FILES+=("install.sh")
for f in install.sh.strings.*.sh; do
    [ -f "$f" ] && FILES+=("$f")
done
[ -f gui/OstlerInstaller/Resources/ViewCopy.json ] && FILES+=("gui/OstlerInstaller/Resources/ViewCopy.json")
[ -f gui/OstlerInstaller/Resources/HintCopy.json ] && FILES+=("gui/OstlerInstaller/Resources/HintCopy.json")

if [ "${#FILES[@]}" -eq 0 ]; then
    echo "check_no_em_dashes: ERROR - no shipped copy files found (run from repo root)." >&2
    exit 2
fi

echo "check_no_em_dashes: scanning ${#FILES[@]} shipped copy file(s) for em dashes (U+2014)..."

hits="$(grep -Hn -- "$EMDASH" "${FILES[@]}" 2>/dev/null || true)"

if [ -n "$hits" ]; then
    {
        echo ""
        echo "FAIL: em dash (U+2014) found in shipped user-facing copy."
        echo "House convention: EN DASH (U+2013) with spaces, or ASCII '--'. Never an em dash."
        echo "Offending file:line ->"
        echo "$hits" | sed 's/^/  /'
    } >&2
    exit 1
fi

echo "check_no_em_dashes: PASS - no em dashes in shipped copy."

# --- Non-fatal advisory: ' -- ' inside JSON copy user-facing values ---
for jf in gui/OstlerInstaller/Resources/ViewCopy.json gui/OstlerInstaller/Resources/HintCopy.json; do
    [ -f "$jf" ] || continue
    adv="$(grep -Hn ' -- ' "$jf" 2>/dev/null | grep -vE '"(_meta|_exempt|note)' || true)"
    if [ -n "$adv" ]; then
        echo ""
        echo "advisory (non-fatal): ' -- ' in $jf user-facing value(s) - consider an en dash:"
        echo "$adv" | sed 's/^/  /'
    fi
done

exit 0
