#!/usr/bin/env bash
# EVERY ARCHIVE THE SCAN FINDS MUST BE OPENED, OR ITS SKIP MUST BE NAMED.
#
# Measured 2026-09-12 on a real install, Andy's explicit instruction, outside
# the launch freeze: a customer's Downloads folder held 46 zip archives from
# roughly fifteen platforms. Only 21 had their contents extracted; 25 had NO
# extracted directory at all, and the install log said nothing about any of
# them. The install reported DONE with zero errors.
#
# THE CAUSE: lib/ostler-detect-exports.sh gated extraction on whether a zip's
# member listing matched one of exactly 12 hardcoded per-platform SIGS
# filenames. A genuine export from a platform outside that list -- or a
# secondary volume of a split archive whose manifest file lives in a
# different part -- matched nothing and was silently dropped: no branch, no
# log line, no count. `unzip -oq ... || true` then also swallowed any
# extraction failure (password, corruption) for the ones that DID match.
#
# THIS TEST is the regression guard for that fix. It builds four synthetic
# zips (Rule 0: no real export data) covering the four outcomes a found
# archive can have, and asserts the detector's own UNZIP_SUMMARY line
# (stderr, counts only -- never a filename) accounts for every single one:
#
#   A. a SIGS-recognised export (Connections.csv)         -> opened
#   B. a genuine export from a platform NOT in SIGS        -> opened (the fix)
#      (a plausible JSON manifest with an unrecognised name -- exactly the
#      shape of a split archive volume, or a platform SIGS has never heard of)
#   C. a decoy with no export-shaped member at all          -> skipped, counted
#   D. a password-protected archive                         -> skipped, counted
#
# Run against the pre-fix detector: B is silently dropped, and no
# UNZIP_SUMMARY line is emitted at all (the pre-fix script never emitted
# one), so this test fails loudly. Run post-fix: all four are accounted for,
# and B lands next to A as opened.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DETECT="${HERE}/../lib/ostler-detect-exports.sh"

pass=0; fail_n=0
ok()  { printf '  ok    %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$*"; fail_n=$((fail_n+1)); }
finish() { printf '\n%d passed, %d failed\n' "$pass" "$fail_n"; [ "$fail_n" -eq 0 ] || exit 1; exit 0; }

[[ -f "$DETECT" ]] || { bad "detector not found at ${DETECT}"; finish; }
command -v zip   >/dev/null 2>&1 || { bad "no zip(1), cannot build fixtures"; finish; }
command -v unzip >/dev/null 2>&1 || { bad "no unzip(1), cannot build fixtures"; finish; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
DL="$TMP/Downloads"
mkdir -p "$DL"

printf '\n=== every archive the scan finds is opened, or its skip is counted ===\n\n'

# A. A SIGS-recognised export.
A_SRC="$TMP/_a"; mkdir -p "$A_SRC"
printf 'First Name,Last Name,URL\nJane,Smith,x\n' > "$A_SRC/Connections.csv"
( cd "$A_SRC" && zip -q "$DL/export-a-recognised.zip" Connections.csv )

# B. A genuine export from a platform SIGS has never heard of: a plausible
# manifest file (JSON -- the shape every export uses) whose name matches
# none of the 12 SIGS entries. This is the customer symptom reproduced: real
# data, unrecognised name, never opened by the pre-fix gate.
B_SRC="$TMP/_b"; mkdir -p "$B_SRC"
printf '{"purchases":[]}' > "$B_SRC/order_history_part_2.json"
( cd "$B_SRC" && zip -q "$DL/export-b-unrecognised-platform.zip" order_history_part_2.json )

# C. A decoy: nothing export-shaped at all.
C_SRC="$TMP/_c"; mkdir -p "$C_SRC"
printf 'not an export\n' > "$C_SRC/readme.txt"
( cd "$C_SRC" && zip -q "$DL/decoy-not-an-export.zip" readme.txt )

# D. Password-protected -- a real "good reason" skip that must still be
# named and counted, not passed over in silence.
D_SRC="$TMP/_d"; mkdir -p "$D_SRC"
printf 'Connections.csv content behind a password\n' > "$D_SRC/Connections.csv"
( cd "$D_SRC" && zip -q -P "synthetic-test-password" "$DL/export-d-password-protected.zip" Connections.csv )

echo "--- running detector with --unzip ---"
STDERR_OUT="$(bash "$DETECT" "$DL" --unzip 2>&1 >/dev/null)"
echo "$STDERR_OUT"

SUMMARY="$(printf '%s\n' "$STDERR_OUT" | grep '^UNZIP_SUMMARY ' || true)"
if [[ -z "$SUMMARY" ]]; then
    bad "no UNZIP_SUMMARY line was emitted at all -- this IS the pre-fix silence: 4 archives were found and the detector said nothing about any of them"
    finish
fi
ok "detector emitted a counts-only UNZIP_SUMMARY line"

get_field() { printf '%s\n' "$SUMMARY" | grep -o "$1=[0-9]*" | cut -d= -f2; }
FOUND="$(get_field found)"
OPENED="$(get_field opened)"
ALREADY="$(get_field already)"
SK_NOREC="$(get_field skipped_norecognised)"
SK_PW="$(get_field skipped_password)"
SK_OTHER="$(get_field skipped_other)"

[[ "${FOUND:-}" == "4" ]] && ok "found=4 (all four fixtures seen by the scan)" \
    || bad "found=${FOUND:-<missing>}, expected 4"

# THE INVARIANT. Nothing the scan finds may vanish: every archive found is
# accounted for in exactly one bucket (opened, already-extracted, or one of
# the named skip reasons). This is the assertion that fails on the pre-fix
# code, where a signature-mismatched real export contributed to neither side.
TOTAL_ACCOUNTED=$(( ${OPENED:-0} + ${ALREADY:-0} + ${SK_NOREC:-0} + ${SK_PW:-0} + ${SK_OTHER:-0} ))
if [[ -n "${FOUND:-}" && "$TOTAL_ACCOUNTED" == "$FOUND" ]]; then
    ok "opened + already + skipped(*) == found (${TOTAL_ACCOUNTED} == ${FOUND}) -- nothing vanished silently"
else
    bad "opened + already + skipped(*) == ${TOTAL_ACCOUNTED}, found == ${FOUND:-<missing>} -- an archive the scan found is neither opened nor reported"
fi

# A: recognised export, must be opened.
[[ -f "$DL/export-a-recognised/Connections.csv" ]] \
    && ok "A (SIGS-recognised) was opened" \
    || bad "A (SIGS-recognised) was NOT opened"

# B: THE FIX. A genuine export the 12-entry SIGS list has never heard of must
# now be opened too -- this is the exact customer symptom.
[[ -f "$DL/export-b-unrecognised-platform/order_history_part_2.json" ]] \
    && ok "B (real export, platform NOT in SIGS) was opened -- the customer symptom is closed" \
    || bad "B (real export, platform NOT in SIGS) was NOT opened -- this is the customer symptom: real archives silently never extracted"

# C: a decoy with nothing export-shaped must stay closed, and its skip must
# still be counted.
[[ -d "$DL/decoy-not-an-export" ]] \
    && bad "C (decoy, no export-shaped member) was opened -- that is 'unzip everything', not detection" \
    || ok "C (decoy, no export-shaped member) was correctly left unopened"
[[ "${SK_NOREC:-0}" -ge 1 ]] \
    && ok "the decoy's skip was counted (skipped_norecognised=${SK_NOREC})" \
    || bad "the decoy's skip was NOT counted (skipped_norecognised=${SK_NOREC:-0})"

# D: password-protected must stay closed (no dest left behind: a failed
# extraction is cleaned up so a later run retries rather than reading an
# empty folder as "already done"), and be counted under its OWN reason, not
# folded into "not recognised".
[[ -e "$DL/export-d-password-protected" ]] \
    && bad "D (password-protected) left extracted content behind, which should be impossible without the password" \
    || ok "D (password-protected) produced no extracted content"
[[ "${SK_PW:-0}" -ge 1 ]] \
    && ok "the password-protected skip was counted under its own reason (skipped_password=${SK_PW})" \
    || bad "the password-protected skip was NOT counted as password-protected (skipped_password=${SK_PW:-0})"

finish
