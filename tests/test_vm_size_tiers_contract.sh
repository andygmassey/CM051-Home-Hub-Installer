#!/usr/bin/env bash
# The installer's tier table (OSTLER_VM_SIZE_TABLE in lib/ostler-vm-size.sh) must
# equal the shared contract fixture that oa's daemon also reads (HOST_TIERS).
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$here/tests/fixtures/vm_size_tiers_contract.txt"
[ -f "$fixture" ] || { echo "FAIL: $fixture missing" >&2; exit 1; }
# shellcheck source=/dev/null
. "$here/lib/ostler-vm-size.sh"
from_lib="$(printf '%s\n' "$OSTLER_VM_SIZE_TABLE" | awk 'NF==5{print $1, $2, $3}')"
from_fixture="$(grep -v '^#' "$fixture" | awk 'NF==3{print $1, $2, $3}')"
if [ "$from_lib" = "$from_fixture" ] && [ -n "$from_lib" ]; then
    echo "PASS: tier table matches the contract fixture ($(printf '%s\n' "$from_lib" | wc -l | tr -d ' ') rows)"
    exit 0
fi
echo "FAIL: tier table differs from the contract fixture" >&2
printf 'lib:\n%s\nfixture:\n%s\n' "$from_lib" "$from_fixture" >&2
exit 1
