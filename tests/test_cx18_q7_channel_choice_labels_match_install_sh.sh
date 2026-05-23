#!/usr/bin/env bash
# CX-18 regression guard (Studio retest #13, 2026-05-23):
# Q7 channel_choice dropdown labels in ViewCopy.json MUST be in
# 1:1 semantic agreement with install.sh's CHANNEL_CHOICE handler.
#
# The bug shape caught in retest #13: the ViewCopy labels were
# out of sync with install.sh's case-block semantics. Founder report:
# "Channels (Q7) still doesn't have the whole list of channels".
#
# Specifically:
#   - install.sh sends choices=1,2,3,4,5 to the GUI via gui_read.
#   - install.sh's `case "$CHANNEL_CHOICE" in` block treats the values
#     with these meanings:
#         1) iMessage only
#         2) Email only
#         3) iMessage + Email (default, recommended)
#         4) Skip for now
#         5) iMessage + Email + WhatsApp
#   - the previous ViewCopy.json had 7 labels (1-7), with 3 labelled
#     "WhatsApp" (wrong -- install.sh treats 3 as iMessage+Email),
#     4 labelled "iMessage + Email (recommended)" (wrong -- install.sh
#     treats 4 as Skip), and 6 + 7 as dead values install.sh refuses
#     via its choices CSV "1,2,3,4,5".
#
# Fix shape (this file refuses regressions):
#   - ViewCopy.json's onboarding_question.choice_label.channel_choice
#     MUST contain EXACTLY the 5 keys "1" through "5" -- no dead
#     entries, no missing entries.
#   - install.sh MUST still pass choices CSV "1,2,3,4,5" to gui_read
#     for the channel_choice prompt -- if the CSV changes, the
#     ViewCopy labels MUST change in lockstep.
#   - the label for "3" MUST imply the iMessage + Email combination
#     (semantic match with install.sh's case 3 block) -- the previous
#     "WhatsApp" label was the bug.
#   - the label for "4" MUST imply a Skip semantic -- the previous
#     "iMessage + Email (recommended)" label was the bug.
#   - the label for "5" MUST mention WhatsApp -- install.sh's case 5
#     is the WhatsApp-enabled combination.
#
# References:
#   - feedback_silent_bail_regression_test_shape (refuse EXACT shape)
#   - feedback_customer_strings_extractable_from_day_one (Rule 0.9)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VIEWCOPY="${REPO_ROOT}/gui/OstlerInstaller/Resources/ViewCopy.json"
INSTALL_SH="${REPO_ROOT}/install.sh"

for f in "$VIEWCOPY" "$INSTALL_SH"; do
    if [[ ! -f "$f" ]]; then
        printf 'FAIL: required file missing: %s\n' "$f" >&2
        exit 1
    fi
done

# Assertion 1: extract install.sh's choices CSV passed to gui_read for
# the channel_choice prompt. This is the canonical set of supported
# values; the ViewCopy labels MUST agree.
INSTALL_CSV="$(grep -E 'gui_read .* "channel_choice"' "$INSTALL_SH" \
    | sed -E 's/.*gui_read[^"]*"[^"]*"[[:space:]]+choice[[:space:]]+"[^"]*"[[:space:]]+"[^"]*"[[:space:]]+"([^"]*)"[[:space:]]+"channel_choice".*/\1/' \
    | head -1)"
if [[ -z "$INSTALL_CSV" ]]; then
    printf 'FAIL: could not extract choices CSV from install.sh gui_read channel_choice call\n' >&2
    exit 1
fi
printf 'install.sh sends choices=%s for channel_choice\n' "$INSTALL_CSV"

# Split CSV into a sorted set of values for comparison.
INSTALL_VALUES="$(printf '%s\n' "$INSTALL_CSV" | tr ',' '\n' | sort -u | xargs)"

# Assertion 2: extract the keys from ViewCopy.json's
# onboarding_question.choice_label.channel_choice block.
VIEWCOPY_KEYS="$(python3 -c "
import json
d = json.load(open('$VIEWCOPY'))
block = d['onboarding_question']['choice_label']['channel_choice']
# Skip _meta-prefixed comment keys
keys = sorted(k for k in block.keys() if not k.startswith('_'))
print(' '.join(keys))
")"
printf 'ViewCopy.json channel_choice keys: %s\n' "$VIEWCOPY_KEYS"

# Assertion 3: install.sh CSV and ViewCopy keys MUST be the SAME SET.
# If install.sh accepts a value the customer cannot pick, that value
# silently breaks the prompt; if ViewCopy offers a value install.sh
# rejects, the customer picks something the case-block dumps into the
# default branch.
if [[ "$INSTALL_VALUES" != "$VIEWCOPY_KEYS" ]]; then
    printf 'FAIL: ViewCopy channel_choice keys do not match install.sh choices CSV.\n' >&2
    printf '  install.sh choices=%s -> values {%s}\n' "$INSTALL_CSV" "$INSTALL_VALUES" >&2
    printf '  ViewCopy keys        -> values {%s}\n' "$VIEWCOPY_KEYS" >&2
    printf '  (founder report: "Channels (Q7) still does not have the whole list of channels")\n' >&2
    exit 1
fi
printf 'PASS: ViewCopy channel_choice keys exactly match install.sh choices CSV (%s)\n' "$INSTALL_VALUES"

# Assertion 4: pull each label value out for semantic spot-checks.
read_label() {
    local n="$1"
    python3 -c "
import json
d = json.load(open('$VIEWCOPY'))
print(d['onboarding_question']['choice_label']['channel_choice']['$n'])
"
}

LABEL_1="$(read_label 1)"
LABEL_2="$(read_label 2)"
LABEL_3="$(read_label 3)"
LABEL_4="$(read_label 4)"
LABEL_5="$(read_label 5)"

printf 'Labels:\n'
printf '  1=%q\n' "$LABEL_1"
printf '  2=%q\n' "$LABEL_2"
printf '  3=%q\n' "$LABEL_3"
printf '  4=%q\n' "$LABEL_4"
printf '  5=%q\n' "$LABEL_5"

# Assertion 5: label 1 mentions iMessage (install.sh case 1 = iMessage only).
if ! [[ "$LABEL_1" == *iMessage* ]]; then
    printf 'FAIL: channel_choice label 1 (%q) should mention "iMessage" -- install.sh treats 1 as iMessage only\n' "$LABEL_1" >&2
    exit 1
fi
printf 'PASS: label 1 mentions iMessage\n'

# Assertion 6: label 2 mentions Email (install.sh case 2 = Email only).
if ! [[ "$LABEL_2" == *Email* ]]; then
    printf 'FAIL: channel_choice label 2 (%q) should mention "Email" -- install.sh treats 2 as Email only\n' "$LABEL_2" >&2
    exit 1
fi
printf 'PASS: label 2 mentions Email\n'

# Assertion 7: label 3 MUST imply iMessage + Email (install.sh case 3
# is the default, recommended, iMessage AND Email). The retest #13 bug
# was label 3 = "WhatsApp" (wrong).
if ! { [[ "$LABEL_3" == *iMessage* ]] && [[ "$LABEL_3" == *Email* ]]; }; then
    printf 'FAIL: channel_choice label 3 (%q) MUST mention BOTH iMessage AND Email -- install.sh treats 3 as iMessage+Email (default, recommended). The retest #13 regression was label 3 = "WhatsApp" which is install.sh case 5'\''s job.\n' "$LABEL_3" >&2
    exit 1
fi
printf 'PASS: label 3 implies iMessage + Email (install.sh case 3 default)\n'

# Assertion 8: label 3 should also flag itself as the recommended /
# default choice (the bash terminal hint says "(recommended)"), so the
# GUI customer sees the same nudge.
if ! [[ "$LABEL_3" == *recommended* || "$LABEL_3" == *default* ]]; then
    printf 'FAIL: channel_choice label 3 (%q) should flag itself as "recommended" so the customer sees the same default nudge install.sh prints on the terminal hint\n' "$LABEL_3" >&2
    exit 1
fi
printf 'PASS: label 3 is flagged as recommended/default\n'

# Assertion 9: label 4 MUST imply a Skip semantic (install.sh case 4 =
# Skip for now / set up later). The retest #13 bug was label 4 =
# "iMessage + Email (recommended)" (wrong -- that's case 3).
if ! [[ "$LABEL_4" =~ [Ss]kip|[Ll]ater ]]; then
    printf 'FAIL: channel_choice label 4 (%q) MUST imply a Skip semantic (Skip / later) -- install.sh treats 4 as "Skip for now"\n' "$LABEL_4" >&2
    exit 1
fi
printf 'PASS: label 4 implies Skip / later (install.sh case 4)\n'

# Assertion 10: label 5 MUST mention WhatsApp (install.sh case 5 is
# the WhatsApp-enabled combination). The retest #13 bug labelled 5 as
# "iMessage + WhatsApp" which is partially right but loses the Email
# leg -- install.sh case 5 enables all three.
if ! [[ "$LABEL_5" == *WhatsApp* ]]; then
    printf 'FAIL: channel_choice label 5 (%q) MUST mention "WhatsApp" -- install.sh treats 5 as iMessage + Email + WhatsApp\n' "$LABEL_5" >&2
    exit 1
fi
if ! { [[ "$LABEL_5" == *iMessage* ]] && [[ "$LABEL_5" == *Email* ]]; }; then
    printf 'FAIL: channel_choice label 5 (%q) MUST mention all three channels (iMessage AND Email AND WhatsApp) -- install.sh case 5 enables all three; the retest #13 regression dropped Email\n' "$LABEL_5" >&2
    exit 1
fi
printf 'PASS: label 5 mentions all three channels (iMessage + Email + WhatsApp)\n'

# Assertion 11: no label should mention any channel install.sh does
# NOT support at install time (e.g. SMS, Slack, Telegram). The set of
# legitimate channel names today is iMessage, Email, WhatsApp.
ALL_LABELS="${LABEL_1} ${LABEL_2} ${LABEL_3} ${LABEL_4} ${LABEL_5}"
for forbidden in SMS Slack Telegram Discord Signal Teams; do
    if [[ "$ALL_LABELS" == *"$forbidden"* ]]; then
        printf 'FAIL: channel_choice labels mention "%s" but install.sh does not support it at install time\n' "$forbidden" >&2
        exit 1
    fi
done
printf 'PASS: no labels mention channels install.sh does not support\n'

printf '\nALL Q7 CHANNEL-CHOICE SEMANTIC ALIGNMENT TESTS PASSED\n'
