#!/usr/bin/env bash
# Bulletproof GDPR-export detection for Ostler's import.
#
# Identifies exports by their SIGNATURE FILES (content), never by the folder
# or zip NAME -- so a customer can drop ANY shape of export and Ostler still
# finds it:
#   - LinkedIn "Basic" OR "Complete" export, or a renamed folder/zip
#   - an export left ZIPPED (never unzipped) or already extracted
#   - exports nested a few folders deep inside the download
#
# The actual importer (ostler-import) is content-based and recurses the whole
# search dir, so detection only has to (a) decide whether an import is worth
# running and (b) --unzip any signature-bearing .zip first so its loose files
# become visible to the parsers.
#
# Usage:
#   ostler-detect-exports.sh <dir> [--unzip]
# Prints one  "LABEL<TAB>path"  line per detected export (path = the export's
# top-level folder under <dir>, or the .zip itself). Exit 0 if >=1 detected,
# 1 if none. With --unzip, signature-bearing zips are extracted in place first.
set -uo pipefail

DIR="${1:-}"
DO_UNZIP=0
[[ "${2:-}" == "--unzip" ]] && DO_UNZIP=1
[[ -n "$DIR" && -d "$DIR" ]] || exit 1

# platform <US> extended-regex of signature basenames (a file OR dir whose
# name is specific enough to identify the source export). Kept deliberately
# high-signal to avoid false positives. <US> = unit separator (0x1f).
SIGS=(
  $'LinkedIn\x1f^Connections\\.csv$'
  $'Facebook\x1f^your_friends\\.json$|^friends\\.json$'
  $'Instagram\x1f^followers_and_following$|^followers_1\\.json$'
  $'X\x1f^tweets\\.js$|^tweet\\.js$'
  $'Google\x1f^watch-history\\.json$|^MyActivity\\.json$|^My Activity$'
  $'Spotify\x1f^StreamingHistory.*\\.json$|^YourLibrary\\.json$|^Userdata\\.json$'
  $'Netflix\x1f^ViewingActivity\\.csv$'
  $'Amazon\x1f^Retail\\.OrderHistory.*\\.csv$|^Digital Items\\.csv$'
  $'Reddit\x1f^post_headers\\.csv$|^saved_posts\\.csv$'
  $'TikTok\x1f^user_data.*\\.json$'
  $'Pinterest\x1f^boards\\.csv$|^pins\\.csv$'
  $'Discord\x1f^messages\\.csv$|^activity$'
)

# --- 1. Optionally unzip any signature-bearing archive -----------------------
# Build one combined regex (path form) for matching zip member lists.
_zip_re=""
for entry in "${SIGS[@]}"; do
    re="${entry#*$'\x1f'}"
    # member paths look like "folder/Connections.csv"; strip the ^...$ anchors
    re_unanchored="${re//^/}"; re_unanchored="${re_unanchored//\$/}"
    _zip_re="${_zip_re:+$_zip_re|}${re_unanchored}"
done

if [[ "$DO_UNZIP" == "1" ]]; then
    while IFS= read -r z; do
        [[ -f "$z" ]] || continue
        if unzip -Z1 "$z" 2>/dev/null | grep -qiE "(${_zip_re})"; then
            dest="${z%.zip}"
            # Only extract once; never clobber an already-unzipped folder.
            if [[ ! -d "$dest" ]]; then
                mkdir -p "$dest" 2>/dev/null || true
                unzip -oq "$z" -d "$dest" 2>/dev/null || true
            fi
        fi
    done < <(find "$DIR" -maxdepth 2 -type f -iname '*.zip' 2>/dev/null || true)
fi

# --- 2. Content detection over loose files (post-unzip) ----------------------
# Resolve the export's top-level folder under DIR (so the friendly label and
# the dedupe key are stable regardless of the export's internal nesting).
_top_under() {  # $1 = a hit path; echoes the first path component below DIR
    local p="$1" parent
    while :; do
        parent="$(dirname "$p")"
        [[ "$parent" == "$DIR" || "$parent" == "/" || "$parent" == "." ]] && break
        p="$parent"
    done
    printf '%s\n' "$p"
}

found_any=1
declare -a SEEN_TOPS=()
for entry in "${SIGS[@]}"; do
    label="${entry%%$'\x1f'*}"
    re="${entry#*$'\x1f'}"
    while IFS= read -r hit; do
        [[ -n "$hit" ]] || continue
        top="$(_top_under "$hit")"
        # de-dup identical top folders reported by multiple signatures
        skip=0
        for s in ${SEEN_TOPS[@]+"${SEEN_TOPS[@]}"}; do [[ "$s" == "$label::$top" ]] && skip=1 && break; done
        [[ "$skip" == "1" ]] && continue
        SEEN_TOPS+=("$label::$top")
        printf '%s\t%s\n' "$label" "$top"
        found_any=0
    done < <(find "$DIR" -maxdepth 6 \( -type f -o -type d \) 2>/dev/null \
                | awk -F/ -v re="$re" 'tolower($NF) ~ tolower(re) || $NF ~ re {print}' \
                | head -5)
done

exit "$found_any"
