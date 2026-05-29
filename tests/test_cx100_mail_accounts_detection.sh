#!/usr/bin/env bash
#
# tests/test_cx100_mail_accounts_detection.sh
#
# Byte-walking regression test for CX-100: Apple Mail account
# detection now reads ~/Library/Accounts/Accounts4.sqlite (source
# of truth) instead of ~/Library/Mail/V<N>/MailData/Accounts.plist
# (derived store).
#
# What the failure looked like (PRE-CX-100, must never recur):
#
#   1. Customer configures iCloud (or Gmail) account in System
#      Settings -> Internet Accounts. accountsd writes the
#      configuration to ~/Library/Accounts/Accounts4.sqlite.
#   2. Customer has NOT opened Mail.app yet (or opened it briefly
#      and quit without it syncing). ~/Library/Mail/V*/MailData/
#      Accounts.plist therefore does NOT exist.
#   3. install.sh probes Accounts.plist with grep -c. File missing
#      -> count is 0. Banner says "Apple Mail accounts visible: 0"
#      and the email-ingest path proceeds against an empty store.
#   4. The downstream "Apple Mail does not appear to hold any
#      local messages" copy fires even though TWO accounts are
#      configured. State 2 (configured but not synced) gets
#      collapsed into state 1 (not configured).
#
# Post-CX-100 the probe is a SQL count against ZACCOUNT joined to
# ZACCOUNTTYPE, filtered for mail-capable account types and active
# top-level rows (ZAUTHENTICATIONTYPE != 'parent'). The Accounts.plist
# read is removed entirely from install.sh.
#
# Axes covered:
#   1. install.sh defines _accountsdb_count_mail helper function
#      and uses it at BOTH probe sites (early Phase 2 + Phase 4).
#   2. install.sh does NOT contain any '<key>AccountName</key>'
#      grep -- the Accounts.plist legacy probe is gone.
#   3. The SQL query enumerates the canonical mail-capable
#      ZIDENTIFIER values: at minimum IMAP, Google, AppleAccount.
#   4. The SQL filters out parent auth-type rows so child IMAP
#      rows under an iCloud / Gmail parent do not double-count.
#   5. Integration: mocked Accounts4.sqlite with 2 mail-capable
#      accounts + 1 child parent row -> helper returns "2", not "3".

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
FAILED=0

failure() {
    echo "FAIL: $*" >&2
    FAILED=1
}

if [[ ! -f "$INSTALL_SH" ]]; then
    echo "FATAL: install.sh not found at $INSTALL_SH" >&2
    exit 2
fi

# Axis 1: helper exists + named correctly.
if ! grep -qE '^_accountsdb_count_mail\(\)' "$INSTALL_SH"; then
    failure "_accountsdb_count_mail helper not defined"
fi

# Axis 2: legacy Accounts.plist grep is fully removed.
if grep -q '<key>AccountName</key>' "$INSTALL_SH"; then
    failure "install.sh still contains <key>AccountName</key> grep -- CX-100 contract broken"
fi
# Old probe also used a 'V[0-9]*' find chain for the early Phase 2 probe
# AT the MailData/Accounts.plist path. The Phase 4 probe still uses
# the V<N> find for the .emlx walk (different axis -- population), but
# it must no longer feed Accounts.plist. Catch the specific shape.
if grep -q 'MailData/Accounts.plist' "$INSTALL_SH"; then
    failure "install.sh still references MailData/Accounts.plist -- CX-100 contract broken"
fi

# Axis 3: SQL enumerates canonical mail-capable account types.
for atype in IMAP Google AppleAccount Hotmail Yahoo Exchange; do
    if ! grep -q "com.apple.account.${atype}" "$INSTALL_SH"; then
        failure "_accountsdb_count_mail SQL is missing 'com.apple.account.${atype}'"
    fi
done

# Axis 4: parent-row filter present.
if ! grep -qE "ZAUTHENTICATIONTYPE.*!=.*'parent'" "$INSTALL_SH"; then
    failure "_accountsdb_count_mail SQL does not filter parent auth-type rows"
fi

# Axis 5: both probe sites call _accountsdb_count_mail. The Phase 4
# (Mail probe) call site uses MAIL_ACCOUNTS_FOUND, and the early
# Phase 2 call site uses _early_mail_accounts.
PHASE2_CALLS=$(grep -c '_early_mail_accounts="\$(_accountsdb_count_mail)"' "$INSTALL_SH" || true)
PHASE4_CALLS=$(grep -c 'MAIL_ACCOUNTS_FOUND="\$(_accountsdb_count_mail)"' "$INSTALL_SH" || true)
if (( PHASE2_CALLS < 1 )); then
    failure "Phase 2 early Mail probe does not call _accountsdb_count_mail"
fi
if (( PHASE4_CALLS < 1 )); then
    failure "Phase 4 Mail content probe does not call _accountsdb_count_mail"
fi

# Axis 6: integration check using a mocked Accounts4.sqlite.
# Build a fake DB that matches the macOS Sequoia schema shape with
# 2 mail-capable top-level rows + 1 child IMAP parent row.
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

MOCK_DB="$TMPDIR/Accounts4.sqlite"
sqlite3 "$MOCK_DB" <<'SQL'
CREATE TABLE ZACCOUNTTYPE (
    Z_PK INTEGER PRIMARY KEY,
    ZIDENTIFIER VARCHAR
);
CREATE TABLE ZACCOUNT (
    Z_PK INTEGER PRIMARY KEY,
    ZACTIVE INTEGER,
    ZACCOUNTTYPE INTEGER,
    ZAUTHENTICATIONTYPE VARCHAR,
    ZUSERNAME VARCHAR
);
INSERT INTO ZACCOUNTTYPE VALUES (7, 'com.apple.account.AppleAccount');
INSERT INTO ZACCOUNTTYPE VALUES (39, 'com.apple.account.IMAP');
INSERT INTO ZACCOUNTTYPE VALUES (54, 'com.apple.account.Google');
INSERT INTO ZACCOUNTTYPE VALUES (47, 'com.apple.account.CardDAV');
INSERT INTO ZACCOUNT VALUES (1, 1, 7,  NULL,     'andy@example.com');
INSERT INTO ZACCOUNT VALUES (2, 1, 54, NULL,     'andy@gmail.com');
INSERT INTO ZACCOUNT VALUES (3, 1, 39, 'parent', '');
INSERT INTO ZACCOUNT VALUES (4, 1, 47, NULL,     'andy@example.com');
INSERT INTO ZACCOUNT VALUES (5, 0, 54, NULL,     'inactive@gmail.com');
SQL

# Source the helper (with HOME overridden so the probe reads our mock).
export HOME="$TMPDIR"
mkdir -p "$TMPDIR/Library/Accounts"
mv "$MOCK_DB" "$TMPDIR/Library/Accounts/Accounts4.sqlite"

# Extract the helper definitions out of install.sh by sourcing in
# a way that doesn't trigger the bootstrap. We use a small extractor
# pattern: read the function bodies + eval them.
HELPER_BLOCK="$(awk '/^_accountsdb_path\(\)/,/^# .. Local-store population probes/' "$INSTALL_SH")"
# Discard the trailing section header
HELPER_BLOCK="${HELPER_BLOCK%%# .. Local-store population probes*}"
# shellcheck disable=SC1090
eval "$HELPER_BLOCK"

result="$(_accountsdb_count_mail)"
if [[ "$result" != "2" ]]; then
    failure "_accountsdb_count_mail returned '$result', expected '2' (1 AppleAccount + 1 Google, parent + inactive filtered)"
fi

if (( FAILED == 0 )); then
    echo "PASS: tests/test_cx100_mail_accounts_detection.sh"
    exit 0
else
    echo "FAILED: tests/test_cx100_mail_accounts_detection.sh" >&2
    exit 1
fi
