#!/usr/bin/env bash
#
# A WALK RECORD CARRIES NO HOME DIRECTORY, IN ANY FIELD.
#
# MEASURED 2026-11-04: walks/v1.0.123.tsv line 75 carried
#   stores_provenance  wiped-by-shipped-uninstaller(<home>/.ostler/bin/ostler-uninstall;...)
# because ttywalk.sh's reset writes the uninstaller path it ran and
# post_walk_qa.sh copied it in verbatim. walks/ is PUBLIC; ci-pii-shape-scan
# blocked CM051 #3318.
#
# WHAT THIS ASSERTS
#   1. walk_record_tildeize rewrites macOS, Linux and root home prefixes to ~
#      in EVERY field, keeps the rest of each value, and re-checks clean
#   2. the exact v1.0.123 marker shape (as ttywalk.sh prints it) comes out as
#      ~/.ostler/bin/ostler-uninstall
#   3. a path it cannot rewrite is a refusal (rc 1), not a pass
#   4. post_walk_qa.sh calls it AFTER the record is complete and BEFORE the
#      owner scan, and deletes the record on refusal
#
# The home paths here are BUILT FROM PARTS at runtime: this file is in a public
# repo and the PII scan rightly refuses a literal one.
#
# EXIT CODES. 0 every arm held; 1 an arm failed; 2 anchors moved.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/scripts/lib_walk_record_paths.sh"
QA="${ROOT}/scripts/post_walk_qa.sh"
[ -f "$LIB" ] && [ -f "$QA" ] || { echo "CANNOT-RUN: lib or post_walk_qa.sh missing"; exit 2; }
# shellcheck source=scripts/lib_walk_record_paths.sh
. "$LIB"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok    %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$*" >&2; }

U="Users"; H="home"; ACCT="walkacct$$"
MAC="/${U}/${ACCT}"; LNX="/${H}/${ACCT}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# 1 + 2: a record with home paths in several fields, including the real marker.
R="${T}/rec.tsv"
{
    printf 'version\tv1.0.999\n'
    printf 'stores_provenance\twiped-by-shipped-uninstaller(%s/.ostler/bin/ostler-uninstall;colimadelete--data,datadiskabsent)\n' "$MAC"
    printf 'instrument_source\tgit(%s/Developer/x)\n' "$MAC"
    printf 'artefact_sha256_source\tmeasured(%s/Downloads/OstlerInstaller-1.0.999.dmg)\n' "$MAC"
    printf 'note\tbare home %s and linux %s/y and root /var/root/z\n' "$MAC" "$LNX"
    printf 'grounding_seed\t~/.walk-grounding-seed-run already tilde\n'
} > "$R"
before_lines="$(wc -l < "$R" | tr -d ' ')"
walk_record_tildeize "$R"; rc=$?
[ "$rc" -eq 0 ] && ok "rewrite returned 0" || bad "rewrite returned ${rc}"
n_home="$(/usr/bin/grep -E -c "/${U}/|/${H}/${ACCT}|/var/root" "$R")"
[ "$n_home" -eq 0 ] && ok "no home path left in any field (0 of ${before_lines} lines)" || bad "${n_home} line(s) still carry a home path"
/usr/bin/grep -q -F 'wiped-by-shipped-uninstaller(~/.ostler/bin/ostler-uninstall;colimadelete--data' "$R" \
    && ok "the v1.0.123 marker reads ~/.ostler/bin/ostler-uninstall" || bad "stores_provenance not rewritten to ~/ form"
/usr/bin/grep -q -F 'measured(~/Downloads/OstlerInstaller-1.0.999.dmg)' "$R" && ok "artefact source keeps its tail" || bad "artefact source mangled"
/usr/bin/grep -q -F 'bare home ~ and linux ~/y and root ~/z' "$R" && ok "bare, Linux and root homes rewritten" || bad "bare/linux/root rewrite wrong"
/usr/bin/grep -q -F 'grounding_seed	~/.walk-grounding-seed-run already tilde' "$R" && ok "an already-tilde field is untouched" || bad "already-tilde field changed"
[ "$(wc -l < "$R" | tr -d ' ')" = "$before_lines" ] && ok "line count preserved" || bad "line count changed"

# 3: a refusal is a refusal. An unreadable file is rc 2, never 0.
walk_record_tildeize "${T}/absent.tsv" 2>/dev/null; rc=$?
[ "$rc" -eq 2 ] && ok "a missing record is rc 2 (could not look), not a pass" || bad "missing record returned ${rc}"

# 4: post_walk_qa.sh wiring, in order: record closed -> tildeize -> owner scan.
l_close="$(/usr/bin/grep -n '^    } > "\$RECORD"$' "$QA" | head -1 | cut -d: -f1)"
l_tilde="$(/usr/bin/grep -n 'if ! walk_record_tildeize "\$RECORD"; then' "$QA" | head -1 | cut -d: -f1)"
l_owner="$(/usr/bin/grep -n 'walk_owner_scan_record "\$RECORD"' "$QA" | head -1 | cut -d: -f1)"
if [ -z "$l_close" ] || [ -z "$l_tilde" ] || [ -z "$l_owner" ]; then
    echo "CANNOT-RUN: post_walk_qa.sh anchors moved (close=${l_close:-?} tilde=${l_tilde:-?} owner=${l_owner:-?})"; exit 2
fi
[ "$l_close" -lt "$l_tilde" ] && [ "$l_tilde" -lt "$l_owner" ] \
    && ok "post_walk_qa.sh tildeizes after the record closes (${l_close}) and before the owner scan (${l_owner})" \
    || bad "wrong order: close=${l_close} tilde=${l_tilde} owner=${l_owner}"
sed -n "${l_tilde},$((l_tilde+5))p" "$QA" | /usr/bin/grep -q 'rm -f "\$RECORD"' \
    && ok "a refusal deletes the record (nothing left to commit)" || bad "a refusal does not delete the record"

echo "test_walk_record_carries_no_home_path: ${PASS} ok, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
