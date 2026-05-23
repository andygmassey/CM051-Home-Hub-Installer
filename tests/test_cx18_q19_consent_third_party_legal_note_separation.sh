#!/usr/bin/env bash
# CX-18 regression guard (Studio retest #13, 2026-05-23):
# Q19 "One last thing: how third-party data works" MUST visually split
# the customer-facing explanation from the GDPR fine-print "Legal note:"
# paragraph + style the legal note as smaller, italic, lower-contrast.
#
# The bug shape caught in retest #13: a wall of equal-weight body text
# with "Legal note:" buried mid-paragraph and the docs link at the end,
# no visual subordination.
#
# Fix shape (this file refuses regressions):
#   - ViewCopy.json MUST expose TWO separate keys for the GUI render:
#       consent_third_party.intro_body
#       consent_third_party.legal_note
#   - the SwiftUI renderer MUST have a consent_third_party branch that
#     reads BOTH keys and renders them as two distinct Text() views.
#   - the legal_note string MUST start with the "Legal note:" lead
#     (kept as the in-string lead so the customer sees it labelled).
#   - the intro_body MUST NOT contain "Legal note:" -- if it does, the
#     two strings have been re-merged and the visual split is gone.
#   - paragraph breaks inside intro_body / legal_note MUST be real LF
#     (or `\n` interpreted by SwiftUI Text), NOT the literal backslash-n
#     two-character sequence. (Sister rule to
#     test_no_literal_backslash_n_in_strings.sh but for the JSON
#     catalogue: JSON `\n` parses to a real LF, which Text renders as
#     a line break, so JSON `\n` is fine here; what we refuse is
#     `\\n` which would parse to literal backslash-n.)
#   - bash-side MSG_PROMPT_CONSENT_THIRD_PARTY_HELP MUST still contain
#     both blocks (TTY install path renders the full text inline).
#   - the SwiftUI renderer MUST style the legal_note differently from
#     the intro_body (italic + .secondary foreground) -- if both are
#     rendered with identical font + colour modifiers the visual
#     subordination is lost.
#
# References:
#   - feedback_silent_bail_regression_test_shape (refuse EXACT shape)
#   - feedback_customer_strings_extractable_from_day_one (Rule 0.9)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VIEWCOPY="${REPO_ROOT}/gui/OstlerInstaller/Resources/ViewCopy.json"
STRINGS="${REPO_ROOT}/install.sh.strings.en-GB.sh"
SWIFT_VIEW="${REPO_ROOT}/gui/OstlerInstaller/Views/OnboardingQuestionView.swift"

for f in "$VIEWCOPY" "$STRINGS" "$SWIFT_VIEW"; do
    if [[ ! -f "$f" ]]; then
        printf 'FAIL: required file missing: %s\n' "$f" >&2
        exit 1
    fi
done

read_key() {
    local key="$1"
    python3 -c "
import json, sys
d = json.load(open('$VIEWCOPY'))
node = d
for part in '$key'.split('.'):
    if not isinstance(node, dict) or part not in node:
        sys.stderr.write('FAIL: ViewCopy.json key not found: $key\n')
        sys.exit(2)
    node = node[part]
if not isinstance(node, str):
    sys.stderr.write('FAIL: ViewCopy.json key is not a string: $key\n')
    sys.exit(2)
sys.stdout.write(node)
"
}

INTRO="$(read_key 'consent_third_party.intro_body')"
LEGAL="$(read_key 'consent_third_party.legal_note')"

# Assertion 1: intro_body is non-empty.
if [[ -z "$INTRO" ]]; then
    printf 'FAIL: consent_third_party.intro_body is empty\n' >&2
    exit 1
fi
printf 'PASS: intro_body is non-empty (%d chars)\n' "${#INTRO}"

# Assertion 2: legal_note is non-empty AND leads with "Legal note:".
if [[ -z "$LEGAL" ]]; then
    printf 'FAIL: consent_third_party.legal_note is empty\n' >&2
    exit 1
fi
if [[ "$LEGAL" != "Legal note:"* ]]; then
    printf 'FAIL: consent_third_party.legal_note must lead with "Legal note:" so the customer sees the labelled fine-print; got: %q\n' \
        "${LEGAL:0:60}..." >&2
    exit 1
fi
printf 'PASS: legal_note leads with "Legal note:" lead-in\n'

# Assertion 3: intro_body MUST NOT contain "Legal note:" -- if it does,
# the two strings have been merged back into one and the visual split
# is gone.
if [[ "$INTRO" == *"Legal note:"* ]]; then
    printf 'FAIL: consent_third_party.intro_body contains "Legal note:" -- the intro + legal-note strings have been re-merged, visual split is lost\n' >&2
    exit 1
fi
printf 'PASS: intro_body does NOT contain "Legal note:" (intro + legal kept separate)\n'

# Assertion 4: neither string contains the literal two-character \n
# escape (which would render as visible \ followed by n in SwiftUI Text).
# The JSON-parsed strings here will already have escape sequences
# resolved to real chars; if a future refactor introduces literal
# backslash-n bytes inside the JSON string content, python3 would have
# read those as literal backslash-n bytes, so we check both strings.
for name in INTRO LEGAL; do
    val="${!name}"
    if [[ "$val" == *'\n'* ]]; then
        printf 'FAIL: consent_third_party.%s contains literal \\n two-char escape\n' "$(echo "$name" | tr 'A-Z' 'a-z')" >&2
        exit 1
    fi
done
printf 'PASS: neither intro_body nor legal_note contains literal \\n escape\n'

# Assertion 5: intro_body MUST itself have at least one paragraph break
# (the original copy has two paragraphs separated by a blank line).
if [[ "$INTRO" != *$'\n\n'* ]]; then
    printf 'FAIL: consent_third_party.intro_body has no paragraph break (LF LF) -- the two-paragraph intro shape is gone\n' >&2
    exit 1
fi
printf 'PASS: intro_body preserves its paragraph break\n'

# Assertion 6: bash-side MSG_PROMPT_CONSENT_THIRD_PARTY_HELP must still
# contain both the intro phrase + the "Legal note:" lead -- the TTY
# install path renders the full text inline and removing either block
# would silently strip content the customer must see.
if ! grep -q "MSG_PROMPT_CONSENT_THIRD_PARTY_HELP=" "$STRINGS"; then
    printf 'FAIL: bash catalogue missing MSG_PROMPT_CONSENT_THIRD_PARTY_HELP\n' >&2
    exit 1
fi
if ! grep -q "Legal note: For records" "$STRINGS"; then
    printf 'FAIL: bash MSG_PROMPT_CONSENT_THIRD_PARTY_HELP no longer contains "Legal note: For records" lead -- TTY path would render incomplete consent text\n' >&2
    exit 1
fi
if ! grep -q "docs.ostler.ai/privacy/third-party-data" "$STRINGS"; then
    printf 'FAIL: bash MSG_PROMPT_CONSENT_THIRD_PARTY_HELP no longer contains the docs link\n' >&2
    exit 1
fi
printf 'PASS: bash MSG_PROMPT_CONSENT_THIRD_PARTY_HELP still has both blocks + docs link\n'

# Assertion 7: the SwiftUI renderer MUST have a consent_third_party
# branch wiring the two ViewCopy keys -- without it the prompt falls
# through to the default linkifiedHelp() single-Text() path and the
# visual subordination is silently lost.
if ! grep -q 'q.prompt.id == "consent_third_party"' "$SWIFT_VIEW"; then
    printf 'FAIL: OnboardingQuestionView.swift has no consent_third_party branch; prompt falls through to default render and the legal-note styling is lost\n' >&2
    exit 1
fi
printf 'PASS: SwiftUI renderer has a consent_third_party branch\n'

# Assertion 8: the SwiftUI consentThirdPartyBody() function MUST read
# BOTH catalogue keys.
for key in "consent_third_party.intro_body" "consent_third_party.legal_note"; do
    if ! grep -q -F "\"$key\"" "$SWIFT_VIEW"; then
        printf 'FAIL: OnboardingQuestionView.swift no longer reads ViewCopy key %s\n' "$key" >&2
        exit 1
    fi
done
printf 'PASS: SwiftUI consentThirdPartyBody() reads both ViewCopy keys\n'

# Assertion 9: the SwiftUI renderer MUST style the legal_note as
# .italic + .secondary (or equivalent subordination). If both runs end
# up with identical styling the visual split is just a paragraph break,
# which is not enough.
# Extract the body of consentThirdPartyBody().
BODY="$(awk '/private func consentThirdPartyBody/,/^    }$/' "$SWIFT_VIEW")"
if [[ -z "$BODY" ]]; then
    printf 'FAIL: could not extract consentThirdPartyBody() body from %s\n' "$SWIFT_VIEW" >&2
    exit 1
fi
if ! grep -q "italic" <<< "$BODY"; then
    printf 'FAIL: consentThirdPartyBody() does not apply .italic() to any Text -- legal-note fine-print styling is lost\n' >&2
    exit 1
fi
if ! grep -q "\.secondary" <<< "$BODY"; then
    printf 'FAIL: consentThirdPartyBody() does not apply .secondary foreground to any Text -- legal-note lower-contrast styling is lost\n' >&2
    exit 1
fi
printf 'PASS: consentThirdPartyBody() applies italic + .secondary to subordinate the legal note\n'

printf '\nALL Q19 CONSENT-THIRD-PARTY LEGAL-NOTE SEPARATION TESTS PASSED\n'
