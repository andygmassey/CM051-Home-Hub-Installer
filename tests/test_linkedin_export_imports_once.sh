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
# MUTATION: remove the per-item ledger check. The RESTART arm must go red.
# ---------------------------------------------------------------------------
MUT="$WORK/ostler-scan-exports.mutant"
sed 's/if \[\[ -f "\$_ES_PLAT" \]\] \&\& grep -Fxq -- "\${P_KEY\[\$_i\]}" "\$_ES_PLAT"; then/if false; then/' "$SCAN" > "$MUT"
if cmp -s "$SCAN" "$MUT"; then
    bad "MUTATION did not apply, so its result below would prove nothing"
else
    chmod +x "$MUT"
    B6="$(setup_box 0)"
    OSTLER_CADENCE_NOW=$(( 2000000000 + 14400 )) NOTIFY_LOG="$B6/notifications.txt" HOME="$B6" PATH="$B6/shim:$PATH" bash "$MUT" >/dev/null 2>&1
    OSTLER_CADENCE_NOW=$(( 2000000000 + 2 * 14400 )) NOTIFY_LOG="$B6/notifications.txt" HOME="$B6" PATH="$B6/shim:$PATH" bash "$MUT" >/dev/null 2>&1
    if [ "$(imports "$B6")" -eq 2 ]; then
        ok "MUTANT (no per-item check) imports the same export twice, so the RESTART arm is not vacuous"
    else
        bad "MUTANT did not re-import; the RESTART arm could pass with the dedupe removed" "imports=$(imports "$B6")"
    fi
fi

printf '\n== %d pass / %d fail / %d total ==\n' "$PASS" "$FAIL" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ]
