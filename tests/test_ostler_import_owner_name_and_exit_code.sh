#!/usr/bin/env bash
#
# tests/test_ostler_import_owner_name_and_exit_code.sh
#
# Two defects in the shipped ostler-import (the IMPORTEOF heredoc in
# install.sh), measured on Ostler cut #14's walks #11, #12 and #13, where a
# synthetic LinkedIn Positions.csv handed to ostler-import left 0 career facts.
#
# 1. NO OWNER NAME ON THE WATCHER PATH. contact_syncer.import_all refuses to
#    run without --user-name (vendor/cm041/contact_syncer/import_all.py, the
#    "--user-name is required" exit 2), falling back only to USER_DISPLAY_NAME
#    or PWG_USER_NAME (contact_syncer/config.py:110). install.sh writes the
#    owner's name to ~/.ostler/config/.env as USER_NAME, and only the
#    install-time hydrate passes --user-name. The Downloads watcher calls
#    `ostler-import "$DOWNLOADS"` with no flag, so every LinkedIn export a
#    customer drops after install exits 2 before linkedin_career runs, and
#    "Where have I worked?" has nothing to answer from. ostler-import must
#    hand the people graph the name from .env when no flag was given.
#
# 2. "UNKNOWN FORMAT" FROM THE LAST STEP DECIDED THE EXIT CODE. The universal
#    importer runs last and returns 3 for any dir it does not recognise
#    (vendor/ostler_fda/universal_import.py main(), status "unknown"), which
#    is every LinkedIn export. `|| rc=$?` made 3 the exit code of a run whose
#    real steps all succeeded, breaking the heredoc's own promise that "a
#    stray folder cannot fail the import". 3 from that step is now non-fatal;
#    any other non-zero from any step still fails the run.
#
# RUNTIME: the heredoc is carved out of install.sh and run against recording
# stubs for the three legs. Synthetic data only.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
PASS=0; FAIL=0
arm() { if [ "$2" -eq 0 ]; then printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); else printf '  [FAIL] %s\n         %s\n' "$1" "${3:-}"; FAIL=$((FAIL+1)); fi; }

[ -f "$INSTALL_SH" ] || { echo "CANNOT-RUN: no install.sh at $INSTALL_SH"; exit 2; }
START="$(grep -n "cat > \"\$IMPORT_SCRIPT\" <<'IMPORTEOF'" "$INSTALL_SH" | head -1 | cut -d: -f1)"
[ -n "$START" ] || { echo "CANNOT-RUN: the ostler-import heredoc opener is gone"; exit 2; }
END="$(awk -v s="$START" 'NR > s && /^IMPORTEOF$/ { print NR; exit }' "$INSTALL_SH")"
[ -n "$END" ] || { echo "CANNOT-RUN: the ostler-import heredoc terminator is gone"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
H="$WORK/home"; O="$H/.ostler"
mkdir -p "$O/bin" "$O/config" "$O/import-pipeline/contact_syncer" "$O/import-pipeline/.venv/bin" \
         "$O/services/cm019/.venv/bin" "$O/services/email-ingest/.venv/bin"
IMP="$O/bin/ostler-import"
sed -n "$((START + 1)),$((END - 1))p" "$INSTALL_SH" > "$IMP"
chmod +x "$IMP"
CALLS="$WORK/calls.log"

# Each leg's stub records its argv and exits with the code its env var names.
# P1 mimics import_all's real refusal: exit 2 when it is given no --user-name.
cat > "$O/import-pipeline/.venv/bin/python3" <<STUB
#!/usr/bin/env bash
echo "P1 \$*" >> "$CALLS"
case " \$* " in *" --user-name "*) : ;; *) echo "Error: --user-name is required" >&2; exit 2 ;; esac
exit "\${STUB_P1_RC:-0}"
STUB
cat > "$O/services/cm019/.venv/bin/python" <<STUB
#!/usr/bin/env bash
echo "P2 \$*" >> "$CALLS"
exit 0
STUB
cat > "$O/services/email-ingest/.venv/bin/python" <<STUB
#!/usr/bin/env bash
echo "P3 \$*" >> "$CALLS"
exit "\${STUB_P3_RC:-0}"
STUB
chmod +x "$O/import-pipeline/.venv/bin/python3" "$O/services/cm019/.venv/bin/python" "$O/services/email-ingest/.venv/bin/python"

# The .env exactly as install.sh writes the owner's name into it.
printf 'USER_ID="owner"\nUSER_NAME="Jane Doe"\n' > "$O/config/.env"
DROP="$WORK/drop/Basic_LinkedInDataExport"; mkdir -p "$DROP"
printf 'Company Name,Title,Description,Location,Started On,Finished On\nExampleCo,Staff engineer,,Riverside,Jan 2020,\n' > "$DROP/Positions.csv"

run() { : > "$CALLS"; ( env -u USER_NAME -u USER_DISPLAY_NAME -u PWG_USER_NAME HOME="$H" "$@" ) >"$WORK/out.log" 2>&1; echo $?; }

echo "1. the owner's name reaches the people graph on the watcher path"
rc=$(run "$IMP" "$WORK/drop")
grep -q '^P1 .*--user-name Jane Doe' "$CALLS"
arm "no --user-name flag: P1 is handed the USER_NAME from ~/.ostler/config/.env" $? "P1 argv: $(grep '^P1' "$CALLS")"
arm "and the run exits 0" "$([ "$rc" = 0 ] && echo 0 || echo 1)" "rc=$rc; $(tail -3 "$WORK/out.log")"
rc=$(run "$IMP" "$WORK/drop" --user-name "Sam Smith")
grep -q '^P1 .*--user-name Sam Smith' "$CALLS"
arm "an explicit --user-name still wins over .env" $? "P1 argv: $(grep '^P1' "$CALLS")"
mv "$O/config/.env" "$O/config/.env.off"
rc=$(run "$IMP" "$WORK/drop")
arm "CONTROL: with no name anywhere, P1 still refuses and the run fails" "$([ "$rc" != 0 ] && echo 0 || echo 1)" "rc=$rc"
mv "$O/config/.env.off" "$O/config/.env"

echo "2. unknown format from the universal step is non-fatal, a real failure is not"
rc=$(run env STUB_P3_RC=3 "$IMP" "$WORK/drop")
arm "P3 exits 3 (unknown format), P1 and P2 ok: the run exits 0" "$([ "$rc" = 0 ] && echo 0 || echo 1)" "rc=$rc"
rc=$(run env STUB_P3_RC=1 "$IMP" "$WORK/drop")
arm "MUST-FAIL: P3 exits 1 (a real failure): the run fails" "$([ "$rc" != 0 ] && echo 0 || echo 1)" "rc=$rc"
rc=$(run env STUB_P1_RC=1 STUB_P3_RC=3 "$IMP" "$WORK/drop")
arm "MUST-FAIL: P1 fails and P3 says unknown format: the run still fails" "$([ "$rc" != 0 ] && echo 0 || echo 1)" "rc=$rc"
rc=$(run env STUB_P1_RC=1 STUB_P3_RC=3 "$IMP" "$WORK/drop")
arm "and that failure is P1's code, not P3's 3" "$([ "$rc" = 1 ] && echo 0 || echo 1)" "rc=$rc"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
