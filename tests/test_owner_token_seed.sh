#!/usr/bin/env bash
# CB137: the installer seeds ~/.ostler/secrets/owner_token ONLY if absent,
# 0600 in a 0700 directory, created under umask 077. Extracts the REAL block
# from install.sh and runs it against a temp directory. Never touches the real
# ~/.ostler.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$ROOT/install.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/owner-seed.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Extract the block: from its marker to the "Keeping existing" info line,
# plus the closing fi.
extract() {
  awk '
    /^# Owner token \(CB137/ { on=1 }
    on { print }
    on && /Keeping existing owner token/ { getline; print; exit }
  ' "$INSTALL"
}

run_block() {  # $1 = script file, $2 = secrets dir
  (
    set -euo pipefail
    ok()   { :; }
    info() { :; }
    fail() { echo "FAIL-CALLED: $*" >&2; exit 99; }
    SECRETS_DIR="$2"
    umask 022              # the installer's ambient umask; the block must still win
    # shellcheck disable=SC1090
    source "$1"
  )
}

mode_of() { python3 -c 'import os,stat,sys;print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$1"; }
fail_test() { echo "RED: $*"; exit 1; }

extract > "$TMP/real.sh"
[ -s "$TMP/real.sh" ] || fail_test "could not extract the owner-token block from install.sh"

# Control: the extraction is the real block, not an empty file.
grep -q 'OWNER_TOKEN_FILE="${SECRETS_DIR}/owner_token"' "$TMP/real.sh" \
  || fail_test "extracted block lacks the owner_token path (extraction is wrong)"

# 1. Fresh install: file created, 0600, dir 0700, 64 hex chars.
S1="$TMP/fresh/secrets"
run_block "$TMP/real.sh" "$S1"
[ -f "$S1/owner_token" ] || fail_test "owner_token not created on a fresh install"
[ "$(mode_of "$S1/owner_token")" = "0o600" ] || fail_test "owner_token mode is $(mode_of "$S1/owner_token"), want 0o600"
[ "$(mode_of "$S1")" = "0o700" ] || fail_test "secrets dir mode is $(mode_of "$S1"), want 0o700"
V1="$(cat "$S1/owner_token")"
echo "$V1" | grep -Eq '^[0-9a-f]{64}$' || fail_test "owner_token is not 64 hex chars"

# 2. Re-install / upgrade: the existing value is KEPT, not regenerated.
run_block "$TMP/real.sh" "$S1"
V2="$(cat "$S1/owner_token")"
[ "$V1" = "$V2" ] || fail_test "re-run regenerated the owner token (must be kept)"

# 3. Upgrade on an existing install that lacks the file: created.
S3="$TMP/upgrade/secrets"
mkdir -p "$S3"
run_block "$TMP/real.sh" "$S3"
[ -f "$S3/owner_token" ] || fail_test "upgrade did not create a missing owner_token"

# 4. Mutant: regenerate unconditionally. The idempotence check must catch it.
sed 's/if \[\[ ! -e "\$OWNER_TOKEN_FILE" \]\]; then/if true; then/' "$TMP/real.sh" > "$TMP/mutant.sh"
if cmp -s "$TMP/real.sh" "$TMP/mutant.sh"; then fail_test "mutant did not change the block (mutation is a no-op)"; fi
S4="$TMP/mutant/secrets"
run_block "$TMP/mutant.sh" "$S4"
M1="$(cat "$S4/owner_token")"
run_block "$TMP/mutant.sh" "$S4"
M2="$(cat "$S4/owner_token")"
if [ "$M1" = "$M2" ]; then fail_test "mutant survived: the idempotence check did not notice regeneration"; fi
echo "mutant: regenerated on re-run as expected (caught)"

echo "PASS: owner_token seeded 0600/0700, kept on re-run, created on upgrade, mutant caught"
