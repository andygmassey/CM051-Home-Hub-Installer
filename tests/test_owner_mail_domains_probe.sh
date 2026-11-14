#!/usr/bin/env bash
# Owner mail-account DOMAINS, read from Accounts4.sqlite (synthetic data only).
#
# Extracts the real helper from install.sh (so the test runs the shipped code),
# points HOME at a synthetic Accounts4 store, and checks:
#   - only the work domain comes out (never an address, never webmail)
#   - parent-auth, inactive and address-less rows are ignored
#   - no mail accounts is an answer ("") and an unreadable store is NOT ("unknown", rc 1)
#
# INSTALL_SH may point at a mutant copy (tests/owner_mail_domains_mutants.py).
set -uo pipefail

INSTALL_SH="${INSTALL_SH:-$(cd "$(dirname "$0")/.." && pwd)/install.sh}"
fail=0
AT="$(printf '\100')"   # the at-sign, built at runtime (fixtures carry no literal address)
ok()  { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/owner-mail-domains-XXXX")"
trap 'rm -rf "$TMP"' EXIT

# Pull the helper definitions out of install.sh verbatim.
extract() {
    awk '
        /^_accountsdb_path\(\) \{/ { on=1 }
        /^_OWNER_WEBMAIL_DOMAINS=/ { on=1 }
        /^_accountsdb_owner_mail_domains\(\) \{/ { on=1 }
        on { print }
        on && /^\}/ { on=0 }
        on && /^_OWNER_WEBMAIL_DOMAINS=/ { on=0 }
    ' "$INSTALL_SH"
}
DEFS="$(extract)"
if ! grep -q '^_accountsdb_owner_mail_domains() {' <<< "$DEFS"; then
    bad "helper _accountsdb_owner_mail_domains not found in install.sh"
    exit 1
fi

make_store() {   # $1 = path; rows are fixed synthetic data, '__AT__' becomes the at-sign
    sed "s/__AT__/${AT}/g" <<'SQL' | sqlite3 "$1"
CREATE TABLE ZACCOUNTTYPE (Z_PK INTEGER PRIMARY KEY, ZIDENTIFIER TEXT);
CREATE TABLE ZACCOUNT (Z_PK INTEGER PRIMARY KEY, ZACCOUNTTYPE INTEGER,
    ZUSERNAME TEXT, ZAUTHENTICATIONTYPE TEXT, ZACTIVE INTEGER);
INSERT INTO ZACCOUNTTYPE VALUES (1, 'com.apple.account.IMAP');
INSERT INTO ZACCOUNTTYPE VALUES (2, 'com.apple.account.AppleAccount');
INSERT INTO ZACCOUNTTYPE VALUES (3, 'com.apple.account.CalDAV');
-- work mail, two spellings of the same domain
INSERT INTO ZACCOUNT VALUES (1, 1, 'owner__AT__Workco.Example', NULL, 1);
INSERT INTO ZACCOUNT VALUES (2, 1, 'o.alt__AT__workco.example', NULL, 1);
-- consumer webmail: must never come out
INSERT INTO ZACCOUNT VALUES (3, 1, 'owner__AT__gmail.com', NULL, 1);
INSERT INTO ZACCOUNT VALUES (4, 2, 'owner__AT__icloud.com', NULL, 1);
-- parent-auth child row, inactive row, address-less row: ignored
INSERT INTO ZACCOUNT VALUES (5, 1, 'child__AT__other.example', 'parent', 1);
INSERT INTO ZACCOUNT VALUES (6, 1, 'old__AT__retired.example', NULL, 0);
INSERT INTO ZACCOUNT VALUES (7, 1, 'no-at-sign', NULL, 1);
-- not a mail type at all
INSERT INTO ZACCOUNT VALUES (8, 3, 'cal__AT__calendar.example', NULL, 1);
SQL
}

run_helper() {  # $1 = HOME dir; prints output, returns helper rc
    HOME="$1" bash -c "$DEFS
_accountsdb_owner_mail_domains"
}

# --- Case A: mixed store -> the work domain only -------------------------
mkdir -p "$TMP/a/Library/Accounts"
make_store "$TMP/a/Library/Accounts/Accounts4.sqlite"
out="$(run_helper "$TMP/a")"; rc=$?
if [[ "$rc" -eq 0 && "$out" == "workco.example" ]]; then
    ok "mixed store yields exactly the work domain"
else
    bad "mixed store: rc=$rc out='$out' (want rc=0 out='workco.example')"
fi
case "$out" in
    *@*) bad "an address leaked into the output" ;;
    *) ok "no address in the output" ;;
esac

# --- Case B: webmail only -> none, which is an answer, not unknown ------
mkdir -p "$TMP/b/Library/Accounts"
sed "s/__AT__/${AT}/g" <<'SQL' | sqlite3 "$TMP/b/Library/Accounts/Accounts4.sqlite"
CREATE TABLE ZACCOUNTTYPE (Z_PK INTEGER PRIMARY KEY, ZIDENTIFIER TEXT);
CREATE TABLE ZACCOUNT (Z_PK INTEGER PRIMARY KEY, ZACCOUNTTYPE INTEGER,
    ZUSERNAME TEXT, ZAUTHENTICATIONTYPE TEXT, ZACTIVE INTEGER);
INSERT INTO ZACCOUNTTYPE VALUES (1, 'com.apple.account.IMAP');
INSERT INTO ZACCOUNT VALUES (1, 1, 'owner__AT__gmail.com', NULL, 1);
INSERT INTO ZACCOUNT VALUES (2, 1, 'owner__AT__proton.me', NULL, 1);
SQL
out="$(run_helper "$TMP/b")"; rc=$?
if [[ "$rc" -eq 0 && -z "$out" ]]; then
    ok "webmail-only store is 'no work domain' (rc 0, empty)"
else
    bad "webmail-only: rc=$rc out='$out' (want rc=0, empty)"
fi

# --- Case C: unreadable store -> unknown (rc 1), never a clean empty -----
mkdir -p "$TMP/c/Library/Accounts"
printf 'this is not sqlite' > "$TMP/c/Library/Accounts/Accounts4.sqlite"
out="$(run_helper "$TMP/c")"; rc=$?
if [[ "$rc" -ne 0 ]]; then
    ok "unreadable store is reported as unknown (rc=$rc)"
else
    bad "unreadable store returned rc 0 with out='$out': that is a manufactured empty"
fi

# --- Case D: no store at all -> unknown too (nothing was looked at) -----
mkdir -p "$TMP/d"
out="$(run_helper "$TMP/d")"; rc=$?
if [[ "$rc" -ne 0 ]]; then
    ok "missing store is unknown (rc=$rc), not 'no accounts'"
else
    bad "missing store returned rc 0 (out='$out')"
fi

exit "$fail"
