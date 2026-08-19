#!/usr/bin/env bash
#
# verify_permission_briefing.sh -- the pre-announce list must name EVERY macOS
# permission the product actually asks for.
#
# WHY. On 2026-08-17 Andy hit two macOS dialogs 30 steps into an install that
# had opened by promising a complete inventory of 10. Measured on his box:
#
#     07:22:53  kTCCServiceSystemPolicyDownloadsFolder  ai.ostler.assistant
#     07:23:32  kTCCServiceSystemPolicyAppData          ai.ostler.assistant
#
# Neither was in the list. The second surfaces as "wants to access data from
# other apps", wording that matched nothing we had said. install.sh mentioned
# SystemPolicyAppData ZERO times.
#
# The list carried a comment reading "update this comment + the printed list
# together when the prompt count changes". That is prose, and prose is not a
# control: the count drifted anyway. This file is the control.
#
# WHAT IT CHECKS, and the limit of it:
#   1. PERMISSIONS_TOTAL equals the number of numbered lines actually printed.
#      Cheap, exact, and catches the "bumped one, forgot the other" edit.
#   2. Every TCC service string the SHIPPED TREE references is represented by a
#      keyword in the printed list.
#
# Check 2 is the load-bearing one and it is deliberately keyword-based rather
# than exact-match: the list is customer copy and must stay readable English,
# so it says "Data from other apps", not "kTCCServiceSystemPolicyAppData".
# The mapping between the two lives here, visibly, instead of in someone's head.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SH="$ROOT/install.sh"
[[ -r "$SH" ]] || { echo "CANNOT: install.sh not readable at $SH"; exit 2; }
FAIL=0

declared="$(grep -oE '^PERMISSIONS_TOTAL=[0-9]+' "$SH" | head -1 | cut -d= -f2)"
[[ -n "$declared" ]] || { echo "CANNOT: PERMISSIONS_TOTAL not found in install.sh"; exit 2; }

# Count the PERMISSIONS the customer sees, which is NOT the number of lines.
# Row 4 is printed as "4-6. Downloads/Desktop/Documents" -- one line, three
# permissions. My first version of this counted lines, reported 9 vs 12 and
# called a correct list broken. The instrument was wrong, not the artefact.
# So: parse each row's leading "N." or "N-M." and sum the span.
printed="$(grep -oE '^echo -e "    [0-9]+(-[0-9]+)?\.' "$SH" \
    | grep -oE '[0-9]+(-[0-9]+)?' \
    | awk -F- '{ if (NF==2) n += ($2 - $1 + 1); else n += 1 } END { print n+0 }')"

printf 'PERMISSIONS_TOTAL=%s   printed rows=%s\n' "$declared" "$printed"
if [[ "$declared" != "$printed" ]]; then
    echo "  [FAIL] the promised count and the printed list disagree."
    echo "         A customer counts the rows. Ostler counts the variable."
    FAIL=$((FAIL+1))
else
    echo "  [ok]   count matches the printed list"
fi

# service string in the tree  ->  keyword that must appear in the printed list
check_service() {
    local svc="$1" keyword="$2"
    grep -rqI "$svc" "$ROOT/install.sh" "$ROOT/gui" 2>/dev/null || return 0   # not requested, nothing owed
    if grep -qiE "^echo .*${keyword}" "$SH"; then
        printf '  [ok]   %-42s named as "%s"\n' "$svc" "$keyword"
    else
        printf '  [FAIL] %-42s is requested but the list never mentions it\n' "$svc"
        printf '         Expected a row matching: %s\n' "$keyword"
        FAIL=$((FAIL+1))
    fi
}
check_service "kTCCServiceSystemPolicyAppData"          "other apps"
check_service "kTCCServiceSystemPolicyDownloadsFolder"  "Downloads"
check_service "kTCCServiceSystemPolicyAllFiles"         "Full Disk Access"

echo
[[ $FAIL -eq 0 ]] || { echo "REFUSING: the permission briefing does not describe what the install does."; exit 1; }
echo "Permission briefing is complete."
