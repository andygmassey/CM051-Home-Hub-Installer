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

# WHY THIS IS A REGISTRY AND NOT A TREE SCAN. THE PREVIOUS SHAPE WENT GREEN ON
# A LIVE DEFECT, 2026-08-20.
#
# The old check_service opened with:
#     grep -rqI "$svc" install.sh gui || return 0   # not requested, nothing owed
# so its worklist was "services install.sh happens to mention". That is the
# SAME failure this file was written for. Its own header records the 2026-08-17
# incident and says "install.sh mentioned SystemPolicyAppData ZERO times" -- and
# then derives its worklist from install.sh. A prompt the file never names is a
# prompt the gate can never ask about. A search scoped to what you already know
# cannot find what you do not.
#
# Measured on 2026-08-20: the tree referenced exactly three service strings
# (AllFiles x2, DownloadsFolder, AppData) and ZERO for Documents. Andy hit the
# assistant's Documents prompt mid-install that morning. The gate was green
# throughout, having examined nothing on that surface.
#
# So the list below is now the AUTHORITY, kept by hand, and every row is owed
# unconditionally. Adding a prompt to the product means adding it here; there is
# no path where silence reads as compliance.
#
# REQUESTER is load-bearing and is the second half of today's fix. A TCC prompt
# is a pair, (service, requesting identity), because TCC pins a grant to
# identifier+team -- which is exactly why the assistant must ask again for
# folders the installer already holds. Matching on keyword alone let the
# installer's own row "4-6. Downloads/Desktop/Documents" satisfy the ASSISTANT's
# Documents prompt: the word was present, the requester was not, and the
# customer still met an unannounced dialog.
#
#   service | requester | keyword the row must contain | must the row name the assistant
# The keyword is matched with grep -F, LITERALLY. My first version passed it to
# grep -iE and every assistant row failed on a correct tree, because "(assistant)"
# is ERE grouping: the engine read it as the word "assistant", not the
# parenthesised text on the line. That is the instrument being wrong rather than
# the artefact, which is the failure line 42 of this file already warns about,
# and I walked into it anyway one screen further down.
#
# Every matching row is considered, not just the first. A keyword like
# "Documents" legitimately appears twice -- once for the installer's own
# pre-warm, once for the assistant -- so "first match does not qualify" is not
# the same as "no row qualifies". Taking head -1 would fail a correct list.
check_prompt() {
    local svc="$1" requester="$2" keyword="$3" needs_assistant="$4"
    local matched=0 qualified=0 row

    while IFS= read -r row; do
        [[ -n "$row" ]] || continue
        matched=$((matched+1))
        if [[ "$needs_assistant" == "yes" ]]; then
            printf '%s' "$row" | grep -qi 'assistant' && qualified=1
        else
            qualified=1
        fi
    done < <(grep -E '^echo -e "    [0-9]+(-[0-9]+)?\.' "$SH" | grep -F "$keyword")

    if [[ "$matched" -eq 0 ]]; then
        printf '  [FAIL] %-42s (%s) is raised but NO row mentions "%s"\n' "$svc" "$requester" "$keyword"
        FAIL=$((FAIL+1))
    elif [[ "$qualified" -eq 0 ]]; then
        printf '  [FAIL] %-42s (%s): %d row(s) mention "%s", none name the assistant.\n' \
            "$svc" "$requester" "$matched" "$keyword"
        printf '         The installer already holds this grant. TCC pins a grant to\n'
        printf '         identifier+team, so the assistant must ask AGAIN under its own\n'
        printf '         identity, and the customer needs telling that it will.\n'
        FAIL=$((FAIL+1))
    else
        printf '  [ok]   %-42s (%s) named, %d row(s) matched "%s"\n' \
            "$svc" "$requester" "$matched" "$keyword"
    fi
}
check_prompt "kTCCServiceSystemPolicyAllFiles"        "installer" "Full Disk Access" no
check_prompt "kTCCServiceSystemPolicyDownloadsFolder" "installer" "Downloads"        no
check_prompt "kTCCServiceSystemPolicyDownloadsFolder" "assistant" "Downloads"        yes
check_prompt "kTCCServiceSystemPolicyDocumentsFolder" "assistant" "Documents"        yes
check_prompt "kTCCServiceSystemPolicyAppData"         "assistant" "other apps"       no

echo
[[ $FAIL -eq 0 ]] || { echo "REFUSING: the permission briefing does not describe what the install does."; exit 1; }
echo "Permission briefing is complete."
