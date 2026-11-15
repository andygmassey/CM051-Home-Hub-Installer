#!/bin/bash
# O3 (2026-11-15): a Homebrew prefix owned by ANOTHER account must stop the
# installer in preflight, in plain English, before any brew call. Ostler never
# chowns or chmods it and never uses sudo for it.
#
# Real files, real uids, no mocks of stat or id:
#   /usr is a real directory owned by root (uid 0), not writable by the test
#   account. That is the second-account case: a prefix this account cannot use.
#   A mktemp directory is owned by this account: the control that must pass.
#   A path that does not exist is a fresh Mac: the control that must pass.
#
# Runs the real install.sh --check (prerequisites only, installs nothing) with a
# sandbox HOME. RED before the preflight block exists: arm 1 exits 0 with no
# refusal. GREEN after: arm 1 exits non-zero and names the refusal.
#
# Run bare: bash tests/test_foreign_homebrew_refuses_before_install.sh
# CANNOT-RUN here: a true second macOS account (proven later on the MBP's
# ostlerwalk account). This test proves the same uid and writability rule on
# a root-owned path this account cannot write.

set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="${REPO}/install.sh"
FAILS=0

check() {
    if [ "$1" = "ok" ]; then echo "ok   $2"; else echo "FAIL $2"; FAILS=$((FAILS + 1)); fi
}

if [ "$(stat -f %u /usr)" = "$(id -u)" ] || [ -w /usr ]; then
    echo "CANNOT-RUN: /usr is writable or owned by this account; no foreign root-owned path to test"
    exit 2
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/o3-brew-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
OWN_PREFIX="${SANDBOX}/own-prefix"
mkdir "$OWN_PREFIX"
ABSENT_PREFIX="${SANDBOX}/absent-prefix"
USR_BEFORE="$(stat -f '%u %Mp%Lp' /usr)"

run_check() {
    # $1 = prefix. Prints combined output; sets RC.
    local out="${SANDBOX}/out.$$.txt"
    mkdir -p "${SANDBOX}/home"
    HOME="${SANDBOX}/home" OSTLER_BREW_PREFIX="$1" bash "$INSTALL" --check >"$out" 2>&1
    RC=$?
    OUT="$(cat "$out")"
}

# Arm 1: foreign-owned prefix must refuse.
run_check /usr
REFUSAL_TEXT="belongs to another account"
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q -F "$REFUSAL_TEXT"; then
    check ok "arm 1: foreign-owned prefix (/usr, uid 0) refuses with rc=$RC and names the cause"
else
    check fail "arm 1: foreign-owned prefix (/usr, uid 0) refuses (got rc=$RC; refusal text present: $(printf '%s' "$OUT" | grep -c -F "$REFUSAL_TEXT"))"
fi
if printf '%s' "$OUT" | grep -q -F "ERR-02-HOMEBREW-OTHER-ACCOUNT"; then
    check ok "arm 1b: refusal carries ERR-02-HOMEBREW-OTHER-ACCOUNT"
else
    check fail "arm 1b: refusal carries ERR-02-HOMEBREW-OTHER-ACCOUNT"
fi

# Arm 2 (control): prefix owned by this account must NOT refuse.
run_check "$OWN_PREFIX"
if [ "$RC" -eq 0 ] && ! printf '%s' "$OUT" | grep -q -F "belongs to another account"; then
    check ok "arm 2: control, prefix owned by this account passes preflight (rc=0)"
else
    check fail "arm 2: control, prefix owned by this account passes preflight (rc=$RC)"
fi

# Arm 3 (control): absent prefix (fresh Mac) must NOT refuse.
run_check "$ABSENT_PREFIX"
if [ "$RC" -eq 0 ] && ! printf '%s' "$OUT" | grep -q -F "belongs to another account"; then
    check ok "arm 3: control, absent prefix (fresh Mac) passes preflight (rc=0)"
else
    check fail "arm 3: control, absent prefix (fresh Mac) passes preflight (rc=$RC)"
fi

# Arm 4: nothing was changed. The foreign path keeps its owner and mode.
if [ "$(stat -f '%u %Mp%Lp' /usr)" = "$USR_BEFORE" ]; then
    check ok "arm 4: /usr owner and mode unchanged by the runs ($USR_BEFORE)"
else
    check fail "arm 4: /usr owner and mode unchanged by the runs (was $USR_BEFORE, now $(stat -f '%u %Mp%Lp' /usr))"
fi

echo ""
if [ "$FAILS" -gt 0 ]; then
    echo "FAILED: $FAILS"
    exit 1
fi
echo "All foreign-Homebrew preflight checks passed."
