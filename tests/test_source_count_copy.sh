#!/usr/bin/env bash
# Regression guard (2026-10-21): customer-facing copy states the real source
# count. Source of truth: 40+ sources overall (39 on the Mac, 42 with the
# iPhone app), 18 platform exports, ten Apple-native.
#
# Refuses the retired claim "20 platforms" / "20+ platforms" / "around 20
# platforms" in the three places a customer reads it:
#   - the install-time data-sources screen (install.sh, echo lines)
#   - the exports-ack help text (install.sh.strings.en-GB.sh)
#   - the installer's import-pipeline hint (HintCopy.json)
# and requires the canonical wording in each.
#
# Control: the stale detector is first run on a synthetic stale line and must
# fire, so a detector that matches nothing cannot pass.
#
# Bash 3.2 safe. No pipes into grep -q (pipefail ratchet): here-strings only.
# Exit 0 clean, 1 on any stale or missing wording.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

INSTALL="${REPO_ROOT}/install.sh"
STRINGS="${REPO_ROOT}/install.sh.strings.en-GB.sh"
HINTS="${REPO_ROOT}/gui/OstlerInstaller/Resources/HintCopy.json"

STALE_RE='(from|around|for|of) +(around +)?20\+? +platforms|twenty +platforms|\+15 +sources'

fails=0
is_stale() { local s="$1"; [[ "$s" =~ $STALE_RE ]]; }

# Control: the detector must fire on the retired phrasings.
for sample in \
    'Ostler imports from 20 platforms. Request your data exports' \
    'Ostler imports from around 20 platforms. The full list' \
    '"subtitle": "Parsers for 20+ platforms"'; do
    if ! is_stale "$sample"; then
        printf 'FAIL: stale detector did not fire on control: %s\n' "$sample" >&2
        fails=$((fails + 1))
    fi
done

for f in "$INSTALL" "$STRINGS" "$HINTS"; do
    if [[ ! -f "$f" ]]; then
        printf 'FAIL: cannot read %s\n' "$f" >&2
        fails=$((fails + 1))
    fi
done
[[ "$fails" -eq 0 ]] || exit 1

n=0
while IFS= read -r line; do
    n=$((n + 1))
    # Only customer-rendered lines: install.sh echo lines, MSG_ values, JSON.
    case "$line" in
        *'echo '*|MSG_*|*'"subtitle"'*) ;;
        *) continue ;;
    esac
    if is_stale "$line"; then
        printf 'FAIL: stale source count: %s\n' "$line" >&2
        fails=$((fails + 1))
    fi
done < <(cat "$INSTALL" "$STRINGS" "$HINTS")

require() {
    local file="$1" want="$2"
    local body
    body="$(cat "$file")"
    if [[ "$body" != *"$want"* ]]; then
        printf 'FAIL: %s lacks canonical wording: %s\n' "${file#"${REPO_ROOT}"/}" "$want" >&2
        fails=$((fails + 1))
    fi
}
require "$INSTALL" 'Ostler imports 18 platform exports. Request your data exports'
require "$STRINGS" 'Ostler imports 18 platform exports. The full list'
require "$HINTS" '"Parsers for 40+ sources"'

if [[ "$fails" -ne 0 ]]; then
    printf 'test_source_count_copy: %d failure(s) over %d lines\n' "$fails" "$n" >&2
    exit 1
fi
printf 'test_source_count_copy: OK (%d lines scanned, 3 controls fired, 3 canonical strings present)\n' "$n"
