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
# running and (b) --unzip any export-shaped .zip first so its loose files
# become visible to the parsers.
#
# Usage:
#   ostler-detect-exports.sh <dir> [--unzip]
# Prints one  "LABEL<TAB>path"  line per detected export (path = the export's
# top-level folder under <dir>, or the .zip itself). Exit 0 if >=1 detected,
# 1 if none. With --unzip: every .zip the scan finds is either opened, or its
# skip is counted and reported on stderr as one UNZIP_SUMMARY line (counts
# only, no filenames) -- see section 1 below.
set -uo pipefail

DIR="${1:-}"
DO_UNZIP=0
[[ "${2:-}" == "--unzip" ]] && DO_UNZIP=1
[[ -n "$DIR" && -d "$DIR" ]] || exit 1

# platform <US> extended-regex of signature basenames (a file OR dir whose
# name is specific enough to identify the source export). Kept deliberately
# high-signal to avoid false positives. <US> = unit separator (0x1f).
#
# USED FOR LABELLING ONLY (section 2, below) -- which platform a detected
# export belongs to. It is NOT the gate for whether a zip gets opened; see
# the 2026-09-12 note in section 1 for why that used to be the same test and
# why that was the defect.
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

# --- 1. Optionally unzip archives worth opening -------------------------------
# Build one combined regex (path form) for matching zip member lists: the
# per-platform SIGS basenames above, PLUS a broad export-SHAPE test (any
# csv/json/html/ics/js member -- the file types every GDPR/platform export
# actually ships).
#
# WHY THE SHAPE TEST EXISTS (measured 2026-09-12, a real install, Andy's
# explicit instruction, outside the launch freeze): this gate used to be
# SIGS alone. SIGS names exactly 12 platforms' manifest files. A customer's
# Downloads can hold genuine exports from MORE than 12 platforms, or a
# multi-part / split archive whose manifest file lives in a DIFFERENT
# volume than the one being tested. Gating extraction on SIGS alone meant
# every such zip was silently never opened: no branch, no log line, no
# count -- found by the find below, then dropped with nothing said. The
# customer's content-based importer then saw nothing and nothing said why.
# 46 real archives, 25 never opened, zero of the 25 named anywhere.
#
# The shape test is a FLOOR, not a replacement for SIGS, and not "unzip
# everything": a zip with NO data-shaped member at all (an installer, a
# photo archive, the empty decoy in
# tests/test_export_detect_large_zip_behaviour.sh) is still left alone.
_zip_re=""
for entry in "${SIGS[@]}"; do
    re="${entry#*$'\x1f'}"
    # member paths look like "folder/Connections.csv"; strip the ^...$ anchors
    re_unanchored="${re//^/}"; re_unanchored="${re_unanchored//\$/}"
    _zip_re="${_zip_re:+$_zip_re|}${re_unanchored}"
done
_zip_shape_re='\.(csv|json|html?|ics|js)$'
_zip_open_re="${_zip_re}|${_zip_shape_re}"

if [[ "$DO_UNZIP" == "1" ]]; then
    _uz_found=0; _uz_opened=0; _uz_already=0
    _uz_skipped_norecognised=0; _uz_skipped_password=0; _uz_skipped_other=0
    while IFS= read -r z; do
        [[ -f "$z" ]] || continue
        _uz_found=$((_uz_found + 1))
        # `grep -c` (never `-q`) so it always reads the whole listing: under
        # `pipefail`, a short-circuiting consumer can make unzip take SIGPIPE
        # and invert a real match to "not found" (#889/#1124). Measured only
        # on Darwin; see tests/test_export_detect_large_zip_behaviour.sh.
        if [ "$(unzip -Z1 "$z" 2>/dev/null | grep -ciE "(${_zip_open_re})")" -eq 0 ]; then
            # Nothing export-shaped in this archive at all. Counted, not silent.
            _uz_skipped_norecognised=$((_uz_skipped_norecognised + 1))
            continue
        fi
        dest="${z%.zip}"
        # Only extract once; never clobber an already-unzipped folder.
        if [[ -d "$dest" ]]; then
            _uz_already=$((_uz_already + 1))
            continue
        fi
        mkdir -p "$dest" 2>/dev/null || true
        _uz_err="$(unzip -oq "$z" -d "$dest" 2>&1 1>/dev/null)"; _uz_rc=$?
        if [[ "$_uz_rc" -eq 0 ]]; then
            _uz_opened=$((_uz_opened + 1))
        else
            # Extraction failed for an archive that WAS worth opening. Remove
            # the empty dest so a later run retries rather than mistaking it
            # for "already extracted", and count + classify the failure
            # rather than swallowing it -- the previous form here was
            # `... || true`, which is exactly the silence this fix removes.
            rmdir "$dest" 2>/dev/null || true
            # `grep -c` (never `-q`), same reason as the shape test above.
            if [ "$(printf '%s' "$_uz_err" | grep -ci "password")" -gt 0 ]; then
                _uz_skipped_password=$((_uz_skipped_password + 1))
            else
                _uz_skipped_other=$((_uz_skipped_other + 1))
            fi
        fi
    done < <(find "$DIR" -maxdepth 2 -type f -iname '*.zip' 2>/dev/null || true)
    # Counts only, no filenames, on STDERR -- so it never mixes with the
    # "LABEL<TAB>path" hits on stdout that callers (install.sh, the export
    # watcher) already parse.
    printf 'UNZIP_SUMMARY found=%s opened=%s already=%s skipped_norecognised=%s skipped_password=%s skipped_other=%s\n' \
        "$_uz_found" "$_uz_opened" "$_uz_already" "$_uz_skipped_norecognised" "$_uz_skipped_password" "$_uz_skipped_other" >&2
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
