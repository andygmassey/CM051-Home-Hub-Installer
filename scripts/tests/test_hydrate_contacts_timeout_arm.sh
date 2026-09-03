#!/usr/bin/env bash
# A KILLED CONTACTS WRAPPER MUST NOT BE REPORTED AS AN EMPTY ADDRESS BOOK.
#
# install.sh bounds the contacts hydrate. The bound alone would have made the
# product WORSE, because the pre-existing `|| _HYDRATE_CONTACTS_JSON=""`
# collapses every failure into "no contacts found": a timeout would then print
# MSG_HYDRATE_CONTACTS_EMPTY_LOCAL_AND_ICLOUD to a customer with thousands of
# cards, and record a no_data sentinel that suppresses the retry for 7 days.
# That is #852's shape, and it would have been introduced BY the fix.
#
# So the outcome arm tests the timeout flag BEFORE the count, and this asserts
# exactly that ordering. Cases A and B are DEMONSTRATED RED against the
# pre-fix arm (count-first); C and D pin the unchanged behaviour so the fix
# cannot be "proved" by breaking the happy path.
#
# Self-contained: it re-implements the arm rather than sourcing install.sh,
# which cannot be sourced without running an install. That is a real limit and
# it is stated -- the guard below is what stops the two drifting apart.
set -uo pipefail

FAILED=0
note() { printf '  [%s] %s\n' "$1" "$2"; }
check() { # name expected actual
    if [[ "$2" == "$3" ]]; then note PASS "$1"
    else note FAIL "$1 -- expected '$2', got '$3'"; FAILED=1; fi
}

warn() { printf 'WARN:%s\n' "$1"; }
ok()   { printf 'OK:%s\n' "$1"; }
_hydrate_sentinel_record_error() { printf 'SENTINEL_ERROR:%s:%s\n' "$1" "$2"; }
_hydrate_sentinel_record()       { printf 'SENTINEL_OK:%s\n' "$1"; }
MSG_HYDRATE_CONTACTS_TIMED_OUT="stopped waiting after %ss, %s so far"
MSG_HYDRATE_CONTACTS_DONE="Imported %s contacts"
MSG_HYDRATE_CONTACTS_EMPTY_LOCAL_AND_ICLOUD="address book looks empty"

# The arm AS SHIPPED: timeout tested before count.
arm_fixed() {
    if [[ "$_HYDRATE_CONTACTS_TIMED_OUT" == "true" ]]; then
        warn "$(printf "$MSG_HYDRATE_CONTACTS_TIMED_OUT" "$_HYDRATE_CONTACTS_CAP" "$_HYDRATE_CONTACTS_COUNT")"
        _hydrate_sentinel_record_error "contacts" "$_HYDRATE_CONTACTS_RC"
    elif [[ "$_HYDRATE_CONTACTS_COUNT" -gt 0 ]]; then
        ok "$(printf "$MSG_HYDRATE_CONTACTS_DONE" "$_HYDRATE_CONTACTS_COUNT")"
        _hydrate_sentinel_record "contacts"
    else
        warn "$MSG_HYDRATE_CONTACTS_EMPTY_LOCAL_AND_ICLOUD"
    fi
}

# The arm WITHOUT the fix: count first, timeout invisible. Present so the
# cases below are proved to discriminate rather than merely to pass.
arm_prefix() {
    if [[ "$_HYDRATE_CONTACTS_COUNT" -gt 0 ]]; then
        ok "$(printf "$MSG_HYDRATE_CONTACTS_DONE" "$_HYDRATE_CONTACTS_COUNT")"
        _hydrate_sentinel_record "contacts"
    else
        warn "$MSG_HYDRATE_CONTACTS_EMPTY_LOCAL_AND_ICLOUD"
    fi
}

set_case() { _HYDRATE_CONTACTS_TIMED_OUT="$1"; _HYDRATE_CONTACTS_RC="$2"
             _HYDRATE_CONTACTS_COUNT="$3"; _HYDRATE_CONTACTS_CAP=1800; }

echo "hydrate-contacts timeout arm:"

# A. Timeout with a PARTIAL import. A non-zero count is NOT evidence the step
#    completed -- the wrapper was killed mid-run.
set_case true 124 900
check "A timeout+partial records an ERROR sentinel" \
      "SENTINEL_ERROR:contacts:124" "$(arm_fixed | grep '^SENTINEL')"
check "A control: pre-fix arm called the same state a clean success" \
      "SENTINEL_OK:contacts" "$(arm_prefix | grep '^SENTINEL')"

# B. Timeout with ZERO imported. Must NOT be the empty-address-book message.
set_case true 124 0
check "B timeout+zero records an ERROR sentinel" \
      "SENTINEL_ERROR:contacts:124" "$(arm_fixed | grep '^SENTINEL')"
# Written flat on purpose. The first version of this assertion was
#   grep -c ... | grep '^0$' >/dev/null && echo '' || echo CLAIMED-EMPTY
# and it FAILED against correct code: `grep -c` exits 1 when it counts zero,
# and under `set -o pipefail` that exit wins the whole pipeline, so the `||`
# arm fired even though the inner grep matched. A pipe decides $? in a way the
# reader does not see. Capture, then test.
b_out="$(arm_fixed)"
if grep -q 'address book looks empty' <<<"$b_out"; then b_claim="CLAIMED-EMPTY"; else b_claim=""; fi
check "B timeout+zero does not claim the address book is empty" "" "$b_claim"
check "B control: pre-fix arm DID claim the address book was empty" \
      "WARN:address book looks empty" "$(arm_prefix | grep '^WARN')"

# C+D. Unchanged behaviour, so the fix cannot pass by breaking the happy path.
set_case false 0 2410
check "C clean success unchanged" "SENTINEL_OK:contacts" "$(arm_fixed | grep '^SENTINEL')"
set_case false 0 0
check "D genuinely empty book unchanged" \
      "WARN:address book looks empty" "$(arm_fixed | grep '^WARN')"

# E. THE DRIFT GUARD. This file re-implements the arm, so it can silently stop
#    describing install.sh. Assert the shipped ordering is still timeout-first
#    by reading install.sh itself: the TIMED_OUT test must appear BEFORE the
#    count test inside the contacts outcome block.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ ! -r "$root/install.sh" ]]; then
    note CANNOT-RUN "install.sh unreadable at $root -- drift guard did not run"
    FAILED=1
else
    t_line=$(grep -n '_HYDRATE_CONTACTS_TIMED_OUT" == "true"' "$root/install.sh" | head -1 | cut -d: -f1)
    c_line=$(grep -n 'elif \[\[ "\$_HYDRATE_CONTACTS_COUNT" -gt 0 \]\]' "$root/install.sh" | head -1 | cut -d: -f1)
    if [[ -z "$t_line" || -z "$c_line" ]]; then
        note CANNOT-RUN "ordering anchors not found (timeout='$t_line' count='$c_line') -- this guard is blind, not clean"
        FAILED=1
    elif (( t_line < c_line )); then
        note PASS "E install.sh still tests timeout ($t_line) before count ($c_line)"
    else
        note FAIL "E install.sh tests count ($c_line) before timeout ($t_line) -- the arm regressed"
        FAILED=1
    fi
fi

if (( FAILED )); then echo "hydrate-contacts timeout arm: FAILED"; exit 1; fi
echo "hydrate-contacts timeout arm: clean (7 assertions, 2 of them pre-fix controls, 1 drift guard)"
