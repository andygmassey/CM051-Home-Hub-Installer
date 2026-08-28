#!/bin/bash
# #550 -- the Sparkle upgrade path must be able to shim the venvs it rebuilds.
#
# THE DEFECT THIS PINS. The upgrade block (OSTLER_UPGRADE_MODE) rm -rf's and
# rebuilds the knowledge and cm048 venvs, then calls _ostler_wire_store_auth_pth
# to install the store-auth .pth. On 38c57e18 that function is DEFINED at :6580,
# thousands of lines AFTER the upgrade block exits (~:755) -- so on every
# upgrade the call hits `command not found`, the venv is left unshimmed, and
# once OSTLER_STORE_AUTH_ENFORCE defaults on (#1222) those clients 401 against
# the enforcing stores. Definition-order in a straight-line script is an
# interface, not a detail.
#
# THE ASSERTION IS STRUCTURAL, ON LINE ORDER: the definition of
# _ostler_wire_store_auth_pth must appear at a lower line number than every call
# to it that lives INSIDE the upgrade block. A call nested in a function defined
# there but INVOKED later (e.g. _ostler_repair_venv_after_promote at ~:2545) is
# NOT counted -- definition-order only bites a call in the executing body, not
# one deferred into a later-invoked function. This test scopes to calls whose
# line is within [upgrade-block-start, upgrade-block-exit].
#
# Exit: 0 PASS  1 FAIL  3 CANNOT-RUN (never conflated with PASS)
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="${1:-${HERE}/install.sh}"
[ -r "$INSTALL" ] || { echo "CANNOT-RUN: cannot read $INSTALL"; exit 3; }

fn_def="$(grep -nE '^_ostler_wire_store_auth_pth\(\) \{' "$INSTALL" | head -1 | cut -d: -f1)"
[ -n "$fn_def" ] || { echo "CANNOT-RUN: no definition of _ostler_wire_store_auth_pth found"; exit 3; }

# the upgrade block: from its opening `if` to the `fi` that closes it.
upg_start="$(grep -nE '^if \[\[ "\$\{OSTLER_UPGRADE_MODE:-0\}" == "1" \|\| "\$\{OSTLER_UPGRADE_ROLLBACK' "$INSTALL" | head -1 | cut -d: -f1)"
[ -n "$upg_start" ] || { echo "CANNOT-RUN: upgrade block start not found"; exit 3; }
# the block ends at the first column-0 `fi` after upg_start.
upg_end="$(awk -v s="$upg_start" 'NR>s && /^fi$/ {print NR; exit}' "$INSTALL")"
[ -n "$upg_end" ] || { echo "CANNOT-RUN: upgrade block end (fi) not found"; exit 3; }

# every CALL to the fn (not the def) inside the block
mapfile -t calls < <(grep -nE '_ostler_wire_store_auth_pth ' "$INSTALL" | cut -d: -f1)
inblock=0; bad=0
for c in "${calls[@]}"; do
    if [ "$c" -gt "$upg_start" ] && [ "$c" -lt "$upg_end" ]; then
        inblock=$((inblock+1))
        if [ "$fn_def" -gt "$c" ]; then
            echo "  FAIL  upgrade-block call at :$c precedes the definition at :$fn_def -> command not found on upgrade"
            bad=$((bad+1))
        fi
    fi
done

# ANTI-VACUITY: if the upgrade block has NO calls, the test is measuring
# nothing (the venv-shim wiring was removed, or this predicate broke).
if [ "$inblock" -eq 0 ]; then
    echo "CANNOT-RUN: found 0 _ostler_wire_store_auth_pth calls inside the upgrade block (:$upg_start-:$upg_end). Predicate suspect or wiring removed."
    exit 3
fi

echo "  wire def at :$fn_def ; upgrade block :$upg_start-:$upg_end ; in-block calls: $inblock"
if [ "$bad" -gt 0 ]; then
    echo "FAIL: the upgrade path calls _ostler_wire_store_auth_pth before it is defined."
    echo "      Hoist the definition above the upgrade block (:$upg_start)."
    exit 1
fi
echo "PASS: the wire fn is defined before every upgrade-block call ($inblock checked)."
exit 0
