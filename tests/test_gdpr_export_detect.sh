#!/usr/bin/env bash
# Bulletproof GDPR-export detection (lib/ostler-detect-exports.sh).
#
# Proves the detector finds exports by CONTENT regardless of how they are
# named or packaged -- the customer-facing promise "drop whatever you've got":
#   1. a LinkedIn export in a RENAMED folder ("Complete_", not "Basic_")
#   2. a Facebook export left as a RENAMED .zip (never unzipped)
#   3. an Instagram export nested a few folders deep
#   4. a non-export folder must NOT false-positive
#   5. an empty dir exits non-zero
# Synthetic fixtures only (Rule 0) -- no real archive data.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DETECT="${HERE}/../lib/ostler-detect-exports.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

[[ -f "$DETECT" ]] || fail "detector script not found at $DETECT"

DL="$TMP/Downloads"
mkdir -p "$DL"

# 1. LinkedIn in a deliberately NON-"Basic" folder name + an extra wrapper dir.
mkdir -p "$DL/Complete_LinkedInDataExport_2026-01-02"
printf 'First Name,Last Name,URL\nJane,Smith,x\n' > "$DL/Complete_LinkedInDataExport_2026-01-02/Connections.csv"

# 2. Facebook export as a RENAMED zip that is never unzipped.
FBSRC="$TMP/_fbsrc/connections/friends"
mkdir -p "$FBSRC"
printf '{"friends_v2":[]}' > "$FBSRC/your_friends.json"
( cd "$TMP/_fbsrc" && zip -qr "$DL/my-facebook-backup-renamed.zip" . )

# 3. Instagram nested deep under a wrapper folder with an unrelated name.
mkdir -p "$DL/social stuff/ig_dump/connections/followers_and_following"
printf '[]' > "$DL/social stuff/ig_dump/connections/followers_and_following/followers_1.json"

# 4. A decoy that must NOT trip detection.
mkdir -p "$DL/holiday-photos"
printf 'not an export\n' > "$DL/holiday-photos/notes.txt"

echo "=== run detector with --unzip ==="
OUT="$(bash "$DETECT" "$DL" --unzip)"; RC=$?
echo "$OUT"
echo "exit=$RC"

[[ "$RC" -eq 0 ]] || fail "detector exited non-zero despite real exports present"

grep -q $'^LinkedIn\t' <<<"$OUT"  || fail "LinkedIn (renamed 'Complete_' folder) NOT detected"
grep -q $'^Facebook\t' <<<"$OUT"  || fail "Facebook (renamed, never-unzipped .zip) NOT detected"
grep -q $'^Instagram\t' <<<"$OUT" || fail "Instagram (deeply nested) NOT detected"
echo "PASS: LinkedIn(renamed folder) + Facebook(renamed zip) + Instagram(nested) all detected"

# The Facebook zip must have been auto-unzipped so the parsers can read it.
[[ -f "$DL/my-facebook-backup-renamed/connections/friends/your_friends.json" ]] \
    || fail "signature-bearing zip was not auto-unzipped"
echo "PASS: renamed Facebook zip auto-unzipped in place"

# No false positive on the decoy folder.
grep -q "holiday-photos" <<<"$OUT" && fail "decoy folder falsely detected as an export"
echo "PASS: non-export decoy not misdetected"

echo "=== empty dir exits non-zero ==="
EMPTY="$TMP/empty"; mkdir -p "$EMPTY"
if bash "$DETECT" "$EMPTY" >/dev/null; then fail "empty dir should exit non-zero"; fi
echo "PASS: empty dir exits non-zero"

echo ""
echo "ALL GDPR-EXPORT-DETECT TESTS PASSED"
