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
DO_LOOSE=0
[[ "${2:-}" == "--unzip" ]] && DO_UNZIP=1
[[ "${2:-}" == "--loose" ]] && DO_LOOSE=1
[[ -n "$DIR" && -d "$DIR" ]] || exit 1

# --- F010: bounded scan (depth cap, time budget, nested-backup skip) ---------
# A 52-minute scan was measured when Desktop held a copied old-Mac home folder
# (its own Library/ and Documents/ tree). Three guards, all env-overridable:
#   OSTLER_SCAN_MAXDEPTH  find depth cap (default 6, the depth every known
#                         export shape fits in)
#   OSTLER_SCAN_BUDGET_S  wall-clock budget in seconds for the WHOLE INSTALL
#                         (default 300). 0 = scan nothing and report
#                         budget_hit=1.
#   OSTLER_SCAN_DEADLINE_EPOCH  absolute epoch-seconds deadline. install.sh
#                         computes it ONCE (now + budget) and exports it, so
#                         every invocation (unzip, loose, default) shares one
#                         budget. Unset or non-numeric: this invocation starts
#                         its own (now + budget), which is the standalone case.
#   nested backups        any directory below DIR that itself holds a Library/
#                         or Users/ subtree is pruned, never walked.
# Counts only (never paths) go to STDERR as one SCAN_SUMMARY line, so the
# "LABEL<TAB>path" hits on stdout stay parseable. State lives in files because
# every find runs inside a process substitution (a subshell).
SCAN_MAXDEPTH="${OSTLER_SCAN_MAXDEPTH:-6}"
SCAN_BUDGET_S="${OSTLER_SCAN_BUDGET_S:-300}"
case "$SCAN_MAXDEPTH" in ''|*[!0-9]*|0) SCAN_MAXDEPTH=6 ;; esac
case "$SCAN_BUDGET_S" in ''|*[!0-9]*) SCAN_BUDGET_S=300 ;; esac
_SCAN_STATE="$(mktemp -d "${TMPDIR:-/tmp}/ostler-scan.XXXXXX")" || exit 1
SCAN_DEADLINE="${OSTLER_SCAN_DEADLINE_EPOCH:-}"
case "$SCAN_DEADLINE" in ''|*[!0-9]*) SCAN_DEADLINE=$(( $(date +%s) + SCAN_BUDGET_S )) ;; esac
_scan_summary() {
    local skipped=0 hit=0
    [[ -f "$_SCAN_STATE/skipped" ]] && skipped="$(cat "$_SCAN_STATE/skipped")"
    [[ -f "$_SCAN_STATE/budget_hit" ]] && hit=1
    printf 'SCAN_SUMMARY skipped_nested_backups=%s budget_hit=%s maxdepth=%s budget_s=%s\n' \
        "$skipped" "$hit" "$SCAN_MAXDEPTH" "$SCAN_BUDGET_S" >&2
    rm -rf "$_SCAN_STATE"
}
trap _scan_summary EXIT

# _bfind <find args...>: run find to a temp file under the shared deadline.
# Kills only the find it started. Output is whatever was found before the stop.
_bfind() {
    local out pid
    if (( $(date +%s) >= SCAN_DEADLINE )); then
        : > "$_SCAN_STATE/budget_hit"
        return 0
    fi
    out="$(mktemp "$_SCAN_STATE/find.XXXXXX")" || return 0
    find "$@" > "$out" 2>/dev/null &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if (( $(date +%s) >= SCAN_DEADLINE )); then
            kill "$pid" 2>/dev/null
            : > "$_SCAN_STATE/budget_hit"
            break
        fi
        sleep 0.2
    done
    wait "$pid" 2>/dev/null
    cat "$out"
    rm -f "$out"
    return 0
}

# Nested home-folder backups: parents (below DIR) of a Library/ or Users/ dir.
# Depth 4 finds roots up to 3 levels down, where a copied backup sits.
SCAN_PRUNE=()
_scan_find_backups() {
    local root esc n=0
    while IFS= read -r root; do
        [[ -n "$root" && "$root" != "$DIR" ]] || continue
        esc="${root//\\/\\\\}"; esc="${esc//\*/\\*}"; esc="${esc//\?/\\?}"; esc="${esc//\[/\\[}"
        SCAN_PRUNE+=( -path "$esc" -prune -o )
        n=$((n + 1))
    done < <(_bfind "$DIR" -maxdepth 4 -type d \( -name Library -o -name Users \) -prune -print \
                | while IFS= read -r hit; do dirname "$hit"; done | sort -u)
    echo "$n" > "$_SCAN_STATE/skipped"
}
_scan_find_backups

# --- 0. LOOSE FILES: the ONE table both detectors read (#30, 2026-10-15) ------
#
# Usage: ostler-detect-exports.sh <dir> --loose
# Prints one  "LABEL<TAB>path<TAB>VERDICT<TAB>REASON"  line per loose data file
# under <dir>, where VERDICT is "import" (the importer behind ostler-import can
# read it) or "skip" (recognised, and REASON says in plain words why it will
# not be imported). Exit 0 if >=1 line, 1 if none.
#
# MEASURED on a synthetic walk box (studio29, v1.0.107 candidate): a loose
# calendar.ics, emails.mbox and contacts.vcf in ~/Downloads. The install-time
# scan listed two of them as "Found 2 GDPR export(s)" from its OWN find arms;
# the Downloads watcher matched none of them, exited 0 before it logged
# anything, and the customer was never told. Two detectors reading the same
# folder disagreed, and the one that runs for the life of the install was the
# blind one. This table is the fix for the SHAPE: both callers read it, so
# they cannot disagree again. Add a format HERE, never in a caller.
#
# Columns, <US>-separated: label, extended regex on the LOWERCASED basename,
# minimum bytes the importer reads, and the reason it is skipped when no
# importer exists for it (empty = importable). Each row is checked against
# the consumer that actually reads it:
#   Mailbox   ostler_fda.universal_import _detect_mbox (any non-empty .mbox)
#   Calendar  contact_syncer.import_all, which skips an .ics of 1000 bytes or
#             less, so 1001 is the floor here and a smaller file is reported
#             as skipped rather than as imported
#   Evernote  ostler_fda.universal_import _detect_evernote (.enex)
#   WhatsApp  NO importer reads a per-chat WhatsApp text file (universal_import
#             recognises the name and has no parser), and none is needed:
#             history comes from WhatsApp Desktop's own store. Recognised so a
#             file dropped in anyway is answered plainly, never "imported".
#   Contacts  NO importer reads a loose .vcf: import_all has no vCard arm, and
#             the only vCard reader (syncer.sync_from_vcf) takes the Contacts
#             app's own export. Recognised, so it is never silent, and skipped
#             with a reason the customer can act on.
LOOSE=(
  $'Mailbox\x1f\\.mbox$\x1f1\x1f'
  $'Calendar\x1f\\.ics$\x1f1001\x1f'
  $'Evernote\x1f\\.enex$\x1f1\x1f'
  $'WhatsApp chat\x1f^whatsapp chat.*\\.txt$\x1f1\x1fOstler does not need this file. It reads your WhatsApp history from WhatsApp Desktop on this Mac, so there is nothing to export'
  $'Contacts\x1f\\.vcf$\x1f1\x1fOstler cannot read a loose contact card yet. Open it to add it to Contacts, and Ostler reads it from there'
)

if [[ "$DO_LOOSE" == "1" ]]; then
    _lx_res=""
    for _lx in "${LOOSE[@]}"; do
        _lx_rest="${_lx#*$'\x1f'}"
        _lx_res="${_lx_res}${_lx_res:+$'\x1f'}${_lx_rest%%$'\x1f'*}"
    done
    _lx_any=1
    # Bounded the way the install-time calendar arm was (2026-09-12, Andy:
    # "change the installer, not the box"): depth 6 covers every export shape
    # measured so far (Takeout/Calendar is depth 4), -xdev keeps a mounted disk
    # image out of it, and package bundles are pruned so a file inside an .app
    # or a photo library is never reported as the customer's own. -maxdepth
    # goes first because GNU find warns when it follows a primary. No file
    # cap: a silent cap is how a fourth calendar went missing.
    #
    # The regexes reach awk through ENVIRON, NEVER `awk -v`: -v runs escape
    # processing, which turns `\.mbox$` into `.mbox$`, and measured on BSD awk
    # a file named "fooxmbox" was then reported as a mailbox.
    while IFS=$'\t' read -r _lx_idx _lx_path; do
        [[ -n "$_lx_path" && -f "$_lx_path" ]] || continue
        _lx_row="${LOOSE[$_lx_idx]}"
        _lx_label="${_lx_row%%$'\x1f'*}"
        _lx_t="${_lx_row#*$'\x1f'}"; _lx_t="${_lx_t#*$'\x1f'}"
        _lx_min="${_lx_t%%$'\x1f'*}"
        _lx_noimp="${_lx_t#*$'\x1f'}"
        _lx_size="$(wc -c < "$_lx_path" 2>/dev/null | tr -d ' ')"
        case "$_lx_size" in ''|*[!0-9]*) _lx_size="" ;; esac
        if [[ -z "$_lx_size" ]]; then
            printf '%s\t%s\tskip\t%s\n' "$_lx_label" "$_lx_path" "Ostler could not read the file"
        elif [[ -n "$_lx_noimp" ]]; then
            printf '%s\t%s\tskip\t%s\n' "$_lx_label" "$_lx_path" "$_lx_noimp"
        elif [[ "$_lx_size" -eq 0 ]]; then
            printf '%s\t%s\tskip\t%s\n' "$_lx_label" "$_lx_path" "the file is empty"
        elif [[ "$_lx_size" -lt "$_lx_min" ]]; then
            printf '%s\t%s\tskip\t%s\n' "$_lx_label" "$_lx_path" "the file is too small to hold anything Ostler can read"
        else
            printf '%s\t%s\timport\t\n' "$_lx_label" "$_lx_path"
        fi
        _lx_any=0
    done < <(_bfind "$DIR" -maxdepth "$SCAN_MAXDEPTH" -xdev \
                  ${SCAN_PRUNE[@]+"${SCAN_PRUNE[@]}"} \
                  \( -name 'node_modules' -o -name '.git' -o -name '.Trash' \
                     -o -name '*.app' -o -name '*.bundle' -o -name '*.framework' \
                     -o -name '*.photoslibrary' -o -name '*.aplibrary' \
                     -o -name '*.fcpbundle' -o -name '*.imovielibrary' \
                     -o -name '*.tvlibrary' -o -name '*.musiclibrary' \
                     -o -name '*.sparsebundle' \) -prune \
                  -o -type f -print \
             | OSTLER_LX_RES="$_lx_res" awk -F/ 'BEGIN { n = split(ENVIRON["OSTLER_LX_RES"], R, "\037") }
                   { b = tolower($NF); for (i = 1; i <= n; i++) if (b ~ R[i]) { print (i - 1) "\t" $0; next } }')
    exit "$_lx_any"
fi

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
        _uz_rc=0
        _uz_err="$(unzip -oq "$z" -d "$dest" 2>&1 1>/dev/null)" || _uz_rc=$?
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
    done < <(_bfind "$DIR" -maxdepth 2 ${SCAN_PRUNE[@]+"${SCAN_PRUNE[@]}"} -type f -iname '*.zip' -print)
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
    done < <(_bfind "$DIR" -maxdepth "$SCAN_MAXDEPTH" ${SCAN_PRUNE[@]+"${SCAN_PRUNE[@]}"} \( -type f -o -type d \) -print \
                | awk -F/ -v re="$re" 'tolower($NF) ~ tolower(re) || $NF ~ re {print}' \
                | head -5)
done

exit "$found_any"
