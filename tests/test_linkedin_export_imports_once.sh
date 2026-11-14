#!/usr/bin/env bash
# A LINKEDIN EXPORT IS IMPORTED ONCE AND ANNOUNCED ONCE (F&F tester, 2026-11-12).
#
# The Downloads watcher (ostler-scan-exports) said "Ostler found your LinkedIn
# export and is adding it" most days. Its dedupe key was ONE hash over the whole
# set of export paths, so:
#   (a) any unrelated new export in Downloads changed the set, re-ran the
#       importer over the folder and announced LinkedIn again ("... and 1 more");
#   (b) an export changed at the same path matched the old key and was never
#       imported again.
# The key is now per item: path plus a fingerprint of its files (names, sizes,
# mtimes), recorded in state/export-scan/imported_platform.tsv.
#
# This runs the SHIPPED scanner (extracted from install.sh) as a fresh process
# per firing, 4 h apart, so the ledger has to survive on disk. The importer and
# osascript are stubs that log what a customer would see. Set INSTALL_SH to run
# the same arms against another install.sh (the old one, to show the red).
set -uo pipefail
cd "$(dirname "$0")/.."
INSTALL_SH="${INSTALL_SH:-install.sh}"

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; [ $# -gt 1 ] && printf '         %s\n' "$2"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
printf '\n=== A LINKEDIN EXPORT IS IMPORTED ONCE AND ANNOUNCED ONCE ===\n\n'

SCAN="$WORK/ostler-scan-exports"
awk "/^cat > \"\\\${OSTLER_DIR}\/bin\/ostler-scan-exports\" <<'SCANEOF'\$/{f=1;next} f&&/^SCANEOF\$/{exit} f{print}" \
    "$INSTALL_SH" > "$SCAN"
if [ "$(wc -l < "$SCAN" | tr -d ' ')" -gt 100 ] && bash -n "$SCAN"; then
    ok "extracted the shipped scanner from ${INSTALL_SH}"
else
    bad "could not extract a parseable scanner from ${INSTALL_SH}; every arm below would be vacuous"
    printf '\n== %d pass / %d fail ==\n' "$PASS" "$FAIL"; exit 1
fi

DETECT="$WORK/ostler-detect-exports.sh"
git show "HEAD:lib/ostler-detect-exports.sh" > "$DETECT" 2>/dev/null || cp lib/ostler-detect-exports.sh "$DETECT"

CSV_V1='First Name,Last Name,URL,Email Address,Company,Position,Connected On
Alex,Example,https://example.invalid/a,,Acme,Engineer,01 Jan 2024'
CSV_V2="${CSV_V1}
Bo,Sample,https://example.invalid/b,,Beta,Analyst,02 Feb 2025"

# Fresh hermetic HOME. $1 = exit code the stub importer returns.
setup_box() {
    local rc="$1" box="$WORK/box_$1_$RANDOM"
    mkdir -p "$box/Downloads/Basic_LinkedInDataExport_01-01-2026" "$box/.ostler/bin" \
             "$box/.ostler/state" "$box/.ostler/lib" "$box/shim"
    cp "$DETECT" "$box/.ostler/lib/ostler-detect-exports.sh"
    printf '%s\n' "$CSV_V1" > "$box/Downloads/Basic_LinkedInDataExport_01-01-2026/Connections.csv"
    printf '%s\n' '#!/usr/bin/env bash' 'echo IMPORT >> "${NOTIFY_LOG}.imports"' "exit ${rc}" \
        > "$box/.ostler/bin/ostler-import"
    chmod +x "$box/.ostler/bin/ostler-import"
    # osascript shim: the text a customer is shown, one line per notification.
    printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$2" >> "${NOTIFY_LOG}"' > "$box/shim/osascript"
    chmod +x "$box/shim/osascript"
    printf '%s' "$box"
}
# One launchd firing. $1 box, $2 firing number (clock moves 4 h per firing).
fire() {
    local box="$1" n="$2"
    OSTLER_CADENCE_NOW=$(( 2000000000 + n * 14400 )) \
    NOTIFY_LOG="$box/notifications.txt" HOME="$box" PATH="$box/shim:$PATH" \
        bash "$SCAN" >/dev/null 2>&1
}
imports()  { grep -c IMPORT "$1/notifications.txt.imports" 2>/dev/null || echo 0; }
linkedin_says() { grep -c 'LinkedIn' "$1/notifications.txt" 2>/dev/null || echo 0; }

# ---------------------------------------------------------------------------
# CONTROL: the first sighting imports and announces once. Without this the
# rest of the file would pass on a scanner that never reaches the importer.
# ---------------------------------------------------------------------------
B1="$(setup_box 0)"
fire "$B1" 1
if [ "$(imports "$B1")" -eq 1 ] && [ "$(linkedin_says "$B1")" -eq 1 ]; then
    ok "CONTROL: first sighting imports the LinkedIn export once and says so once"
else
    bad "CONTROL failed: imports=$(imports "$B1") linkedin_notices=$(linkedin_says "$B1")" \
        "$(cat "$B1/notifications.txt" 2>/dev/null)"
fi

# RESTART: a new process four hours later, same export, nothing else changed.
fire "$B1" 2
if [ "$(imports "$B1")" -eq 1 ] && [ "$(linkedin_says "$B1")" -eq 1 ]; then
    ok "RESTART: the next firing (fresh process, ledger read from disk) does not import or announce it again"
else
    bad "same export re-imported on the next firing: imports=$(imports "$B1")" \
        "$(cat "$B1/notifications.txt" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# SUBJECT (fails on the old code): an UNRELATED export arrives. The LinkedIn
# export was already imported and must not be announced again.
# ---------------------------------------------------------------------------
B2="$(setup_box 0)"
fire "$B2" 1
mkdir -p "$B2/Downloads/facebook-example"
printf '[]\n' > "$B2/Downloads/facebook-example/friends.json"
fire "$B2" 2
if [ "$(linkedin_says "$B2")" -eq 1 ]; then
    ok "SAME EXPORT SEEN TWICE: an unrelated new export does not re-announce LinkedIn (announced once)"
else
    bad "LinkedIn announced $(linkedin_says "$B2") times; the same export was seen twice" \
        "$(cat "$B2/notifications.txt" 2>/dev/null)"
fi
if grep -qi 'facebook' "$B2/notifications.txt" 2>/dev/null; then
    ok "and the new Facebook export is the one announced on the second firing"
else
    bad "the new export was not announced on its own" "$(cat "$B2/notifications.txt" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# A CHANGED EXPORT STILL IMPORTS: same path, new content, a new announcement.
# ---------------------------------------------------------------------------
B3="$(setup_box 0)"
fire "$B3" 1
printf '%s\n' "$CSV_V2" > "$B3/Downloads/Basic_LinkedInDataExport_01-01-2026/Connections.csv"
fire "$B3" 2
if [ "$(imports "$B3")" -eq 2 ] && [ "$(linkedin_says "$B3")" -eq 2 ]; then
    ok "CHANGED EXPORT: a re-saved export at the same path is imported again and announced again"
else
    bad "a changed export was not imported again: imports=$(imports "$B3") linkedin_notices=$(linkedin_says "$B3")" \
        "$(cat "$B3/notifications.txt" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# ONE EXPORT, NOT TWO: the name glob ends in "/" and the detector does not.
# The same folder must count once, not "... and 1 more".
# ---------------------------------------------------------------------------
B4="$(setup_box 0)"
fire "$B4" 1
if grep -q 'and 1 more' "$B4/notifications.txt" 2>/dev/null; then
    bad "one LinkedIn folder was counted as two exports" "$(cat "$B4/notifications.txt")"
elif [ "$(linkedin_says "$B4")" -eq 1 ]; then
    ok "one LinkedIn folder is counted as one export, not two"
else
    bad "unexpected first-firing notices" "$(cat "$B4/notifications.txt" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# A ZIPPED EXPORT IS ONE EXPORT: the name glob matches the .zip, and the
# detector then extracts it to a sibling folder in the same tick. The zip and
# its folder must count once, and the first announcement must not say "1 more".
# ---------------------------------------------------------------------------
B7="$(setup_box 0)"
rm -rf "$B7/Downloads/Basic_LinkedInDataExport_01-01-2026"
ZW="$(mktemp -d)"; mkdir -p "$ZW/Basic_LinkedInDataExport_01-01-2026"
printf '%s\n' "$CSV_V1" > "$ZW/Basic_LinkedInDataExport_01-01-2026/Connections.csv"
( cd "$ZW" && zip -qr "$B7/Downloads/linkedin_export.zip" Basic_LinkedInDataExport_01-01-2026 )
rm -rf "$ZW"
fire "$B7" 1
if grep -q 'and 1 more' "$B7/notifications.txt" 2>/dev/null; then
    bad "a zipped LinkedIn export was counted as two exports (the zip and its extracted folder)" "$(cat "$B7/notifications.txt")"
elif [ "$(imports "$B7")" -eq 1 ] && [ "$(linkedin_says "$B7")" -eq 1 ]; then
    ok "a zipped LinkedIn export is one export: imported once, announced once, not 'and 1 more'"
else
    bad "unexpected result for a zipped export: imports=$(imports "$B7")" "$(cat "$B7/notifications.txt" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# A FAILED IMPORT IS STILL RETRIED (#1571 must not regress): no key written.
# ---------------------------------------------------------------------------
B5="$(setup_box 1)"
fire "$B5" 1
printf '%s\n' '#!/usr/bin/env bash' 'echo IMPORT >> "${NOTIFY_LOG}.imports"' 'exit 0' > "$B5/.ostler/bin/ostler-import"
fire "$B5" 2
if [ "$(imports "$B5")" -eq 2 ] && [ "$(grep -c 'now part of your world' "$B5/notifications.txt")" -eq 1 ]; then
    ok "FAILED IMPORT RETRIED: a failed import writes no key, so the next firing imports it"
else
    bad "a failed import was not retried: imports=$(imports "$B5")" "$(cat "$B5/notifications.txt" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# DATE HIGH-WATER MARK. Epochs are computed the way the scanner computes them.
# ---------------------------------------------------------------------------
epoch_of() { date -j -u -f '%m-%d-%Y %H:%M:%S' "$1 00:00:00" +%s; }
mk_export() {  # $1 box, $2 date MM-DD-YYYY (folder name carries the export date)
    mkdir -p "$1/Downloads/Basic_LinkedInDataExport_$2"
    printf '%s\n' "$CSV_V1" > "$1/Downloads/Basic_LinkedInDataExport_$2/Connections.csv"
}

# OLDER IS SKIPPED, SILENTLY: the mark is Feb 2026; a Jan 2026 export arrives.
B8="$(setup_box 0)"; rm -rf "$B8/Downloads/Basic_LinkedInDataExport_01-01-2026"
mk_export "$B8" 02-01-2026
fire "$B8" 1
mk_export "$B8" 01-01-2026
fire "$B8" 2
if [ "$(imports "$B8")" -eq 1 ] && [ "$(linkedin_says "$B8")" -eq 1 ]; then
    ok "OLDER SKIPPED: a Jan 2026 export after a Feb 2026 import is not imported and not announced"
else
    bad "an older export was imported or announced: imports=$(imports "$B8")" "$(cat "$B8/notifications.txt" 2>/dev/null)"
fi

# NEWER IMPORTS ONCE: a Feb 2026 export after a Jan 2026 import imports once, then is quiet.
B9="$(setup_box 0)"
fire "$B9" 1
mk_export "$B9" 02-01-2026
fire "$B9" 2
fire "$B9" 3
if [ "$(imports "$B9")" -eq 2 ] && [ "$(linkedin_says "$B9")" -eq 2 ]; then
    ok "NEWER IMPORTS ONCE: a newer export is imported and announced once, and not again on the next firing"
else
    bad "a newer export was not imported once: imports=$(imports "$B9") linkedin_notices=$(linkedin_says "$B9")" \
        "$(cat "$B9/notifications.txt" 2>/dev/null)"
fi

# FAILED IMPORT LEAVES THE MARK UNCHANGED: mark is Jan 2026; Feb 2026 import fails.
B10="$(setup_box 0)"
fire "$B10" 1
MARK_JAN="$(awk -F'\t' '{print $2}' "$B10/.ostler/state/export-scan/high_water.tsv" 2>/dev/null)"
printf '%s\n' '#!/usr/bin/env bash' 'echo IMPORT >> "${NOTIFY_LOG}.imports"' 'exit 1' > "$B10/.ostler/bin/ostler-import"
mk_export "$B10" 02-01-2026
fire "$B10" 2
MARK_AFTER_FAIL="$(awk -F'\t' '{print $2}' "$B10/.ostler/state/export-scan/high_water.tsv" 2>/dev/null)"
if [ -n "$MARK_JAN" ] && [ "$MARK_JAN" = "$MARK_AFTER_FAIL" ] && [ "$MARK_AFTER_FAIL" = "$(epoch_of 01-01-2026)" ]; then
    ok "FAILED IMPORT: a failed newer import leaves the mark at Jan 2026"
else
    bad "a failed import moved the mark: before=${MARK_JAN:-<none>} after=${MARK_AFTER_FAIL:-<none>}"
fi

# RESTART PERSISTS THE MARK: the mark is on disk, and a fresh process reads it.
B11="$(setup_box 0)"
fire "$B11" 1
MARKF="$B11/.ostler/state/export-scan/high_water.tsv"
if [ "$(awk -F'\t' -v l=LinkedIn '$1 == l {print $2}' "$MARKF" 2>/dev/null)" = "$(epoch_of 01-01-2026)" ]; then
    ok "RESTART: the LinkedIn high-water mark is persisted on disk at the export date (2026-01-01)"
else
    bad "no persisted LinkedIn mark at the export date" "$(cat "$MARKF" 2>/dev/null)"
fi

# ZIP AND FOLDER ARE ONE EXPORT, ACROSS TICKS: zip first, then the detector extracts it.
B12="$(setup_box 0)"; rm -rf "$B12/Downloads/Basic_LinkedInDataExport_01-01-2026"
ZW2="$(mktemp -d)"; mkdir -p "$ZW2/Basic_LinkedInDataExport_03-01-2026"
printf '%s\n' "$CSV_V1" > "$ZW2/Basic_LinkedInDataExport_03-01-2026/Connections.csv"
( cd "$ZW2" && zip -qr "$B12/Downloads/Basic_LinkedInDataExport_03-01-2026.zip" Basic_LinkedInDataExport_03-01-2026 )
rm -rf "$ZW2"
fire "$B12" 1; fire "$B12" 2
if [ "$(imports "$B12")" -eq 1 ] && [ "$(linkedin_says "$B12")" -eq 1 ]; then
    ok "ZIP + EXTRACTED FOLDER across two ticks: 1 import, 1 announce (extraction adds nothing)"
else
    bad "zip plus extracted folder across ticks: imports=$(imports "$B12") notices=$(linkedin_says "$B12")" "$(cat "$B12/notifications.txt" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# MUTANTS: each disables one decision line of the SHIPPED scanner. Its arm
# must show the defect returning, or the arm above proves nothing.
# ---------------------------------------------------------------------------
mutant_box() {  # $1 = sed program, $2 = label
    local prog="$1" label="$2" mut="$WORK/mut_$RANDOM.sh" B
    sed "$prog" "$SCAN" > "$mut"
    if cmp -s "$SCAN" "$mut"; then bad "MUTATION ($label) did not apply, so its result would prove nothing"; return; fi
    chmod +x "$mut"; B="$(setup_box 0)"; rm -rf "$B/Downloads/Basic_LinkedInDataExport_01-01-2026"
    mk_export "$B" 02-01-2026
    OSTLER_CADENCE_NOW=$(( 2000000000 + 14400 )) NOTIFY_LOG="$B/notifications.txt" HOME="$B" PATH="$B/shim:$PATH" bash "$mut" >/dev/null 2>&1
    mk_export "$B" 01-01-2026
    OSTLER_CADENCE_NOW=$(( 2000000000 + 2 * 14400 )) NOTIFY_LOG="$B/notifications.txt" HOME="$B" PATH="$B/shim:$PATH" bash "$mut" >/dev/null 2>&1
    echo "$B"
}
MB="$(mutant_box 's/elif \[\[ -n "\$_m" \&\& "\$_d" -lt "\$_m" \]\]; then/elif false; then/' "skip older")"
if [ -n "$MB" ] && [ "$(imports "$MB")" -eq 2 ]; then
    ok "MUTANT (no older-skip) imports the older export, so the OLDER arm is not vacuous"
else
    bad "MUTANT (no older-skip) did not re-import the older export" "imports=$(imports "${MB:-/nonexistent}")"
fi
MB2="$(mutant_box 's/ \&\& _es_ledger_has "\$_d" "\${P_FP\[\$_i\]}"; then/ \&\& false; then/' "no tiebreak")"
if [ -n "$MB2" ] && [ "$(imports "$MB2")" -eq 2 ]; then
    ok "MUTANT (no same-date tiebreak) re-imports at the mark, so the fingerprint tiebreak is not vacuous"
else
    bad "MUTANT (no tiebreak) did not show a re-import at the mark" "imports=$(imports "${MB2:-/nonexistent}")"
fi

printf '\n== %d pass / %d fail / %d total ==\n' "$PASS" "$FAIL" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ]
