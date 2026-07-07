#!/usr/bin/env bash
#
# scripts/check_strings_key_parity.sh
#
# Informational key-parity checker for the install.sh strings
# catalogues (W7 per-key fallback fix, 2026-07-07).
#
# Lists, per locale, every MSG_* key present in the en-GB base
# catalogue but absent from that locale's catalogue (and any extra
# keys the locale defines that en-GB does not, which usually means a
# renamed/orphaned key).
#
# Since the install.sh loader now overlays the selected locale on top
# of the en-GB base, a missing translated key degrades gracefully to
# English text rather than a set -u crash, so this checker does NOT
# fail the build by default -- it exists to keep translation drift
# visible. Run with --strict to exit 1 on any drift (for future CI
# tightening once the catalogues are topped up).
#
# Usage:
#   scripts/check_strings_key_parity.sh            # informational, exit 0
#   scripts/check_strings_key_parity.sh --strict   # exit 1 on drift
#   scripts/check_strings_key_parity.sh --summary  # counts only, no key lists

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="${REPO_ROOT}/install.sh.strings.en-GB.sh"

STRICT=0
SUMMARY=0
for arg in "$@"; do
    case "$arg" in
        --strict)  STRICT=1 ;;
        --summary) SUMMARY=1 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

if [[ ! -f "$BASE" ]]; then
    echo "FATAL: en-GB base catalogue not found at $BASE" >&2
    exit 2
fi

list_keys() { grep -oE '^MSG_[A-Z0-9_]+' "$1" | sort -u; }

BASE_KEYS_FILE="$(mktemp)"
trap 'rm -f "$BASE_KEYS_FILE"' EXIT
list_keys "$BASE" > "$BASE_KEYS_FILE"
BASE_COUNT="$(wc -l < "$BASE_KEYS_FILE" | tr -d ' ')"

echo "Base catalogue: install.sh.strings.en-GB.sh (${BASE_COUNT} keys)"
echo

DRIFT=0
FOUND_LOCALE=0
for catalogue in "$REPO_ROOT"/install.sh.strings.*.sh; do
    [[ "$catalogue" == "$BASE" ]] && continue
    FOUND_LOCALE=1
    name="$(basename "$catalogue")"
    lang="${name#install.sh.strings.}"
    lang="${lang%.sh}"

    locale_keys="$(list_keys "$catalogue")"
    locale_count="$(wc -l <<<"$locale_keys" | tr -d ' ')"
    missing="$(comm -23 "$BASE_KEYS_FILE" <(printf '%s\n' "$locale_keys"))"
    extra="$(comm -13 "$BASE_KEYS_FILE" <(printf '%s\n' "$locale_keys"))"
    missing_count=0; [[ -n "$missing" ]] && missing_count="$(wc -l <<<"$missing" | tr -d ' ')"
    extra_count=0;   [[ -n "$extra"   ]] && extra_count="$(wc -l <<<"$extra" | tr -d ' ')"

    printf '%s: %s keys | %s untranslated (en-GB fallback) | %s extra\n' \
        "$lang" "$locale_count" "$missing_count" "$extra_count"

    if [[ "$SUMMARY" -eq 0 ]]; then
        if [[ -n "$missing" ]]; then
            sed 's/^/    missing: /' <<<"$missing"
        fi
        if [[ -n "$extra" ]]; then
            sed 's/^/    extra:   /' <<<"$extra"
        fi
    fi
    if [[ "$missing_count" -gt 0 || "$extra_count" -gt 0 ]]; then
        DRIFT=1
    fi
done

if [[ "$FOUND_LOCALE" -eq 0 ]]; then
    echo "No non-en-GB catalogues found; nothing to compare." >&2
fi

echo
if [[ "$DRIFT" -eq 0 ]]; then
    echo "All locale catalogues have full key parity with en-GB."
else
    echo "Drift detected. Untranslated keys render in English via the loader's en-GB base layer (graceful, not a crash)."
fi

if [[ "$STRICT" -eq 1 && "$DRIFT" -eq 1 ]]; then
    exit 1
fi
exit 0
