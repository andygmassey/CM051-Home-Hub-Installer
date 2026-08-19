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

mk "$TMP/a" 'PERMISSIONS_TOTAL=2
echo -e "    1. ${BOLD}Contacts${NC}  x"
echo -e "    2. ${BOLD}macOS admin password${NC}  y"'
[[ "$(rc "$TMP/a")" == 0 ]] && ok "matching count -> green" || no "matching count wrongly failed"

mk "$TMP/b" 'PERMISSIONS_TOTAL=5
echo -e "    1. ${BOLD}Contacts${NC}  x"
echo -e "    2. ${BOLD}macOS admin password${NC}  y"'
[[ "$(rc "$TMP/b")" == 1 ]] && ok "promises 5, prints 2 -> rc=1" || no "count mismatch NOT caught"
grep -q 'customer counts the rows' "$TMP/o" && ok "and it names the asymmetry" || no "message did not name it"

mk "$TMP/c" 'PERMISSIONS_TOTAL=4
echo -e "    1. ${BOLD}Contacts${NC}  x"
echo -e "    2-4. ${BOLD}Downloads/Desktop/Documents${NC}  y"'
[[ "$(rc "$TMP/c")" == 0 ]] && ok "a RANGE row counts as its span, not as 1" || no "range row miscounted (the original gate bug)"

mk "$TMP/d" 'PERMISSIONS_TOTAL=1
echo -e "    1. ${BOLD}Contacts${NC}  x"
kTCCServiceSystemPolicyAppData'
[[ "$(rc "$TMP/d")" == 1 ]] && ok "requests AppData but never names it -> rc=1" || no "unnamed service NOT caught"

echo; echo "  $PASS passed, $FAIL failed"; [[ $FAIL == 0 ]] || exit 1
echo "ALL PERMISSION-BRIEFING CONTROLS PASSED"
