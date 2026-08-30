#!/usr/bin/env bash
# scripts/tests/test_store_curl_conf_permissions.sh
# ============================================================================
# THE SECRETS DIRECTORY MUST BE 0700, NOT JUST THE FILE INSIDE IT.
#
# _ostler_write_store_curl_config writes a credential the whole 8044/8144
# close depends on: if another local account can present the header, closing
# the port buys nothing (#549/#550). @TNM checked the FILE and it is correct --
# `umask 0077` is set BEFORE the truncate, inside the subshell, so the file is
# never briefly world-readable with a secret already in it.
#
# The DIRECTORY was not. mkdir sat OUTSIDE that subshell with no mode, so
# secrets/ kept whatever mode it was born with -- typically 0755 holding a
# 0600 file. No credential leaks that way. The filenames and their existence
# do, and on a shared Mac that is the same class the close exists to shut.
#
# THE MKDIR CANNOT CREATE THAT DIRECTORY, ON ANY REACHABLE PATH.
# The function reads oxigraph_token and qdrant_api_key out of secrets/ and
# returns 1 when both are empty. Reaching the mkdir therefore PROVES the
# directory already existed. So `mkdir -p -m 700` -- the obvious one-word fix --
# would never fire: -m only modes components mkdir actually creates, and this
# mkdir creates none, ever. The chmod is the entire fix. Arm C pins that
# reachability claim so nobody "simplifies" the chmod back into a -m flag.
#
# MUTATION-PROVED against the pre-fix line
#     mkdir -p "${OSTLER_DIR}/secrets" 2>/dev/null || true
# and against the tempting wrong fix `mkdir -p -m 700 …`. BOTH go RED on arms
# A and B. An assertion that cannot fail on the original defect is not a
# regression test, and one that cannot fail on the plausible wrong fix does
# not protect the reasoning.
#
# 🔻 MY FIRST VERSION OF THIS FILE WAS WRONG and the mutation run is what
# caught it: it had two arms labelled "fresh install" and "upgrade" which
# pre-created the directory identically, so they were one scenario written
# twice and the "fresh" label was false. A fixture can encode the flag rather
# than the property.
# ============================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/../.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"

PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

if [ ! -r "$INSTALL_SH" ]; then
    echo "CANNOT-RUN: ${INSTALL_SH} is not readable. Nothing was examined, which is not a pass."
    exit 78
fi

# Extract ONLY the writer. Sourcing install.sh whole would run an installer.
_fn="$(sed -n '/^_ostler_write_store_curl_config() {/,/^}/p' "$INSTALL_SH")"
if [ -z "$_fn" ]; then
    echo "CANNOT-RUN: could not extract _ostler_write_store_curl_config from install.sh."
    echo "            It may have been renamed. Nothing ran, which is not a pass."
    exit 78
fi
# MUST-HIT CONTROL on the extraction: a body missing the thing under test
# means the sed range is wrong and every assertion below measures an empty
# function -- the shape of a false green.
case "$_fn" in
    *"secrets"*) : ;;
    *) echo "CANNOT-RUN: extracted body never mentions secrets/ -- sed range is wrong."; exit 78 ;;
esac
eval "$_fn"

mode_of() { /usr/bin/stat -f '%OLp' "$1" 2>/dev/null; }

seed() { # seed <dir> <mode>  -- create secrets/ with both credential files
    mkdir -p "${1}/secrets"
    # Synthetic and obviously fake. Never a real token, and described by role
    # rather than value so this fixture can never become a scanner's subject.
    printf 'not-a-real-token-fixture\n' > "${1}/secrets/oxigraph_token"
    printf 'not-a-real-key-fixture\n'   > "${1}/secrets/qdrant_api_key"
    chmod "$2" "${1}/secrets"
}

echo "--- arm A: secrets/ exists at 0755 (the real-world case) ---"
_d="$(mktemp -d)"; OSTLER_DIR="$_d"; _OSTLER_STORE_CURL_ARGS=()
seed "$_d" 0755
_ostler_write_store_curl_config; _rc=$?
_dm="$(mode_of "${_d}/secrets")"; _fm="$(mode_of "${_d}/secrets/store-curl.conf")"
printf '[A] rc=%s dir=%s file=%s\n' "$_rc" "${_dm:-<absent>}" "${_fm:-<absent>}"
[ "$_rc" = 0 ]     && ok "A: returned 0"            || bad "A: returned ${_rc}, expected 0"
[ "$_dm" = "700" ] && ok "A: secrets/ re-moded to 0700" || bad "A: secrets/ is ${_dm:-<absent>}, expected 700 -- another local account can list the credential filenames"
[ "$_fm" = "600" ] && ok "A: store-curl.conf is 0600"   || bad "A: store-curl.conf is ${_fm:-<absent>}, expected 600"
rm -rf "$_d"

echo "--- arm B: secrets/ ALREADY 0700 -- must stay, and must not regress ---"
_d="$(mktemp -d)"; OSTLER_DIR="$_d"; _OSTLER_STORE_CURL_ARGS=()
seed "$_d" 0700
_ostler_write_store_curl_config; _rc=$?
_dm="$(mode_of "${_d}/secrets")"
printf '[B] rc=%s dir=%s\n' "$_rc" "${_dm:-<absent>}"
[ "$_rc" = 0 ]     && ok "B: returned 0"          || bad "B: returned ${_rc}, expected 0"
[ "$_dm" = "700" ] && ok "B: secrets/ still 0700" || bad "B: secrets/ became ${_dm:-<absent>} -- the writer widened its own directory"
rm -rf "$_d"

echo "--- arm C: secrets/ ABSENT -- fail closed, and create NOTHING ---"
echo "    This pins the reachability claim: the mkdir is never a creator, so"
echo "    mkdir -p -m 700 would be a fix that never fires."
_d="$(mktemp -d)"; OSTLER_DIR="$_d"; _OSTLER_STORE_CURL_ARGS=()
_ostler_write_store_curl_config; _rc=$?
printf '[C] rc=%s secrets_exists=%s\n' "$_rc" "$([ -d "${_d}/secrets" ] && echo yes || echo no)"
[ "$_rc" = 1 ] && ok "C: failed closed with rc=1" \
               || bad "C: returned ${_rc}, expected 1 -- with no credential it must refuse, not write"
[ ! -d "${_d}/secrets" ] && ok "C: created no secrets/ directory (mkdir is unreachable as a creator)" \
                         || bad "C: created secrets/ -- the early return no longer guards the mkdir, and the -m reasoning in install.sh is now stale"
[ ! -e "${_d}/secrets/store-curl.conf" ] && ok "C: wrote no credential file" \
                                         || bad "C: wrote a credential file with no credential to put in it"
rm -rf "$_d"

echo
echo "examined: 3 arms, 8 assertions"
echo "pass ${PASS} / fail ${FAIL}"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
