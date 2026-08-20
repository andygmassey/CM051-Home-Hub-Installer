#!/usr/bin/env bash
# Prove verify_permission_briefing.sh FIRES. Fixtures are throwaway install.sh
# stubs driven through the shipping entry point.
#
# Control 3 is the one that matters. The gate's first version counted LINES and
# reported 9 vs 12 on a correct list, because "4-6." is one line and three
# permissions. A gate that cries wolf on a correct tree gets switched off, so
# the range case is pinned here permanently.
set -uo pipefail
GATE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/verify_permission_briefing.sh"
PASS=0; FAIL=0; TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ok(){ printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }
mk(){ mkdir -p "$1"; printf '%s\n' "$2" > "$1/install.sh"; }
rc(){ bash "$GATE" "$1" >"$TMP/o" 2>&1; echo $?; }

# EVERY FIXTURE MUST SATISFY THE PROMPT REGISTRY, AND THAT IS NOT INCIDENTAL.
#
# The gate has TWO limbs: the count must match the printed rows, and every
# (service, requester) pair in the registry must be named. The second limb is
# UNCONDITIONAL by design -- that is the whole point of #451, where a
# tree-scanning version derived its worklist from what install.sh happened to
# mention and so could never ask about a prompt the file never named.
#
# These fixtures used to be two-row stubs mentioning Contacts and a password.
# Against the registry limb they are incomplete trees, and the gate correctly
# refuses them, so `a` and `c` were asserting rc=0 on trees that SHOULD be
# rejected. The old assertions were pinned to the old contract.
#
# So each fixture now carries the five rows the registry owes, and the arm
# under test varies ONE thing on top of that. Otherwise a count arm can go red
# for a registry reason and the failure text points at the wrong limb.
ROWS='echo -e "    1. ${BOLD}Full Disk Access${NC}  x"
echo -e "    2. ${BOLD}Downloads${NC}  y"
echo -e "    3. ${BOLD}Downloads (assistant)${NC}  y"
echo -e "    4. ${BOLD}Documents (assistant)${NC}  y"
echo -e "    5. ${BOLD}Data from other apps${NC}  z"'

mk "$TMP/a" "PERMISSIONS_TOTAL=5
$ROWS"
[[ "$(rc "$TMP/a")" == 0 ]] && ok "matching count -> green" || no "matching count wrongly failed"

mk "$TMP/b" "PERMISSIONS_TOTAL=8
$ROWS"
[[ "$(rc "$TMP/b")" == 1 ]] && ok "promises 8, prints 5 -> rc=1" || no "count mismatch NOT caught"
grep -q 'customer counts the rows' "$TMP/o" && ok "and it names the asymmetry" || no "message did not name it"

# The range row is the ORIGINAL gate bug and stays pinned permanently: "2-4."
# is ONE line and THREE permissions. A gate that counts lines reports 5 vs 7
# on a correct list, and a gate that cries wolf on a correct tree gets
# switched off. Total below is 1 + 3 + 1 + 1 + 1 = 7.
mk "$TMP/c" 'PERMISSIONS_TOTAL=7
echo -e "    1. ${BOLD}Full Disk Access${NC}  x"
echo -e "    2-4. ${BOLD}Downloads/Desktop/Documents${NC}  y"
echo -e "    5. ${BOLD}Downloads (assistant)${NC}  y"
echo -e "    6. ${BOLD}Documents (assistant)${NC}  y"
echo -e "    7. ${BOLD}Data from other apps${NC}  z"'
[[ "$(rc "$TMP/c")" == 0 ]] && ok "a RANGE row counts as its span, not as 1" || no "range row miscounted (the original gate bug)"

# AND THE REGISTRY LIMB NEEDS ITS OWN ARM, or the fixtures above quietly
# become the only thing keeping it honest. Drop the assistant's Documents row
# -- the exact prompt Andy hit mid-install on 2026-08-20 -- keep the count
# self-consistent, and the gate must still refuse.
mk "$TMP/d" 'PERMISSIONS_TOTAL=4
echo -e "    1. ${BOLD}Full Disk Access${NC}  x"
echo -e "    2. ${BOLD}Downloads${NC}  y"
echo -e "    3. ${BOLD}Downloads (assistant)${NC}  y"
echo -e "    4. ${BOLD}Data from other apps${NC}  z"'
[[ "$(rc "$TMP/d")" == 1 ]] && ok "a self-consistent count does NOT excuse an unnamed prompt" || no "the registry limb did not fire on a missing assistant-Documents row"

mk "$TMP/d" 'PERMISSIONS_TOTAL=1
echo -e "    1. ${BOLD}Contacts${NC}  x"
kTCCServiceSystemPolicyAppData'
[[ "$(rc "$TMP/d")" == 1 ]] && ok "requests AppData but never names it -> rc=1" || no "unnamed service NOT caught"

echo; echo "  $PASS passed, $FAIL failed"; [[ $FAIL == 0 ]] || exit 1
echo "ALL PERMISSION-BRIEFING CONTROLS PASSED"
